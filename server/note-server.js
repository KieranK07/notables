#!/usr/bin/env node
'use strict';
// Notables note server - zero npm dependencies, Node stdlib only.
// Wire protocol: docs/PROTOCOL.md. Run with --help for the CLI.

const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const zlib = require('zlib');
const path = require('path');

const cfg = require('./lib/config');
const log = require('./lib/log');
const util = require('./lib/util');
const store = require('./lib/store');
const vault = require('./lib/vault');
const sse = require('./lib/sse');
const claude = require('./lib/claude');
const whisper = require('./lib/whisper');
const pipeline = require('./lib/pipeline');
const search = require('./lib/search');
const canvas = require('./lib/canvas');
const materials = require('./lib/materials');
const chat = require('./lib/chat');

const startedAt = Date.now();

// ------------------------------------------------------------------- auth
let tokenCache = { value: null, at: 0 };
function loadToken() {
  if (tokenCache.value && Date.now() - tokenCache.at < 10000) return tokenCache.value;
  try {
    const v = fs.readFileSync(cfg.TOKEN_FILE, 'utf8').replace(/^\uFEFF/, '').trim();
    tokenCache = { value: v || null, at: Date.now() };
  } catch (e) {
    log.error('cannot read token file', cfg.TOKEN_FILE, '-', e.message);
    tokenCache = { value: null, at: Date.now() };
  }
  return tokenCache.value;
}

