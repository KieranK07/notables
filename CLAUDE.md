# Notables — instructions for agents working in this repo

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first, then
[docs/PROTOCOL.md](docs/PROTOCOL.md) — the protocol is the contract between three
independently-built components; do not change it unilaterally.
[docs/CANVAS.md](docs/CANVAS.md) covers the Canvas integration and why its auth is odd.

## Hard rules

1. **LLM work runs on the Claude subscription via the `claude` CLI**, never the Anthropic
   API. No API keys, no `ANTHROPIC_API_KEY`, no `@anthropic-ai/sdk`. On the PC the binary
   is `C:\Users\Kieran\AppData\Local\Microsoft\WinGet\Links\claude.exe`.
   Pipe the prompt in on **stdin** — a 1-hour transcript is far past `cmd.exe`'s 8191-char
   command-line limit.
2. **The verbatim transcript is written to disk before Claude is called.** Never let an AI
   failure lose a lecture.
3. **Zero npm/pip dependencies in `server/`.** Node stdlib only.
4. **The PC is the only machine that keeps audio.** The Mac records to
   `~/Documents/Notables/Recordings/`, uploads, and then *releases* its copy once the
   server reports `safeToDelete` — audio verified on the PC **and** the note at `ready`,
   so the transcript and the markdown exist too. Playback fetches the recording back from
   `GET /api/audio/{id}`. Never delete a local recording on anything weaker than that
   flag, and never infer the flag from an SSE event. See **docs/PROTOCOL.md**.
5. **The Canvas session cookie is a full-account credential.** It lives only in
   `%USERPROFILE%\.notables\canvas-session.json`, is never logged, never written
   into the vault, and is never sent to any host but `CANVAS_HOST`. It expires, and
   an expired session must be *visible* — never a silent "no new materials".
   See **docs/CANVAS.md**.

## Environment facts (verified 2026-09-04, don't re-derive)

- Mac: macOS 26.6.2, Apple Silicon, Xcode 26.5. `swiftc` builds the app; no `.xcodeproj`.
- On-device transcription = macOS 26 `SpeechAnalyzer`. See **docs/SPEECH-API.md** for the
  working pipeline and the five gotchas that will otherwise cost you an hour.
- PC: `ssh pc` works. Windows 11, **default shell is `cmd.exe`** — separate commands with
  `&`, not `;`. Node and Git are on PATH; the `python` on PATH is a broken uv shim, use
  `C:\Users\Kieran\AppData\Local\Programs\Python\Python312\python.exe` if you need Python.
- Tailscale: Mac `100.98.99.110`, PC `100.69.103.126`. **The link is DERP-relayed via
  Chicago, not direct** — the PC sits behind a campus symmetric NAT
  (`MappingVariesByDestIP: true`, LAN `10.72.x`, no port mapping), which Tailscale
  cannot hole-punch. Budget ~1.6 MB/s and ~50 ms RTT for everything crossing the
  network, and prefer fewer, smaller, compressed round trips. Verified 2026-09-05.
- `claude -p "prompt"` on the PC works and takes ~6 s round trip over ssh.
- Canvas: `franciscan.instructure.com`. **Student access tokens are disabled** and
  login is Microsoft SAML SSO — session-cookie auth is the only option, and it is
  not a shortcut anyone should "fix" with a token. Verified 2026-09-05.

## Traps already hit (don't repay these)

- **Non-ASCII paths must not cross the Node→Python boundary on Windows.** The vault's
  filenames contain an em dash; the Python child decoded stdin as cp1252, wrote its JSON to
  a mojibake path, and Node's read failed with ENOENT — after which the server *silently
  fell back to the Mac's rough draft transcript* and everything looked fine. Fixed by handing
  Python a pure-ASCII scratch path and moving the file in Node, plus `PYTHONUTF8=1`.
  General rule: any fallback that silently degrades quality must be visible in the UI —
  `transcriptSource` is on every note and the app shows a "rough" badge for `draft`.
- **`MainActor.assumeIsolated` in an audio tap is a guaranteed crash, not a shortcut.**
  `Recorder` reached its main-actor `audioFile`/converters from the nonisolated tap callback
  through three `…Unsafe` accessors wrapping `MainActor.assumeIsolated`. That silences the
  concurrency checker and then traps (`EXC_BREAKPOINT` in `dispatch_assert_queue_fail`) on the
  *first* buffer: `assumeIsolated` asserts which thread you are on, and a CoreAudio tap is never
  the main one. A harness confirms every tap callback arrives off-main. State the tap needs now
  lives in a lock-protected `TapState` the closure captures; it also holds the only reference to
  the `AVAudioFile`, so `invalidate()` closes the container at a chosen moment rather than
  whenever the engine gets round to releasing its closure — the caller stats that file
  immediately, and an unfinalised one reads as an empty recording.

- **AAC's legal bitrate range depends on the sample rate.** At 16 kHz mono the ceiling is
  48 kbps; the recorder asked for 64 kbps and `AVAudioFile(forWriting:)` threw
  `kAudioFormatUnsupportedDataFormatError` ('!dat') from
  `AudioConverterSetProperty(kAudioConverterEncodeBitRate)`, so **Mac recording never once
  worked**. `kAudioFormatProperty_AvailableEncodeBitRates` is no help — it is a static
  superset that advertises 64 kbps at 16 kHz anyway. Worse, the file is created on disk
  *before* the converter setup throws, leaving a ~557-byte stub that reads as an empty
  recording. `makeRecordingFile` now descends 48k → 32k → encoder default and deletes the
  stub between attempts.

