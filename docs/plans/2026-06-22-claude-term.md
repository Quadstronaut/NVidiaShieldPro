# claude-term Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `claude-term` — a LAN-only, phone-driven web terminal that launches and reattaches Claude Code sessions running on the NVIDIA Shield, per `docs/SPEC-claude-term.md` (user-approved 2026-06-20).

**Architecture:** A single small **plain-Node** process (`http` + `ws` + `node-pty`) serves one static xterm.js page behind a shared-secret cookie gate. The page lists/creates/attaches **tmux**-managed sessions; each session is shell-rooted then auto-starts `claude`. A WebSocket carries PTY bytes both ways; snippet chips inject bracketed-paste blocks through the same input channel. Ships as a digest-pinned arm64 `node:20-bookworm-slim` container, run `--network host` on `:7777`, launched by a button in the existing `shield-c2` dashboard (`:8888`).

**Tech Stack:** Node 20 (ESM), `ws`, `@homebridge/node-pty-prebuilt-multiarch`, `@xterm/xterm` + `@xterm/addon-fit` (vendored static assets), `tmux`, `@anthropic-ai/claude-code`. Tests use the built-in `node:test` + `node:assert` runner (no framework — matches the plain-Node ethos). Docker classic builder (`DOCKER_BUILDKIT=0`, `--network=host`) on-device.

## Global Constraints

Copied verbatim from the spec; every task implicitly includes these:

- **Runtime = plain Node** (`http` + `ws` + `node-pty`) serving a static xterm.js page — **NOT** SvelteKit (D1).
- **Base image = `node:20-bookworm-slim`, arm64, digest-pinned** `@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df` (glibc, not alpine — kernel 4.9.141 trips `ENOSYS` on musl) (D4/I7). Documented fallback: `node:18-bullseye-slim` (logged exception).
- **Host networking only** — `--network host`, bind `CLAUDE_TERM_PORT` on the LAN IP. No `-p`, no bridge, no docker0 (bridge is dead on this kernel) (I4).
- **On-device build** — classic builder only: `DOCKER_BUILDKIT=0` and `--network=host` on `docker build` (else npm install gets no DNS → `EAI_AGAIN`).
- **Auth fail-closed (I1):** every route AND the WS upgrade require a valid session cookie. If `CLAUDE_TERM_SECRET` is empty the server **refuses to start**.
- **Workspace confinement (I2/I3):** the only writable host mounts are `/data/claude` (rw) and the `~/.claude` named volume. A new session's `cwd` must `realpath` under `/data/claude`. **No** docker socket (I9 — the bright line vs `shield-c2`).
- **Non-root Claude (I8):** server + `claude` run as in-container user `claude` (uid 1000).
- **No secrets in history (I10/I11):** `CLAUDE_TERM_SECRET` and `CLAUDE_CODE_OAUTH_TOKEN` arrive via env at run time; never baked into the image or committed. `snippets.json` (no secrets) may be committed.
- **Port = 7777** (`CLAUDE_TERM_PORT`, env-overridable). Occupied host ports to avoid: 8888 (shield-c2), 3001 (Kuma).
- **Commits land on the current branch** of `NVIDIAShield` (`master`, user convention). This repo has **no git remote** — repo transfer to the Shield is a deploy-time step (Task 14).

---

## File Structure

```
NVIDIAShield/
  claude-term/
    package.json            # ESM; deps: ws, node-pty fork, @xterm/*; scripts: start, test
    .gitignore              # node_modules, *.local
    .dockerignore           # node_modules, .git, test
    snippets.json           # 6 seed chips (committed default/example)
    server/
      config.js             # env → config; assertConfig fail-closed (I1)
      auth.js               # shared-secret gate: issue/validate token, parseCookie
      snippets.js           # load snippets.json w/ baked-in defaults
      sessions.js           # tmux list/create/kill + name + cwd-confinement (I3)
      bracketed-paste.js    # wrapPaste(body, submit) (D7)
      pty-bridge.js         # ws ↔ node-pty `tmux attach` (D2/D3)
      http.js               # route table, auth enforcement, static serving, /api/*
      index.js              # entry: build server, ws upgrade, listen
      static.js             # serve public/ + vendored xterm dist
    public/
      index.html            # terminal page: session list, new-session form, chips, xterm
      app.js                # client: fetch sessions/snippets, WS, xterm, chip injection
      login.html            # passphrase form
      style.css             # minimal styling
    test/
      config.test.js  auth.test.js  snippets.test.js
      sessions.test.js  bracketed-paste.test.js  pty-bridge.test.js
  docker-bringup/
    claude-term.sh          # launcher mirroring c2.sh (port 7777, no socket, rw mounts)
    claude-term.env.example # template: CLAUDE_TERM_SECRET=, CLAUDE_CODE_OAUTH_TOKEN=
  docs/
    THREAT-MODEL.md         # append claude-term section
  shield-c2/                # add one "Claude Code" nav link → :7777
```

**Test environment split (honest):** `config / auth / snippets / sessions(logic) / bracketed-paste / pty-bridge(protocol via fake spawn)` run on the **dev box** (`node --test`, no tmux/claude needed). `tmux`/`node-pty`/`claude`/WS-end-to-end/on-Shield checks run **in the container / on the Shield** (Task 14, using the spec §6 acceptance tests). Every device-dependent test is labelled.

---

### Task 1: Scaffold the claude-term Node project

**Files:**
- Create: `claude-term/package.json`, `claude-term/.gitignore`, `claude-term/.dockerignore`
- Test: `claude-term/test/smoke.test.js`

**Interfaces:**
- Produces: an ESM project where `npm test` runs the `node:test` runner over `test/*.test.js`.

- [ ] **Step 1: Write `claude-term/package.json`**

```json
{
  "name": "claude-term",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "LAN-only phone-driven web terminal for Claude Code sessions on the NVIDIA Shield.",
  "scripts": {
    "start": "node server/index.js",
    "test": "node --test"
  },
  "dependencies": {
    "@homebridge/node-pty-prebuilt-multiarch": "^0.12.0",
    "@xterm/addon-fit": "^0.10.0",
    "@xterm/xterm": "^5.5.0",
    "ws": "^8.18.0"
  }
}
```

- [ ] **Step 2: Write `claude-term/.gitignore`**

```
node_modules/
*.local
*.log
```

- [ ] **Step 3: Write `claude-term/.dockerignore`**

```
node_modules
.git
test
*.local
```

- [ ] **Step 4: Write the smoke test** `claude-term/test/smoke.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('smoke: node:test runner is wired', () => {
  assert.equal(1 + 1, 2);
});
```

- [ ] **Step 5: Install deps and run the smoke test**

Run (from `claude-term/`): `npm install --no-audit --no-fund && npm test`
Expected: `node-pty` prebuilt downloads without a compile; smoke test PASSES (`# pass 1`).
Note: if the prebuilt fails to download/load on the dev box, that is **R2** — it is *not* a blocker for the logic tasks (2–6); record it and continue, it is verified on-device in Task 14.