function timingSafeEq(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) {
    // Still burn a comparison so length isn't leaked by timing.
    crypto.timingSafeEqual(ba, ba);
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

function presentedToken(req, url) {
  const h = req.headers['authorization'] || '';
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  if (m) return m[1].trim();
  // EventSource in a browser cannot set headers; allow ?token= as a fallback.
  const q = url.searchParams.get('token');
  return q ? q.trim() : null;
}

function authorised(req, url) {
  const expected = loadToken();
  if (!expected) return false;
  const got = presentedToken(req, url);
  if (!got) return false;
  return timingSafeEq(got, expected);
}

// ------------------------------------------------------------------- http
// The Mac and the PC are on different networks behind a symmetric NAT, so Tailscale
// relays through a DERP server: ~1.6 MB/s and ~50ms RTT. Every byte is worth saving.
// Extracted lecture text and course manifests compress by roughly 5-10x.
const GZIP_MIN_BYTES = 4096;

function send(res, code, obj, extraHeaders) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  const headers = Object.assign({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  }, extraHeaders || {});

  // res.req is the request this response belongs to (Node >= 15.7), so compression
  // needs no signature change at any of the call sites.
  const accepts = String((res.req && res.req.headers['accept-encoding']) || '');
  if (body.length >= GZIP_MIN_BYTES && /\bgzip\b/.test(accepts)) {
    zlib.gzip(body, (err, zipped) => {
      if (err || !zipped || zipped.length >= body.length) {
        headers['Content-Length'] = body.length;
        res.writeHead(code, headers);
        return res.end(body);
      }
      headers['Content-Encoding'] = 'gzip';
      headers['Content-Length'] = zipped.length;
      headers['Vary'] = 'Accept-Encoding';
      res.writeHead(code, headers);
      res.end(zipped);
    });
    return;
  }
  headers['Content-Length'] = body.length;
  res.writeHead(code, headers);
  res.end(body);
}
function fail(res, code, error, extra) {
  send(res, code, Object.assign({ ok: false, error }, extra || {}));
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('body too large'), { code: 'TOO_LARGE' }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

/** Same limit discipline as readBody, but keeps the bytes - photos are not utf8. */
function readRawBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('body too large'), { code: 'TOO_LARGE' }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function readJsonBody(req, res) {
  let raw;
  try {
    raw = await readBody(req, cfg.MAX_BODY_BYTES);
  } catch (e) {
    fail(res, e.code === 'TOO_LARGE' ? 413 : 400, e.message);
    return null;
  }
  if (!raw.trim()) { fail(res, 400, 'empty body'); return null; }
  try {
    const v = JSON.parse(raw.replace(/^\uFEFF/, ''));
    if (!v || typeof v !== 'object' || Array.isArray(v)) { fail(res, 400, 'body must be a JSON object'); return null; }
    return v;
  } catch (e) {
    fail(res, 400, 'invalid JSON: ' + e.message);
    return null;
  }
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

// -------------------------------------------------------------- endpoints
async function handleHealth(req, res) {
  let ok = claude.lastHealth();
  if (ok === null) ok = await claude.checkHealth();
  else claude.checkHealth().catch(() => {});   // refresh in the background
  let wok = whisper.lastHealth();
  if (wok === null) wok = await whisper.checkHealth();
  else whisper.checkHealth().catch(() => {});
  send(res, 200, {
    ok: true,
    version: cfg.VERSION,
    vault: cfg.VAULT,
    queueDepth: pipeline.depth(),
    claudeOk: !!ok,
    // extras (not part of PROTOCOL.md, safe to ignore)
    whisperOk: !!wok,
    whisper: {
      model: cfg.WHISPER_MODEL, device: cfg.WHISPER_DEVICE,
      computeType: cfg.WHISPER_COMPUTE, detail: whisper.detail(),
    },
    model: cfg.MODEL,
    noteCount: store.state.notes.size,
    todoCount: store.state.todos.size,
    canvas: canvas.status(),
    canvasSync: { syncing: materials.isSyncing(), last: materials.last() },
    sseClients: sse.count(),
    uptimeSec: Math.round((Date.now() - startedAt) / 1000),
    node: process.version,
    pid: process.pid,
  }, CORS);
}

async function handleIngest(req, res) {
  const body = await readJsonBody(req, res);
  if (!body) return;

  const id = util.asString(body.id).trim();
  if (!id || id.length > 200) return fail(res, 400, 'id is required');
  if (/[\\/:*?"<>|]/.test(id)) return fail(res, 400, 'id contains characters that are illegal in a filename');

  // Idempotency: re-POSTing the same id is a no-op that reports current state.
  const existing = store.getNote(id);
  if (existing) {
    log.info('ingest duplicate id', id, '- state', existing.state);
    return send(res, 202, { ok: true, id, state: existing.state, duplicate: true }, CORS);
  }

  const recordedAt = util.normIso(body.recordedAt);
  const payload = {
    id,
    title: util.asString(body.title).trim() || 'Untitled Recording',
    recordedAt,
    durationSec: Number.isFinite(body.durationSec) ? Math.max(0, Math.round(body.durationSec)) : 0,
    locale: util.asString(body.locale, 'en_US'),
    device: util.asString(body.device),
    audioBytes: Number.isFinite(body.audioBytes) ? Math.max(0, Math.round(body.audioBytes)) : 0,
    audioFormat: (util.asString(body.audioFormat, 'm4a').toLowerCase().replace(/[^a-z0-9]/g, '') || 'm4a'),
    // Apple's on-device pass: a preview and a fallback, NEVER the final text.
    draftTranscript: util.asString(body.draftTranscript || body.transcript),
    receivedAt: util.nowIso(),
  };

  // ---- DURABILITY: the payload (draft included) hits disk immediately ----
  try {
    vault.saveInbox(payload);
  } catch (e) {
    log.error('ingest could not write to the vault:', e.message);
    return fail(res, 500, 'could not write to the vault: ' + e.message);
  }

  const note = {
    id,
    title: payload.title,
    course: null,
    section: null,
    topic: payload.title,
    classDate: util.localDate(recordedAt, cfg.TZ),
    recordedAt,
    durationSec: payload.durationSec,
    state: 'awaiting_audio',
    tags: [],
    summary: '',
    actionItemCount: 0,
    notePath: null,
    transcriptPath: null,
    updatedAt: util.nowIso(),
    // extras beyond PROTOCOL.md
    audioBytes: payload.audioBytes,
    audioReceived: 0,
    hasDraft: !!payload.draftTranscript.trim(),
    transcriptSource: null,
  };
  store.putNote(note);
  store.save(true);

  log.info('ingested', id, JSON.stringify(payload.title),
    '| draft', payload.draftTranscript.length, 'chars | expecting', payload.audioBytes, 'audio bytes');
  send(res, 202, { ok: true, id, state: 'awaiting_audio' }, CORS);

  sse.broadcast('note', note);
  pipeline.emitState(id, 'awaiting_audio', 'waiting for the audio upload');
}

// ------------------------------------------------------------ audio upload
/** PUT /api/audio/{id} - raw body, no multipart. */
function handleAudioPut(req, res, id) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'unknown id ' + id + ' - POST /api/ingest first');

  const payload = vault.readInbox(id) || {
    id, audioFormat: (note.audioPath || 'x.m4a').split('.').pop(), audioBytes: note.audioBytes || 0,
  };
  const expected = Number(payload.audioBytes) || 0;
  const finalPath = vault.audioAbs(id, payload);
  const partPath = vault.audioPartAbs(id, payload);

  try { fs.mkdirSync(cfg.DIRS.audio, { recursive: true }); }
  catch (e) { return fail(res, 500, 'could not create the audio directory: ' + e.message); }

  let received = 0, aborted = false;
  const out = fs.createWriteStream(partPath);

  const abort = (code, msg, extra) => {
    if (aborted) return;
    aborted = true;
    try { req.unpipe(out); } catch (_) {}
    out.destroy();
    if (!res.headersSent) fail(res, code, msg, extra);
    else try { res.end(); } catch (_) {}
  };

  req.on('data', c => {
    received += c.length;
    if (received > cfg.MAX_AUDIO_BYTES) { abort(413, 'audio exceeds ' + cfg.MAX_AUDIO_BYTES + ' bytes'); req.destroy(); }
  });
  req.on('error', e => abort(400, 'upload aborted: ' + e.message));
  req.on('aborted', () => abort(400, 'upload aborted by the client'));
  out.on('error', e => abort(500, 'could not write the audio: ' + e.message));

  req.pipe(out);

  out.on('close', () => {
    if (aborted) return;
    if (expected && received !== expected) {
      log.warn('audio upload for', id, 'was', received, 'bytes, expected', expected, '- keeping the partial');
      return fail(res, 400, 'incomplete upload', { received, expected, ok: false });
    }
    if (received === 0) return fail(res, 400, 'empty body', { received: 0, expected });

    try { fs.renameSync(partPath, finalPath); }
    catch (e) { return fail(res, 500, 'could not finalise the audio file: ' + e.message); }

    note.audioPath = vault.rel(finalPath);
    note.audioReceived = received;
    note.state = 'transcribing';
    delete note.error;
    store.putNote(note);
    store.save(true);

    log.info('audio received for', id, '-', received, 'bytes ->', note.audioPath);
    send(res, 202, { ok: true, id, state: 'transcribing', received, expected }, CORS);

    sse.broadcast('note', note);
    pipeline.emitState(id, 'transcribing', 'queued for transcription');
    pipeline.enqueue({ type: 'note', id, payload, retranscribe: true });
  });
}

/** GET /api/audio/{id}/status - lets the Mac see how much arrived before a retry. */
function handleAudioStatus(req, res, id) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'unknown id ' + id);
  const payload = vault.readInbox(id) || { id, audioFormat: 'm4a', audioBytes: note.audioBytes || 0 };
  const got = vault.audioReceived(id, payload);
  const expected = Number(payload.audioBytes) || note.audioBytes || 0;

  // `complete` means the bytes are on the PC under their final name (never the .part
  // file). `safeToDelete` is the stricter promise the Mac erases a lecture on, so it
  // also requires the note to have finished: at 'ready' the whisper transcript and the
  // markdown both exist on disk, so the audio is no longer the only copy of the content.
  const complete = got.complete && (!expected || got.bytes === expected);
  const safeToDelete = complete && note.state === 'ready';

  send(res, 200, {
    ok: true, id,
    received: got.bytes,
    expected,
    complete,
    state: note.state,
    safeToDelete,
    notePath: note.notePath || null,
    transcriptPath: note.transcriptPath || null,
  }, CORS);
}

