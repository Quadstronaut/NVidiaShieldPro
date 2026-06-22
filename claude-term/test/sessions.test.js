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
