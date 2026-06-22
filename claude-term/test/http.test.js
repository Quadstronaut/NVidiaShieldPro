import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { loadConfig } from '../server/config.js';
import { createAuth } from '../server/auth.js';
import { createServer } from '../server/http.js';

function deps() {
  const sessions = [];
  return {
    listSessions: async () => sessions,
    createSession: async ({ name }) => { sessions.push({ name, cwd: '/data/claude' }); },
    killSession: async ({ name }) => { const i = sessions.findIndex((s) => s.name === name); if (i >= 0) sessions.splice(i, 1); },
    hasSession: async ({ name }) => sessions.some((s) => s.name === name),
    listDirs: async () => ['proj'],
    attachSession: () => {},
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

test('AC2: session create/list/delete through the API', async () => {
  const { srv, base } = await boot();
  const login = await fetch(base + '/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'pw' }) });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const c = await fetch(base + '/api/sessions', { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify({ name: 't1', cwd: '/data/claude' }) });
  assert.equal(c.status, 201);
  const list = await (await fetch(base + '/api/sessions', { headers: { cookie } })).json();
  assert.ok(list.some((s) => s.name === 't1'));
  const d = await fetch(base + '/api/sessions/t1', { method: 'DELETE', headers: { cookie } });
  assert.equal(d.status, 204);
  srv.close();
});

test('api without cookie → 401', async () => {
  const { srv, base } = await boot();
  const r = await fetch(base + '/api/sessions');
  assert.equal(r.status, 401);
  srv.close();
});

// FIX 1: DELETE with invalid session name (contains space after URL-decode) → 400
test('DELETE /api/sessions/:name with invalid name → 400', async () => {
  const { srv, base } = await boot();
  const login = await fetch(base + '/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'pw' }) });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const r = await fetch(base + '/api/sessions/bad%20name', { method: 'DELETE', headers: { cookie } });
  assert.equal(r.status, 400);
  const body = await r.json();
  assert.equal(body.error, 'invalid session name');
  srv.close();
});
