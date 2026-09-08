'use strict';
// Scoped Claude conversations over course materials.
//
// A chat is an ordinary `claude` session whose working directory IS the thing you
// scoped it to - a course, one chapter, or the folder holding a single file - so Claude
// reads the material with its own tools rather than being handed a wad of pasted text.
// That is the whole trick: no context stuffing, no chunking, no embeddings. It can grep
// the chapter, open the PDF's extracted sidecar, and follow a reference to another file
// in the same module, exactly as it would in a repo.
//
// Sessions are the CLI's own. We mint the UUID (`--session-id`) so we always know the id
// without parsing it back out, then continue with `--resume`; the conversation state
// lives wherever the CLI keeps it, and what we store here is only what the app needs to
// redraw the transcript.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const cfg = require('./config');
const log = require('./log');
const materials = require('./materials');
const { nowIso, asString } = require('./util');

const CHAT_DIR = path.join(cfg.VAULT, 'Chats');
const INDEX = path.join(CHAT_DIR, '_sessions.json');
// Sonnet 5. The note pass uses cfg.MODEL; this is a conversation with a person waiting
// on it, so it is pinned rather than inherited.
const MODEL = process.env.NOTABLES_CHAT_MODEL || 'claude-sonnet-5';
// Read and search, nothing that writes. A study chat has no business editing the vault,
// and a headless session cannot put up a permission prompt to ask.
const ALLOWED_TOOLS = (process.env.NOTABLES_CHAT_TOOLS ||
  'Read,Grep,Glob,WebSearch,WebFetch,NotebookRead,TodoWrite').split(',');

function ensureDirs() {
  fs.mkdirSync(CHAT_DIR, { recursive: true });
}

// ------------------------------------------------------------------ scope
/**
 * Turn {course, module, fileId} into a real directory, refusing anything that would
 * point outside `Course Materials`. The client never sends a path - it names things the
 * manifest already knows about - so there is no path for traversal to arrive through.
 */
function resolveScope(scope) {
  const course = asString(scope && scope.course).trim();
  if (!course) throw Object.assign(new Error('a course is required'), { code: 'BAD_SCOPE' });

  const manifest = materials.readManifest(course);
  if (!manifest) throw Object.assign(new Error('no synced materials for ' + course), { code: 'NO_COURSE' });

  const root = path.join(cfg.VAULT, 'Course Materials', course);
  let dir = root;
  let kind = 'course';
  let label = course;
  let focus = null;

  const fileId = asString(scope.fileId).trim();
  const mod = asString(scope.module).trim();

  if (fileId) {
    const f = manifest.files && manifest.files[fileId];
    if (!f || !f.path) throw Object.assign(new Error('no such file in ' + course), { code: 'NO_FILE' });
    const abs = path.join(cfg.VAULT, f.path.split('/').join(path.sep));
    dir = path.dirname(abs);
    kind = 'file';
    label = f.name;
    focus = { name: f.name, textFile: f.textPath ? path.basename(f.textPath) : null };
  } else if (mod) {
    const known = (manifest.modules || []).some(m => m.folder === mod);
    if (!known) throw Object.assign(new Error('no such chapter in ' + course), { code: 'NO_MODULE' });
    dir = path.join(root, mod);
    kind = 'module';
    label = mod.replace(/^\d+\s+/, '');
  }

  const resolved = path.resolve(dir);
  if (!resolved.startsWith(path.resolve(cfg.VAULT, 'Course Materials') + path.sep)) {
    throw Object.assign(new Error('scope escapes the materials directory'), { code: 'BAD_SCOPE' });
  }
  if (!fs.existsSync(resolved)) {
    throw Object.assign(new Error(label + ' has not been synced to disk yet'), { code: 'NOT_SYNCED' });
  }
  return { dir: resolved, kind, label, course, module: mod || null, fileId: fileId || null, focus };
}

function scopeKey(s) {
  // JSON rather than a delimiter: course names and module folders are arbitrary text,
  // and any separator picked by hand is a collision waiting to happen.
  return JSON.stringify([s.course, s.module || '', s.fileId || '']);
}

// --------------------------------------------------------------- sessions
function readIndex() {
  try { return JSON.parse(fs.readFileSync(INDEX, 'utf8')); }
  catch (_) { return { version: 1, sessions: [] }; }
}

function writeIndex(idx) {
  ensureDirs();
  const tmp = INDEX + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(idx, null, 2));
  fs.renameSync(tmp, INDEX);
}

function listSessions(scope) {
  const idx = readIndex();
  const key = scope ? scopeKey(scope) : null;
  return idx.sessions
    .filter(s => !key || s.key === key)
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
}

function transcriptPath(id) { return path.join(CHAT_DIR, id + '.json'); }

function readTranscript(id) {
  try { return JSON.parse(fs.readFileSync(transcriptPath(id), 'utf8')); }
  catch (_) { return null; }
}

