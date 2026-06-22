// Central runtime config. All values come from the environment so the launcher
// and Dockerfile fully control behaviour.

function num(v, d) {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

export function loadConfig(env = process.env) {
  return {
    port: num(env.CLAUDE_TERM_PORT, 7777),
    secret: env.CLAUDE_TERM_SECRET ?? '',
    snippetsPath: env.CLAUDE_TERM_SNIPPETS || '/data/claude/snippets.json',
    workspace: env.CLAUDE_TERM_WORKSPACE || '/data/claude',
    // Presence only matters to the launcher/Claude; the server passes it through.
    oauthToken: env.CLAUDE_CODE_OAUTH_TOKEN ?? '',
    // Open mode: serve with NO passphrase gate (LAN-trusted, like shield-c2).
    noAuth: env.CLAUDE_TERM_NO_AUTH === '1',
  };
}

// Refuse to start without a gate secret — UNLESS open mode is explicitly set
// (CLAUDE_TERM_NO_AUTH=1), in which case the app serves with no passphrase.
export function assertConfig(cfg) {
  if (!cfg.noAuth && !cfg.secret) {
    throw new Error('CLAUDE_TERM_SECRET is required (or set CLAUDE_TERM_NO_AUTH=1) — refusing to start.');
  }
  return cfg;
}
