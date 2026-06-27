import { readFile } from 'node:fs/promises';
import path from 'node:path';

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };

// v2 ships a dependency-free client (compact markdown + line-diff in app.js), so
// there is no vendored bundle to serve — the xterm dist is gone with the terminal.
export async function serveStatic(req, res, publicDir) {
  if (req.method && req.method !== 'GET') return false; // static files GET-only (inherited FIX 6)
  const url = req.url.split('?')[0];
  let file;
  if (url === '/' || url === '/index.html') file = path.join(publicDir, 'index.html');
  else if (url === '/login') file = path.join(publicDir, 'login.html');
  else if (/^\/(app\.js|style\.css)$/.test(url)) file = path.join(publicDir, url.slice(1));
  else return false;

  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
    res.end(body);
    return true;
  } catch {
    return false;
  }
}
