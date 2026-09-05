'use strict';
// The GPU transcription pass: faster-whisper large-v3, float16, CUDA, driven by
// server/python/transcribe.py in a venv outside the vault.
//
// The Node server itself still has zero npm dependencies; Python is a subprocess.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const log = require('./log');
const { asString } = require('./util');

/**
 * Build the whisper `initial_prompt`.
 *
 * This is a genuine accuracy lever: whisper conditions its first window on this
 * text, so seeding it with the course's own vocabulary is what makes
 * "Le Chatelier", "chemiosmotic" and "cytochrome c oxidase" come out right instead
 * of phonetically. The glossary accumulates in _courses.json from the key terms of
 * every previous note in that course.
 */
function buildInitialPrompt(courseName, glossary, title) {
  const bits = [];
  if (courseName) bits.push('The following is a lecture from ' + courseName + '.');
  else if (title) bits.push('The following is a university lecture recording: ' + title + '.');
  else bits.push('The following is a university lecture recording.');

  const terms = (glossary || []).filter(Boolean);
  if (terms.length) {
    const lead = 'Terms used in this course include: ';
    // Budget the WHOLE prompt, not just the term list. whisper truncates
    // initial_prompt to its last 224 tokens, so an overlong prompt silently loses
    // its front - which used to be exactly the terms we most wanted to prime.
    const overhead = bits.join(' ').length + 1 + lead.length + 1;   // + the trailing '.'
    let budget = cfg.GLOSSARY_PROMPT_CHARS - overhead;
    const kept = [];
    for (const t of terms) {
      const cost = t.length + (kept.length ? 2 : 0);                // ', '
      if (cost > budget) break;
      kept.push(t);
      budget -= cost;
    }
    if (kept.length) bits.push(lead + kept.join(', ') + '.');
  }
  return bits.join(' ');
}

/**
 * Guess which existing course a recording belongs to BEFORE Claude has seen it,
 * so the right glossary can bias transcription. Scores the recording title heavily
 * and Apple's draft transcript lightly.
 */
function guessCourse(title, draft, courses) {
  const t = ' ' + asString(title).toLowerCase().replace(/[^a-z0-9]+/g, ' ') + ' ';
  const d = ' ' + asString(draft).slice(0, 4000).toLowerCase().replace(/[^a-z0-9]+/g, ' ') + ' ';
  let best = null, bestScore = 0;
  for (const c of courses) {
    const norm = String(c).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
    const tokens = norm.split(' ').filter(Boolean);
    if (!tokens.length) continue;
    let score = 0;
    // the whole course name spelled out is a strong signal wherever it appears
    if (t.includes(' ' + norm + ' ')) score += 5 * tokens.length;
    else if (d.includes(' ' + norm + ' ')) score += 3 * tokens.length;
    for (const tok of tokens) {
      if (tok.length < 2) continue;
      if (t.includes(' ' + tok + ' ')) score += 3;
      else if (t.includes(tok)) score += 2;     // "chem101" contains "chem" and "101"
      if (d.includes(' ' + tok + ' ')) score += 1;
    }
    score = score / tokens.length;
    if (score > bestScore) { bestScore = score; best = c; }
  }
  return bestScore >= 1.5 ? best : null;
}

/** A filename-safe, pure-ASCII key derived from the audio path (which is `<uuid>.m4a`). */
function asciiKey(audioPath) {
  const base = path.basename(audioPath || '').replace(/\.[^.]*$/, '');
  const safe = base.replace(/[^A-Za-z0-9_-]/g, '');
  return safe || ('job-' + Date.now());
}

/**
 * Run the transcription. Resolves with the parsed result object (including `text`
 * and `segments`), rejects with a descriptive Error. `onProgress(done, total)` is
 * called as segments stream out.
 */
