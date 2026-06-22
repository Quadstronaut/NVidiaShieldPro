import crypto from 'node:crypto';

export const COOKIE_NAME = 'ct_session';

// In-memory token set (A5/D): tokens die on container restart — acceptable (I6).
export function createAuth(secret) {
  const tokens = new Set();
  return {
    // Constant-secret compare; empty secret can never authenticate (I1).
    check(attempt) {
      return secret.length > 0 && attempt === secret;
    },
    issue() {
      const t = crypto.randomBytes(32).toString('hex');
      tokens.add(t);
      return t;
    },
    valid(token) {
      return typeof token === 'string' && tokens.has(token);
    },
    revoke(token) {
      tokens.delete(token);
    },
  };
}

export function parseCookie(header, name = COOKIE_NAME) {
  if (!header) return null;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const k = part.slice(0, idx).trim();
    if (k === name) return decodeURIComponent(part.slice(idx + 1).trim());
  }
  return null;
}
