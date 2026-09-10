import Foundation
import AVFoundation
import CoreAudio
import Speech

/// Captures the microphone to a compact AAC file while running Apple's on-device
/// transcriber for a live preview.
///
/// The preview is NOT the transcript that becomes your notes — the PC re-transcribes this
/// audio with whisper large-v3 on its GPU. So the file is encoded for a transcription
/// model's benefit, not a listener's: 64 kbps mono at 16 kHz ≈ 29 MB for a one-hour class,
/// near-transparent for speech and small enough to be irrelevant over Tailscale.
enum RecorderError: LocalizedError {
    case noAudioConverter
    var errorDescription: String? {
        switch self {
        case .noAudioConverter: return "the microphone format could not be converted for recording"
        }
    }
}

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

    /// Which device the audio is actually coming from. Shown while recording because the
    /// system default input is not always the one you think: an hour of a lecture was lost
    /// to AirPods that were still the default input while delivering nothing.
    @Published private(set) var inputDeviceName: String?
    /// False only when this Mac has no built-in input to pin to, or pinning was refused.
    @Published private(set) var usingBuiltInMic = true
    /// How long the input has been delivering pure digital zeros. Drives the "no sound is
    /// reaching Notables" warning.
    @Published private(set) var silentFor: TimeInterval = 0
    /// False until a single sample above the silence floor arrives. If this is still false
    /// at stop(), the recording is 100% silence and the class was not captured at all.
    @Published private(set) var heardSignal = false

    /// −80 dBFS. Comfortably below any real microphone's noise floor (−60 dBFS or so), so
    /// this detects a *dead* input, never a quiet room.
    private static let silenceFloor: Float = 1e-4
    /// How long a dead input has to stay dead before the UI shouts about it.
    static let silenceWarningAfter: TimeInterval = 12
    /// How long the on-device analyzer gets to flush before we stop waiting on it.
    private static let flushTimeout: TimeInterval = 12

    private let engine = AVAudioEngine()
    private var tap: TapState?
    private var transcriber: Any?                            // LiveTranscriber, gated on macOS 26
    private var analyzerFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
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

    /// AAC's legal bitrate range depends on the sample rate, and at 16 kHz mono it tops out
    /// at 48 kbps: 64 kbps throws `kAudioFormatUnsupportedDataFormatError` ('!dat') out of
    /// `AudioConverterSetProperty(kAudioConverterEncodeBitRate)`. Two things make that worse
    /// than it sounds. `kAudioFormatProperty_AvailableEncodeBitRates` is a *static superset*
    /// which cheerfully advertises 64 kbps at 16 kHz, so it cannot be used to choose a rate;
    /// and AVAudioFile creates the file on disk *before* the converter setup throws, leaving
    /// a ~557-byte stub that later reads as an empty recording. So descend through known-good
    /// rates, fall back to the encoder's own default, and delete the stub between attempts.
    /// 48 kbps across 8 kHz of speech bandwidth is well past transparent, so the ceiling
    /// costs nothing. Verified on macOS 26.6.2, 2026-09-07.
    private static func makeRecordingFile(at url: URL) throws -> AVAudioFile {
        var lastError: Error = CocoaError(.fileWriteUnknown)
        for bitRate in [48_000, 32_000, nil] {
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1
            ]
            if let bitRate { settings[AVEncoderBitRateKey] = bitRate }
            do { return try AVAudioFile(forWriting: url, settings: settings) }
            catch {
                lastError = error
                try? FileManager.default.removeItem(at: url)
            }
        }
        throw lastError
    }

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
        silentFor = 0; heardSignal = false

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
        pinToBuiltInMic()
        // Read the format only after pinning: it describes whichever device the input node
        // is now attached to, and that is no longer the system default.
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            self.error = "No microphone input is available."
            state = .idle
            return
        }

        // Mono 16 kHz is exactly what whisper wants.
        let url = Self.recordingsDirectory.appendingPathComponent("\(id).m4a")
        recordingURL = url
        do {
            let file = try Self.makeRecordingFile(at: url)
            // Without this converter nothing reaches disk, so fail loudly rather than
            // record silence for an hour.
            guard let toFile = AVAudioConverter(from: micFormat, to: file.processingFormat) else {
                throw RecorderError.noAudioConverter
            }
            let toAnalyzer = AVAudioConverter(from: micFormat, to: analyzerFormat)
            toAnalyzer?.primeMethod = .none
            tap = TapState(file: file, toFile: toFile, toAnalyzer: toAnalyzer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            self.error = "Could not create the recording file: \(error.localizedDescription)"
            state = .idle
            return
        }

        self.analyzerFormat = analyzerFormat
        installTap(micFormat: micFormat)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Could not start the audio engine: \(error.localizedDescription)"
            state = .idle
            return
        }

        // A device change (AirPods connecting, a dock unplugged, the default input switched
        // in System Settings) tears the engine's connections down and takes the tap with
        // them. The engine keeps reporting itself as running, so without this the rest of
        // the lecture goes to disk as silence and nothing says so.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.audioRouteChanged() }
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
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }

        // ORDER MATTERS, and it is ordered by what is irreplaceable.
        //
        // The m4a is the lecture. The live transcript is a preview the PC re-does from
        // that same audio. So the file is closed FIRST, before anything that can block:
        // `engine.stop()` is synchronous and waits on the audio thread, and the analyzer
        // flush below can wait on a model. A 79-minute class was lost to exactly this -
        // the app was killed while stopping, and the recording was still an unfinalised
        // container holding 29 MB of AAC with no index to it.
        engine.inputNode.removeTap(onBus: 0)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writeQueue.async { c.resume() }            // let queued writes drain
        }
        // Releases the AVAudioFile here, on the main actor, so the container is finalised
        // before the caller stats the file. Waiting on the engine to release its tap
        // closure would race that check and report a good recording as empty.
        tap?.invalidate(); tap = nil

        teardownEngine()

        // The analyzer flush is best-effort and time-boxed. `finalizeAndFinishThroughEndOfInput`
        // then awaiting the results task can hang - the stream simply never ends - and an
        // hour of audio is not worth risking on a preview that is about to be thrown away.
        var transcript = transcriptSoFar
        if #available(macOS 26.0, *), let live = transcriber as? LiveTranscriber {
            if let flushed = await withTimeout(seconds: Self.flushTimeout, { await live.finish() }) {
                transcript = flushed
            } else {
                error = "The live transcriber didn't finish in time — the recording is saved " +
                        "and the PC will transcribe it properly."
                Task { await live.cancel() }           // let it unwind on its own time
            }
        }
        finalText = transcript
        volatileText = ""
        transcriber = nil
        analyzerFormat = nil
        let duration = elapsed
        state = .idle
        level = 0
        return (recordingURL, transcript, duration)
    }

    /// Stop the engine and hand the microphone back.
    ///
    /// `engine.stop()` alone leaves the input node initialised, which keeps the device
    /// open and the orange microphone indicator lit long after a recording has ended.
    /// Resetting and deallocating the input unit's render resources is what actually
    /// releases it.
    private func teardownEngine() {
        engine.stop()
        engine.reset()
        engine.inputNode.auAudioUnit.deallocateRenderResources()
    }

    /// Run `work`, giving up after `seconds`. Returns nil on timeout, leaving the original
    /// task to finish or hang on its own without holding anyone up.
    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Forget the last recording's text so the panel does not open showing it. Called once
    /// the note is safely queued - not in stop(), whose return value is that text.
    func clearTranscript() {
        finalText = ""
        volatileText = ""
        levels = []
        level = 0
        elapsed = 0
    }

    func cancel() async {
        guard state != .idle else { return }
        ticker?.invalidate(); ticker = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        tap?.invalidate(); tap = nil
        teardownEngine()
        if #available(macOS 26.0, *), let live = transcriber as? LiveTranscriber { await live.cancel() }
        transcriber = nil
        analyzerFormat = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        finalText = ""; volatileText = ""; elapsed = 0; level = 0; levels = []
        silentFor = 0; heardSignal = false
        state = .idle
    }

    // MARK: - Input device

    /// Installs (or reinstalls) the tap for `micFormat`. The closure captures the `TapState`
    /// box, never the file itself, so `TapState.invalidate()` drops the last reference at a
    /// moment we choose — see stop().
    private func installTap(micFormat: AVAudioFormat) {
        guard let tapState = tap, let analyzerFormat, let open = tapState.open else { return }
        guard let toFile = AVAudioConverter(from: micFormat, to: open.file.processingFormat) else {
            error = "The new audio input's format cannot be recorded. Stop and start again."
            return
        }
        let toAnalyzer = AVAudioConverter(from: micFormat, to: analyzerFormat)
        toAnalyzer?.primeMethod = .none
        tapState.reconfigure(toFile: toFile, toAnalyzer: toAnalyzer)

        let live = transcriber
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, tap: tapState, analyzerFormat: analyzerFormat, live: live as Any)
        }
    }

    /// The audio hardware changed under a running recording. AVAudioEngine has already
    /// stopped and dropped every connection, so capture is dead until we rebuild it —
    /// silently, if nobody does. Rebuild against the new device and keep writing to the
    /// same file, and say what happened either way.
    private func audioRouteChanged() {
        guard state == .recording else { return }
        let previous = inputDeviceName

        // Re-pin rather than accept whatever the change left behind: AirPods connecting
        // mid-lecture must not become the microphone, which is the whole point of pinning.
        let input = engine.inputNode
        pinToBuiltInMic()
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            error = "The microphone (\(previous ?? "input")) went away. Recording is paused — " +
                    "reconnect it, or stop and start again."
            return
        }
        installTap(micFormat: micFormat)
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if let now = inputDeviceName, now != previous {
                error = "The audio input switched to \(now) mid-recording. Still recording — " +
                        "check that the class is still being picked up."
            }
        } catch {
            self.error = "The audio input changed and recording could not resume: " +
                         "\(error.localizedDescription). Stop and start again."
        }
    }

    struct InputDevice: Equatable {
        let id: AudioDeviceID
        let name: String
    }

    /// Pin the engine's input to the Mac's own microphone, whatever the system default is.
    ///
    /// `AVAudioEngine.inputNode` otherwise follows the system default input, which is how a
    /// lecture came out as 72 minutes of silence: AirPods held the default while delivering
    /// nothing. The built-in mic is the one that is always present, always in the room, and
    /// never claimed by a phone — for recording a class it is simply the right device, so
    /// the app stops asking. `setDeviceID` must happen while the engine is stopped, which is
    /// true at both call sites (start, and after a route change tears the engine down).
    private func pinToBuiltInMic() {
        guard let builtIn = Self.builtInInputDevice() else {
            // No built-in input at all — a Mac mini, or a Studio with nothing attached.
            // Fall back to the default rather than refusing to record, and name it.
            let fallback = Self.defaultInputDevice()
            usingBuiltInMic = false
            inputDeviceName = fallback?.name
            return
        }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(builtIn.id)
            usingBuiltInMic = true
            inputDeviceName = builtIn.name
        } catch {
            let fallback = Self.defaultInputDevice()
            usingBuiltInMic = false
            inputDeviceName = fallback?.name
            self.error = "Could not switch to the built-in microphone " +
                         "(\(error.localizedDescription)) — recording from " +
                         "\(fallback?.name ?? "the default input") instead."
        }
    }

    /// The Mac's own microphone: built-in transport, with input channels. Matching on
    /// transport type rather than on the name keeps this working across Mac models.
    nonisolated static func builtInInputDevice() -> InputDevice? {
        for id in allDeviceIDs()
        where transportType(id) == kAudioDeviceTransportTypeBuiltIn && inputChannels(id) > 0 {
            return InputDevice(id: id, name: deviceName(id) ?? "Built-in Microphone")
        }
        return nil
    }

    /// The system's current default input — only the fallback now, but still what gets named
    /// on screen when there is no built-in mic to pin to.
    nonisolated static func defaultInputDevice() -> InputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return InputDevice(id: deviceID, name: deviceName(deviceID) ?? "Default Input")
    }

    private nonisolated static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// Total input channels. Zero means the device is output-only, which is how the
    /// speakers-and-microphone pair that share a name are told apart.
    private nonisolated static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func deviceName(_ id: AudioDeviceID) -> String? {
        // kAudioObjectPropertyName hands back a +1 CFStringRef. It has to land in an
        // `Unmanaged` — taking `&` on a plain `CFString` forms a raw pointer to an object
        // reference, which the compiler rightly calls out and ARC would then double-free.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    // MARK: - Audio tap (runs on the audio thread)

    private nonisolated func handle(buffer: AVAudioPCMBuffer,
                                    tap: TapState?,
                                    analyzerFormat: AVAudioFormat,
                                    live: Any) {
        let m = Self.measure(buffer)
        Task { @MainActor [weak self] in
            self?.push(level: m.meter, peak: m.peak, seconds: m.seconds)
        }

        guard let open = tap?.open else { return }   // nil once stop() has closed the file

        // Archive copy.
        if let out = Self.convert(buffer, with: open.toFile, to: open.file.processingFormat) {
            writeQueue.async { try? open.file.write(from: out) }
        }
        // Transcriber copy.
        if #available(macOS 26.0, *), let live = live as? LiveTranscriber,
           let conv = open.toAnalyzer,
           let out = Self.convert(buffer, with: conv, to: analyzerFormat) {
            live.feed(out)
        }
    }

    /// What the tap needs to do its job, held off the main actor because that is where the
    /// tap actually runs. The previous version reached main-actor properties through
    /// `MainActor.assumeIsolated`, which type-checks and then traps on the first buffer:
    /// `assumeIsolated` asserts *which thread you are on*, and a CoreAudio tap is never
    /// the main one. Mutation is confined to start/stop, but the lock is what makes the
    /// hand-off to the audio thread legal rather than merely hoped-for.
    private final class TapState: @unchecked Sendable {
        struct Open {
            let file: AVAudioFile
            let toFile: AVAudioConverter
            let toAnalyzer: AVAudioConverter?
        }
        private let lock = NSLock()
        private var state: Open?

        init(file: AVAudioFile, toFile: AVAudioConverter, toAnalyzer: AVAudioConverter?) {
            state = Open(file: file, toFile: toFile, toAnalyzer: toAnalyzer)
        }

        var open: Open? {
            lock.lock(); defer { lock.unlock() }
            return state
        }

        /// Swap in converters built for a new input format, keeping the same open file, so
        /// a device change mid-lecture costs a moment of audio rather than the rest of it.
        func reconfigure(toFile: AVAudioConverter, toAnalyzer: AVAudioConverter?) {
            lock.lock(); defer { lock.unlock() }
            guard let current = state else { return }
            state = Open(file: current.file, toFile: toFile, toAnalyzer: toAnalyzer)
        }

        /// Drops the file and converters. Any buffer still in flight sees nil and bows out.
        func invalidate() {
            lock.lock(); defer { lock.unlock() }
            state = nil
        }
    }

    private nonisolated static func convert(_ input: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        // `.inputRanDry` is the normal outcome here, not a failure: the input block hands over
        // exactly one buffer and then reports `.noDataNow`, so the converter runs dry on every
        // call having already produced good frames. It leaves `error` nil when that happens and
        // fills it only on a real `.error`, so switching on the status says what we mean.
        switch status {
        case .haveData, .inputRanDry:
            return out.frameLength > 0 ? out : nil
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }

    /// One pass over the buffer for both jobs the meter and the watchdog need.
    ///
    /// `meter` is the pretty 0…1 needle value, which floors at 0 for anything below
    /// −55 dBFS — a quiet room and a dead input look identical on it, which is why it
    /// cannot be what detects silence. `peak` is the raw maximum sample, and *that*
    /// separates "nobody is talking" (a noise floor around −60 dBFS) from "this device is
    /// handing us zeros" (exactly 0.0, for 69 million samples straight).
    /// Internal rather than private so bench/silence-check can run the real function
    /// over real recordings — see that harness for the regression this guards.
    nonisolated static func measure(_ buffer: AVAudioPCMBuffer)
    -> (meter: Float, peak: Float, seconds: TimeInterval) {
        let n = Int(buffer.frameLength)
        let seconds = buffer.format.sampleRate > 0
            ? TimeInterval(n) / buffer.format.sampleRate : 0
        guard let data = buffer.floatChannelData, n > 0 else { return (0, 0, seconds) }
        var sum: Float = 0
        var peak: Float = 0
        for i in 0..<n {
            let s = data[0][i]
            sum += s * s
            let a = abs(s)
            if a > peak { peak = a }
        }
        let rms = (sum / Float(n)).squareRoot()
        // dBFS → a 0…1 scale that looks right on a meter.
        let db = 20 * log10(max(rms, 1e-7))
        return (min(max((db + 55) / 55, 0), 1), peak, seconds)
    }

    private func push(level newLevel: Float, peak: Float, seconds: TimeInterval) {
        level += (newLevel - level) * 0.35            // smooth the needle
        levels.append(newLevel)
        if levels.count > 180 { levels.removeFirst(levels.count - 180) }

        if peak > Self.silenceFloor {
            heardSignal = true
            silentFor = 0
        } else {
            silentFor += seconds
        }
    }
}
