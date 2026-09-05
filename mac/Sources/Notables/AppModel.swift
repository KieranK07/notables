import Foundation
import SwiftUI

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
    private let client = NotesClient()
    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?

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
        eventTask = Task { await self.listen() }
        outboxTask = Task { await self.drainOutboxLoop() }
        Task { await refresh() }
        Task { await self.warmUpSpeechModel() }
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
        Outbox.save(payload)
        pendingUploads = Outbox.pending().count
        recordingTitle = ""
        await drainOutbox()
    }

    private func defaultTitle() -> String {
        "Class \(DateFormatter.friendly.string(from: Date()))"
    }

    func cancelRecording() async {
        await recorder.cancel()
        currentRecordingID = nil
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
                // real until these bytes land.
                if let path = payload.localAudioPath {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) {
                        uploadingID = payload.id
                        defer { uploadingID = nil }
                        try await client.uploadAudio(id: payload.id, from: url)
                    } else {
                        banner = "Audio for “\(payload.title)” is missing — sent the draft transcript only."
                    }
                }
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
enum Outbox {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notables/Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func save(_ p: NotesClient.IngestPayload) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: dir.appendingPathComponent("\(p.id).json"), options: .atomic)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    static func pending() -> [NotesClient.IngestPayload] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let d = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(NotesClient.IngestPayload.self, from: d)
        }
    }
}
