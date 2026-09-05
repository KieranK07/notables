# ios/ — Action Button quick capture

The third leg of Notables. The Mac records lectures, the PC files them, and the iPhone
catches the things that happen *between* classes — "chem homework problems 12 to 20 due
friday" on the way out of the lecture hall.

```
Action Button (hold)
   └─► Shortcut "Notables Capture"
         ├─ Dictate Text            speech→text happens ON THE PHONE
         ├─ POST /api/capture       ~200 bytes of JSON over Tailscale
         └─ banner: Captured / NOT captured
                     │
                     ▼
        note-server on the PC (100.69.103.126:8787)
         ├─ writes inbox/<id>.json immediately  ← never lost
         ├─ claude -p decides todo | homework | note, course, due date
         ├─ appends Captures/<YYYY-MM>.md, registers the todo
         └─ SSE ─► the Mac app's todo list updates live
```

**Build it:** [SETUP.md](SETUP.md). There is no importable `.shortcut` file — SETUP.md
explains why at the bottom.

## Why dictation, not audio upload

The Shortcuts **Dictate Text** action returns text, so the phone does its own
speech-to-text and the request is a couple of hundred bytes. No audio upload, no
server-side transcription path to build, nothing to time out on a bad connection. It also
keeps the architecture's rule intact: only text crosses the network.

## Why `"kind":"auto"`

The server already has the course registry and a Claude pass. A keyword parser on the phone
would be a second, worse classifier that drifts out of sync with the course list. The phone
sends the raw sentence and gets out of the way.

## The request

```
POST http://100.69.103.126:8787/api/capture
Authorization: Bearer <token from ~/.notables/token>
Content-Type: application/json      (set automatically by Shortcuts)

{
  "text":       "chem homework problems 12 to 20 due friday",
  "kind":       "auto",
  "capturedAt": "2026-09-04T12:34:05-04:00",
  "device":     "iphone-17-pro"
}
```

Notes on the fields, against `docs/PROTOCOL.md`:

- **`id` is omitted.** PROTOCOL lists it, but Shortcuts has no UUID generator, and the
  server treats it as optional — it mints one and returns it. Everything downstream
  (`capture:<id>` todo sources, `inbox/<id>.json`) uses the server's id. This is the one
  place where the shortcut can't send exactly what PROTOCOL's example shows.
- **`capturedAt` carries a UTC offset**, not a `Z` suffix, because that's what Shortcuts'
  *Format Date → ISO 8601* produces. Verified accepted: the server normalises it
  (`2026-09-04T12:34:05-04:00` → `2026-09-04T16:34:05Z`). It's also optional — drop it and
  the server stamps arrival time.
- **`kind`** accepts `auto | todo | homework | note`; anything else silently becomes `auto`.

## Verified end to end

Run from the Mac on 2026-09-04 against the live server — byte-for-byte the request the
shortcut sends:

```console
$ curl -s -i -X POST http://100.69.103.126:8787/api/capture \
    -H "Authorization: Bearer $(cat ~/.notables/token)" \
    -H "Content-Type: application/json" \
    -d '{"text":"chem homework problems 12 to 20 due friday","kind":"auto",
         "capturedAt":"2026-09-04T12:34:05-04:00","device":"iphone-17-pro"}'

HTTP/1.1 202 Accepted
X-Notables-Version: 1.0.0
Content-Type: application/json; charset=utf-8

{"ok":true,"id":"46dd777b-4b83-4167-b73d-4f368fcfa9d8","state":"queued"}
```

~10 s later, `C:\Users\Kieran\Notables\Captures\2026-09.md`:

```markdown
## 2026-09-04 16:34:05Z — homework
*course: Chemistry 101 · due: 2026-09-11 · id: 46dd777b-4b83-4167-b73d-4f368fcfa9d8*

- [ ] Do problems 12-20 in chemistry  (due 2026-09-11)

> chem homework problems 12 to 20 due friday
```

and in `GET /api/notes`:

```json
{"id":"4e22a28bdabb1e115b06e03a","text":"Do problems 12-20 in chemistry",
 "due":"2026-09-11","course":"Chemistry 101","done":false,
 "source":"capture:46dd777b-4b83-4167-b73d-4f368fcfa9d8"}
```

Classification, course matching against the existing registry, and "friday" → `2026-09-11`
all came from the server. (That test item is real and still in the vault — tick it off.)

Error responses, also verified live:

| Request | Response |
|---|---|
| valid | `202` `{"ok":true,"id":"…","state":"queued"}` |
| wrong / missing token | `401` `{"ok":false,"error":"unauthorized"}` |
| empty `text` | `400` `{"ok":false,"error":"text is required"}` |
| `GET /api/health` | `200` `{"ok":true,...}` — **unauthenticated**, so it's the cheap reachability probe |

