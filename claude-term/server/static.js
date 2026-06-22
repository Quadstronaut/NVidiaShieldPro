import { readFile } from 'node:fs/promises';
import path from 'node:path';

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };

// Vendored xterm dist served from node_modules so we ship no bundler.
const VENDOR = {
  '/vendor/xterm.js': '@xterm/xterm/lib/xterm.js',
  '/vendor/xterm.css': '@xterm/xterm/css/xterm.css',
  '/vendor/addon-fit.js': '@xterm/addon-fit/lib/addon-fit.js',
};

export async function serveStatic(req, res, publicDir, nodeModules = path.resolve('node_modules')) {
  if (req.method && req.method !== 'GET') return false; // FIX 6: static files GET-only
  const url = req.url.split('?')[0];
  let file;
  if (VENDOR[url]) file = path.join(nodeModules, VENDOR[url]);
  else if (url === '/' || url === '/index.html') file = path.join(publicDir, 'index.html');
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
