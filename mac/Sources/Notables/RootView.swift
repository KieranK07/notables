import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var showRecorder = false
    @State private var materialSelection: MaterialSelection?
    @State private var confirmFullSync = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, showRecorder: $showRecorder)
                .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 300)
        } content: {
            MiddleColumn(model: model, materialSelection: $materialSelection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
        } detail: {
            detail
                .frame(minWidth: 420)
                .background(Theme.surface)
        }
        .onAppear { model.onAppear() }
        .sheet(isPresented: $showRecorder) {
            RecordingView(model: model, recorder: model.recorder)
        }
        .confirmationDialog("Re-pull everything from Canvas?",
                            isPresented: $confirmFullSync, titleVisibility: .visible) {
            Button("Re-pull everything") { Task { await model.syncCanvas(full: true) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Widens the sync to every enrolled course, including finished terms, and "
                 + "re-downloads and re-reads files even when Canvas says they haven't "
                 + "changed. Each course's glossary is rebuilt afterwards. Expect several "
                 + "minutes and a few hundred MB. The routine sync every 6 hours only "
                 + "picks up what is new.")
        }
        .toolbar {
            if model.selection == .materials {
                ToolbarItem {
                    // Split button: the common case stays one click, and the expensive
                    // one is behind the chevron where it cannot be hit by accident.
                    Menu {
                        Button("Sync new files") { Task { await model.syncCanvas() } }
                        Divider()
                        Button("Re-pull everything…") { confirmFullSync = true }
                    } label: {
                        Label("Sync Canvas", systemImage: "arrow.triangle.2.circlepath")
                    } primaryAction: {
                        Task { await model.syncCanvas() }
                    }
                    .disabled(model.canvasSyncing || model.canvas?.hasSession != true)
                    .help("Pull new files from each course's Canvas modules")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showRecorder = true } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Record a class (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search notes")
        .tint(Theme.accent)
        .background(Theme.canvas)
    }

    /// The wide pane. Every view puts something real here; a void is a wasted pane.
    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .calendar:
            CalendarDayView(model: model)
        case .todos:
            DeadlineDetail(model: model)
        case .materials:
            if let sel = materialSelection {
                MaterialDetailView(selection: sel)
            } else {
                EmptyState(icon: "books.vertical", title: "Course Materials")
            }
        default:
            DetailColumn(model: model)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var showRecorder: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showRecorder = true
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Circle().fill(Theme.recordRed).frame(width: 8, height: 8)
                    Text("Record Class").font(Theme.Font.headline)
                    Spacer()
                }
                .padding(.vertical, 8).padding(.horizontal, Theme.Space.m)
                .frame(maxWidth: .infinity)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
                .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            List(selection: Binding(
                get: { model.selection },
                set: { if let v = $0 { model.selection = v } })) {

                Section {
                    SidebarRow(icon: "doc.text", title: "All Notes",
                               count: model.notes.count, selected: model.selection == .allNotes)
                        .tag(AppModel.Selection.allNotes)
                    SidebarRow(icon: "checklist", title: "Deadlines",
                               count: model.openTodos.count, selected: model.selection == .todos)
                        .tag(AppModel.Selection.todos)
                    SidebarRow(icon: "calendar", title: "Calendar",
                               selected: model.selection == .calendar)
                        .tag(AppModel.Selection.calendar)
                    SidebarRow(icon: "books.vertical", title: "Course Materials",
                               count: model.materials.reduce(0) { $0 + $1.fileCount },
                               selected: model.selection == .materials)
                        .tag(AppModel.Selection.materials)
                }

                Section {
                    ForEach(model.courses) { course in
                        SidebarRow(dot: course.name, title: course.name,
                                   count: course.noteCount,
                                   selected: model.selection == .course(course.name))
                            .tag(AppModel.Selection.course(course.name))
                    }
                    if model.courses.isEmpty {
                        Text("No courses yet").font(Theme.Font.body).foregroundStyle(Theme.inkFaint)
                    }
                } header: {
                    Text("Courses").sectionLabel()
                }
            }
            .listStyle(.sidebar)

            if model.canvasNeedsReconnect {
                Divider().overlay(Theme.hairline)
                CanvasReconnectBanner()
            }
            Divider().overlay(Theme.hairline)
            ConnectionFooter(model: model)
        }
    }
}

