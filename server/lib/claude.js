'use strict';
// The Claude pass. Runs on Kieran's SUBSCRIPTION through the claude CLI - there is
// no API key anywhere in this project. The prompt goes in on STDIN because an hour
// of lecture is ~12k tokens, far past the Windows command-line limit.
const { spawn } = require('child_process');
const cfg = require('./config');
const log = require('./log');
const { localDate, isDateString, asArray, asString, slugTag, sanitizeName } = require('./util');

// --------------------------------------------------------------- schemas
// --json-schema makes the CLI return a bare JSON object with no prose and no
// ```json fence, and it enforces the field types (without it, `notes` comes back
// as an array about half the time). We still parse defensively.
const LECTURE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    course: { type: 'string' },
    courseIsNew: { type: 'boolean' },
    topic: { type: 'string' },
    section: { type: ['string', 'null'] },
    classDate: { type: 'string' },
    tags: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    keyTerms: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: { term: { type: 'string' }, definition: { type: 'string' } },
        required: ['term', 'definition'],
      },
    },
    notes: { type: 'string' },
    actionItems: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: { text: { type: 'string' }, due: { type: ['string', 'null'] } },
        required: ['text', 'due'],
      },
    },
  },
  required: ['course', 'courseIsNew', 'topic', 'section', 'classDate', 'tags',
             'summary', 'keyTerms', 'notes', 'actionItems'],
};

const CAPTURE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    kind: { type: 'string', enum: ['todo', 'homework', 'note'] },
    text: { type: 'string' },
    course: { type: ['string', 'null'] },
    due: { type: ['string', 'null'] },
  },
  required: ['kind', 'text', 'course', 'due'],
};

// How much of the Mac's rough live draft is enough to recognise a subject. The whole
// point of this pass is that it runs BEFORE whisper, so it has to be cheap.
const COURSE_MATCH_SAMPLE = 3000;

const COURSE_MATCH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    course: { type: ['string', 'null'] },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
  required: ['course', 'confidence'],
};

const GLOSSARY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    terms: { type: 'array', items: { type: 'string' } },
  },
  required: ['terms'],
};

const SYSTEM_PROMPT =
  'You are a precise extraction service inside a note-taking pipeline. You read a ' +
  'class transcript and return one JSON object. You never ask questions, never add ' +
  'commentary, and never invent facts that are not in the input.';

// --------------------------------------------------------------- prompts
function buildLecturePrompt(payload, courses, transcript) {
  const day = localDate(payload.recordedAt, cfg.TZ);
  const durMin = Math.round((payload.durationSec || 0) / 60);
  const courseList = courses.length ? JSON.stringify(courses) : '(none yet - this is the first note)';

  return [
'Turn the class transcript below into organized study notes. Return one JSON object.',
'',
'RECORDING METADATA',
'- Title the student typed: ' + JSON.stringify(asString(payload.title)),
'- Recording started (UTC): ' + payload.recordedAt,
'- Local date of the recording (' + cfg.TZ + '): ' + day,
'- Duration: ' + durMin + ' minutes',
'- Courses that already exist in the vault: ' + courseList,
'',
'FIELD RULES',
'1. course - If this lecture belongs to one of the existing courses listed above, output',
'   that name EXACTLY as written, character for character, and set courseIsNew=false.',
'   "Chem 101", "CHEM101" and "Chemistry 101" must never coexist. Only when none of them',
'   is the same class, invent a new properly capitalised name (e.g. "Chemistry 101") and',
'   set courseIsNew=true. When you genuinely cannot tell what class this is, use',
'   "Uncategorized" with courseIsNew=false.',
'2. topic - a short, specific title for THIS class, 3-8 words. No course name, no date,',
'   no "Lecture 5". Describe what was actually taught.',
'3. section - the textbook or lecture section / chapter the lecturer names out loud',
'   ("today we are covering section 4.3", "chapter 12", "unit 2.1"). Copy the identifier',
'   verbatim: "4.3", "12", "2.1". If the lecturer never states one, output null.',
'   NEVER infer, guess, or invent a section number.',
'4. classDate - YYYY-MM-DD, the day the class happened. Default to the local date given',
'   above. Only use a different date if the transcript clearly states one.',
'5. summary - 2 to 4 sentences of plain language: what this class actually covered.',
'6. keyTerms - the terms, concepts, laws and equations that were DEFINED or explained in',
'   class, each with a one or two sentence definition in the lecturer\'s sense. 0-15 items.',
'   Empty array if the class defined nothing.',
'7. notes - Markdown. The organised MAIN TAKEAWAYS, not a rewrite or a restatement of the',
'   transcript. Group related ideas under a few "### " subheadings, then bullets under',
'   each. Keep worked examples, formulas (LaTeX in $...$ or $$...$$), distinctions the',
'   lecturer drew, and anything repeated or emphasised. Drop filler, attendance, tangents,',
'   administrivia and transcription noise. Do NOT include a "# " title, a summary section,',
'   a key-terms section or an action-items section - those are separate fields.',
'8. actionItems - everything the student has to DO: homework problem sets, readings, lab',
'   prep, quizzes, project milestones, and anything flagged as "this will be on the exam".',
'   text is one imperative line including problem numbers ("Do problems 12-20 in chapter 4").',
'   due is YYYY-MM-DD when a date or weekday is stated - resolve weekdays forward from',
'   classDate - otherwise null. Empty array if nothing was assigned.',
'9. tags - 2 to 6 lowercase kebab-case topic tags. No course name, no dates.',
'',
'The transcript is automatic speech recognition, so expect occasional misheard words,',
'especially names and technical vocabulary. Correct an obvious mishearing when the',
'context makes the intended word unambiguous; never invent content to paper over a gap.',
'',
'=== TRANSCRIPT BEGINS ===',
String(transcript == null ? (payload.transcript || '') : transcript),
'=== TRANSCRIPT ENDS ===',
  ].join('\n');
}

