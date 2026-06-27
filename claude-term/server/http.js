import http from 'node:http';
import { WebSocketServer } from 'ws';
import { COOKIE_NAME, parseCookie } from './auth.js';
import { loadSnippets } from './snippets.js';
import { serveStatic } from './static.js';
import path from 'node:path';

const PUBLIC = path.resolve('public');

function json(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
}
const MAX_BODY = 64 * 1024; // cap body size to prevent pre-auth DoS (inherited FIX 4)
function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => { b += c; if (b.length > MAX_BODY) { req.destroy(); resolve({}); } });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch { resolve({}); } });
  });
}
function authed(req, auth) { return auth.valid(parseCookie(req.headers.cookie)); }

// deps: the hub (createSession/listSessions/deleteSession/attach/hasSession) +
// listDirs. Auth gate is unchanged from v1 and still covers the WS upgrade (I1).
export function createServer({ config, auth, deps }) {
  const open = config.noAuth === true;
  const server = http.createServer(async (req, res) => {
    const url = req.url.split('?')[0];

    // --- public auth endpoints ---
    if (req.method === 'POST' && url === '/login') {
      const { secret } = await readBody(req);
      if (!auth.check(secret)) return json(res, 401, { error: 'bad secret' });
      const token = auth.issue();
      res.writeHead(200, { 'set-cookie': `${COOKIE_NAME}=${token}; HttpOnly; Path=/; SameSite=Lax`, 'content-type': 'application/json' });
      return res.end(JSON.stringify({ ok: true }));
    }
    if (req.method === 'POST' && url === '/logout') {
      auth.revoke(parseCookie(req.headers.cookie));
      res.writeHead(200, { 'set-cookie': `${COOKIE_NAME}=; HttpOnly; Path=/; Max-Age=0` });
      return res.end('{}');
    }
    if (url === '/login') {
      if (open) { res.writeHead(302, { location: '/' }); return res.end(); }
      return serveStatic(req, res, PUBLIC);
    }

    // --- everything else requires auth (unless open mode) ---
    if (!(open || authed(req, auth))) {
      if (url.startsWith('/api/')) return json(res, 401, { error: 'unauthorized' });
      res.writeHead(302, { location: '/login' });
      return res.end();
    }

    // --- API ---
    if (url === '/api/sessions' && req.method === 'GET') return json(res, 200, await deps.listSessions());
    if (url === '/api/sessions' && req.method === 'POST') {
      const { cwd } = await readBody(req);
      try { return json(res, 201, await deps.createSession({ cwd: cwd || config.workspace })); }
      catch (e) { return json(res, 400, { error: e.message }); }
    }
    if (url.startsWith('/api/sessions/') && req.method === 'DELETE') {
      const id = decodeURIComponent(url.slice('/api/sessions/'.length));
      try { await deps.deleteSession(id); return (res.writeHead(204), res.end()); }
      catch (e) { return json(res, 400, { error: e.message }); }
    }
    if (url === '/api/dirs') return json(res, 200, await deps.listDirs(config.workspace));
    if (url === '/api/snippets') return json(res, 200, await loadSnippets(config.snippetsPath));

    // --- static ---
    if (await serveStatic(req, res, PUBLIC)) return;
    res.writeHead(404); res.end('not found');
  });

  // --- WS upgrade: auth-gated (I1), attaches the client to a session hub (D3) ---
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (req, socket, head) => {
    if (!open && !auth.valid(parseCookie(req.headers.cookie))) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return socket.destroy();
    }
    const id = new URL(req.url, 'http://x').searchParams.get('session');
    if (!id || !deps.hasSession(id)) {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      return socket.destroy();
    }
    wss.handleUpgrade(req, socket, head, (ws) => { deps.attach(ws, id); });
  });

  return server;
}
