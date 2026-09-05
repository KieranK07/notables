'use strict';
// Canvas LMS client. Node stdlib only.
//
// AUTH: session cookie, not an access token. Franciscan has student-generated
// tokens disabled (Account -> Settings has no "+ New Access Token") and logs in
// through Microsoft SAML SSO, so no password or token flow is available to us.
// Canvas's own web UI drives /api/v1 with the session cookie, and it accepts that
// cookie for GETs from anywhere - so the user signs in by hand in a real browser
// view and we keep only the resulting cookie.
//
// That cookie is a full-account credential and it EXPIRES. Two rules follow:
//   1. it is never logged, never written into the vault, and never sent anywhere
//      except https://<CANVAS_HOST>/;
//   2. when it dies, that is loud. A dead session must never look like "no new
//      materials" - this project has already been bitten once by a silent
//      degradation (see the whisper draft fallback in CLAUDE.md).
const https = require('https');
const fs = require('fs');
const path = require('path');
const cfg = require('./config');
const log = require('./log');
const { nowIso } = require('./util');

let session = null;          // { host, cookie, user, savedAt }
let loaded = false;
const health = {
  connected: false,
  host: cfg.CANVAS_HOST,
  user: null,
  checkedAt: null,
  error: null,
  expiredAt: null,           // set the moment Canvas answers 401
};

// --------------------------------------------------------------- session io
function loadSession() {
  if (loaded) return session;
  loaded = true;
  try {
    const raw = fs.readFileSync(cfg.CANVAS_SESSION_FILE, 'utf8').replace(/^﻿/, '');
    const j = JSON.parse(raw);
    if (j && j.cookie && j.host) {
      session = { host: j.host, cookie: j.cookie, user: j.user || null, savedAt: j.savedAt || null };
      health.host = j.host;
      health.user = j.user || null;
    }
  } catch (e) {
    if (e.code !== 'ENOENT') log.warn('canvas: unreadable session file -', e.message);
  }
  return session;
}

function saveSession(host, cookie, user) {
  session = { host, cookie, user: user || null, savedAt: nowIso() };
  loaded = true;
  const dir = path.dirname(cfg.CANVAS_SESSION_FILE);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = cfg.CANVAS_SESSION_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(session, null, 2), { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(tmp, cfg.CANVAS_SESSION_FILE);
  try { fs.chmodSync(cfg.CANVAS_SESSION_FILE, 0o600); } catch (_) {}
  health.host = host;
  health.user = user || null;
  health.expiredAt = null;
  health.error = null;
  // Deliberately logs the host and user, never the cookie or its length.
  log.info('canvas: session stored for', host, '| user:', (user && user.name) || '(unknown)');
  return session;
}

function clearSession() {
  session = null;
  loaded = true;
  try { fs.unlinkSync(cfg.CANVAS_SESSION_FILE); } catch (_) {}
  health.connected = false;
  health.user = null;
  log.warn('canvas: session cleared');
}

function hasSession() { return !!loadSession(); }

function markExpired(why) {
  if (!health.expiredAt) log.warn('canvas: session rejected by Canvas -', why);
  health.connected = false;
  health.expiredAt = health.expiredAt || nowIso();
  health.error = why;
  health.checkedAt = nowIso();
}

function status() {
  loadSession();
  return {
    connected: health.connected,
    hasSession: !!session,
    host: health.host,
    user: health.user,
    savedAt: session ? session.savedAt : null,
    checkedAt: health.checkedAt,
    expiredAt: health.expiredAt,
    error: health.error,
  };
}

// ------------------------------------------------------------------ request
let lastCall = 0;
function gap() {
  const wait = Math.max(0, cfg.CANVAS_MIN_GAP_MS - (Date.now() - lastCall));
  lastCall = Date.now() + wait;
  return wait ? new Promise(r => setTimeout(r, wait)) : Promise.resolve();
}

/**
 * One HTTPS GET. `opts.authenticated=false` sends NO cookie - used for the signed
 * S3/instfs URLs Canvas redirects file downloads to, which must never see the
 * session. Resolves { status, headers, body:Buffer }.
 */
function rawGet(urlStr, opts) {
  const o = opts || {};
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(urlStr); } catch (e) { return reject(new Error('bad canvas url: ' + urlStr)); }
    if (u.protocol !== 'https:') return reject(new Error('refusing non-https canvas url'));

    const headers = {
      'Accept': o.accept || 'application/json+canvas-string-ids, application/json',
      'User-Agent': 'Notables/' + cfg.VERSION + ' (personal note pipeline)',
      'Accept-Encoding': 'identity',
    };
    if (o.authenticated !== false) {
      const s = loadSession();
      if (!s) return reject(Object.assign(new Error('canvas is not connected'), { code: 'NO_SESSION' }));
      if (u.hostname !== s.host) {
        return reject(new Error('refusing to send the canvas cookie to ' + u.hostname));
      }
      headers['Cookie'] = s.cookie;
    }

    const req = https.request({
      hostname: u.hostname, port: 443, path: u.pathname + u.search, method: 'GET', headers,
    }, res => {
      const chunks = [];
      let bytes = 0;
      res.on('data', c => {
        bytes += c.length;
        if (bytes > cfg.CANVAS_MAX_FILE_BYTES) {
          req.destroy(new Error('canvas response exceeded ' + cfg.CANVAS_MAX_FILE_BYTES + ' bytes'));
          return;
        }
        chunks.push(c);
      });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.setTimeout(o.timeoutMs || cfg.CANVAS_TIMEOUT_MS, () => {
      req.destroy(new Error('canvas request timed out after ' +
        Math.round((o.timeoutMs || cfg.CANVAS_TIMEOUT_MS) / 1000) + 's'));
    });
    req.end();
  });
}

