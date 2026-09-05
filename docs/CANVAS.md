# Canvas integration

Pulls each course's **module files** — slide decks, handouts, problem sets — out of
Canvas onto the PC, extracts their text, and feeds that text back into the two
places it makes the pipeline measurably better:

1. **whisper's `initial_prompt`**, so the transcriber knows the course's vocabulary
   *before* the first lecture is ever recorded (see "Why this matters" below);
2. **the vault**, as greppable text beside each original file.

Host: `franciscan.instructure.com`. Vault location: `Course Materials/<Course>/`.

---

## 1. Why the auth is strange

Franciscan's Canvas:

- has **student-generated access tokens disabled** — Account → Settings has no
  "+ New Access Token" button; and
- authenticates through **Microsoft SAML SSO** (`/login` → `/login/saml`).

So the two normal integration paths are both closed: no API token, and no password
flow we could ever automate (MFA, redirect chains, and we should not be holding a
university password regardless).

What *is* available: Canvas's own web UI drives `/api/v1` with the **session
cookie**, and Canvas honours that cookie for `GET`s from anywhere. So:

> Kieran signs in by hand, in a real `WKWebView` inside the Mac app — Microsoft's
> own page, MFA and all. The app never sees the password. It harvests only the
> resulting Canvas cookie and hands it to the PC, which uses it for read-only
> `GET`s.

`mac/Sources/Notables/CanvasAuth.swift` → `POST /api/canvas/session` → stored at
`%USERPROFILE%\.notables\canvas-session.json` (mode 0600, **never** in the vault,
**never** logged).

### The cookie expires, and that must be loud

A dead session returns 401 — or, on some routes, an HTML login page with a 200,
which is why `canvas.js` treats a non-JSON body as expiry too. Either way it is
recorded as `expiredAt` and surfaced:

- `GET /api/canvas/status` → `expiredAt`
- SSE `canvas` event
- an orange **"Canvas needs reconnecting"** banner in the Mac sidebar
- the scheduled sync **stops** rather than retrying in a loop

This is deliberate and follows the rule the project learned the hard way with the
whisper draft fallback: *an expired session looks exactly like "no new materials"
unless you make it look like something else.*

A rejected cookie is never stored. `POST /api/canvas/session` verifies against
`/api/v1/users/self` first and discards anything that fails, so a "connected"
state always means a session that genuinely worked.

---

## 2. How files are found

Instructors build courses three different ways, and students often have the Files
tab locked, so all three routes are walked (`server/lib/materials.js`):

| Route | Typical case |
|---|---|
| module items of type `File` | the common one |
| file links scraped out of `Page` / `Assignment` / `Quiz` / `Discussion` bodies reached from module items | very common — the file is only linked, never added as an item |
| the course **Files** tab | catches unlinked uploads; frequently `403` for students, which is **not** an error |

`ExternalUrl` / `ExternalTool` items are recorded as links, not downloaded.

A file linked from two modules is stored **once** (these are 20MB decks) with the
other module names recorded in `alsoIn`.

Modules whose item list Canvas omits (large modules) are re-fetched via `items_url`.

---

## 3. Text extraction

`server/python/extract.py`, run in the same venv as whisper.

| Format | Method | Dependency |
|---|---|---|
| PDF (text layer) | `pypdf` | `pypdf` |
| PDF (**scanned**) | render with `pypdfium2`, read with RapidOCR/onnxruntime | `pypdfium2`, `rapidocr-onnxruntime` |
| PPTX / PPT | `zipfile` + XML, slides **and speaker notes** | stdlib |
| DOCX | `zipfile` + XML, paragraph-aware | stdlib |
| HTML / TXT / MD / CSV | direct, full entity decoding | stdlib |

Install: `scripts/install-whisper.sh` handles all three wheels. None needs an
external binary. Without them, PDFs report `extraction failed` in the UI and index
rather than silently yielding nothing.

### OCR for scanned PDFs

Franciscan's courses do contain scans — the Gen Chem Lab safety document is one.
When a PDF's text layer yields fewer than ~25 characters per page, `extract.py`
renders each page at 200 dpi and reads it, keeping whichever result says more (so a
mostly-digital PDF with one scanned insert keeps its real text layer).

- ~7 s per page on the CPU, so it is a **fallback only** and capped at
  `OCR_MAX_PAGES` (40). A truncated run says so in the text.
- Measured: the 2-page Flinn safety scan → 4,229 characters, correct down to the
  em dashes.
- OCR text is labelled everywhere it surfaces — an `OCR` pill in the Mac app, a
  banner above the text, `**(OCR — may contain recognition errors)**` in `_Index.md`,
  and an `(OCR, may contain recognition errors)` marker on the sample handed to the
  glossary pass, so garbled tokens are not learned as course vocabulary.

**A file that produced no text is not "done" just because it is unchanged.** When a
new extraction capability lands, `syncFile` re-extracts it *in place* from the copy
already in the vault — no re-download — and then sets `ocrAttempted` so a genuinely
unreadable document is not re-OCR'd on every sync.

Measured: the 23MB, 1141-page McQuarrie *General Chemistry* extracts in **15s** to
2.7M characters.

### Two traps this code exists to avoid

