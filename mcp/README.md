# Notables MCP server

The class vault as tools any Claude instance can call: Canvas course materials, the study
notes written from recorded lectures, and the verbatim transcripts — searchable, readable,
and re-syncable from inside a conversation.

```
claude mcp add notables -s user -- node /Users/kierankelly/Desktop/Notables/mcp/notables-mcp.js
```

`-s user` puts it in every project, not just this repo. On the PC, after
`scripts/deploy-server.sh` has copied it over:

```
claude mcp add notables -s user -- node C:\Users\Kieran\Notables\mcp\notables-mcp.js
```

Check it with `claude mcp get notables`. Remove it with `claude mcp remove notables -s user`.

## Tools

| tool | what it answers |
|---|---|
| `list_classes` | What classes exist, how many files and lectures each holds, which Canvas modules, when it last synced. **Start here** — it gives the exact course names the other tools want. |
| `search` | Full text across materials, notes and transcripts. Ranked snippets, each with a `ref`. |
| `list_documents` | Browse files rather than contents. Filter by class, module, kind, filename. |
| `read_document` | The full text of one `ref`, with `max_chars` / `offset` for paging a 100k-character slide deck. |
| `resync` | Re-pull everything from Canvas, then report what changed and what needs attention. |

## Refs

Everything is addressed by one string, so `search` → `read_document` chains without the
caller knowing which kind it found:

```
material:<course>/<canvasFileId>     the extracted text of a Canvas file
note:<noteId>                        the markdown study notes
transcript:<noteId>                  the verbatim lecture transcript
```

## How it fits together

This is a **stdio proxy**, not MCP hosted on the PC:

```
Claude (Mac or PC)  ──stdio JSON-RPC──▶  notables-mcp.js  ──HTTP/Tailscale──▶  note server (PC)
```

It runs wherever the Claude instance runs, so one file serves every machine on the tailnet
and the note server keeps its single HTTP surface. It reads `~/.notables/token` (override
with `NOTABLES_TOKEN`) and talks to `http://100.69.103.126:8787` (override with
`NOTABLES_URL` — use `http://127.0.0.1:8787` on the PC itself).

**Zero npm dependencies**, matching the rule the rest of the project is built on. MCP over
stdio is newline-delimited JSON-RPC 2.0; the handful of methods a tools-only server needs
(`initialize`, `tools/list`, `tools/call`, `ping`) are implemented directly.

**Searching happens on the PC**, never here. The Mac↔PC link is a DERP relay at ~1.6 MB/s
and the extracted material text is well past a megabyte, so this process moves questions
and answers rather than corpora. The server side is `server/lib/search.js` behind
`GET /api/search`, `/api/documents`, `/api/document` and `/api/vault/status`.

## What `resync` means by "needs attention"

- **Path collisions.** Canvas gives a re-uploaded file a *new id* but the same display
  name, so the newer revision overwrites the older one on disk and the manifest ends up
  with several entries pointing at one path — all but the newest describing a file that is
  no longer there. `search` already collapses these and reports the stale ids under
  `supersedes`; `resync` names them so the manifest can be cleaned up properly.
- **Extract failures.** `.xlsx` and friends download fine but have no text extractor, so
  they match by filename and never by content.