/**
 * GET /api/audio/{id} - the recording, back again.
 *
 * The Mac drops its local copy once safeToDelete goes true, so from that point this is
 * the only way to hear a lecture. Range requests are honoured because that is what a
 * seeking player asks for, and a 45-minute lecture is not something to refetch whole.
 */
function handleAudioGet(req, res, id) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'unknown id ' + id);
  const payload = vault.readInbox(id) || { id, audioFormat: 'm4a', audioBytes: note.audioBytes || 0 };
  const abs = vault.audioAbs(id, payload);

  let st;
  try { st = fs.statSync(abs); }
  catch (_) {
    return fail(res, 404, 'the audio for ' + id + ' is not on the server', { state: note.state });
  }

  const headers = Object.assign({
    'Content-Type': 'audio/mp4',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'private, max-age=3600',
    'Content-Disposition': "inline; filename*=UTF-8''" + encodeURIComponent(id + '.m4a'),
  }, CORS);

  let start = 0, end = st.size - 1, code = 200;
  const range = /^bytes=(\d*)-(\d*)$/.exec(util.asString(req.headers.range).trim());
  if (range && !(range[1] === '' && range[2] === '')) {
    if (range[1] === '') start = Math.max(0, st.size - Number(range[2]));   // bytes=-500
    else {
      start = Number(range[1]);
      if (range[2] !== '') end = Math.min(end, Number(range[2]));
    }
    if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= st.size) {
      res.writeHead(416, Object.assign({ 'Content-Range': 'bytes */' + st.size }, CORS));
      return res.end();
    }
    code = 206;
    headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + st.size;
  }
  headers['Content-Length'] = end - start + 1;

  if (req.method === 'HEAD') { res.writeHead(code, headers); return res.end(); }
  res.writeHead(code, headers);
  const stream = fs.createReadStream(abs, { start, end });
  stream.on('error', e => {
    log.error('streaming audio', id, 'failed -', e.message);
    try { res.destroy(); } catch (_) {}
  });
  stream.pipe(res);
}

async function handleCapture(req, res) {
  const body = await readJsonBody(req, res);
  if (!body) return;

  const id = util.asString(body.id).trim() || crypto.randomUUID();
  const text = util.asString(body.text).trim();
  if (!text) return fail(res, 400, 'text is required');

  let kind = util.asString(body.kind, 'auto').toLowerCase().trim() || 'auto';
  if (!['auto', 'todo', 'homework', 'note'].includes(kind)) kind = 'auto';

  const payload = {
    id, text, kind,
    capturedAt: util.normIso(body.capturedAt),
    device: util.asString(body.device),
    receivedAt: util.nowIso(),
    _capture: true,
  };
  try { vault.saveInbox(payload); }
  catch (e) { return fail(res, 500, 'could not write to the vault: ' + e.message); }

  log.info('captured', id, JSON.stringify(text.slice(0, 120)), 'kind=' + kind);
  send(res, 202, { ok: true, id, state: 'queued' }, CORS);

  pipeline.emitState(id, 'queued', 'queued');
  pipeline.enqueue({ type: 'capture', id, payload });
}

function handleNotes(req, res) {
  send(res, 200, {
    courses: store.courseSummaries(),
    notes: store.notesSorted(),
    todos: store.allTodos(),
  }, CORS);
}

function handleNote(req, res, id) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'no note with id ' + id);
  send(res, 200, Object.assign({}, note, {
    markdown: vault.readNoteMarkdown(note),
    transcript: vault.readNoteTranscript(note),
  }), CORS);
}

function handleReprocess(req, res, id, retranscribe) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'no note with id ' + id);
  if (pipeline.isBusy(id)) {
    return send(res, 202, { ok: true, id, state: note.state, alreadyQueued: true }, CORS);
  }

  const payload = vault.readInbox(id) || {
    id, title: note.title,
    recordedAt: note.recordedAt, durationSec: note.durationSec,
    audioFormat: (note.audioPath || 'x.m4a').split('.').pop(),
    audioBytes: note.audioBytes || 0,
    locale: 'en_US', device: 'reprocess',
  };

  const haveTranscript = !!(note.transcriptPath && fs.existsSync(vault.abs(note.transcriptPath)));
  const haveAudio = fs.existsSync(vault.audioAbs(id, payload));
  const wantRetranscribe = retranscribe || !haveTranscript;

  if (wantRetranscribe && !haveAudio && !util.asString(payload.draftTranscript).trim()) {
    return fail(res, 409, 'nothing to reprocess for ' + id + ' - no transcript and no audio on disk');
  }
  try { vault.saveInbox(payload); } catch (_) {}

  const next = wantRetranscribe ? 'transcribing' : 'processing';
  note.state = next;
  delete note.error;
  store.putNote(note);
  log.info('reprocess requested for', id, wantRetranscribe ? '(re-transcribing)' : '(claude pass only)');
  send(res, 202, { ok: true, id, state: next, retranscribe: wantRetranscribe }, CORS);

  pipeline.emitState(id, next, 'reprocess queued');
  pipeline.enqueue({ type: 'note', id, payload, retranscribe: wantRetranscribe });
}

// Extension beyond PROTOCOL.md: lets a client tick a checkbox off.
function handleTodoDone(req, res, id, done) {
  const t = store.setTodoDone(id, done);
  if (!t) return fail(res, 404, 'no todo with id ' + id);
  store.save(true);
  send(res, 200, { ok: true, todo: t }, CORS);
  pipeline.emitTodos();
}

