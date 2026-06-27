import { loadConfig, assertConfig } from './config.js';
import { createAuth } from './auth.js';
import { createServer } from './http.js';
import { createHub } from './hub.js';
import { readdir } from 'node:fs/promises';
import path from 'node:path';

const config = assertConfig(loadConfig()); // throws + exits non-zero if no secret (I1/AC1)
const auth = createAuth(config.secret);

// The hub owns Claude Code turn-processes and fans events to attached clients.
// skipPermissions defaults on (NI3); remote control is on by default for every
// session (NI4) — there is no per-session enable.
const hub = createHub({ workspace: config.workspace, skipPermissions: config.skipPermissions });

async function listDirs(workspace) {
  // Always offer the workspace root first so the new-session picker is never empty.
  const dirs = [workspace];
  try {
    const ents = await readdir(workspace, { withFileTypes: true });
    for (const e of ents) if (e.isDirectory()) dirs.push(path.join(workspace, e.name));
  } catch { /* keep just the root */ }
  return dirs;
}

const server = createServer({
  config, auth,
  deps: {
    listSessions: () => hub.listSessions(),
    createSession: (o) => hub.createSession(o),
    deleteSession: (id) => hub.deleteSession(id),
    attach: (ws, id) => hub.attach(ws, id),
    hasSession: (id) => hub.hasSession(id),
    listDirs,
  },
});

server.listen(config.port, () => {
  console.log(`claude-term v2 on http://${process.env.CLAUDE_TERM_HOST || '0.0.0.0'}:${config.port} (native Claude Code UI, LAN)`);
});
