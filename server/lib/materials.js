'use strict';
// Canvas course materials: discover, download, extract, file, index.
//
// The priority is the files inside each course's MODULES, because that is where
// lecture slides and handouts actually live. Canvas exposes them three different
// ways depending on how the instructor built the course and whether the Files tab
// is unlocked for students, so all three are walked:
//
//   1. module items of type File                     (the common case)
//   2. file links inside Page / Assignment / Quiz /
//      Discussion bodies reached from module items   (very common)
//   3. the course Files tab                          (often 403 for students)
//
// Everything lands under Course Materials/<course>/<NN Module>/, with the
// extracted text beside each file so the vault stays greppable and Claude-readable
// without re-parsing anything.
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const log = require('./log');
const sse = require('./sse');
const store = require('./store');
const canvas = require('./canvas');
const extract = require('./extract');
const { sanitizeName, nowIso, asString, mdPath, localDate } = require('./util');
const pipeline = require('./pipeline');

const SEP = ' — ';
let running = null;      // a promise while a sync is in flight
let lastResult = null;

// ------------------------------------------------------------------- paths
function courseDir(vaultCourse) {
  return path.join(cfg.DIRS.materials, sanitizeName(vaultCourse, 'Uncategorized'));
}
function manifestPath(vaultCourse) {
  return path.join(courseDir(vaultCourse), '_canvas.json');
}
function rel(abs) {
  return path.relative(cfg.VAULT, abs).split(path.sep).join('/');
}

/** sanitizeName truncates, which would eat an extension. Keep the suffix intact. */
function safeFileName(displayName, fallbackExt) {
  const raw = asString(displayName, 'file').trim();
  const m = /^(.*?)(\.[A-Za-z0-9]{1,8})$/.exec(raw);
  const base = m ? m[1] : raw;
  const ext = (m ? m[2] : (fallbackExt ? '.' + fallbackExt : '')).toLowerCase();
  return sanitizeName(base, 'file').slice(0, 80) + ext;
}

function moduleFolder(mod) {
  const n = Number(mod.position || 0);
  const prefix = n > 0 ? String(n).padStart(2, '0') + ' ' : '';
  return sanitizeName(prefix + asString(mod.name, 'Module'), 'Module');
}

// ---------------------------------------------------------------- manifest
function readManifest(vaultCourse) {
  try { return JSON.parse(fs.readFileSync(manifestPath(vaultCourse), 'utf8')); }
  catch (_) { return null; }
}
function writeManifest(vaultCourse, m) {
  const p = manifestPath(vaultCourse);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = p + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(m, null, 2), 'utf8');
  fs.renameSync(tmp, p);
}

