#!/system/bin/sh
# redeploy.sh — re-run the active service launchers after a pull.
# Each launcher is idempotent (docker rm -f + run), so re-running is safe; it just
# bounces the container onto the new image/config. Edit ACTIVE as the stack grows.
set -e

REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
BR="$REPO_DIR/docker-bringup"
HERE=$(dirname "$0")

# FIRST: make /data/docker match the repo we just pulled. Without this the deploy
# rail pulled new code and then ran the OLD copies forever -- the repo was the
# source of truth for nothing. Copy-only and non-restarting by design; see the
# header of install-device-scripts.sh for why restarting here would self-kill.
sh "$HERE/install-device-scripts.sh"

# Order matters loosely: monitors first, app last.
#
# claude-steer.sh is GONE ON PURPOSE. It copied claude-env/ (this PUBLIC repo's
# tiny public-safe steering: 3 skills, 4 agents) over /home/claude/.claude on
# every boot. Steering is now delivered by tools/Sync-ShieldIdentity.ps1 over a
# PRIVATE rail carrying the full ~/.claude -- 623 memory files, 6 skills, 8
# agents. Leaving claude-steer.sh wired here would overwrite the richer content
# at every reboot: two writers, one directory, the poorer one winning.
#
# claude-term.sh is also intentionally NOT here -- it needs an untracked
# on-device env (secret/OAuth), so the rail must never recreate that container.
ACTIVE="kuma-netfix.sh c2.sh"

for s in $ACTIVE; do
  if [ -f "$BR/$s" ]; then
    echo "=== launcher: $s ==="
    sh "$BR/$s" || echo "WARN: $s exited non-zero"
  else
    echo "skip (absent): $s"
  fi
done
echo "=== redeploy done ==="
