# Notables Wire Protocol — v1

**This file is the source of truth.** The Mac app, the Windows note server, and the
iOS Shortcut are built by different agents against this contract. Change it here first,
then update every implementation.

## Endpoints

Base URL: `http://<pc-ip>:8787` (Windows PC over Tailscale; `<pc-ip>` is its tailnet
address, kept in the gitignored `notables.local` as `NOTABLES_PC_HOST`)
Auth: `Authorization: Bearer <token>` on every request. Token lives in
`~/.notables/token` on the Mac and `%USERPROFILE%\.notables\token` on the PC.

### `POST /api/ingest` — announce a finished recording (step 1 of 2)
The Mac uploads the **audio**; the PC does the authoritative transcription on its GPU.
```jsonc
{
  "id":          "0F8C…",         // UUID, client-generated, idempotency key
  "title":       "Chem 101 - Thermo",  // the filename the user typed
  "recordedAt":  "2026-09-04T13:05:00Z",       // ISO8601 UTC, recording START
  "durationSec": 3312,
  "locale":      "en_US",
  "device":      "macbook-air",
  "audioBytes":  29344512,        // so the server can verify the upload completed
  "audioFormat": "m4a",           // AAC, 16 kHz mono
  "draftTranscript": "Welcome to Chemistry 101…"  // the Mac's live on-device pass
}
```
→ `202 {"ok":true,"id":"0F8C…","state":"awaiting_audio"}`

`draftTranscript` is Apple's fast on-device result. It is **a preview and a fallback, never
the final text** — the app shows it immediately so a note isn't blank while the GPU works,
and the server falls back to it if whisper fails outright. Re-POSTing the same `id` is a
no-op returning the current state.

### `PUT /api/audio/{id}` — the recording itself (step 2 of 2)
Raw body, `Content-Type: audio/mp4`. No multipart — the server is Node stdlib.
Server writes it to `Audio/`, verifies the length against `audioBytes`, then queues
transcription. → `202 {"ok":true,"state":"transcribing"}`

Resumable: `GET /api/audio/{id}/status` →
```jsonc
{ "received": 12345678, "expected": 29344512,
  "complete": true,          // the bytes are on the PC under their final name
  "state": "ready",
  "safeToDelete": true,      // complete AND state=ready - see below
  "notePath": "Notes/Chemistry 101/2026-09-07 — Isotopes.md",
  "transcriptPath": "Transcripts/Chemistry 101/2026-09-07 — Isotopes.txt" }
```
The Mac may retry the PUT from scratch; the server overwrites.

### `GET /api/audio/{id}` — the recording back again
Returns `audio/mp4`. Supports `Range` (`206` + `Content-Range`, `416` when unsatisfiable)
and `HEAD`, so a player can seek without refetching a 45-minute lecture. `404` while the
audio has not been uploaded, or after it has been removed from the PC.

## Who keeps the audio

The Mac records to `~/Documents/Notables/Recordings/<id>.m4a` and **keeps that file until
the PC confirms it no longer needs to**. That confirmation is `safeToDelete`, and it is
deliberately stricter than "the upload finished":

| condition | why it is in the flag |
|---|---|
| `complete` — final-name file on the PC, byte count matches `audioBytes` | a `.part` file is not a recording |
| `state == "ready"` | at `ready` the whisper transcript **and** the markdown note are also on disk, so the audio has stopped being the only copy of the lecture |

Only the server sets this. **The Mac must never infer it** from an SSE `note` event or from
its own upload succeeding — it asks, and deletes only on `safeToDelete: true`. Everything
after that point streams from `GET /api/audio/{id}`.

This is a deliberate move from two copies to one, taken so a term of lectures does not sit
on a laptop SSD. The PC is now the only machine holding audio.

### `POST /api/capture` — quick voice capture (iPhone Action Button)
```jsonc
{ "text":"remind me chem problems 12 to 20 are due friday",
  "kind":"auto",            // auto | todo | homework | note
  "capturedAt":"2026-09-04T18:22:00Z", "device":"iphone-17-pro",
  "id":"…" }                // OPTIONAL — server mints one when absent
```
→ `202 {"ok":true,"id":"…","state":"queued"}`
`auto` lets Claude decide between todo / homework / note and file it accordingly.

