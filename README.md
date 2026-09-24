# Notables

Records a class on the Mac, ships the audio to a Windows PC over Tailscale, transcribes it
there with whisper large-v3 on the GPU, and has Claude file the result into a Markdown vault
as a note with a summary, key terms and dated homework items. The finished note appears back
in the Mac app about seven minutes later without anyone touching anything.

All the AI runs on my **Claude subscription** through the `claude` CLI. There is no API key
in this project, and the server blanks the environment so it can't inherit one.

```
Mac: record + live preview  ──►  PC: whisper + Claude + vault  ──►  Mac: read
                                          ▲            ▲
                       iPhone Action Button│            │Canvas (course slides,
                       (quick capture)     │            │ syllabi → vocabulary)
```

## Why

Recording a class is easy. Doing anything with the recording is not. An hour of audio takes
an hour to listen back to, whisper large-v3 on a MacBook Air is slower than realtime and
cooks the laptop, and every product that will do it for you wants your lecture audio in
their cloud on a monthly bill. Meanwhile there is an RTX 3060 Ti sitting idle in the next
room and a Claude subscription I already pay for.

So the laptop only records, the desktop does the expensive part, Claude does the filing, and
the output is plain Markdown files I still own if I delete all of this tomorrow.

## What each part is

[`docs/PROTOCOL.md`](docs/PROTOCOL.md) is the wire contract between the three;
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) has the design decisions and the measured
numbers.

| | |
|---|---|
| **`mac/`** | `Notables.app` — SwiftUI, no Xcode project, built by `swiftc` into a hand-assembled bundle. Records 64 kbps mono 16 kHz AAC (~29 MB/hour), runs Apple's on-device `SpeechAnalyzer` for a live transcript so you can see it's capturing, queues the file, uploads it. Menu bar app; library, calendar and deadlines update over SSE. |
| **`server/`** | The Node half, on the PC. **Zero npm dependencies** — stdlib only, no `package.json`, nothing to install. Bearer auth, gzip, resumable uploads, idempotent ingest, a serial job queue and an SSE fan-out in about 3,900 lines of JavaScript. Drives `faster-whisper` and the `claude` CLI as subprocesses. |
| **`ios/`** | Not an app — a hand-built Shortcuts recipe on the Action Button. Dictate, `POST /api/capture`, banner. [`ios/SETUP.md`](ios/SETUP.md) builds it action by action, and explains why there is no importable `.shortcut` file. |

## How it works

`POST /api/ingest` announces a recording (metadata plus Apple's draft transcript, written
straight to `inbox/<id>.json`). `PUT /api/audio/{id}` sends the bytes and is resumable —
`GET /api/audio/{id}/status` reports how many arrived. The server runs whisper large-v3 on
CUDA in float16, **writes the verbatim transcript to disk**, and only then pipes it to
`claude -p` under a JSON schema to get back course, section, class date, summary, key terms,
structured notes and action items. It renders the Markdown, updates `_index.json`, and
pushes an SSE event that lands in the Mac app immediately.

Every stage is durable and retryable from what is already on disk. The transcript is written
before Claude is ever called, so a rate limit or a malformed response costs you a filing
pass, never a lecture.

### The glossary loop

whisper's `initial_prompt` is a real accuracy lever, not decoration: it conditions the first
window, so seeding it with a course's own vocabulary is what makes "Le Chatelier" and
"cytochrome c oxidase" come out as words instead of phonetics. Each finished note's key
terms fold back into a per-course glossary in `_courses.json`, which biases the *next*
recording in that course. `buildInitialPrompt` budgets the whole prompt string, because
whisper silently truncates `initial_prompt` to its last 224 tokens and an overlong one drops
exactly the terms you most wanted.

That loop has a cold start — the first lecture of a course has no glossary — which is what
the Canvas integration is for. It walks each course's modules, downloads the slides and
handouts, extracts their text (with an OCR fallback for scans), and runs a Claude pass over
a sample to produce 30–60 spoken terms *before* the first recording exists. Franciscan
disables student API tokens and logs in through Microsoft SAML SSO, so the only credential
available is a session cookie the user establishes by hand in a `WKWebView` — Microsoft's
own page, MFA and all. Details and traps in [`docs/CANVAS.md`](docs/CANVAS.md).

### Why two transcriptions

Apple's live model is instant but not verbatim. On a real lecture it turned "textbook" into
"tax work" and "red spheres" into "Red Spears" — good enough to prove the mic is working,
not good enough to study from. It is a preview and a fallback, never the final text.
[`docs/SPEECH-API.md`](docs/SPEECH-API.md) covers the macOS 26 `SpeechAnalyzer` pipeline and
the five gotchas that cost the most time.

That fallback is where the project's one real design rule came from. An encoding bug on the
Node→Python boundary once made the server quietly serve Apple's draft instead of whisper's
output, and nothing looked broken. So every note now carries `transcriptSource` and the app
shows a "rough" badge; an expired Canvas session surfaces as `expiredAt` and an orange
banner rather than "no new materials". Any fallback that degrades quality has to be visible.

### When a device is offline

This is a three-device system on a laptop that leaves the building, so most of the design
budget went here.

- **PC asleep or off the tailnet.** The Mac writes each recording to a durable outbox
  *before* attempting the upload, retries the queue every 20 seconds, and shows a "PC
  offline" pill with the pending count.
- **Mac closed mid-note.** Nothing is discarded server-side: the payload stays in `inbox/`
  until the note is `ready`, the audio in `Audio/`, the transcript in `Transcripts/`.
  `POST /api/note/{id}/reprocess` re-runs the Claude pass on what's there.
