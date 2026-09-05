import Foundation
import AVFoundation
import Speech

/// Captures the microphone to a compact AAC file while running Apple's on-device
/// transcriber for a live preview.
///
/// The preview is NOT the transcript that becomes your notes — the PC re-transcribes this
/// audio with whisper large-v3 on its GPU. So the file is encoded for a transcription
/// model's benefit, not a listener's: 64 kbps mono at 16 kHz ≈ 29 MB for a one-hour class,
/// near-transparent for speech and small enough to be irrelevant over Tailscale.
@MainActor
final class Recorder: ObservableObject {

    enum State: Equatable { case idle, preparing, recording, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0            // 0…1, smoothed, for the meter
    @Published private(set) var levels: [Float] = []        // rolling waveform history
    @Published private(set) var finalText: String = ""
    @Published private(set) var volatileText: String = ""
    @Published private(set) var error: String?
    @Published private(set) var modelDownloadProgress: Double?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var fileConverter: AVAudioConverter?
    private var analyzerConverter: AVAudioConverter?
    private var transcriber: Any?                            // LiveTranscriber, gated on macOS 26
    private var startedAt: Date?
    private var ticker: Timer?
    private let writeQueue = DispatchQueue(label: "com.kierankelly.notables.write")

    private(set) var recordingURL: URL?

    static let recordingsDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notables/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    var transcriptSoFar: String {
        (finalText + " " + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Permission

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Lifecycle

    func start(id: String) async {
        guard state == .idle else { return }
        error = nil
        state = .preparing

        guard await Self.requestMicrophoneAccess() else {
            error = "Notables needs microphone access. Enable it in System Settings › Privacy & Security › Microphone."
            state = .idle
            return
        }
        guard #available(macOS 26.0, *) else {
            error = "Notables needs macOS 26 or later for on-device transcription."
            state = .idle
            return
        }

        finalText = ""; volatileText = ""; levels = []; level = 0; elapsed = 0

        let live = LiveTranscriber()
        transcriber = live

        let analyzerFormat: AVAudioFormat
        do {
            modelDownloadProgress = nil
            analyzerFormat = try await live.start { [weak self] final, volatile in
                Task { @MainActor in
                    self?.finalText = final
                    self?.volatileText = volatile
                }
            }
        } catch {
            self.error = "Could not start transcription: \(error.localizedDescription)"
            state = .idle
            return
        }

        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            self.error = "No microphone input is available."
            state = .idle
            return
        }

        // Mono 16 kHz is exactly what whisper wants; 64 kbps keeps AAC artefacts off the ASR.
        let url = Self.recordingsDirectory.appendingPathComponent("\(id).m4a")
        recordingURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            audioFile = file
            fileConverter = AVAudioConverter(from: micFormat, to: file.processingFormat)
            analyzerConverter = AVAudioConverter(from: micFormat, to: analyzerFormat)
            analyzerConverter?.primeMethod = .none
        } catch {
            self.error = "Could not create the recording file: \(error.localizedDescription)"
            state = .idle
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, analyzerFormat: analyzerFormat, live: live)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Could not start the audio engine: \(error.localizedDescription)"
            state = .idle
            return
        }

        startedAt = Date()
        state = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
    }

    /// Stops capture and returns the finished verbatim transcript.
    func stop() async -> (url: URL?, transcript: String, duration: TimeInterval) {
        guard state == .recording else { return (recordingURL, finalText, elapsed) }
        state = .finishing
        ticker?.invalidate(); ticker = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Let queued writes drain before we close the file.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writeQueue.async { c.resume() }
        }
        audioFile = nil

        var transcript = transcriptSoFar
        if #available(macOS 26.0, *), let live = transcriber as? LiveTranscriber {
            transcript = await live.finish()
        }
        finalText = transcript
        volatileText = ""
        transcriber = nil
        let duration = elapsed
        state = .idle
        level = 0
        return (recordingURL, transcript, duration)
    }

    func cancel() async {
        guard state != .idle else { return }
        ticker?.invalidate(); ticker = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        if #available(macOS 26.0, *), let live = transcriber as? LiveTranscriber { await live.cancel() }
        transcriber = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        finalText = ""; volatileText = ""; elapsed = 0; level = 0; levels = []
        state = .idle
    }

    // MARK: - Audio tap (runs on the audio thread)

    private nonisolated func handle(buffer: AVAudioPCMBuffer,
                                    analyzerFormat: AVAudioFormat,
                                    live: Any) {
        let rms = Self.rms(of: buffer)
        Task { @MainActor [weak self] in self?.push(level: rms) }

        // Archive copy.
        if let file = audioFileUnsafe, let conv = fileConverterUnsafe,
           let out = Self.convert(buffer, with: conv, to: file.processingFormat) {
            writeQueue.async { try? file.write(from: out) }
        }
        // Transcriber copy.
        if #available(macOS 26.0, *), let live = live as? LiveTranscriber,
           let conv = analyzerConverterUnsafe,
           let out = Self.convert(buffer, with: conv, to: analyzerFormat) {
            live.feed(out)
        }
    }

    // The tap runs off the main actor; these are only mutated in start/stop, never during capture.
    private nonisolated var audioFileUnsafe: AVAudioFile? {
        MainActor.assumeIsolated { audioFile }
    }
    private nonisolated var fileConverterUnsafe: AVAudioConverter? {
        MainActor.assumeIsolated { fileConverter }
    }
    private nonisolated var analyzerConverterUnsafe: AVAudioConverter? {
        MainActor.assumeIsolated { analyzerConverter }
    }

    private nonisolated static func convert(_ input: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var err: NSError?
        var supplied = false
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if err != nil || out.frameLength == 0 { return nil }
        return out
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = data[0][i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        // dBFS → a 0…1 scale that looks right on a meter.
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 55) / 55, 0), 1)
    }

    private func push(level newLevel: Float) {
        level += (newLevel - level) * 0.35            // smooth the needle
        levels.append(newLevel)
        if levels.count > 180 { levels.removeFirst(levels.count - 180) }
    }
}