/// One sidebar entry. Draws its own selection so it stays in the palette.
struct SidebarRow: View {
    var icon: String? = nil
    var dot: String? = nil
    let title: String
    var count: Int = 0
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.inkMuted)
                } else if let dot {
                    CourseDot(course: dot)
                }
            }
            .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(Theme.Font.caption).monospacedDigit()
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.vertical, 2)
        .quietRowSelection(selected, inset: 10)
    }
}

struct ConnectionFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .help(detailText)
            Spacer()
            if model.pendingUploads > 0 {
                Pill(text: "\(model.pendingUploads) queued", color: Theme.soon)
                    .help("Recordings saved on this Mac, waiting for the PC.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var color: Color {
        switch model.connection {
        case .online: return Theme.accent
        case .connecting: return Theme.soon
        case .offline: return Theme.overdue
        }
    }
    private var label: String {
        switch model.connection {
        case .online: return "Synced with PC"
        case .connecting: return "Connecting…"
        case .offline: return "PC offline"
        }
    }
    private var detailText: String {
        if case .offline(let why) = model.connection { return why }
        return "Live updates over Tailscale"
    }
}

// MARK: - Middle column

struct MiddleColumn: View {
    @ObservedObject var model: AppModel
    @Binding var materialSelection: MaterialSelection?

    var body: some View {
        Group {
            if model.selection == .todos {
                TodoList(model: model)
            } else if model.selection == .calendar {
                CalendarView(model: model)
            } else if model.selection == .materials {
                MaterialsList(model: model, selected: $materialSelection)
            } else {
                NoteList(model: model)
            }
        }
        .background(Theme.canvas)
        .navigationTitle(title)
    }

    private var title: String {
        switch model.selection {
        case .allNotes: return "All Notes"
        case .todos: return "Deadlines"
        case .calendar: return "Calendar"
        case .materials: return "Course Materials"
        case .course(let c): return c
        }
    }
}

