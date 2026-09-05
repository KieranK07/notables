import Foundation
import AVFoundation
import Speech

/// Wraps macOS 26's on-device `SpeechAnalyzer`. See docs/SPEECH-API.md — in particular,
/// only `result.isFinal` text may be appended; volatile results are a live preview only.
@available(macOS 26.0, *)
actor LiveTranscriber {

    enum Failure: LocalizedError {
        case unsupportedLocale
        case noCompatibleFormat
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:  return "No speech model is available for your language."
            case .noCompatibleFormat: return "The speech analyzer offered no usable audio format."
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<Void, Never>?
    private(set) var analyzerFormat: AVAudioFormat?

    /// Committed text. Only `isFinal` results land here.
    private(set) var finalText: String = ""
    /// The in-flight phrase, still being revised by the model.
    private(set) var volatileText: String = ""

    private var onUpdate: (@Sendable (String, String) -> Void)?

    static func modelIsReady(locale: Locale) async -> Bool {
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [t]) == .installed
    }

    static func resolvedLocale() async -> Locale? {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: .current) { return l }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first { $0.identifier.hasPrefix("en") } ?? supported.first
    }

    /// Downloads the on-device model if it isn't installed yet. Safe to call repeatedly.
    static func prepareModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let locale = await resolvedLocale() else { throw Failure.unsupportedLocale }
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [t]) != .installed {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                let observation = Task { @Sendable in
                    while !Task.isCancelled {
                        progress?(req.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { observation.cancel() }
                try await req.downloadAndInstall()
            }
        }
        _ = try? await AssetInventory.reserve(locale: locale)   // false for system locales; harmless
    }

    /// Spins up the analyzer and returns the audio format it wants buffers in.
    func start(onUpdate: @escaping @Sendable (String, String) -> Void) async throws -> AVAudioFormat {
        guard let locale = await Self.resolvedLocale() else { throw Failure.unsupportedLocale }
        try await Self.prepareModel()

        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw Failure.noCompatibleFormat
        }

        self.onUpdate = onUpdate
        self.transcriber = t
        self.analyzerFormat = fmt
        self.finalText = ""
        self.volatileText = ""

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = cont
        let a = SpeechAnalyzer(modules: [t])
        self.analyzer = a

        // Must be consuming before audio starts flowing, or results are dropped.
        collector = Task { [weak self] in
            do {
                for try await result in t.results {
                    guard let self else { return }
                    await self.ingest(result)
                }
            } catch {
                NSLog("[Notables] transcriber results ended: \(error)")
            }
        }

        try await a.prepareToAnalyze(in: fmt)
        try await a.start(inputSequence: stream)
        return fmt
    }

    private func ingest(_ result: SpeechTranscriber.Result) {
        let chunk = String(result.text.characters)
        if result.isFinal {
            finalText += chunk
            volatileText = ""
        } else {
            volatileText = chunk
        }
        onUpdate?(finalText, volatileText)
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        Task { await self.yield(buffer) }
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Flushes the analyzer and returns the complete verbatim transcript.
    func finish() async -> String {
        continuation?.finish()
        continuation = nil
        if let a = analyzer {
            do { try await a.finalizeAndFinishThroughEndOfInput() }
            catch { NSLog("[Notables] finalize failed: \(error)") }
        }
        _ = await collector?.value
        collector = nil
        analyzer = nil
        transcriber = nil
        let text = (finalText + " " + volatileText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        volatileText = ""
        finalText = text
        return text
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        if let a = analyzer { await a.cancelAndFinishNow() }
        collector?.cancel()
        collector = nil
        analyzer = nil
        transcriber = nil
    }

    /// One-shot transcription of an existing recording. Uses the native file path —
    /// a hand-rolled AVAudioFile.read loop throws `nilError` (see docs/SPEECH-API.md).
    static func transcribeFile(at url: URL) async throws -> String {
        guard let locale = await resolvedLocale() else { throw Failure.unsupportedLocale }
        try await prepareModel()
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [t])

        let collected = Task { () -> String in
            var out = ""
            do { for try await r in t.results where r.isFinal { out += String(r.text.characters) } }
            catch { NSLog("[Notables] file results ended: \(error)") }
            return out
        }

        let file = try AVAudioFile(forReading: url)
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
