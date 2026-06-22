import { loadConfig, assertConfig } from './config.js';
import { createAuth } from './auth.js';
import { createServer } from './http.js';
import { listSessions, createSession, killSession, hasSession } from './sessions.js';
import { attachSession } from './pty-bridge.js';
import { readdir } from 'node:fs/promises';
import path from 'node:path';

const config = assertConfig(loadConfig()); // throws + exits non-zero if no secret (I1/AC1)
const auth = createAuth(config.secret);

async function listDirs(workspace) {
  // Always offer the workspace root first, so the new-session picker is never
  // empty (a fresh /data/claude has no subdirs -> you could never launch).
  const dirs = [workspace];
  try {
    const ents = await readdir(workspace, { withFileTypes: true });
    for (const e of ents) if (e.isDirectory()) dirs.push(path.join(workspace, e.name));
  } catch { /* keep just the root */ }
  return dirs;
}

const server = createServer({
  config, auth,
  deps: { listSessions, createSession, killSession, hasSession, listDirs, attachSession },
});

server.listen(config.port, () => {
  // FIX 7: use env var for host in log, not hardcoded IP
  console.log(`claude-term on http://${process.env.CLAUDE_TERM_HOST || '0.0.0.0'}:${config.port} (LAN, secret-gated)`);
});