/**
 * Pull the technical vocabulary out of a course's own materials.
 *
 * This is what fixes whisper's cold start. The glossary otherwise only grows from
 * previous notes, so the FIRST lecture of a course - exactly when the jargon is
 * newest - gets no biasing at all. Slides and a syllabus give us the words before
 * the first recording exists.
 */
function buildGlossaryPrompt(courseName, samples) {
  return [
'List the technical vocabulary a lecturer in this course would say out loud.',
'',
'Course: ' + JSON.stringify(asString(courseName)),
'',
'These terms seed a speech recogniser, so they are useful only if they are words',
'that get SPOKEN in class and that a general-purpose recogniser would otherwise get',
'wrong: technical nouns, named laws and people, units, reagents, anatomy, notation',
'read aloud. Include the singular form a lecturer would actually say.',
'',
'Rules:',
'- 30 to 60 terms, ordered most to least likely to be spoken.',
'- Each term 1-4 words, under 40 characters. No definitions, no numbering.',
'- Proper nouns keep their spelling and accents ("Le Chatelier", "Avogadro").',
'- NO generic academic words (syllabus, midterm, homework, chapter, quiz, exam).',
'- NO words from the document furniture: page numbers, file names, the instructor\'s',
'  email, "office hours", publisher boilerplate.',
'- Only terms actually present in the material below. Do not invent plausible ones.',
'',
'=== COURSE MATERIAL BEGINS ===',
String(samples || '').slice(0, 60000),
'=== COURSE MATERIAL ENDS ===',
  ].join('\n');
}

function normaliseGlossary(data) {
  const seen = new Set();
  const out = [];
  for (const t of asArray(data && data.terms)) {
    const s = asString(t).trim().replace(/\s+/g, ' ').replace(/^[-*\d.\s]+/, '');
    if (!s || s.length > 40 || s.length < 2) continue;
    const k = s.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(s);
  }
  return out.slice(0, 60);
}

/**
 * Which known course is this recording from? Deliberately a closed-list choice: the
 * model picks a name we already have or says null. Naming a new course is the job of
 * the note pass later on, once whisper has produced something worth reading.
 */
function buildCourseMatchPrompt(title, draft, courses) {
  return [
'Identify which of the student\'s existing courses this class recording belongs to.',
'',
'COURSES - answer with one of these names copied EXACTLY, or null:',
JSON.stringify(courses),
'',
'The student names recordings in a hurry, mid-class, on a laptop. Titles are',
'abbreviations, nicknames, dates, or mostly noise - "chem9/7(halfway through class)",',
'"bio tues", "2nd half". Judge by the SUBJECT MATTER of the transcript first and the',
'title second. A title that only abbreviates a course name ("chem" for "Chemistry 101")',
'is still a match.',
'',
'Answer null only if the transcript is genuinely none of the listed courses. Do not',
'invent a course name, and do not answer with a course that is not in the list above.',
'',
'TITLE: ' + asString(title),
'',
'TRANSCRIPT - rough live draft, first ' + COURSE_MATCH_SAMPLE + ' characters:',
asString(draft).slice(0, COURSE_MATCH_SAMPLE),
  ].join('\n');
}