function transcribe(opts) {
  // The vault's pretty filenames contain an em dash. That character does not survive the
  // Node->Python boundary intact on Windows (the child decodes stdin as cp1252 unless
  // forced), so Python wrote its JSON to a mojibake path and Node's read got ENOENT --
  // which then fell back to the Mac's draft transcript without anything looking broken.
  // Hand Python a pure-ASCII scratch path instead and do the rename ourselves.
  const scratchDir = path.join(cfg.VAULT, 'tmp');
  try { fs.mkdirSync(scratchDir, { recursive: true }); } catch (e) {}
  const scratchJson = path.join(scratchDir, asciiKey(opts.audio) + '.json');
  try { fs.unlinkSync(scratchJson); } catch (e) {}

  const job = {
    audio: opts.audio,
    out_json: scratchJson,
    model: cfg.WHISPER_MODEL,
    device: cfg.WHISPER_DEVICE,
    compute_type: cfg.WHISPER_COMPUTE,
    model_dir: cfg.WHISPER_MODEL_DIR,
    beam_size: cfg.WHISPER_BEAM,
    vad_filter: true,
    language: opts.language || 'en',
    initial_prompt: opts.initialPrompt || null,
  };

  return new Promise((resolve, reject) => {
    if (!fs.existsSync(cfg.PYTHON)) {
      return reject(new Error('python venv not found at ' + cfg.PYTHON +
        ' - run scripts/install-whisper.sh'));
    }
    const child = spawn(cfg.PYTHON, [cfg.TRANSCRIBE_PY], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      cwd: cfg.VAULT,
      // Belt and braces alongside the ASCII scratch path: make the child speak UTF-8
      // regardless of the machine's code page.
      env: Object.assign({}, process.env, {
        PYTHONUTF8: '1',
        PYTHONIOENCODING: 'utf-8',
      }),
    });

    let out = '', errTail = '', settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill(); } catch (_) {}
      reject(new Error('whisper timed out after ' + Math.round(cfg.WHISPER_TIMEOUT_MS / 60000) + ' min'));
    }, cfg.WHISPER_TIMEOUT_MS);

    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => {
      const s = String(d);
      errTail = (errTail + s).slice(-4000);
      for (const line of s.split(/\r?\n/)) {
        const m = /^PROGRESS ([\d.]+) ([\d.]+)$/.exec(line.trim());
        if (m && opts.onProgress) opts.onProgress(parseFloat(m[1]), parseFloat(m[2]));
        if (/^MODEL_LOADED/.test(line)) log.info('whisper', line.trim());
      }
    });
    child.on('error', e => {
      if (settled) return; settled = true; clearTimeout(timer);
      reject(new Error('could not run python (' + cfg.PYTHON + '): ' + e.message));
    });
    child.on('close', code => {
      if (settled) return; settled = true; clearTimeout(timer);
      let summary = null;
      try { summary = JSON.parse(out.trim()); } catch (_) {}
      if (code !== 0 || !summary || summary.ok !== true) {
        const why = (summary && summary.error) || errTail.trim().split(/\r?\n/).slice(-6).join(' | ') ||
          ('exit ' + code);
        return reject(new Error('whisper failed: ' + String(why).slice(0, 500)));
      }
      let full;
      try { full = JSON.parse(fs.readFileSync(scratchJson, 'utf8')); }
      catch (e) {
        return reject(new Error('whisper wrote no readable result at ' + scratchJson +
                                ': ' + e.message));
      }
      // Node owns the move into the vault, so the em dash never crosses a process boundary.
      try {
        fs.mkdirSync(path.dirname(opts.outJson), { recursive: true });
        fs.copyFileSync(scratchJson, opts.outJson);
        fs.unlinkSync(scratchJson);
      } catch (e) {
        log.warn('could not move whisper sidecar into the vault: ' + e.message);
      }
      full._summary = summary;
      resolve(full);
    });

    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(job), 'utf8');
  });
}

// ------------------------------------------------------------------- health
let ok = null, lastProbe = 0, lastDetail = '';

function probe() {
  return new Promise(resolve => {
    if (!fs.existsSync(cfg.PYTHON)) return resolve({ ok: false, detail: 'venv missing' });
    const code = [
      'import os,sys,json',
      'base=os.path.join(sys.prefix,"Lib","site-packages","nvidia")',
      'for s in ("cublas","cudnn","cuda_nvrtc"):',
      '    p=os.path.join(base,s,"bin")',
      '    if os.path.isdir(p): os.add_dll_directory(p)',
      'import ctranslate2',
      'print(json.dumps({"cuda":ctranslate2.get_cuda_device_count(),"ct2":ctranslate2.__version__}))',
    ].join('\n');
    const child = spawn(cfg.PYTHON, ['-c', code], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let o = '', e = '';
    child.stdout.on('data', d => o += d);
    child.stderr.on('data', d => e += d);
    const t = setTimeout(() => { try { child.kill(); } catch (_) {} resolve({ ok: false, detail: 'probe timeout' }); }, 30000);
    child.on('error', err => { clearTimeout(t); resolve({ ok: false, detail: err.message }); });
    child.on('close', c => {
      clearTimeout(t);
      if (c !== 0) return resolve({ ok: false, detail: (e || 'exit ' + c).slice(0, 200) });
      try {
        const j = JSON.parse(o.trim());
        resolve({ ok: j.cuda > 0, detail: 'ctranslate2 ' + j.ct2 + ', cuda devices ' + j.cuda });
      } catch (_) { resolve({ ok: false, detail: 'unparseable probe output' }); }
    });
  });
}

async function checkHealth(force) {
  if (!force && ok !== null && Date.now() - lastProbe < 10 * 60 * 1000) return ok;
  lastProbe = Date.now();
  const r = await probe();
  ok = r.ok; lastDetail = r.detail;
  return ok;
}
function setHealth(v, detail) { ok = v; lastProbe = Date.now(); if (detail) lastDetail = detail; }
function lastHealth() { return ok; }
function detail() { return lastDetail; }

module.exports = { transcribe, buildInitialPrompt, guessCourse, checkHealth, setHealth, lastHealth, detail };