function writeTranscript(id, data) {
  ensureDirs();
  const tmp = transcriptPath(id) + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, transcriptPath(id));
}

function deleteSession(id) {
  const idx = readIndex();
  const before = idx.sessions.length;
  idx.sessions = idx.sessions.filter(s => s.id !== id);
  writeIndex(idx);
  try { fs.rmSync(transcriptPath(id)); } catch (_) {}
  try { fs.rmSync(attachmentDir(id), { recursive: true, force: true }); } catch (_) {}
  return idx.sessions.length !== before;
}

/** First words of the opening question, so the resume list is readable. */
function titleFrom(text) {
  const one = asString(text).replace(/\s+/g, ' ').trim();
  return one.length > 60 ? one.slice(0, 57) + '…' : (one || 'New conversation');
}

// ------------------------------------------------------------ attachments
function attachmentDir(id) { return path.join(CHAT_DIR, id, 'attachments'); }

/**
 * Photos and pasted files. They land beside the session rather than in the vault's
 * course folders - a snapshot of a homework sheet is not course material, and the next
 * Canvas sync would be entitled to wonder what it was doing there.
 */
function saveAttachment(sessionId, name, buffer) {
  const dir = attachmentDir(sessionId);
  fs.mkdirSync(dir, { recursive: true });
  const safe = asString(name).replace(/[^A-Za-z0-9._-]/g, '_').slice(-80) || 'upload';
  const file = path.join(dir, Date.now() + '-' + safe);
  fs.writeFileSync(file, buffer);
  return file;
}

// ------------------------------------------------------------------- run
function buildSystemPrompt(scope) {
  const lines = [
    'You are helping a university student study for "' + scope.course + '".',
    'Your working directory holds that course\'s materials as synced from Canvas.',
    'Every PDF, slide deck and doc has a sibling ".txt" file containing its extracted',
    'text - read the .txt when you want the contents; it is far cheaper than the binary.',
    '"_Index.md" lists what is here. Folders are Canvas modules, usually chapters.',
  ];
  if (scope.kind === 'module') {
    lines.push('The student has scoped this conversation to the chapter "' + scope.label + '".');
  } else if (scope.kind === 'file' && scope.focus) {
    lines.push('The student has scoped this conversation to one file: "' + scope.focus.name + '"' +
      (scope.focus.textFile ? ' (extracted text in "' + scope.focus.textFile + '")' : '') + '.',
      'Answer about that file first; the rest of the folder is background.');
  }
  lines.push(
    'Cite the file and page or section when you use the materials, so they can go and look.',
    'If the materials do not cover something, say so plainly rather than filling the gap.');
  return lines.join('\n');
}

/**
 * One turn. Streams normalised events to `onEvent` and resolves with the final text.
 *
 * The CLI is asked for `stream-json` with partial messages, which is what makes tokens
 * appear as they are produced rather than in one lump at the end. The event shapes it
 * emits are richer than anything here needs, so this narrows them to four kinds the app
 * can render without knowing anything about Claude Code's internals.
 */
function run({ scope, sessionId, resume, text, attachments, onEvent }) {
  return new Promise((resolve, reject) => {
    const args = [
      '-p',
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
      '--model', MODEL,
      '--allowedTools', ALLOWED_TOOLS.join(','),
      '--permission-mode', 'dontAsk',
      '--append-system-prompt', buildSystemPrompt(scope),
    ];
    if (resume) args.push('--resume', sessionId);
    else args.push('--session-id', sessionId);
    // Attachments live outside the working directory, so Claude needs to be told it may
    // read them.
    if (attachments && attachments.length) args.push('--add-dir', attachmentDir(sessionId));

    const child = spawn(cfg.CLAUDE_BIN, args, {
      cwd: scope.dir,
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      env: Object.assign({}, process.env, {
        ANTHROPIC_API_KEY: '',
        ANTHROPIC_AUTH_TOKEN: '',
      }),
    });

    let buf = '';
    let answer = '';
    let stderr = '';
    let settled = false;
    let meta = {};

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill(); } catch (_) {}
      reject(new Error('claude timed out after ' + Math.round(cfg.CLAUDE_TIMEOUT_MS / 1000) + 's'));
    }, cfg.CLAUDE_TIMEOUT_MS);

    const emit = e => { try { onEvent(e); } catch (_) {} };

    const handle = line => {
      let ev;
      try { ev = JSON.parse(line); } catch (_) { return; }

      // Token-by-token text.
      if (ev.type === 'stream_event' && ev.event) {
        const e = ev.event;
        if (e.type === 'content_block_delta' && e.delta) {
          if (e.delta.type === 'text_delta' && e.delta.text) {
            answer += e.delta.text;
            emit({ t: 'delta', text: e.delta.text });
          } else if (e.delta.type === 'thinking_delta' && e.delta.thinking) {
            emit({ t: 'thinking', text: e.delta.thinking });
          }
        }
        return;
      }

      // Whole assistant messages: the tool calls are in here.
      if (ev.type === 'assistant' && ev.message && Array.isArray(ev.message.content)) {
        for (const block of ev.message.content) {
          if (block.type === 'tool_use') {
            emit({ t: 'tool', name: block.name, detail: describeTool(block) });
          }
        }
        return;
      }

      if (ev.type === 'result') {
        meta = {
          costUsd: ev.total_cost_usd,
          durationMs: ev.duration_ms,
          turns: ev.num_turns,
          sessionId: ev.session_id || sessionId,
        };
        // With partial messages the text has already streamed; this is the backstop for
        // a run where it did not (an error subtype, or a CLI that dropped the deltas).
        if (!answer && typeof ev.result === 'string') {
          answer = ev.result;
          emit({ t: 'delta', text: answer });
        }
        if (ev.is_error) emit({ t: 'error', message: asString(ev.result) || 'claude reported an error' });
      }
    };

    child.stdout.on('data', d => {
      buf += d.toString('utf8');
      let nl;
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) handle(line);
      }
    });
    child.stderr.on('data', d => { stderr += d.toString('utf8'); });

    child.on('error', e => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      reject(new Error('could not run claude (' + cfg.CLAUDE_BIN + '): ' + e.message));
    });

    child.on('close', code => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (buf.trim()) handle(buf.trim());
      if (code !== 0 && !answer) {
        return reject(new Error('claude exited ' + code + ': ' + (stderr || '').trim().slice(0, 400)));
      }
      resolve({ text: answer, meta });
    });

    child.stdin.on('error', () => {});
    child.stdin.end(composePrompt(text, attachments), 'utf8');
  });
}

