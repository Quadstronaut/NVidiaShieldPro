import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { listDirs } from '../server/dirs.js';

// Regression cover for the defect that made claude-term unusable: listDirs did
// one readdir() of the workspace, so after clones moved to
// workspace/<CATEGORY>/<repo> the new-session picker offered no repository at
// all. Every assertion below is a property the phone UI depends on.

const sep = (p) => p.split(path.sep).join('/');

async function fixture() {
  const ws = await mkdtemp(path.join(tmpdir(), 'ct-dirs-'));
  const mk = async (rel) => mkdir(path.join(ws, rel), { recursive: true });
  // workspace/<CATEGORY>/<repo>, the real layout
  await mk('GIT/LOCAL-mod/NVIDIAShield/.git');
  await mk('GIT/LOCAL-mod/Archangel/.git');
  await mk('GIT/BUSINESS-pursuits/Starhold/.git');
  // a repo that lives OUTSIDE GIT/ on purpose
  await mk('book-writing/.git');
  // plain working dirs, no repos
  await mk('scratch');
  await mk('work');
  // noise that must never appear
  await mk('GIT/LOCAL-mod/NVIDIAShield/node_modules/somedep/.git');
  await mk('.hidden/repo/.git');
  return ws;
}

test('finds every repo at workspace/<CATEGORY>/<repo>', async (t) => {
  const ws = await fixture();
  t.after(() => rm(ws, { recursive: true, force: true }));
  const out = (await listDirs(ws)).map(sep);
  const w = sep(ws);
  for (const r of ['GIT/LOCAL-mod/NVIDIAShield', 'GIT/LOCAL-mod/Archangel', 'GIT/BUSINESS-pursuits/Starhold']) {
    assert.ok(out.includes(`${w}/${r}`), `missing repo: ${r}`);
  }
});

test('offers the workspace root first so the picker is never empty', async (t) => {
  const ws = await fixture();
  t.after(() => rm(ws, { recursive: true, force: true }));
  const out = await listDirs(ws);
  assert.equal(out[0], ws);
});

test('includes a repo that lives outside the GIT tree', async (t) => {
  const ws = await fixture();
  t.after(() => rm(ws, { recursive: true, force: true }));
  const out = (await listDirs(ws)).map(sep);
  assert.ok(out.includes(`${sep(ws)}/book-writing`));
});

test('does NOT offer container dirs that are not themselves repos', async (t) => {
  // GIT and GIT/LOCAL-mod hold repos but are not repos. Offering them is how a
  // session lands one or two levels above the project and quietly does nothing
  // useful -- the old picker's only non-root git-ish option was exactly this.
  const ws = await fixture();
  t.after(() => rm(ws, { recursive: true, force: true }));
  const out = (await listDirs(ws)).map(sep);
  const w = sep(ws);
  assert.ok(!out.includes(`${w}/GIT`));
  assert.ok(!out.includes(`${w}/GIT/LOCAL-mod`));
});

test('keeps plain non-repo working dirs', async (t) => {
  const ws = await fixture();
  t.after(() => rm(ws, { recursive: true, force: true }));
  const out = (await listDirs(ws)).map(sep);
  const w = sep(ws);
  assert.ok(out.includes(`${w}/scratch`));
  assert.ok(out.includes(`${w}/work`));
});

test('never descends into a repo, node_modules, or dotdirs', async (t) => {
  const ws = await fixture();
  t.after(() => rm(ws, { recursive: true, force: true }));
  const out = (await listDirs(ws)).map(sep);
  assert.ok(!out.some((d) => d.includes('node_modules')), 'walked node_modules');
  assert.ok(!out.some((d) => d.includes('/.hidden')), 'walked a dotdir');
});

test('.git as a FILE (linked worktree / submodule) still counts as a repo', async (t) => {
  const ws = await mkdtemp(path.join(tmpdir(), 'ct-dirs-wt-'));
  t.after(() => rm(ws, { recursive: true, force: true }));
  await mkdir(path.join(ws, 'GIT/CAT/linked'), { recursive: true });
  await writeFile(path.join(ws, 'GIT/CAT/linked/.git'), 'gitdir: /elsewhere/.git/worktrees/linked\n');
  const out = (await listDirs(ws)).map(sep);
  assert.ok(out.includes(`${sep(ws)}/GIT/CAT/linked`));
});

test('an empty or missing workspace still yields the root, never a crash', async (t) => {
  const ws = await mkdtemp(path.join(tmpdir(), 'ct-dirs-empty-'));
  t.after(() => rm(ws, { recursive: true, force: true }));
  assert.deepEqual(await listDirs(ws), [ws]);
  assert.deepEqual(await listDirs(path.join(ws, 'does-not-exist')), [path.join(ws, 'does-not-exist')]);
});
