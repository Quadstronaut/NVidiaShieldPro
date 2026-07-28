import { readdir } from 'node:fs/promises';
import path from 'node:path';

// Depth cap. The layout is workspace/<CATEGORY>/<repo>, so 3 reaches every repo
// while stopping a stray deep tree from turning the picker into a full
// filesystem walk on every open.
export const MAX_DIR_DEPTH = 3;

/**
 * Working directories offered by the new-session picker.
 *
 * This was one readdir() of the workspace, which was right back when clones sat
 * flat under it. Phase 2 moved them to workspace/<CATEGORY>/<repo> and this was
 * never updated, so the picker offered six entries of which exactly one was a
 * git repo and NONE were among the 55 real projects. There was no path from the
 * UI into any repository the user wanted to work in -- the single reason
 * "use my Claude on the Shield" did not work.
 *
 * A directory containing .git is the unit of work: that is what a session's cwd
 * should be, and descending into one would bury the list in submodules and
 * vendored checkouts.
 *
 * Lives in its own module so it can be tested. While it was an inline helper in
 * index.js it had no test, and that is exactly how it silently stopped matching
 * the directory layout for a month.
 */
export async function listDirs(workspace) {
  const repos = [];
  const others = [];

  // Returns true if this subtree contained at least one repo.
  async function walk(dir, depth) {
    let ents;
    // Unreadable is reported as "contained something" so an inaccessible
    // directory is not then offered as a plain working dir.
    try { ents = await readdir(dir, { withFileTypes: true }); } catch { return true; }

    // .git may be a FILE (linked worktree, submodule), so test the name only.
    if (ents.some((e) => e.name === '.git')) { repos.push(dir); return true; }
    if (depth >= MAX_DIR_DEPTH) return false;

    let found = false;
    for (const e of ents) {
      if (!e.isDirectory()) continue;
      if (e.name.startsWith('.') || e.name === 'node_modules') continue;
      if (await walk(path.join(dir, e.name), depth + 1)) found = true;
    }
    return found;
  }

  try {
    const ents = await readdir(workspace, { withFileTypes: true });
    for (const e of ents) {
      if (!e.isDirectory()) continue;
      if (e.name.startsWith('.') || e.name === 'node_modules') continue;
      const p = path.join(workspace, e.name);
      // Plain directories (scratch, work) stay offered -- but only when they
      // hold no repos, so a category folder never appears alongside its own
      // children as though it were somewhere to work.
      if (!(await walk(p, 1))) others.push(p);
    }
  } catch { /* fall through to just the root */ }

  const byPath = (a, b) => a.localeCompare(b);
  // Root first so the picker is never empty, then repos (the actual work),
  // then the scratch dirs.
  return [workspace, ...repos.sort(byPath), ...others.sort(byPath)];
}
