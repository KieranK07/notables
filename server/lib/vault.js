'use strict';
// Everything that touches the file vault: directory layout, transcript files,
// note markdown, the captures log, and rebuilding _index.json from the markdown.
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const log = require('./log');
const store = require('./store');
const {
  sanitizeName, localDate, isDateString, nowIso, yamlScalar, yamlList, mdPath,
  asArray, asString, slugTag,
} = require('./util');

const EMDASH = '—';
const SEP = ' ' + EMDASH + ' ';

function ensureDirs() {
  for (const d of Object.values(cfg.DIRS)) fs.mkdirSync(d, { recursive: true });
}

/** Vault-relative, forward-slash path. Every path we hand out over the API is one of these. */
function rel(abs) {
  return path.relative(cfg.VAULT, abs).split(path.sep).join('/');
}
function abs(relPath) {
  return path.join(cfg.VAULT, relPath.split('/').join(path.sep));
}

/** Pick a free filename, appending " (2)", " (3)"... Never steals `keepPath`. */
function uniquePath(dir, base, ext, keepAbs) {
  fs.mkdirSync(dir, { recursive: true });
  let candidate = path.join(dir, base + ext);
  let n = 1;
  while (fs.existsSync(candidate) && (!keepAbs || path.resolve(candidate) !== path.resolve(keepAbs))) {
    n++;
    candidate = path.join(dir, base + ' (' + n + ')' + ext);
    if (n > 200) break;
  }
  return candidate;
}

// ------------------------------------------------------------------ inbox
function inboxPath(id) { return path.join(cfg.DIRS.inbox, sanitizeName(id, 'unknown') + '.json'); }

function saveInbox(payload) {
  fs.mkdirSync(cfg.DIRS.inbox, { recursive: true });
  store.writeAtomic(inboxPath(payload.id), JSON.stringify(payload, null, 2));
  return inboxPath(payload.id);
}
function readInbox(id) { return store.readJson(inboxPath(id), null); }
function deleteInbox(id) { try { fs.unlinkSync(inboxPath(id)); } catch (_) {} }

// ----------------------------------------------------------------- audio
function audioExt(payload) {
  const f = asString(payload && payload.audioFormat, 'm4a').toLowerCase().replace(/[^a-z0-9]/g, '');
  return '.' + (f || 'm4a');
}
function audioAbs(id, payload) {
  return path.join(cfg.DIRS.audio, sanitizeName(id, 'unknown') + audioExt(payload));
}
function audioPartAbs(id, payload) { return audioAbs(id, payload) + '.part'; }

/** Bytes on disk for an upload, finished or in flight. */
function audioReceived(id, payload) {
  for (const p of [audioAbs(id, payload), audioPartAbs(id, payload)]) {
    try { return { bytes: fs.statSync(p).size, complete: !p.endsWith('.part'), path: p }; }
    catch (_) {}
  }
  return { bytes: 0, complete: false, path: null };
}

// ------------------------------------------------------------ transcripts
/** The stable _Unsorted basename for a recording, before we know its course. */
function unsortedBase(payload) {
  const day = localDate(payload.recordedAt, cfg.TZ);
  return day + SEP + sanitizeName(payload.title, 'Untitled Recording') +
    ' [' + sanitizeName(String(payload.id)).slice(0, 8) + ']';
}
function unsortedTxt(payload)  { return path.join(cfg.DIRS.unsorted, unsortedBase(payload) + '.txt'); }
function unsortedJson(payload) { return path.join(cfg.DIRS.unsorted, unsortedBase(payload) + '.json'); }

/**
 * DURABILITY STEP. Written before Claude is ever called, into _Unsorted because we
 * don't know the course or topic yet. Moved into Transcripts/<Course>/ on success.
 * `text` is whisper's output (or, if whisper failed outright, the Mac's draft).
 */
function writeUnsortedTranscript(payload, text, source) {
  fs.mkdirSync(cfg.DIRS.unsorted, { recursive: true });
  const p = unsortedTxt(payload);
  fs.writeFileSync(p, transcriptFileBody(payload, text, source), 'utf8');
  return p;
}

