import SwiftUI

/// The focused recording panel: title field, live level meter, timer, and the
/// transcript appearing as it's spoken so you can see it's actually working.
struct RecordingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            transcriptArea
            Divider().overlay(Theme.hairline)
            controls
        }
        .frame(width: 620, height: 560)
        .background(Theme.surface)
        .onAppear { titleFocused = recorder.state == .idle }
    }

    private var header: some View {
        VStack(spacing: 16) {
            TextField("Class name", text: $model.recordingTitle)
                .textFieldStyle(.plain)
                .font(Theme.Font.display)
                .foregroundStyle(Theme.ink)
                .focused($titleFocused)
                .disabled(recorder.state == .finishing)

            LevelMeter(levels: recorder.levels, active: recorder.state == .recording)
                .frame(height: 52)

            if showSilenceWarning { silenceWarning }

            HStack(spacing: 10) {
                if recorder.state == .recording {
                    Circle().fill(Theme.recordRed).frame(width: 9, height: 9)
                        .opacity(pulse ? 1 : 0.25)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }
                Text(formatDuration(recorder.elapsed))
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(recorder.state == .recording ? Theme.ink : Theme.inkFaint)
                    .contentTransition(.numericText())
                Spacer()
                if recorder.state == .recording {
                    // Naming the device is the cheapest guard against the failure that
                    // costs a whole lecture: the system default input being something
                    // that is not in the room.
                    Label(recorder.inputDeviceName ?? "Transcribing on-device",
                          systemImage: "waveform.badge.mic")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(20)
    }

    @State private var pulse = false

    private var showSilenceWarning: Bool {
        recorder.state == .recording && recorder.silentFor >= Recorder.silenceWarningAfter
    }

    /// A dead input is not a subtle problem and does not get a subtle banner: 72 minutes of
    /// digital silence once sailed through recording, upload and transcription without a
    /// single thing on screen looking wrong.
    private var silenceWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.recordRed)
            VStack(alignment: .leading, spacing: 3) {
                Text(recorder.heardSignal
                     ? "No sound for \(Int(recorder.silentFor))s"
                     : "No sound is reaching Notables")
                    .font(Theme.Font.headline).foregroundStyle(Theme.ink)
                Text("\(recorder.inputDeviceName ?? "The input device") is sending silence. "
                     + "Check System Settings › Sound › Input — this class is not being recorded.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.recordRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.recordRed.opacity(0.35)))
    }

    /// Committed text reads solid; the phrase still being revised is dimmed.
    private var liveTranscript: AttributedString {
        var out = AttributedString(recorder.finalText)
        out.foregroundColor = Theme.ink
        if !recorder.volatileText.isEmpty {
            var pending = AttributedString(" " + recorder.volatileText)
            pending.foregroundColor = Theme.inkFaint
            out.append(pending)
        }
        return out
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if recorder.transcriptSoFar.isEmpty {
                        VStack(spacing: Theme.Space.m) {
                            Image(systemName: "waveform")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(Theme.inkFaint.opacity(0.6))
                            if recorder.state == .recording {
                                // "Listening…" over a dead microphone is exactly the
                                // reassurance that let a silent lecture run to the end.
                                Text(showSilenceWarning ? "Hearing nothing" : "Listening…")
                                    .font(Theme.Font.headline)
                                    .foregroundStyle(showSilenceWarning ? Theme.recordRed : Theme.inkFaint)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 70)
                    } else {
                        Text(liveTranscript)
                            .font(Theme.Font.reading)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("transcript")
                    }
                }
                .padding(20)
            }
            .onChange(of: recorder.volatileText) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.state == .recording {
                Button(role: .destructive) {
                    Task { await model.cancelRecording(); dismiss() }
                } label: { Text("Discard").frame(width: 78) }
                .controlSize(.large)
            } else {
                Button("Close") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if let err = recorder.error {
                Text(err).font(Theme.Font.caption).foregroundStyle(Theme.overdue)
                    .lineLimit(2).frame(maxWidth: 280, alignment: .trailing)
            }

            Button {
                Task {
                    if recorder.state == .recording {
                        await model.stopRecordingAndSend()
                        dismiss()
                    } else {
                        await model.startRecording()
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: recorder.state == .recording
                          ? "stop.circle.fill" : "record.circle.fill")
                        .font(.system(size: 15))
                    Text(recorder.state == .recording ? "Stop & File Note"
                         : recorder.state == .preparing ? "Starting…" : "Record")
                        .fontWeight(.medium)
                }
                .frame(minWidth: 128)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(recorder.state == .recording ? Theme.recordRed : Theme.accent)
            .disabled(recorder.state == .preparing || recorder.state == .finishing)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

/// Scrolling bar meter driven by the mic's RMS level.
struct LevelMeter: View {
    let levels: [Float]
    let active: Bool

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int(geo.size.width / (barWidth + spacing)))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    bar(value: value(at: i, of: count), height: geo.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func bar(value: CGFloat, height: CGFloat) -> some View {
        let fill: Color = active
            ? Theme.recordRed.opacity(0.35 + 0.65 * value)
            : Theme.inkFaint.opacity(0.22)
        return Capsule()
            .fill(fill)
            .frame(width: barWidth, height: max(3, value * height))
    }

    /// Right-aligns the history so the newest sample is always at the leading edge of the tail.
    private func value(at index: Int, of count: Int) -> CGFloat {
        let shown = levels.suffix(count)
        let offset = index - (count - shown.count)
        guard offset >= 0, offset < shown.count else { return 0 }
        return CGFloat(Array(shown)[offset])
    }
}
