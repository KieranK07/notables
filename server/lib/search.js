'use strict';
// Full-text search across the vault: Canvas course materials, lecture notes, and
// verbatim transcripts.
//
// This runs on the PC because that is where the files are. The Mac<->PC link is a DERP
// relay at ~1.6 MB/s and the extracted material text alone is well over a megabyte, so
// searching from the other end would mean dragging the whole corpus across the network
// for every query. Snippets go back, not documents; a caller that wants the whole thing
// asks for the ref.
//
// Everything searchable is addressed by a single `ref` string so a caller can chain
// search -> read without knowing which of the three kinds it found:
//
//   material:<course>/<canvasFileId>      the extracted text of a Canvas file
//   note:<noteId>                         the markdown study notes
//   transcript:<noteId>                   the verbatim lecture transcript
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const store = require('./store');
const materials = require('./materials');
const { asString } = require('./util');

const KINDS = ['material', 'note', 'transcript'];
const SNIPPET_RADIUS = 110;     // characters either side of a hit
const MAX_PER_DOC = 3;          // snippets from any one file
const MAX_SCAN_CHARS = 4_000_000;

function absOf(relPath) {
  return path.join(cfg.VAULT, String(relPath).split('/').join(path.sep));
}

function readText(relPath) {
  try { return fs.readFileSync(absOf(relPath), 'utf8'); } catch (_) { return null; }
}

// --------------------------------------------------------------------- refs
function parseRef(ref) {
  const s = asString(ref).trim();
  const cut = s.indexOf(':');
  if (cut === -1) return null;
  const kind = s.slice(0, cut);
  const rest = s.slice(cut + 1);
  if (kind === 'note' || kind === 'transcript') {
    return rest ? { kind, id: rest } : null;
  }
  if (kind === 'material') {
    // course names contain "/" nowhere, but they do contain spaces and "&"
    const slash = rest.lastIndexOf('/');
    if (slash <= 0) return null;
    return { kind, course: rest.slice(0, slash), id: rest.slice(slash + 1) };
  }
  return null;
}

/** Resolve a ref to `{ text, meta }`, or `{ error }`. */
function readRef(ref) {
  const p = parseRef(ref);
  if (!p) return { error: 'not a valid ref: ' + asString(ref) };

  if (p.kind === 'material') {
    const m = materials.readManifest(p.course);
    const f = m && m.files && m.files[p.id];
    if (!f) return { error: 'no synced file ' + p.id + ' in ' + p.course };
    if (!f.textPath) return { error: 'no extracted text for ' + f.name + ' (extract state: ' +
                                     ((f.extract && f.extract.state) || 'unknown') + ')' };
    const text = readText(f.textPath);
    if (text == null) return { error: 'the extracted text is not on disk: ' + f.textPath };
    return { text, meta: materialMeta(p.course, p.id, f) };
  }

  const note = store.getNote(p.id);
  if (!note) return { error: 'no such note ' + p.id };
  const rel = p.kind === 'note' ? note.notePath : note.transcriptPath;
  if (!rel) return { error: 'this note has no ' + p.kind + ' yet (state: ' + note.state + ')' };
  const text = readText(rel);
  if (text == null) return { error: 'the file is not on disk: ' + rel };
  return { text, meta: noteMeta(p.kind, note) };
}

function materialMeta(course, id, f) {
  return {
    ref: 'material:' + course + '/' + id,
    kind: 'material',
    course,
    title: f.name,
    module: f.module || null,
    contentType: f.contentType || null,
    bytes: f.size || 0,
    chars: (f.extract && f.extract.chars) || 0,
    extractState: (f.extract && f.extract.state) || null,
    path: f.path || null,
    updatedAt: f.updatedAt || null,
    syncedAt: f.syncedAt || null,
  };
}

function noteMeta(kind, note) {
  return {
    ref: kind + ':' + note.id,
    kind,
    course: note.course || null,
    title: note.topic || note.title || '',
    recordingTitle: note.title || '',
    classDate: note.classDate || null,
    section: note.section || null,
    durationSec: note.durationSec || 0,
    path: (kind === 'note' ? note.notePath : note.transcriptPath) || null,
  };
}

