import SwiftUI
import AVFoundation

/// Playback for a lecture whose audio now lives only on the PC.
///
/// The Mac releases its local recording once the note is ready (see `reconcileLocalAudio`),
/// so there is nothing on this machine to open — the file is fetched from
/// `GET /api/audio/{id}` on demand into the temp directory, and cached for a second listen.
///
/// It never starts on its own. Selecting a note neither fetches nor plays; sound only ever
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
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var speed: Float = 1

    static let speeds: [Float] = [1, 1.25, 1.5, 2]

    /// Set by `AppModel`; pulls the recording down from the PC.
    var fetch: (@Sendable (String) async throws -> URL)?

    private var player: AVPlayer?
    private var ticker: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    /// Downloaded files, by note id. A second listen should not re-cross Tailscale.
    private var cached: [String: URL] = [:]

    // MARK: - Loading

    /// Fetch if needed, then play. The only call that makes sound, and it exists to be
    /// wired to a button — nothing calls it in response to selection or a note arriving.
    ///
    /// `knownDuration` comes from the note itself, so the scrubber is the right length
    /// before a single byte has been fetched.
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
            guard let self else { return }
            do {
                let url = try await self.file(for: id)
                guard !Task.isCancelled, self.noteID == id else { return }
                self.attach(url)
                self.resume()
            } catch is CancellationError {
                return
            } catch {
                guard self.noteID == id else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    private func file(for id: String) async throws -> URL {
        if let hit = cached[id], FileManager.default.fileExists(atPath: hit.path) { return hit }
        guard let fetch else { throw NotesClient.ClientError.offline("No connection to the note server.") }
        let url = try await fetch(id)
        cached[id] = url
        return url
    }

    private func attach(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        player = p

        // `queue: .main` means these fire on the main queue, but hopping through a
        // @MainActor Task is what actually proves it to the compiler. This deliberately
        // does not use `MainActor.assumeIsolated` — see the Recorder note in CLAUDE.md.
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

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.position = self.duration
            }
        }

        phase = .ready
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
        player?.pause()
        player = nil
        isPlaying = false
        duration = 0
        position = 0
    }

    private static func message(for error: Error) -> String {
        guard let e = error as? NotesClient.ClientError else { return error.localizedDescription }
        switch e {
        case .offline(let m):  return m
        case .unauthorized:    return "The PC rejected this Mac's token."
        case .server(let code, _):
            return code == 404 ? "The PC has no audio for this lecture." : "The PC answered \(code)."
        }
    }

    /// mm:ss, or h:mm:ss once a lecture runs past the hour.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
