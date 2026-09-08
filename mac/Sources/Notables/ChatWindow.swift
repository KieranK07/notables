import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A Claude conversation scoped to one course, chapter, or file.
///
/// The conversation itself belongs to the `claude` CLI on the PC — this only holds what
/// is needed to draw it. Sessions are resumable because the CLI's own `--resume` is doing
/// the work; the id is minted here so a photo can be attached before the first turn has
/// created anything to attach it to.
@MainActor
final class ChatModel: ObservableObject {
    struct Msg: Identifiable {
        let id = UUID()
        var role: String            // user | assistant
        var text: String
        var attachments: [String] = []
        var failed = false
    }

    struct Staged: Identifiable {
        let id = UUID()
        var name: String
        var data: Data
        var image: NSImage?
    }

    @Published var messages: [Msg] = []
    @Published var draft = ""
    @Published var staged: [Staged] = []
    @Published var streaming = false
    /// "Reading policies.pdf.txt" — what Claude is doing while nothing is printing yet.
    @Published var activity: String?
    @Published var error: String?
    @Published var sessions: [NotesClient.ChatSession] = []
    @Published var sessionId: String?
    @Published var modelName = "claude-sonnet-5"

    let scope: NotesClient.ChatScope
    private let client = NotesClient()
    private var turn: Task<Void, Never>?

    init(scope: NotesClient.ChatScope) {
        self.scope = scope
    }

    var canSend: Bool {
        !streaming && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty)
    }

    // MARK: - Sessions

    func loadSessions() async {
        sessions = (try? await client.chatSessions(scope: scope)) ?? []
    }

    func startNew() {
        turn?.cancel()
        streaming = false
        activity = nil
        error = nil
        messages = []
        sessionId = nil
    }

    func resume(_ id: String) async {
        turn?.cancel()
        streaming = false
        activity = nil
        error = nil
        sessionId = id
        do {
            let t = try await client.chatTranscript(id: id)
            messages = t.messages.map {
                Msg(role: $0.role, text: $0.text, attachments: $0.attachments ?? [])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ id: String) async {
        try? await client.deleteChatSession(id: id)
        if sessionId == id { startNew() }
        await loadSessions()
    }

    // MARK: - Attachments

    func stage(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        staged.append(Staged(name: url.lastPathComponent, data: data, image: NSImage(contentsOf: url)))
    }

    func stage(image: NSImage, name: String = "pasted.png") {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        staged.append(Staged(name: name, data: png, image: image))
    }

    func unstage(_ id: UUID) { staged.removeAll { $0.id == id } }

    // MARK: - Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streaming, !text.isEmpty || !staged.isEmpty else { return }

        // Mint the id up front so attachments have somewhere to live.
        let id = sessionId ?? UUID().uuidString.lowercased()
        sessionId = id
        let files = staged

        draft = ""
        staged = []
        error = nil
        messages.append(Msg(role: "user", text: text, attachments: files.map(\.name)))
        messages.append(Msg(role: "assistant", text: ""))
        streaming = true
        activity = "Thinking…"

        turn = Task { [weak self] in
            guard let self else { return }
            var paths: [String] = []
            do {
                for f in files {
                    paths.append(try await self.client.uploadChatAttachment(
                        sessionId: id, name: f.name, data: f.data))
                }
            } catch {
                self.finish(with: "Couldn't send the attachment: \(error.localizedDescription)")
                return
            }

            do {
                for try await event in self.client.chatStream(scope: self.scope, sessionId: id,
                                                              text: text, attachments: paths) {
                    if Task.isCancelled { return }
                    switch event {
                    case .started(let model, _):
                        if !model.isEmpty { self.modelName = model }
                    case .delta(let chunk):
                        self.activity = nil
                        self.appendToLast(chunk)
                    case .tool(let name, let detail):
                        self.activity = detail.isEmpty ? "\(name)…" : "\(Self.verb(name)) \(detail)"
                    case .done(let sid, let final, _):
                        if !sid.isEmpty { self.sessionId = sid }
                        // The stream is authoritative; this only repairs a turn whose
                        // deltas never arrived.
                        if self.lastText.isEmpty, !final.isEmpty { self.setLast(final) }
                        self.finish(with: nil)
                        await self.loadSessions()
                    case .failed(let why):
                        self.finish(with: why)
                    }
                }
                if self.streaming { self.finish(with: nil) }
            } catch is CancellationError {
                return
            } catch {
                self.finish(with: error.localizedDescription)
            }
        }
    }

    func stop() {
        turn?.cancel()
        turn = nil
        finish(with: nil)
    }

    private static func verb(_ tool: String) -> String {
        switch tool {
        case "Read", "NotebookRead": return "Reading"
        case "Grep":                 return "Searching"
        case "Glob":                 return "Looking through"
        case "WebSearch":            return "Searching the web for"
        case "WebFetch":             return "Fetching"
        default:                     return tool
        }
    }

    private var lastText: String { messages.last?.text ?? "" }

    private func appendToLast(_ chunk: String) {
        guard let i = messages.indices.last else { return }
        messages[i].text += chunk
    }

    private func setLast(_ text: String) {
        guard let i = messages.indices.last else { return }
        messages[i].text = text
    }

    private func finish(with problem: String?) {
        streaming = false
        activity = nil
        if let problem {
            error = problem
            if let i = messages.indices.last, messages[i].role == "assistant", messages[i].text.isEmpty {
                messages[i].failed = true
                messages[i].text = problem
            }
        } else if let i = messages.indices.last, messages[i].role == "assistant",
                  messages[i].text.isEmpty {
            messages.remove(at: i)
        }
    }
}