/** Follow redirects, dropping the cookie the moment we leave the Canvas host. */
async function getFollowing(urlStr, opts) {
  let url = urlStr;
  let authenticated = !(opts && opts.authenticated === false);
  for (let hop = 0; hop < 6; hop++) {
    const r = await rawGet(url, Object.assign({}, opts, { authenticated }));
    if (r.status >= 300 && r.status < 400 && r.headers.location) {
      const next = new URL(r.headers.location, url);
      // Canvas hands file downloads off to instfs/S3 with the credential in the
      // query string. Anything off-host gets no cookie.
      const s = loadSession();
      authenticated = authenticated && !!s && next.hostname === s.host;
      url = next.toString();
      continue;
    }
    return r;
  }
  throw new Error('too many redirects fetching a canvas resource');
}

function parseNextLink(linkHeader) {
  if (!linkHeader) return null;
  for (const part of String(linkHeader).split(',')) {
    const m = /^\s*<([^>]+)>\s*;\s*rel="?next"?/.exec(part);
    if (m) return m[1];
  }
  return null;
}

/**
 * GET an /api/v1 endpoint. `p` is a path like '/api/v1/courses?per_page=100'.
 * Throws with code CANVAS_AUTH on 401/403-unauthenticated so callers can surface
 * "reconnect Canvas" rather than treating it as an empty result.
 */
async function api(p, opts) {
  const s = loadSession();
  if (!s) throw Object.assign(new Error('canvas is not connected'), { code: 'NO_SESSION' });
  await gap();
  const url = 'https://' + s.host + (p.startsWith('/') ? p : '/' + p);
  const r = await getFollowing(url, opts);

  if (r.status === 401) {
    markExpired('401 from ' + p.split('?')[0]);
    throw Object.assign(new Error('canvas session has expired - reconnect required'), { code: 'CANVAS_AUTH' });
  }
  if (r.status === 403) {
    const text = r.body.toString('utf8').slice(0, 300);
    if (/rate limit/i.test(text)) {
      throw Object.assign(new Error('canvas rate limit hit'), { code: 'CANVAS_RATE' });
    }
    // A real 403 means "you may not see this", which for a student is normal on
    // e.g. a locked Files tab. Callers treat it as "skip", not as a failure.
    throw Object.assign(new Error('canvas forbade ' + p.split('?')[0]), { code: 'CANVAS_FORBIDDEN' });
  }
  if (r.status === 404) {
    throw Object.assign(new Error('canvas has no ' + p.split('?')[0]), { code: 'CANVAS_NOT_FOUND' });
  }
  if (r.status !== 200) {
    throw new Error('canvas returned ' + r.status + ' for ' + p.split('?')[0]);
  }

  // A login page served with 200 is how Canvas answers a dead cookie on some routes.
  const ct = String(r.headers['content-type'] || '');
  if (!/json/i.test(ct)) {
    markExpired('got ' + (ct.split(';')[0] || 'no content-type') + ' instead of JSON from ' + p.split('?')[0]);
    throw Object.assign(new Error('canvas session has expired - reconnect required'), { code: 'CANVAS_AUTH' });
  }

  let text = r.body.toString('utf8');
  // Canvas prefixes JSON responses with a JS-hijacking guard.
  if (text.startsWith('while(1);')) text = text.slice(9);
  health.connected = true;
  health.checkedAt = nowIso();
  health.expiredAt = null;
  try {
    return { data: JSON.parse(text), headers: r.headers };
  } catch (e) {
    throw new Error('canvas sent unparseable JSON for ' + p.split('?')[0]);
  }
}

/** Paginated GET: walks Link rel="next" and concatenates the arrays. */
async function apiAll(p, opts) {
  const out = [];
  let next = p.includes('per_page=') ? p : p + (p.includes('?') ? '&' : '?') + 'per_page=100';
  let pages = 0;
  while (next && pages < 50) {
    const r = await api(next, opts);
    if (Array.isArray(r.data)) out.push(...r.data);
    else out.push(r.data);
    pages++;
    const link = parseNextLink(r.headers.link);
    if (!link) break;
    const u = new URL(link);
    next = u.pathname + u.search;
    await gap();
  }
  return out;
}

/**
 * Download a Canvas file to disk. Takes the file's API metadata (which carries a
 * short-lived signed `url`) and streams it out, cookie-free once off-host.
 */
async function downloadTo(fileUrl, destAbs) {
  const r = await getFollowing(fileUrl, { accept: '*/*', authenticated: true });
  if (r.status !== 200) throw new Error('download failed with ' + r.status);
  fs.mkdirSync(path.dirname(destAbs), { recursive: true });
  const tmp = destAbs + '.part';
  fs.writeFileSync(tmp, r.body);
  fs.renameSync(tmp, destAbs);
  return r.body.length;
}

/** Confirm the cookie works and learn who it belongs to. */
async function verify() {
  const r = await api('/api/v1/users/self');
  const u = r.data || {};
  const user = { id: String(u.id || ''), name: u.name || u.short_name || null, login: u.login_id || null };
  health.connected = true;
  health.user = user;
  health.error = null;
  if (session) { session.user = user; saveSession(session.host, session.cookie, user); }
  return user;
}

module.exports = {
  loadSession, saveSession, clearSession, hasSession, status, health,
  api, apiAll, downloadTo, verify, markExpired, rawGet, getFollowing,
};
