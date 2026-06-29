import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { loadConfig } from '../server/config.js';
import { createAuth } from '../server/auth.js';
import { createServer } from '../server/http.js';

// v2 deps shape: sessions are uuid-keyed, created from a cwd (no names/tmux).
// deleteSession mirrors the hub — it throws 'invalid session id' on a non-uuid.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function deps() {
  const sessions = new Map();
  return {
    listSessions: async () => [...sessions.values()],
    createSession: async ({ cwd }) => { const id = randomUUID(); sessions.set(id, { id, cwd, title: '(new session)' }); return { id, cwd }; },
    deleteSession: async (id) => { if (!UUID_RE.test(id)) throw new Error('invalid session id'); sessions.delete(id); },
    attach: () => {},
    hasSession: (id) => UUID_RE.test(id),
    listDirs: async () => ['/data/claude'],
  };
}

async function boot() {
  const config = loadConfig({ CLAUDE_TERM_SECRET: 'pw' });
  const auth = createAuth('pw');
  const srv = createServer({ config, auth, deps: deps() });
  srv.listen(0);
  await once(srv, 'listening');
  const base = `http://127.0.0.1:${srv.address().port}`;
  return { srv, base };
}

async function loginCookie(base) {
  const r = await fetch(base + '/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'pw' }) });
  return r.headers.get('set-cookie').split(';')[0];
}

test('AC1: no cookie → / returns 302 to /login', async () => {
  const { srv, base } = await boot();
  const r = await fetch(base + '/', { redirect: 'manual' });
  assert.equal(r.status, 302);
  srv.close();
});

test('AC1: POST /login with secret sets cookie; then / is 200', async () => {
  const { srv, base } = await boot();
  const r = await fetch(base + '/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'pw' }) });
  assert.equal(r.status, 200);
  const cookie = r.headers.get('set-cookie').split(';')[0];
  const r2 = await fetch(base + '/', { headers: { cookie }, redirect: 'manual' });
  assert.equal(r2.status, 200);
  srv.close();
});

test('AC1: wrong secret → 401, no cookie', async () => {
  const { srv, base } = await boot();
  const r = await fetch(base + '/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'nope' }) });
  assert.equal(r.status, 401);
  assert.equal(r.headers.get('set-cookie'), null);
  srv.close();
});

test('AC2: session create/list/delete through the API (uuid-keyed)', async () => {
  const { srv, base } = await boot();
  const cookie = await loginCookie(base);
  const c = await fetch(base + '/api/sessions', { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify({ cwd: '/data/claude' }) });
  assert.equal(c.status, 201);
  const { id } = await c.json();
  assert.ok(UUID_RE.test(id), 'create returns a uuid');
  const list = await (await fetch(base + '/api/sessions', { headers: { cookie } })).json();
  assert.ok(list.some((s) => s.id === id));
  const d = await fetch(base + '/api/sessions/' + id, { method: 'DELETE', headers: { cookie } });
  assert.equal(d.status, 204);
  srv.close();
});

test('api without cookie → 401', async () => {
  const { srv, base } = await boot();
  const r = await fetch(base + '/api/sessions');
  assert.equal(r.status, 401);
  srv.close();
});

test('DELETE /api/sessions/:id with a non-uuid → 400', async () => {
  const { srv, base } = await boot();
  const cookie = await loginCookie(base);
  const r = await fetch(base + '/api/sessions/not-a-uuid', { method: 'DELETE', headers: { cookie } });
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error, 'invalid session id');
  srv.close();
});
