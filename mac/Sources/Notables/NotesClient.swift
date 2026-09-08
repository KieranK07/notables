import Foundation

/// Talks to the note server on the Windows PC. See docs/PROTOCOL.md.
actor NotesClient {

    struct Config: Sendable {
        var host: String
        var port: Int
        var token: String
        var baseURL: URL { URL(string: "http://\(host):\(port)")! }

        static let defaultHost = "100.69.103.126"   // desktop-kd53etc over Tailscale
        static let defaultPort = 8787

        static func load() -> Config {
            let d = UserDefaults.standard
            let host = d.string(forKey: "serverHost") ?? defaultHost
            let port = d.integer(forKey: "serverPort")
            return Config(host: host,
                          port: port > 0 ? port : defaultPort,
                          token: Config.readToken())
        }

        /// Shared secret, same file the server reads on its side.
        static func readToken() -> String {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".notables/token")
            return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum ClientError: LocalizedError {
        case unauthorized
        case server(Int, String)
        case offline(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:        return "The server rejected our token. Re-sync ~/.notables/token."
            case .server(let c, let m): return "Server error \(c): \(m)"
            case .offline(let m):      return m
            }
        }
    }

    private var config: Config
    private let session: URLSession

    init(config: Config = .load()) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600      // SSE streams stay open
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func updateConfig(_ new: Config) { config = new }
    func currentConfig() -> Config { config }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        // NOT appendingPathComponent: it treats the whole string as one path segment
        // and escapes "?" to "%3F", so any query string becomes part of the path and
        // the server answers 404. Split the query off and set it as a query.
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        comps.path = "/" + parts[0]
        if parts.count > 1 { comps.percentEncodedQuery = String(parts[1]) }
        var r = URLRequest(url: comps.url ?? config.baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func run(_ r: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: r) }
        catch { throw ClientError.offline("Can't reach the note server — is the PC awake and on Tailscale?") }
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - API

    func health() async throws -> Bool {
        let data = try await run(request("api/health"))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["ok"] as? Bool) ?? true
    }

    func fetchIndex() async throws -> NotesIndex {
        let data = try await run(request("api/notes"))
        return try Self.decoder.decode(NotesIndex.self, from: data)
    }

    func fetchNote(id: String) async throws -> NoteDetail {
        let data = try await run(request("api/note/\(id)"))
        return try Self.decoder.decode(NoteDetail.self, from: data)
    }

    func reprocess(id: String) async throws {
        _ = try await run(request("api/note/\(id)/reprocess", method: "POST", body: Data("{}".utf8)))
    }

    /// Deletes the note and everything derived from it — markdown, transcript, audio,
    /// deadlines. The server refuses (409) while the note is mid-pipeline.
    func deleteNote(id: String) async throws {
        _ = try await run(request("api/note/\(id)", method: "DELETE"))
    }

    // ------------------------------------------------------------- canvas
    struct CanvasUser: Codable, Sendable {
        var id: String
        var name: String?
        var login: String?
    }

    struct CanvasStatus: Codable, Sendable {
        var connected: Bool
        var hasSession: Bool
        var host: String?
        var user: CanvasUser?
        var savedAt: String?
        var checkedAt: String?
        var expiredAt: String?
        var error: String?

        /// A session we once had and Canvas has since rejected. This is the state
        /// that must never be silent — it looks exactly like "nothing new" otherwise.
        var needsReconnect: Bool { hasSession == false || expiredAt != nil }
    }

    struct MaterialsSummary: Codable, Sendable, Identifiable {
        var course: String
        var canvasName: String?
        var courseCode: String?
        var term: String?
        var syncedAt: String?
        var moduleCount: Int
        var fileCount: Int
        var textChars: Int
        var problems: Int
        var glossaryTerms: Int
        var id: String { course }
    }

    struct MaterialFile: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var module: String
        var itemTitle: String?
        var via: String?
        var size: Int?
        var updatedAt: String?
        var textPath: String?
        var alsoIn: [String]?
        var extract: Extract?

        struct Extract: Codable, Sendable {
            var state: String
            var chars: Int?
            var pages: Int?
            var method: String?
            var error: String?
        }

        /// Text that came from OCR rather than a real text layer. Shown as such —
        /// it is genuinely less reliable, and pretending otherwise is the kind of
        /// quiet degradation this project keeps designing against.
        var isOCR: Bool { extract?.method == "ocr" }

        /// Present in Canvas but with nothing readable inside — a real gap in what
        /// the pipeline knows, which the UI shows rather than hides.
        var hasText: Bool { extract?.state == "ok" }
        var gapReason: String? {
            switch extract?.state {
            case "ok", .none:        return nil
            case "no-text-layer":    return "scanned image, no text"
            case "unsupported":      return "not a text format"
            default:                 return extract?.error ?? "extraction failed"
            }
        }
    }

    struct CourseMaterials: Codable, Sendable {
        var canvasCourseId: String?
        var canvasName: String?
        var courseCode: String?
        var term: String?
        var syncedAt: String?
        var modules: [Module]?
        var files: [String: MaterialFile]
        var links: [Link]?

        struct Module: Codable, Sendable { var id: String; var name: String; var position: Int; var folder: String }
        struct Link: Codable, Sendable { var title: String; var url: String; var module: String }

        /// Files grouped by module, in Canvas's own module order.
        var byModule: [(module: String, files: [MaterialFile])] {
            let order = (modules ?? []).sorted { $0.position < $1.position }.map(\.folder)
            let groups = Dictionary(grouping: files.values, by: \.module)
            return groups.keys.sorted {
                let a = order.firstIndex(of: $0) ?? Int.max
                let b = order.firstIndex(of: $1) ?? Int.max
                return a == b ? $0 < $1 : a < b
            }.map { ($0, groups[$0]!.sorted { $0.name < $1.name }) }
        }
    }

    private struct MaterialsListReply: Codable {
        var courses: [MaterialsSummary]
        var syncing: Bool
    }
    private struct MaterialsCourseReply: Codable { var materials: CourseMaterials }
    private struct MaterialTextReply: Codable {
        var text: String?
        var canvasUrl: String?
        var file: MaterialFile?
    }

    func fetchMaterials() async throws -> (courses: [MaterialsSummary], syncing: Bool) {
        let data = try await run(request("api/materials"))
        let r = try Self.decoder.decode(MaterialsListReply.self, from: data)
        return (r.courses, r.syncing)
    }

    func fetchCourseMaterials(_ course: String) async throws -> CourseMaterials {
        let data = try await run(request("api/materials?course=\(Self.esc(course))"))
        return try Self.decoder.decode(MaterialsCourseReply.self, from: data).materials
    }

    func fetchMaterialText(course: String, id: String)
        async throws -> (text: String?, canvasUrl: String?, file: MaterialFile?) {
        let data = try await run(request("api/material?course=\(Self.esc(course))&id=\(Self.esc(id))"))
        let r = try Self.decoder.decode(MaterialTextReply.self, from: data)
        return (r.text, r.canvasUrl, r.file)
    }

    /// Download a synced file to a local cache and return its file URL, so the app
    /// can render the real PDF / deck rather than only its extracted text.
    /// Cached by file id + the sync stamp, so a re-synced file re-downloads and an
    /// unchanged one is instant.
    func materialFileURL(course: String, file: MaterialFile) async throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notables/materials", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Keep the real extension: QuickLook picks its previewer from it.
        let ext = (file.name as NSString).pathExtension
        let stamp = (file.updatedAt ?? "0").replacingOccurrences(of: ":", with: "")
        var name = "\(file.id)-\(stamp)"
        if !ext.isEmpty { name += ".\(ext)" }
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        let r = request("api/material/file?course=\(Self.esc(course))&id=\(Self.esc(file.id))")
        let (tmp, response) = try await session.download(for: r)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            if http.statusCode == 401 { throw ClientError.unauthorized }
            throw ClientError.server(http.statusCode, "could not fetch the file")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    func setTodoDone(id: String, done: Bool) async throws {
        _ = try await run(request("api/todo/\(Self.esc(id))/\(done ? "done" : "undone")",
                                  method: "POST", body: Data("{}".utf8)))
    }

    func syncCanvas(full: Bool = false) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["full": full])
        _ = try await run(request("api/canvas/sync", method: "POST", body: body))
    }

    /// Percent-encode a query VALUE.
    ///
    /// Not `.urlQueryAllowed`: that set permits `&`, `=`, `+` and `#`, because they
    /// are legal *in a query* — just not inside a single value. A course actually
    /// called "Intro Distributed & Cloud Computing" would otherwise arrive as
    /// `course=Intro Distributed ` plus a second, junk parameter. Encode everything
    /// outside the unreserved set.
    private static let unreserved: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    private static func esc(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private struct CanvasSessionBody: Codable { var host: String; var cookie: String }
    private struct CanvasSessionReply: Codable { var ok: Bool; var user: CanvasUser }
    private struct CanvasStatusReply: Codable { var ok: Bool; var canvas: CanvasStatus }

    /// Hand the harvested Canvas cookie to the PC. The server verifies it against
    /// /api/v1/users/self and refuses to store one that doesn't actually work, so a
    /// success here means the session is genuinely live.
    func connectCanvas(host: String, cookie: String) async throws -> CanvasUser {
        let body = try JSONEncoder().encode(CanvasSessionBody(host: host, cookie: cookie))
        let data = try await run(request("api/canvas/session", method: "POST", body: body))
        return try Self.decoder.decode(CanvasSessionReply.self, from: data).user
    }

    func canvasStatus() async throws -> CanvasStatus {
        let data = try await run(request("api/canvas/status"))
        return try Self.decoder.decode(CanvasStatusReply.self, from: data).canvas
    }

    func disconnectCanvas() async throws {
        _ = try await run(request("api/canvas/disconnect", method: "POST", body: Data("{}".utf8)))
    }

    struct IngestPayload: Codable {
        var id: String
        var title: String
        var recordedAt: String
        var durationSec: Double
        var locale: String
        var device: String
        var audioBytes: Int
        var audioFormat: String
        /// Apple's fast on-device pass. A preview and a fallback — never the final text.
        var draftTranscript: String
        /// Local only; not sent. Lets the outbox find the file again after a relaunch.
        var localAudioPath: String?

        enum CodingKeys: String, CodingKey {
            case id, title, recordedAt, durationSec, locale, device
            case audioBytes, audioFormat, draftTranscript
        }
    }

    /// Step 1 — announce the recording so the server can reserve the note.
    func ingest(_ payload: IngestPayload) async throws {
        let body = try JSONEncoder().encode(payload)
        _ = try await run(request("api/ingest", method: "POST", body: body))
    }

    /// Step 2 — the audio itself, raw body (no multipart; the server is Node stdlib).
    func uploadAudio(id: String, from url: URL) async throws {
        var r = request("api/audio/\(id)", method: "PUT")
        r.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 600

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.upload(for: r, fromFile: url) }
        catch { throw ClientError.offline("Audio upload failed — is the PC awake?") }

        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// What the PC has of a recording, and whether the Mac may stop holding its copy.
    struct AudioStatus: Codable, Sendable {
        var received: Int
        var expected: Int
        var complete: Bool
        var state: String
        /// Set by the server only. The Mac deletes a lecture on this and nothing else.
        var safeToDelete: Bool
        var notePath: String?
        var transcriptPath: String?
    }

    func audioStatus(id: String) async throws -> AudioStatus {
        let data = try await run(request("api/audio/\(id)/status"))
        return try Self.decoder.decode(AudioStatus.self, from: data)
    }

    /// Everything `AVURLAsset` needs to stream a recording straight off the PC.
    ///
    /// Streaming rather than downloading is the whole point: the server honours Range, so
    /// playback starts on the first few seconds instead of waiting out a 15 MB transfer,
    /// and the wait no longer grows with the length of the lecture.
    func audioStreamSource(id: String) -> (url: URL, headers: [String: String]) {
        let r = request("api/audio/\(id)")
        return (r.url ?? config.baseURL, ["Authorization": "Bearer \(config.token)"])
    }

    // MARK: - Chat

    /// What a conversation is scoped to. Identifies a directory on the PC by naming
    /// things the manifest already knows — the app never sends a path, so there is no
    /// route for one to be forged.
    struct ChatScope: Codable, Hashable, Identifiable, Sendable {
        var course: String
        var module: String?
        var fileId: String?
        /// For the window title; the server derives its own from the manifest.
        var label: String
        /// course | module | file
        var kind: String

        var id: String { [course, module ?? "", fileId ?? ""].joined(separator: "\u{1}") }

        static func course(_ name: String) -> ChatScope {
            ChatScope(course: name, module: nil, fileId: nil, label: name, kind: "course")
        }
        static func module(_ folder: String, in course: String) -> ChatScope {
            ChatScope(course: course, module: folder, fileId: nil,
                      label: folder.replacingOccurrences(of: #"^\d+\s+"#, with: "",
                                                         options: .regularExpression),
                      kind: "module")
        }
        static func file(_ id: String, named name: String, in course: String) -> ChatScope {
            ChatScope(course: course, module: nil, fileId: id, label: name, kind: "file")
        }
    }

    enum ChatEvent: Sendable {
        case started(model: String, label: String)
        case delta(String)
        case tool(name: String, detail: String)
        case done(sessionId: String, text: String, seconds: Double?)
        case failed(String)
    }

    struct ChatSession: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var title: String
        var label: String?
        var kind: String?
        var updatedAt: String
        var messages: Int
    }

    struct ChatTranscript: Codable, Sendable {
        var id: String
        var messages: [Message]
        struct Message: Codable, Sendable, Identifiable {
            var role: String
            var text: String
            var at: String?
            var attachments: [String]?
            var id: String { (at ?? "") + role + String(text.prefix(24)) }
        }
    }

    private struct ChatRequest: Encodable {
        var scope: ChatScope
        var sessionId: String?
        var text: String
        var attachments: [String]
    }

    /// One turn, streamed as newline-delimited JSON.
    ///
    /// Not the SSE channel: that stream has been seen dying silently for hours, and a
    /// chat that quietly stops printing is worse than one that fails loudly. This turn
    /// owns its own response body, so a dead connection surfaces as a thrown error.
    nonisolated func chatStream(scope: ChatScope, sessionId: String?, text: String,
                                attachments: [String]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamChat(scope: scope, sessionId: sessionId, text: text,
                                              attachments: attachments, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ChatWire: Decodable {
        var t: String
        var text: String?
        var name: String?
        var detail: String?
        var message: String?
        var sessionId: String?
        var label: String?
        var model: String?
        var meta: Meta?
        struct Meta: Decodable { var durationMs: Double?; var costUsd: Double?; var turns: Int? }
    }

    private func streamChat(scope: ChatScope, sessionId: String?, text: String,
                            attachments: [String],
                            into continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws {
        var r = request("api/chat", method: "POST",
                        body: try JSONEncoder().encode(ChatRequest(scope: scope, sessionId: sessionId,
                                                                   text: text, attachments: attachments)))
        // A turn that reads several PDFs genuinely takes a while; the server's own
        // claude timeout is the real ceiling.
        r.timeoutInterval = 900

        let (bytes, response) = try await session.bytes(for: r)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ClientError.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await b in bytes { body.append(Character(UnicodeScalar(b))) }
                throw ClientError.server(http.statusCode, Self.errorText(body))
            }
        }

        // Raw bytes, not `.lines` — same reason as the SSE parser.
        var buffer: [UInt8] = []
        for try await byte in bytes {
            guard byte == 0x0A else { buffer.append(byte); continue }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            guard !line.isEmpty, let ev = try? Self.decoder.decode(ChatWire.self, from: Data(line.utf8))
            else { continue }
            switch ev.t {
            case "scope":    continuation.yield(.started(model: ev.model ?? "", label: ev.label ?? scope.label))
            case "delta":    if let t = ev.text { continuation.yield(.delta(t)) }
            case "tool":     continuation.yield(.tool(name: ev.name ?? "", detail: ev.detail ?? ""))
            case "done":
                continuation.yield(.done(sessionId: ev.sessionId ?? "", text: ev.text ?? "",
                                         seconds: ev.meta?.durationMs.map { $0 / 1000 }))
            case "error":    continuation.yield(.failed(ev.message ?? "Claude reported an error."))
            default:         break
            }
        }
    }

    /// Pull the server's `{"ok":false,"error":"…"}` out of a failed response.
    private static func errorText(_ body: String) -> String {
        guard let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let e = o["error"] as? String else { return body }
        return e
    }

    /// Put one photo or file on the PC and get back the path to reference in the turn.
    func uploadChatAttachment(sessionId: String, name: String, data: Data) async throws -> String {
        let q = "session=\(Self.esc(sessionId))&name=\(Self.esc(name))"
        var r = request("api/chat/attachment?" + q, method: "POST")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 300

        let (out, response): (Data, URLResponse)
        do { (out, response) = try await session.upload(for: r, from: data) }
        catch { throw ClientError.offline("Couldn't send the attachment — is the PC awake?") }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 { throw ClientError.unauthorized }
            throw ClientError.server(http.statusCode, String(data: out, encoding: .utf8) ?? "")
        }
        struct Reply: Codable { var path: String }
        return try Self.decoder.decode(Reply.self, from: out).path
    }

    private struct SessionsReply: Codable { var sessions: [ChatSession] }

    func chatSessions(scope: ChatScope?) async throws -> [ChatSession] {
        var q = ""
        if let s = scope {
            q = "?course=\(Self.esc(s.course))"
                + "&module=\(Self.esc(s.module ?? ""))"
                + "&fileId=\(Self.esc(s.fileId ?? ""))"
        }
        let data = try await run(request("api/chat/sessions" + q))
        return try Self.decoder.decode(SessionsReply.self, from: data).sessions
    }

    private struct TranscriptReply: Codable { var session: ChatTranscript }

    func chatTranscript(id: String) async throws -> ChatTranscript {
        let data = try await run(request("api/chat/session/\(Self.esc(id))"))
        return try Self.decoder.decode(TranscriptReply.self, from: data).session
    }

    func deleteChatSession(id: String) async throws {
        _ = try await run(request("api/chat/session/\(Self.esc(id))", method: "DELETE"))
    }

    // MARK: - SSE

    enum Event: Sendable {
        case note(Note)
        case noteDeleted(String)
        case todos([Todo])
        case state(id: String, state: String, detail: String?)
        case canvas(CanvasEvent)
        case connected
        case disconnected(String)
    }

    /// Canvas sync progress, and — the part that matters — session expiry.
    struct CanvasEvent: Codable, Sendable {
        var syncing: Bool?
        var phase: String?
        var course: String?
        var done: Int?
        var total: Int?
        var item: String?
        var connected: Bool?
        var expiredAt: String?
        var glossary: Glossary?
        struct Glossary: Codable, Sendable { var course: String; var added: Int; var total: Int }
    }

    /// Long-lived event stream. Reconnects with backoff; yields `.connected` each time it
    /// (re)attaches so the UI can resync and clear any "offline" banner.
    nonisolated func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                var backoff: UInt64 = 1
                while !Task.isCancelled {
                    do {
                        try await self.streamOnce(into: continuation)
                        backoff = 1
                    } catch {
                        continuation.yield(.disconnected(error.localizedDescription))
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(Double(backoff)))
                    backoff = min(backoff * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamOnce(into continuation: AsyncStream<Event>.Continuation) async throws {
        var r = request("api/events")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 3600

        let (bytes, response) = try await session.bytes(for: r)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ClientError.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                throw ClientError.server(http.statusCode, "event stream refused")
            }
        }
        continuation.yield(.connected)

        // Deliberately NOT `bytes.lines`: AsyncLineSequence drops empty lines, and the
        // blank line is exactly what terminates an SSE event. Split the bytes ourselves.
        var buffer: [UInt8] = []
        var eventName = "message"
        var dataLines: [String] = []

        for try await byte in bytes {
            guard byte == 0x0A else { buffer.append(byte); continue }
            if buffer.last == 0x0D { buffer.removeLast() }          // tolerate CRLF
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)

            if line.isEmpty {                                        // dispatch point
                if !dataLines.isEmpty {
                    Self.dispatch(name: eventName,
                                  data: dataLines.joined(separator: "\n"),
                                  to: continuation)
                }
                eventName = "message"
                dataLines = []
            } else if line.hasPrefix(":") {
                continue                                             // keepalive comment
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        throw ClientError.offline("Event stream closed by the server.")
    }

    private static func dispatch(name: String, data: String, to c: AsyncStream<Event>.Continuation) {
        guard let raw = data.data(using: .utf8) else { return }
        switch name {
        case "note":
            if let note = try? decoder.decode(Note.self, from: raw) { c.yield(.note(note)) }
        case "note-deleted":
            struct Deleted: Decodable { let id: String }
            if let d = try? decoder.decode(Deleted.self, from: raw) { c.yield(.noteDeleted(d.id)) }
        case "todos":
            struct Wrapper: Decodable { let todos: [Todo] }
            if let w = try? decoder.decode(Wrapper.self, from: raw) { c.yield(.todos(w.todos)) }
            else if let list = try? decoder.decode([Todo].self, from: raw) { c.yield(.todos(list)) }
        case "state":
            if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let id = obj["id"] as? String {
                c.yield(.state(id: id,
                               state: obj["state"] as? String ?? "",
                               detail: obj["detail"] as? String))
            }
        case "canvas":
            if let e = try? decoder.decode(CanvasEvent.self, from: raw) { c.yield(.canvas(e)) }
        default: break
        }
    }

    static let decoder = JSONDecoder()
}