struct NoteList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let notes = model.visibleNotes
        if notes.isEmpty {
            EmptyState(icon: "waveform",
                       title: model.searchText.isEmpty ? "No notes yet" : "No matches for “\(model.searchText)”")
        } else {
            List(selection: Binding(get: { model.selectedNoteID },
                                    set: { model.select($0) })) {
                ForEach(groupedByDay(notes), id: \.0) { day, dayNotes in
                    Section {
                        ForEach(dayNotes) { note in
                            NoteRow(note: note)
                                .tag(note.id)
                                .quietRowSelection(note.id == model.selectedNoteID)
                                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(day)
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
        }
    }

    /// Notes group by the day of the class, which is what Kieran actually navigates by.
    private func groupedByDay(_ notes: [Note]) -> [(String, [Note])] {
        var order: [String] = []
        var map: [String: [Note]] = [:]
        for n in notes {
            let key = Dates.longDay(n.sortDate)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(n)
        }
        return order.map { ($0, map[$0]!) }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            CourseDot(course: note.course).padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Space.s) {
                    Text(note.title).font(Theme.Font.title).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    StateBadge(state: note.state)
                }
                if let s = note.summary, !s.isEmpty {
                    Text(s).font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
                HStack(spacing: Theme.Space.s) {
                    Text(note.course).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    if let sec = note.section, !sec.isEmpty {
                        Text("§\(sec)").font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    }
                    Text(note.displaySubtitle).font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                    if note.isDraftTranscript { Pill(text: "rough", color: Theme.soon) }
                    Spacer(minLength: 0)
                    if let n = note.actionItemCount, n > 0 {
                        Text("\(n) to do").font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}

struct StateBadge: View {
    let state: NoteState
    var body: some View {
        switch state {
        case .ready:
            EmptyView()
        case .failed:
            Pill(text: "failed", color: Theme.overdue)
        case .queued:
            Pill(text: "queued", color: Theme.inkMuted)
        case .awaitingAudio, .transcribing, .processing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(shortLabel).font(Theme.Font.micro).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    private var shortLabel: String {
        switch state {
        case .awaitingAudio: return "uploading"
        case .transcribing:  return "transcribing"
        default:             return "writing"
        }
    }
}

/// Deadlines, grouped by urgency rather than listed flat. "Late / Today / This week"
/// is the question you actually have; a wall of dates is not an answer.
struct TodoList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let groups = model.dueGroups
        if groups.isEmpty {
            EmptyState(icon: "checkmark.circle", title: "Nothing due")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.l, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(group.todos) { todo in
                                    DeadlineRow(todo: todo, model: model, selectable: true)
                                }
                            }
                        } header: {
                            HStack(spacing: Theme.Space.s) {
                                Text(group.title).sectionLabel()
                                    .foregroundStyle(group.title == "Late" ? Theme.overdue : Theme.inkFaint)
                                Text("\(group.todos.count)")
                                    .font(Theme.Font.micro).foregroundStyle(Theme.inkFaint)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, Theme.Space.xs)
                            .padding(.bottom, Theme.Space.s)
                            .background(Theme.canvas)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.m)
            }
            .background(Theme.canvas)
        }
    }
}

/// One deadline, opened from the list. The list is narrow and long names wrap there;
/// here the text has room, and the Canvas link is a button rather than a hover icon.
struct DeadlineDetail: View {
    @ObservedObject var model: AppModel

    private var todo: Todo? {
        guard let id = model.selectedTodoID else { return nil }
        return model.todos.first { $0.id == id }
    }

    var body: some View {
        if let t = todo {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let c = t.course {
                        HStack(spacing: 6) {
                            CourseDot(course: c, size: 8)
                            Text(c).font(Theme.Font.headline).foregroundStyle(Theme.courseColor(c))
                        }
                    }

                    Text(t.text)
                        .font(Theme.Font.display)
                        .foregroundStyle(t.done ? Theme.inkFaint : Theme.ink)
                        .strikethrough(t.done, color: Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if t.due != nil {
                            fact("Due") {
                                HStack(spacing: Theme.Space.s) {
                                    Text(dueLong(t)).foregroundStyle(Theme.ink)
                                    if let rel = t.dueDisplay {
                                        Text(rel).foregroundStyle(t.dueStyle.color)
                                    }
                                }
                            }
                        }
                        if let p = t.pointsDisplay {
                            fact("Points") { Text(p).foregroundStyle(Theme.ink) }
                        }
                        fact("From") {
                            if let n = sourceNote(t) {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform").foregroundStyle(Theme.accent)
                                    Text(n.title).foregroundStyle(Theme.ink)
                                    Text(DateFormatter.friendly.string(from: n.sortDate))
                                        .foregroundStyle(Theme.inkFaint)
                                }
                            } else if t.isAssignment {
                                Text("Canvas").foregroundStyle(Theme.ink)
                            } else {
                                Text("Lecture").foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    .font(Theme.Font.body)
                    .padding(.top, Theme.Space.xs)

                    HStack(spacing: Theme.Space.s) {
                        Button(t.done ? "Mark as not done" : "Mark as done") {
                            model.setTodoDone(t, !t.done)
                        }
                        if let u = t.url, let url = URL(string: u) {
                            Link("Open in Canvas", destination: url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, Theme.Space.m)
                }
                .padding(Theme.Space.xxl)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surface)
        } else {
            EmptyState(icon: "checklist", title: "Deadlines")
        }
    }

    private func fact<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(label).sectionLabel().frame(width: 52, alignment: .leading)
            value()
        }
    }

    private func dueLong(_ t: Todo) -> String {
        var s = Dates.longDay(t.due ?? "")
        if let time = t.dueTime { s += " · \(time)" }
        return s
    }

    /// The class this came out of, when it did.
    private func sourceNote(_ t: Todo) -> Note? {
        guard let src = t.source, src.hasPrefix("note:") else { return nil }
        let id = String(src.dropFirst(5))
        return model.notes.first { $0.id == id }
    }
}

/// A quiet pane. A glyph and a fixed name; no copy telling you what to do.
struct EmptyState: View {
    let icon: String, title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: icon).font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.inkFaint.opacity(0.6))
            Text(title).font(Theme.Font.headline).foregroundStyle(Theme.inkFaint)
            if let message, !message.isEmpty {
                Text(message).font(Theme.Font.body).foregroundStyle(Theme.inkFaint)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }
}
