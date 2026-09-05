'use strict';
// Node side of the course-material text extractor. Drives server/python/extract.py.
//
// The path discipline here is not optional. Canvas filenames carry em dashes,
// smart quotes and accents, and a Windows Node->Python round trip has already
// silently corrupted one of those in this project (CLAUDE.md). So: Python is only
// ever handed pure-ASCII scratch paths keyed by the Canvas file id, and Node does
// every rename into the vault itself.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const log = require('./log');

/** Extensions we can turn into text, and therefore into glossary terms. */
const SUPPORTED = new Set([
  'pdf', 'pptx', 'ppt', 'docx', 'html', 'htm', 'txt', 'md', 'csv', 'rtf', 'json',
]);

function extFor(name) {
  const m = /\.([A-Za-z0-9]{1,8})$/.exec(String(name || ''));
  return m ? m[1].toLowerCase() : '';
}
function canExtract(name) { return SUPPORTED.has(extFor(name)); }

function scratchDir() {
  const d = path.join(cfg.VAULT, 'tmp');
  try { fs.mkdirSync(d, { recursive: true }); } catch (_) {}
  return d;
}

/**
 * Extract `srcAbs` (already at an ASCII path) to text. Resolves
 * { ok, text, chars, pages, method } or { ok:false, error, unsupported }.
 * Never throws for a bad document - one unreadable PDF must not abort a sync.
 */
function toText(srcAbs, kind, asciiKey, opts) {
  const o = opts || {};
  // ".out.txt", not ".txt". A .txt/.md/.csv source is staged at
  // <scratch>/<key>.txt, so a plain ".txt" output path IS the input path: the
  // extractor would then delete its own source, and the caller's copy into the
  // vault would fail with ENOENT. That silently cost one whole course its materials.
  const outPath = path.join(scratchDir(), String(asciiKey) + '.out.txt');
  try { fs.unlinkSync(outPath); } catch (_) {}

  return new Promise(resolve => {
    if (!fs.existsSync(cfg.PYTHON)) {
      return resolve({ ok: false, error: 'python venv not found at ' + cfg.PYTHON });
    }
    const child = spawn(cfg.PYTHON, [cfg.EXTRACT_PY], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      cwd: cfg.VAULT,
      env: Object.assign({}, process.env, { PYTHONUTF8: '1', PYTHONIOENCODING: 'utf-8' }),
    });

    let out = '', errTail = '', settled = false;
    const done = v => { if (!settled) { settled = true; clearTimeout(timer); resolve(v); } };
    const timer = setTimeout(() => {
      try { child.kill(); } catch (_) {}
      done({ ok: false, error: 'extraction timed out' });
    }, cfg.EXTRACT_TIMEOUT_MS);

    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { errTail = (errTail + d).slice(-2000); });
    child.on('error', e => done({ ok: false, error: 'could not run python: ' + e.message }));
    child.on('close', code => {
      let summary = null;
      try { summary = JSON.parse(out.trim()); } catch (_) {}
      if (!summary) {
        return done({ ok: false, error: 'extractor produced no result (exit ' + code + '): ' +
          errTail.trim().split(/\r?\n/).slice(-3).join(' | ').slice(0, 300) });
      }
      if (!summary.ok) return done(summary);
      let text = '';
      try { text = fs.readFileSync(outPath, 'utf8'); }
      catch (e) { return done({ ok: false, error: 'extractor wrote no readable text: ' + e.message }); }
      try { fs.unlinkSync(outPath); } catch (_) {}
      // An "ok" that produced nothing is a scanned/image-only document. Say so -
      // silently storing an empty .txt would look exactly like a working sync.
      if (!text.trim()) {
        return done({ ok: false, error: 'no text layer, and OCR found nothing either',
                      empty: true, pages: summary.pages, method: summary.method });
      }
      done({ ok: true, text, chars: text.length, pages: summary.pages, method: summary.method });
    });

    child.stdin.end(JSON.stringify({
      input: srcAbs, output: outPath, kind,
      // OCR is a fallback inside the PDF handler; extract.py only reaches for it
      // when the text layer is effectively empty.
      ocr: o.ocr === undefined ? cfg.OCR_ENABLED : !!o.ocr,
      ocr_max_pages: cfg.OCR_MAX_PAGES,
      ocr_dpi: cfg.OCR_DPI,
    }), 'utf8');
  });
}

module.exports = { toText, canExtract, extFor, SUPPORTED, scratchDir };
