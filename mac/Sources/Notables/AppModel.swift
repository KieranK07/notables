import Foundation
import SwiftUI
import AVFoundation      // AVAudioFile, to read a recovered recording's true duration

@MainActor
final class AppModel: ObservableObject {

    @Published var notes: [Note] = []
    @Published var courses: [Course] = []
    @Published var todos: [Todo] = []
    @Published var selection: Selection = .allNotes
    @Published var selectedNoteID: String?
    @Published var detail: NoteDetail?
    @Published var loadingDetail = false
    @Published var connection: Connection = .connecting
    @Published var banner: String?
    @Published var searchText: String = ""
    /// The day the calendar is looking at; the detail pane reads from here.
    @Published var calendarDay: String = Dates.iso(Date())
    /// The deadline open in the detail pane.
    @Published var selectedTodoID: String?
    @Published var pendingUploads: Int = 0
    @Published var uploadingID: String?
    /// Audio still held on this Mac. Recordings the PC has finished with are released.
    @Published var localAudioBytes: Int = 0

    // --- canvas ---------------------------------------------------------
    @Published var canvas: NotesClient.CanvasStatus?
    @Published var materials: [NotesClient.MaterialsSummary] = []
    @Published var canvasSyncing = false
    @Published var canvasProgress: String?

    /// True when Canvas once worked and has since stopped. This has to be visible:
    /// an expired session looks exactly like "no new materials" if it is not.
    var canvasNeedsReconnect: Bool {
        guard let c = canvas else { return false }
        return c.expiredAt != nil || (c.hasSession && !c.connected)
    }

    let recorder = Recorder()
    let player = AudioPlayer()
    private let client = NotesClient()
    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    enum Selection: Hashable { case allNotes, todos, calendar, materials, course(String) }

    // MARK: - Deadlines
    //
    // Grouped by urgency rather than listed flat: what matters is "is this late,
    // is it today, is it this week", not a wall of dates.
    struct DueGroup: Identifiable {
        let title: String
        let todos: [Todo]
        var id: String { title }
    }

    var dueGroups: [DueGroup] {
        let open = openTodos
        var late: [Todo] = [], today: [Todo] = [], week: [Todo] = [], later: [Todo] = [], undated: [Todo] = []
        for t in open {
            guard t.due != nil else { undated.append(t); continue }
            switch t.dueStyle {
            case .overdue: late.append(t)
            case .today:   today.append(t)
            case .soon:    week.append(t)
            default:       later.append(t)
            }
        }
        return [
            DueGroup(title: "Late", todos: late),
            DueGroup(title: "Today", todos: today),
            DueGroup(title: "This week", todos: week),
            DueGroup(title: "Later", todos: later),
            DueGroup(title: "No date", todos: undated),
        ].filter { !$0.todos.isEmpty }
    }

    /// Open items due on a given day, for the calendar.
    func todos(on iso: String) -> [Todo] {
        todos.filter { $0.due == iso && !$0.done }
    }
    func notes(on iso: String) -> [Note] {
        notes.filter { $0.classDate == iso }
    }
    var lateCount: Int { openTodos.filter { $0.dueStyle == .overdue }.count }
    enum Connection: Equatable {
        case connecting, online, offline(String)
        var isOnline: Bool { if case .online = self { return true }; return false }
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard eventTask == nil else { return }
        // The recording is on the PC, so playback streams it from there.
        player.streamSource = { [client] id in await client.audioStreamSource(id: id) }
        eventTask = Task { await self.listen() }
        outboxTask = Task { await self.drainOutboxLoop() }
        Task { await refresh() }
        Task { await self.warmUpSpeechModel() }
        Task {
            await self.recoverOrphanRecordings()
            await self.reconcileLocalAudio()
        }
        reconcileTask = Task { await self.reconcileLoop() }

