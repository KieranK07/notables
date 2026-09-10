#!/usr/bin/env node
'use strict';
// Notables MCP server - the class vault as tools any Claude instance can call.
//
//   claude mcp add notables -- node /path/to/notables-mcp.js
//
// WHY A STDIO PROXY, not MCP hosted on the PC: this runs wherever the Claude instance
// runs and talks to the note server over Tailscale, so the Mac, the PC and anything else
// on the tailnet all get the same tools from one file, and the note server keeps its
// single HTTP surface. It is JSON-RPC 2.0 over newline-delimited stdin/stdout.
//
// Zero npm dependencies, matching the rule the rest of the project is built on: Node
// stdlib only. The MCP wire format is small enough that a SDK buys nothing here.
//
// Every heavy operation - search, listing, extraction - happens on the PC where the
// files actually are. The Mac<->PC link is a DERP relay at ~1.6 MB/s, so this process
// moves questions and answers, never corpora.
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const PROTOCOL_FALLBACK = '2025-06-18';
const SERVER_INFO = { name: 'notables', version: '1.0.0' };

// ------------------------------------------------------------------- config
function loadToken() {
  if (process.env.NOTABLES_TOKEN) return process.env.NOTABLES_TOKEN.trim();
  const file = path.join(os.homedir(), '.notables', 'token');
  try { return fs.readFileSync(file, 'utf8').trim(); }
  catch (e) {
    throw new Error('no API token: set NOTABLES_TOKEN or put it in ' + file);
  }
}
const BASE = (process.env.NOTABLES_URL || 'http://100.69.103.126:8787').replace(/\/+$/, '');
let TOKEN = null;      // read lazily so a missing token is a tool error, not a dead server

// --------------------------------------------------------------------- http
function apiGet(pathAndQuery, timeoutMs) {
  return request('GET', pathAndQuery, null, timeoutMs);
}
function apiPost(pathAndQuery, body, timeoutMs) {
  return request('POST', pathAndQuery, body, timeoutMs);
}

function request(method, pathAndQuery, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    if (TOKEN === null) TOKEN = loadToken();
    const url = new URL(BASE + pathAndQuery);
    const mod = url.protocol === 'https:' ? https : http;
    const payload = body == null ? null : Buffer.from(JSON.stringify(body));
    const req = mod.request(url, {
      method,
      headers: Object.assign(
        { Authorization: 'Bearer ' + TOKEN, Accept: 'application/json' },
        payload ? { 'Content-Type': 'application/json', 'Content-Length': payload.length } : {}),
      timeout: timeoutMs || 120000,
    }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(raw); } catch (_) {}
        if (res.statusCode >= 400) {
          const why = (json && json.error) || raw.slice(0, 300) || ('HTTP ' + res.statusCode);
          return reject(new Error('notables server: ' + why + ' (HTTP ' + res.statusCode + ')'));
        }
        if (!json) return reject(new Error('the server did not return JSON: ' + raw.slice(0, 200)));
        resolve(json);
      });
    });
    req.on('timeout', () => { req.destroy(new Error('timed out after ' + (timeoutMs || 120000) + 'ms')); });
    req.on('error', e => reject(new Error(
      'cannot reach the Notables server at ' + BASE + ' - ' + e.message +
      '. Is the PC awake and on the tailnet?')));
    if (payload) req.write(payload);
    req.end();
  });
}

const qs = obj => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null || v === '') continue;
    p.set(k, String(v));
  }
  const s = p.toString();
  return s ? '?' + s : '';
};

