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

// tmux on this Android/kernel-4.9 build mangles a TAB separator in -F format
// output into '_' (verified on-device), so packing fields into one -F line yields
// e.g. "vtest_1_1700000000_0". Instead: list session NAMES alone (single field,
// no separator to corrupt), then fetch each session's fields with per-session
// display-message. The name stays clean and WS attach gets the right target.
export async function listSessions({ exec = defaultExec } = {}) {
  let names;
  try {
    const out = await exec('tmux', ['list-sessions', '-F', '#{session_name}']);
    names = out.stdout.split('\n').filter(Boolean);
  } catch {
    return []; // no server / no sessions
  }
  const sessions = [];
  for (const name of names) {
    let cwd = '', attached = false, windows = 0;
    try {
      const c = await exec('tmux', ['display-message', '-p', '-t', name, '#{pane_current_path}']);
      cwd = c.stdout.trim();
    } catch { /* leave blank */ }
    try {
      const a = await exec('tmux', ['display-message', '-p', '-t', name, '#{session_attached}']);
      attached = a.stdout.trim() === '1';
    } catch { /* default false */ }
    try {
      const w = await exec('tmux', ['display-message', '-p', '-t', name, '#{session_windows}']);
      windows = Number(w.stdout.trim()) || 0;
    } catch { /* default 0 */ }
    sessions.push({ name, windows, created: 0, attached, cwd });
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

export async function createSession({ name, cwd, workspace, launchCmd = 'claude', exec = defaultExec }) {
  if (!validName(name)) throw new Error(`invalid session name: ${name}`);
  const safeCwd = await confineCwd(cwd, workspace);
  // Shell-rooted, then auto-start Claude Code so exiting claude drops to a shell (D3).
  // launchCmd is typed verbatim into the shell (e.g. with --dangerously-skip-permissions).
  await exec('tmux', ['new-session', '-d', '-s', name, '-c', safeCwd]);
  await exec('tmux', ['send-keys', '-t', name, launchCmd, 'Enter']);
}

export async function killSession({ name, exec = defaultExec }) {
  await exec('tmux', ['kill-session', '-t', name]);
}