/**
 * GET /api/search?q=&course=&kind=&limit=&regex=1 - full text across the vault.
 *
 * Runs here rather than on the caller because this is where the files are; see
 * lib/search.js. Returns snippets and refs, never whole documents.
 */
function handleSearch(req, res, url) {
  let out;
  try {
    out = search.search({
      q: url.searchParams.get('q'),
      course: url.searchParams.get('course'),
      kind: url.searchParams.get('kind'),
      limit: url.searchParams.get('limit'),
      regex: /^(1|true)$/i.test(util.asString(url.searchParams.get('regex'))),
    });
  } catch (e) {
    return fail(res, 400, e.message);
  }
  log.info('search', JSON.stringify(out.query), '-', out.matched, 'of', out.scanned, 'file(s)');
  send(res, 200, Object.assign({ ok: true }, out), CORS);
}

/**
 * GET /api/vault/status - what is on disk and what looks wrong with it.
 *
 * This is the "does anything need resyncing?" answer: per-course counts, files whose
 * text never extracted, and manifest entries that collide on one path (a Canvas
 * re-upload gets a new id but the same display name, so the newer revision overwrites
 * the older and two entries end up describing a file that is no longer there).
 */
function handleVaultStatus(req, res) {
  const collisions = search.collisions();
  const problems = search.extractProblems();
  const courses = [];
  for (const c of store.courseSummaries(true)) {
    const m = materials.readManifest(c.name);
    const files = (m && m.files) ? Object.values(m.files) : [];
    courses.push({
      course: c.name,
      canvasCourseId: (m && m.canvasCourseId) || null,
      courseCode: (m && m.courseCode) || null,
      noteCount: c.noteCount || 0,
      lastClass: c.lastClass || null,
      fileEntries: files.length,
      distinctFiles: new Set(files.map(f => f.path).filter(Boolean)).size,
      textChars: files.reduce((n, f) => n + ((f.extract && f.extract.chars) || 0), 0),
      modules: (m && m.modules || []).map(x => x.folder || x.name),
      syncedAt: (m && m.syncedAt) || null,
    });
  }
  send(res, 200, {
    ok: true,
    canvas: canvas.status(),
    syncing: materials.isSyncing(),
    lastSync: materials.last(),
    courses,
    needsAttention: {
      extractFailures: problems,
      pathCollisions: collisions,
    },
  }, CORS);
}

/** GET /api/documents?course=&kind=&name=&module=&limit= - browse refs without text. */
function handleDocuments(req, res, url) {
  const out = search.list({
    course: url.searchParams.get('course'),
    kind: url.searchParams.get('kind'),
    name: url.searchParams.get('name'),
    module: url.searchParams.get('module'),
    limit: url.searchParams.get('limit'),
  });
  send(res, 200, Object.assign({ ok: true }, out), CORS);
}

/** GET /api/document?ref=<kind:id> - the full text behind any search result. */
function handleDocument(req, res, url) {
  const ref = util.asString(url.searchParams.get('ref')).trim();
  if (!ref) return fail(res, 400, 'a ref is required');
  const r = search.readRef(ref);
  if (r.error) return fail(res, 404, r.error);
  send(res, 200, { ok: true, ref, meta: r.meta, chars: r.text.length, text: r.text }, CORS);
}

/**
 * PATCH /api/note/{id} - rename a note.
 *
 * Only the student's typed title. The course, topic, section and dates are Claude's
 * output and the vault path is derived from them, so a rename never moves a file - which
 * is what keeps this cheap enough to do from a context menu.
 */
async function handleNoteRename(req, res, id) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'unknown id ' + id);

  const body = await readJsonBody(req, res);
  if (!body) return;
  const title = util.asString(body.title).trim();
  if (!title) return fail(res, 400, 'a non-empty title is required');
  if (title.length > 200) return fail(res, 400, 'title is too long (max 200 characters)');

  const before = note.title;
  note.title = title;
  store.putNote(note);
  store.save(true);

  if (note.notePath) vault.setNoteSourceTitle(note.notePath, title);
  // A note still holding an inbox payload has not been filed yet; reprocessing it reads
  // the title back from there and would otherwise re-render under the old name.
  const inbox = vault.readInbox(id);
  if (inbox) { inbox.title = title; vault.saveInbox(inbox); }

  log.info('renamed note', id, JSON.stringify(util.asString(before)), '->', JSON.stringify(title));
  send(res, 200, { ok: true, id, title }, CORS);
  sse.broadcast('note', note);
}

/**
 * DELETE /api/note/{id} - remove a note and everything derived from it.
 *
 * The vault is the product, so this deletes for real: the markdown, the transcript and
 * its whisper sidecar, the audio, the inbox payload, and any deadlines this lecture
 * produced. There is no undo and none is implied - the app asks first.
 *
 * Refused while the pipeline holds the note, because deleting the audio out from under a
 * running whisper job produces a confusing failure instead of a clean one.
 */
function handleNoteDelete(req, res, id) {
  const note = store.getNote(id);
  if (!note) return fail(res, 404, 'unknown id ' + id);
  if (pipeline.isBusy(id)) {
    return fail(res, 409, 'this note is being processed right now - try again in a moment');
  }

  const payload = vault.readInbox(id) || { id, audioFormat: (note.audioPath || '.m4a').split('.').pop() };
  const removed = [];

  // The transcript's whisper sidecar sits beside it as .json.
  if (note.transcriptPath) {
    removed.push(note.transcriptPath);
    vault.removeFileQuiet(note.transcriptPath);
    vault.removeFileQuiet(note.transcriptPath.replace(/\.txt$/i, '.json'));
  }
  if (note.notePath) { removed.push(note.notePath); vault.removeFileQuiet(note.notePath); }

  for (const abs of [vault.audioAbs(id, payload), vault.audioPartAbs(id, payload)]) {
    try { fs.unlinkSync(abs); removed.push(vault.rel(abs)); } catch (_) {}
  }
  vault.deleteInbox(id);

  store.replaceTodosForSource('note:' + id, []);
  store.removeNote(id);
  store.save(true);

  log.info('deleted note', id, '-', util.asString(note.title), '|', removed.length, 'file(s)');
  send(res, 200, { ok: true, id, removed }, CORS);
  sse.broadcast('note-deleted', { id });
  pipeline.emitTodos();
}

