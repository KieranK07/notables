# Notables — architecture

A class-recording → transcription → auto-organized-notes system across three devices,
joined by Tailscale. All LLM work runs on Kieran's **Claude subscription** via the
`claude` CLI in headless mode (`claude -p`). **No Anthropic API key, anywhere.**

```
┌─ MacBook Air ────────────────────────────────────────────────────┐
│                                                                  │
│  Notables.app  (SwiftUI, macOS 26)                              │
│   ├─ Record     AVAudioEngine ──► AAC 64kbps mono 16kHz .m4a    │
│   │                            └► SpeechAnalyzer = LIVE PREVIEW  │
│   │                               (fast, but not verbatim-exact) │
│   ├─ Library    SSE-subscribed, updates the instant the PC       │
│   │             finishes a note                                  │
│   └─ Keeps its own copy of every recording                       │
└──────────────────────────┬───────────────────────────────────────┘
                           │ POST /api/ingest  + PUT /api/audio/{id}
                           │ GET  /api/events   (SSE, held open)
                           ▼        Tailscale
┌─ Windows PC ─────────────────────────────────────────────────────┐
│  note-server (Node, zero npm dependencies)                       │
│   ├─ whisper large-v3 on the RTX 3060 Ti  ◄── the real transcript │
│   │    biased with a per-course glossary (initial_prompt)        │
│   ├─ writes the verbatim transcript to disk FIRST (never lost)   │
│   ├─ queue ──► `claude -p` (subscription) ──► JSON               │
│   │            course · section · class date · summary ·         │
│   │            key terms · notes · action items                  │
│   ├─ writes Notes/<Course>/<date> — <Topic>.md                   │
│   └─ pushes an SSE event ──► every connected client              │
│  Vault: %USERPROFILE%\Notables                                   │
└──────────────────────────▲───────────────────────────────────────┘
                           │ POST /api/capture
┌─ iPhone 17 Pro ──────────┴───────────────────────────────────────┐
│  Action Button ──► Shortcut ──► dictate ──► POST                 │
│  "add homework: chem 12-20 due friday"                           │
└──────────────────────────────────────────────────────────────────┘
```

## Why each choice

**Two transcription passes, and only the second one counts.** Apple's on-device
`SpeechAnalyzer` runs live on the Mac while you record — see [SPEECH-API.md](SPEECH-API.md).
Tested against a real lecture it gets the structure right but misses words ("textbook" →
"tax work", "red spheres" → "Red Spears"), which is not good enough for study notes. So it
serves as the **live on-screen preview and a fallback only**. The authoritative transcript
is produced on the PC by **whisper large-v3 on the RTX 3060 Ti**, which is far more accurate
on technical vocabulary and can be biased with a per-course glossary via `initial_prompt`.

**The audio goes to the PC.** ~29 MB for a one-hour class at 64 kbps mono AAC — nothing over
Tailscale, and it means the GPU does the heavy lifting instead of the laptop. The Mac keeps
its own copy under `~/Documents/Notables/Recordings/` so nothing depends on one machine.

**Transcript is written before Claude is called.** If the AI pass fails — rate limit, PC
asleep, bad JSON — the lecture is already safe on disk and the job retries from `inbox/`.

**Markdown files, not a database.** The vault is plain files: greppable, Obsidian-readable,
backed up by anything, and survives this project being deleted. `_index.json` is a
derived cache that can be rebuilt from the files.

**SSE, not WebSockets.** One-way server→client push is all the live-update requirement
needs, and SSE is a few lines over plain HTTP with zero npm dependencies and automatic
browser/URLSession reconnection.

**Zero npm dependencies on the server.** Nothing to install on Windows, nothing to break
on a `npm audit`, and the whole server is auditable in one sitting.

## Measured, on a real 45-minute lecture (2026-09-04)

End to end, audio leaving the Mac to notes appearing in the app: **5 min 43 s.**

| stage | time |
|---|---|
| upload 11 MB over Tailscale | 6 s |
| whisper large-v3, cuda/float16 | 290 s for 2700 s of audio — **9.44× realtime**, 882 segments |
| Claude pass (course, section, summary, key terms, todos) | 56 s |

A one-hour class should therefore land in roughly **7–8 minutes**. The per-course glossary
had accumulated 23 terms by this run and was fed to whisper as `initial_prompt`.

### Why the second pass is worth those minutes
The same lecture, same audio, both transcribers:

| Apple `SpeechAnalyzer` (live, on the Mac) | whisper large-v3 (PC GPU) |
|---|---|
| "in your **tax work** especially" | "in your **textbook** especially" |
| "oxygen is represented as **Red Spears**" | "Oxygen = red … two red spheres joined together" |
| "carbon is black, and **mentioned it is** blue" | "Carbon = black, **Nitrogen** = blue" |
| "hydrogen oxygen, carbon and nitrogen, **orchilos**, or…" | "…noble gases … helium, neon, argon, krypton" |

Apple's pass is genuinely useful as a live "it's capturing" indicator and as a fallback that
keeps a lecture from being lost. It is not something to study from.

## Repo layout
```
mac/         Notables.app — SwiftUI recorder + library (Swift 6, macOS 26)
server/      note-server — authored here on the Mac, deployed to the PC over ssh
ios/         Action Button shortcut + setup guide
docs/        PROTOCOL.md (the contract) · SPEECH-API.md · ARCHITECTURE.md
scripts/     deploy + service-install helpers
```

## Cross-machine access
`ssh pc` is already configured (Tailscale + key auth). **The PC's default shell is
`cmd.exe`, not a POSIX shell** — `;` is not a command separator there, use `&`.
Authoring code on the Mac and `scp`-ing it over beats editing remotely through cmd quoting.

---

## Canvas course materials

A fourth input, alongside the microphone and the phone: the LMS.

```
  Canvas (franciscan.instructure.com)
        │  session cookie, harvested once by hand in the Mac app's WKWebView
        │  (student API tokens are DISABLED; login is Microsoft SAML SSO)
        ▼
  PC  ── walks each course's MODULES ──▶ module-item files
      │                                  + files linked inside Page/Assignment bodies
      │                                  + the Files tab when it isn't locked
      ▼
  download ──▶ extract text (pypdf / zipfile) ──▶ Course Materials/<Course>/
                                                  │
                                                  ├─▶ _Index.md   (browsable, incl. gaps)
                                                  └─▶ Claude glossary pass
                                                          │
                                                          ▼
                                              whisper initial_prompt for the
                                              NEXT recording in that course
```

The point is the last arrow. Before this, the glossary was built only from previous
notes, so a course's first lecture was transcribed with no vocabulary biasing at
all. Canvas supplies the terms before any recording exists.

Full detail — auth, traps, endpoints, on-disk layout — in [CANVAS.md](CANVAS.md).

### Measured

| Step | Cost |
|---|---|
| PDF text extraction (23MB, 1141pp *General Chemistry*) | 15 s → 2.7M chars |
| Claude glossary pass (30k char sample) | 23 s → 52 terms |
| Re-sync with nothing changed | no downloads, no Claude call |
