'use strict';
// The serial job queue.
//
//   awaiting_audio -> transcribing (whisper large-v3, GPU) -> processing (claude) -> ready
//                                                                                 -> failed
//
// One job at a time on purpose: whisper wants the whole GPU and a lecture-sized
// claude prompt is big enough that running two would just make both slower.
const path = require('path');
const fs = require('fs');
const cfg = require('./config');
const log = require('./log');
const sse = require('./sse');
const store = require('./store');
const vault = require('./vault');
const claude = require('./claude');
const whisper = require('./whisper');
const { nowIso, asString, localDate, isDateString } = require('./util');

const queue = [];
const queued = new Set();   // note/capture ids already waiting, so a retry can't double-run
let running = null;

function depth() { return queue.length + (running ? 1 : 0); }
function isBusy(id) { return queued.has(id) || running === id; }

function enqueue(job) {
  if (job.id && queued.has(job.id)) return false;
  if (job.id && running === job.id) return false;
  if (job.id) queued.add(job.id);
  queue.push(job);
  setImmediate(pump);
  return true;
}

async function pump() {
  if (running || !queue.length) return;
  const job = queue.shift();
  if (job.id) queued.delete(job.id);
  running = job.id || true;
  try {
    if (job.type === 'note') await runNote(job);
    else if (job.type === 'capture') await processCapture(job);
    else if (job.type === 'glossary') await processGlossary(job);
  } catch (e) {
    log.error('job crashed:', job.type, job.id, '-', (e && e.stack) || e);
  } finally {
    running = null;
    setImmediate(pump);
  }
}

function emitState(id, state, detail) {
  sse.broadcast('state', { id, state, detail: detail || state });
}
function emitTodos() {
  sse.broadcast('todos', { todos: store.allTodos() });
}
function setState(note, state, detail) {
  note.state = state;
  store.putNote(note);
  emitState(note.id, state, detail);
}

// ============================================================== lecture note
/**
 * Durability contract, in order:
 *   1. inbox/<id>.json  (metadata + Apple's draft) written by POST /api/ingest
 *   2. Audio/<id>.m4a   written by PUT /api/audio/<id>
 *   3. Transcripts/_Unsorted/<...>.txt + .json  written the moment whisper finishes
 *   4. only then is claude called
 * Any step can fail; nothing earlier is ever discarded, and every step is retryable
 * from what is already on disk.
 */
async function runNote(job) {
  const id = job.id;
  const note = store.getNote(id);
  if (!note) { log.warn('runNote: no such note', id); return; }

  const payload = job.payload || vault.readInbox(id) || rebuildPayloadFromDisk(note);
  if (!payload) return fail(note, 'no stored payload for this note');

  // ---------------------------------------------------------- phase 1: whisper
  let transcript = null;
  const haveTranscript = note.transcriptPath && fs.existsSync(vault.abs(note.transcriptPath));

  if (haveTranscript && !job.retranscribe) {
    transcript = vault.transcriptTextFromFile(vault.abs(note.transcriptPath));
  } else {
    const r = await transcribePhase(note, payload);
    if (!r) return;                        // fail() already reported
    transcript = r;
  }

  if (!asString(transcript).trim()) return fail(note, 'transcript is empty');

  // ---------------------------------------------------------- phase 2: claude
  setState(note, 'processing', 'asking claude');
  log.info('processing note', id, '-', asString(payload.title),
    '(' + asString(transcript).length + ' chars)');

  let ai, meta;
  try {
    const known = store.courseNames().filter(n => n !== 'Uncategorized');
    const prompt = claude.buildLecturePrompt(payload, known, transcript);
    const res = await claude.ask(prompt, claude.LECTURE_SCHEMA);
    ai = claude.normaliseLecture(res.data, payload, known);
    meta = res.meta;
    claude.setHealth(true);
  } catch (e) {
    claude.setHealth(false);
    return fail(note, e.message);
  }

  try {
    // move the transcript (and its whisper sidecar) out of _Unsorted
    const currentTranscriptAbs = note.transcriptPath ? vault.abs(note.transcriptPath) : null;
    let transcriptRel = note.transcriptPath;
    if (currentTranscriptAbs && fs.existsSync(currentTranscriptAbs)) {
      transcriptRel = vault.rel(vault.placeTranscript(
        currentTranscriptAbs, ai.course, ai.classDate, ai.topic, currentTranscriptAbs));
    }

    const oldNoteRel = note.notePath || null;
    const oldNoteAbs = oldNoteRel ? vault.abs(oldNoteRel) : null;
    const noteAbs = vault.notePathFor(ai.course, ai.classDate, ai.topic, oldNoteAbs);
    const noteRel = vault.rel(noteAbs);

    note.course = ai.course;
    note.section = ai.section;
    note.topic = ai.topic;
    note.classDate = ai.classDate;
    note.tags = ai.tags;
    note.summary = ai.summary;
    note.actionItemCount = ai.actionItems.length;
    note.notePath = noteRel;
    note.transcriptPath = transcriptRel;
    note.state = 'ready';
    delete note.error;

    vault.writeNoteFile(noteAbs, vault.renderNote(note, ai, transcriptRel || 'Transcripts'));
    if (oldNoteRel && oldNoteRel !== noteRel) vault.removeFileQuiet(oldNoteRel);

    store.ensureCourse(ai.course);
    // Feed this lecture's vocabulary back into the course glossary so the NEXT
    // recording in this course transcribes its jargon correctly.
    store.addGlossaryTerms(ai.course,
      ai.keyTerms.map(t => t.term).concat(ai.tags.map(t => t.replace(/-/g, ' '))));
    store.replaceTodosForSource('note:' + id,
      ai.actionItems.map(a => ({ text: a.text, due: a.due, course: ai.course })));
    store.putNote(note);
    store.save(true);
    vault.deleteInbox(id);

    log.info('note ready', id, '->', noteRel,
      '| course=' + ai.course, 'section=' + ai.section, 'todos=' + ai.actionItems.length,
      meta && meta.durationMs ? '| claude ' + Math.round(meta.durationMs / 1000) + 's' : '');

    emitState(id, 'ready', 'done');
    sse.broadcast('note', note);
    emitTodos();
  } catch (e) {
    log.error('writing note failed', id, '-', e.stack || e.message);
    return fail(note, 'write failed: ' + e.message);
  }
}