// Extension beyond PROTOCOL.md: rebuild the derived index from the markdown files.
function handleReindex(req, res) {
  const r = vault.rebuildIndex();
  send(res, 200, Object.assign({ ok: true }, r), CORS);
  pipeline.emitTodos();
}

// ------------------------------------------------------------------ canvas
/**
 * The Mac app signs into Canvas in a real WKWebView (Microsoft SAML SSO, MFA and
 * all) and posts the resulting cookie here. We never see a password, and the
 * cookie never goes anywhere except https://<CANVAS_HOST>/.
 */
async function handleCanvasSession(req, res) {
  const body = await readJsonBody(req, res);
  if (!body) return;
  const host = util.asString(body.host, cfg.CANVAS_HOST).trim().toLowerCase();
  const cookie = util.asString(body.cookie).trim();
  if (!cookie) return fail(res, 400, 'cookie is required');
  if (!/^[a-z0-9.-]+\.instructure\.com$|^[a-z0-9.-]+\.[a-z]{2,}$/.test(host)) {
    return fail(res, 400, 'host does not look like a canvas hostname');
  }
  if (cookie.length > 16000) return fail(res, 400, 'cookie header is implausibly large');

  canvas.saveSession(host, cookie, null);
  try {
    const user = await canvas.verify();
    sse.broadcast('canvas', canvas.status());
    log.info('canvas connected as', user.name || '(unknown)', '| host', host);
    send(res, 200, { ok: true, user, status: canvas.status() }, CORS);
  } catch (e) {
    // A cookie that does not actually work is worse than none: it would make every
    // later sync look like "nothing new". Refuse to keep it.
    canvas.clearSession();
    sse.broadcast('canvas', canvas.status());
    log.error('canvas session rejected -', e.message);
    fail(res, 400, 'canvas rejected that session: ' + e.message);
  }
}

function handleCanvasStatus(req, res) {
  send(res, 200, { ok: true, canvas: canvas.status() }, CORS);
}

function handleCanvasDisconnect(req, res) {
  canvas.clearSession();
  sse.broadcast('canvas', canvas.status());
  send(res, 200, { ok: true, canvas: canvas.status() }, CORS);
}

/**
 * Diagnostic: what does this Canvas account actually expose? Reports, per course,
 * whether modules / files / assignments are readable, because a student account
 * with the Files tab locked is the normal case and changes how we find material.
 */
async function handleCanvasProbe(req, res) {
  if (!canvas.hasSession()) return fail(res, 409, 'canvas is not connected');
  const out = { host: canvas.status().host, user: canvas.status().user, courses: [] };
  try {
    const courses = await canvas.apiAll(
      '/api/v1/courses?enrollment_state=active&include[]=term&state[]=available');
    for (const c of courses) {
      const entry = {
        id: String(c.id), name: c.name || null, code: c.course_code || null,
        term: (c.term && c.term.name) || null, counts: {}, errors: {},
      };
      for (const [key, p] of [
        ['modules', '/api/v1/courses/' + c.id + '/modules?include[]=items&per_page=100'],
        ['files', '/api/v1/courses/' + c.id + '/files?per_page=1'],
        ['assignments', '/api/v1/courses/' + c.id + '/assignments?per_page=100'],
        ['pages', '/api/v1/courses/' + c.id + '/pages?per_page=100'],
        ['announcements', '/api/v1/announcements?context_codes[]=course_' + c.id + '&per_page=10'],
      ]) {
        try {
          const rows = await canvas.apiAll(p);
          entry.counts[key] = rows.length;
          if (key === 'modules') {
            entry.moduleItemTypes = {};
            for (const m of rows) {
              for (const it of (m.items || [])) {
                entry.moduleItemTypes[it.type] = (entry.moduleItemTypes[it.type] || 0) + 1;
              }
            }
          }
        } catch (e) {
          entry.errors[key] = e.code || e.message;
          if (e.code === 'CANVAS_AUTH') { out.expired = true; break; }
        }
      }
      out.courses.push(entry);
      if (out.expired) break;
    }
    send(res, 200, { ok: true, probe: out }, CORS);
  } catch (e) {
    fail(res, e.code === 'CANVAS_AUTH' ? 401 : 502, e.message, { canvas: canvas.status() });
  }
}

async function handleCanvasSync(req, res) {
  if (!canvas.hasSession()) return fail(res, 409, 'canvas is not connected', { canvas: canvas.status() });
  if (materials.isSyncing()) {
    return send(res, 202, { ok: true, started: false, alreadyRunning: true }, CORS);
  }
  const body = (await readJsonBody(req, res).catch(() => ({}))) || {};
  const opts = {
    full: !!body.full,
    reglossary: !!body.reglossary,
    courseIds: Array.isArray(body.courseIds) ? body.courseIds.map(String) : null,
  };
  // Fire and forget: a full sync downloads slide decks and can run for minutes.
  // Progress goes out over SSE; the result lands in /api/health and /api/materials.
  materials.sync(opts).catch(e => log.error('canvas sync crashed -', e.stack || e.message));
  send(res, 202, { ok: true, started: true }, CORS);
}