function buildCapturePrompt(payload, courses) {
  const day = localDate(payload.capturedAt, cfg.TZ);
  const courseList = courses.length ? JSON.stringify(courses) : '(none yet)';
  const forced = payload.kind && payload.kind !== 'auto' ? payload.kind : null;

  return [
'A student dictated a quick capture into their phone. Clean it up and file it.',
'Return one JSON object.',
'',
'- Captured (local ' + cfg.TZ + '): ' + day,
'- Existing courses: ' + courseList,
forced ? '- The student already chose kind="' + forced + '". Use exactly that value.'
       : '- kind: "homework" for graded work with problems or readings, "todo" for any other' +
         ' task or reminder, "note" for a fact worth keeping that is not a task.',
'',
'- text: one clean imperative line ("Do problems 12-20 in chapter 4"), or for kind="note"',
'  the cleaned-up fact. Fix dictation errors. Do not add information.',
'- course: the exact name from the existing course list if one is clearly meant,',
'  otherwise null. Never invent a near-duplicate of an existing course.',
'- due: YYYY-MM-DD if a date or weekday is stated - resolve weekdays forward from the',
'  capture date above - otherwise null.',
'',
'=== CAPTURE ===',
String(payload.text || ''),
'=== END ===',
  ].filter(Boolean).join('\n');
}

// ------------------------------------------------------------ the process
function claudeArgs(schema) {
  const args = [
    '-p',
    '--output-format', 'json',
    '--tools', '',                 // pure text transform: no file access, no bash
    '--strict-mcp-config',         // ignore any MCP servers configured for the user
    '--setting-sources', '',       // ignore user/project settings and CLAUDE.md
    '--disable-slash-commands',
    '--no-session-persistence',
    '--system-prompt', SYSTEM_PROMPT,
  ];
  if (cfg.MODEL) args.push('--model', cfg.MODEL);
  if (schema) args.push('--json-schema', JSON.stringify(schema));
  return args;
}

/** Pull a JSON object out of text that may be fenced or wrapped in prose. */
function extractJson(text) {
  const s = String(text == null ? '' : text).trim();
  if (!s) throw new Error('claude returned an empty result');

  const attempts = [];
  attempts.push(s);

  const fence = /```(?:json)?\s*([\s\S]*?)```/i.exec(s);
  if (fence) attempts.push(fence[1].trim());

  const first = s.indexOf('{');
  const last = s.lastIndexOf('}');
  if (first !== -1 && last > first) attempts.push(s.slice(first, last + 1));

  for (const a of attempts) {
    try { const v = JSON.parse(a); if (v && typeof v === 'object' && !Array.isArray(v)) return v; }
    catch (_) {}
  }
  throw new Error('could not parse JSON from claude output: ' + s.slice(0, 300));
}

function spawnClaude(prompt, schema) {
  return new Promise((resolve, reject) => {
    const args = claudeArgs(schema);
    const child = spawn(cfg.CLAUDE_BIN, args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      cwd: cfg.VAULT,
      env: Object.assign({}, process.env, {
        // Belt and braces: this project must never bill an API key.
        ANTHROPIC_API_KEY: '',
        ANTHROPIC_AUTH_TOKEN: '',
      }),
    });

    let out = '', err = '', settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill(); } catch (_) {}
      reject(new Error('claude timed out after ' + Math.round(cfg.CLAUDE_TIMEOUT_MS / 1000) + 's'));
    }, cfg.CLAUDE_TIMEOUT_MS);

    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    child.on('error', e => {
      if (settled) return; settled = true; clearTimeout(timer);
      reject(new Error('could not run claude (' + cfg.CLAUDE_BIN + '): ' + e.message));
    });
    child.on('close', code => {
      if (settled) return; settled = true; clearTimeout(timer);
      if (code !== 0) {
        return reject(new Error('claude exited ' + code + ': ' + (err || out).trim().slice(0, 400)));
      }
      let envelope;
      try { envelope = JSON.parse(out); }
      catch (_) { return resolve({ text: out, meta: {} }); } // plain-text fallback
      if (envelope.is_error) {
        return reject(new Error('claude reported an error: ' +
          String(envelope.result || envelope.api_error_status || 'unknown').slice(0, 400)));
      }
      resolve({
        text: envelope.result,
        meta: {
          model: envelope.modelUsage ? Object.keys(envelope.modelUsage)[0] : cfg.MODEL,
          durationMs: envelope.duration_ms,
          costUsd: envelope.total_cost_usd,
          sessionId: envelope.session_id,
        },
      });
    });

    child.stdin.on('error', () => {}); // EPIPE if claude dies early
    child.stdin.end(prompt, 'utf8');
  });
}

/** Run the pass, retrying once without --json-schema if the CLI rejects the flag. */
async function ask(prompt, schema) {
  let res;
  try {
    res = await spawnClaude(prompt, schema);
  } catch (e) {
    if (/unknown option|json-schema/i.test(e.message)) {
      log.warn('--json-schema rejected, retrying without it:', e.message.slice(0, 160));
      res = await spawnClaude(prompt + '\n\nReturn ONLY the JSON object, with no prose and no code fence.', null);
    } else {
      throw e;
    }
  }
  return { data: extractJson(res.text), meta: res.meta };
}

