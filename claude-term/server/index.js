import { loadConfig, assertConfig } from './config.js';
import { createAuth } from './auth.js';
import { createServer } from './http.js';
import { createHub } from './hub.js';
import { listDirs } from './dirs.js';

const config = assertConfig(loadConfig()); // throws + exits non-zero if no secret (I1/AC1)
const auth = createAuth(config.secret);

// The hub owns Claude Code turn-processes and fans events to attached clients.
// skipPermissions defaults on (NI3); remote control is on by default for every
// session (NI4) — there is no per-session enable.
const hub = createHub({ workspace: config.workspace, skipPermissions: config.skipPermissions });

const server = createServer({
  config, auth,
  deps: {
    listSessions: () => hub.listSessions(),
    createSession: (o) => hub.createSession(o),
    deleteSession: (id) => hub.deleteSession(id),
    attach: (ws, id) => hub.attach(ws, id),
    hasSession: (id) => hub.hasSession(id),
    // listDirs lives in its own module so it is testable. As an inline helper
    // here it had no test, which is how it silently stopped matching the
    // directory layout for a month while every other check reported green.
    listDirs,
  },
});

server.listen(config.port, () => {
  console.log(`claude-term v2 on http://${process.env.CLAUDE_TERM_HOST || '0.0.0.0'}:${config.port} (native Claude Code UI, LAN)`);
});
