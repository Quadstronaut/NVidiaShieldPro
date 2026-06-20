#!/system/bin/sh
# pull-and-deploy.sh — the orchestrator the init service runs.
#   1) wait for dockerd to be ready (it also starts at boot_completed; order isn't guaranteed)
#   2) git-sync this repo (in a container)
#   3) if HEAD moved since the last deploy, re-run the launchers
# No host `git` needed: change detection compares the HEAD printed by git-sync.sh
# against a stored marker.
set -e

HERE=$(dirname "$0")
REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
MARKER="$REPO_DIR/deploy/.last-deployed"
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
LOG=/data/docker/deploy.log

exec >>"$LOG" 2>&1
echo "===== $(date) pull-and-deploy ====="

# 1) wait up to ~120s for the docker socket
i=0
until $DOCKER version >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 60 ] && { echo "FATAL: dockerd not ready"; exit 1; }
  sleep 2
done

# 2) sync; last line of output is the current HEAD
NEWREF=$(sh "$HERE/git-sync.sh" | tail -1)
OLDREF=$(cat "$MARKER" 2>/dev/null || echo "")
echo "HEAD: old=$OLDREF new=$NEWREF"

# 3) redeploy only on change (or first run)
if [ "$NEWREF" != "$OLDREF" ] && [ -n "$NEWREF" ]; then
  echo "change detected -> redeploy"
  sh "$HERE/redeploy.sh"
  echo "$NEWREF" > "$MARKER"
else
  echo "no change -> nothing to do"
fi
echo "===== done ====="
