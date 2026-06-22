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