function transcriptFileBody(payload, text, source) {
  // LF, not CRLF: the transcript body must come back byte-for-byte identical to
  // what whisper produced. "Verbatim" is a hard rule.
  const header = [
    'id: ' + payload.id,
    'title: ' + asString(payload.title),
    'recorded_at: ' + payload.recordedAt,
    'duration_sec: ' + (payload.durationSec || 0),
    'locale: ' + asString(payload.locale, 'en_US'),
    'device: ' + asString(payload.device),
    'source: ' + asString(source, 'whisper'),
    '',
    '---',
    '',
  ].join('\n');
  return header + String(text || '');
}

/** Strip the header block back off, giving the verbatim transcript. */
function transcriptTextFromFile(absPath) {
  const raw = fs.readFileSync(absPath, 'utf8');
  const markerCrlf = raw.indexOf('\r\n---\r\n');
  const marker = raw.indexOf('\n---\n');
  if (markerCrlf !== -1 && (marker === -1 || markerCrlf < marker)) return raw.slice(markerCrlf + 7);
  if (marker !== -1) return raw.slice(marker + 5);
  return raw;
}

function moveFile(from, to) {
  if (path.resolve(from) === path.resolve(to)) return to;
  fs.mkdirSync(path.dirname(to), { recursive: true });
  try { fs.renameSync(from, to); }
  catch (_) {
    // Cross-device or locked file: fall back to copy+unlink.
    fs.copyFileSync(from, to);
    try { fs.unlinkSync(from); } catch (_) {}
  }
  return to;
}

/**
 * Move the _Unsorted transcript (and its whisper segment sidecar) to their final
 * home now that we know the course and topic.
 */
function placeTranscript(currentAbs, course, classDate, topic, keepAbs) {
  const dir = path.join(cfg.DIRS.transcripts, sanitizeName(course, 'Uncategorized'));
  const base = classDate + SEP + sanitizeName(topic, 'Untitled');
  const dest = uniquePath(dir, base, '.txt', keepAbs);
  const sidecarFrom = currentAbs.replace(/\.txt$/i, '.json');
  moveFile(currentAbs, dest);
  if (fs.existsSync(sidecarFrom)) moveFile(sidecarFrom, dest.replace(/\.txt$/i, '.json'));
  return dest;
}

// ------------------------------------------------------------------ notes
function renderNote(note, ai, transcriptRelPath) {
  const noteDirRel = path.posix.dirname(note.notePath || 'Notes/x/y.md');
  let transcriptLink = path.posix.relative(noteDirRel, transcriptRelPath);
  if (!transcriptLink.startsWith('.')) transcriptLink = './' + transcriptLink;

  const durationMin = Math.max(0, Math.round((note.durationSec || 0) / 60));
  const fm = [
    '---',
    'id: ' + yamlScalar(note.id),
    'title: ' + yamlScalar(note.topic),
    'course: ' + yamlScalar(note.course),
    'section: ' + (note.section ? yamlScalar(String(note.section)) : 'null'),
    'class_date: ' + note.classDate,
    'recorded_at: ' + note.recordedAt,
    'duration_min: ' + durationMin,
    'tags: ' + yamlList(note.tags),
    'transcript: ' + yamlScalar(transcriptLink),
    // --- additions beyond PROTOCOL.md, so _index.json can be rebuilt losslessly ---
    'source_title: ' + yamlScalar(note.title),
    'duration_sec: ' + (note.durationSec || 0),
    '---',
    '',
  ].join('\n');

  const metaBits = [note.course];
  if (note.section) metaBits.push('Section ' + note.section);
  metaBits.push(note.classDate);
  if (durationMin) metaBits.push(durationMin + ' min');

  const out = [];
  out.push(fm);
  out.push('# ' + note.topic);
  out.push('');
  out.push('*' + metaBits.join(' · ') + '*');
  out.push('');
  out.push('## Summary');
  out.push('');
  out.push(asString(ai.summary, '_No summary produced._').trim() || '_No summary produced._');
  out.push('');
  out.push('## Key Terms');
  out.push('');
  const terms = asArray(ai.keyTerms).filter(t => t && asString(t.term).trim());
  if (terms.length) {
    for (const t of terms) {
      out.push('- **' + asString(t.term).trim() + '** ' + EMDASH + ' ' + asString(t.definition).trim());
    }
  } else {
    out.push('_None identified._');
  }
  out.push('');
  out.push('## Notes');
  out.push('');
  out.push(asString(ai.notes).trim() || '_No notes produced._');
  out.push('');

  const items = asArray(ai.actionItems).filter(a => a && asString(a.text).trim());
  if (items.length) {
    out.push('## Action Items');
    out.push('');
    for (const a of items) {
      const due = a.due && isDateString(a.due) ? '  (due ' + a.due + ')' : '';
      out.push('- [ ] ' + asString(a.text).trim() + due);
    }
    out.push('');
  }

  out.push('## Full Transcript');
  out.push('');
  out.push('[' + path.posix.basename(transcriptRelPath) + '](' + mdPath(transcriptLink) + ')');
  out.push('');
  return out.join('\n');
}

