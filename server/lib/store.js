'use strict';
// _index.json + _courses.json. Both are DERIVED caches - the markdown files in the
// vault are the source of truth (see vault.rebuildIndex).
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const log = require('./log');
const { nowIso, sha1 } = require('./util');

const state = {
  notes: new Map(),   // id -> note object
  todos: new Map(),   // id -> todo object
  courses: new Map(), // name -> { name, createdAt }
};

// -------------------------------------------------------------- persistence
function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, text, 'utf8');
  fs.renameSync(tmp, file); // MoveFileEx(REPLACE_EXISTING) on Windows
}

function readJson(file, fallback) {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    return JSON.parse(raw.replace(/^\uFEFF/, ''));
  } catch (e) {
    if (e.code !== 'ENOENT') log.warn('could not read', file, '-', e.message);
    return fallback;
  }
}

function load() {
  const idx = readJson(cfg.INDEX_FILE, null);
  if (idx) {
    for (const n of (idx.notes || [])) if (n && n.id) state.notes.set(n.id, n);
    for (const t of (idx.todos || [])) if (t && t.id) state.todos.set(t.id, t);
  }
  const c = readJson(cfg.COURSES_FILE, null);
  if (c) for (const co of (c.courses || [])) {
    if (co && co.name) state.courses.set(co.name, {
      name: co.name,
      createdAt: co.createdAt || nowIso(),
      glossary: Array.isArray(co.glossary) ? co.glossary : [],
      canvas: co.canvas || null,
    });
  }
  // Any course referenced by a note but missing from the registry gets added back.
  for (const n of state.notes.values()) if (n.course) ensureCourse(n.course);
  log.info('loaded index:', state.notes.size, 'notes,', state.todos.size, 'todos,', state.courses.size, 'courses');
}

let saveTimer = null;
function save(immediate) {
  if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
  if (!immediate) { saveTimer = setTimeout(() => save(true), 250); if (saveTimer.unref) saveTimer.unref(); return; }
  try {
    writeAtomic(cfg.INDEX_FILE, JSON.stringify({
      version: 1, updatedAt: nowIso(),
      courses: courseSummaries(), notes: notesSorted(), todos: todosSorted(),
    }, null, 2));
    writeAtomic(cfg.COURSES_FILE, JSON.stringify({
      version: 1, updatedAt: nowIso(), courses: courseSummaries(true),
    }, null, 2));
  } catch (e) {
    log.error('index save failed:', e.message);
  }
}

// -------------------------------------------------------------- courses
function ensureCourse(name) {
  if (!name) return null;
  if (!state.courses.has(name)) {
    state.courses.set(name, { name, createdAt: nowIso(), glossary: [], canvas: null });
  }
  const c = state.courses.get(name);
  if (!Array.isArray(c.glossary)) c.glossary = [];
  if (c.canvas === undefined) c.canvas = null;
  return c;
}

/**
 * The per-course technical vocabulary that seeds whisper's `initial_prompt`.
 * Accumulated from the key terms of every note in the course - this is what makes
 * "Le Chatelier" and "chemiosmotic" transcribe correctly next lecture.
 * Newest first, capped, deduplicated case-insensitively.
 */
function addGlossaryTerms(courseName, terms) {
  const c = ensureCourse(courseName);
  if (!c) return;
  const seen = new Set();
  const merged = [];
  for (const t of [].concat(terms || [], c.glossary)) {
    const s = String(t == null ? '' : t).trim().replace(/\s+/g, ' ');
    if (!s || s.length > 60) continue;
    const k = s.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    merged.push(s);
    if (merged.length >= cfg.GLOSSARY_MAX_TERMS) break;
  }
  c.glossary = merged;
  save();
}

/** Link a vault course to its Canvas course. */
function setCourseCanvas(courseName, meta) {
  const c = ensureCourse(courseName);
  if (!c) return null;
  c.canvas = meta || null;
  save();
  return c;
}

/**
 * Reapply per-course metadata that lives ONLY in _courses.json. rebuildIndex()
 * derives everything from the markdown, and the glossary and the Canvas link are
 * not in the markdown - without this they are destroyed by a reindex.
 */
function restoreCourseMeta(saved) {
  for (const [name, meta] of Object.entries(saved || {})) {
    if (!state.courses.has(name)) continue;
    const c = state.courses.get(name);
    if (Array.isArray(meta.glossary) && meta.glossary.length) c.glossary = meta.glossary.slice();
    if (meta.canvas) c.canvas = meta.canvas;
    if (meta.createdAt) c.createdAt = meta.createdAt;
  }
  save();
}

