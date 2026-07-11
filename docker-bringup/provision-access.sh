#!/bin/sh
# provision-access.sh — RUN INSIDE the claude-term container as user `claude`.
# One-time, idempotent setup of the container's on-device credentials (all in the
# persistent claude-home volume, NONE in any repo):
#   1) GitHub: gh auth from a PAT (stdin), + git credential helper for HTTPS push.
#   2) SSH keys: a dedicated ed25519 for Starhold and one for the qflix host,
#      generated HERE so the private halves never transit a network or touch GitHub.
#   3) ~/.ssh/config aliases so `ssh starhold-dedi|starhold-vps|qflix` just work.
#
# Invoke (topology + PAT injected via the environment from DEVIL's untracked
# shield-access.env — NONE of it is in this file, which is public):
#   docker exec -u claude \
#     -e GH_PAT=<pat> \
#     -e STARHOLD_USER=.. -e STARHOLD_DEDI=.. -e STARHOLD_VPS=.. \
#     -e QFLIX_USER=..    -e QFLIX_HOST=.. \
#     claude-term sh /tmp/provision-access.sh
# (GH_PAT is used then discarded — written only to gh's own mode-600 hosts.yml. Omit
#  GH_PAT to (re)do just the SSH half. The real IPs/hostnames land only in the on-device
#  ~/.ssh/config inside the claude-home volume, never in any repo.)
set -eu

# Topology from the environment (supplied at exec time). Defaults are placeholders so a
# missing var fails loudly at connect time rather than silently writing a bad config.
STARHOLD_USER="${STARHOLD_USER:-grasp}"
STARHOLD_DEDI="${STARHOLD_DEDI:?set STARHOLD_DEDI (starhold-dedi tailnet IP)}"
STARHOLD_VPS="${STARHOLD_VPS:?set STARHOLD_VPS (starhold-vps tailnet IP)}"
QFLIX_USER="${QFLIX_USER:?set QFLIX_USER}"
QFLIX_HOST="${QFLIX_HOST:?set QFLIX_HOST (qflix public SSH host)}"

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# --- 1) GitHub PAT -> gh + git credential helper -----------------------------------
if [ -n "${GH_PAT:-}" ]; then
  printf '%s' "$GH_PAT" | gh auth login --with-token
  gh auth setup-git            # git push over HTTPS borrows gh's credential helper
  echo "gh: authenticated as $(gh api user -q .login 2>/dev/null || echo '?')"
else
  echo "gh: GH_PAT not set — skipping GitHub auth (SSH setup still runs)"
fi

# --- 2) dedicated SSH keys (atomic + idempotent, no TOCTOU) -------------------------
# mkdir is an atomic lock; generate to a unique temp name then atomically rename, so
# two concurrent runs can never both create a key (the race the council reproduced).
keygen_once() {
  key="$1"; comment="$2"
  [ -f "$key" ] && { echo "key $key exists — keep"; return 0; }
  lock="$key.lock"
  if ! mkdir "$lock" 2>/dev/null; then echo "key $key: concurrent run holds lock — skip"; return 0; fi
  if [ -f "$key" ]; then rmdir "$lock"; return 0; fi     # re-check under the lock
  tmp="$key.new.$$"
  ssh-keygen -t ed25519 -f "$tmp" -N "" -C "$comment" -q
  mv "$tmp" "$key"; mv "$tmp.pub" "$key.pub"
  chmod 600 "$key"; chmod 644 "$key.pub"
  rmdir "$lock"
  echo "generated $key"
}
keygen_once "$SSH_DIR/starhold_ed25519"  "shield-starhold-$(date +%Y%m%d 2>/dev/null || echo x)"
keygen_once "$SSH_DIR/qflix_ed25519"     "shield-qflix-$(date +%Y%m%d 2>/dev/null || echo x)"

# --- 3) ssh config aliases ---------------------------------------------------------
# accept-new = trust-on-first-use (tailnet is WireGuard-authenticated; the qflix host
# is already trusted by DEVIL). Pre-seeding known_hosts from DEVIL is the documented
# hardening (see docs/shield-access.md).
CFG="$SSH_DIR/config"
# UNquoted heredoc: the real topology (from the env) is interpolated HERE, on-device,
# into the claude-home volume — never into the public repo file.
cat > "$CFG" <<EOF
# Managed by provision-access.sh — Shield claude-term remote targets.
Host starhold-dedi
    HostName $STARHOLD_DEDI
    User $STARHOLD_USER
    IdentityFile ~/.ssh/starhold_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30

Host starhold-vps
    HostName $STARHOLD_VPS
    User $STARHOLD_USER
    IdentityFile ~/.ssh/starhold_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30

# qflix arr stack — reached over the PUBLIC internet (NOT the tailnet).
Host qflix
    HostName $QFLIX_HOST
    User $QFLIX_USER
    IdentityFile ~/.ssh/qflix_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
EOF
chmod 600 "$CFG"
echo "wrote $CFG"

echo "=== public keys to authorize (feed these to tools/authorize-shield-keys.ps1 on DEVIL) ==="
echo "STARHOLD_PUB=$(cat "$SSH_DIR/starhold_ed25519.pub")"
echo "QFLIX_PUB=$(cat "$SSH_DIR/qflix_ed25519.pub")"
