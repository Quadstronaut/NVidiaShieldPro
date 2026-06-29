// Session store over Claude Code's own on-disk transcripts (spec D2). REPLACES
// the v1 tmux session manager. Sessions live as
//   $HOME/.claude/projects/<encoded-cwd>/<session-id>.jsonl
// inside the persistence volume, so they survive container restart AND Shield
// reboot (NI5) — strictly better than v1's tmux sessions, which died on restart.
import { readdir, readFile, stat, unlink, realpath, open } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

const HOME = process.env.HOME || '/home/claude';
const PROJECTS = path.join(HOME, '.claude', 'projects');
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function validId(id) {
  return typeof id === 'string' && UUID_RE.test(id);
}

// I3 (inherited): resolve symlinks, reject anything outside the workspace root.
export async function confineCwd(cwd, workspace) {
  const wsReal = await realpath(workspace);
  let target;
  try { target = await realpath(cwd); }
  catch { throw new Error('cwd does not resolve to an existing path'); }
  const rel = path.relative(wsReal, target);
  if (rel === '') return target;
  if (rel.startsWith('..') || path.isAbsolute(rel)) throw new Error('cwd escapes the workspace');
  return target;
}

// Read up to `bytes` from a file (bounded — listing must not slurp huge logs).
async function readHead(file, bytes = 16384) {
  const fh = await open(file, 'r');
  try {
    const b = Buffer.alloc(bytes);
    const { bytesRead } = await fh.read(b, 0, bytes, 0);
    return b.subarray(0, bytesRead).toString('utf8');
  } finally { await fh.close(); }
}

// Find the .jsonl path for a session id by scanning project dirs (robust against
// cwd-encoding quirks — we match the file, not reconstruct the dir name).
async function findTranscript(id) {
  let dirs;
  try { dirs = await readdir(PROJECTS, { withFileTypes: true }); } catch { return null; }
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const file = path.join(PROJECTS, d.name, `${id}.jsonl`);
    try { await stat(file); return file; } catch { /* not here */ }
  }
  return null;
}

// First user prompt → a short title; any record's cwd → the working dir.
function summarizeHead(text) {
  let title = '', cwd = '';
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    let r; try { r = JSON.parse(line); } catch { break; } // partial trailing line
    if (!cwd && typeof r.cwd === 'string') cwd = r.cwd;
    if (!title && r.type === 'user' && typeof r.message?.content === 'string') {
      title = r.message.content.replace(/\s+/g, ' ').trim().slice(0, 80);
    }
    if (title && cwd) break;
  }
  return { title, cwd };
}

// List every persisted session, newest first. The hub layers live state
// (running / attachedClients) on top — see hub.listSessions().
export async function listSessions() {
  let dirs;
  try { dirs = await readdir(PROJECTS, { withFileTypes: true }); } catch { return []; }
  const out = [];
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const dir = path.join(PROJECTS, d.name);
    let files;
    try { files = await readdir(dir); } catch { continue; }
    for (const f of files) {
      if (!f.endsWith('.jsonl')) continue;
      const id = f.slice(0, -'.jsonl'.length);
      if (!validId(id)) continue;
      const file = path.join(dir, f);
      let mtime = 0, head = '';
      try { mtime = (await stat(file)).mtimeMs; } catch { /* keep 0 */ }
      try { head = await readHead(file); } catch { /* keep '' */ }
      const { title, cwd } = summarizeHead(head);
      out.push({
        id,
        title: title || '(new session)',
        cwd: cwd || decodeDir(d.name),
        lastActive: mtime,
      });
    }
  }
  out.sort((a, b) => b.lastActive - a.lastActive);
  return out;
}

// Best-effort decode of an encoded project dir back to a path (fallback only;
// the real cwd is read from the transcript when present).
function decodeDir(name) {
  return name.startsWith('-') ? name.replace(/-/g, '/') : name;
}

// Parse a session's .jsonl into normalized WS events for replay-on-attach. Mirrors
// agent.js's assistant/user mapping, but over stored records (whose user content
// is a plain string for real turns, an array of tool_result for tool returns).
export async function loadTranscript(id) {
  const file = await findTranscript(id);
  if (!file) return [];
  let raw;
  try { raw = await readFile(file, 'utf8'); } catch { return []; }
  const events = [];
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let r; try { r = JSON.parse(line); } catch { continue; }
    if (r.type === 'user') {
      const c = r.message?.content;
      if (typeof c === 'string') {
        if (c.trim()) events.push({ type: 'user_message', text: c });
      } else if (Array.isArray(c)) {
        for (const b of c) {
          if (b.type === 'tool_result') {
            events.push({ type: 'tool_result', id: b.tool_use_id, content: blockText(b.content), isError: !!b.is_error });
          } else if (b.type === 'text' && b.text) {
            events.push({ type: 'user_message', text: b.text });
          }
        }
      }
    } else if (r.type === 'assistant') {
      for (const b of (r.message?.content || [])) {
        if (b.type === 'text' && b.text) events.push({ type: 'assistant_message', text: b.text });
        else if (b.type === 'tool_use') events.push({ type: 'tool_use', id: b.id, name: b.name, input: b.input || {} });
        else if (b.type === 'thinking' && b.thinking) events.push({ type: 'assistant_thinking', text: b.thinking });
      }
    }
  }
  return events;
}

function blockText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((c) => (typeof c === 'string' ? c : c.text || '')).join('\n');
  return '';
}

// Has `claude` already persisted a transcript for this id? Decides whether the
// next turn must CREATE the session (--session-id) or RESUME it (--resume) — see
// hub.startTurn / agent.runTurn. Disk-truth, so it stays correct across restarts.
export async function transcriptExists(id) {
  return (await findTranscript(id)) !== null;
}

// The working dir a persisted session was created in (read from its transcript),
// so a reattach after restart resumes `claude` in the right cwd. null if unknown.
export async function readSessionCwd(id) {
  const file = await findTranscript(id);
  if (!file) return null;
  try { return summarizeHead(await readHead(file)).cwd || null; } catch { return null; }
}

// Allocate a new session: validate the cwd, mint a uuid. No Claude process spawns
// until the first user message (the .jsonl appears on the first turn).
export async function createSession({ cwd, workspace }) {
  const safeCwd = await confineCwd(cwd, workspace);
  return { id: randomUUID(), cwd: safeCwd };
}

// Delete a session's transcript. Returns true if a file was removed.
export async function deleteSession(id) {
  if (!validId(id)) throw new Error('invalid session id');
  const file = await findTranscript(id);
  if (!file) return false;
  await unlink(file);
  return true;
}
