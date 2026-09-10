#!/usr/bin/env node
'use strict';
// Notables MCP - the stdio transport, for Claude Code on any machine.
//
//   claude mcp add notables -s user -- node /path/to/notables-mcp.js
//
// This file is a BRIDGE and nothing else: it reads newline-delimited JSON-RPC from
// stdin, POSTs each message to the note server's MCP endpoint, and writes the reply to
// stdout. The tools, their schemas and their prose all live in one place -
// server/lib/mcp.js, on the PC - so the stdio path and the public HTTP path that
// claude.ai talks to cannot drift apart. Two copies of five tool descriptions would,
// and a drifted description is a tool the model calls wrongly.
//
// Zero npm dependencies, matching the rest of the project.
//
// Config:
//   NOTABLES_MCP_URL     full endpoint URL, overrides everything below
//   NOTABLES_MCP_HOST    default http://100.69.103.126:8788  (the PC over Tailscale)
//   NOTABLES_MCP_TOKEN   the secret; otherwise read from ~/.notables/mcp-token
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const DEFAULT_HOST = process.env.NOTABLES_MCP_HOST || 'http://100.69.103.126:8788';

function endpoint() {
  if (process.env.NOTABLES_MCP_URL) return process.env.NOTABLES_MCP_URL;
  let secret = process.env.NOTABLES_MCP_TOKEN;
  if (!secret) {
    const file = path.join(os.homedir(), '.notables', 'mcp-token');
    try { secret = fs.readFileSync(file, 'utf8').trim(); }
    catch (e) {
      throw new Error('no MCP secret: set NOTABLES_MCP_URL or NOTABLES_MCP_TOKEN, or put ' +
                      'the secret in ' + file);
    }
  }
  return DEFAULT_HOST.replace(/\/+$/, '') + '/mcp/' + secret.trim();
}

let URL_CACHE = null;

function post(message) {
  return new Promise((resolve, reject) => {
    if (!URL_CACHE) URL_CACHE = endpoint();
    const url = new URL(URL_CACHE);
    const mod = url.protocol === 'https:' ? https : http;
    const payload = Buffer.from(JSON.stringify(message));
    const req = mod.request(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream',
        'Content-Length': payload.length,
      },
      timeout: 300000,          // resync waits on a Canvas pull, about a minute
    }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode === 202 || !raw.trim()) return resolve(null);   // notification
        if (res.statusCode >= 400) {
          return reject(new Error('notables MCP endpoint: HTTP ' + res.statusCode + ' ' +
                                  raw.slice(0, 200)));
        }
        try { resolve(JSON.parse(raw)); }
        catch (e) { reject(new Error('the endpoint did not return JSON: ' + raw.slice(0, 200))); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timed out')));
    req.on('error', e => reject(new Error(
      'cannot reach the Notables MCP endpoint at ' + url.origin + ' - ' + e.message +
      '. Is the PC awake and on the tailnet?')));
    req.write(payload);
    req.end();
  });
}

function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }

let buffer = '';
let inFlight = 0;
let stdinClosed = false;

// Exit only once nothing is still being answered. A real client keeps stdin open for the
// life of the session, but anything that pipes a batch and closes - a test, a script -
// would otherwise die mid-await and return silence.
function exitWhenIdle() {
  if (stdinClosed && inFlight === 0) process.exit(0);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;

    let msg;
    try { msg = JSON.parse(line); }
    catch (e) {
      send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error: ' + e.message } });
      continue;
    }

    inFlight++;
    post(msg)
      .then(reply => { if (reply) send(reply); })
      .catch(e => {
        // Reaching the server is this process's whole job, so a failure is a transport
        // error, reported against the id that asked.
        if (msg && msg.id !== undefined && msg.id !== null) {
          send({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: e.message } });
        }
      })
      .finally(() => { inFlight--; exitWhenIdle(); });
  }
});
process.stdin.on('end', () => { stdinClosed = true; exitWhenIdle(); });
