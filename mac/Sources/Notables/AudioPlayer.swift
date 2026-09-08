import SwiftUI
import AVFoundation

/// Playback for a lecture whose audio now lives only on the PC.
///
/// The Mac releases its local recording once the note is ready (see `reconcileLocalAudio`),
/// so there is nothing on this machine to open. The recording is *streamed* from
/// `GET /api/audio/{id}` rather than downloaded: the server honours Range, so playback
/// begins on the first few seconds — measured at ~3.4 s to `readyToPlay` — instead of
/// waiting out a whole 15 MB transfer. That wait is also flat, where downloading grew with
/// the length of the lecture.
///
/// It never starts on its own. Selecting a note neither connects nor plays; sound only ever
/// follows a deliberate press of play. That matters more than it sounds — these are lecture
/// recordings, and the app is often open *during* a lecture.
@MainActor
final class AudioPlayer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var noteID: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPlaying = false
    /// Waiting on the network mid-playback — the transport stays up and says so.
    @Published private(set) var buffering = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var speed: Float = 1

    static let speeds: [Float] = [1, 1.25, 1.5, 2]

    /// Set by `AppModel`; yields the URL and auth headers for a recording.
    var streamSource: (@Sendable (String) async -> (url: URL, headers: [String: String]))?

    private var player: AVPlayer?
    private var ticker: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?

    // MARK: - Loading

    /// Connect and play. The only call that makes sound, and it exists to be wired to a
    /// button — nothing calls it in response to selection or to a note arriving.
    ///
    /// `knownDuration` comes from the note itself, so the scrubber is the right length
    /// before the first byte arrives.
    func play(noteID id: String, knownDuration: Double?) {
        if noteID == id, player != nil {
            resume()
            return
        }
        teardown()
        noteID = id
        phase = .loading
        if let knownDuration, knownDuration > 0 { duration = knownDuration }

        loadTask = Task { [weak self] in
            guard let self, let streamSource = self.streamSource else { return }
            let source = await streamSource(id)
            guard !Task.isCancelled, self.noteID == id else { return }
            self.attach(url: source.url, headers: source.headers)
        }
    }

    private func attach(url: URL, headers: [String: String]) {
        // `AVURLAssetHTTPHeaderFieldsKey` is undocumented but long-stable. The documented
        // alternative is an AVAssetResourceLoaderDelegate reimplementing ranged HTTP by
        // hand — a lot of surface area to re-derive something the server already does.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        // Streaming: let AVPlayer begin the moment it has enough, rather than forcing a
        // start it cannot sustain.
        p.automaticallyWaitsToMinimizeStalling = true
        player = p

        ticker = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            let secs = t.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                if secs.isFinite { self.position = secs }
                if self.duration == 0,
                   let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
            }
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let failed = it.status == .failed
            let why = it.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, failed else { return }
                self.phase = .failed(why ?? "The recording wouldn't load.")
                self.isPlaying = false
            }
        }

        // The honest "is it actually making sound" signal: .waitingToPlayAtSpecifiedRate
        // is AVPlayer telling us it wants to play but is still filling its buffer.
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
            let waiting = pl.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let playing = pl.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.buffering = waiting
                if playing { self.isPlaying = true }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.buffering = false
                self.position = self.duration
            }
        }

        // The transport appears now, buffering, rather than after a blank wait.
        phase = .ready
        p.playImmediately(atRate: speed)
        isPlaying = true
    }

    // MARK: - Transport

    func resume() {
        guard let player else { return }
        if duration > 0, position >= duration - 0.25 { seek(to: 0) }
        player.playImmediately(atRate: speed)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        buffering = false
    }

    func toggle() { isPlaying ? pause() : resume() }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        position = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    func setSpeed(_ rate: Float) {
        speed = rate
        if isPlaying { player?.rate = rate }
    }

    /// The selection moved to another note — a lecture must not keep playing underneath a
    /// note you are no longer looking at.
    func stop() {
        teardown()
        noteID = nil
        phase = .idle
    }

    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        if let ticker { player?.removeTimeObserver(ticker) }
        ticker = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver?.invalidate(); statusObserver = nil
        rateObserver?.invalidate();   rateObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        buffering = false
        duration = 0
        position = 0
    }

    /// mm:ss, or h:mm:ss once a lecture runs past the hour.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
