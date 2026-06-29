#!/system/bin/sh
# claude-steer.sh — sync the running claude-term container's Claude steering from
# the repo's claude-env/ (CLAUDE.md, skills/, agents/) and strip the PC-only bits
# the Shield can't use (ollama/Windows hooks + all MCP servers).
#
# Non-destructive: touches only /home/claude/.claude steering inside the persistent
# claude-home volume. NEVER recreates the container, never touches auth/OAuth, never
# restarts (each `claude -p` turn reads ~/.claude fresh). Idempotent — re-running
# on an already-synced container is a no-op. This is what makes the Shield's Claude
# track the PC: push claude-env/ -> Shield pulls -> redeploy runs this.
set -e

HERE=$(dirname "$0")
REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
ENV_DIR="$REPO_DIR/claude-env"
[ -d "$ENV_DIR" ] || ENV_DIR="$HERE/../claude-env"   # fallback when run from a working tree
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
NAME=claude-term
DEST=/home/claude/.claude

[ -f "$ENV_DIR/CLAUDE.md" ] || { echo "FATAL: no steering at $ENV_DIR"; exit 1; }
$DOCKER inspect -f '{{.State.Running}}' $NAME 2>/dev/null | grep -q true \
  || { echo "FATAL: $NAME not running — nothing to steer"; exit 1; }

echo "=== copy steering (CLAUDE.md, skills/, agents/) into $NAME:$DEST ==="
$DOCKER cp "$ENV_DIR/CLAUDE.md" "$NAME:$DEST/CLAUDE.md"
# Replace skills/ and agents/ wholesale so upstream deletions propagate (not merge).
$DOCKER exec -u 0 $NAME sh -c "rm -rf $DEST/skills $DEST/agents"
$DOCKER cp "$ENV_DIR/skills"  "$NAME:$DEST/skills"
$DOCKER cp "$ENV_DIR/agents"  "$NAME:$DEST/agents"

echo "=== strip dead hooks + all MCP servers (no ollama/Windows/uv on the Shield) ==="
# settings.json hooks point at ~/.claude/hooks/*.sh + powershell.exe that don't exist
# in the container; every mcpServers entry is PC-bound (uv/ollama/Windows paths/tokens).
$DOCKER exec -u 0 $NAME node -e '
  const fs = require("fs");
  for (const p of ["/home/claude/.claude/settings.json", "/home/claude/.claude.json"]) {
    let c; try { c = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { console.log("skip " + p); continue; }
    let ch = false;
    if (c.hooks)      { delete c.hooks;      ch = true; }
    if (c.mcpServers) { delete c.mcpServers; ch = true; }
    if (ch) { fs.writeFileSync(p, JSON.stringify(c, null, 2)); console.log("cleaned " + p); }
    else    { console.log("already clean " + p); }
  }
'

echo "=== own steering as the in-container claude user (uid 1000) ==="
$DOCKER exec -u 0 $NAME chown -R 1000:1000 "$DEST/CLAUDE.md" "$DEST/skills" "$DEST/agents"

echo "=== done — steering synced; read fresh by the next claude -p turn (no restart) ==="