**`id` must stay optional here.** Unlike `/api/ingest`, this endpoint is called from an iOS
Shortcut, and **Shortcuts has no UUID generator** — the client genuinely cannot supply one.
The server mints an id and returns it. Verified behaviour, not an aspiration.

`capturedAt` arrives as ISO 8601 with a **UTC offset** (`…T11:34:05-05:00`), which is what
Shortcuts emits — not a `Z` suffix. The server normalises it.

The `202` returns **before** classification finishes, so the caller learns the item was
accepted, never what it was filed as. That is deliberate: the phone gets an instant
confirmation and the Mac app shows the classified result over SSE moments later.

### `GET /api/notes` — the index
```jsonc
{ "courses":[{"name":"Chemistry 101","noteCount":12,"lastClass":"2026-09-04"}],
  "notes":[{ "id","title","course","section","topic","classDate","recordedAt",
             "durationSec","state","tags":[],"summary","actionItemCount",
             "notePath","transcriptPath","updatedAt" }],
  "todos":[{ "id","text","due","course","done","source" }] }
```

### The MCP listener — a **second port**, publicly reachable
`POST http://<host>:8788/mcp/<secret>` — MCP Streamable HTTP, JSON-RPC 2.0, stateless.
Defined in `server/lib/mcp.js`; carried by the stdio bridge in `mcp/` and by
`https://notables.chadnerd.lol/mcp/<secret>` through the PC's Cloudflare tunnel.

**This port is on the public internet and `8787` is not.** That is the whole reason it is
a separate listener: it serves exactly one route, refuses `GET`, and holds its own secret
in `~/.notables/mcp-token`. Never move `/api/*` onto it, and never point the tunnel at
`8787` — a `DELETE /api/note/{id}` reachable from the internet loses a lecture.

### `GET /api/search?q=&course=&kind=&limit=&regex=` — full text across the vault
```jsonc
{ "ok":true, "query":"relational algebra", "scanned":93, "matched":14, "truncated":false,
  "results":[{ "ref":"material:DB & Information Processing Systems/1851757",
               "kind":"material", "course":"…", "title":"CSCSFE261Fall2026Mod2.pdf",
               "module":"02 Course Content", "chars":44834, "hits":57,
               "snippets":["…Module #2 Relational Algebra Dates: 7 and 9 Septe…"],
               "supersedes":["material:…/1843314"] }] }
```
`kind` is a comma-separated subset of `material,note,transcript` (default: all three).
Runs on the PC because that is where the files are — the link is a DERP relay, so
snippets cross it, never corpora. Results are **deduplicated by path**: a Canvas file
re-uploaded under the same name has several ids pointing at one file on disk, and only
the newest is really there. The superseded refs are reported, not hidden.

### `GET /api/documents?course=&kind=&name=&module=&limit=` — browse refs, no text
### `GET /api/document?ref=` — the full text behind any ref
Refs are `material:<course>/<canvasFileId>`, `note:<noteId>` or `transcript:<noteId>`.

### `GET /api/vault/status` — what is on disk and what looks wrong with it
Per-course counts, `lastSync`, and `needsAttention: { extractFailures, pathCollisions }`.
This is the "does anything need resyncing?" answer.

### `GET /api/note/{id}` → `{ …meta, "markdown":"…", "transcript":"…" }`
### `PATCH /api/note/{id}` — rename a note
```jsonc
{ "title": "csc261 9/9" }        // the student's typed title, 1-200 chars
```
→ `200 {"ok":true,"id":"…","title":"csc261 9/9"}`

Renames **only** the typed title. `course`, `topic`, `section` and the dates are Claude's
output and the vault path is derived from them, so a rename never moves a file.

The title is stored in two places and both are written: `_index.json`, and `source_title:`
in the note's front matter — the latter is what makes `rebuildIndex()` lossless, so an
index-only rename would be undone by the next reindex. Broadcasts `note`.

### `DELETE /api/note/{id}` — remove a note and everything derived from it
→ `200 {"ok":true,"id":"…","removed":["Notes/…","Transcripts/…","Audio/….m4a"]}`

