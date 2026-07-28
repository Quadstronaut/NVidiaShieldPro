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
#
# `NEWREF=$(sh git-sync.sh | tail -1)` threw the exit status away: a pipeline
# reports only its LAST command, POSIX sh has no `pipefail`, and `tail` always
# succeeds. So a failed clone or pull looked like success, and NEWREF became
# whatever the last line of the error output happened to be -- which was then
# written to .last-deployed as if it were a commit. That poisons the change
# detector permanently: the marker never matches a real HEAD again, so every
# subsequent boot "detects a change" and redeploys.
#
# Capture, check the status, and validate the shape before trusting it.
set +e
SYNC_OUT=$(sh "$HERE/git-sync.sh" 2>&1)
SYNC_RC=$?
set -e
echo "$SYNC_OUT"
if [ "$SYNC_RC" -ne 0 ]; then
  echo "FATAL: git-sync.sh exited $SYNC_RC - refusing to deploy or move the marker"
  exit 1
fi

NEWREF=$(echo "$SYNC_OUT" | tail -1 | tr -d ' \t\r')
# A commit sha is 40 lowercase hex characters and nothing else. Anything else
# means git-sync printed something that is not a HEAD, and acting on it is worse
# than stopping.
if [ ${#NEWREF} -ne 40 ] || [ -n "$(printf %s "$NEWREF" | tr -d '0-9a-f')" ]; then
  echo "FATAL: git-sync.sh did not end with a commit sha (got: '$NEWREF')"
  exit 1
fi

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