// ------------------------------------------------------------ course match
function normTokens(s) {
  return asString(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().split(' ').filter(Boolean);
}

/** 0..1 overlap between a Canvas course and an existing vault course name. */
function matchScore(canvasCourse, vaultName) {
  const v = new Set(normTokens(vaultName));
  if (!v.size) return 0;
  const c = new Set(normTokens(canvasCourse.name).concat(normTokens(canvasCourse.course_code)));
  if (!c.size) return 0;
  let hit = 0;
  for (const t of v) if (c.has(t)) hit++;
  return hit / v.size;
}

/**
 * Which vault course does this Canvas course belong to?
 *
 * A wrong answer here scatters a course's notes and materials across two folders,
 * so the bar for reusing an existing name is deliberately high, and the decision is
 * always reported (`matchedBy`) rather than done quietly.
 */
function resolveVaultCourse(canvasCourse) {
  const canvasId = String(canvasCourse.id);
  for (const c of store.state.courses.values()) {
    if (c.canvas && String(c.canvas.id) === canvasId) return { name: c.name, matchedBy: 'canvasId' };
  }
  let best = null, bestScore = 0;
  for (const c of store.state.courses.values()) {
    if (c.canvas) continue;                       // already spoken for
    const s = matchScore(canvasCourse, c.name);
    if (s > bestScore) { bestScore = s; best = c.name; }
  }
  if (best && bestScore >= 0.5) return { name: best, matchedBy: 'name', score: bestScore };
  const fresh = sanitizeName(canvasCourse.name || canvasCourse.course_code || 'Course', 'Course');
  return { name: fresh, matchedBy: 'created', suggested: best, suggestedScore: bestScore };
}

// ------------------------------------------------------- reference gathering
const FILE_ID_RE = /\/files\/(\d+)/g;

function scrapeFileIds(html) {
  const out = new Set();
  let m;
  FILE_ID_RE.lastIndex = 0;
  while ((m = FILE_ID_RE.exec(asString(html))) !== null) out.add(m[1]);
  return Array.from(out);
}

/** Pull a module's items, fetching them separately when Canvas omits the inline list. */
async function moduleItems(courseId, mod) {
  if (Array.isArray(mod.items) && mod.items.length) return mod.items;
  if (!mod.items_url) return [];
  try {
    const u = new URL(mod.items_url);
    return await canvas.apiAll(u.pathname + u.search);
  } catch (e) {
    log.warn('canvas: could not list items of module', mod.name, '-', e.message);
    return [];
  }
}

/**
 * Walk every module and return { refs, links, modules }.
 * refs: Map fileId -> { fileId, module, moduleId, itemTitle, via }
 */
async function collectRefs(courseId, report) {
  const refs = new Map();
  const links = [];
  const seen = [];
  let modules = [];
  try {
    modules = await canvas.apiAll('/api/v1/courses/' + courseId + '/modules?include[]=items');
  } catch (e) {
    if (e.code === 'CANVAS_AUTH') throw e;
    report.errors.modules = e.code || e.message;
    return { refs, links, modules: seen };
  }

  for (const mod of modules) {
    const folder = moduleFolder(mod);
    const items = await moduleItems(courseId, mod);
    seen.push({ id: String(mod.id), name: asString(mod.name), position: mod.position || 0,
                folder, itemCount: items.length, state: mod.state || null });

    for (const item of items) {
      const base = { module: folder, moduleId: String(mod.id), itemTitle: asString(item.title) };
      const add = (fileId, via) => {
        const key = String(fileId);
        if (!refs.has(key)) {
          refs.set(key, Object.assign({ fileId: key, via, alsoIn: [] }, base));
          return;
        }
        // Instructors relink the same handout across modules. Store it once - it can
        // be a 20MB deck - but remember everywhere it appears.
        const existing = refs.get(key);
        if (existing.module !== base.module && !existing.alsoIn.includes(base.module)) {
          existing.alsoIn.push(base.module);
        }
      };

      try {
        switch (item.type) {
          case 'File':
            if (item.content_id) add(item.content_id, 'module-item');
            break;
          case 'Page': {
            if (!item.page_url) break;
            const r = await canvas.api('/api/v1/courses/' + courseId + '/pages/' +
              encodeURIComponent(item.page_url));
            for (const id of scrapeFileIds(r.data && r.data.body)) add(id, 'page');
            break;
          }
          case 'Assignment': {
            if (!item.content_id) break;
            const r = await canvas.api('/api/v1/courses/' + courseId + '/assignments/' + item.content_id);
            for (const id of scrapeFileIds(r.data && r.data.description)) add(id, 'assignment');
            break;
          }
          case 'Quiz': {
            if (!item.content_id) break;
            const r = await canvas.api('/api/v1/courses/' + courseId + '/quizzes/' + item.content_id);
            for (const id of scrapeFileIds(r.data && r.data.description)) add(id, 'quiz');
            break;
          }
          case 'Discussion': {
            if (!item.content_id) break;
            const r = await canvas.api('/api/v1/courses/' + courseId + '/discussion_topics/' + item.content_id);
            for (const id of scrapeFileIds(r.data && r.data.message)) add(id, 'discussion');
            for (const a of (r.data && r.data.attachments) || []) if (a && a.id) add(a.id, 'discussion');
            break;
          }
          case 'ExternalUrl':
          case 'ExternalTool':
            if (item.external_url) {
              links.push({ title: asString(item.title), url: item.external_url, module: folder });
            }
            break;
          default:
            break;                                  // SubHeader and friends carry nothing
        }
      } catch (e) {
        if (e.code === 'CANVAS_AUTH') throw e;
        // A locked page or a deleted assignment is normal; note it and carry on.
        report.skipped.push({ item: asString(item.title), type: item.type, why: e.code || e.message });
      }
    }
  }

  // The Files tab catches anything the instructor uploaded but never linked. It is
  // frequently locked for students, which is not an error.
  try {
    const files = await canvas.apiAll('/api/v1/courses/' + courseId + '/files');
    for (const f of files) {
      if (!refs.has(String(f.id))) {
        refs.set(String(f.id), { fileId: String(f.id), via: 'files-tab', module: '_Files',
                                 moduleId: null, itemTitle: asString(f.display_name), meta: f });
      }
    }
  } catch (e) {
    if (e.code === 'CANVAS_AUTH') throw e;
    report.errors.files = e.code || e.message;
  }

  return { refs, links, modules: seen };
}

// ------------------------------------------------------- revisions / planning
function destRelFor(vaultCourse, ref, meta) {
  const name = safeFileName(meta.display_name || meta.filename, extract.extFor(meta.filename));
  return rel(path.join(courseDir(vaultCourse), ref.module || '_Files', name));
}

/** Newest revision first: Canvas's updated_at, then the file id, which counts up. */
function byRevisionDesc(a, b) {
  const ta = Date.parse((a.meta && a.meta.updated_at) || '') || 0;
  const tb = Date.parse((b.meta && b.meta.updated_at) || '') || 0;
  if (ta !== tb) return tb - ta;
  return (parseInt(b.fileId, 10) || 0) - (parseInt(a.fileId, 10) || 0);
}

/**
 * Decide which Canvas file owns each destination path, before anything is downloaded.
 *
 * Canvas mints a NEW file id every time an instructor re-uploads a document, and the
 * vault names files by display name - so three revisions of "Mod2.pdf" arrive as three
 * refs resolving to one path. Each download overwrote the last and each left a manifest
 * entry behind, so two of the three described bytes that were no longer on disk. It was
 * self-sustaining, too: a stale entry's own updatedAt and size still matched Canvas and
 * the file at its path still existed, so `unchanged` was true and the next sync never
 * looked again.
 *
 * A re-upload is a revision, not a second document. The newest wins the path; older
 * entries are dropped from the manifest whether or not Canvas still lists them; and the
 * winner is re-downloaded, because the bytes sitting there are whichever revision
 * happened to be written last, which is not the same question.
 *
 * Returns the refs actually worth syncing, in the original order.
 */
async function planRefs(courseId, refs, vaultCourse, manifest, report) {
  const byPath = new Map();
  const ordered = [];

  for (const ref of refs.values()) {
    ordered.push(ref);
    if (!ref.meta) {
      // syncFile would fetch this anyway; hoisting it costs no extra Canvas calls and
      // is what makes the destination knowable before we commit to a download.
      try { ref.meta = await fileMeta(courseId, ref.fileId, null); }
      catch (e) {
        if (e.code === 'CANVAS_AUTH') throw e;
        continue;                       // leave it to syncFile to report the skip
      }
    }
    if (!ref.meta || ref.meta.locked_for_user) continue;   // cannot own a path it can't fill
    ref.destRel = destRelFor(vaultCourse, ref, ref.meta);
    if (!byPath.has(ref.destRel)) byPath.set(ref.destRel, []);
    byPath.get(ref.destRel).push(ref);
  }

  for (const [destRel, group] of byPath) {
    group.sort(byRevisionDesc);
    const winner = group[0];

    // Older revisions simply are not synced. Once a path has been resolved that is the
    // steady state on every future run, so it is silent - the run only reports a change
    // it actually made.
    for (const loser of group.slice(1)) loser.supersededBy = winner.fileId;

    // Anything else still claiming this path is a leftover describing bytes that were
    // overwritten. Removing one is the real change, and it is also the only thing that
    // justifies re-fetching the winner: until it is gone, the file sitting at that path
    // may be a loser's. Once the manifest is clean this finds nothing and the winner
    // goes back to being 'unchanged'.
    let removed = 0;
    for (const [id, f] of Object.entries(manifest.files)) {
      if (id === winner.fileId || !f.path || f.path !== destRel) continue;
      delete manifest.files[id];
      removed++;
      report.superseded.push({
        path: destRel, name: f.name || id, droppedId: id, keptId: winner.fileId,
      });
    }
    if (removed) winner.forceDownload = true;
  }

  return ordered.filter(r => !r.supersededBy);
}

// ------------------------------------------------------------------- files
async function fileMeta(courseId, fileId, cached) {
  if (cached) return cached;
  const r = await canvas.api('/api/v1/courses/' + courseId + '/files/' + fileId);
  return r.data;
}

/**
 * Download one file (if changed) and extract its text. Mutates `manifest.files`.
 * Returns 'new' | 'updated' | 'unchanged' | 'skipped'.
 */
async function syncFile(courseId, ref, vaultCourse, manifest, report) {
  let meta;
  try {
    meta = await fileMeta(courseId, ref.fileId, ref.meta);
  } catch (e) {
    if (e.code === 'CANVAS_AUTH') throw e;
    report.skipped.push({ item: ref.itemTitle || ('file ' + ref.fileId), why: e.code || e.message });
    return 'skipped';
  }
  if (!meta || meta.locked_for_user) {
    report.skipped.push({ item: (meta && meta.display_name) || ref.fileId, why: 'locked' });
    return 'skipped';
  }

  const prev = manifest.files[ref.fileId];
  const name = safeFileName(meta.display_name || meta.filename, extract.extFor(meta.filename));
  const destAbs = path.join(courseDir(vaultCourse), ref.module || '_Files', name);
  const unchanged = prev && prev.updatedAt === meta.updated_at && prev.size === meta.size &&
    prev.path && fs.existsSync(path.join(cfg.VAULT, prev.path.split('/').join(path.sep)));
  // `unchanged` asks whether Canvas still agrees with our record - it cannot tell whether
  // the bytes at that path are OURS. When another revision of the same filename has been
  // writing over this path, they are not, and planRefs sets forceDownload to settle it.
  if (unchanged && !report.full && !ref.forceDownload) {
    // A file that produced no text is not "done" just because it is unchanged. When a
    // new extraction capability lands (OCR), revisit it once - from the copy already
    // in the vault, with no download.
    const st = prev.extract && prev.extract.state;
    if ((st === 'no-text-layer' || st === 'failed') && cfg.OCR_ENABLED &&
        !(prev.extract && prev.extract.ocrAttempted)) {
      return await reextractInPlace(prev, vaultCourse, manifest, report);
    }
    return 'unchanged';
  }

  if (!meta.url) {
    report.skipped.push({ item: meta.display_name, why: 'canvas gave no download url' });
    return 'skipped';
  }
  if (meta.size && meta.size > cfg.CANVAS_MAX_FILE_BYTES) {
    report.skipped.push({ item: meta.display_name, why: 'larger than the ' +
      Math.round(cfg.CANVAS_MAX_FILE_BYTES / 1048576) + 'MB cap' });
    return 'skipped';
  }

  // Download to a pure-ASCII scratch path. Canvas display names are full of em
  // dashes and smart quotes, and those must not cross the Node->Python boundary.
  const ext = extract.extFor(meta.filename || meta.display_name || '');
  const scratchAbs = path.join(extract.scratchDir(), 'canvas-' + ref.fileId + (ext ? '.' + ext : ''));
  let bytes;
  try {
    bytes = await canvas.downloadTo(meta.url, scratchAbs);
  } catch (e) {
    if (e.code === 'CANVAS_AUTH') throw e;
    report.failed.push({ item: meta.display_name, why: 'download failed: ' + e.message });
    return 'skipped';
  }

  let text = null, extractInfo = { state: 'unsupported', chars: 0, error: null };
  if (extract.canExtract(meta.filename || meta.display_name)) {
    const r = await extract.toText(scratchAbs, ext, 'canvas-' + ref.fileId);
    if (r.ok) {
      text = r.text;
      extractInfo = { state: 'ok', chars: r.chars, pages: r.pages, method: r.method, error: null };
    } else {
      extractInfo = { state: r.empty ? 'no-text-layer' : 'failed', chars: 0, error: r.error,
                      method: r.method || null, ocrAttempted: cfg.OCR_ENABLED };
      // Visible, not swallowed: an image-only scan is a real gap in what the
      // pipeline knows, and the index page says so.
      report.failed.push({ item: meta.display_name, why: r.error });
    }
  }

  // Node alone renames into the vault, so the pretty name never crosses to Python.
  fs.mkdirSync(path.dirname(destAbs), { recursive: true });
  fs.copyFileSync(scratchAbs, destAbs);
  try { fs.unlinkSync(scratchAbs); } catch (_) {}

  let textRel = null;
  if (text) {
    const textAbs = destAbs + '.txt';
    fs.writeFileSync(textAbs, text, 'utf8');
    textRel = rel(textAbs);
  }

  manifest.files[ref.fileId] = {
    id: ref.fileId,
    name: meta.display_name || name,
    updatedAt: meta.updated_at || null,
    size: meta.size || bytes,
    contentType: meta['content-type'] || meta.content_type || null,
    module: ref.module || '_Files',
    moduleId: ref.moduleId || null,
    itemTitle: ref.itemTitle || null,
    via: ref.via,
    alsoIn: (ref.alsoIn && ref.alsoIn.length) ? ref.alsoIn : undefined,
    path: rel(destAbs),
    textPath: textRel,
    extract: extractInfo,
    syncedAt: nowIso(),
  };
  return prev ? 'updated' : 'new';
}

/**
 * Re-run extraction on a file already sitting in the vault. Same ASCII-scratch
 * discipline as the download path: the pretty name never crosses to Python.
 */
async function reextractInPlace(prev, vaultCourse, manifest, report) {
  const srcAbs = path.join(cfg.VAULT, prev.path.split('/').join(path.sep));
  const ext = extract.extFor(prev.name || prev.path);
  const scratchAbs = path.join(extract.scratchDir(), 'canvas-' + prev.id + (ext ? '.' + ext : ''));
  try {
    fs.copyFileSync(srcAbs, scratchAbs);
  } catch (e) {
    report.failed.push({ item: prev.name, why: 're-extract could not stage the file: ' + e.message });
    return 'unchanged';
  }

  log.info('re-extracting', prev.name, '- previously', (prev.extract || {}).state);
  const r = await extract.toText(scratchAbs, ext, 'canvas-' + prev.id);
  try { fs.unlinkSync(scratchAbs); } catch (_) {}

  if (!r.ok) {
    // Mark it tried, so a genuinely unreadable document is not re-OCR'd every sync.
    prev.extract = { state: r.empty ? 'no-text-layer' : 'failed', chars: 0,
                     error: r.error, method: r.method || null, ocrAttempted: true };
    report.failed.push({ item: prev.name, why: r.error });
    return 'unchanged';
  }

  const textAbs = srcAbs + '.txt';
  fs.writeFileSync(textAbs, r.text, 'utf8');
  prev.textPath = rel(textAbs);
  prev.extract = { state: 'ok', chars: r.chars, pages: r.pages, method: r.method,
                   error: null, ocrAttempted: true };
  prev.syncedAt = nowIso();
  log.info('re-extracted', prev.name, 'via', r.method, '-', r.chars, 'chars');
  return 'updated';
}

// ------------------------------------------------------------- index page
function writeCourseIndex(vaultCourse, manifest) {
  const out = [];
  out.push('---');
  out.push('course: ' + JSON.stringify(vaultCourse));
  out.push('canvas_course_id: ' + JSON.stringify(String(manifest.canvasCourseId)));
  out.push('synced_at: ' + manifest.syncedAt);
  out.push('---');
  out.push('');
  out.push('# ' + vaultCourse + SEP + 'Course Materials');
  out.push('');
  out.push('*' + [manifest.canvasName, manifest.courseCode, manifest.term]
    .filter(Boolean).join(' · ') + '*');
  out.push('');

  const byModule = new Map();
  for (const f of Object.values(manifest.files)) {
    if (!byModule.has(f.module)) byModule.set(f.module, []);
    byModule.get(f.module).push(f);
  }
  const order = (manifest.modules || []).map(m => m.folder);
  const names = Array.from(byModule.keys())
    .sort((a, b) => {
      const ia = order.indexOf(a), ib = order.indexOf(b);
      if (ia !== ib) return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
      return a.localeCompare(b);
    });

  for (const modName of names) {
    out.push('## ' + modName);
    out.push('');
    for (const f of byModule.get(modName).sort((a, b) => a.name.localeCompare(b.name))) {
      const link = './' + mdPath(f.module + '/' + path.posix.basename(f.path));
      const bits = [];
      if (f.size) bits.push(Math.max(1, Math.round(f.size / 1024)) + ' KB');
      if (f.extract && f.extract.state === 'ok') {
        bits.push(f.extract.chars.toLocaleString('en-US') + ' chars of text' +
          (f.extract.method === 'ocr' ? ' **(OCR — may contain recognition errors)**' : ''));
      }
      else if (f.extract && f.extract.state === 'no-text-layer') bits.push('**no text layer — scanned image**');
      else if (f.extract && f.extract.state === 'failed') bits.push('**text extraction failed**');
      else bits.push('not text-extractable');
      if (f.alsoIn && f.alsoIn.length) bits.push('also in ' + f.alsoIn.join(', '));
      out.push('- [' + f.name + '](' + link + ') — ' + bits.join(', '));
    }
    out.push('');
  }

  if ((manifest.links || []).length) {
    out.push('## External links');
    out.push('');
    for (const l of manifest.links) out.push('- [' + l.title + '](' + l.url + ') — ' + l.module);
    out.push('');
  }

  const problems = (manifest.lastRun && manifest.lastRun.failed) || [];
  if (problems.length) {
    out.push('## Not captured');
    out.push('');
    out.push('These exist in Canvas but produced no usable text. Listed so a gap in what');
    out.push('the pipeline knows is visible rather than silent.');
    out.push('');
    for (const p of problems) out.push('- ' + p.item + ' — ' + p.why);
    out.push('');
  }

  const abs = path.join(courseDir(vaultCourse), '_Index.md');
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, out.join('\n'), 'utf8');
  return rel(abs);
}

