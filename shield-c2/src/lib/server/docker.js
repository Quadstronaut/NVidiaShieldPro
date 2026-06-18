// Typed docker-socket client. IMPLEMENTS ONLY THE ALLOWLIST (I2):
//   { list, inspect, start, stop, restart, logs }
// There is NO generic passthrough. create / exec / commit / build / pull /
// volume / network are NEVER constructed here. The socket is root-equivalent;
// this allowlist is the sole blast-radius control (D5).

import http from 'node:http';
import { config } from './config.js';

// Low-level request to the unix socket. `path` is fixed by the named methods
// below — callers cannot inject an arbitrary docker path through this module's
// public API.
function request(method, path, { json = false, raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        socketPath: config.dockerSocket,
        method,
        path,
        headers: { Host: 'docker', Accept: json ? 'application/json' : 'text/plain' }
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const status = res.statusCode ?? 0;
          const buf = Buffer.concat(chunks);
          if (status >= 400) {
            let detail = buf.toString('utf8');
            try {
              detail = JSON.parse(detail).message ?? detail;
            } catch {
              /* keep raw */
            }
            return reject(Object.assign(new Error(`docker ${status}`), { status, detail }));
          }
          if (raw) return resolve(buf);
          if (json) {
            try {
              return resolve(buf.length ? JSON.parse(buf.toString('utf8')) : null);
            } catch (e) {
              return reject(e);
            }
          }
          resolve(buf.toString('utf8'));
        });
      }
    );
    req.on('error', reject);
    req.end();
  });
}

// Container ids may contain only hex + name chars from the daemon. We accept the
// caller-supplied id but only ever embed it in a fixed, allowlisted path.
function safeId(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(id)) {
    throw Object.assign(new Error('invalid container id'), { status: 400 });
  }
  return encodeURIComponent(id);
}

// --- ALLOWLIST -------------------------------------------------------------

// list
export async function listContainers() {
  const arr = await request('GET', '/containers/json?all=1', { json: true });
  return (arr ?? []).map((c) => ({
    id: c.Id,
    name: (c.Names?.[0] ?? '').replace(/^\//, ''),
    image: c.Image,
    state: c.State,
    status: c.Status,
    ports: c.Ports ?? []
  }));
}

// inspect (used internally / available to the allowlist)
export function inspectContainer(id) {
  return request('GET', `/containers/${safeId(id)}/json`, { json: true });
}

// start
export function startContainer(id) {
  return request('POST', `/containers/${safeId(id)}/start`);
}

// stop
export function stopContainer(id) {
  return request('POST', `/containers/${safeId(id)}/stop`);
}

// restart
export function restartContainer(id) {
  return request('POST', `/containers/${safeId(id)}/restart`);
}

// logs (tail capped 1..1000)
export async function containerLogs(id, tail) {
  const n = Math.min(1000, Math.max(1, Number(tail) || 200));
  const buf = await request(
    'GET',
    `/containers/${safeId(id)}/logs?stdout=1&stderr=1&tail=${n}`,
    { raw: true }
  );
  return demux(buf);
}

// Docker multiplexes non-tty logs with an 8-byte stream header per frame.
// Strip it so the client gets clean text. TTY logs have no header; detect by
// checking the first byte is a valid stream type (0..2).
function demux(buf) {
  if (buf.length >= 8 && buf[0] <= 2 && buf[1] === 0 && buf[2] === 0 && buf[3] === 0) {
    const out = [];
    let off = 0;
    while (off + 8 <= buf.length) {
      const len = buf.readUInt32BE(off + 4);
      out.push(buf.slice(off + 8, off + 8 + len));
      off += 8 + len;
    }
    return Buffer.concat(out).toString('utf8');
  }
  return buf.toString('utf8');
}
