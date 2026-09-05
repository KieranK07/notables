'use strict';
const crypto = require('crypto');

// ---------------------------------------------------------------- filenames
// Characters Windows forbids in a path component, plus control chars.
const ILLEGAL = /[<>:"/\\|?*\x00-\x1f]/g;
const RESERVED = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;

/** Make an arbitrary string safe as a single Windows path component. */
function sanitizeName(input, fallback = 'Untitled') {
  let s = String(input == null ? '' : input);
  s = s.replace(ILLEGAL, ' ');
  s = s.replace(/\s+/g, ' ').trim();
  // Windows silently strips trailing dots and spaces; strip them ourselves so the
  // name we record matches the name on disk.
  s = s.replace(/[. ]+$/g, '').trim();
  if (s.length > 90) s = s.slice(0, 90).replace(/[. ]+$/g, '').trim();
  if (!s) return fallback;
  if (RESERVED.test(s)) s = s + '_';
  return s;
}

// ---------------------------------------------------------------- dates
/** YYYY-MM-DD for an instant, in the given IANA zone. */
function localDate(iso, tz) {
  const d = iso ? new Date(iso) : new Date();
  const dt = isNaN(d.getTime()) ? new Date() : d;
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(dt);
}

function isDateString(s) { return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s); }
function nowIso() { return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'); }

/** Normalise whatever the client sent into a clean ISO-8601 UTC string. */
function normIso(v, fallback) {
  if (typeof v === 'string') {
    const d = new Date(v);
    if (!isNaN(d.getTime())) return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
  }
  return fallback === undefined ? nowIso() : fallback;
}

// ---------------------------------------------------------------- yaml
const NEEDS_QUOTE = /^$|^[-?:,[\]{}#&*!|>'"%@`]|[:#]\s|\s$|^\s|^(true|false|null|yes|no|on|off|~)$|^[\d.+-]+$/i;

/** Emit a YAML scalar, quoting only when the plain form would be ambiguous. */
function yamlScalar(v) {
  if (v === null || v === undefined) return 'null';
  const s = String(v);
  if (NEEDS_QUOTE.test(s) || s.includes('\n')) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ') + '"';
  }
  return s;
}
function yamlList(arr) {
  if (!Array.isArray(arr) || !arr.length) return '[]';
  return '[' + arr.map(yamlScalar).join(', ') + ']';
}

// ---------------------------------------------------------------- misc
function sha1(s) { return crypto.createHash('sha1').update(String(s), 'utf8').digest('hex'); }
function shortId(s) { return sha1(s).slice(0, 16); }

/** Percent-encode a path for use inside a markdown link target. */
function mdPath(p) {
  return p.split('/').map(seg => encodeURIComponent(seg)).join('/');
}

function asArray(v) { return Array.isArray(v) ? v : []; }
function asString(v, fallback = '') {
  if (typeof v === 'string') return v;
  if (v === null || v === undefined) return fallback;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return fallback;
}

/** kebab-case, lowercase, stripped of anything weird. Used for tags. */
function slugTag(s) {
  return asString(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}

module.exports = {
  sanitizeName, localDate, isDateString, nowIso, normIso,
  yamlScalar, yamlList, sha1, shortId, mdPath, asArray, asString, slugTag,
};