        // Coming back to the app is the other moment worth re-checking: if the event
        // stream died while the Mac was idle, this is what makes the UI honest again.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
                await self.reconcileLocalAudio()
            }
        }
        pendingUploads = Outbox.pending().count
    }

    private func warmUpSpeechModel() async {
        guard #available(macOS 26.0, *) else { return }
        try? await LiveTranscriber.prepareModel()
    }

    func refresh() async {
        do {
            let index = try await client.fetchIndex()
            apply(index)
            connection = .online
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    private func apply(_ index: NotesIndex) {
        notes = index.notes.sorted { $0.sortDate > $1.sortDate }
        courses = index.courses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        todos = index.todos ?? []
    }

    private func listen() async {
        for await event in client.events() {
            switch event {
            case .connected:
                connection = .online
                banner = nil
                await refresh()
                await refreshCanvas()
            case .disconnected(let why):
                connection = .offline(why)
            case .note(let note):
                upsert(note)
                if note.id == selectedNoteID { await loadDetail(note.id) }
                if note.state == .ready { await reclaimLocalAudio(for: note.id) }
            case .noteDeleted(let id):
                removeLocally(id)
            case .todos(let list):
                todos = list
            case .state(let id, let state, _):
                if let i = notes.firstIndex(where: { $0.id == id }),
                   let s = NoteState(rawValue: state) {
                    notes[i].state = s
                }
            case .canvas(let e):
                applyCanvasEvent(e)
            }
        }
    }

    private func applyCanvasEvent(_ e: NotesClient.CanvasEvent) {
        if let syncing = e.syncing { canvasSyncing = syncing }
        if let g = e.glossary {
            banner = "Learned \(g.added) terms from \(g.course) materials — \(g.total) total."
        }
        if canvasSyncing {
            if let phase = e.phase, let course = e.course {
                if let done = e.done, let total = e.total, total > 0 {
                    canvasProgress = "\(course): \(phase) \(done)/\(total)"
                } else {
                    canvasProgress = "\(course): \(phase)"
                }
            }
        } else {
            canvasProgress = nil
            Task { await refreshCanvas() }
        }
        if e.expiredAt != nil { Task { await refreshCanvas() } }
    }

    /// Tick a deadline off. Optimistic: the row responds immediately and the server
    /// is told after, because waiting on a 50ms relayed round trip to redraw a
    /// checkbox feels broken.
    func setTodoDone(_ todo: Todo, _ done: Bool) {
        guard let i = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        let previous = todos[i].done
        todos[i].done = done
        Task {
            do { try await client.setTodoDone(id: todo.id, done: done) }
            catch {
                if let j = todos.firstIndex(where: { $0.id == todo.id }) { todos[j].done = previous }
                banner = "Couldn't update that item: \(error.localizedDescription)"
            }
        }
    }

    func refreshCanvas() async {
        canvas = try? await client.canvasStatus()
        if let m = try? await client.fetchMaterials() {
            materials = m.courses
            canvasSyncing = m.syncing
        }
    }

    func syncCanvas(full: Bool = false) async {
        do {
            try await client.syncCanvas(full: full)
            canvasSyncing = true
            canvasProgress = "starting…"
        } catch {
            banner = "Canvas sync could not start: \(error.localizedDescription)"
        }
    }

    private func upsert(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        else { notes.append(note) }
        notes.sort { $0.sortDate > $1.sortDate }
        if !courses.contains(where: { $0.name == note.course }) {
            courses.append(Course(name: note.course, noteCount: 1, lastClass: note.classDate))
            courses.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Detail

    func select(_ id: String?) {
        // A lecture must not carry on playing under a note you have navigated away from.
        if player.noteID != id { player.stop() }
        selectedNoteID = id
        detail = nil
        guard let id else { return }
        Task { await loadDetail(id) }
    }

    private func loadDetail(_ id: String) async {
        loadingDetail = true
        defer { loadingDetail = false }
        do { detail = try await client.fetchNote(id: id) }
        catch { banner = error.localizedDescription }
    }

    func reprocess(_ id: String) {
        Task {
            do { try await client.reprocess(id: id); banner = "Re-running the notes pass…" }
            catch { banner = error.localizedDescription }
        }
    }

    /// Renames a note on the PC. The server owns the vault — it writes the new title into
    /// the note's front matter as well as the index — so this waits for it to confirm and
    /// then applies the same change here rather than guessing ahead of it.
    func renameNote(_ id: String, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != notes.first(where: { $0.id == id })?.title else { return }
        Task {
            do {
                try await client.renameNote(id: id, title: title)
                if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].title = title }
                if selectedNoteID == id { await loadDetail(id) }
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    /// Deletes a note on the PC and drops it here. The server owns the vault, so this waits
    /// for it to confirm before touching local state — and only then releases this Mac's
    /// copy of the audio, which is otherwise held until `safeToDelete`, a flag a deleted
    /// note will never produce.
    func deleteNote(_ id: String) {
        Task {
            let title = notes.first(where: { $0.id == id })?.title ?? "That note"
            do {
                try await client.deleteNote(id: id)
                LocalRecordings.all().filter { $0.id == id }.forEach { _ = LocalRecordings.remove($0) }
                localAudioBytes = LocalRecordings.all().reduce(0) { $0 + $1.bytes }
                removeLocally(id)
                banner = "Deleted “\(title)”."
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    /// Drop a deleted note from this window, whether we deleted it or another client did.
    private func removeLocally(_ id: String) {
        notes.removeAll { $0.id == id }
        todos.removeAll { $0.source == "note:" + id }
        if selectedNoteID == id {
            selectedNoteID = nil
            detail = nil
        }
    }

    // MARK: - Recording

    @Published var recordingTitle: String = ""

    func startRecording() async {
        let id = UUID().uuidString
        currentRecordingID = id
        await recorder.start(id: id)
    }

    private var currentRecordingID: String?

    func stopRecordingAndSend() async {
        guard let id = currentRecordingID else { return }
        let startedAt = Date().addingTimeInterval(-recorder.elapsed)
        let result = await recorder.stop()
        // Survives stop() on purpose: a recording that never saw a single sample above the
        // silence floor is not a recording, and the user has to hear that now rather than
        // discover it when the note comes back empty an hour later.
        let capturedNothing = !recorder.heardSignal
        let inputName = recorder.inputDeviceName ?? "the input device"
        currentRecordingID = nil

        guard let audioURL = result.url,
              let size = try? FileManager.default
                .attributesOfItem(atPath: audioURL.path)[.size] as? Int, size > 0 else {
            banner = "The recording file is empty — nothing was captured."
            return
        }

        let title = recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = NotesClient.IngestPayload(
            id: id,
            title: title.isEmpty ? defaultTitle() : title,
            recordedAt: ISO8601.string(startedAt),
            durationSec: result.duration,
            locale: Locale.current.identifier,
            device: Host.current().localizedName ?? "mac",
            audioBytes: size,
            audioFormat: "m4a",
            draftTranscript: result.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            localAudioPath: audioURL.path
        )

        // Queue to disk first. A sleeping PC can never cost us a lecture.
        // Silent audio is still uploaded: the durability contract does not get to decide
        // the recording was worthless, and the server reports the empty transcript as a
        // visible failure. The banner is what makes it visible here.
        Outbox.save(payload)
        pendingUploads = Outbox.pending().count
        recordingTitle = ""
        // The panel keeps `finalText` so stop() can return it; clear it now that the note
        // is queued, or the next recording opens showing the last class's transcript.
        recorder.clearTranscript()
        if capturedNothing {
            banner = "That recording is completely silent — \(inputName) captured nothing. "
                   + "Check System Settings › Sound › Input before the next class."
        }
        await drainOutbox()
    }

    private func defaultTitle() -> String {
        "Class \(DateFormatter.friendly.string(from: Date()))"
    }

    func cancelRecording() async {
        await recorder.cancel()
        currentRecordingID = nil
    }

    // MARK: - Local audio

    /// Every recording still on this Mac that the PC has finished with.
    ///
    /// The Mac used to keep a copy of every lecture forever, which is a term of audio on
    /// a laptop SSD. It now keeps one only until the PC says `safeToDelete` — audio
    /// verified there, whisper transcript written, note written. After that the recording
    /// is fetched on demand from `GET /api/audio/{id}`.
    func reconcileLocalAudio() async {
        let recordings = LocalRecordings.all()
        guard !recordings.isEmpty else { return }
        var freed = 0
        for rec in recordings {
            guard await canRelease(rec) else { continue }
            if LocalRecordings.remove(rec) { freed += rec.bytes }
        }
        localAudioBytes = LocalRecordings.all().reduce(0) { $0 + $1.bytes }
        if freed > 0 { banner = "Freed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file)) — those lectures live on the PC now." }
    }

    /// Releasing audio must not depend on the event stream.
    ///
    /// The SSE `note` event is the fast path, but it is a *push* channel: it has been seen
    /// silently absent — app running, zero open connections, `sseClients: 0` on the server
    /// — after the Mac sat idle for a few hours. A recording whose note went ready in that
    /// window would otherwise sit on disk forever. This poll is the floor: cheap when the
    /// directory is empty, and it costs one request per held recording per minute when it
    /// is not.
    private func reconcileLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if !LocalRecordings.all().isEmpty { await reconcileLocalAudio() }
        }
    }

    /// The same check for one note, run the moment it reaches `ready` over SSE.
    private func reclaimLocalAudio(for id: String) async {
        guard let rec = LocalRecordings.all().first(where: { $0.id == id }), await canRelease(rec) else { return }
        guard LocalRecordings.remove(rec) else { return }
        localAudioBytes = LocalRecordings.all().reduce(0) { $0 + $1.bytes }
        banner = "Freed \(ByteCountFormatter.string(fromByteCount: Int64(rec.bytes), countStyle: .file)) — that lecture lives on the PC now."
    }

    /// Deleting the only copy of a lecture is unforgiving, so this refuses on anything it
    /// is not certain about: the file being written right now, anything still queued for
    /// upload, and — the one that actually matters — anything the *server* has not
    /// explicitly cleared. `safeToDelete` is never inferred locally, and an unreachable
    /// PC means "keep it", because `audioStatus` throwing is not consent.
    /// File any recording on this Mac that never made it into the outbox.
    ///
    /// `stopRecordingAndSend` writes the outbox entry only after `recorder.stop()` returns.
    /// If the app dies in that window - it was killed mid-stop once, taking a 79-minute
    /// class with it - the audio is sitting right there and nothing will ever look at it
    /// again. So on launch, a recording with no outbox entry and no note on the PC gets
    /// one rebuilt from the file itself. Recordings that were cancelled are already
    /// deleted from disk, so there is nothing here to resurrect against the user's wishes.
    func recoverOrphanRecordings() async {
        for rec in LocalRecordings.all() {
            guard rec.id != currentRecordingID else { continue }
            guard !Outbox.pending().contains(where: { $0.id == rec.id }) else { continue }
            guard rec.bytes > 0 else { continue }
            // Does the PC already know about it? Anything but a clean "no" is left alone.
            if let status = try? await client.audioStatus(id: rec.id), status.received > 0 { continue }
            if notes.contains(where: { $0.id == rec.id }) { continue }

            // A file the system cannot open is not a recording the PC can transcribe - it
            // is one that needs repairing. Say so rather than pushing 29 MB of unusable
            // AAC over a 1.6 MB/s relay to produce a failed note at the other end.
            guard let audio = try? AVAudioFile(forReading: rec.url) else {
                banner = "A recording on this Mac is damaged and can't be filed " +
                         "(\(rec.id.prefix(8))). The audio is still in " +
                         "~/Documents/Notables/Recordings."
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: rec.url.path)
            let recordedAt = (attrs?[.creationDate] as? Date) ?? Date()
            let duration = audio.processingFormat.sampleRate > 0
                ? Double(audio.length) / audio.processingFormat.sampleRate : 0

            let payload = NotesClient.IngestPayload(
                id: rec.id,
                title: "Recovered class \(DateFormatter.friendly.string(from: recordedAt))",
                recordedAt: ISO8601.string(recordedAt),
                durationSec: duration,
                locale: Locale.current.identifier,
                device: Host.current().localizedName ?? "mac",
                audioBytes: rec.bytes,
                audioFormat: "m4a",
                draftTranscript: "",
                localAudioPath: rec.url.path
            )
            Outbox.save(payload)
            banner = "Found a recording that was never filed — uploading it now."
        }
        pendingUploads = Outbox.pending().count
        if pendingUploads > 0 { await drainOutbox() }
    }

    private func canRelease(_ rec: LocalRecordings.Item) async -> Bool {
        if rec.id == currentRecordingID { return false }
        if Outbox.pending().contains(where: { $0.id == rec.id }) { return false }
        guard let status = try? await client.audioStatus(id: rec.id) else { return false }
        return status.safeToDelete
    }

    // MARK: - Outbox

    private func drainOutboxLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if !Outbox.pending().isEmpty { await drainOutbox() }
        }
    }

    func drainOutbox() async {
        for payload in Outbox.pending() {
            do {
                try await client.ingest(payload)

                // The audio is the point now — the PC transcribes it, so the note isn't
                // real until these bytes land. An entry therefore only leaves the outbox
                // once the audio is on the PC, or is provably gone from this Mac.
                guard let path = payload.localAudioPath else {
                    banner = "“\(payload.title)” uploaded without its audio — retrying."
                    continue
                }
                guard FileManager.default.fileExists(atPath: path) else {
                    banner = "Audio for “\(payload.title)” is missing from this Mac — sent the draft transcript only."
                    Outbox.remove(payload.id)
                    continue
                }
                uploadingID = payload.id
                defer { uploadingID = nil }
                try await client.uploadAudio(id: payload.id, from: URL(fileURLWithPath: path))

                Outbox.remove(payload.id)
                connection = .online
            } catch {
                connection = .offline(error.localizedDescription)
                banner = "Saved on this Mac — will upload when the PC is reachable."
                break
            }
        }
        pendingUploads = Outbox.pending().count
        if pendingUploads == 0 { await refresh() }
    }

    // MARK: - Derived

    var visibleNotes: [Note] {
        var list = notes
        if case .course(let name) = selection { list = list.filter { $0.course == name } }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.lowercased().contains(q)
            || $0.course.lowercased().contains(q)
            || ($0.summary ?? "").lowercased().contains(q)
            || $0.tags.contains { $0.lowercased().contains(q) }
            || ($0.section ?? "").lowercased().contains(q)
        }
    }

    var openTodos: [Todo] {
        todos.filter { !$0.done }.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a < b
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return $0.text < $1.text
            }
        }
    }
}