// ------------------------------------------------------------------- sync
function progress(payload) {
  sse.broadcast('canvas', Object.assign({ syncing: true }, payload));
}

async function syncCourse(course, opts) {
  const courseId = String(course.id);
  const resolved = resolveVaultCourse(course);
  const vaultCourse = resolved.name;
  const report = {
    course: vaultCourse, canvasCourseId: courseId, matchedBy: resolved.matchedBy,
    suggested: resolved.suggested || null,
    counts: { new: 0, updated: 0, unchanged: 0, skipped: 0 },
    skipped: [], failed: [], errors: {}, superseded: [], full: !!opts.full,
  };

  const manifest = readManifest(vaultCourse) || { version: 1, files: {} };
  manifest.version = 1;
  manifest.canvasCourseId = courseId;
  manifest.canvasName = course.name || null;
  manifest.courseCode = course.course_code || null;
  manifest.term = (course.term && course.term.name) || null;
  manifest.vaultCourse = vaultCourse;
  manifest.files = manifest.files || {};

  progress({ phase: 'listing', course: vaultCourse });
  const { refs, links, modules } = await collectRefs(courseId, report);
  manifest.modules = modules;
  manifest.links = links;

  // Resolve re-uploads to one file per path before downloading anything.
  const plan = await planRefs(courseId, refs, vaultCourse, manifest, report);
  if (report.superseded.length) {
    log.info('canvas:', vaultCourse, '-', report.superseded.length,
      'superseded revision(s) dropped:',
      report.superseded.map(r => r.name + ' #' + r.droppedId).join(', '));
  }

  let done = 0;
  for (const ref of plan) {
    progress({ phase: 'files', course: vaultCourse, done, total: plan.length, item: ref.itemTitle });
    const outcome = await syncFile(courseId, ref, vaultCourse, manifest, report);
    report.counts[outcome] = (report.counts[outcome] || 0) + 1;
    done++;
  }

  // The syllabus is small, current, and densely full of the course's vocabulary.
  if (course.syllabus_body) {
    // Same rule as every other document: Python only ever sees an ASCII scratch
    // path. A course name can carry an accent or a dash just as a filename can.
    const scratchAbs = path.join(extract.scratchDir(), 'syllabus-' + courseId + '.html');
    fs.writeFileSync(scratchAbs, course.syllabus_body, 'utf8');
    const r = await extract.toText(scratchAbs, 'html', 'syllabus-' + courseId);
    const abs = path.join(courseDir(vaultCourse), 'Syllabus.html');
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.copyFileSync(scratchAbs, abs);
    try { fs.unlinkSync(scratchAbs); } catch (_) {}
    if (r.ok) fs.writeFileSync(path.join(courseDir(vaultCourse), 'Syllabus.txt'), r.text, 'utf8');
    manifest.syllabus = { path: rel(abs), chars: r.ok ? r.chars : 0 };
  }

  manifest.syncedAt = nowIso();
  manifest.lastRun = { at: manifest.syncedAt, counts: report.counts,
                       failed: report.failed, skipped: report.skipped,
                       superseded: report.superseded, errors: report.errors };
  writeManifest(vaultCourse, manifest);
  report.indexPath = writeCourseIndex(vaultCourse, manifest);

  // Record the Canvas link on the vault course so the next sync is unambiguous.
  store.setCourseCanvas(vaultCourse, {
    id: courseId, name: course.name || null, code: course.course_code || null,
    term: (course.term && course.term.name) || null, syncedAt: manifest.syncedAt,
  });

  // Seed whisper's vocabulary from the material itself. Only worth a Claude call
  // when something actually changed - and only from the small, current documents:
  // a 1,100-page textbook is the wrong sample for "what will they say out loud".
  if (report.counts.new || report.counts.updated || o_force(opts)) {
    const samples = glossarySamples(vaultCourse, manifest);
    if (samples.length > 500) {
      pipeline.enqueue({ type: 'glossary', id: 'glossary:' + vaultCourse,
                         course: vaultCourse, samples });
      report.glossaryQueued = true;
    }
  }

  const asg = await syncAssignments(course, vaultCourse, report);
  report.assignments = asg.imported;
  report.upcoming = asg.upcoming;

  report.fileCount = Object.keys(manifest.files).length;
  report.textChars = Object.values(manifest.files)
    .reduce((n, f) => n + ((f.extract && f.extract.chars) || 0), 0);
  return report;
}