/**
 * Run whisper and write the transcript to disk. Returns the text, or null after
 * calling fail(). Falls back to Apple's draft only when whisper fails outright -
 * a draft must never overwrite a real whisper transcript.
 */
async function transcribePhase(note, payload) {
  const id = note.id;
  const audio = vault.audioAbs(id, payload);
  const draft = asString(payload.draftTranscript);

  if (!fs.existsSync(audio)) {
    if (draft.trim()) {
      log.warn('no audio for', id, '- falling back to the Mac draft transcript');
      return commitTranscript(note, payload, draft, 'draft');
    }
    fail(note, 'audio has not been uploaded yet (PUT /api/audio/' + id + ')', 'awaiting_audio');
    return null;
  }

  // Bias whisper with this course's accumulated vocabulary.
  const courses = store.courseNames().filter(n => n !== 'Uncategorized');
  const guess = whisper.guessCourse(payload.title, draft, courses);
  const initialPrompt = whisper.buildInitialPrompt(guess, store.glossaryFor(guess), payload.title);

  setState(note, 'transcribing', 'transcribing on the gpu');
  log.info('transcribing', id, '| audio', Math.round(fs.statSync(audio).size / 1024) + 'kb',
    '| course guess:', guess || '(none)',
    '| glossary terms:', store.glossaryFor(guess).length);

  let result;
  const t0 = Date.now();
  try {
    let lastPct = -1;
    result = await whisper.transcribe({
      audio,
      outJson: vault.unsortedJson(payload),
      language: (asString(payload.locale, 'en_US').split(/[_-]/)[0] || 'en'),
      initialPrompt,
      onProgress: (done, total) => {
        if (!total) return;
        const pct = Math.min(99, Math.round((done / total) * 100));
        if (pct === lastPct) return;
        lastPct = pct;
        emitState(id, 'transcribing', 'transcribing ' + pct + '%');
      },
    });
    whisper.setHealth(true);
  } catch (e) {
    whisper.setHealth(false, e.message);
    log.error('whisper failed for', id, '-', e.message);
    if (draft.trim()) {
      log.warn('falling back to the Mac draft transcript for', id);
      return commitTranscript(note, payload, draft, 'draft');
    }
    fail(note, 'transcription failed: ' + e.message);
    return null;
  }

  const wall = (Date.now() - t0) / 1000;
  log.info('transcribed', id,
    '| ' + Math.round(result.duration) + 's audio in ' + Math.round(wall) + 's',
    '| ' + result.realtimeFactor + 'x realtime on ' + result.device + '/' + result.computeType,
    '| ' + result.segments.length + ' segments,', (result.text || '').length, 'chars');

  // whisper knows the true length; trust it over whatever the client claimed.
  if (result.duration > 0) {
    note.durationSec = Math.round(result.duration);
    payload.durationSec = note.durationSec;
  }
  note.transcription = {
    model: result.model, device: result.device, computeType: result.computeType,
    realtimeFactor: result.realtimeFactor, segments: result.segments.length,
    language: result.language, initialPromptChars: (initialPrompt || '').length,
    courseHint: guess || null, at: nowIso(),
  };
  return commitTranscript(note, payload, result.text, 'whisper');
}

