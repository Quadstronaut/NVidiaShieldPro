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