// -------------------------------------------------------------------- tools
const TOOLS = [
  {
    name: 'list_classes',
    description:
      'List every class in the Notables vault with what is held for each: how many Canvas ' +
      'files and lecture notes, how much extracted text, the Canvas module names, and when ' +
      'it last synced. Start here to learn the exact course names the other tools expect.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'search',
    description:
      'Full-text search across everything for a class: Canvas course materials (slides, ' +
      'PDFs, handouts), the markdown study notes from recorded lectures, and the verbatim ' +
      'lecture transcripts. Returns ranked snippets with a `ref` for each hit - pass that ' +
      'ref to read_document for the full text. This is the main way in.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Text to find. Case-insensitive substring by default.' },
        course: { type: 'string', description: 'Restrict to one class, named exactly as list_classes reports it.' },
        kind: {
          type: 'string',
          description: "Comma-separated: 'material', 'note', 'transcript'. Defaults to all three.",
        },
        regex: { type: 'boolean', description: 'Treat query as a JavaScript regular expression.' },
        limit: { type: 'number', description: 'Max files to return (1-100, default 20).' },
      },
      required: ['query'],
      additionalProperties: false,
    },
  },
  {
    name: 'list_documents',
    description:
      'Browse the files themselves rather than searching their contents. Filter by class, ' +
      'Canvas module, kind, or a substring of the filename. Returns refs and metadata, no text.',
    inputSchema: {
      type: 'object',
      properties: {
        course: { type: 'string', description: 'Restrict to one class.' },
        kind: { type: 'string', description: "Comma-separated: 'material', 'note', 'transcript'." },
        name: { type: 'string', description: 'Substring of the file or lecture title.' },
        module: { type: 'string', description: 'Substring of the Canvas module name.' },
        limit: { type: 'number', description: 'Max documents (1-1000, default 200).' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'read_document',
    description:
      'Read the full text of one document by ref. Refs come from search or list_documents ' +
      'and look like "material:<course>/<canvasFileId>", "note:<noteId>" or ' +
      '"transcript:<noteId>". PDFs and slide decks come back as their extracted text.',
    inputSchema: {
      type: 'object',
      properties: {
        ref: { type: 'string', description: 'The document ref.' },
        max_chars: {
          type: 'number',
          description: 'Truncate to this many characters. Some lecture slide decks run past ' +
                       '100k characters, so cap it when you only need the start.',
        },
        offset: { type: 'number', description: 'Start reading at this character offset, for paging through a long file.' },
      },
      required: ['ref'],
      additionalProperties: false,
    },
  },
  {
    name: 'resync',
    description:
      'Re-pull everything from Canvas and report what changed and what still needs ' +
      'attention: per-class new / updated / unchanged counts, courses that failed, files ' +
      'whose text could not be extracted, and files that collide on one path on disk. ' +
      'Waits for the sync to finish by default; a full pull can take a few minutes.',
    inputSchema: {
      type: 'object',
      properties: {
        full: { type: 'boolean', description: 'Re-download every file instead of only what changed.' },
        wait: { type: 'boolean', description: 'Wait for completion and report the result. Default true.' },
        timeout_sec: { type: 'number', description: 'How long to wait before giving up on the report (default 600).' },
      },
      additionalProperties: false,
    },
  },
];

// ------------------------------------------------------------ tool handlers
async function toolListClasses() {
  const s = await apiGet('/api/vault/status');
  const lines = [];
  lines.push('Canvas: ' + (s.canvas && s.canvas.connected ? 'connected' : 'NOT connected') +
             (s.canvas && s.canvas.host ? ' (' + s.canvas.host + ')' : '') +
             (s.syncing ? ' - a sync is running right now' : ''));
  lines.push('');
  for (const c of s.courses) {
    lines.push('## ' + c.course);
    const bits = [
      c.distinctFiles + ' Canvas file' + (c.distinctFiles === 1 ? '' : 's'),
      c.noteCount + ' lecture note' + (c.noteCount === 1 ? '' : 's'),
      c.textChars.toLocaleString('en-US') + ' chars of extracted text',
    ];
    if (c.courseCode) bits.unshift(c.courseCode);
    lines.push('   ' + bits.join(' · '));
    if (c.lastClass) lines.push('   last class recorded: ' + c.lastClass);
    if (c.syncedAt) lines.push('   last synced: ' + c.syncedAt);
    if (c.modules && c.modules.length) lines.push('   modules: ' + c.modules.join(', '));
    lines.push('');
  }
  const na = s.needsAttention || {};
  const trouble = (na.extractFailures || []).length + (na.pathCollisions || []).length;
  if (trouble) lines.push('Run resync for detail on ' + trouble + ' file(s) needing attention.');
  return lines.join('\n');
}

async function toolSearch(a) {
  const r = await apiGet('/api/search' + qs({
    q: a.query, course: a.course, kind: a.kind,
    limit: a.limit, regex: a.regex ? 1 : '',
  }));
  if (!r.results.length) {
    return 'No matches for ' + JSON.stringify(r.query) + ' in ' + r.scanned + ' file(s)' +
           (r.course ? ' for ' + r.course : '') + '.';
  }
  const out = [
    'Found ' + r.matched + ' file(s) matching ' + JSON.stringify(r.query) +
    ' out of ' + r.scanned + ' searched' + (r.truncated ? ' (showing the top ' + r.results.length + ')' : '') + ':',
    '',
  ];
  for (const hit of r.results) {
    out.push('## ' + hit.title + '  [' + hit.kind + ']');
    const meta = [hit.course];
    if (hit.module) meta.push(hit.module);
    if (hit.classDate) meta.push(hit.classDate);
    meta.push(hit.hits + ' hit' + (hit.hits === 1 ? '' : 's'));
    out.push(meta.join(' · '));
    out.push('ref: ' + hit.ref);
    for (const s of hit.snippets) out.push('  > ' + s);
    out.push('');
  }
  return out.join('\n');
}

async function toolListDocuments(a) {
  const r = await apiGet('/api/documents' + qs({
    course: a.course, kind: a.kind, name: a.name, module: a.module, limit: a.limit,
  }));
  if (!r.documents.length) return 'No documents match those filters.';
  const out = [r.total + ' document(s)' + (r.truncated ? ' (showing ' + r.documents.length + ')' : '') + ':', ''];
  let course = null;
  for (const d of r.documents) {
    if (d.course !== course) { course = d.course; out.push('## ' + course); }
    const bits = ['[' + d.kind + ']', d.title];
    if (d.module) bits.push('(' + d.module + ')');
    if (d.chars) bits.push(d.chars.toLocaleString('en-US') + ' chars');
    if (d.classDate) bits.push(d.classDate);
    out.push('  ' + bits.join(' ') + '\n    ref: ' + d.ref);
    if (d.extractState && d.extractState !== 'ok') {
      out.push('    NOTE: text extraction ' + d.extractState + ' - searchable by name only');
    }
  }
  return out.join('\n');
}

async function toolReadDocument(a) {
  const r = await apiGet('/api/document' + qs({ ref: a.ref }));
  const offset = Math.max(0, parseInt(a.offset, 10) || 0);
  const max = parseInt(a.max_chars, 10) || 0;
  let text = r.text.slice(offset);
  let note = '';
  if (max > 0 && text.length > max) {
    text = text.slice(0, max);
    note = '\n\n[truncated at ' + max + ' chars; the document is ' + r.chars +
           ' chars total. Read on with offset=' + (offset + max) + '.]';
  }
  const m = r.meta || {};
  const head = [
    m.title || a.ref,
    [m.kind, m.course, m.module, m.classDate].filter(Boolean).join(' · '),
    'ref: ' + a.ref + (m.path ? '\npath: ' + m.path : ''),
  ].filter(Boolean).join('\n');
  const sup = (m.supersedes && m.supersedes.length)
    ? '\nsupersedes ' + m.supersedes.length + ' older Canvas upload(s) of the same filename' : '';
  return head + sup + '\n\n---\n\n' + text + note;
}

async function toolResync(a) {
  const wait = a.wait !== false;
  const timeoutMs = (parseInt(a.timeout_sec, 10) || 600) * 1000;

  const before = await apiGet('/api/vault/status');
  if (!before.canvas || !before.canvas.connected) {
    if (!before.canvas || !before.canvas.hasSession) {
      return 'Canvas is not connected - no saved session. Reconnect from the Notables app ' +
             '(it signs in through a real browser window because the school uses Microsoft SSO).';
    }
    // hasSession but not connected just means it has not been probed since the last restart.
  }

  const started = await apiPost('/api/canvas/sync', { full: !!a.full });
  if (started.alreadyRunning) {
    if (!wait) return 'A sync was already running; left it to finish.';
  }
  if (!wait) return 'Sync started. Call resync again with wait=true, or list_classes, to see the result.';

  const deadline = Date.now() + timeoutMs;
  let status = null;
  // Poll rather than hold a request open for minutes: a full pull downloads slide decks.
  while (Date.now() < deadline) {
    await sleep(3000);
    status = await apiGet('/api/vault/status');
    if (!status.syncing) break;
  }
  if (!status || status.syncing) {
    return 'The sync is still running after ' + Math.round(timeoutMs / 1000) + 's. ' +
           'Call list_classes later, or resync with a longer timeout_sec.';
  }
  return formatSyncReport(status);
}

function formatSyncReport(status) {
  const last = status.lastSync;
  const out = [];
  if (!last) {
    out.push('The sync finished but the server reported no result. Check the Notables app.');
  } else {
    out.push('Canvas re-pull ' + (last.ok ? 'completed' : 'FAILED') +
             (last.durationSec ? ' in ' + last.durationSec + 's' : '') + '.');
    if (last.error) out.push('Error: ' + last.error);
    if (last.needsReconnect) {
      out.push('The Canvas session has EXPIRED - reconnect from the Notables app; nothing ' +
               'below is fresh.');
    }
    out.push('');
    let quiet = 0;
    for (const c of last.courses || []) {
      const k = c.counts || {};
      const changed = (k.new || 0) + (k.updated || 0);
      if (!changed && !c.problems) { quiet++; continue; }
      out.push('- ' + c.course + ': ' +
               (k.new || 0) + ' new, ' + (k.updated || 0) + ' updated, ' +
               (k.unchanged || 0) + ' unchanged' +
               (k.skipped ? ', ' + k.skipped + ' skipped' : '') +
               (c.problems ? ' - ' + c.problems + ' problem(s)' : ''));
    }
    if (quiet) out.push('- ' + quiet + ' other class(es) unchanged.');
    for (const f of last.failedCourses || []) {
      out.push('- FAILED ' + f.course + ': ' + f.error);
    }
  }

  const na = status.needsAttention || {};
  const fails = na.extractFailures || [];
  const collide = na.pathCollisions || [];
  out.push('');
  if (!fails.length && !collide.length) {
    out.push('Nothing needs resyncing - every file is on disk with its text extracted.');
    return out.join('\n');
  }

  if (collide.length) {
    out.push('NEEDS ATTENTION - ' + collide.length + ' file(s) collide on one path:');
    out.push('  Canvas gives a re-uploaded file a new id but the same display name, so the ' +
             'newer revision overwrote the older one. Only the newest is really on disk; ' +
             'search already hides the stale entries.');
    for (const c of collide) {
      out.push('  - ' + c.course + ' / ' + c.name + ' - ' + c.entries.length + ' Canvas ids: ' +
               c.entries.map(e => e.id + ' (' + e.chars + ' chars)').join(', '));
    }
    out.push('');
  }
  if (fails.length) {
    out.push('NO SEARCHABLE TEXT - ' + fails.length + ' file(s):');
    for (const f of fails) {
      out.push('  - ' + f.course + ' / ' + f.name + ' - ' + f.state +
               (f.error ? ': ' + f.error : '') + '  [' + f.ref + ']');
    }
    out.push('  These are downloaded and on disk; only their text could not be pulled out, ' +
             'so they match by filename but not by content.');
  }
  return out.join('\n');
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

const HANDLERS = {
  list_classes: toolListClasses,
  search: toolSearch,
  list_documents: toolListDocuments,
  read_document: toolReadDocument,
  resync: toolResync,
};

// ----------------------------------------------------------- jsonrpc / mcp
function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}
function reply(id, result) { send({ jsonrpc: '2.0', id, result }); }
function replyError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;

  switch (method) {
    case 'initialize': {
      // Echo the client's protocol version when it names one: this server's surface is
      // plain tools, which every revision of MCP has carried unchanged.
      const asked = params && typeof params.protocolVersion === 'string' ? params.protocolVersion : null;
      return reply(id, {
        protocolVersion: asked || PROTOCOL_FALLBACK,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions:
          'Notables holds Kieran\'s class vault: Canvas course materials, the study notes ' +
          'written from recorded lectures, and the verbatim transcripts. Call list_classes ' +
          'first to get exact course names, then search to find things and read_document to ' +
          'read them. resync re-pulls from Canvas and reports what needs attention.',
      });
    }
    case 'notifications/initialized':
    case 'initialized':
      return;                                  // notification: no response
    case 'ping':
      return reply(id, {});
    case 'tools/list':
      return reply(id, { tools: TOOLS });
    case 'tools/call': {
      const name = params && params.name;
      const fn = HANDLERS[name];
      if (!fn) return replyError(id, -32602, 'no such tool: ' + name);
      try {
        const text = await fn((params && params.arguments) || {});
        return reply(id, { content: [{ type: 'text', text: String(text) }] });
      } catch (e) {
        // A tool failure is a result, not a protocol error - the model should see it and
        // be able to react (reconnect Canvas, wake the PC, fix a course name).
        return reply(id, { content: [{ type: 'text', text: 'Error: ' + e.message }], isError: true });
      }
    }
    // Declared no capability for these, but answer politely rather than erroring if asked.
    case 'resources/list': return reply(id, { resources: [] });
    case 'prompts/list':   return reply(id, { prompts: [] });
    default:
      if (isNotification) return;
      return replyError(id, -32601, 'method not found: ' + method);
  }
}

let buffer = '';
let inFlight = 0;
let stdinClosed = false;

// Exit only once nothing is still being answered. A real client keeps stdin open for the
// life of the session, but anything that pipes a batch of requests and closes - a test,
// a script - would otherwise kill the process mid-await and get silence back.
function exitWhenIdle() {
  if (stdinClosed && inFlight === 0) process.exit(0);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); }
    catch (e) { replyError(null, -32700, 'parse error: ' + e.message); continue; }
    inFlight++;
    Promise.resolve(handle(msg))
      .catch(e => {
        if (msg && msg.id !== undefined && msg.id !== null) replyError(msg.id, -32603, e.message);
      })
      .finally(() => { inFlight--; exitWhenIdle(); });
  }
});
process.stdin.on('end', () => { stdinClosed = true; exitWhenIdle(); });