// ------------------------------------------------------------------- corpus
/** Every searchable document, with the metadata that makes a hit worth reading. */
function corpus(opts) {
  const wantCourse = opts.course ? String(opts.course).toLowerCase() : null;
  const kinds = opts.kinds;
  const docs = [];

  if (kinds.has('material')) {
    for (const course of store.courseNames()) {
      if (wantCourse && course.toLowerCase() !== wantCourse) continue;
      const m = materials.readManifest(course);
      if (!m || !m.files) continue;
      for (const [id, f] of Object.entries(m.files)) {
        if (!f.textPath) continue;                    // nothing extracted, nothing to search
        docs.push({ meta: materialMeta(course, id, f), textPath: f.textPath });
      }
    }
  }

  for (const note of store.notesSorted()) {
    if (wantCourse && String(note.course || '').toLowerCase() !== wantCourse) continue;
    if (kinds.has('note') && note.notePath) {
      docs.push({ meta: noteMeta('note', note), textPath: note.notePath });
    }
    if (kinds.has('transcript') && note.transcriptPath) {
      docs.push({ meta: noteMeta('transcript', note), textPath: note.transcriptPath });
    }
  }
  return dedupe(docs);
}

/**
 * Collapse documents that are the same file on disk.
 *
 * A Canvas file gets a NEW id every time the instructor re-uploads it, and the sync
 * writes it under its display name - so three revisions of "Mod2.pdf" are three manifest
 * entries pointing at one path, each having overwritten the last. Searching then reads
 * that file three times and reports three identical hits, and two of the three carry a
 * character count that no longer matches anything on disk. Keep the newest entry and
 * hang the superseded refs off it rather than pretending they are separate documents.
 */
function dedupe(docs) {
  const byPath = new Map();
  for (const doc of docs) {
    const key = doc.textPath;
    const prev = byPath.get(key);
    if (!prev) { byPath.set(key, doc); continue; }
    const keep = newer(doc, prev) ? doc : prev;
    const drop = keep === doc ? prev : doc;
    keep.meta.supersedes = (keep.meta.supersedes || []).concat(drop.meta.supersedes || [], [drop.meta.ref]);
    byPath.set(key, keep);
  }
  return Array.from(byPath.values());
}

function stamp(doc) {
  return Date.parse(doc.meta.syncedAt || doc.meta.updatedAt || '') || 0;
}
function newer(a, b) {
  const d = stamp(a) - stamp(b);
  if (d !== 0) return d > 0;
  return (a.meta.chars || 0) > (b.meta.chars || 0);   // no timestamps: trust the fuller extract
}

/**
 * Every document, deduped, as refs plus metadata and no text. What a caller browses
 * before deciding which ref to read.
 */
function list(opts) {
  const kindList = (opts.kind ? String(opts.kind).split(',') : KINDS)
    .map(x => x.trim().toLowerCase()).filter(k => KINDS.includes(k));
  const kinds = new Set(kindList.length ? kindList : KINDS);
  const limit = Math.min(Math.max(parseInt(opts.limit, 10) || 200, 1), 1000);
  const nameNeedle = asString(opts.name).trim().toLowerCase();
  const moduleNeedle = asString(opts.module).trim().toLowerCase();

  let docs = corpus({ course: opts.course, kinds }).map(d => d.meta);
  if (nameNeedle) docs = docs.filter(d => String(d.title || '').toLowerCase().includes(nameNeedle));
  if (moduleNeedle) docs = docs.filter(d => String(d.module || '').toLowerCase().includes(moduleNeedle));

  docs.sort((a, b) =>
    String(a.course).localeCompare(String(b.course)) ||
    String(a.module || '').localeCompare(String(b.module || '')) ||
    String(a.title).localeCompare(String(b.title)));

  return {
    course: opts.course || null,
    kinds: Array.from(kinds),
    total: docs.length,
    truncated: docs.length > limit,
    documents: docs.slice(0, limit),
  };
}

/**
 * Manifest entries that collide on one path - the thing `resync` reports as needing
 * attention. Returns one row per contested path, newest first within each.
 */