/// Durable local queue of recordings waiting to reach the PC.
/// The recordings directory on this Mac, addressed by note id — the recorder writes
/// `<id>.m4a`, so the id *is* the filename and no extra bookkeeping is needed.
enum LocalRecordings {
    struct Item: Sendable {
        var id: String
        var url: URL
        var bytes: Int
    }

    static func all() -> [Item] {
        let dir = Recorder.recordingsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "m4a" }.map {
            Item(id: $0.deletingPathExtension().lastPathComponent,
                 url: $0,
                 bytes: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    static func remove(_ item: Item) -> Bool {
        do { try FileManager.default.removeItem(at: item.url); return true }
        catch { return false }
    }
}

enum Outbox {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notables/Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// What actually goes on disk: the wire payload plus the local-only fields that
    /// `IngestPayload.CodingKeys` deliberately drops. `CodingKeys` governs decoding as
    /// well as encoding, so a path left to the synthesized coder comes back nil and the
    /// audio upload is skipped — silently, which is how a whole lecture went text-only.
    private struct Record: Codable {
        var payload: NotesClient.IngestPayload
        var localAudioPath: String?
    }

    static func save(_ p: NotesClient.IngestPayload) {
        let record = Record(payload: p, localAudioPath: p.localAudioPath)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: dir.appendingPathComponent("\(p.id).json"), options: .atomic)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    static func pending() -> [NotesClient.IngestPayload] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let d = try? Data(contentsOf: $0),
                  let record = try? JSONDecoder().decode(Record.self, from: d) else { return nil }
            var payload = record.payload
            payload.localAudioPath = record.localAudioPath
            return payload
        }
    }
}
