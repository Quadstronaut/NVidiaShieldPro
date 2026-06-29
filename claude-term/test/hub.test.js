import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

// sessions.js reads HOME at import time, so set it BEFORE importing the hub.
const HOME = await mkdtemp(path.join(tmpdir(), 'cthome-'));
process.env.HOME = HOME;
// Real layout: ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl — transcripts
// live one level inside a per-project dir, which is what findTranscript scans.
const PROJECTS = path.join(HOME, '.claude', 'projects', '-some-encoded-cwd');
await mkdir(PROJECTS, { recursive: true });

const { createHub } = await import('../server/hub.js');

// A fake WS that records what the hub sends and lets the test drive messages.
function fakeWs() {
  const sent = [];
  const handlers = {};
  return {
    send: (s) => sent.push(JSON.parse(s)),
    on: (ev, fn) => { handlers[ev] = fn; },
    emit: (ev, ...a) => handlers[ev]?.(...a),
    sent,
  };
}

// Poll until a condition holds — startTurn awaits a real readdir, so a fixed
// number of ticks is racy (condition-based-waiting over arbitrary timeouts).
async function waitFor(fn, ms = 2000) {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await new Promise((r) => setImmediate(r));
  }
}

// A fake runTurn that records the `create` flag and finishes the turn at once.
function recordingRunTurn(log) {
  return ({ sessionId, create, onEvent }) => {
    log.push({ sessionId, create });
    onEvent({ type: 'status', running: false });
    return { proc: {}, kill() {}, done: Promise.resolve({ sessionId, ok: true }) };
  };
}

test('first turn of a fresh session CREATEs it; the next turn RESUMEs it', async () => {
  const log = [];
  const hub = createHub({ workspace: HOME, runTurn: recordingRunTurn(log) });
  const id = '11111111-2222-3333-4444-555555555555';
  hub.register({ id, cwd: HOME });

  const ws = fakeWs();
  await hub.attach(ws, id);

  // Turn 1: no .jsonl on disk -> must create with --session-id.
  ws.emit('message', JSON.stringify({ type: 'user_message', text: 'first' }));
  await waitFor(() => log.length >= 1);
  assert.deepEqual(log[0], { sessionId: id, create: true });

  // claude would now have written the transcript; simulate that, then turn 2.
  await writeFile(path.join(PROJECTS, `${id}.jsonl`), '{"type":"user"}\n');
  ws.emit('message', JSON.stringify({ type: 'user_message', text: 'second' }));
  await waitFor(() => log.length >= 2);
  assert.deepEqual(log[1], { sessionId: id, create: false }, 'second turn must resume, not re-create');
});

test('a turn on an ALREADY-persisted session RESUMEs from the very first turn', async () => {
  const log = [];
  const hub = createHub({ workspace: HOME, runTurn: recordingRunTurn(log) });
  const id = '99999999-8888-7777-6666-555555555555';
  await writeFile(path.join(PROJECTS, `${id}.jsonl`), '{"type":"user"}\n'); // pre-existing transcript

  const ws = fakeWs();
  await hub.attach(ws, id); // hydrate from disk
  ws.emit('message', JSON.stringify({ type: 'user_message', text: 'go' }));
  await waitFor(() => log.length >= 1);
  assert.deepEqual(log[0], { sessionId: id, create: false });
});

test.after(() => rm(HOME, { recursive: true, force: true }));
