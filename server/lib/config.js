'use strict';
// Central configuration. Everything is overridable by environment variable so the
// server can be run from a different vault for testing without touching the real one.
const path = require('path');
const os = require('os');

const HOME = process.env.USERPROFILE || os.homedir();

const config = {
  VERSION: '1.0.0',
  HOME,
  VAULT: process.env.NOTABLES_VAULT || path.join(HOME, 'Notables'),
  PORT: parseInt(process.env.NOTABLES_PORT || '8787', 10),
  HOST: process.env.NOTABLES_HOST || '0.0.0.0',
  TOKEN_FILE: process.env.NOTABLES_TOKEN_FILE || path.join(HOME, '.notables', 'token'),
  CLAUDE_BIN: process.env.NOTABLES_CLAUDE_BIN ||
    path.join(HOME, 'AppData', 'Local', 'Microsoft', 'WinGet', 'Links', 'claude.exe'),
  // Model used for the note pass. Sonnet is fast and more than good enough for
  // extraction; set NOTABLES_MODEL=opus for a heavier pass.
  MODEL: process.env.NOTABLES_MODEL || 'sonnet',
  // Kieran is US Central. classDate defaults to the recording's date in this zone.
  TZ: process.env.NOTABLES_TZ || 'America/Chicago',
  CLAUDE_TIMEOUT_MS: parseInt(process.env.NOTABLES_CLAUDE_TIMEOUT_MS || String(15 * 60 * 1000), 10),
  MAX_BODY_BYTES: parseInt(process.env.NOTABLES_MAX_BODY || String(64 * 1024 * 1024), 10),
  MAX_AUDIO_BYTES: parseInt(process.env.NOTABLES_MAX_AUDIO || String(4 * 1024 * 1024 * 1024), 10),

  // --- whisper (faster-whisper large-v3 on the RTX 3060 Ti) -----------------
  // The venv is deliberately OUTSIDE the vault. The `python` on PATH is a broken
  // uv shim, so this points at the venv interpreter explicitly.
  PYTHON: process.env.NOTABLES_PYTHON || path.join(HOME, '.notables-venv', 'Scripts', 'python.exe'),
  TRANSCRIBE_PY: process.env.NOTABLES_TRANSCRIBE_PY || path.join(__dirname, '..', 'python', 'transcribe.py'),
  EXTRACT_PY: process.env.NOTABLES_EXTRACT_PY || path.join(__dirname, '..', 'python', 'extract.py'),
  EXTRACT_TIMEOUT_MS: parseInt(process.env.NOTABLES_EXTRACT_TIMEOUT_MS || String(20 * 60 * 1000), 10),
  // OCR fallback for scanned PDFs (pypdfium2 + rapidocr-onnxruntime, CPU, ~7s/page).
  // Only ever runs when a PDF has no usable text layer, and is page-capped so one
  // 200-page scan cannot stall a sync.
  OCR_ENABLED: process.env.NOTABLES_OCR !== '0',
  OCR_MAX_PAGES: parseInt(process.env.NOTABLES_OCR_MAX_PAGES || '40', 10),
  OCR_DPI: parseInt(process.env.NOTABLES_OCR_DPI || '200', 10),
  WHISPER_MODEL: process.env.NOTABLES_WHISPER_MODEL || 'large-v3',
  WHISPER_DEVICE: process.env.NOTABLES_WHISPER_DEVICE || 'cuda',
  WHISPER_COMPUTE: process.env.NOTABLES_WHISPER_COMPUTE || 'float16',
  WHISPER_MODEL_DIR: process.env.NOTABLES_WHISPER_MODEL_DIR || path.join(HOME, '.notables-models'),
  WHISPER_BEAM: parseInt(process.env.NOTABLES_WHISPER_BEAM || '5', 10),
  WHISPER_TIMEOUT_MS: parseInt(process.env.NOTABLES_WHISPER_TIMEOUT_MS || String(4 * 60 * 60 * 1000), 10),
  // whisper truncates initial_prompt to its last 224 tokens; stay under that.
  GLOSSARY_PROMPT_CHARS: parseInt(process.env.NOTABLES_GLOSSARY_CHARS || '700', 10),
  GLOSSARY_MAX_TERMS: parseInt(process.env.NOTABLES_GLOSSARY_MAX || '80', 10),
  // --- Canvas LMS ---------------------------------------------------------
  // Franciscan has student-generated access tokens DISABLED and logs in through
  // Microsoft SAML SSO, so the only credential we can hold is a session cookie the
  // user establishes by hand in a real browser view. It expires; that must be loud.
  CANVAS_HOST: process.env.NOTABLES_CANVAS_HOST || 'franciscan.instructure.com',
  CANVAS_SESSION_FILE: process.env.NOTABLES_CANVAS_SESSION ||
    path.join(HOME, '.notables', 'canvas-session.json'),
  CANVAS_TIMEOUT_MS: parseInt(process.env.NOTABLES_CANVAS_TIMEOUT_MS || String(60 * 1000), 10),
  // Canvas allows ~700 "cost units" per user; a GET is cheap but a tight loop is not.
  CANVAS_MIN_GAP_MS: parseInt(process.env.NOTABLES_CANVAS_GAP_MS || '120', 10),
  CANVAS_MAX_FILE_BYTES: parseInt(process.env.NOTABLES_CANVAS_MAX_FILE || String(200 * 1024 * 1024), 10),
  CANVAS_SYNC_INTERVAL_MS: parseInt(process.env.NOTABLES_CANVAS_SYNC_MS || String(6 * 60 * 60 * 1000), 10),

  KEEPALIVE_MS: 20000,
  LOG_MAX_BYTES: 5 * 1024 * 1024,
};

config.DIRS = {
  notes:       path.join(config.VAULT, 'Notes'),
  transcripts: path.join(config.VAULT, 'Transcripts'),
  audio:       path.join(config.VAULT, 'Audio'),
  unsorted:    path.join(config.VAULT, 'Transcripts', '_Unsorted'),
  captures:    path.join(config.VAULT, 'Captures'),
  inbox:       path.join(config.VAULT, 'inbox'),
  materials:   path.join(config.VAULT, 'Course Materials'),
  logs:        path.join(config.VAULT, 'logs'),
};
config.INDEX_FILE   = path.join(config.VAULT, '_index.json');
config.COURSES_FILE = path.join(config.VAULT, '_courses.json');
config.LOG_FILE     = path.join(config.DIRS.logs, 'server.log');

module.exports = config;
