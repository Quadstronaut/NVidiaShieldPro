#!/system/bin/sh
# git-sync.sh — clone/pull this repo onto the Shield using a throwaway git CONTAINER.
# Why a container: Toybox (the Android userland) has no `git`. Docker is the one thing
# on this box that has network + git, so we borrow it. Host networking because the
# Tegra 4.9 bridge is dead (see docs/02-docker-on-kernel-4.9.md).
#
# Secrets: this repo is PRIVATE, so cloning/pulling needs a GitHub token. NEVER hardcode it.
# Put it in deploy/deploy.env (gitignored):  GH_TOKEN=github_pat_...   REPO_URL=https://github.com/<you>/NVidiaShieldPro.git
set -e

HERE=$(dirname "$0")
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"

DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
REPO_URL=${REPO_URL:-https://github.com/Quadstronaut/NVidiaShieldPro.git}
GIT_IMG=${GIT_IMG:-alpine/git:latest}

# Inject the token only into the URL for this run (kept out of any committed file).
if [ -n "$GH_TOKEN" ]; then
  AUTH_URL=$(echo "$REPO_URL" | sed "s#https://#https://x-access-token:${GH_TOKEN}@#")
else
  AUTH_URL="$REPO_URL"
fi

$DOCKER image inspect "$GIT_IMG" >/dev/null 2>&1 || $DOCKER pull "$GIT_IMG"

if [ -d "$REPO_DIR/.git" ]; then
  echo "=== pull $REPO_DIR ==="
  $DOCKER run --rm --network host -v /data:/data -w "$REPO_DIR" "$GIT_IMG" pull --ff-only
else
  echo "=== clone -> $REPO_DIR ==="
  $DOCKER run --rm --network host -v /data:/data "$GIT_IMG" clone "$AUTH_URL" "$REPO_DIR"
fi

# Print the current HEAD so the orchestrator can detect changes.
$DOCKER run --rm --network host -v /data:/data -w "$REPO_DIR" "$GIT_IMG" rev-parse HEAD