- **SSE drops.** The client reconnects with exponential backoff to 30 s and re-syncs the
  index on every reattach. It parses raw bytes rather than `AsyncBytes.lines`, because
  `.lines` drops empty lines and the blank line is what terminates an SSE event.
- **Server dies.** A Windows scheduled task relaunches it at logon and re-checks every two
  minutes; `run-server.cmd` exits immediately if the port is already listening.
- **whisper or Claude fails.** whisper failing falls back to the draft, badged. Claude
  failing marks the note `failed` with the error and leaves everything on disk. A one-line
  phone capture that fails classification is filed verbatim as a todo rather than dropped.

The link between the two machines is DERP-relayed rather than direct — the PC sits behind a
campus symmetric NAT that Tailscale can't hole-punch — so it's ~1.6 MB/s at ~50 ms RTT.
That's why responses over 4 KB are gzipped, why the phone sends text and not audio, and why
"only text crosses the network" is a rule rather than a preference.

## Build and install

Prerequisites that genuinely matter: macOS 26 and Xcode 26 (`SpeechAnalyzer` does not exist
before macOS 26), an NVIDIA GPU with ~5 GB free for large-v3 in float16, Node on the PC, and
Tailscale on all three devices with `ssh pc` working.

```bash
# Mac app
cd mac && ./build.sh                 # -> ~/Library/Caches/notables-build/Notables.app
../scripts/install-mac-app.sh        # copies to /Applications, starts it at login

# PC, one time: whisper venv, CUDA wheels, large-v3 pre-download
./scripts/install-whisper.sh

# PC: deploy the server, install the scheduled task + firewall rule, health-check
./scripts/deploy-server.sh --install
```

The two machines share a bearer token. Generate one with `openssl rand -hex 24` and write
the same value to `~/.notables/token` on the Mac and `%USERPROFILE%\.notables\token` on the
PC. The server re-reads it every ten seconds, so rotating it needs no restart. The firewall
rule only admits `100.64.0.0/10`, so the port is reachable from the tailnet and nowhere else.

The PC's tailnet address goes in `notables.local` at the repo root
(`NOTABLES_PC_HOST=<pc-ip>`). It is gitignored; `build.sh`, `deploy-server.sh` and the MCP
bridge read it.

First launch asks for microphone access. Transcription is on-device — nothing goes to Apple.

## Using it

**⌘R**, or the menu bar icon → *Record a Class*. The name you type is a strong hint to both
the course guesser and the filing pass, so "Chem 101 — Thermo" files better than "recording
3". Press **Stop & File Note** and it queues to disk, then uploads. Or hold the iPhone
Action Button and say "chem homework problems 12 to 20 due friday" to put a dated item
straight into the vault.

## Where things live

| | |
|---|---|
| Audio (Mac's own copy) | `~/Documents/Notables/Recordings/*.m4a` |
| Pending uploads (Mac) | `~/Library/Application Support/Notables/Outbox/` |
| Shared token | `~/.notables/token` (Mac), `%USERPROFILE%\.notables\token` (PC) |
| Canvas session cookie | `%USERPROFILE%\.notables\canvas-session.json`, mode 0600, never logged |
| Note vault (PC) | `C:\Users\Kieran\Notables` |

The vault is plain Markdown with YAML front matter — `Notes/<Course>/<date> — <Topic>.md`,
the transcript beside it in `Transcripts/`, whisper's segment timestamps as a JSON sidecar.
`_index.json` is a derived cache; `POST /api/reindex` rebuilds it from the files. Obsidian
reads it, `grep` reads it, and it outlives this project.

## Troubleshooting

**"PC offline" in the sidebar** — the PC is asleep or off the tailnet. Check `tailscale
status`, then `curl http://<pc-ip>:8787/api/health`. Recordings keep queuing locally; the footer shows
how many are waiting.

**Nothing transcribed** — wrong input device. The recorder shows a live level meter; if it
never moves, check System Settings › Sound.

**A note stuck on "transcribing"** — whisper is working, or CUDA fell back to CPU. The
realtime factor is in `logs/server.log`; an hour of audio should take minutes, not an hour.

**A note says "failed"** — the Claude pass failed, but the transcript is safe on both
machines. Open the note and press **Retry**, or `POST /api/note/{id}/reprocess`.

## Status

Working and in daily use on my own hardware, which is also the honest limit of it. Measured
on a real 45-minute lecture: 5 min 43 s end to end, of which whisper was 290 s at 9.44×
realtime and the Claude pass 56 s.

What it is not:

- **Not portable as-is.** `C:\Users\Kieran\...` paths and one Canvas host are baked into
  the defaults. Everything is env-overridable, but it has never run on anyone else's
  hardware.
- **Single user, single shared secret.** One bearer token over plain HTTP, with Tailscale
  doing the encryption. Fine for three of my own devices; not an auth model.
- **No tests, no CI.** Verification has been running it against the live server and reading
  the logs.
- **Serial by design.** One job at a time — whisper wants the whole GPU — so a queued
  lecture waits for the one ahead of it.
- **The Canvas integration is tied to one institution's quirks.** Session-cookie auth exists
  because student API tokens are disabled there; a normal Canvas deployment wants a token.

`bench/` — model weights, a venv, synthetic test clips and a real class recording used for
the accuracy comparison — is deliberately not in this repo. It's 2.7 GB, and the recording is
other people's voices.