function glossaryFor(courseName) {
  const c = state.courses.get(courseName);
  return (c && Array.isArray(c.glossary)) ? c.glossary : [];
}

/** Course list with live counts, as served by GET /api/notes. */
function courseSummaries(withCreatedAt) {
  const out = [];
  for (const c of state.courses.values()) {
    let noteCount = 0, lastClass = null;
    for (const n of state.notes.values()) {
      if (n.course !== c.name) continue;
      noteCount++;
      if (n.classDate && (!lastClass || n.classDate > lastClass)) lastClass = n.classDate;
    }
    const o = { name: c.name, noteCount, lastClass };
    if (withCreatedAt) { o.createdAt = c.createdAt; o.glossary = c.glossary || []; o.canvas = c.canvas || null; }
    else if (c.canvas) o.canvas = { id: c.canvas.id, code: c.canvas.code, syncedAt: c.canvas.syncedAt };
    out.push(o);
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

/** Just the names, for the "don't invent a near-duplicate course" prompt. */
function courseNames() { return courseSummaries().map(c => c.name); }

// -------------------------------------------------------------- notes
function notesSorted() {
  return Array.from(state.notes.values()).sort((a, b) => {
    const ad = a.classDate || '', bd = b.classDate || '';
    if (ad !== bd) return bd.localeCompare(ad);              // newest class first
    return String(b.recordedAt || '').localeCompare(String(a.recordedAt || ''));
  });
}
function getNote(id) { return state.notes.get(id) || null; }
function putNote(note) {
  note.updatedAt = nowIso();
  state.notes.set(note.id, note);
  if (note.course) ensureCourse(note.course);
  save();
  return note;
}

// -------------------------------------------------------------- todos
function todosSorted() {
  return Array.from(state.todos.values()).sort((a, b) => {
    if (a.done !== b.done) return a.done ? 1 : -1;
    const ad = a.due || '9999-99-99', bd = b.due || '9999-99-99';
    if (ad !== bd) return ad.localeCompare(bd);
    return String(a.text).localeCompare(String(b.text));
  });
}
function allTodos() { return todosSorted(); }

function todoId(source, text) { return sha1(source + ' ' + String(text).trim().toLowerCase()).slice(0, 24); }

/**
 * Replace every todo that came from `source` with `items`, preserving the `done`
 * flag of any todo whose text is unchanged. Called on both first process and
 * reprocess so re-running Claude never duplicates a homework item.
 */
function replaceTodosForSource(source, items) {
  const prevDone = new Map();
  for (const [id, t] of state.todos) {
    if (t.source === source) { prevDone.set(id, t.done); state.todos.delete(id); }
  }
  for (const it of items) {
    const text = String(it.text || '').trim();
    if (!text) continue;
    const id = todoId(source, text);
    // Canvas can mark something done (you submitted it); so can a tick in the app.
    // Neither un-does the other — a sync must never uncheck what you ticked off.
    const done = it.done === true ? true : (prevDone.has(id) ? !!prevDone.get(id) : false);
    const todo = { id, text, due: it.due || null, course: it.course || null, done, source };
    // Canvas assignments carry more than a line of text: a real timestamp, points,
    // a link back, and whether it has actually been handed in.
    if (it.kind) todo.kind = it.kind;
    if (it.dueAt) todo.dueAt = it.dueAt;
    if (it.url) todo.url = it.url;
    if (it.points !== undefined && it.points !== null) todo.points = it.points;
    if (it.submitted !== undefined) todo.submitted = !!it.submitted;
    if (it.graded !== undefined) todo.graded = !!it.graded;
    if (it.canvasId) todo.canvasId = String(it.canvasId);
    state.todos.set(id, todo);
  }
  save();
}

function setTodoDone(id, done) {
  const t = state.todos.get(id);
  if (!t) return null;
  t.done = !!done;
  save();
  return t;
}

function reset() { state.notes.clear(); state.todos.clear(); state.courses.clear(); }

module.exports = {
  state, load, save, writeAtomic, readJson,
  ensureCourse, addGlossaryTerms, glossaryFor, courseSummaries, courseNames,
  setCourseCanvas, restoreCourseMeta,
  notesSorted, getNote, putNote,
  allTodos, todosSorted, replaceTodosForSource, setTodoDone, todoId,
  reset,
};