/**
 * Rewrite `source_title:` in a note's front matter.
 *
 * The student's typed title lives in the markdown as well as in `_index.json` - that is
 * exactly what makes `rebuildIndex()` lossless - so a rename that touched only the index
 * would be silently undone by the next reindex. Only that one line moves; the note body,
 * and every field Claude produced, are left alone.
 */
function setNoteSourceTitle(relPath, title) {
  const absPath = abs(relPath);
  let raw;
  try { raw = fs.readFileSync(absPath, 'utf8'); } catch (_) { return false; }

  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const lines = raw.split(/\r?\n/);
  if (lines[0] !== '---') return false;
  const close = lines.indexOf('---', 1);
  if (close === -1) return false;

  const line = 'source_title: ' + yamlScalar(title);
  const at = lines.findIndex((l, i) => i > 0 && i < close && /^source_title:/.test(l));
  if (at !== -1) lines[at] = line;
  else lines.splice(close, 0, line);      // a note written before the field existed
  fs.writeFileSync(absPath, lines.join(eol), 'utf8');
  return true;
}

function notePathFor(course, classDate, topic, keepAbs) {
  const dir = path.join(cfg.DIRS.notes, sanitizeName(course, 'Uncategorized'));
  const base = classDate + SEP + sanitizeName(topic, 'Untitled');
  return uniquePath(dir, base, '.md', keepAbs);
}

function writeNoteFile(absPath, text) {
  fs.mkdirSync(path.dirname(absPath), { recursive: true });
  fs.writeFileSync(absPath, text, 'utf8');
}

function readNoteMarkdown(note) {
  if (!note || !note.notePath) return null;
  try { return fs.readFileSync(abs(note.notePath), 'utf8'); } catch (_) { return null; }
}
function readNoteTranscript(note) {
  if (!note) return null;
  if (note.transcriptPath) {
    try { return transcriptTextFromFile(abs(note.transcriptPath)); } catch (_) {}
  }
  // Not transcribed yet (or the file is gone): fall back to Apple's on-device draft
  // so the Mac never shows a blank note while the GPU works.
  const inbox = readInbox(note.id);
  if (inbox && inbox.draftTranscript) return String(inbox.draftTranscript);
  return null;
}

function removeFileQuiet(relPath) {
  if (!relPath) return;
  try { fs.unlinkSync(abs(relPath)); } catch (_) {}
}