- [ ] **Step 6: Commit**

```bash
git add claude-term/package.json claude-term/.gitignore claude-term/.dockerignore claude-term/test/smoke.test.js
git commit -m "feat(claude-term): scaffold plain-Node project + test runner"
```

---

### Task 2: Config module (fail-closed)

**Files:**
- Create: `claude-term/server/config.js`
- Test: `claude-term/test/config.test.js`

**Interfaces:**
- Produces: `loadConfig(env=process.env) → {port, secret, snippetsPath, workspace, oauthToken}`; `assertConfig(cfg) → cfg` (throws if `secret` empty).

- [ ] **Step 1: Write the failing test** `claude-term/test/config.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig, assertConfig } from '../server/config.js';

test('defaults: port 7777, workspace /data/claude', () => {
  const c = loadConfig({ CLAUDE_TERM_SECRET: 'x' });
  assert.equal(c.port, 7777);
  assert.equal(c.workspace, '/data/claude');
  assert.equal(c.snippetsPath, '/data/claude/snippets.json');
});

test('env overrides are honored', () => {
  const c = loadConfig({ CLAUDE_TERM_PORT: '9001', CLAUDE_TERM_WORKSPACE: '/w', CLAUDE_TERM_SECRET: 'x' });
  assert.equal(c.port, 9001);
  assert.equal(c.workspace, '/w');
});

test('assertConfig throws fail-closed when secret empty (I1)', () => {
  assert.throws(() => assertConfig(loadConfig({})), /CLAUDE_TERM_SECRET/);
});

test('assertConfig returns the config when secret set', () => {
  const c = loadConfig({ CLAUDE_TERM_SECRET: 'hunter2' });
  assert.equal(assertConfig(c), c);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/config.test.js`
Expected: FAIL — `Cannot find module '../server/config.js'`.

- [ ] **Step 3: Write `claude-term/server/config.js`**

```js
// Central runtime config. All values come from the environment so the launcher
// and Dockerfile fully control behaviour.

function num(v, d) {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

export function loadConfig(env = process.env) {
  return {
    port: num(env.CLAUDE_TERM_PORT, 7777),
    secret: env.CLAUDE_TERM_SECRET ?? '',
    snippetsPath: env.CLAUDE_TERM_SNIPPETS || '/data/claude/snippets.json',
    workspace: env.CLAUDE_TERM_WORKSPACE || '/data/claude',
    // Presence only matters to the launcher/Claude; the server passes it through.
    oauthToken: env.CLAUDE_CODE_OAUTH_TOKEN ?? '',
  };
}

// I1: refuse to start without a gate secret. Never silently serve an open shell.
export function assertConfig(cfg) {
  if (!cfg.secret) {
    throw new Error('CLAUDE_TERM_SECRET is required (fail-closed, I1) — refusing to start.');
  }
  return cfg;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/config.test.js`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add claude-term/server/config.js claude-term/test/config.test.js
git commit -m "feat(claude-term): env config with fail-closed secret assertion (I1)"
```

---

### Task 3: Auth module (shared-secret gate)

**Files:**
- Create: `claude-term/server/auth.js`
- Test: `claude-term/test/auth.test.js`

**Interfaces:**
- Produces: `createAuth(secret) → { check(attempt), issue(), valid(token), revoke(token) }`; `parseCookie(header, name='ct_session') → string|null`; `COOKIE_NAME='ct_session'`.

- [ ] **Step 1: Write the failing test** `claude-term/test/auth.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAuth, parseCookie, COOKIE_NAME } from '../server/auth.js';

test('check: right secret passes, wrong/empty fails', () => {
  const a = createAuth('s3cret');
  assert.equal(a.check('s3cret'), true);
  assert.equal(a.check('nope'), false);
  const empty = createAuth('');
  assert.equal(empty.check(''), false); // empty secret never authenticates
});

test('issue → valid; unknown token invalid; revoke removes', () => {
  const a = createAuth('s');
  const t = a.issue();
  assert.equal(a.valid(t), true);
  assert.equal(a.valid('deadbeef'), false);
  assert.equal(a.valid(undefined), false);
  a.revoke(t);
  assert.equal(a.valid(t), false);
});

test('parseCookie extracts the named cookie', () => {
  assert.equal(parseCookie(`a=1; ${COOKIE_NAME}=abc; b=2`), 'abc');
  assert.equal(parseCookie('a=1; b=2'), null);
  assert.equal(parseCookie(undefined), null);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/auth.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `claude-term/server/auth.js`**

```js
import crypto from 'node:crypto';

export const COOKIE_NAME = 'ct_session';

// In-memory token set (A5/D): tokens die on container restart — acceptable (I6).
export function createAuth(secret) {
  const tokens = new Set();
  return {
    // Constant-secret compare; empty secret can never authenticate (I1).
    check(attempt) {
      return secret.length > 0 && attempt === secret;
    },
    issue() {
      const t = crypto.randomBytes(32).toString('hex');
      tokens.add(t);
      return t;
    },
    valid(token) {
      return typeof token === 'string' && tokens.has(token);
    },
    revoke(token) {
      tokens.delete(token);
    },
  };
}

export function parseCookie(header, name = COOKIE_NAME) {
  if (!header) return null;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const k = part.slice(0, idx).trim();
    if (k === name) return decodeURIComponent(part.slice(idx + 1).trim());
  }
  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/auth.test.js`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add claude-term/server/auth.js claude-term/test/auth.test.js
git commit -m "feat(claude-term): shared-secret auth gate + cookie parsing"
```

---

### Task 4: Snippets module + seed config

**Files:**
- Create: `claude-term/server/snippets.js`, `claude-term/snippets.json`
- Test: `claude-term/test/snippets.test.js`

**Interfaces:**
- Produces: `DEFAULT_SNIPPETS: Array<{label,body,submit?}>` (6 chips); `loadSnippets(path) → Promise<Array<{label,body,submit?}>>` (falls back to defaults on any read/parse/shape failure).

- [ ] **Step 1: Write the failing test** `claude-term/test/snippets.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { loadSnippets, DEFAULT_SNIPPETS } from '../server/snippets.js';

test('missing file → baked-in defaults (>=6, all have label+body)', async () => {
  const s = await loadSnippets('/no/such/file.json');
  assert.ok(s.length >= 6);
  assert.ok(s.every((c) => c.label && c.body));
  assert.deepEqual(s, DEFAULT_SNIPPETS);
});

test('valid file is parsed and returned', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'snip-'));
  const p = path.join(dir, 'snippets.json');
  await writeFile(p, JSON.stringify([{ label: 'X', body: 'do x', submit: true }]));
  const s = await loadSnippets(p);
  assert.equal(s[0].label, 'X');
  assert.equal(s[0].submit, true);
  await rm(dir, { recursive: true, force: true });
});