function collisions() {
  const out = [];
  for (const course of store.courseNames()) {
    const m = materials.readManifest(course);
    if (!m || !m.files) continue;
    const byPath = new Map();
    for (const [id, f] of Object.entries(m.files)) {
      if (!f.path) continue;
      if (!byPath.has(f.path)) byPath.set(f.path, []);
      byPath.get(f.path).push({
        ref: 'material:' + course + '/' + id,
        id, name: f.name,
        chars: (f.extract && f.extract.chars) || 0,
        syncedAt: f.syncedAt || null, updatedAt: f.updatedAt || null,
      });
    }
    for (const [p, rows] of byPath) {
      if (rows.length < 2) continue;
      rows.sort((a, b) => (Date.parse(b.syncedAt || b.updatedAt || '') || 0) -
                          (Date.parse(a.syncedAt || a.updatedAt || '') || 0));
      out.push({ course, path: p, name: rows[0].name, entries: rows });
    }
  }
  return out;
}

/** Synced files whose text extraction did not succeed - they are searchable by name only. */
function extractProblems() {
  const out = [];
  for (const course of store.courseNames()) {
    const m = materials.readManifest(course);
    if (!m || !m.files) continue;
    for (const [id, f] of Object.entries(m.files)) {
      const st = (f.extract && f.extract.state) || null;
      if (st === 'ok') continue;
      out.push({
        course, ref: 'material:' + course + '/' + id, name: f.name,
        contentType: f.contentType || null,
        state: st || 'never extracted',
        error: (f.extract && f.extract.error) || null,
      });
    }
  }
  return out;
}

// ------------------------------------------------------------------ matching
function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function buildMatcher(q, useRegex) {
  const src = useRegex ? q : escapeRegex(q);
  try { return new RegExp(src, 'gi'); }
  catch (e) { throw Object.assign(new Error('bad regex: ' + e.message), { code: 'BAD_REGEX' }); }
}

/** One-line context around a hit, with the surrounding whitespace flattened. */
function snippet(text, at, len) {
  const from = Math.max(0, at - SNIPPET_RADIUS);
  const to = Math.min(text.length, at + len + SNIPPET_RADIUS);
  const body = text.slice(from, to).replace(/\s+/g, ' ').trim();
  return (from > 0 ? '…' : '') + body + (to < text.length ? '…' : '');
}

/**
 * Search the vault. Returns `{ query, matched, scanned, results }`, results ordered by
 * hit count so the file that talks about the term most lands first.
 */
function search(opts) {
  const q = asString(opts && opts.q).trim();
  if (!q) throw Object.assign(new Error('a query is required'), { code: 'NO_QUERY' });

  const kindList = (opts.kind ? String(opts.kind).split(',') : KINDS)
    .map(s => s.trim().toLowerCase()).filter(k => KINDS.includes(k));
  const kinds = new Set(kindList.length ? kindList : KINDS);
  const limit = Math.min(Math.max(parseInt(opts.limit, 10) || 20, 1), 100);
  const re = buildMatcher(q, !!opts.regex);

  const docs = corpus({ course: opts.course, kinds });
  const results = [];
  let scanned = 0;

  for (const doc of docs) {
    const text = readText(doc.textPath);
    if (text == null) continue;
    scanned++;
    const body = text.length > MAX_SCAN_CHARS ? text.slice(0, MAX_SCAN_CHARS) : text;

    re.lastIndex = 0;
    let hits = 0;
    const snippets = [];
    let m;
    while ((m = re.exec(body)) !== null) {
      hits++;
      if (snippets.length < MAX_PER_DOC) snippets.push(snippet(body, m.index, m[0].length));
      if (m[0].length === 0) re.lastIndex++;          // a zero-width regex would spin forever
      if (hits >= 500) break;
    }
    if (hits) results.push(Object.assign({}, doc.meta, { hits, snippets }));
  }

  results.sort((a, b) => b.hits - a.hits || String(a.title).localeCompare(String(b.title)));
  return {
    query: q,
    regex: !!opts.regex,
    kinds: Array.from(kinds),
    course: opts.course || null,
    scanned,
    matched: results.length,
    truncated: results.length > limit,
    results: results.slice(0, limit),
  };
}

module.exports = { search, list, readRef, parseRef, corpus, collisions, extractProblems, KINDS };
