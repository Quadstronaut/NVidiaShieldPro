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
