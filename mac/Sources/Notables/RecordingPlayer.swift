import SwiftUI

/// The transport for a lecture recording, shown under the note header.
///
/// Collapsed to a single button until you ask for it: the audio lives on the PC now, and
/// fetching 15 MB because a note happened to be selected would be rude to both machines.
struct RecordingPlayer: View {
    @ObservedObject var player: AudioPlayer
    let note: Note

    @State private var scrub: Double?

    private var isMine: Bool { player.noteID == note.id }
    private var length: Double { player.duration > 0 ? player.duration : (note.durationSec ?? 0) }

    var body: some View {
        Group {
            if isMine {
                switch player.phase {
                case .loading:            loadingRow
                case .ready:              transport
                case .failed(let why):    failedRow(why)
                case .idle:               idleRow
                }
            } else {
                idleRow
            }
        }
        .cardStyle(padding: Theme.Space.m)
        .padding(.bottom, Theme.Space.l)
    }

    // MARK: - States

    private var idleRow: some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                player.play(noteID: note.id, knownDuration: note.durationSec)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text("Play recording")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(length > 0 ? Dates.minutes(length) : "Recording")
                    .font(Theme.Font.headline).foregroundStyle(Theme.ink)
                Text("Streams from the PC — no copy is kept on this Mac.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
        }
    }

    private var loadingRow: some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fetching from the PC…").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                Text(length > 0 ? Dates.minutes(length) : "")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            Button("Cancel") { player.stop() }
                .buttonStyle(.borderless).controlSize(.small)
        }
    }

    private func failedRow(_ why: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.overdue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't play the recording")
                    .font(Theme.Font.headline).foregroundStyle(Theme.ink)
                Text(why).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Retry") { player.play(noteID: note.id, knownDuration: note.durationSec) }
                .controlSize(.small)
        }
    }

    private var transport: some View {
        HStack(spacing: Theme.Space.m) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .background(Theme.accentSoft, in: Circle())
            .help(player.isPlaying ? "Pause" : "Play")

            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 13))
            }
            .buttonStyle(.borderless).help("Back 15 seconds")

            Button { player.skip(15) } label: {
                Image(systemName: "goforward.15").font(.system(size: 13))
            }
            .buttonStyle(.borderless).help("Forward 15 seconds")

            Text(AudioPlayer.clock(scrub ?? player.position))
                .font(Theme.Font.caption).monospacedDigit()
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 44, alignment: .trailing)

            Slider(value: progress, in: 0...max(length, 1)) { editing in
                if !editing, let s = scrub {
                    player.seek(to: s)
                    scrub = nil
                }
            }
            .controlSize(.small)

            Text(AudioPlayer.clock(length))
                .font(Theme.Font.caption).monospacedDigit()
                .foregroundStyle(Theme.inkFaint)
                .frame(width: 44, alignment: .leading)

            Menu {
                ForEach(AudioPlayer.speeds, id: \.self) { r in
                    Button {
                        player.setSpeed(r)
                    } label: {
                        if player.speed == r { Label(Self.rate(r), systemImage: "checkmark") }
                        else { Text(Self.rate(r)) }
                    }
                }
            } label: {
                Text(Self.rate(player.speed))
                    .font(Theme.Font.caption).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")
        }
    }

    // MARK: - Bits

    /// While dragging, the slider follows the finger rather than the clock.
    private var progress: Binding<Double> {
        Binding(get: { scrub ?? min(player.position, max(length, 1)) },
                set: { scrub = $0 })
    }

    private static func rate(_ r: Float) -> String {
        r == rintf(r) ? "\(Int(r))×" : String(format: "%.2f×", r).replacingOccurrences(of: "0×", with: "×")
    }
}