/**
 * Canvas assignments are the real deadlines.
 *
 * Everything in the todo list used to come from what a lecturer happened to say out
 * loud, which catches what was emphasised and misses everything else. Canvas has the
 * actual list with actual timestamps; a spoken todo and a Canvas one now coexist,
 * distinguished by `kind`.
 */
async function syncAssignments(course, vaultCourse, report) {
  let rows = [];
  try {
    rows = await canvas.apiAll('/api/v1/courses/' + course.id +
      '/assignments?include[]=submission&order_by=due_at');
  } catch (e) {
    if (e.code === 'CANVAS_AUTH') throw e;
    report.errors.assignments = e.code || e.message;
    return { imported: 0, upcoming: 0 };
  }

  // Anything still outstanding is kept however old it is - a missed assignment is
  // exactly what you want to see. Finished work ages out after three weeks.
  const cutoff = Date.now() - 21 * 86400000;
  const items = [];
  let upcoming = 0;

  for (const a of rows) {
    const sub = a.submission || {};
    const submitted = !!sub.submitted_at ||
      sub.workflow_state === 'submitted' || sub.workflow_state === 'graded';
    const dueMs = a.due_at ? new Date(a.due_at).getTime() : null;
    if (submitted && (!dueMs || dueMs < cutoff)) continue;
    if (submitted && dueMs && dueMs < cutoff) continue;

    if (dueMs && dueMs >= Date.now()) upcoming++;
    items.push({
      kind: 'assignment',
      text: asString(a.name, 'Untitled assignment').trim(),
      due: a.due_at ? localDate(a.due_at, cfg.TZ) : null,
      dueAt: a.due_at || null,
      course: vaultCourse,
      url: a.html_url || null,
      points: typeof a.points_possible === 'number' ? a.points_possible : null,
      submitted,
      graded: sub.workflow_state === 'graded',
      canvasId: a.id,
      done: submitted,
    });
  }

  store.replaceTodosForSource('canvas:' + course.id, items);
  return { imported: items.length, upcoming };
}

