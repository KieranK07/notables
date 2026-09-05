import SwiftUI

struct DetailColumn: View {
    @ObservedObject var model: AppModel
    @State private var showTranscript = false

    private var note: Note? {
        guard let id = model.selectedNoteID else { return nil }
        return model.notes.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let note {
                content(note)
            } else {
                EmptyState(icon: "doc.text", title: "No note selected")
            }
        }
        .frame(minWidth: 420)
        .background(Theme.surface)
    }

    @ViewBuilder
    private func content(_ note: Note) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(note)

                if note.state == .failed {
                    failureBanner(note)
                } else if note.state != .ready {
                    processingBanner(note)
                } else if note.isDraftTranscript {
                    draftFallbackBanner(note)
                }

                if showTranscript {
                    transcriptSection
                } else if let md = model.detail?.markdown, !md.isEmpty {
                    // The header above already carries the title and the meta line.
                    MarkdownView(markdown: stripFrontMatter(md), dropLeadingTitle: true)
                        .padding(.top, Theme.Space.s)
                } else if model.loadingDetail {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(Theme.Font.body).foregroundStyle(Theme.inkFaint)
                    }
                    .padding(.top, Theme.Space.xl)
                } else if note.state == .ready {
                    Text("No body yet").font(Theme.Font.body).foregroundStyle(Theme.inkFaint)
                        .padding(.top, Theme.Space.xl)
                } else if let draft = model.detail?.transcript, !draft.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Live draft from this Mac").sectionLabel()
                        Text(draft).font(Theme.Font.reading).lineSpacing(5)
                            .foregroundStyle(Theme.inkMuted).textSelection(.enabled)
                    }
                    .padding(.top, Theme.Space.m)
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(note.id)
        .toolbar {
            ToolbarItemGroup {
                Picker("", selection: $showTranscript) {
                    Text("Notes").tag(false)
                    Text("Transcript").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 168)

                Menu {
                    Button("Re-run notes pass") { model.reprocess(note.id) }
                    if let p = note.notePath {
                        Button("Copy vault path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(p, forType: .string)
                        }
                    }
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.detail?.transcript ?? "", forType: .string)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func header(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                CourseDot(course: note.course, size: 8)
                Text(note.course)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.courseColor(note.course))
                if let s = note.section, !s.isEmpty { Pill(text: "§\(s)", color: Theme.accent) }
            }

            Text(note.title)
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let topic = note.topic, !topic.isEmpty, topic != note.title {
                Text(topic)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.s) {
                Text(Dates.longDay(note.sortDate))
                if let d = note.durationSec, d > 0 {
                    Text("·")
                    Text(Dates.minutes(d))
                }
                if note.isDraftTranscript { Pill(text: "rough", color: Theme.soon) }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.inkFaint)
            .padding(.top, 2)

            if !note.tags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(note.tags, id: \.self) { Pill(text: $0, color: Theme.inkFaint) }
                }
                .padding(.top, Theme.Space.xs)
            }

            Divider().overlay(Theme.hairline).padding(.top, Theme.Space.m)
        }
        .padding(.bottom, Theme.Space.m)
    }

    // MARK: Banners — state the user is waiting on, said once and quietly.

    private func banner<Trailing: View>(icon: String, tint: Color, title: String, detail: String? = nil,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
        .cardStyle(padding: Theme.Space.m)
        .padding(.bottom, Theme.Space.l)
    }

    private func processingBanner(_ note: Note) -> some View {
        banner(icon: "clock", tint: Theme.soon, title: note.state.progressLabel) {
            ProgressView().controlSize(.small)
        }
    }

    private func failureBanner(_ note: Note) -> some View {
        banner(icon: "arrow.counterclockwise", tint: Theme.overdue,
               title: "The notes pass failed",
               detail: "The transcript is saved on the PC and on this Mac.") {
            Button("Retry") { model.reprocess(note.id) }
        }
    }

    /// Whisper failed and the server fell back to this Mac's rough pass. That is the right
    /// behaviour — better a rough note than none — but it must never pass for the real thing.
    private func draftFallbackBanner(_ note: Note) -> some View {
        banner(icon: "waveform", tint: Theme.soon,
               title: "Rough transcript",
               detail: "Written from this Mac's live pass; the PC's transcription didn't run.") {
            Button("Redo on PC") { model.reprocess(note.id) }
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let t = model.detail?.transcript, !t.isEmpty {
            Text(t)
                .font(Theme.Font.reading)
                .foregroundStyle(Theme.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Space.s)
        } else if model.loadingDetail {
            ProgressView().controlSize(.small).padding(.top, Theme.Space.xl)
        } else {
            Text("No transcript stored").font(Theme.Font.body).foregroundStyle(Theme.inkFaint)
                .padding(.top, Theme.Space.xl)
        }
    }

    /// The server writes YAML front-matter; the header above already shows that metadata.
    private func stripFrontMatter(_ md: String) -> String {
        guard md.hasPrefix("---") else { return md }
        let lines = md.components(separatedBy: .newlines)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return md }
        return lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