// --------------------------------------------------------------- captures
function appendCapture(entry) {
  fs.mkdirSync(cfg.DIRS.captures, { recursive: true });
  const month = String(entry.capturedAt || nowIso()).slice(0, 7);
  const file = path.join(cfg.DIRS.captures, month + '.md');
  if (!fs.existsSync(file)) fs.writeFileSync(file, '# Captures ' + month + '\n', 'utf8');

  const stamp = String(entry.capturedAt || nowIso()).replace('T', ' ').replace('Z', 'Z');
  const lines = ['', '## ' + stamp + SEP + entry.kind];
  const bits = [];
  if (entry.course) bits.push('course: ' + entry.course);
  if (entry.due) bits.push('due: ' + entry.due);
  bits.push('id: ' + entry.id);
  lines.push('*' + bits.join(' · ') + '*');
  lines.push('');
  if (entry.kind === 'note') {
    lines.push(entry.text);
  } else {
    lines.push('- [ ] ' + entry.text + (entry.due ? '  (due ' + entry.due + ')' : ''));
  }
  lines.push('');
  lines.push('> ' + String(entry.raw || '').replace(/\r?\n/g, ' '));
  lines.push('');
  fs.appendFileSync(file, lines.join('\n'), 'utf8');
  return rel(file);
}

// ------------------------------------------------------- index rebuilding
function parseFrontMatter(text) {
  if (!text.startsWith('---')) return null;
  const end = text.indexOf('\n---', 3);
  if (end === -1) return null;
  const block = text.slice(3, end);
  const out = {};
  for (const line of block.split(/\r?\n/)) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/.exec(line);
    if (!m) continue;
    let v = m[2].trim();
    if (v === 'null' || v === '') v = null;
    else if (/^\[.*\]$/.test(v)) {
      v = v.slice(1, -1).split(',').map(s => s.trim().replace(/^"(.*)"$/, '$1')).filter(Boolean);
    } else if (/^".*"$/.test(v)) v = v.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    out[m[1]] = v;
  }
  return out;
}

function sectionBody(text, heading) {
  const re = new RegExp('^## ' + heading + '\\s*$', 'm');
  const m = re.exec(text);
  if (!m) return '';
  const start = m.index + m[0].length;
  const next = /^## /m.exec(text.slice(start));
  return text.slice(start, next ? start + next.index : undefined).trim();
}

