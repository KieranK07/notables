# Notables Quick Capture — iPhone setup

Press the Action Button, say *"chem homework problems 12 to 20 due friday"*, and it lands
in the vault on the PC as a homework item with the right course and due date. No app, no
taps, no confirmation screen.

This guide builds the Shortcut by hand. It takes about ten minutes. **There is no
`.shortcut` file to import** — see [Why there is no importable file](#why-there-is-no-importable-file)
at the bottom for the honest reason.

---

## Before you start

| | |
|---|---|
| **Tailscale on the iPhone** | Install *Tailscale* from the App Store, sign in with the same account as the Mac and PC, and make sure the VPN toggle is **on**. The PC's tailnet IP (written `<pc-ip>` below; the Tailscale app lists it) is only reachable over Tailscale. |
| **The PC is awake** | The note server runs on the Windows PC. If the PC is asleep, capture fails. |
| **The token** | The shared secret the server checks on every request. Read yours with `cat ~/.notables/token` on the Mac; it must be byte-identical to `%USERPROFILE%\.notables\token` on the PC. If neither exists yet, make one — `openssl rand -hex 24` — and write the same string to both files. Below it is written as `<YOUR_NOTE_SERVER_TOKEN>`; substitute the real value. |

> ⚠️ **That token is a write key to your note vault.** Anyone holding it can add and read
> notes. Don't share the shortcut, don't screenshot the Headers field, don't post it. If it
> ever leaks, change `~/.notables/token` on the Mac and `%USERPROFILE%\.notables\token` on
> the PC (they must match), then edit the header in this shortcut.

**Quick reachability test before you build anything.** In Safari on the iPhone, open:

```
http://<pc-ip>:8787/api/health
```

You should get a line of JSON starting `{"ok":true,...}`. If Safari can't connect, fix
Tailscale or wake the PC first — the shortcut cannot work until this does.

---

## Part 1 — Build the shortcut

Open **Shortcuts** → the **Shortcuts** tab → **+** (top right) to create a new one.

For every step below: tap the search field at the bottom (**"Search for apps and actions"**),
type the action name, and tap the result. Actions are appended in order — build them top to
bottom and don't reorder.

### 1. Dictate Text

1. Search `Dictate` → tap **Dictate Text**.
2. Tap the expand arrow (**⌄**) on the action to show its options.
3. **Language** → *English (US)*. (Leaving it on the default is fine too.)
4. **Stop Listening** → **After Pause**.
   - *After Pause* is the safe default: it waits for a real silence, so it won't cut you off
     mid-sentence.
   - If it feels sluggish, switch to **After Short Pause**.
   - If you want to dictate several sentences, choose **On Tap** and tap Stop when finished.

This action outputs a variable called **Dictated Text**. You'll use it twice.

### 2. Date

1. Search `Date` → tap the plain **Date** action (it's in the *Date* category and displays as
   **Current Date** once added).

### 3. Format Date

1. Search `Format Date` → tap **Format Date**. It should already read
   *Format **Current Date*** — if its input is empty, tap the input and pick **Current Date**.
2. Tap **Date Format** → choose **ISO 8601**.
3. Make sure the time is included (the action shows an **Include Time** toggle, or an
   *ISO 8601 Format* picker where you choose **Date and Time**). Turn it on.

The output looks like `2026-09-04T12:34:05-04:00`. The server parses that exact form —
this was tested against the live server. This action outputs **Formatted Date**.

### 4. Get Contents of URL

This is the action that does the work.

1. Search `Get Contents of URL` → tap it.
2. In the **URL** field type exactly:
   ```
   http://<pc-ip>:8787/api/capture
   ```
   (`http`, not `https`. Tailscale is the encryption layer here.)
3. Tap the expand arrow (**⌄**) to reveal *Method*, *Headers*, and *Request Body*.
4. **Method** → **POST**.
5. **Headers** → tap **Add new field**:
   - **Key**: `Authorization`
   - **Text**: `Bearer <YOUR_NOTE_SERVER_TOKEN>`

   One space after `Bearer`. No quotes. No trailing space — it's easy to add one when you
   paste, and the server will reject it with `unauthorized`.

   You do **not** need a `Content-Type` header; Shortcuts sets it automatically once you
   pick a JSON body below.
6. **Request Body** → **JSON**.
7. Tap **Add new field** four times, choosing type **Text** each time, and fill in:

   | Key | Value |
   |---|---|
   | `text` | the **Dictated Text** variable (see below) |
   | `kind` | `auto` |
   | `capturedAt` | the **Formatted Date** variable |
   | `device` | `iphone-17-pro` |

   **To insert a variable:** tap into the value box, then tap the variable chip (e.g.
   **Dictated Text**) in the strip just above the keyboard. If it isn't offered, tap the
   variable/**Shortcut Input** button at the right end of that strip and pick
   *Dictate Text → Dictated Text*.

   Keys are case-sensitive: `capturedAt`, not `capturedat`.

When you're done, the body you're sending is:

```json
{
  "text": "chem homework problems 12 to 20 due friday",
  "kind": "auto",
  "capturedAt": "2026-09-04T12:34:05-04:00",
  "device": "iphone-17-pro"
}
```

`"kind": "auto"` is deliberate — the server asks Claude to decide between **todo**,
**homework** and **note**, and it already knows your course list. Don't try to classify on
the phone.

### 5. Get Dictionary Value

The server replies `{"ok":true,"id":"…","state":"queued"}` on success. We check `state`.

1. Search `Dictionary` → tap **Get Dictionary Value**. (Some iOS versions list it as
   **Get Value for Key**; it's the same action — the one that reads *Get **Value** for
   **key** in **Dictionary***.)
2. Set **Get** → **Value** (the default), **for** → type `state`.
3. Its **in** input should already be **Contents of URL**. If not, tap it and choose
   **Contents of URL**.

### 6. If / Otherwise

1. Search `If` → tap **If**. Shortcuts inserts **If**, **Otherwise** and **End If** together.
2. Tap the **If** input and choose the **Dictionary Value** variable.
3. Condition → **is**. Value → `queued`.

### 7. Success notification (inside **If**)

1. With the cursor between **If** and **Otherwise**, search `Show Notification` → tap it.
   If it lands in the wrong place, drag it by its handle so it sits between **If** and
   **Otherwise**.
2. In the notification text field type `Captured: ` and then insert the **Dictated Text**
   variable.
3. If the action has a separate **Title** field (expand with **⌄**), set it to `Notables`.

### 8. Failure notification (inside **Otherwise**)

1. Add another **Show Notification**, and drag it so it sits between **Otherwise** and
   **End If**.
2. Text: type `NOT captured — ` and then insert the **Contents of URL** variable. That
   prints the server's own error, e.g. `{"ok":false,"error":"unauthorized"}`, which tells
   you exactly what went wrong.
3. Expand it and turn **Sound** **on**, so a failure is impossible to miss when the phone is
   in your pocket.
4. Optional: add a **Vibrate Device** action right after it.

### The finished shortcut

```
Dictate Text                          (Stop Listening: After Pause)
Date
Format Date                           (ISO 8601, with time)
Get Contents of URL                   POST http://<pc-ip>:8787/api/capture
                                      Headers:  Authorization: Bearer <token>
                                      JSON body: text / kind / capturedAt / device
Get Dictionary Value  "state"  in  Contents of URL
If  Dictionary Value  is  "queued"
    Show Notification  "Captured: <Dictated Text>"
Otherwise
    Show Notification  "NOT captured — <Contents of URL>"   (sound on)
End If
```

Eight actions. Runs in about a second once you stop speaking.

---

## Part 2 — Name and icon

1. Tap the shortcut's name at the top of the editor (or the **ⓘ** / *Details*).
2. **Rename** it to **Notables Capture**. Use exactly this name — you'll pick it by name in
   Settings.
3. **Choose Icon** → pick something you'll recognise (a microphone glyph, red).
4. In *Details*, leave **Show When Run** **on**. Dictate Text needs its listening UI on
   screen; turning this off can leave you speaking into nothing.
5. **Done**.

---

## Part 3 — Assign it to the Action Button

1. **Settings** → **Action Button**.
2. Swipe the carousel to **Shortcut**.
3. Tap **Choose a Shortcut** (the picker below the illustration).
4. Select **Notables Capture**.
5. Back out of Settings.

Press and hold the Action Button to fire it.

---

## Part 4 — The first run (permission prompts)

The first run is the slow one. iOS will ask, roughly in this order:

1. **Speech recognition / microphone** — allow it. Dictate Text needs both.
2. **"Notables Capture" wants to send data to <pc-ip>** — tap **Allow**, or
   **Always Allow** if offered, so it stops asking.

Answer these once and subsequent runs are silent. Do the first run somewhere you can look at
the screen, not walking out of a lecture.

---

## Part 5 — Test it

1. Hold the Action Button, say: **"chem homework problems 12 to 20 due friday"**.
2. Within a second you should get a banner: **Captured: chem homework problems 12 to 20 due friday**.
3. Give the PC ~10 seconds to run the Claude pass, then check it landed. Any of:
   - the Mac app's todo list (it's live over SSE and updates itself), or
   - on the PC, `C:\Users\Kieran\Notables\Captures\2026-09.md`, or
   - from the Mac:
     ```sh
     curl -s http://<pc-ip>:8787/api/notes \
       -H "Authorization: Bearer $(cat ~/.notables/token)" | python3 -m json.tool
     ```

A capture of that exact sentence was run against the live server while writing this guide
and filed as:

```markdown
## 2026-09-04 16:34:05Z — homework
*course: Chemistry 101 · due: 2026-09-11 · id: 46dd777b-…*

- [ ] Do problems 12-20 in chemistry  (due 2026-09-11)

> chem homework problems 12 to 20 due friday
```

Note what the server did on its own: picked **homework**, matched the existing course
**Chemistry 101**, resolved *"friday"* to a real date, and cleaned the wording — while
keeping your raw sentence underneath. That's why the phone sends `"kind":"auto"` and no
parsing.

If it didn't work, see **[README.md](README.md) → Troubleshooting**.

---

## Optional extras

**A note-only version.** `auto` occasionally calls something a todo when you meant a note.
Duplicate the shortcut (long-press → *Duplicate*), rename it *Notables Note*, and change the
`kind` field from `auto` to `note`. Put that one in Control Center or on the Home Screen —
the Action Button only holds one shortcut.

**Skipping the timestamp.** If you'd rather have six actions than eight, delete **Date** and
**Format Date** and drop the `capturedAt` field. The server timestamps the capture on
arrival instead. You lose accuracy only if you capture something while Tailscale is down and
retry later.

**Hearing what it filed it as.** The `202` reply comes back *before* Claude classifies, so
the confirmation banner can only say "captured", never "filed as homework". Getting the
classification onto the phone means waiting ~10 s and polling `GET /api/notes` for the todo
whose `source` is `capture:<id>` (the id is in the POST response) — about eight more actions
and a ten-second wait, for information the Mac app shows you live anyway. Not recommended.

---

## Why there is no importable file

Shortcuts are binary-plist files (`WFWorkflowActions`) and iOS will import an unsigned one
when *Allow Untrusted Shortcuts* is enabled, so generating one looked plausible. It was
investigated properly and rejected:

- A `.shortcut` file **can** be generated and **can** be signed on the Mac with
  `shortcuts sign --mode anyone`.
- But `shortcuts sign` validates nothing. It was fed a file whose only action identifier was
  `is.workflow.actions.THIS.DOES.NOT.EXIST`, and a file containing no actions at all — it
  signed both, exit 0. Signing is not evidence the shortcut is correct.
- The exact serialisation for the three actions that matter most here — **Dictate Text**,
  **Show Notification**, and above all **Get Contents of URL** with a POST method, custom
  headers and a JSON body — could not be confirmed against any ground truth. The Shortcuts
  library on the Mac contains real examples of `gettext`, `setvariable`, `conditional` and a
  *GET*-only `downloadurl`, but nothing with `WFHTTPBodyType` / `WFJSONValues` / `WFHTTPHeaders`,
  and the parameter definitions live inside the dyld shared cache rather than in a readable
  plist.
- There is no way to verify an import without a human tapping *Add Shortcut*. `shortcuts`
  has `run`, `list`, `view` and `sign` — no import — and QuickLook wouldn't render the file
  either.

The realistic failure mode wasn't a file that refuses to open; it was one that imports
cleanly with a silently empty Authorization header or an empty request body — captures that
look like they worked and quietly go nowhere. Ten minutes of building it by hand beats
debugging that. Hence: manual guide only.