/** A one-line summary of a tool call, for the "reading X…" line in the UI. */
function describeTool(block) {
  const i = block.input || {};
  const p = asString(i.file_path || i.path || i.pattern || i.query || i.url);
  return p ? path.basename(p) || p : '';
}

/**
 * Attachments are handed over as paths, not as base64 in the prompt: the CLI has a Read
 * tool that handles images natively, and a path costs a few tokens where an inlined
 * photo costs thousands before Claude has decided whether it even needs to look.
 */
function composePrompt(text, attachments) {
  const body = asString(text);
  if (!attachments || !attachments.length) return body;
  const list = attachments.map(a => '- ' + a).join('\n');
  return body + '\n\nThe student attached these files. Read them:\n' + list;
}

/**
 * Public entry point for a turn. Creates the session on first use, appends both messages
 * to the transcript, and keeps the index current.
 */
async function send({ scope, sessionId, text, attachments, onEvent }) {
  ensureDirs();
  const resolved = resolveScope(scope);
  const idx = readIndex();

  let record = sessionId ? idx.sessions.find(s => s.id === sessionId) : null;
  const isNew = !record;
  // The client mints the id so it can attach photos before the first turn has created
  // anything. Any UUID it offers is honoured; a malformed one is replaced rather than
  // trusted, since it becomes a directory name.
  const offered = asString(sessionId).trim();
  const id = record ? record.id
    : (/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(offered)
        ? offered : crypto.randomUUID());

  if (!record) {
    record = {
      id,
      key: scopeKey(resolved),
      course: resolved.course,
      module: resolved.module,
      fileId: resolved.fileId,
      kind: resolved.kind,
      label: resolved.label,
      title: titleFrom(text),
      createdAt: nowIso(),
      updatedAt: nowIso(),
      messages: 0,
    };
    idx.sessions.push(record);
  }

  const transcript = readTranscript(id) || { id, scope: record, messages: [] };
  transcript.messages.push({
    role: 'user', text: asString(text), at: nowIso(),
    attachments: (attachments || []).map(a => path.basename(a)),
  });

  log.info('chat', isNew ? 'start' : 'turn', id, '|', resolved.kind, resolved.label,
    '|', (attachments || []).length, 'attachment(s)');

  let result;
  try {
    result = await run({
      scope: resolved, sessionId: id, resume: !isNew, text,
      attachments, onEvent,
    });
  } catch (e) {
    // The question is not lost just because the answer failed.
    writeTranscript(id, transcript);
    record.updatedAt = nowIso();
    record.messages = transcript.messages.length;
    writeIndex(idx);
    throw e;
  }

  transcript.messages.push({ role: 'assistant', text: result.text, at: nowIso(), meta: result.meta });
  writeTranscript(id, transcript);

  record.updatedAt = nowIso();
  record.messages = transcript.messages.length;
  if (isNew) record.title = titleFrom(text);
  writeIndex(idx);

  log.info('chat done', id, '|', (result.text || '').length, 'chars',
    result.meta.durationMs ? '| ' + Math.round(result.meta.durationMs / 1000) + 's' : '');

  return { id, text: result.text, meta: result.meta };
}

module.exports = {
  resolveScope, listSessions, readTranscript, deleteSession,
  saveAttachment, attachmentDir, send, MODEL,
};
