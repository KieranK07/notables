'use strict';
// The MCP surface: the class vault as tools a Claude instance can call.
//
// This module is the SINGLE definition of those tools. Two transports carry it and
// neither owns any of it:
//
//   stdio  - mcp/notables-mcp.js, a thin bridge for Claude Code on any machine
//   HTTP   - the second listener in note-server.js, reached from claude.ai through
//            the Cloudflare tunnel that already fronts this PC
//
// Keeping the tool list, the argument schemas and the prose formatting here is the
// point: two copies of five tool descriptions would drift, and a drifted description
// is a tool the model calls wrongly.
//
// Handlers call the vault modules directly rather than looping back through the HTTP
// API. This runs inside the note server, so search is a function call.
const cfg = require('./config');
const log = require('./log');
const store = require('./store');
const canvas = require('./canvas');
const materials = require('./materials');
const search = require('./search');
const { asString } = require('./util');

const PROTOCOL_FALLBACK = '2025-06-18';
const SERVER_INFO = { name: 'notables', version: cfg.VERSION };

const INSTRUCTIONS =
  "Notables holds Kieran's class vault: Canvas course materials, the study notes " +
  'written from recorded lectures, and the verbatim transcripts of those lectures. ' +
  'Call list_classes first to get exact course names, then search to find things and ' +
  'read_document to read them. resync re-pulls from Canvas and reports what needs ' +
  'attention.';

