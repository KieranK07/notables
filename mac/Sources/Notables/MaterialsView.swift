import SwiftUI

/// Course materials pulled from Canvas: what was found, what was readable, and —
/// just as important — what was not. A silent gap is the failure mode this whole
/// project keeps designing against, so anything Canvas has but we could not read
/// is shown, not hidden.
struct MaterialsList: View {
    @ObservedObject var model: AppModel
    @Binding var selected: MaterialSelection?

    var body: some View {
        VStack(spacing: 0) {
            if model.canvasNeedsReconnect { CanvasReconnectBanner() }
            if model.canvasSyncing { syncingStrip }

            if model.materials.isEmpty {
                emptyState
            } else {
                List(selection: Binding(
                    get: { selected },
                    set: { if let v = $0 { selected = v } })) {
                    ForEach(model.materials) { course in
                        Section {
                            CourseMaterialsSection(model: model, course: course, selected: $selected)
                        } header: {
                            HStack(spacing: 7) {
                                CourseDot(course: course.course)
                                Text(course.course)
                                    .font(Theme.Font.headline).foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(course.fileCount) files")
                                    .font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                                AskClaudeButton(scope: .course(course.course), compact: true)
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Theme.inkFaint)
                            }
                            .contextMenu {
                                AskClaudeButton(scope: .course(course.course),
                                                title: "Ask Claude about this course")
                            }
                            .listSectionSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.canvas)
        .task { await model.refreshCanvas() }
    }

    private var syncingStrip: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text(model.canvasProgress ?? "Syncing Canvas…")
                .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
        .background(Theme.sunken)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "books.vertical")
                .font(.system(size: 28, weight: .light)).foregroundStyle(Theme.inkFaint.opacity(0.6))
            Text(model.canvas?.hasSession == true ? "Nothing synced yet" : "Canvas not connected")
                .font(Theme.Font.headline).foregroundStyle(Theme.inkFaint)
            if model.canvas?.hasSession == true {
                Button("Sync now") { Task { await model.syncCanvas() } }
                    .buttonStyle(.bordered)
            } else {
                OpenCanvasButton().buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CourseMaterialsSection: View {
    @ObservedObject var model: AppModel
    let course: NotesClient.MaterialsSummary
    @Binding var selected: MaterialSelection?

    @State private var detail: NotesClient.CourseMaterials?
    @State private var failed: String?

    var body: some View {
        Group {
            if let detail, detail.byModule.isEmpty, (detail.links ?? []).isEmpty {
                Text("No files").font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                    .listRowSeparator(.hidden)
            } else if let detail {
                ForEach(detail.byModule, id: \.module) { group in
                    DisclosureGroup {
                        ForEach(group.files) { file in
                            let sel = MaterialSelection(course: course.course, file: file,
                                                        canvasCourseId: detail.canvasCourseId)
                            MaterialRow(file: file)
                                .contextMenu {
                                    AskClaudeButton(scope: .file(file.id, named: file.name,
                                                                 in: course.course),
                                                    title: "Ask Claude about this file")
                                }
                                .tag(sel)
                                .quietRowSelection(selected == sel, inset: 4)
                                .listRowSeparator(.hidden)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.module).font(Theme.Font.body).foregroundStyle(Theme.ink)
                            Spacer()
                            AskClaudeButton(scope: .module(group.module, in: course.course), compact: true)
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.inkFaint)
                        }
                        .contextMenu {
                            AskClaudeButton(scope: .module(group.module, in: course.course),
                                            title: "Ask Claude about this chapter")
                        }
                    }
                    .listRowSeparator(.hidden)
                    .onChange(of: selected) { _, sel in
                        // Opening one file usually means opening its neighbours next.
                        guard let sel, sel.course == course.course,
                              group.files.contains(where: { $0.id == sel.fileID }) else { return }
                        let rest = group.files.filter { $0.id != sel.fileID }
                        Task.detached(priority: .background) {
                            await MaterialPrefetcher.shared.prefetch(course: sel.course, files: rest)
                        }
                    }
                }
                if let links = detail.links, !links.isEmpty {
                    DisclosureGroup {
                        ForEach(links, id: \.url) { l in
                            Link(destination: URL(string: l.url) ?? URL(string: "https://canvas.instructure.com")!) {
                                Label(l.title, systemImage: "arrow.up.forward.square")
                                    .font(Theme.Font.body)
                            }
                            .listRowSeparator(.hidden)
                        }
                    } label: {
                        Text("External links").font(Theme.Font.body).foregroundStyle(Theme.ink)
                    }
                    .listRowSeparator(.hidden)
                }
            } else if course.fileCount == 0 {
                Text("No files").font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                    .listRowSeparator(.hidden)
            } else if let failed {
                Text(failed).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    .listRowSeparator(.hidden)
            } else {
                ProgressView().controlSize(.small).listRowSeparator(.hidden)
            }
        }
        .task(id: course.syncedAt) {
            do { detail = try await NotesClient().fetchCourseMaterials(course.course) }
            catch { failed = "Couldn't load: \(error.localizedDescription)" }
        }
    }
}

struct MaterialRow: View {
    let file: NotesClient.MaterialFile

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(file.hasText ? Theme.accent : Theme.inkFaint)
                .frame(width: 15)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(Theme.Font.body).foregroundStyle(Theme.ink).lineLimit(2)
                HStack(spacing: 6) {
                    if let size = file.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let gap = file.gapReason {
                        Text(gap).foregroundStyle(Theme.overdue)
                    } else if let chars = file.extract?.chars {
                        Text("\(chars.formatted()) chars")
                        if file.isOCR {
                            Pill(text: "OCR", color: Theme.soon)
                                .help("Read by OCR — this file had no text layer, so expect occasional recognition errors")
                        }
                    }
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        let n = file.name.lowercased()
        if n.hasSuffix(".pdf") { return "doc.richtext" }
        if n.hasSuffix(".pptx") || n.hasSuffix(".ppt") { return "rectangle.on.rectangle" }
        if n.hasSuffix(".docx") || n.hasSuffix(".doc") { return "doc.text" }
        if n.hasSuffix(".xlsx") || n.hasSuffix(".csv") { return "tablecells" }
        return "doc"
    }
}

/// Carries the file metadata the list already holds.
///
/// The detail view used to re-fetch this from the server before it could start
/// downloading anything — a round trip of pure latency on a link that relays through
/// Chicago. The list has the metadata; hand it over.
struct MaterialSelection: Hashable, Identifiable {
    let course: String
    let file: NotesClient.MaterialFile
    let canvasCourseId: String?

    var fileID: String { file.id }
    var id: String { course + "/" + file.id }

    static func == (a: MaterialSelection, b: MaterialSelection) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Downloads files the user is likely to open next, so clicking through a module
/// does not pay the transfer cost each time. Bounded on purpose: this is a metered,
/// relayed link, not a LAN.
actor MaterialPrefetcher {
    static let shared = MaterialPrefetcher()
    private var inFlight: Set<String> = []
    private static let maxBytes = 8 * 1024 * 1024
    private static let maxFiles = 3

    func prefetch(course: String, files: [NotesClient.MaterialFile]) async {
        var done = 0
        for f in files where done < Self.maxFiles {
            if (f.size ?? 0) > Self.maxBytes { continue }
            let key = course + "/" + f.id
            if inFlight.contains(key) { continue }
            inFlight.insert(key)
            done += 1
            _ = try? await NotesClient().materialFileURL(course: course, file: f)
            inFlight.remove(key)
        }
    }
}

/// One course file: the document itself, or the text pulled out of it.
struct MaterialDetailView: View {
    let selection: MaterialSelection

    enum Mode: String, CaseIterable { case document = "Document", text = "Text" }
    @State private var mode: Mode = .document

    @State private var localURL: URL?
    @State private var text: String?
    @State private var error: String?
    @State private var loadingText = true
    @State private var loadingFile = false
    @State private var fileError: String?

    private var file: NotesClient.MaterialFile { selection.file }
    private var isOCR: Bool { file.isOCR }
    private var canvasURL: URL? {
        guard let cid = selection.canvasCourseId else { return nil }
        return URL(string: "https://\(CanvasConnect.defaultHost)/courses/\(cid)/files/\(file.id)")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            switch mode {
            case .document: documentPane
            case .text:     textPane
            }
        }
        .background(Theme.surface)
        // ONE task, keyed on the selection. Two independent tasks plus an early
        // "already loaded" return is what made the first file viewed the only file
        // viewable: the second selection saw stale state and bailed.
        .task(id: selection) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(Theme.Font.headline).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.inkFaint).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 168)
            .onChange(of: mode) { _, m in
                // Extracted text is fetched only when it is actually asked for. It can
                // be hundreds of KB, and most of the time the document is what's wanted.
                if m == .text && text == nil && !loadingText { Task { await loadText() } }
            }

            Menu {
                AskClaudeButton(scope: .file(selection.fileID, named: selection.file.name,
                                             in: selection.course),
                                title: "Ask Claude about this file")
                Divider()
                if let localURL {
                    Button("Open in Default App") { NSWorkspace.shared.open(localURL) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([localURL])
                    }
                }
                if let canvasURL {
                    Divider()
                    Button("Open in Canvas") { NSWorkspace.shared.open(canvasURL) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).frame(width: 30)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
    }

    private var subtitle: String {
        var bits: [String] = [file.module]
        if let size = file.size {
            bits.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if isOCR { bits.append("text read by OCR") }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder private var documentPane: some View {
        if let localURL {
            FilePreview(url: localURL)
        } else if loadingFile {
            VStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Fetching from the PC…").font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "doc")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Theme.inkFaint.opacity(0.6))
                Text(fileError ?? "Couldn't load this file")
                    .font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
                Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var textPane: some View {
        if text == nil && !loadingText && error == nil {
            Color.clear.task { await loadText() }
        } else if loadingText {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text, !text.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isOCR {
                        Label("Read by OCR; expect occasional recognition errors", systemImage: "text.viewfinder")
                            .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                            .padding(.bottom, Theme.Space.m)
                    }
                    Text(text)
                        .font(Theme.Font.reading)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "doc")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Theme.inkFaint.opacity(0.6))
                Text(error ?? "No text in this file")
                    .font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Fetch the document itself. Metadata already came with the selection, so this
    /// starts moving bytes immediately — no round trip first.
    ///
    /// State is cleared up front: without that, switching files leaves the previous
    /// document on screen while the new one loads.
    private func load() async {
        text = nil
        localURL = nil
        error = nil
        fileError = nil
        loadingText = false
        loadingFile = true

        let wanted = selection
        do {
            let url = try await NotesClient().materialFileURL(course: wanted.course, file: wanted.file)
            guard wanted == selection, !Task.isCancelled else { return }
            localURL = url
        } catch {
            guard wanted == selection else { return }
            fileError = error.localizedDescription
        }
        loadingFile = false

        if mode == .text { await loadText() }
    }

    private func loadText() async {
        let wanted = selection
        loadingText = true
        defer { if wanted == selection { loadingText = false } }
        do {
            let r = try await NotesClient().fetchMaterialText(course: wanted.course, id: wanted.fileID)
            guard wanted == selection, !Task.isCancelled else { return }
            text = r.text
        } catch {
            guard wanted == selection else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Shown whenever the Canvas session has died. It has to be seen — an expired
/// session looks exactly like "no new materials" otherwise — but seen in sand, not
/// in a warning triangle.
struct CanvasReconnectBanner: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.soon)
            VStack(alignment: .leading, spacing: 1) {
                Text("Canvas needs reconnecting").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                Text("The sign-in expired, so materials stopped updating.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            OpenCanvasButton().buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .background(Theme.soon.opacity(0.12))
    }
}
