'use strict';
// Server-Sent Events fan-out. Many concurrent clients; each is dropped as soon as
// its socket closes or errors so a dead Mac never wedges the queue.
const cfg = require('./config');
const log = require('./log');

const clients = new Set();
let seq = 0;

function attach(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  // Ask the client to back off 3s between reconnects.
  res.write('retry: 3000\n\n');
  res.write(': connected\n\n');

  const client = { id: ++seq, res, timer: null };
  client.timer = setInterval(() => {
    try { res.write(': keepalive\n\n'); } catch (e) { drop(client); }
  }, cfg.KEEPALIVE_MS);
  if (client.timer.unref) client.timer.unref();

  clients.add(client);
  log.info('sse client connected', '#' + client.id, 'total=' + clients.size);

  const bye = () => drop(client);
  req.on('close', bye);
  req.on('aborted', bye);
  req.on('error', bye);
  res.on('close', bye);
  res.on('error', bye);
  if (req.socket) {
    req.socket.setTimeout(0);
    req.socket.setNoDelay(true);
    req.socket.setKeepAlive(true, 30000);
  }
  return client;
}

function drop(client) {
  if (!clients.has(client)) return;
  clients.delete(client);
  if (client.timer) clearInterval(client.timer);
  try { client.res.end(); } catch (_) {}
  log.info('sse client disconnected', '#' + client.id, 'total=' + clients.size);
}

/** Broadcast one SSE event to every connected client. */
function broadcast(event, data) {
  if (!clients.size) return;
  let payload;
  try { payload = JSON.stringify(data); } catch (_) { return; }
  // Guard against embedded newlines breaking the frame (JSON.stringify escapes them,
  // but be explicit anyway).
  const frame = 'event: ' + event + '\ndata: ' + payload.replace(/\n/g, ' ') + '\n\n';
  for (const c of Array.from(clients)) {
    try { c.res.write(frame); } catch (e) { drop(c); }
  }
}

function count() { return clients.size; }

module.exports = { attach, broadcast, count, drop };