function o_force(opts) { return !!(opts && opts.reglossary); }

/**
 * The text to hand the glossary pass. Syllabus first, then the newest small
 * documents. Big references are deliberately excluded: they blow the prompt and
 * are full of vocabulary the lecturer will never actually say.
 */
const GLOSSARY_SAMPLE_MAX = 60000;
const GLOSSARY_DOC_MAX = 40000;
const GLOSSARY_BIG_HEAD = 15000;

function glossarySamples(vaultCourse, manifest) {
  const parts = [];
  let budget = GLOSSARY_SAMPLE_MAX;

  const syllabusTxt = path.join(courseDir(vaultCourse), 'Syllabus.txt');
  try {
    const t = fs.readFileSync(syllabusTxt, 'utf8').slice(0, GLOSSARY_DOC_MAX);
    if (t.trim()) { parts.push('--- syllabus ---\n' + t); budget -= t.length; }
  } catch (_) {}

  const extracted = Object.values(manifest.files)
    .filter(f => f.textPath && f.extract && f.extract.state === 'ok')
    .sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')));

  // Small, current documents first - slides and handouts are what the lecturer is
  // actually about to talk about.
  const small = extracted.filter(f => f.extract.chars <= GLOSSARY_DOC_MAX);
  // ...but a course whose only materials are a textbook must still get a glossary.
  // The front of a big reference is its table of contents and chapter titles, which
  // is exactly the dense list of terms we want, so take a head slice rather than
  // skipping the document entirely.
  const large = extracted.filter(f => f.extract.chars > GLOSSARY_DOC_MAX);

  for (const [group, cap] of [[small, GLOSSARY_DOC_MAX], [large, GLOSSARY_BIG_HEAD]]) {
    for (const f of group) {
      if (budget <= 1000) break;
      try {
        const t = fs.readFileSync(path.join(cfg.VAULT, f.textPath.split('/').join(path.sep)), 'utf8');
        const slice = t.slice(0, Math.min(budget, cap));
        // Say when text came from OCR: the glossary prompt should discount garbled
        // tokens rather than learn them as vocabulary.
        const label = (f.extract && f.extract.method === 'ocr')
          ? f.name + ' (OCR, may contain recognition errors)' : f.name;
        parts.push('--- ' + label + ' ---\n' + slice);
        budget -= slice.length;
      } catch (_) {}
    }
  }
  return parts.join('\n\n');
}