// MARK: - Window

struct ChatWindow: View {
    @StateObject private var model: ChatModel
    @FocusState private var composerFocused: Bool

    init(scope: NotesClient.ChatScope) {
        _model = StateObject(wrappedValue: ChatModel(scope: scope))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            transcript
            Divider().overlay(Theme.hairline)
            composer
        }
        .background(Theme.surface)
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await model.loadSessions()
            composerFocused = true
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.stage(url) }
                }
            }
            return true
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: NSImage.self) {
                    _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                        guard let img = img as? NSImage else { return }
                        Task { @MainActor in model.stage(image: img) }
                    }
                } else {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in model.stage(url) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.scope.label).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.inkFaint).lineLimit(1)
            }
            Spacer()

            Menu {
                Button("New conversation") { model.startNew() }
                if !model.sessions.isEmpty {
                    Divider()
                    Section("Resume") {
                        ForEach(model.sessions) { s in
                            Button {
                                Task { await model.resume(s.id) }
                            } label: {
                                Text(s.id == model.sessionId ? "✓ \(s.title)" : s.title)
                            }
                        }
                    }
                    if let current = model.sessionId {
                        Divider()
                        Button("Delete this conversation", role: .destructive) {
                            Task { await model.delete(current) }
                        }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Resume an earlier conversation")
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .background(Theme.sunken)
    }

    private var icon: String {
        switch model.scope.kind {
        case "file":   return "doc.text"
        case "module": return "folder"
        default:       return "books.vertical"
        }
    }

    private var subtitle: String {
        let what: String
        switch model.scope.kind {
        case "file":   return "\(model.scope.course) · \(model.modelName)"
        case "module": what = "chapter"
        default:       what = "whole course"
        }
        return "\(what) · \(model.modelName)"
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                    if model.messages.isEmpty { emptyState }
                    ForEach(model.messages) { m in
                        bubble(m).id(m.id)
                    }
                    if let a = model.activity {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text(a).font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                        }
                        .id("activity")
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                if let last = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Ask about \(model.scope.label)")
                .font(Theme.Font.headline).foregroundStyle(Theme.ink)
            Text("Claude can read every file in this \(model.scope.kind == "file" ? "file's folder" : model.scope.kind) "
                 + "on the PC — the PDFs' extracted text included — and will cite what it used. "
                 + "Drop in a photo of a problem and it will read that too.")
                .font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Space.s)
    }

    @ViewBuilder
    private func bubble(_ m: ChatModel.Msg) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.role == "user" ? "You" : "Claude")
                .font(Theme.Font.micro)
                .foregroundStyle(m.role == "user" ? Theme.inkFaint : Theme.accent)

            if !m.attachments.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(m.attachments, id: \.self) { Pill(text: $0, color: Theme.inkFaint) }
                }
            }

            if m.role == "user" {
                Text(m.text)
                    .font(Theme.Font.reading).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if m.failed {
                Text(m.text)
                    .font(Theme.Font.body).foregroundStyle(Theme.overdue)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownView(markdown: m.text)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let e = model.error, !model.streaming {
                Text(e).font(Theme.Font.caption).foregroundStyle(Theme.overdue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.staged.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(model.staged) { s in
                            HStack(spacing: 5) {
                                if let img = s.image {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 3))
                                } else {
                                    Image(systemName: "doc").font(.system(size: 10))
                                }
                                Text(s.name).font(Theme.Font.caption).lineLimit(1)
                                Button { model.unstage(s.id) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                }
                                .buttonStyle(.borderless).foregroundStyle(Theme.inkFaint)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                        }
                    }
                }
                .frame(height: 30)
            }

            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                Button { pickFiles() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).help("Attach a photo or file")

                TextEditor(text: $model.draft)
                    .font(Theme.Font.reading)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 34, maxHeight: 120)
                    .focused($composerFocused)
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("Ask about \(model.scope.label)…")
                                .font(Theme.Font.reading).foregroundStyle(Theme.inkFaint)
                                .padding(.top, 1).allowsHitTesting(false)
                        }
                    }

                if model.streaming {
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless).help("Stop")
                } else {
                    Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.borderless)
                        .disabled(!model.canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.sunken)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach(model.stage) }
    }
}