/** Write the transcript to _Unsorted and record it on the note. Returns the text. */
function commitTranscript(note, payload, text, source) {
  const abs = vault.writeUnsortedTranscript(payload, text, source);
  note.transcriptPath = vault.rel(abs);
  note.transcriptSource = source;
  store.putNote(note);
  store.save(true);
  sse.broadcast('note', note);
  return text;
}

function fail(note, message, state) {
  note.state = state || 'failed';
  note.error = String(message).slice(0, 500);
  store.putNote(note);
  store.save(true);
  log.error('note ' + note.state, note.id, '-', note.error);
  emitState(note.id, note.state, note.error);
  sse.broadcast('note', note);
}

/** Reconstruct enough of the ingest payload from disk to re-run a stored note. */
function rebuildPayloadFromDisk(note) {
  return {
    id: note.id,
    title: note.title,
    recordedAt: note.recordedAt,
    durationSec: note.durationSec,
    audioFormat: (note.audioPath || '.m4a').split('.').pop(),
    locale: 'en_US',
    device: 'reprocess',
  };
}

// ================================================================== capture
async function processCapture(job) {
  const p = job.payload;
  emitState(p.id, 'processing', 'asking claude');

  let out;
  try {
    const known = store.courseNames().filter(n => n !== 'Uncategorized');
    const res = await claude.ask(claude.buildCapturePrompt(p, known), claude.CAPTURE_SCHEMA);
    out = claude.normaliseCapture(res.data, p, known);
    claude.setHealth(true);
  } catch (e) {
    claude.setHealth(false);
    log.error('capture failed', p.id, '-', e.message);
    // A capture is one sentence; never lose it - file it verbatim as a todo.
    out = { kind: p.kind && p.kind !== 'auto' ? p.kind : 'todo', text: asString(p.text).trim(), course: null, due: null };
    emitState(p.id, 'failed', e.message);
  }

  const entry = {
    id: p.id, kind: out.kind, text: out.text, course: out.course, due: out.due,
    capturedAt: p.capturedAt, raw: p.text,
  };
  const rel = vault.appendCapture(entry);
  if (out.course) store.ensureCourse(out.course);

  if (out.kind !== 'note') {
    store.replaceTodosForSource('capture:' + p.id,
      [{ text: out.text, due: out.due, course: out.course }]);
  }
  store.save(true);
  vault.deleteInbox(p.id);

  log.info('capture filed', p.id, '->', rel, '| kind=' + out.kind, 'due=' + out.due);
  emitState(p.id, 'ready', 'filed as ' + out.kind);
  emitTodos();
}

// ================================================================ glossary
/**
 * Turn a course's Canvas material into whisper vocabulary.
 *
 * Runs on the same serial queue as everything else so it can never contend with a
 * lecture being transcribed - a class recording always matters more than this.
 */
async function processGlossary(job) {
  const course = job.course;
  try {
    const res = await claude.ask(claude.buildGlossaryPrompt(course, job.samples), claude.GLOSSARY_SCHEMA);
    const terms = claude.normaliseGlossary(res.data);
    claude.setHealth(true);
    if (!terms.length) {
      log.warn('glossary: claude returned no usable terms for', course);
      return;
    }
    store.addGlossaryTerms(course, terms);
    store.save(true);
    log.info('glossary: seeded', course, 'with', terms.length, 'terms from course material',
      '| now', store.glossaryFor(course).length, 'total');
    sse.broadcast('canvas', { glossary: { course, added: terms.length,
                                          total: store.glossaryFor(course).length } });
  } catch (e) {
    claude.setHealth(false);
    // Not fatal: the materials are already on disk, and the glossary only makes
    // the NEXT recording better. Retried on the next sync.
    log.error('glossary pass failed for', course, '-', e.message);
  }
}

module.exports = { enqueue, depth, isBusy, emitTodos, emitState, runNote };