Deletes for real and without an undo: the markdown, the transcript and its whisper
sidecar, the audio, the inbox payload, and every todo whose `source` is `note:{id}`.
Clients must confirm with the user first.

`409` while the pipeline holds the note — deleting the audio out from under a running
whisper job turns a clean outcome into a confusing one. `404` for an unknown id.
Broadcasts `note-deleted` so other clients drop it too.
### `GET /api/events` — Server-Sent Events, the live-update channel
```
event: note         data: {…note object…}     // created or updated
event: note-deleted data: {"id":"…"}           // gone from the vault, drop it
event: state    data: {"id":"…","state":"processing","detail":"asking claude"}
event: todos    data: {"todos":[…]}
: keepalive                                // every 20s
```
## Scoped Claude conversations

A chat is an ordinary `claude` CLI session whose **working directory is the scope** — a
course folder, one chapter folder, or the folder holding one file. Claude reads the
material with its own tools; nothing is pasted into a prompt, chunked, or embedded.

The client never sends a path. It names `{course, module?, fileId?}`, and the server
resolves that against the Canvas manifest and refuses anything landing outside
`Course Materials/`.

### `POST /api/chat` — one turn, streamed
```jsonc
{ "scope": {"course":"Discrete Mathematics","module":"03 Chapter 0"},  // module/fileId optional
  "sessionId": "uuid",            // omit for a new conversation; the client may mint it
  "text": "what does this chapter cover?",
  "attachments": ["C:\\...\\Chats\\<id>\\attachments\\photo.png"] }
```
Responds `application/x-ndjson`, one JSON object per line:
```
{"t":"scope","kind":"module","label":"Chapter 0","model":"claude-sonnet-5"}
{"t":"tool","name":"Grep","detail":"policies.pdf.txt"}
{"t":"delta","text":"Late homework is "}
{"t":"done","sessionId":"…","text":"…","meta":{"durationMs":12455,"turns":4}}
{"t":"error","message":"…"}                 // instead of done
```
**Deliberately not SSE.** That channel has been observed dead for hours with the app
still running (see CLAUDE.md); a chat that silently stops printing is worse than one
that fails. Here the turn owns its response body, so a dropped connection is an error.

Continuation is the CLI's own `--resume`, so context, compaction and history are its
problem, not ours. The client may mint the session UUID so it can attach a photo before
the first turn exists; a malformed one is replaced rather than trusted, since it becomes
a directory name.

### `POST /api/chat/attachment?session={id}&name={filename}` — raw body, one file
→ `{"ok":true,"path":"…","name":"…","bytes":123}`. Pass `path` in the next turn's
`attachments`. Files land beside the session, never in the course folders — a photo of a
homework sheet is not course material, and the next Canvas sync would rightly wonder
what it was doing there. Paths are handed to Claude rather than inlined: it has a Read
tool, and a path costs a few tokens where an inlined photo costs thousands before Claude
has decided whether it needs to look.

### `GET /api/chat/sessions?course=&module=&fileId=` — the resume list, newest first
### `GET /api/chat/session/{id}` — the stored transcript, for redrawing
### `DELETE /api/chat/session/{id}` — drops the transcript and its attachments

Tools are restricted to reads and search (`NOTABLES_CHAT_TOOLS`): a study chat has no
business editing the vault, and a headless session cannot raise a permission prompt to
ask. The model is pinned to `claude-sonnet-5` (`NOTABLES_CHAT_MODEL`).

### `POST /api/note/{id}/reprocess` — re-run the Claude pass on a stored transcript
### `GET  /api/health` → `{"ok":true,"version","vault","queueDepth","claudeOk"}`

## Note lifecycle (`state`)
`awaiting_audio` → `transcribing` → `processing` → `ready`, or → `failed` at any step.
Nothing is ever discarded: the uploaded audio stays in `Audio/`, the whisper transcript is
written to `Transcripts/` **before** Claude is called, and the raw payload stays in
`inbox/` until the note reaches `ready`. Every step is retryable from what's on disk.

