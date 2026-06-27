import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { normalize, runTurn } from '../server/agent.js';

// --- normalize(): the observed CC 2.1.185 event shapes -> WS events ---

test('system/init -> status with model + sessionId + slashCommands', () => {
  const out = normalize({ type: 'system', subtype: 'init', session_id: 'sid', model: 'claude-sonnet-4-6', slash_commands: ['clear', 'compact'] });
  assert.deepEqual(out, [{ type: 'status', running: true, model: 'claude-sonnet-4-6', sessionId: 'sid', slashCommands: ['clear', 'compact'] }]);
});

test('stream_event text_delta -> ephemeral assistant_delta', () => {
  const out = normalize({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hel' } } });
  assert.deepEqual(out, [{ type: 'assistant_delta', text: 'Hel', ephemeral: true }]);
});

test('stream_event input_json_delta -> nothing (card lands on assistant event)', () => {
  assert.deepEqual(normalize({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'input_json_delta', partial_json: '{' } } }), []);
});

test('assistant text + tool_use -> assistant_message + tool_use', () => {
  const out = normalize({ type: 'assistant', message: { content: [
    { type: 'text', text: "I'll run it." },
    { type: 'tool_use', id: 'tu1', name: 'Bash', input: { command: 'echo hi' } },
  ] } });
  assert.deepEqual(out, [
    { type: 'assistant_message', text: "I'll run it." },
    { type: 'tool_use', id: 'tu1', name: 'Bash', input: { command: 'echo hi' } },
  ]);
});

test('user tool_result (array content) -> tool_result with flattened text', () => {
  const out = normalize({ type: 'user', message: { content: [
    { type: 'tool_result', tool_use_id: 'tu1', content: [{ type: 'text', text: 'hi\n' }], is_error: false },
  ] } });
  assert.deepEqual(out, [{ type: 'tool_result', id: 'tu1', content: 'hi\n', isError: false }]);
});

test('result -> cost + contextLeftPct + idle status', () => {
  const out = normalize({
    type: 'result', subtype: 'success', total_cost_usd: 0.12, stop_reason: 'end_turn',
    usage: { input_tokens: 3, cache_read_input_tokens: 50000, cache_creation_input_tokens: 50000 },
    modelUsage: { 'claude-sonnet-4-6': { contextWindow: 200000 } },
  });
  assert.equal(out[0].type, 'result');
  assert.equal(out[0].costUsd, 0.12);
  assert.equal(out[0].contextLeftPct, 50); // 1 - 100003/200000 ~= 0.5
  assert.deepEqual(out[1], { type: 'status', running: false });
});

test('rate_limit_event and unknown -> ignored', () => {
  assert.deepEqual(normalize({ type: 'rate_limit_event' }), []);
  assert.deepEqual(normalize({ type: 'whatever' }), []);
});

// --- runTurn(): line-splitting, arg building, session id capture, interrupt ---

function fakeSpawn(lines, { exitCode = 0 } = {}) {
  const calls = {};
  const factory = (cmd, args) => {
    calls.cmd = cmd; calls.args = args;
    const proc = new EventEmitter();
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    proc.kill = () => { proc.killed = true; proc.emit('close', null, 'SIGTERM'); };
    queueMicrotask(() => {
      // Emit the canned NDJSON, split awkwardly across chunks to exercise buffering.
      const blob = lines.map((l) => JSON.stringify(l)).join('\n') + '\n';
      proc.stdout.emit('data', blob.slice(0, 10));
      proc.stdout.emit('data', blob.slice(10));
      proc.emit('close', exitCode, null);
    });
    return proc;
  };
  factory.calls = calls;
  return factory;
}

test('runTurn builds resume + bypass args and captures the session id', async () => {
  const spawn = fakeSpawn([
    { type: 'system', subtype: 'init', session_id: 'abc-123', model: 'm', slash_commands: [] },
    { type: 'assistant', message: { content: [{ type: 'text', text: 'PONG' }] }, session_id: 'abc-123' },
    { type: 'result', subtype: 'success', total_cost_usd: 0.01, stop_reason: 'end_turn', usage: {} },
  ]);
  const events = [];
  const { done } = runTurn({ cwd: '/data/claude', sessionId: 'abc-123', text: 'hi', onEvent: (e) => events.push(e), spawn });
  const res = await done;

  assert.equal(spawn.calls.cmd, 'claude');
  assert.ok(spawn.calls.args.includes('--dangerously-skip-permissions'));
  assert.deepEqual(spawn.calls.args.slice(0, 2), ['-p', 'hi']);
  assert.ok(spawn.calls.args.includes('--resume') && spawn.calls.args.includes('abc-123'));
  assert.equal(res.sessionId, 'abc-123');
  assert.ok(events.some((e) => e.type === 'assistant_message' && e.text === 'PONG'));
  assert.ok(events.some((e) => e.type === 'result'));
});

test('runTurn omits --resume for a new session and learns the id from init', async () => {
  const spawn = fakeSpawn([{ type: 'system', subtype: 'init', session_id: 'new-id', model: 'm', slash_commands: [] }]);
  const events = [];
  const { done } = runTurn({ cwd: '/data/claude', text: 'first', onEvent: (e) => events.push(e), spawn });
  const res = await done;
  assert.ok(!spawn.calls.args.includes('--resume'));
  assert.equal(res.sessionId, 'new-id');
});

test('kill() interrupts the turn (SIGTERM, no error event)', async () => {
  const spawn = (cmd, args) => {
    const proc = new EventEmitter();
    proc.stdout = new EventEmitter(); proc.stderr = new EventEmitter();
    proc.kill = () => proc.emit('close', null, 'SIGTERM');
    return proc;
  };
  const events = [];
  const { kill, done } = runTurn({ cwd: '/x', text: 'hi', onEvent: (e) => events.push(e), spawn });
  kill();
  const res = await done;
  assert.equal(res.interrupted, true);
  assert.ok(!events.some((e) => e.type === 'error'));
});