/** The extracted text of one synced file, so the Mac can read it without the PC's disk. */
function handleMaterialText(req, res, url) {
  const course = url.searchParams.get('course');
  const id = url.searchParams.get('id');
  if (!course || !id) return fail(res, 400, 'course and id are required');
  const m = materials.readManifest(course);
  const f = m && m.files && m.files[id];
  if (!f) return fail(res, 404, 'no such synced file');
  let text = null;
  if (f.textPath) {
    try { text = fs.readFileSync(path.join(cfg.VAULT, f.textPath.split('/').join(path.sep)), 'utf8'); }
    catch (e) { log.warn('material text unreadable', f.textPath, '-', e.message); }
  }
  send(res, 200, {
    ok: true, course, file: f, text,
    canvasUrl: m.canvasCourseId
      ? 'https://' + canvas.status().host + '/courses/' + m.canvasCourseId + '/files/' + id
      : null,
  }, CORS);
}

/**
 * The raw bytes of a synced file, so the Mac can render the actual PDF / slide deck
 * rather than only the text pulled out of it.
 *
 * The path is taken from the manifest by file id, never from the query, so no input
 * here can escape the vault.
 */
function handleMaterialFile(req, res, url) {
  const course = url.searchParams.get('course');
  const id = url.searchParams.get('id');
  if (!course || !id) return fail(res, 400, 'course and id are required');
  const m = materials.readManifest(course);
  const f = m && m.files && m.files[id];
  if (!f || !f.path) return fail(res, 404, 'no such synced file');

  const abs = path.join(cfg.VAULT, f.path.split('/').join(path.sep));
  const resolved = path.resolve(abs);
  if (!resolved.startsWith(path.resolve(cfg.VAULT) + path.sep)) {
    log.error('refusing to serve a path outside the vault:', resolved);
    return fail(res, 400, 'bad path');
  }
  let st;
  try { st = fs.statSync(resolved); }
  catch (e) { return fail(res, 404, 'file is not on disk: ' + e.message); }

  const type = f.contentType || 'application/octet-stream';
  const headers = Object.assign({
    'Content-Type': type,
    'Content-Length': st.size,
    'Cache-Control': 'private, max-age=3600',
    // filename* so a name with an em dash survives the header.
    'Content-Disposition': "inline; filename*=UTF-8''" +
      encodeURIComponent(f.name || path.basename(resolved)),
    'X-Notables-Extract': (f.extract && f.extract.method) || 'none',
  }, CORS);

  if (req.method === 'HEAD') { res.writeHead(200, headers); return res.end(); }
  res.writeHead(200, headers);
  const stream = fs.createReadStream(resolved);
  stream.on('error', e => {
    log.error('streaming', f.path, 'failed -', e.message);
    try { res.destroy(); } catch (_) {}
  });
  stream.pipe(res);
}

function handleMaterials(req, res, url) {
  const wanted = url.searchParams.get('course');
  if (wanted) {
    const m = materials.forCourse(wanted);
    if (!m) return fail(res, 404, 'no synced materials for ' + wanted);
    return send(res, 200, { ok: true, course: wanted, materials: m }, CORS);
  }
  const out = [];
  for (const c of store.courseSummaries(true)) {
    const m = materials.readManifest(c.name);
    if (!m) continue;
    out.push({
      course: c.name,
      canvasCourseId: m.canvasCourseId,
      canvasName: m.canvasName,
      courseCode: m.courseCode,
      term: m.term,
      syncedAt: m.syncedAt,
      moduleCount: (m.modules || []).length,
      fileCount: Object.keys(m.files || {}).length,
      textChars: Object.values(m.files || {})
        .reduce((n, f) => n + ((f.extract && f.extract.chars) || 0), 0),
      problems: ((m.lastRun && m.lastRun.failed) || []).length,
      glossaryTerms: (c.glossary || []).length,
      indexPath: 'Course Materials/' + c.name + '/_Index.md',
    });
  }
  send(res, 200, { ok: true, courses: out, syncing: materials.isSyncing(), lastSync: materials.last() }, CORS);
}

// -------------------------------------------------------------------- chat
/**
 * POST /api/chat - one turn, streamed back as newline-delimited JSON.
 *
 * Deliberately NOT over the SSE channel. That stream has been observed dying silently
 * for hours (see CLAUDE.md), and a chat that quietly stops printing is worse than no
 * chat. Here the turn owns its own response body: if the connection drops, the request
 * visibly fails.
 */
async function handleChat(req, res) {
  const body = await readJsonBody(req, res);
  if (!body) return;

  const text = util.asString(body.text).trim();
  const attachments = Array.isArray(body.attachments) ? body.attachments.map(String) : [];
  if (!text && !attachments.length) return fail(res, 400, 'text is required');

  let scope;
  try { scope = chat.resolveScope(body.scope || {}); }
  catch (e) { return fail(res, e.code === 'NO_COURSE' || e.code === 'NO_FILE' ? 404 : 400, e.message); }

  res.writeHead(200, Object.assign({
    'Content-Type': 'application/x-ndjson; charset=utf-8',
    'Cache-Control': 'no-store',
    // Nothing between here and the Mac should be holding these lines back.
    'X-Accel-Buffering': 'no',
  }, CORS));

  const write = obj => { try { res.write(JSON.stringify(obj) + '\n'); } catch (_) {} };
  write({ t: 'scope', kind: scope.kind, label: scope.label, course: scope.course, model: chat.MODEL });

  let closed = false;
  req.on('close', () => { closed = true; });

  try {
    const out = await chat.send({
      scope: body.scope || {},
      sessionId: util.asString(body.sessionId).trim() || null,
      text,
      attachments,
      onEvent: e => { if (!closed) write(e); },
    });
    write({ t: 'done', sessionId: out.id, text: out.text, meta: out.meta });
  } catch (e) {
    log.error('chat turn failed -', e.message);
    write({ t: 'error', message: e.message });
  }
  try { res.end(); } catch (_) {}
}