**Not verified:** the shortcut itself. It has never been run — it doesn't exist until Kieran
builds it. What's proven is the server side of the wire and the exact payload shape;
untested are the Shortcuts action fields, the Action Button binding, and how iOS surfaces a
network-level failure (see below).

## Troubleshooting

Work down this list; it's ordered by how often each thing is the culprit.

**Nothing happens / an iOS error banner instead of a notification.**
The POST never completed. `Get Contents of URL` raises its own error on a connection
failure, which stops the shortcut before the `If` ever runs — so an iOS error banner
normally means *couldn't reach the server*, and the shortcut's own `NOT captured` banner
means *the server answered and said no*. (Some iOS versions also raise on a `401`/`4xx`
rather than returning the body; if you get a bare iOS error and `/api/health` in Safari
works fine, treat it as the token case below.) In order:

1. **Tailscale off.** Open Tailscale on the phone, confirm the VPN toggle is on and it shows
   connected. This is the usual answer, especially after a reboot or a flight.
2. **PC asleep.** The server only exists while the PC is awake. Wake it. Then, from Safari
   on the phone, `http://100.69.103.126:8787/api/health` should return
   `{"ok":true,...}` — if Safari can't reach it, the shortcut can't either.
3. **Server not running.** Health returns nothing but the PC is up → the `note-server`
   process isn't running. Start it on the PC.
4. **Denied network permission.** If you tapped *Don't Allow* on the first run's
   "wants to send data to 100.69.103.126" prompt, delete and re-add the
   `Get Contents of URL` action, or reset Shortcuts' permissions, and answer *Allow*.

**Banner says `NOT captured — {"ok":false,"error":"unauthorized"}`.**
The token is wrong. Check the Headers field in the shortcut:

- value must be `Bearer ` + the token, one space, nothing else — **no trailing space**, which
  is the classic paste error;
- key must be exactly `Authorization`;
- the token must match `~/.notables/token` on the Mac and
  `%USERPROFILE%\.notables\token` on the PC. Get the current one with
  `cat ~/.notables/token`. If they were rotated, all three have to be updated.

**Banner says `NOT captured — {"ok":false,"error":"text is required"}`.**
Dictation returned nothing — you started talking before it was listening, or it stopped
early. Speak after the listening indicator appears. If it keeps cutting you off, set
**Stop Listening** to *On Tap*.

**Banner says `NOT captured — …could not write to the vault…`.**
The PC's vault path is unwritable (external drive missing, permissions). Server-side; check
`C:\Users\Kieran\Notables` and `logs/server.log`.

**Captured fine, but nothing shows up in the vault.**
The `202` only means "queued" — Claude runs afterwards. Wait ~10 s. If it still hasn't
appeared, check `claudeOk` in `/api/health`: `false` means the `claude` CLI on the PC is
failing (not signed in, rate limited). Nothing is lost when that happens — a failed capture
is filed verbatim as a todo, and the raw payload stays in `inbox/<id>.json`.

**It filed the wrong kind.** Say the word: "*note*: ..." or "*homework*: ..." nudges the
classifier. If it happens constantly, use the note-only duplicate described in SETUP.md.

**Speaking to it feels slow.** Set **Stop Listening** to *After Short Pause* in the
Dictate Text action.

## Security

The Bearer token in the shortcut is a write credential for the whole note vault, and it sits
in plain text inside the shortcut. Don't share the shortcut, don't AirDrop it, don't post
screenshots of the Headers field. Rotating it means changing the file on the Mac, the file
on the PC, and the header in the shortcut — all three.

Traffic is plain HTTP; Tailscale (WireGuard) is the encryption layer for anything crossing
the internet.

The server socket does listen on `0.0.0.0` rather than only the Tailscale interface, but
that is **not** the exposure it looks like: the Windows Firewall rule *Notables Note Server
8787* scopes inbound TCP 8787 to `100.64.0.0/10`, the Tailscale CGNAT range. Verified:

```
> Get-NetFirewallRule -DisplayName '*Notab*' | Get-NetFirewallAddressFilter
RemoteAddress : 100.64.0.0/255.192.0.0
```

So a machine on the same café or campus LAN cannot reach `:8787` — it is filtered before it
reaches the listener, and the Bearer token is a second layer rather than the only one. If
that firewall rule is ever deleted, the bind address becomes load-bearing again; re-add the
rule (see `server/README.md`) rather than relying on the token alone.
