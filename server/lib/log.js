'use strict';
const fs = require('fs');
const path = require('path');
const cfg = require('./config');

let ready = false;
function ensure() {
  if (ready) return;
  try { fs.mkdirSync(cfg.DIRS.logs, { recursive: true }); ready = true; } catch (_) {}
}

function rotateIfBig() {
  try {
    const st = fs.statSync(cfg.LOG_FILE);
    if (st.size > cfg.LOG_MAX_BYTES) {
      const old = cfg.LOG_FILE + '.1';
      try { fs.unlinkSync(old); } catch (_) {}
      fs.renameSync(cfg.LOG_FILE, old);
    }
  } catch (_) { /* no log file yet */ }
}

function write(level, args) {
  const line = '[' + new Date().toISOString() + '] ' + level + ' ' +
    args.map(a => (typeof a === 'string' ? a : safe(a))).join(' ');
  // stdout so the scheduled-task launcher's redirect also captures it
  process.stdout.write(line + '\n');
  ensure();
  try { rotateIfBig(); fs.appendFileSync(cfg.LOG_FILE, line + '\r\n'); } catch (_) {}
}

function safe(o) {
  try { return JSON.stringify(o); } catch (_) { return String(o); }
}

module.exports = {
  info: (...a) => write('INFO ', a),
  warn: (...a) => write('WARN ', a),
  error: (...a) => write('ERROR', a),
  debug: (...a) => { if (process.env.NOTABLES_DEBUG) write('DEBUG', a); },
};