**Pure-ASCII paths across the Node→Python boundary.** Canvas display names are full
of em dashes and smart quotes (`Lecture 1 — Intro (Fall '26).pptx`). Node downloads
to `tmp/canvas-<fileid>.<ext>`, Python only ever sees that, and **Node alone**
renames into the vault. This is the same discipline `whisper.js` uses, for the same
reason — see the em-dash entry in `CLAUDE.md`. The syllabus follows it too, because
a *course name* can carry an accent just as a filename can.

**Library chatter is not protocol.** `pypdf` logs font warnings freely, and this
script's stdout *is* the JSON protocol. `extract.py` redirects stdout to stderr
during extraction, so a chatty PDF cannot corrupt the result.

**An `ok` that produced no text is reported as a gap**, not stored as an empty
file — that is a scanned document, and the `_Index.md` "Not captured" section and
the Mac UI both say so.

---

## 4. Why this matters: whisper's cold start

The glossary that biases whisper used to be built **only** from the key terms of
previous notes in that course. So the *first* lecture of every course — exactly
when the jargon is newest and most likely to be misheard — got no biasing at all.

Canvas fixes that. After a sync, a Claude pass (`buildGlossaryPrompt`) reads the
syllabus and the course's small, current documents — plus a 15k head slice of any
large reference, because the front of a textbook is its table of contents, which is
a dense list of exactly the right terms — and returns 30–60 spoken-vocabulary terms.

Verified against the real McQuarrie textbook: 23s, 52 terms, including
`enthalpy of formation`, `Hess's Law`, `VSEPR theory`, `stoichiometric coefficients`,
`Le Chatelier`. These are precisely the words a general-purpose recogniser gets
wrong.

The glossary pass runs **on the same serial queue** as transcription, so it can
never contend with a lecture being processed.

> `whisper` truncates `initial_prompt` to its last 224 tokens.
> `buildInitialPrompt` budgets the **whole** prompt against
> `GLOSSARY_PROMPT_CHARS`, not just the term list — an earlier version measured
> only the list and overflowed to 754/700 chars, which silently dropped terms off
> the front.

---

## 5. Course mapping

Canvas courses are matched to vault course names by, in order:

1. an existing `canvas.id` link in `_courses.json`;
2. token overlap ≥ 0.5 against an unclaimed vault course name;
3. otherwise a **new** course named from Canvas.

The decision is always reported as `matchedBy` (`canvasId` / `name` / `created`)
rather than made quietly, because a wrong match scatters a course's notes and
materials across two folders. A near-miss is reported as `suggested` and left for
a human — the sync will not merge courses on its own.

---

## 6. Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/api/canvas/status` | connection state, user, `expiredAt` |
| `POST` | `/api/canvas/session` | store a harvested cookie (verifies first) |
| `POST` | `/api/canvas/disconnect` | forget the session |
| `GET`  | `/api/canvas/probe` | diagnostic: what does this account actually expose? |
| `POST` | `/api/canvas/sync` | `{full?, courseIds?, reglossary?}` — returns `202`, progress over SSE |
| `GET`  | `/api/materials` | per-course summary |
| `GET`  | `/api/materials?course=X` | full manifest |
| `GET`  | `/api/material?course=X&id=FID` | one file's extracted text + metadata |
| `GET`  | `/api/material/file?course=X&id=FID` | the **raw bytes** of the file |

SSE event `canvas` carries sync progress, glossary results, and expiry.

Scheduled sync: 30s after server start, then every `CANVAS_SYNC_INTERVAL_MS`
(default 6h). Skipped entirely while the session is expired.

**`/api/canvas/probe` is the first thing to run when something looks wrong** — it
reports, per course, how many modules / files / assignments / pages / announcements
are readable and which ones return `CANVAS_FORBIDDEN`.

---

## 7. On disk

```
Course Materials/
  General Chemistry I/
    _canvas.json                  manifest: file ids, updated_at, sizes, extract state
    _Index.md                     human/Obsidian index, incl. a "Not captured" section
    Syllabus.html / Syllabus.txt
    01 Module 1 — Matter & Measurement/
      Lecture 1 — Intro (Fall '26).pptx
      Lecture 1 — Intro (Fall '26).pptx.txt
```

Text sidecars are `<original name>.txt` — deliberately not `<base>.txt`, so a
`Lecture.pdf` and a `Lecture.pptx` in the same module cannot collide.

Re-sync is incremental: `updated_at` + `size` + "the file is still on disk". Only
changed files are re-downloaded, and the glossary pass only runs when something
actually changed.

---

## 8. Reading the files on the Mac

`/api/material/file` streams the original bytes with its real content type. The Mac
caches the file under `~/Library/Caches/Notables/materials/<id>-<updated_at>.<ext>`
— keyed by the sync stamp, so a re-synced file re-downloads and an unchanged one
opens instantly — and renders it:

- **PDF** → PDFKit (`PDFView`), with real page navigation, selection and search.
- **DOCX / PPTX / everything else** → QuickLook (`QLPreviewView`), the same
  previewer Finder uses, so the Office formats work without this app carrying a
  parser for them.

A segmented **Document / Text** control switches between the real file and the
extracted text, and the overflow menu offers *Open in Default App*, *Reveal in
Finder*, and *Open in Canvas*.

The served path is looked up in the manifest **by file id** and checked to resolve
inside the vault, so nothing in the query string can reach the filesystem.