/**
 * Resolve a recording to one of `courses`, or null. The answer is validated against the
 * list before it is returned - a model that names something not on the list is treated
 * as "no match", because the only thing downstream of this is which glossary biases
 * whisper, and a wrong glossary is worse than none.
 */
async function matchCourse(title, draft, courses) {
  if (!Array.isArray(courses) || !courses.length) return null;
  const { data, meta } = await ask(buildCourseMatchPrompt(title, draft, courses), COURSE_MATCH_SCHEMA);
  const raw = asString(data && data.course).trim();
  if (!raw || /^(null|none)$/i.test(raw)) return null;
  const hit = courses.find(c => String(c).toLowerCase() === raw.toLowerCase());
  if (!hit) {
    log.warn('claude matched a course that does not exist:', JSON.stringify(raw), '- ignoring');
    return null;
  }
  return { course: hit, confidence: asString(data.confidence) || 'unknown', meta };
}

// ------------------------------------------------------------- normalising
function pickCourse(raw, known) {
  const s = asString(raw).trim();
  if (!s) return 'Uncategorized';
  const hit = known.find(k => k.toLowerCase() === s.toLowerCase());
  return hit || s;
}

function normaliseLecture(data, payload, knownCourses) {
  const fallbackDate = localDate(payload.recordedAt, cfg.TZ);
  const course = sanitizeName(pickCourse(data.course, knownCourses), 'Uncategorized');
  let topic = sanitizeName(asString(data.topic).trim(), '');
  if (!topic) topic = sanitizeName(asString(payload.title), 'Untitled Class');

  let section = data.section;
  if (typeof section === 'number') section = String(section);
  section = asString(section).trim();
  if (!section || /^(null|none|n\/a|unknown|not mentioned)$/i.test(section)) section = null;
  if (section && section.length > 40) section = section.slice(0, 40);

  const classDate = isDateString(data.classDate) ? data.classDate : fallbackDate;

  const tags = Array.from(new Set(asArray(data.tags).map(slugTag).filter(Boolean))).slice(0, 8);

  const keyTerms = asArray(data.keyTerms)
    .map(t => ({ term: asString(t && t.term).trim(), definition: asString(t && t.definition).trim() }))
    .filter(t => t.term)
    .slice(0, 30);

  const actionItems = asArray(data.actionItems)
    .map(a => ({
      text: asString(a && a.text).trim(),
      due: isDateString(a && a.due) ? a.due : null,
    }))
    .filter(a => a.text)
    .slice(0, 40);

  const knownLower = knownCourses.map(c => c.toLowerCase());
  const courseIsNew = !knownLower.includes(course.toLowerCase());

  return {
    course, courseIsNew, topic, section, classDate, tags,
    summary: asString(data.summary).trim(),
    keyTerms,
    notes: asString(data.notes).trim(),
    actionItems,
  };
}

function normaliseCapture(data, payload, knownCourses) {
  let kind = asString(data.kind).toLowerCase().trim();
  if (payload.kind && payload.kind !== 'auto') kind = payload.kind;
  if (!['todo', 'homework', 'note'].includes(kind)) kind = 'todo';
  const text = asString(data.text).trim() || asString(payload.text).trim();
  let course = asString(data.course).trim();
  if (!course || /^(null|none)$/i.test(course)) course = null;
  else course = pickCourse(course, knownCourses);
  const due = isDateString(data.due) ? data.due : null;
  return { kind, text, course, due };
}

// ------------------------------------------------------------------ health
let claudeOk = null;
let lastProbe = 0;

function probe() {
  return new Promise(resolve => {
    const child = spawn(cfg.CLAUDE_BIN, ['--version'], { windowsHide: true, stdio: 'ignore' });
    const t = setTimeout(() => { try { child.kill(); } catch (_) {} resolve(false); }, 20000);
    child.on('error', () => { clearTimeout(t); resolve(false); });
    child.on('close', code => { clearTimeout(t); resolve(code === 0); });
  });
}

async function checkHealth(force) {
  const age = Date.now() - lastProbe;
  if (!force && claudeOk !== null && age < 5 * 60 * 1000) return claudeOk;
  lastProbe = Date.now();
  claudeOk = await probe();
  return claudeOk;
}
function setHealth(ok) { claudeOk = ok; lastProbe = Date.now(); }
function lastHealth() { return claudeOk; }

module.exports = {
  LECTURE_SCHEMA, GLOSSARY_SCHEMA, CAPTURE_SCHEMA, COURSE_MATCH_SCHEMA,
  buildLecturePrompt, buildCapturePrompt, buildGlossaryPrompt, normaliseGlossary,
  buildCourseMatchPrompt, matchCourse,
  ask, extractJson, normaliseLecture, normaliseCapture,
  checkHealth, setHealth, lastHealth,
};
