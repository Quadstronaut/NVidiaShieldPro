import http from 'node:http';
import { WebSocketServer } from 'ws';
import { COOKIE_NAME, parseCookie } from './auth.js';
import { loadSnippets } from './snippets.js';
import { serveStatic } from './static.js';
import { validName } from './sessions.js';
import path from 'node:path';

const PUBLIC = path.resolve('public');

function json(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
}
const MAX_BODY = 64 * 1024; // FIX 4: cap body size to prevent pre-auth DoS
function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => {
      b += c;
      if (b.length > MAX_BODY) { req.destroy(); resolve({}); }
    });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch { resolve({}); } });
  });
}
function authed(req, auth) {
  return auth.valid(parseCookie(req.headers.cookie));
}

export function createServer({ config, auth, deps }) {
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
    if (url === '/login') return serveStatic(req, res, PUBLIC); // GET login page

    // --- everything else requires auth ---
    const ok = authed(req, auth);
    if (!ok) {
      if (url.startsWith('/api/')) return json(res, 401, { error: 'unauthorized' });
      res.writeHead(302, { location: '/login' });
      return res.end();
    }

    // --- API ---
    if (url === '/api/sessions' && req.method === 'GET') return json(res, 200, await deps.listSessions());
    if (url === '/api/sessions' && req.method === 'POST') {
      const { name, cwd } = await readBody(req);
      try {
        await deps.createSession({ name, cwd, workspace: config.workspace });
        return json(res, 201, { ok: true });
      } catch (e) { return json(res, 400, { error: e.message }); }
    }
    if (url.startsWith('/api/sessions/') && req.method === 'DELETE') {
      const name = decodeURIComponent(url.slice('/api/sessions/'.length));
      if (!validName(name)) return json(res, 400, { error: 'invalid session name' }); // FIX 1 (I3)
      try { await deps.killSession({ name }); return (res.writeHead(204), res.end()); }
      catch (e) { return json(res, 400, { error: e.message }); }
    }
    if (url === '/api/dirs') return json(res, 200, await deps.listDirs(config.workspace));
    if (url === '/api/snippets') return json(res, 200, await loadSnippets(config.snippetsPath));

    // --- static ---
    if (await serveStatic(req, res, PUBLIC)) return;
    res.writeHead(404); res.end('not found');
  });

  // --- WS upgrade: auth-gated (I1) ---
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (req, socket, head) => {
    if (!auth.valid(parseCookie(req.headers.cookie))) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return socket.destroy();
    }
    const u = new URL(req.url, 'http://x');
    const session = u.searchParams.get('session');
    wss.handleUpgrade(req, socket, head, async (ws) => {
      // FIX 2 (I1 defense-in-depth): reject invalid or unknown session names
      if (!session || !validName(session) || !(await deps.hasSession({ name: session }))) {
        ws.close(1008, 'invalid or unknown session');
        return;
      }
      deps.attachSession(ws, session);
    });
  });

  return server;
}