function walk(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

/**
 * Rebuild _index.json + _courses.json purely from the markdown in Notes/.
 * This is the disaster-recovery path: the files are the source of truth.
 */
function rebuildIndex() {
  ensureDirs();
  const files = walk(cfg.DIRS.notes, []).filter(f => f.toLowerCase().endsWith('.md'));

  // The glossary and the Canvas link live ONLY in _courses.json - they are not
  // derivable from the note markdown. store.reset() would drop them, and a reindex
  // would silently un-teach whisper every technical term the course has learned.
  // Snapshot them here and reapply after the rebuild.
  const savedMeta = {};
  const prior = store.readJson(cfg.COURSES_FILE, null);
  for (const c of ((prior && prior.courses) || [])) {
    if (c && c.name) savedMeta[c.name] = { glossary: c.glossary, canvas: c.canvas, createdAt: c.createdAt };
  }

  store.reset();
  let ok = 0, skipped = 0;
  const derivedTerms = new Map();   // course -> terms re-read from the notes

  for (const f of files) {
    let text;
    try { text = fs.readFileSync(f, 'utf8'); } catch (_) { skipped++; continue; }
    const fm = parseFrontMatter(text);
    if (!fm || !fm.id) { skipped++; continue; }

    const notePath = rel(f);
    // Resolve the transcript link (front matter holds it relative to the note).
    let transcriptPath = null;
    if (fm.transcript) {
      const t = path.posix.normalize(path.posix.join(path.posix.dirname(notePath), fm.transcript));
      if (fs.existsSync(abs(t))) transcriptPath = t;
    }
    if (!transcriptPath) {
      const guess = 'Transcripts/' + sanitizeName(fm.course || 'Uncategorized') + '/' +
        path.posix.basename(notePath).replace(/\.md$/i, '.txt');
      if (fs.existsSync(abs(guess))) transcriptPath = guess;
    }

    const actionItemCount = (sectionBody(text, 'Action Items').match(/^- \[[ xX]\] /gm) || []).length;
    // Second recovery path for the glossary: the key terms are right there in the
    // markdown, so even a lost _courses.json can be rebuilt from the vault alone.
    const courseKey = fm.course || 'Uncategorized';
    for (const line of sectionBody(text, 'Key Terms').split(/\r?\n/)) {
      const km = /^-\s+\*\*(.+?)\*\*/.exec(line.trim());
      if (!km) continue;
      if (!derivedTerms.has(courseKey)) derivedTerms.set(courseKey, []);
      derivedTerms.get(courseKey).push(km[1].trim());
    }
    // Audio is stored as Audio/<id>.<ext>, so it can be found from the id alone.
    let audioPath = null;
    for (const ext of ['.m4a', '.mp4', '.wav', '.mp3']) {
      const cand = 'Audio/' + sanitizeName(fm.id, 'unknown') + ext;
      if (fs.existsSync(abs(cand))) { audioPath = cand; break; }
    }
    const durationSec = fm.duration_sec ? parseInt(fm.duration_sec, 10)
      : (fm.duration_min ? parseInt(fm.duration_min, 10) * 60 : 0);

    const note = {
      id: fm.id,
      title: fm.source_title || fm.title || '',
      course: fm.course || 'Uncategorized',
      section: fm.section || null,
      topic: fm.title || '',
      classDate: fm.class_date || (fm.recorded_at ? localDate(fm.recorded_at, cfg.TZ) : null),
      recordedAt: fm.recorded_at || null,
      durationSec: isNaN(durationSec) ? 0 : durationSec,
      state: 'ready',
      tags: Array.isArray(fm.tags) ? fm.tags : [],
      summary: sectionBody(text, 'Summary').replace(/^_No summary produced\._$/, ''),
      actionItemCount,
      notePath,
      transcriptPath,
      updatedAt: nowIso(),
      audioPath,
      transcriptSource: transcriptPath ? 'whisper' : null,
    };
    store.putNote(note);

    // Re-derive that note's todos from the checkboxes in the file.
    const items = [];
    for (const line of sectionBody(text, 'Action Items').split(/\r?\n/)) {
      const m = /^- \[([ xX])\]\s+(.*)$/.exec(line.trim());
      if (!m) continue;
      let txt = m[2].trim();
      let due = null;
      const dm = /\(due (\d{4}-\d{2}-\d{2})\)\s*$/.exec(txt);
      if (dm) { due = dm[1]; txt = txt.slice(0, dm.index).trim(); }
      items.push({ text: txt, due, course: note.course, done: m[1] !== ' ' });
    }
    store.replaceTodosForSource('note:' + note.id, items);
    for (const it of items) {
      if (it.done) store.setTodoDone(store.todoId('note:' + note.id, it.text), true);
    }
    ok++;
  }

  // Re-derive from the markdown first, then let the saved glossary win where it
  // exists - it is the richer of the two (it also carries Canvas-seeded vocabulary).
  for (const [course, terms] of derivedTerms) store.addGlossaryTerms(course, terms);
  store.restoreCourseMeta(savedMeta);

  store.save(true);
  const glossaryTotal = store.courseSummaries(true)
    .reduce((n, c) => n + ((c.glossary || []).length), 0);
  log.info('rebuilt index from', files.length, 'markdown files:', ok, 'ok,', skipped, 'skipped',
    '| glossary terms preserved:', glossaryTotal);
  return { files: files.length, notes: ok, skipped, glossaryTerms: glossaryTotal };
}

module.exports = {
  SEP, ensureDirs, rel, abs, uniquePath, moveFile,
  inboxPath, saveInbox, readInbox, deleteInbox,
  audioExt, audioAbs, audioPartAbs, audioReceived,
  unsortedBase, unsortedTxt, unsortedJson,
  writeUnsortedTranscript, transcriptTextFromFile, placeTranscript,
  renderNote, notePathFor, writeNoteFile, readNoteMarkdown, readNoteTranscript, removeFileQuiet,
  setNoteSourceTitle,
  appendCapture, parseFrontMatter, sectionBody, rebuildIndex,
};