/** GET /api/chat/sessions - the resume list, newest first. */
function handleChatSessions(req, res, url) {
  const course = url.searchParams.get('course');
  const scope = course ? {
    course,
    module: url.searchParams.get('module') || '',
    fileId: url.searchParams.get('fileId') || '',
  } : null;
  send(res, 200, { ok: true, model: chat.MODEL, sessions: chat.listSessions(scope) }, CORS);
}

/** GET /api/chat/session/{id} - the stored transcript, so the app can redraw it. */
function handleChatSession(req, res, id) {
  const t = chat.readTranscript(id);
  if (!t) return fail(res, 404, 'no such conversation');
  send(res, 200, { ok: true, session: t }, CORS);
}

function handleChatSessionDelete(req, res, id) {
  if (!chat.deleteSession(id)) return fail(res, 404, 'no such conversation');
  send(res, 200, { ok: true, id }, CORS);
}

/**
 * POST /api/chat/attachment?session=<id>&name=<filename> - raw body, one file.
 * Returns the absolute path, which the next /api/chat call passes in `attachments`.
 */
async function handleChatAttachment(req, res, url) {
  const sessionId = util.asString(url.searchParams.get('session')).trim();
  const name = util.asString(url.searchParams.get('name')).trim() || 'upload';
  if (!/^[0-9a-fA-F-]{8,64}$/.test(sessionId)) return fail(res, 400, 'a session id is required');

  let buf;
  try { buf = await readRawBody(req, cfg.MAX_BODY_BYTES); }
  catch (e) { return fail(res, e.code === 'TOO_LARGE' ? 413 : 400, e.message); }
  if (!buf.length) return fail(res, 400, 'empty body');

  try {
    const file = chat.saveAttachment(sessionId, name, buf);
    log.info('chat attachment', path.basename(file), buf.length, 'bytes');
    send(res, 200, { ok: true, path: file, name: path.basename(file), bytes: buf.length }, CORS);
  } catch (e) {
    fail(res, 500, 'could not save the attachment: ' + e.message);
  }
}

// ------------------------------------------------------------------ router
const server = http.createServer(async (req, res) => {
  let url;
  try { url = new URL(req.url, 'http://localhost'); }
  catch (_) { return fail(res, 400, 'bad url'); }
  const p = url.pathname.replace(/\/+$/, '') || '/';
  const method = req.method.toUpperCase();

  res.setHeader('X-Notables-Version', cfg.VERSION);

  try {
    if (method === 'OPTIONS') { res.writeHead(204, CORS); return res.end(); }

    // /api/health is deliberately unauthenticated so a reachability check is cheap.
    if (p === '/api/health' && (method === 'GET' || method === 'HEAD')) return await handleHealth(req, res);
    if (p === '/' && method === 'GET') {
      return send(res, 200, { ok: true, service: 'notables-note-server', version: cfg.VERSION }, CORS);
    }

    if (!authorised(req, url)) {
      log.warn('401', method, p, 'from', req.socket.remoteAddress);
      res.setHeader('WWW-Authenticate', 'Bearer realm="notables"');
      return fail(res, 401, 'unauthorized');
    }

    if (p === '/api/events' && method === 'GET') { sse.attach(req, res); return; }
    if (p === '/api/notes' && method === 'GET') return handleNotes(req, res);
    if (p === '/api/ingest' && method === 'POST') return await handleIngest(req, res);
    if (p === '/api/capture' && method === 'POST') return await handleCapture(req, res);
    if (p === '/api/reindex' && method === 'POST') return handleReindex(req, res);

    if (p === '/api/canvas/status' && method === 'GET') return handleCanvasStatus(req, res);
    if (p === '/api/canvas/session' && method === 'POST') return await handleCanvasSession(req, res);
    if (p === '/api/canvas/disconnect' && method === 'POST') return handleCanvasDisconnect(req, res);
    if (p === '/api/canvas/probe' && method === 'GET') return await handleCanvasProbe(req, res);
    if (p === '/api/canvas/sync' && method === 'POST') return await handleCanvasSync(req, res);
    if (p === '/api/search' && method === 'GET') return handleSearch(req, res, url);
    if (p === '/api/documents' && method === 'GET') return handleDocuments(req, res, url);
    if (p === '/api/document' && method === 'GET') return handleDocument(req, res, url);
    if (p === '/api/vault/status' && method === 'GET') return handleVaultStatus(req, res);
    if (p === '/api/materials' && method === 'GET') return handleMaterials(req, res, url);
    if (p === '/api/material' && method === 'GET') return handleMaterialText(req, res, url);
    if (p === '/api/material/file' && (method === 'GET' || method === 'HEAD')) return handleMaterialFile(req, res, url);

    let m = /^\/api\/audio\/([^/]+)$/.exec(p);
    if (m && (method === 'PUT' || method === 'POST')) return handleAudioPut(req, res, decodeURIComponent(m[1]));
    if (m && (method === 'GET' || method === 'HEAD')) return handleAudioGet(req, res, decodeURIComponent(m[1]));

    m = /^\/api\/audio\/([^/]+)\/status$/.exec(p);
    if (m && method === 'GET') return handleAudioStatus(req, res, decodeURIComponent(m[1]));

    if (p === '/api/chat' && method === 'POST') return await handleChat(req, res);
    if (p === '/api/chat/sessions' && method === 'GET') return handleChatSessions(req, res, url);
    if (p === '/api/chat/attachment' && method === 'POST') return await handleChatAttachment(req, res, url);

    m = /^\/api\/chat\/session\/([^/]+)$/.exec(p);
    if (m && method === 'GET') return handleChatSession(req, res, decodeURIComponent(m[1]));
    if (m && method === 'DELETE') return handleChatSessionDelete(req, res, decodeURIComponent(m[1]));

    m = /^\/api\/note\/([^/]+)\/reprocess$/.exec(p);
    if (m && method === 'POST') {
      const rt = url.searchParams.get('retranscribe');
      return handleReprocess(req, res, decodeURIComponent(m[1]), rt === '1' || rt === 'true');
    }

    m = /^\/api\/note\/([^/]+)$/.exec(p);
    if (m && method === 'GET') return handleNote(req, res, decodeURIComponent(m[1]));
    if (m && method === 'DELETE') return handleNoteDelete(req, res, decodeURIComponent(m[1]));
    if (m && method === 'PATCH') return await handleNoteRename(req, res, decodeURIComponent(m[1]));

    m = /^\/api\/todo\/([^/]+)\/(done|undone)$/.exec(p);
    if (m && method === 'POST') return handleTodoDone(req, res, decodeURIComponent(m[1]), m[2] === 'done');

    fail(res, 404, 'no route for ' + method + ' ' + p);
  } catch (e) {
    log.error('unhandled request error', method, p, '-', e.stack || e.message);
    if (!res.headersSent) fail(res, 500, 'internal error: ' + e.message);
    else try { res.end(); } catch (_) {}
  }
});

