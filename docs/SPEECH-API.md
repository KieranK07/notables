# On-device transcription: macOS 26 `SpeechAnalyzer`

Verified working on this machine (macOS 26.6.2, Apple Silicon, Xcode 26.5 / macOS 26.5 SDK)
on 2026-09-04. **No Whisper, no model files, no Python.** Everything below was
established by running code, not from docs — trust it over your memory of the API.

## Why this and not whisper.cpp
Apple's `Speech` framework in macOS 26 exposes `SpeechAnalyzer` + `SpeechTranscriber`:
fully on-device, streaming, free, no build step, no model checkout. On a test clip it
produced a clean verbatim transcript and correctly rendered *"section 4.3"* — the exact
signal we rely on for filing notes by textbook section.

## Working pipeline

```swift
import Speech, AVFoundation

// 1. Pick a locale the transcriber actually supports.
let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
           ?? Locale(identifier: "en_US")
let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

// 2. Install the on-device model if needed (one time, ~seconds; en_* came preinstalled here).
if await AssetInventory.status(forModules: [transcriber]) != .installed,
   let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await req.downloadAndInstall()          // req.progress is a Foundation.Progress
}
_ = try? await AssetInventory.reserve(locale: locale)   // returns false for system locales; harmless

// 3. The analyzer tells you the audio format it wants: 16 kHz, mono, Int16.
let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!

let analyzer = SpeechAnalyzer(modules: [transcriber])

// 4. Consume results on a separate task BEFORE feeding audio.
Task {
    for try await r in transcriber.results {
        if r.isFinal { finalText += String(r.text.characters) }   // stable, append this
        else         { livePreview = String(r.text.characters) }  // volatile, for on-screen only
    }
}
```

### Feeding audio — two paths

**Live microphone** (what the recorder uses): tap `AVAudioEngine.inputNode`, convert each
buffer to `fmt` with `AVAudioConverter`, and yield `AnalyzerInput(buffer:)` into an
`AsyncStream<AnalyzerInput>` passed to `analyzer.start(inputSequence:)`.
Finish with `continuation.finish()` then `analyzer.finalizeAndFinishThroughEndOfInput()`.

**An audio file** (re-transcribe / import): do **not** hand-roll an `AVAudioFile.read` loop.
Use the native call — it handles conversion and chunking for you:
```swift
let file = try AVAudioFile(forReading: url)
_ = try await analyzer.analyzeSequence(from: file)
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

## Gotchas that cost real time

| Symptom | Cause | Fix |
|---|---|---|
| Transcript is `"WWelWelcome toWelcome to Chem…"` | Concatenating **volatile** results | Only append when `result.isFinal`; volatile text is for a live preview label |
| `nilError` thrown on the *second* `AVAudioFile.read(into:frameCount:)` | Hand-rolled file read loop | Use `analyzer.analyzeSequence(from: file)` |
| `AssetInventory.reserve` returns `false` | Locale needs no reservation (system locale) | Ignore the return value; don't treat as failure |
| `statements are not allowed at the top level` | Built with `-parse-as-library` | Provide `@main struct Main { static func main() async }` |
| Results never arrive | Started feeding audio before consuming `transcriber.results` | Spawn the consuming `Task` first |

`result.isFinal` comes from a protocol extension on `SpeechModuleResult`; it is **not**
listed as a member of `SpeechTranscriber.Result`, so it is easy to miss when reading the
`.swiftinterface`.

## Reading the API yourself
```
SDK=$(xcrun --sdk macosx --show-sdk-path)
$SDK/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface
```
682 lines, the whole surface. Faster and more accurate than searching the web.