## Transcription (on the PC)
`faster-whisper` **large-v3**, float16, CUDA — the PC has an RTX 3060 Ti (8 GB), which fits
the model in ~5 GB and runs roughly 10–20× realtime. Requirements:
- `vad_filter=True` to skip silence, `beam_size=5`.
- **`initial_prompt` is a real accuracy lever and must be used.** Seed it with the course
  name plus technical vocabulary already seen in that course (accumulate a per-course
  glossary in `_courses.json` from previous notes' key terms). This is what makes
  "Le Chatelier", "chemiosmotic" and "cytochrome c oxidase" come out right.
- Keep whisper's own segment timestamps in the transcript file as a sidecar
  (`Transcripts/<Course>/<name>.json`) so a note can be traced back to the audio.

## Vault layout — `%USERPROFILE%\Notables`
```
Notes/<Course>/<YYYY-MM-DD> — <Topic>.md      AI pass (summary, key terms, todos)
Transcripts/<Course>/<YYYY-MM-DD> — <Topic>.txt   full verbatim text (whisper large-v3)
Transcripts/<Course>/<YYYY-MM-DD> — <Topic>.json  whisper segments + timestamps
Audio/<id>.m4a                                 the uploaded recording
Captures/<YYYY-MM>.md                          quick captures from the phone
_index.json      note + todo registry (the thing GET /api/notes serves)
_courses.json    course registry — keeps Claude from inventing near-duplicate courses
inbox/<id>.json  raw ingest payload, deleted once state=ready
logs/server.log
```

## Note front-matter
```yaml
---
id: 0F8C…
title: Second Law of Thermodynamics
course: Chemistry 101
section: "4.3"          # textbook/lecture section, if the lecturer said one; else null
class_date: 2026-09-04  # the DAY OF THE CLASS — notes sort by this
recorded_at: 2026-09-04T13:05:00Z
duration_min: 55
tags: [entropy, gibbs-free-energy]
transcript: ../../Transcripts/Chemistry 101/2026-09-04 — Second Law of Thermodynamics.txt
---
```

## Note body (exactly these sections, in this order)
`# Title` · italic meta line · `## Summary` · `## Key Terms` · `## Notes` ·
`## Action Items` (checkboxes) · `## Full Transcript` (relative link).
Omit `## Action Items` only when there are genuinely none.

---

## Canvas + course materials

Full detail, including why the auth works the way it does, is in
[CANVAS.md](CANVAS.md). Summary of the wire surface:

| Method | Path | Body / query | Returns |
|---|---|---|---|
| `GET`  | `/api/canvas/status` | — | `{ok, canvas:{connected, hasSession, host, user, expiredAt, error}}` |
| `POST` | `/api/canvas/session` | `{host, cookie}` | `{ok, user, status}`; **400 and stores nothing** if Canvas rejects it |
| `POST` | `/api/canvas/disconnect` | — | `{ok, canvas}` |
| `GET`  | `/api/canvas/probe` | — | per-course readability diagnostic |
| `POST` | `/api/canvas/sync` | `{full?, courseIds?, reglossary?}` | `202 {ok, started}` — runs in the background |
| `GET`  | `/api/materials` | — | `{ok, courses:[summary], syncing, lastSync}` |
| `GET`  | `/api/materials` | `?course=NAME` | `{ok, course, materials:<manifest>}` |
| `GET`  | `/api/material` | `?course=NAME&id=FILEID` | `{ok, file, text, canvasUrl}` |
| `GET`/`HEAD` | `/api/material/file` | `?course=NAME&id=FILEID` | the raw file bytes, real `Content-Type` |

`/api/health` gains `canvas` (the status object) and `canvasSync`.

### SSE `canvas` event

Sent on connect/disconnect, during a sync, and when a glossary pass completes:

```json
{"syncing": true, "phase": "files", "course": "General Chemistry I", "done": 3, "total": 11, "item": "Lecture 5"}
{"syncing": false, "connected": true, "lastSync": { }}
{"glossary": {"course": "General Chemistry I", "added": 52, "total": 61}}
```

`expiredAt` on a `canvas` event or in `/api/canvas/status` means **the session is
dead and the user must reconnect**. Clients must show this; treating it as "no new
materials" is the specific failure this field exists to prevent.
