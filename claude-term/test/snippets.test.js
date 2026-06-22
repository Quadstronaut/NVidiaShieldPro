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