- **A property left out of `CodingKeys` is dropped on the way *in*, not just out.**
  `IngestPayload.localAudioPath` was documented "local only; not sent" and omitted from
  `CodingKeys` — which governs decoding too, so the outbox wrote the payload to disk
  without the path and read it back as `nil`. `drainOutbox` re-reads each job from disk,
  so this fired on the *first* attempt, not only after a relaunch: `if let path =` failed,
  the audio upload was skipped entirely, and `Outbox.remove` then ran unconditionally and
  deleted the job. The server was left holding an `awaiting_audio` note with 0 of
  10,098,127 bytes while the app reported success — the "audio is missing" banner sat in
  an inner `else` that the failed `if let` could never reach. A real lecture uploaded as
  text only. The outbox now persists a `Record` wrapper carrying the local-only fields
  beside the wire payload, and an entry leaves the outbox only once the audio is on the PC
  or is provably gone from this Mac.

- **Releasing local audio must not depend on the SSE event.** The reclaim was first wired
  only to the `note`-went-`ready` event. That event never arrived: the app sat running for
  hours with **zero open TCP connections** and `sseClients: 0` on the server, so a finished
  lecture kept its 17.8 MB local copy and the Library silently went stale. Root cause of the
  dead stream is still unknown (App Nap is a candidate). Retention now also polls every 60 s
  while recordings are held, and reconciles when the app becomes active. Treat SSE as an
  accelerator, never as the only trigger for anything that matters.

- **A dead input device records perfect silence and nothing anywhere notices.** A
  72-minute lecture went to disk as 69,330,236 consecutive **exact zero** samples (AAC
  compressed it to 500 bit/s — 600 kB for a 72-minute class, against ~49 kbps for a real
  one). The system default input was AirPods, which stayed "the default input" while
  delivering nothing. Every layer then reported success: the file was non-empty so the
  upload proceeded, whisper ran happily and returned 0 segments, and the recording panel
  said "Listening…" over a flat meter for the whole class. **The RMS meter cannot detect
  this** — it floors at 0 below −55 dBFS, so a quiet room and a dead device look identical
  on it. Peak amplitude is the discriminator: real mics have a −60 dBFS noise floor, dead
  ones give exactly 0.0. `Recorder` now tracks peak per buffer, warns in the panel after
  12 s of silence, names the actual input device on screen, and banners at stop if it never
  heard a single sample. `bench/silence-check` runs the real `Recorder.measure` over this
  lecture and a good one as a regression test.

- **AVAudioEngine does not follow the audio route.** A device change (AirPods connecting,
  the default input switched) tears down the engine's connections and takes the tap with
  them, while `engine.isRunning` keeps saying yes — so the rest of the lecture is written
  as silence. `Recorder` now observes `.AVAudioEngineConfigurationChange`, rebuilds the
  converters against the new format, keeps writing to the *same* `AVAudioFile`, and says
  on screen that the input changed.

- **An empty string is falsy, and `if (!r) return` swallowed a whole note.**
  `pipeline.runNote` called `transcribePhase`, whose contract is "returns the text, or
  `null` after calling `fail()`". whisper succeeding with no speech returns `''`, which took
  the `null` branch: the function returned **without** failing the note, so it sat at
  `transcribing` forever — no error, no SSE event, the app's spinner turning all morning.
  The `if (!transcript.trim()) return fail(...)` guard one line below could never be reached
  for `''`, only for whitespace. Test the sentinel (`r === null`), never truthiness, when
  the sentinel and a legitimate empty value are both falsy.

- **`URLSession.AsyncBytes.lines` drops empty lines**, and the blank line is what terminates
  an SSE event — so SSE parsed with `.lines` never dispatches. Parse the raw bytes.
- **`wmic` is gone** on this Windows build; use `powershell -NoProfile -Command`.
  `nvidia-smi` is not on PATH.
- **`pypdf` writes font warnings to stdout, and a script's stdout is the JSON
  protocol.** `extract.py` redirects stdout to stderr during extraction. Any future
  Python child that speaks JSON on stdout must do the same.
- **whisper truncates `initial_prompt` to its last 224 tokens.** `buildInitialPrompt`
  must budget the *whole* string; an earlier version measured only the term list and
  overflowed 700 → 754 chars, silently dropping terms off the front.
- **`rebuildIndex()` used to destroy every course glossary.** The glossary and the
  Canvas link live only in `_courses.json`, and a reindex derives everything from the
  note markdown. It now snapshots them first *and* re-derives terms from each note's
  `## Key Terms`, so the vault alone can rebuild them.
- **The repo is under `Desktop`, which is file-provider synced.** The provider
  re-stamps `com.apple.FinderInfo` onto a bundle in the window between `xattr -cr`
  and `codesign --verify`, so signing inside the repo can never be made reliably
  clean. **`build.sh` therefore builds to `~/Library/Caches/notables-build`**, outside
  the synced tree (`NOTABLES_BUILD_DIR` overrides). `install-mac-app.sh` still strips,
  re-signs if needed, and verifies both the signature and the `audio-input`
  entitlement on the installed copy — a broken signature silently costs the mic.
- **The app is signed with the real Apple Development identity**, auto-detected by
  `build.sh` (`NOTABLES_SIGN_ID` overrides; `-` forces ad-hoc). Ad-hoc leaves
  `TeamIdentifier` unset, which forfeits anything keyed to app identity.
- **codesign refuses a bundle carrying Finder metadata**, which a *running* app reacquires.
  `build.sh` strips xattrs and then verifies the signature rather than assuming it took.

## Working style

- Author server code **on the Mac** under `server/`, then deploy with
  `scripts/deploy-server.sh`. Editing remotely through `cmd.exe` quoting is a trap.
- Test against a real running server before reporting success. `GET /api/health` is the
  cheap check.