test('malformed JSON → defaults (no throw)', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'snip-'));
  const p = path.join(dir, 'snippets.json');
  await writeFile(p, '{ not json');
  const s = await loadSnippets(p);
  assert.deepEqual(s, DEFAULT_SNIPPETS);
  await rm(dir, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/snippets.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `claude-term/server/snippets.js`**

```js
import { readFile } from 'node:fs/promises';

// The 6 seed chips (spec §9). `submit:true` fires immediately; default prepends.
export const DEFAULT_SNIPPETS = [
  { label: '🏛️ Council', body: 'Convene the council (council-v2-spec) on this change before committing.' },
  { label: '💡 Brainstorm', body: 'Use the brainstorming skill first — explore intent and design before any code.' },
  { label: '🐛 Debug', body: 'Use systematic-debugging: form a hypothesis and find root cause before proposing a fix.' },
  { label: '📐 Plan only', body: 'Produce a written plan only. Do not edit code until I approve it.' },
  { label: '✅ Verify', body: 'Run the verification commands and show the output before claiming this works.', submit: true },
  { label: '🦙 Local offload', body: 'Offload bulk reads/summaries to the local Ollama tools where it saves main-context tokens.' },
];

export async function loadSnippets(p) {
  try {
    const raw = await readFile(p, 'utf8');
    const arr = JSON.parse(raw);
    if (Array.isArray(arr) && arr.length > 0 && arr.every((c) => c && c.label && c.body)) {
      return arr;
    }
  } catch {
    // fall through to defaults
  }
  return DEFAULT_SNIPPETS;
}
```

- [ ] **Step 4: Write the committed seed `claude-term/snippets.json`** (same 6 chips, so the on-device default file exists)

```json
[
  { "label": "🏛️ Council", "body": "Convene the council (council-v2-spec) on this change before committing." },
  { "label": "💡 Brainstorm", "body": "Use the brainstorming skill first — explore intent and design before any code." },
  { "label": "🐛 Debug", "body": "Use systematic-debugging: form a hypothesis and find root cause before proposing a fix." },
  { "label": "📐 Plan only", "body": "Produce a written plan only. Do not edit code until I approve it." },
  { "label": "✅ Verify", "body": "Run the verification commands and show the output before claiming this works.", "submit": true },
  { "label": "🦙 Local offload", "body": "Offload bulk reads/summaries to the local Ollama tools where it saves main-context tokens." }
]
```

- [ ] **Step 5: Run test to verify it passes**

Run: `node --test test/snippets.test.js`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add claude-term/server/snippets.js claude-term/snippets.json claude-term/test/snippets.test.js
git commit -m "feat(claude-term): snippet loader with baked-in defaults + seed config"
```

---

### Task 5: Sessions module (tmux API + confinement)

**Files:**
- Create: `claude-term/server/sessions.js`
- Test: `claude-term/test/sessions.test.js`

**Interfaces:**
- Produces:
  - `validName(name) → boolean` (`^[A-Za-z0-9_-]{1,32}$`)
  - `confineCwd(cwd, workspace) → Promise<string>` (resolved real path; throws if outside `workspace`) (I3)
  - `listSessions({exec}) → Promise<Array<{name,windows,created,attached,cwd}>>`
  - `createSession({name,cwd,workspace,exec}) → Promise<void>` (validates, `tmux new -d`, then `send-keys 'claude' Enter`) (D3)
  - `killSession({name,exec}) → Promise<void>`
  - `hasSession({name,exec}) → Promise<boolean>`
  - `exec` defaults to a `promisify(execFile)` wrapper; tests inject a fake.

- [ ] **Step 1: Write the failing test** `claude-term/test/sessions.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { validName, confineCwd, listSessions, createSession, killSession } from '../server/sessions.js';

test('validName accepts safe names, rejects junk', () => {
  assert.equal(validName('t1'), true);
  assert.equal(validName('my_session-2'), true);
  assert.equal(validName('bad name'), false);
  assert.equal(validName('../etc'), false);
  assert.equal(validName(''), false);
  assert.equal(validName('x'.repeat(33)), false);
});

test('confineCwd allows the workspace and subdirs, rejects escapes (I3)', async () => {
  const ws = await mkdtemp(path.join(tmpdir(), 'ws-'));
  const sub = path.join(ws, 'proj');
  await mkdir(sub);
  assert.equal(await confineCwd(ws, ws), await import('node:fs/promises').then((m) => m.realpath(ws)));
  assert.ok((await confineCwd(sub, ws)).endsWith('proj'));
  await assert.rejects(() => confineCwd('/etc', ws), /escapes|resolve/);
  await assert.rejects(() => confineCwd(path.join(ws, '..'), ws), /escapes|resolve/);
  await rm(ws, { recursive: true, force: true });
});

test('createSession validates then issues tmux new + send-keys claude (D3)', async () => {
  const ws = await mkdtemp(path.join(tmpdir(), 'ws-'));
  const calls = [];
  const exec = async (cmd, args) => { calls.push([cmd, ...args]); return { stdout: '', stderr: '' }; };
  await createSession({ name: 'dev', cwd: ws, workspace: ws, exec });
  assert.deepEqual(calls[0], ['tmux', 'new-session', '-d', '-s', 'dev', '-c', await import('node:fs/promises').then((m) => m.realpath(ws))]);
  assert.deepEqual(calls[1], ['tmux', 'send-keys', '-t', 'dev', 'claude', 'Enter']);
  await rm(ws, { recursive: true, force: true });
});

test('createSession rejects a bad name before any exec', async () => {
  const exec = async () => { throw new Error('should not run'); };
  await assert.rejects(() => createSession({ name: 'bad name', cwd: '/tmp', workspace: '/tmp', exec }), /name/i);
});

test('listSessions parses tmux -F output incl. cwd', async () => {
  const exec = async (cmd, args) => {
    if (args[0] === 'list-sessions') return { stdout: 'dev\t2\t1718900000\t1\n', stderr: '' };
    if (args[0] === 'display-message') return { stdout: '/data/claude/proj\n', stderr: '' };
    return { stdout: '', stderr: '' };
  };
  const s = await listSessions({ exec });
  assert.equal(s[0].name, 'dev');
  assert.equal(s[0].windows, 2);
  assert.equal(s[0].attached, true);
  assert.equal(s[0].cwd, '/data/claude/proj');
});

test('killSession calls tmux kill-session', async () => {
  const calls = [];
  const exec = async (cmd, args) => { calls.push(args); return { stdout: '', stderr: '' }; };
  await killSession({ name: 'dev', exec });
  assert.deepEqual(calls[0], ['kill-session', '-t', 'dev']);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/sessions.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `claude-term/server/sessions.js`**

```js
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { realpath } from 'node:fs/promises';
import path from 'node:path';

const NAME_RE = /^[A-Za-z0-9_-]{1,32}$/;
const defaultExec = promisify(execFile);

export function validName(name) {
  return typeof name === 'string' && NAME_RE.test(name);
}

// I3: resolve symlinks, reject anything not under the workspace root.
export async function confineCwd(cwd, workspace) {
  const wsReal = await realpath(workspace);
  let target;
  try {
    target = await realpath(cwd);
  } catch {
    throw new Error('cwd does not resolve to an existing path');
  }
  const rel = path.relative(wsReal, target);
  if (rel === '') return target; // the workspace itself
  if (rel.startsWith('..') || path.isAbsolute(rel)) {
    throw new Error('cwd escapes the workspace');
  }
  return target;
}

const FMT = '#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}';

export async function listSessions({ exec = defaultExec } = {}) {
  let out;
  try {
    out = await exec('tmux', ['list-sessions', '-F', FMT]);
  } catch {
    return []; // no server / no sessions
  }
  const lines = out.stdout.split('\n').filter(Boolean);
  const sessions = [];
  for (const line of lines) {
    const [name, windows, created, attached] = line.split('\t');
    let cwd = '';
    try {
      const c = await exec('tmux', ['display-message', '-p', '-t', name, '#{pane_current_path}']);
      cwd = c.stdout.trim();
    } catch { /* leave blank */ }
    sessions.push({ name, windows: Number(windows), created: Number(created), attached: attached === '1', cwd });
  }
  return sessions;
}

export async function hasSession({ name, exec = defaultExec }) {
  try {
    await exec('tmux', ['has-session', '-t', name]);
    return true;
  } catch {
    return false;
  }
}

export async function createSession({ name, cwd, workspace, exec = defaultExec }) {
  if (!validName(name)) throw new Error(`invalid session name: ${name}`);
  const safeCwd = await confineCwd(cwd, workspace);
  // Shell-rooted, then auto-start Claude Code so exiting claude drops to a shell (D3).
  await exec('tmux', ['new-session', '-d', '-s', name, '-c', safeCwd]);
  await exec('tmux', ['send-keys', '-t', name, 'claude', 'Enter']);
}

export async function killSession({ name, exec = defaultExec }) {
  await exec('tmux', ['kill-session', '-t', name]);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/sessions.test.js`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add claude-term/server/sessions.js claude-term/test/sessions.test.js
git commit -m "feat(claude-term): tmux session API + name validation + cwd confinement (I3/D3)"
```

---

### Task 6: Bracketed-paste injection helper

**Files:**
- Create: `claude-term/server/bracketed-paste.js`
- Test: `claude-term/test/bracketed-paste.test.js`

**Interfaces:**
- Produces: `wrapPaste(body, submit=false) → string` — wraps body in `ESC[200~ … ESC[201~`, appends `\r` when `submit` (D7).

- [ ] **Step 1: Write the failing test** `claude-term/test/bracketed-paste.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wrapPaste } from '../server/bracketed-paste.js';

const START = '\x1b[200~';
const END = '\x1b[201~';

test('wraps a multi-line body in bracketed-paste markers, no submit', () => {
  const out = wrapPaste('line1\nline2');
  assert.ok(out.startsWith(START));
  assert.ok(out.endsWith(END));
  assert.ok(out.includes('line1\nline2'));
  assert.ok(!out.endsWith('\r'));
});

test('submit:true appends a carriage return after the end marker (D7)', () => {
  const out = wrapPaste('go', true);
  assert.ok(out.endsWith(END + '\r'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/bracketed-paste.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `claude-term/server/bracketed-paste.js`**

```js
const ESC = '\x1b';
const START = `${ESC}[200~`;
const END = `${ESC}[201~`;

// D7: bracketed paste makes Claude Code's TUI treat a multi-line block as pasted
// text (inserted, not submitted at the first newline). submit appends CR to fire.
export function wrapPaste(body, submit = false) {
  return START + body + END + (submit ? '\r' : '');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/bracketed-paste.test.js`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add claude-term/server/bracketed-paste.js claude-term/test/bracketed-paste.test.js
git commit -m "feat(claude-term): bracketed-paste wrap for snippet injection (D7)"
```

---

### Task 7: PTY ↔ WebSocket bridge

**Files:**
- Create: `claude-term/server/pty-bridge.js`
- Test: `claude-term/test/pty-bridge.test.js`

**Interfaces:**
- Consumes: a `ws` WebSocket-like object (`.send`, `.on`, `.close`).
- Produces: `attachSession(ws, sessionName, {spawn}) → ptyHandle` — spawns `tmux attach -t <name>`, pipes PTY→ws as `{type:'data',data}`, handles client `{type:'data'|'resize'}`, kills PTY on ws close. `spawn` is injectable (default `node-pty`'s `spawn`).

- [ ] **Step 1: Write the failing test** `claude-term/test/pty-bridge.test.js`

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { attachSession } from '../server/pty-bridge.js';

function fakePty() {
  const em = new EventEmitter();
  return {
    written: [], resized: [], killed: false, _dataCb: null, _exitCb: null,
    onData(cb) { this._dataCb = cb; },
    onExit(cb) { this._exitCb = cb; },
    write(d) { this.written.push(d); },
    resize(c, r) { this.resized.push([c, r]); },
    kill() { this.killed = true; },
  };
}
function fakeWs() {
  const em = new EventEmitter();
  em.sent = []; em.closed = false;
  em.send = (m) => em.sent.push(m);
  em.close = () => { em.closed = true; };
  return em;
}

test('spawns tmux attach for the session', () => {
  const calls = [];
  const spawn = (cmd, args) => { calls.push([cmd, ...args]); return fakePty(); };
  attachSession(fakeWs(), 'dev', { spawn });
  assert.deepEqual(calls[0], ['tmux', 'attach', '-t', 'dev']);
});

test('PTY output is framed to the ws as {type:data}', () => {
  const p = fakePty();
  const ws = fakeWs();
  attachSession(ws, 'dev', { spawn: () => p });
  p._dataCb('hello');
  assert.deepEqual(JSON.parse(ws.sent[0]), { type: 'data', data: 'hello' });
});

test('client data writes to PTY; resize resizes', () => {
  const p = fakePty();
  const ws = fakeWs();
  attachSession(ws, 'dev', { spawn: () => p });
  ws.emit('message', JSON.stringify({ type: 'data', data: 'x' }));
  ws.emit('message', JSON.stringify({ type: 'resize', cols: 100, rows: 40 }));
  assert.deepEqual(p.written, ['x']);
  assert.deepEqual(p.resized, [[100, 40]]);
});

test('ws close kills the PTY (session itself survives in tmux, I6)', () => {
  const p = fakePty();
  const ws = fakeWs();
  attachSession(ws, 'dev', { spawn: () => p });
  ws.emit('close');
  assert.equal(p.killed, true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/pty-bridge.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `claude-term/server/pty-bridge.js`**

```js
import nodePty from '@homebridge/node-pty-prebuilt-multiarch';

// D2/D3: a thin bridge. tmux owns persistence; node-pty runs `tmux attach`.
// `spawn` is injectable so the protocol is unit-testable without a real PTY.
export function attachSession(ws, sessionName, { spawn = nodePty.spawn } = {}) {
  const p = spawn('tmux', ['attach', '-t', sessionName], {
    name: 'xterm-color',
    cols: 80,
    rows: 24,
    cwd: process.env.HOME,
    env: process.env,
  });

  p.onData((data) => {
    try { ws.send(JSON.stringify({ type: 'data', data })); } catch { /* ws gone */ }
  });
  p.onExit(() => {
    try { ws.close(); } catch { /* already closed */ }
  });

  ws.on('message', (raw) => {
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return; }
    if (m.type === 'data') p.write(m.data);
    else if (m.type === 'resize') p.resize(m.cols, m.rows);
  });
  // I6: detaching the PTY leaves the tmux session running for reattach.
  ws.on('close', () => p.kill());

  return p;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/pty-bridge.test.js`
Expected: PASS (4 tests). (No real PTY/tmux touched — `spawn` is faked. Real attach is verified on-device, Task 14 / AC4.)

- [ ] **Step 5: Commit**

```bash
git add claude-term/server/pty-bridge.js claude-term/test/pty-bridge.test.js
git commit -m "feat(claude-term): ws<->node-pty tmux-attach bridge (D2/D3/I6)"
```

---

### Task 8: Static client page (xterm + session UI + chips)

**Files:**
- Create: `claude-term/server/static.js`, `claude-term/public/index.html`, `claude-term/public/login.html`, `claude-term/public/app.js`, `claude-term/public/style.css`

**Interfaces:**
- Produces: `serveStatic(req, res, publicDir) → boolean` (true if it served a known static path incl. vendored xterm assets at `/vendor/*`); the client `app.js` consuming `/api/sessions`, `/api/snippets`, `/api/dirs`, and `GET /ws?session=`.

> This task is UI glue with no pure-logic unit test; its acceptance is the manual browser checks T10–T13 in Task 14. Keep it minimal and correct.

- [ ] **Step 1: Write `claude-term/server/static.js`**

```js
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
```

- [ ] **Step 2: Write `claude-term/public/login.html`**

```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>claude-term — login</title><link rel="stylesheet" href="/style.css" /></head>
<body class="center">
  <form id="f" class="card">
    <h1>claude-term</h1>
    <input id="secret" type="password" placeholder="passphrase" autofocus autocomplete="current-password" />
    <button type="submit">Unlock</button>
    <p id="err" class="err"></p>
  </form>
  <script>
    document.getElementById('f').addEventListener('submit', async (e) => {
      e.preventDefault();
      const r = await fetch('/login', { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ secret: document.getElementById('secret').value }) });
      if (r.ok) location.href = '/';
      else document.getElementById('err').textContent = 'Wrong passphrase';
    });
  </script>
</body></html>
```

- [ ] **Step 3: Write `claude-term/public/index.html`**

```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>claude-term</title>
<link rel="stylesheet" href="/vendor/xterm.css" />
<link rel="stylesheet" href="/style.css" /></head>
<body>
  <header>
    <select id="sessions" aria-label="sessions"></select>
    <button id="refresh">⟳</button>
    <input id="newname" placeholder="name" maxlength="32" />
    <select id="newdir" aria-label="working dir"></select>
    <button id="create">＋ new</button>
    <button id="kill">🗑</button>
    <button id="logout">logout</button>
  </header>
  <div id="chips"></div>
  <div id="term"></div>
  <script src="/vendor/xterm.js"></script>
  <script src="/vendor/addon-fit.js"></script>
  <script src="/app.js"></script>
</body></html>
```

- [ ] **Step 4: Write `claude-term/public/app.js`**

```js
const term = new window.Terminal({ cursorBlink: true, fontSize: 14 });
const fit = new window.FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.getElementById('term'));
fit.fit();

let ws = null;
const $ = (id) => document.getElementById(id);

async function api(path, opts) {
  const r = await fetch(path, opts);
  if (r.status === 401) { location.href = '/login'; throw new Error('unauth'); }
  return r;
}

async function refreshSessions() {
  const list = await (await api('/api/sessions')).json();
  $('sessions').innerHTML = list.map((s) => `<option value="${s.name}">${s.name} (${s.cwd || '?'})</option>`).join('');
}

async function refreshDirs() {
  const dirs = await (await api('/api/dirs')).json();
  $('newdir').innerHTML = dirs.map((d) => `<option value="${d}">${d}</option>`).join('');
}

async function loadChips() {
  const chips = await (await api('/api/snippets')).json();
  $('chips').innerHTML = '';
  for (const c of chips) {
    const b = document.createElement('button');
    b.textContent = c.label;
    b.className = 'chip';
    b.addEventListener('click', () => {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      const ESC = '\x1b';
      const payload = `${ESC}[200~${c.body}${ESC}[201~` + (c.submit ? '\r' : '');
      ws.send(JSON.stringify({ type: 'data', data: payload }));
      term.focus();
    });
    $('chips').appendChild(b);
  }
}

function connect(name) {
  if (ws) ws.close();
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws?session=${encodeURIComponent(name)}`);
  ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.type === 'data') term.write(m.data); };
  ws.onopen = () => { fit.fit(); ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows })); };
}

term.onData((d) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'data', data: d })); });
window.addEventListener('resize', () => {
  fit.fit();
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
});

$('sessions').addEventListener('change', (e) => connect(e.target.value));
$('refresh').addEventListener('click', refreshSessions);
$('create').addEventListener('click', async () => {
  const name = $('newname').value, cwd = $('newdir').value;
  const r = await api('/api/sessions', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name, cwd }) });
  if (r.ok) { await refreshSessions(); $('sessions').value = name; connect(name); }
  else alert((await r.json()).error || 'create failed');
});
$('kill').addEventListener('click', async () => {
  const name = $('sessions').value; if (!name) return;
  await api(`/api/sessions/${encodeURIComponent(name)}`, { method: 'DELETE' });
  await refreshSessions();
});
$('logout').addEventListener('click', async () => { await fetch('/logout', { method: 'POST' }); location.href = '/login'; });

(async () => {
  await Promise.all([refreshSessions(), refreshDirs(), loadChips()]);
  if ($('sessions').value) connect($('sessions').value);
})();
```

- [ ] **Step 5: Write `claude-term/public/style.css`**

```css
* { box-sizing: border-box; }
body { margin: 0; background: #0b0f14; color: #d6deeb; font-family: system-ui, sans-serif; }
header { display: flex; gap: 6px; padding: 6px; flex-wrap: wrap; align-items: center; background: #11161d; }
header select, header input, header button { background: #1b2430; color: #d6deeb; border: 1px solid #2a3645; border-radius: 6px; padding: 6px 8px; font-size: 14px; }
#chips { display: flex; gap: 6px; padding: 6px; flex-wrap: wrap; background: #0e131a; }
.chip { background: #20303f; border: 1px solid #2f4256; border-radius: 16px; padding: 6px 12px; color: #cfe3ff; font-size: 13px; }
.chip:active { background: #2f4d66; }
#term { padding: 4px; height: calc(100vh - 92px); }
.center { display: grid; place-items: center; height: 100vh; }
.card { display: grid; gap: 10px; padding: 24px; background: #11161d; border-radius: 12px; width: min(320px, 90vw); }
.card h1 { margin: 0 0 8px; font-size: 18px; }
.err { color: #ff6b6b; min-height: 1em; margin: 0; font-size: 13px; }
```

- [ ] **Step 6: Commit**

```bash
git add claude-term/server/static.js claude-term/public/
git commit -m "feat(claude-term): static xterm page, session UI, snippet chips, login"
```

---

### Task 9: HTTP server wiring (routes + auth + WS upgrade)

**Files:**
- Create: `claude-term/server/http.js`, `claude-term/server/index.js`
- Test: `claude-term/test/http.test.js` (dev-box runnable: tmux calls are stubbed via a test hook)

**Interfaces:**
- Consumes: everything above (`loadConfig/assertConfig`, `createAuth/parseCookie`, `loadSnippets`, sessions API, `attachSession`, `serveStatic`).
- Produces: `createServer({config, auth, deps}) → http.Server` with a `ws` upgrade handler; `deps` injects `{listSessions, createSession, killSession, hasSession, listDirs, attachSession}` so routes are testable without tmux.

- [ ] **Step 1: Write the failing test** `claude-term/test/http.test.js`

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/http.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `claude-term/server/http.js`**

```js
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
function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => (b += c));
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
      if (!session || !(await deps.hasSession({ name: session }))) {
        ws.close(1008, 'no such session');
        return;
      }
      deps.attachSession(ws, session);
    });
  });

  return server;
}
```

- [ ] **Step 4: Write `claude-term/server/index.js`**

```js
import { loadConfig, assertConfig } from './config.js';
import { createAuth } from './auth.js';
import { createServer } from './http.js';
import { listSessions, createSession, killSession, hasSession } from './sessions.js';
import { attachSession } from './pty-bridge.js';
import { readdir } from 'node:fs/promises';
import path from 'node:path';

const config = assertConfig(loadConfig()); // throws + exits non-zero if no secret (I1/AC1)
const auth = createAuth(config.secret);

async function listDirs(workspace) {
  try {
    const ents = await readdir(workspace, { withFileTypes: true });
    return ents.filter((e) => e.isDirectory()).map((e) => path.join(workspace, e.name));
  } catch { return []; }
}

const server = createServer({
  config, auth,
  deps: { listSessions, createSession, killSession, hasSession, listDirs, attachSession },
});

server.listen(config.port, () => {
  console.log(`claude-term on http://10.0.0.88:${config.port} (LAN, secret-gated)`);
});
```

- [ ] **Step 5: Run test to verify it passes**

Run: `node --test test/http.test.js`
Expected: PASS (5 tests). Then run the whole suite: `node --test` → all dev-box tests green.

- [ ] **Step 6: Commit**

```bash
git add claude-term/server/http.js claude-term/server/index.js claude-term/test/http.test.js
git commit -m "feat(claude-term): http routes, auth-gated API + WS upgrade, server entry (AC1/AC2/I1)"
```

---

### Task 10: Dockerfile (arm64, claude-code + tmux)

**Files:**
- Create: `claude-term/Dockerfile`

**Interfaces:**
- Produces: an arm64 image that installs app deps + `@anthropic-ai/claude-code` + `tmux` + `git` + `ripgrep`, runs as non-root `claude`, ENTRYPOINT the Node server.

- [ ] **Step 1: Write `claude-term/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
# claude-term — single-stage arm64 on glibc bookworm (D4/I7). kernel 4.9.141 +
# musl trips ENOSYS; glibc 2.36 degrades instead. Digest is node:20-bookworm-slim
# linux/arm64 (same pin as shield-c2). Fallback node:18-bullseye-slim (logged).
FROM --platform=linux/arm64 node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df

# OS deps: tmux (sessions), git + ripgrep (Claude Code), ca-certificates (TLS).
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux git ripgrep ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root user owns the app and runs Claude Code (I8).
RUN useradd -m -u 1000 claude
WORKDIR /app

# App deps (node-pty prebuilt fetched here) + Claude Code CLI on PATH.
COPY package.json ./
RUN npm install --no-audit --no-fund --omit=dev \
    && npm install -g @anthropic-ai/claude-code

COPY server ./server
COPY public ./public
COPY snippets.json ./snippets.json

# /data/claude (workspace) + /home/claude/.claude (creds vol) are writable by claude.
RUN mkdir -p /data/claude && chown -R claude:claude /app /data/claude /home/claude
USER claude

ENV CLAUDE_TERM_PORT=7777 \
    CLAUDE_TERM_WORKSPACE=/data/claude \
    CLAUDE_TERM_SNIPPETS=/data/claude/snippets.json \
    NODE_ENV=production
EXPOSE 7777
ENTRYPOINT ["node", "server/index.js"]
```

- [ ] **Step 2: Verify the build context is self-consistent (dev box, no Docker needed)**

Run (from `claude-term/`): `node -e "require('fs').accessSync('server/index.js'); require('fs').accessSync('public/index.html'); console.log('context ok')"`
Expected: `context ok`. (The real arm64 build runs on the Shield in Task 14 — **R2** node-pty / **AC12** ENOSYS are verified there.)

- [ ] **Step 3: Commit**

```bash
git add claude-term/Dockerfile
git commit -m "feat(claude-term): arm64 Dockerfile (claude-code + tmux + ripgrep, non-root, digest-pinned)"
```

---

### Task 11: Launcher + env template

**Files:**
- Create: `docker-bringup/claude-term.sh`, `docker-bringup/claude-term.env.example`
- Modify: the repo `.gitignore` (add `docker-bringup/claude-term.env`)

**Interfaces:**
- Produces: an idempotent launcher mirroring `c2.sh`: port-7777 assert, build-or-load, `--network host`, `--restart=always`, rw `/data/claude` + named `claude-home` volume → `/home/claude/.claude`, **no** docker socket; reads `CLAUDE_TERM_SECRET` + `CLAUDE_CODE_OAUTH_TOKEN` from a sourced untracked `claude-term.env`.

- [ ] **Step 1: Write `docker-bringup/claude-term.env.example`**

```sh
# Copy to claude-term.env (gitignored) and fill in. Sourced by claude-term.sh.
# Generate the token on the PC: `claude setup-token` (subscription-backed, ~1yr).
CLAUDE_TERM_SECRET=change-me-LAN-passphrase
CLAUDE_CODE_OAUTH_TOKEN=
```

- [ ] **Step 2: Write `docker-bringup/claude-term.sh`**

```sh
#!/system/bin/sh
# Bring up claude-term: phone-driven Claude Code web terminal on the Shield,
# port 7777 (D5). Host networking (bridge dead on this kernel, I4) -> reachable
# at http://10.0.0.88:7777. Workspace /data/claude is the ONLY writable host
# mount besides the ~/.claude creds volume (I2); NO docker socket (I9).
# Secret + OAuth token come from a sourced untracked claude-term.env (I11).
# --restart=always = returns when dockerd does. Idempotent: re-run replaces it.
set -e

HERE=$(dirname "$0")
[ -f "$HERE/claude-term.env" ] && . "$HERE/claude-term.env"

BB=/data/docker/bin/busybox
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
IMG=claude-term:latest
NAME=claude-term
PORT=${CLAUDE_TERM_PORT:-7777}
CTX=${CLAUDE_TERM_CTX:-/data/docker/claude-term}
VOL=claude-home

echo "=== fail-closed: secret must be set (I1) ==="
[ -n "$CLAUDE_TERM_SECRET" ] || { echo "FATAL: CLAUDE_TERM_SECRET unset (source claude-term.env)"; exit 1; }
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || echo "WARN: CLAUDE_CODE_OAUTH_TOKEN empty — Claude will demand /login (R3)"

echo "=== dockerd reachable? ==="
$DOCKER version --format 'server {{.Server.Version}}' || { echo "FATAL: dockerd not responding"; exit 1; }

echo "=== drop any previous $NAME FIRST (frees the port on re-run) ==="
$DOCKER rm -f $NAME 2>/dev/null || true

echo "=== assert port $PORT free (vs 8888 c2 / 3001 kuma) ==="
if $BB netstat -ltn 2>/dev/null | $BB grep -qE "[:.]$PORT[[:space:]]"; then
  echo "FATAL: port $PORT already in use"; exit 1
fi
echo "port $PORT free"

echo "=== obtain image $IMG (load tar, else build from $CTX) ==="
if $DOCKER image inspect $IMG >/dev/null 2>&1; then echo "image present"
elif [ -f /data/docker/claude-term.tar ]; then $DOCKER load -i /data/docker/claude-term.tar
elif [ -d "$CTX" ]; then
  echo "building from $CTX (classic builder, host net for DNS)"
  DOCKER_BUILDKIT=0 $DOCKER build --network=host -t $IMG "$CTX"
else echo "FATAL: no image, no tar, no context at $CTX"; exit 1
fi

echo "=== run $NAME (host net, rw /data/claude + creds vol, NO socket, port $PORT) ==="
$DOCKER run -d \
  --name $NAME \
  --restart=always \
  --network host \
  -e CLAUDE_TERM_PORT=$PORT \
  -e CLAUDE_TERM_SECRET="$CLAUDE_TERM_SECRET" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  -e CLAUDE_TERM_WORKSPACE=/data/claude \
  -e CLAUDE_TERM_SNIPPETS=/data/claude/snippets.json \
  -v /data/claude:/data/claude \
  -v $VOL:/home/claude/.claude \
  $IMG

echo "=== container state ==="
$DOCKER ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo "claude-term up at http://10.0.0.88:$PORT  (secret-gated, LAN only)"
```

- [ ] **Step 3: Add the real env file to `.gitignore`**

Append to the repo root `.gitignore` (the one that already excludes `node_modules`/build):

```
# claude-term local secret env (NEVER commit — I11)
docker-bringup/claude-term.env
```

- [ ] **Step 4: Verify the launcher is valid shell + secret-free (dev box)**

Run: `sh -n docker-bringup/claude-term.sh && echo "syntax ok"`
Run: `grep -nE 'CLAUDE_TERM_SECRET=[^"$]|OAUTH_TOKEN=sk' docker-bringup/claude-term.sh || echo "no hardcoded secrets"`
Expected: `syntax ok` then `no hardcoded secrets`.

- [ ] **Step 5: Commit**

```bash
git add docker-bringup/claude-term.sh docker-bringup/claude-term.env.example .gitignore
git commit -m "feat(claude-term): on-Shield launcher (host net, no socket, creds vol) + env template"
```

---

### Task 12: shield-c2 "Claude Code" launch link (AC15)

**Files:**
- Modify: the shield-c2 header/nav component (locate the existing nav/header in `shield-c2/src/`)

**Interfaces:**
- Produces: a visible link/card in the dashboard pointing at `http://10.0.0.88:7777` labelled "Claude Code". No deeper coupling (the dashboard is just a launcher).

- [ ] **Step 1: Locate the dashboard's header/nav markup**

Run: `grep -rn "shield-c2\|<header\|<nav\|Containers" shield-c2/src/routes/+page.svelte | head`
Identify where top-level nav/cards render.

- [ ] **Step 2: Add the launch link** (in the dashboard header, near the title)

```svelte
<a class="claude-link" href="http://10.0.0.88:7777" target="_blank" rel="noopener">🤖 Claude Code →</a>
```
with minimal styling consistent with the existing cards (reuse an existing class if present; otherwise a small `.claude-link { ... }` rule matching the dashboard palette).

- [ ] **Step 3: Verify it builds (dev box)**

Run: `cd shield-c2 && npm run build && echo "c2 build ok"`
Expected: build succeeds; the link is present in the output. (Reachability of `:7777` is confirmed in Task 14 once claude-term is up.)

- [ ] **Step 4: Commit**

```bash
git add shield-c2/src
git commit -m "feat(shield-c2): Claude Code launch link to :7777 (AC15)"
```

---

### Task 13: Threat-model section

**Files:**
- Modify: `docs/THREAT-MODEL.md`

- [ ] **Step 1: Append a `claude-term` section** documenting: a full root-capable-in-container shell behind a single shared-secret gate on plain-HTTP LAN; blast radius = `/data/claude` + the Claude OAuth token + LAN reach; mitigations = fail-closed auth (I1), workspace-confined mounts (I2/I3), non-root in-container user (I8), no docker socket (I9); accepted risks = cleartext secret on trusted LAN, tmux sessions don't survive reboot (I6); upgrade path = HTTPS + per-user auth.

```markdown
## claude-term (`:7777`)

`claude-term` serves an interactive Claude Code shell (and a login shell behind
it) to any LAN browser that knows one shared passphrase, over plain HTTP.

- **Blast radius:** read/write within `/data/claude`; the Claude `CLAUDE_CODE_OAUTH_TOKEN`
  (subscription-backed); and whatever the LAN is reachable from the container
  (`--network host`). The docker socket is **not** mounted (I9), so — unlike
  `shield-c2` — it cannot control other containers or the host daemon.
- **Controls:** fail-closed shared-secret gate on every route incl. the WS upgrade
  (I1); writable mounts limited to `/data/claude` + the `~/.claude` creds volume
  (I2); new-session `cwd` confined under the workspace (I3); server + `claude` run
  as non-root `claude` uid 1000 (I8); secret + token via env only, never in image
  or git (I10/I11).
- **Accepted risks:** the passphrase crosses the LAN in cleartext (trusted home
  LAN); tmux sessions die on container restart / Shield reboot (I6).
- **Upgrade path:** terminate TLS (HTTPS) and move to per-user auth.
```

- [ ] **Step 2: Commit**

```bash
git add docs/THREAT-MODEL.md
git commit -m "docs(threat-model): add claude-term section (gate, blast radius, upgrade path)"
```

---

### Task 14: On-Shield deploy + acceptance verification (the device gauntlet)

> This task runs **on/against the Shield** (10.0.0.88). It resolves the spec's R1–R5 risks and the §6 acceptance tests T1–T14. Prereqs (spec §8) must be done first.

**Files:** none new — this is deploy + verify. Record results in `docs/THREAT-MODEL.md`-adjacent notes or a short `docs/claude-term-bringup.md` if useful.

- [ ] **Step 1: Prereqs**
  - On the PC: `claude setup-token` → paste into `docker-bringup/claude-term.env` as `CLAUDE_CODE_OAUTH_TOKEN`; set `CLAUDE_TERM_SECRET`.
  - Transfer the `NVIDIAShield` tree (or at least `claude-term/` + `docker-bringup/`) to the Shield at `/data/docker/claude-term` (build context) — choose a mechanism (bare repo over LAN / `git bundle` + `adb push` / private remote). No git remote exists yet (spec §8).

- [ ] **Step 2: Build + launch on the Shield**

Run (on the Shield): `sh docker-bringup/claude-term.sh`
Expected: secret assertion passes, image builds (classic builder, host net), container runs, `docker ps` shows `claude-term` Up. If `node-pty` fails to load (**R2**) → switch the Dockerfile base to `node:18-bullseye-slim` (logged exception) OR add a build stage compiling node-pty from source; rebuild.

- [ ] **Step 3: Run the scripted acceptance tests (spec §6, from another LAN host)**

Run T1–T9 verbatim from `SPEC-claude-term.md` §6 with `BASE=http://10.0.0.88:7777` and `CLAUDE_TERM_SECRET` exported. Each must exit 0:
  - T1 fail-closed auth (AC1) · T2 session lifecycle (AC2) · T3 cwd confinement (AC3) · T4 snippets (AC8) · T5 no docker socket (AC9) · T6 workspace-only writes (AC10) · T7 runs on 4.9 / no ENOSYS (AC12) · T8 host-net + restart (AC13) · T9 no secrets (AC14).
  - Also AC1 empty-secret variant: `docker run ... -e CLAUDE_TERM_SECRET= ...` exits non-zero.

- [ ] **Step 4: Manual browser checks on the phone (spec §6 T10–T14)**
  - T10 attach + live I/O + resize (AC4) · T11 reattach persistence after tab kill (AC5/I6) · T12 multi-line snippet prepends unsent (**R1**/AC6) · T13 submit-flag chip fires in one tap (AC7) · T14 `claude` reaches an authed prompt with no `/login` (**R3**/AC11).
  - If **R1** fails (bracketed paste not honored): fall back to plain-input injection + single-line snippets (documented fallback) and re-test T12/T13.
  - If **R3** fails: bootstrap `~/.claude` once interactively into the `claude-home` volume, then rely on the persisted volume.

- [ ] **Step 5: Confirm the dashboard launch path**
  - From the phone, open `http://10.0.0.88:8888`, click **🤖 Claude Code →**, land on the claude-term login, unlock, create/attach a session (AC15 end-to-end).

- [ ] **Step 6: Commit any device-driven fixes + a short bringup note**

```bash
git add -A
git commit -m "chore(claude-term): on-Shield bringup — R1-R5 resolved, §6 acceptance passing"
```

- [ ] **Step 7: Update the ledger / mark spec acceptance**
  - Record which ACs passed with evidence; note any logged exceptions (base-image fallback, R1/R3 fallbacks). A `pass` without its evidence is treated as not-done (spec §6).

---

## Self-Review

**1. Spec coverage** (each spec section → task):
- A1–A5 (access/launch/sessions/snippets/auth) → Tasks 8/9/5/4/3,9. D1–D8 → 9/8,9/5/10/9/3/6/10. I1–I11 → 2,3,9 / 9,10 / 5 / 9 / 8 / 6,9 / 9 / 10 / 9 / 10,11 / 11. §3 interface (auth/sessions/snippets/WS routes) → 9. §5 ACs → AC1-3,8,9,10,12,13,14 scripted in 14/step3; AC4-7,11 manual in 14/step4; AC15 in 12 + 14/step5. §9 deliverables → app(1-9), Dockerfile(10), launcher(11), snippets(4), c2 link(12), threat-model(13). §10 git preflight → 11 (gitignore env). **No gaps.**
- R1 (bracketed paste) → 6 + 14/T12. R2 (node-pty arm64) → 1/step5 + 14/step2. R3 (headless OAuth) → 11 warn + 14/T14. R4 (PTY device) → 14. R5 (version drift) → optional pin note in Dockerfile (Task 10) — **add a pin only if Task 14 shows drift breaks input** (YAGNI until observed).
- **§8 prereqs** (OAuth token, secret, repo transfer) → 14/step1, explicitly flagged as deploy-time.

**2. Placeholder scan:** No "TBD/TODO/handle edge cases" — every code step carries real code; device-only steps carry the exact spec §6 commands rather than vague intent. ✔

**3. Type consistency:** `exec` injection shape `(cmd, args) → {stdout,stderr}` consistent across `sessions.js` + its tests; `attachSession(ws, name, {spawn})` consistent between Task 7 and Task 9 `deps`; `createSession({name,cwd,workspace,exec})` signature matches the Task 9 call (which passes `{name,cwd,workspace}`, `exec` defaulted) and the Task 5 tests. `COOKIE_NAME`/`parseCookie`/`createAuth` consistent across auth + http. ✔

---

## Execution Handoff

Plan complete. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration. Good fit: Tasks 2–7 are independent, well-bounded modules.
2. **Inline Execution** — execute in this session via executing-plans, batch with checkpoints.

Tasks 1–13 are dev-box buildable now; **Task 14 is the on-Shield gauntlet** and needs the prereqs (OAuth token, secret, repo transfer) before it can run.