server.headersTimeout = 0;
server.requestTimeout = 0;
server.timeout = 0;
server.keepAliveTimeout = 120000;

// ------------------------------------------------------------------- boot
function requeueOrphans() {
  let n = 0;
  for (const note of store.state.notes.values()) {
    // awaiting_audio is not an orphan - it is waiting on the Mac, not on us.
    if (note.state === 'transcribing' || note.state === 'processing' || note.state === 'queued') {
      pipeline.enqueue({ type: 'note', id: note.id, payload: vault.readInbox(note.id) });
      n++;
    }
  }
  // Captures whose inbox file survived a crash.
  let entries = [];
  try { entries = fs.readdirSync(cfg.DIRS.inbox); } catch (_) {}
  for (const f of entries) {
    if (!f.endsWith('.json')) continue;
    const id = f.slice(0, -5);
    if (store.getNote(id)) continue;
    const payload = store.readJson(path.join(cfg.DIRS.inbox, f), null);
    if (payload && payload._capture) { pipeline.enqueue({ type: 'capture', id, payload }); n++; }
  }
  if (n) log.info('requeued', n, 'unfinished job(s) from the last run');
}

/**
 * Keep course materials fresh without anyone asking. A first sync happens shortly
 * after boot (the PC wakes long before Kieran opens the Mac app), then on a slow
 * timer. A dead Canvas session does NOT retry in a loop - it waits to be
 * reconnected, and says so.
 */
function startCanvasSchedule() {
  if (!canvas.hasSession()) {
    log.info('canvas: not connected - materials sync idle until the Mac app connects');
    return;
  }
  const run = why => {
    if (materials.isSyncing()) return;
    if (canvas.status().expiredAt) {
      log.warn('canvas: session expired - skipping scheduled sync, reconnect from the Mac app');
      return;
    }
    log.info('canvas: scheduled sync (' + why + ')');
    materials.sync({}).catch(e => log.error('scheduled canvas sync failed -', e.message));
  };
  setTimeout(() => run('startup'), 30000).unref?.();
  const t = setInterval(() => run('interval'), cfg.CANVAS_SYNC_INTERVAL_MS);
  if (t.unref) t.unref();
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--help') || argv.includes('-h')) {
    console.log([
      'notables note-server ' + cfg.VERSION,
      '',
      '  node note-server.js                 start the server',
      '  node note-server.js --rebuild-index rebuild _index.json from the markdown, then exit',
      '  node note-server.js --version',
      '',
      'Environment: NOTABLES_VAULT NOTABLES_PORT NOTABLES_HOST NOTABLES_TOKEN_FILE',
      '             NOTABLES_CLAUDE_BIN NOTABLES_MODEL NOTABLES_TZ NOTABLES_DEBUG',
      '             NOTABLES_PYTHON NOTABLES_WHISPER_MODEL NOTABLES_WHISPER_DEVICE',
      '             NOTABLES_WHISPER_COMPUTE NOTABLES_WHISPER_MODEL_DIR',
    ].join('\n'));
    return;
  }
  if (argv.includes('--version')) { console.log(cfg.VERSION); return; }

  vault.ensureDirs();

  if (argv.includes('--rebuild-index')) {
    const r = vault.rebuildIndex();
    console.log(JSON.stringify(r));
    return;
  }

  store.load();

  server.on('error', e => {
    if (e.code === 'EADDRINUSE') {
      // The 5-minute watchdog task starts us blindly; this is the normal outcome.
      process.stdout.write('port ' + cfg.PORT + ' already in use - another instance is running\n');
      process.exit(0);
    }
    log.error('server error:', e.message);
    process.exit(1);
  });

  server.listen(cfg.PORT, cfg.HOST, () => {
    log.info('notables note-server ' + cfg.VERSION + ' listening on ' + cfg.HOST + ':' + cfg.PORT);
    log.info('vault:', cfg.VAULT, '| model:', cfg.MODEL, '| tz:', cfg.TZ, '| node', process.version);
    if (!loadToken()) log.error('NO TOKEN LOADED - every authenticated request will 401');
    claude.checkHealth(true).then(ok => log.info('claude reachable:', ok));
    whisper.checkHealth(true).then(ok => log.info('whisper/cuda ready:', ok, '-', whisper.detail()));
    requeueOrphans();
    startCanvasSchedule();
  });

  const bye = sig => () => { log.info('shutting down on ' + sig); store.save(true); process.exit(0); };
  process.on('SIGINT', bye('SIGINT'));
  process.on('SIGTERM', bye('SIGTERM'));
  process.on('uncaughtException', e => { log.error('uncaught:', e.stack || e.message); });
  process.on('unhandledRejection', e => { log.error('unhandled rejection:', (e && e.stack) || e); });
}

if (require.main === module) main();
module.exports = { server, main };