// -------------------------------------------------------------------- tools
const TOOLS = [
  {
    name: 'list_classes',
    description:
      'List every class in the Notables vault with what is held for each: how many ' +
      'Canvas files and lecture notes, how much extracted text, the Canvas module ' +
      'names, and when it last synced. Start here to learn the exact course names the ' +
      'other tools expect.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'search',
    description:
      'Full-text search across everything for a class: Canvas course materials ' +
      '(slides, PDFs, handouts), the markdown study notes from recorded lectures, and ' +
      'the verbatim lecture transcripts. Returns ranked snippets with a `ref` for each ' +
      'hit - pass that ref to read_document for the full text. This is the main way in.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Text to find. Case-insensitive substring by default.' },
        course: { type: 'string', description: 'Restrict to one class, named exactly as list_classes reports it.' },
        kind: { type: 'string', description: "Comma-separated: 'material', 'note', 'transcript'. Defaults to all three." },
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
      'Browse the files themselves rather than searching their contents. Filter by ' +
      'class, Canvas module, kind, or a substring of the filename. Returns refs and ' +
      'metadata, no text.',
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
      'Read the full text of one document by ref. Refs come from search or ' +
      'list_documents and look like "material:<course>/<canvasFileId>", ' +
      '"note:<noteId>" or "transcript:<noteId>". PDFs and slide decks come back as ' +
      'their extracted text.',
    inputSchema: {
      type: 'object',
      properties: {
        ref: { type: 'string', description: 'The document ref.' },
        max_chars: {
          type: 'number',
          description: 'Truncate to this many characters. Some lecture slide decks run ' +
                       'past 100k characters, so cap it when you only need the start.',
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
      'attention: per-class new / updated / unchanged counts, courses that failed, ' +
      'files whose text could not be extracted, and superseded revisions cleaned up. ' +
      'Waits for the sync to finish by default; a full pull takes about a minute.',
    inputSchema: {
      type: 'object',
      properties: {
        full: { type: 'boolean', description: 'Re-download every file instead of only what changed.' },
        wait: { type: 'boolean', description: 'Wait for completion and report the result. Default true.' },
        timeout_sec: { type: 'number', description: 'How long to wait before reporting that it is still running (default 240).' },
      },
      additionalProperties: false,
    },
  },
];

// ----------------------------------------------------------------- handlers
function vaultStatus() {
  const courses = [];
  for (const c of store.courseSummaries(true)) {
    const m = materials.readManifest(c.name);
    const files = (m && m.files) ? Object.values(m.files) : [];
    courses.push({
      course: c.name,
      courseCode: (m && m.courseCode) || null,
      noteCount: c.noteCount || 0,
      lastClass: c.lastClass || null,
      fileCount: new Set(files.map(f => f.path).filter(Boolean)).size,
      textChars: files.reduce((n, f) => n + ((f.extract && f.extract.chars) || 0), 0),
      modules: (m && m.modules || []).map(x => x.folder || x.name),
      syncedAt: (m && m.syncedAt) || null,
    });
  }
  return courses;
}

function toolListClasses() {
  const cv = canvas.status();
  const out = [];
  out.push('Canvas: ' + (cv && cv.connected ? 'connected' : 'NOT connected') +
           (cv && cv.host ? ' (' + cv.host + ')' : '') +
           (materials.isSyncing() ? ' - a sync is running right now' : ''));
  out.push('');
  for (const c of vaultStatus()) {
    out.push('## ' + c.course);
    const bits = [
      c.fileCount + ' Canvas file' + (c.fileCount === 1 ? '' : 's'),
      c.noteCount + ' lecture note' + (c.noteCount === 1 ? '' : 's'),
      c.textChars.toLocaleString('en-US') + ' chars of extracted text',
    ];
    if (c.courseCode) bits.unshift(c.courseCode);
    out.push('   ' + bits.join(' · '));
    if (c.lastClass) out.push('   last class recorded: ' + c.lastClass);
    if (c.syncedAt) out.push('   last synced: ' + c.syncedAt);
    if (c.modules.length) out.push('   modules: ' + c.modules.join(', '));
    out.push('');
  }
  const trouble = search.extractProblems().length + search.collisions().length;
  if (trouble) out.push('Run resync for detail on ' + trouble + ' file(s) needing attention.');
  return out.join('\n');
}

function toolSearch(a) {
  const r = search.search({
    q: a.query, course: a.course, kind: a.kind, limit: a.limit, regex: !!a.regex,
  });
  if (!r.results.length) {
    return 'No matches for ' + JSON.stringify(r.query) + ' in ' + r.scanned + ' file(s)' +
           (r.course ? ' for ' + r.course : '') + '.';
  }
  const out = [
    'Found ' + r.matched + ' file(s) matching ' + JSON.stringify(r.query) + ' out of ' +
    r.scanned + ' searched' + (r.truncated ? ' (showing the top ' + r.results.length + ')' : '') + ':',
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

function toolListDocuments(a) {
  const r = search.list({
    course: a.course, kind: a.kind, name: a.name, module: a.module, limit: a.limit,
  });
  if (!r.documents.length) return 'No documents match those filters.';
  const out = [r.total + ' document(s)' +
               (r.truncated ? ' (showing ' + r.documents.length + ')' : '') + ':', ''];
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

function toolReadDocument(a) {
  const r = search.readRef(a.ref);
  if (r.error) throw new Error(r.error);
  const offset = Math.max(0, parseInt(a.offset, 10) || 0);
  const max = parseInt(a.max_chars, 10) || 0;
  let text = r.text.slice(offset);
  let note = '';
  if (max > 0 && text.length > max) {
    text = text.slice(0, max);
    note = '\n\n[truncated at ' + max + ' chars; the document is ' + r.text.length +
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

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function toolResync(a) {
  if (!canvas.hasSession()) {
    return 'Canvas is not connected - no saved session. Reconnect from the Notables app; ' +
           'it signs in through a real browser window because the school uses Microsoft SSO.';
  }
  const wait = a.wait !== false;
  const deadline = Date.now() + (parseInt(a.timeout_sec, 10) || 240) * 1000;

  if (!materials.isSyncing()) {
    // Fire and forget here too: the wait below is a poll, so a caller that gives up
    // does not cancel the pull.
    materials.sync({ full: !!a.full })
      .catch(e => log.error('canvas sync (mcp) crashed -', e.stack || e.message));
  }
  if (!wait) return 'Sync started. Call resync again, or list_classes, to see the result.';

  while (Date.now() < deadline) {
    await sleep(2000);
    if (!materials.isSyncing()) return formatSyncReport();
  }
  return 'The sync is still running. Call resync again in a moment for the report.';
}

function formatSyncReport() {
  const last = materials.last();
  const out = [];
  if (!last) {
    out.push('The sync finished but reported no result. Check the Notables app.');
  } else {
    out.push('Canvas re-pull ' + (last.ok ? 'completed' : 'FAILED') +
             (last.durationSec ? ' in ' + last.durationSec + 's' : '') + '.');
    if (last.error) out.push('Error: ' + last.error);
    if (last.needsReconnect) {
      out.push('The Canvas session has EXPIRED - reconnect from the Notables app; nothing ' +
               'below is fresh.');
    }
    out.push('');
    let quiet = 0, cleaned = 0;
    for (const c of last.courses || []) {
      const k = c.counts || {};
      cleaned += c.superseded || 0;
      if (!(k.new || 0) && !(k.updated || 0) && !c.problems && !c.superseded) { quiet++; continue; }
      out.push('- ' + c.course + ': ' + (k.new || 0) + ' new, ' + (k.updated || 0) +
               ' updated, ' + (k.unchanged || 0) + ' unchanged' +
               (k.skipped ? ', ' + k.skipped + ' skipped' : '') +
               (c.superseded ? ', ' + c.superseded + ' superseded revision(s) cleaned up' : '') +
               (c.problems ? ' - ' + c.problems + ' problem(s)' : ''));
    }
    if (cleaned) {
      out.push('  (a superseded revision is an older Canvas upload of the same filename ' +
               'whose bytes had already been overwritten - the manifest entry is gone too)');
    }
    if (quiet) out.push('- ' + quiet + ' other class(es) unchanged.');
    for (const f of last.failedCourses || []) out.push('- FAILED ' + f.course + ': ' + f.error);
  }

  const fails = search.extractProblems();
  const collide = search.collisions();
  out.push('');
  if (!fails.length && !collide.length) {
    out.push('Nothing needs resyncing - every file is on disk with its text extracted.');
    return out.join('\n');
  }
  if (collide.length) {
    out.push('NEEDS ATTENTION - ' + collide.length + ' file(s) still collide on one path:');
    for (const c of collide) {
      out.push('  - ' + c.course + ' / ' + c.name + ' - Canvas ids ' +
               c.entries.map(e => e.id).join(', '));
    }
    out.push('');
  }
  if (fails.length) {
    out.push('NO SEARCHABLE TEXT - ' + fails.length + ' file(s):');
    for (const f of fails) {
      out.push('  - ' + f.course + ' / ' + f.name + ' - ' + f.state +
               (f.error ? ': ' + f.error : '') + '  [' + f.ref + ']');
    }
    out.push('  These are downloaded and on disk; only their text could not be pulled ' +
             'out, so they match by filename but not by content.');
  }
  return out.join('\n');
}

const HANDLERS = {
  list_classes: toolListClasses,
  search: toolSearch,
  list_documents: toolListDocuments,
  read_document: toolReadDocument,
  resync: toolResync,
};

// ------------------------------------------------------------ jsonrpc / mcp
/**
 * Handle one JSON-RPC message. Resolves to the reply object, or null for a
 * notification (which by the spec gets no reply at all).
 */
async function handleMessage(msg) {
  const id = msg && msg.id;
  const isNotification = id === undefined || id === null;
  const ok = result => (isNotification ? null : { jsonrpc: '2.0', id, result });
  const err = (code, message) =>
    (isNotification ? null : { jsonrpc: '2.0', id, error: { code, message } });

  switch (msg && msg.method) {
    case 'initialize': {
      const p = msg.params || {};
      // Echo the client's protocol version when it names one: this server's surface is
      // plain tools, which every revision of MCP has carried unchanged.
      const asked = typeof p.protocolVersion === 'string' ? p.protocolVersion : null;
      return ok({
        protocolVersion: asked || PROTOCOL_FALLBACK,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case 'notifications/initialized':
    case 'initialized':
      return null;
    case 'ping':
      return ok({});
    case 'tools/list':
      return ok({ tools: TOOLS });
    case 'tools/call': {
      const p = msg.params || {};
      const fn = HANDLERS[p.name];
      if (!fn) return err(-32602, 'no such tool: ' + asString(p.name));
      try {
        const text = await fn(p.arguments || {});
        return ok({ content: [{ type: 'text', text: String(text) }] });
      } catch (e) {
        // A tool failure is a result, not a protocol error: the model should see it and
        // be able to react rather than have the call disappear.
        log.warn('mcp tool', p.name, 'failed -', e.message);
        return ok({ content: [{ type: 'text', text: 'Error: ' + e.message }], isError: true });
      }
    }
    // No capability declared for these, but answer politely rather than erroring.
    case 'resources/list': return ok({ resources: [] });
    case 'prompts/list':   return ok({ prompts: [] });
    default:
      return err(-32601, 'method not found: ' + asString(msg && msg.method));
  }
}

module.exports = { handleMessage, TOOLS, SERVER_INFO, INSTRUCTIONS };
