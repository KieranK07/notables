# note-server

The Windows half of Notables. Node stdlib only — no `package.json`, no `npm install`.
Wire protocol: [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

- Authored on the Mac in `server/`, deployed with `scripts/deploy-server.sh`.
- Lives on the PC at `%USERPROFILE%\Notables\server`.
- Vault at `%USERPROFILE%\Notables`.
- Listens on `0.0.0.0:8787`; the firewall rule only admits `100.64.0.0/10` (Tailscale).
- The AI pass shells out to `claude.exe -p` on Kieran's **subscription**. No API key.

```
note-server.js       http server, routing, auth
lib/config.js        paths, port, model, timezone — all env-overridable
lib/util.js          filename sanitising, timezone dates, YAML scalars
lib/store.js         _index.json + _courses.json (derived caches)
lib/vault.js         transcript files, note markdown, captures, index rebuild
lib/claude.js        prompts, `claude.exe` spawn, JSON parsing, normalising
lib/pipeline.js      the serial job queue
lib/sse.js           /api/events fan-out
run-server.cmd       launcher (checks the port, then runs node with logging)
start-hidden.vbs     runs run-server.cmd with no console window
stop-server.cmd      kills every running note-server
restart-server.cmd   stop + start
```

## Deploying from the Mac

```bash
./scripts/deploy-server.sh              # copy + restart + health check
./scripts/deploy-server.sh --install    # also (re)install the task + firewall rule
./scripts/deploy-server.sh --no-restart # copy only
```

## Start / stop / restart

The server runs from a Scheduled Task named **`Notables Note Server`**, as user
`Kieran` (not SYSTEM — `claude.exe` authenticates with credentials in Kieran's
profile, so a SYSTEM task could not run the AI pass). It has two triggers:

| trigger | what it does |
|---|---|
| at logon | brings the server back after a reboot |
| every 2 minutes | watchdog. `run-server.cmd` exits immediately if the port is already listening, so it only does something when the server has died. |

From the Mac (`ssh pc` runs `cmd.exe`, so separate commands with `&`, not `;`):

```bash
ssh pc 'wscript.exe //B //Nologo %USERPROFILE%\Notables\server\start-hidden.vbs'   # start
ssh pc '%USERPROFILE%\Notables\server\stop-server.cmd'                             # stop
ssh pc '%USERPROFILE%\Notables\server\restart-server.cmd'                          # restart
ssh pc 'schtasks /query /tn "Notables Note Server" /v /fo list'                      # task status
ssh pc 'schtasks /run   /tn "Notables Note Server"'                                  # force a start
ssh pc 'schtasks /change /tn "Notables Note Server" /disable'                         # stop the watchdog
```

**`stop-server.cmd` is not permanent** — the watchdog restarts the server within two
minutes. To keep it down, disable the task first.

To run it in the foreground for debugging (Ctrl-C to quit):

```bash
ssh pc '%USERPROFILE%\Notables\server\stop-server.cmd & node %USERPROFILE%\Notables\server\note-server.js'
```

## Logs

| file | what |
|---|---|
| `%USERPROFILE%\Notables\logs\server.log` | the server's own log; rotates to `server.log.1` at 5 MB |
| `%USERPROFILE%\Notables\logs\stdout.log` | raw stdout/stderr from the launcher — read this when the process won't even start |

```bash
ssh pc 'powershell -NoProfile -Command "Get-Content $env:USERPROFILE\Notables\logs\server.log -Tail 40"'
ssh pc 'powershell -NoProfile -Command "Get-Content $env:USERPROFILE\Notables\logs\server.log -Wait -Tail 20"'   # follow
```

## Retrying a failed note

Nothing is lost when the AI pass fails. Before `claude.exe` is ever spawned the server
has already written:

* `inbox\<id>.json` — the whole ingest payload including the verbatim transcript
* `Transcripts\_Unsorted\<date> — <title> [<id8>].txt` — the transcript as a file

A failed note keeps `state: "failed"` in `_index.json` with an `error` field, and both
files stay on disk. Retry it:

```bash
TOKEN=$(cat ~/.notables/token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://<pc-ip>:8787/api/note/<id>/reprocess
```

List what needs retrying:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://<pc-ip>:8787/api/notes \
 | python3 -c "import json,sys; [print(n['id'], n.get('error')) for n in json.load(sys.stdin)['notes'] if n['state']=='failed']"
```

`reprocess` also works on a note that is already `ready` — it re-runs the pass, rewrites
the markdown in place, and preserves the `done` flag of any action item whose text did
not change.

If `inbox\<id>.json` is gone (it is deleted once the note is `ready`), reprocess falls
back to reading the transcript file the note points at, so it still works.

## Rebuilding `_index.json` from the markdown

`_index.json` and `_courses.json` are **derived caches**. The markdown files in `Notes\`
are the source of truth. If the index is corrupted or deleted:

```bash
ssh pc '%USERPROFILE%\Notables\server\stop-server.cmd & node %USERPROFILE%\Notables\server\note-server.js --rebuild-index'
ssh pc 'wscript.exe //B //Nologo %USERPROFILE%\Notables\server\start-hidden.vbs'
```

or, without stopping anything:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://<pc-ip>:8787/api/reindex
```

The rebuild reads the YAML front matter of every `Notes\**\*.md`, re-derives the course
list, and re-derives todos from the `## Action Items` checkboxes (preserving `[x]`).
Two extra front-matter keys — `source_title` and `duration_sec` — exist purely so this
rebuild is lossless.

## Configuration

Every setting is an environment variable, read at startup:

| var | default |
|---|---|
| `NOTABLES_VAULT` | `%USERPROFILE%\Notables` |
| `NOTABLES_PORT` | `8787` |
| `NOTABLES_HOST` | `0.0.0.0` |
| `NOTABLES_TOKEN_FILE` | `%USERPROFILE%\.notables\token` |
| `NOTABLES_CLAUDE_BIN` | `%USERPROFILE%\AppData\Local\Microsoft\WinGet\Links\claude.exe` |
| `NOTABLES_MODEL` | `sonnet` — set to `opus` for a heavier pass |
| `NOTABLES_TZ` | `America/Chicago` — the zone `classDate` defaults to |
| `NOTABLES_CLAUDE_TIMEOUT_MS` | `900000` (15 min) |
| `NOTABLES_DEBUG` | unset — set to anything for debug logging |

The bearer token is re-read from disk at most every 10 seconds, so rotating
`%USERPROFILE%\.notables\token` takes effect without a restart.

## Endpoints beyond PROTOCOL.md

These are additive; the Mac app can ignore them.

* `POST /api/todo/{id}/done` and `/undone` — tick a checkbox off. PROTOCOL defines a
  `done` flag on todos but no way to set it.
* `POST /api/reindex` — the rebuild above.
* `GET /` — an unauthenticated liveness ping.
* `GET /api/events?token=<token>` — the token may go in the query string as well as the
  `Authorization` header, because a browser `EventSource` cannot set headers.