function isCurrent(course) {
  if (course.access_restricted_by_date) return false;
  if (course.workflow_state && course.workflow_state !== 'available') return false;
  const end = (course.term && course.term.end_at) || course.end_at;
  if (end && new Date(end).getTime() < Date.now() - 7 * 86400000) return false;
  return true;
}

async function sync(opts) {
  const o = opts || {};
  if (running) return running;
  running = (async () => {
    const t0 = Date.now();
    const out = { startedAt: nowIso(), courses: [], errors: [] };
    try {
      const all = await canvas.apiAll(
        '/api/v1/courses?enrollment_state=active&state[]=available' +
        '&include[]=term&include[]=syllabus_body');
      const courses = all.filter(c => (o.full ? true : isCurrent(c)))
        .filter(c => !o.courseIds || o.courseIds.includes(String(c.id)));
      out.considered = all.length;
      log.info('canvas sync:', courses.length, 'of', all.length, 'courses in scope');

      for (const c of courses) {
        try {
          out.courses.push(await syncCourse(c, o));
        } catch (e) {
          if (e.code === 'CANVAS_AUTH') throw e;
          log.error('canvas sync failed for', c.name, '-', e.message);
          out.errors.push({ course: c.name, error: e.message });
        }
      }
      out.ok = true;
    } catch (e) {
      out.ok = false;
      out.error = e.message;
      out.needsReconnect = e.code === 'CANVAS_AUTH' || e.code === 'NO_SESSION';
      log.error('canvas sync aborted -', e.message);
    }
    out.durationSec = Math.round((Date.now() - t0) / 1000);
    out.finishedAt = nowIso();
    lastResult = out;
    store.save(true);
    // The todo list just changed shape; push it rather than waiting for a refresh.
    try { require('./pipeline').emitTodos(); } catch (_) {}
    sse.broadcast('canvas', Object.assign({ syncing: false }, canvas.status(), { lastSync: summarise(out) }));
    log.info('canvas sync done in', out.durationSec + 's', '|',
      out.courses.map(c => c.course + ':' + c.fileCount + 'f/' + (c.assignments || 0) + 'a')
        .join(', ') || '(nothing)');
    return out;
  })().finally(() => { running = null; });
  return running;
}

function summarise(r) {
  if (!r) return null;
  return {
    ok: r.ok, at: r.finishedAt, durationSec: r.durationSec,
    error: r.error || null, needsReconnect: !!r.needsReconnect,
    // Per-course failures were being captured and then dropped here, so a course
    // that failed every single sync simply did not appear anywhere. Absent is not
    // the same as fine.
    failedCourses: (r.errors || []).map(e => ({ course: e.course, error: e.error })),
    courses: (r.courses || []).map(c => ({
      course: c.course, files: c.fileCount, textChars: c.textChars,
      counts: c.counts, matchedBy: c.matchedBy, suggested: c.suggested,
      assignments: c.assignments || 0, upcoming: c.upcoming || 0,
      problems: (c.failed || []).length,
      superseded: (c.superseded || []).length,
    })),
  };
}

function isSyncing() { return !!running; }
function last() { return summarise(lastResult); }

/** Everything we hold for one course, for the API and the note pass. */
function forCourse(vaultCourse) {
  const m = readManifest(vaultCourse);
  if (!m) return null;
  return m;
}

module.exports = {
  sync, isSyncing, last, summarise, forCourse, readManifest, courseDir, glossarySamples,
  resolveVaultCourse, matchScore, scrapeFileIds, safeFileName, moduleFolder,
};
