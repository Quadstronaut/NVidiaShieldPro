#!/system/bin/sh
# git-sync.sh — clone/pull this repo onto the Shield via a throwaway alpine/git CONTAINER
# (Toybox has no `git`), authenticating with a READ-ONLY SSH deploy key.
# Host networking because the Tegra 4.9 bridge is dead (see docs/02-docker-on-kernel-4.9.md).
#
# The key lives OUTSIDE the repo so the very first clone can bootstrap:
#   /data/.ssh/shield_deploy_ed25519   (chmod 600)
#   /data/.ssh/known_hosts             (github.com host keys)
# Deploy keys are read-only + scoped to this one repo, so a leaked key exposes nothing else.
set -e

DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
REPO_SSH=${REPO_SSH:-git@github.com:Quadstronaut/NVidiaShieldPro.git}
GIT_IMG=${GIT_IMG:-alpine/git:latest}
SSH_DIR=${SSH_DIR:-/data/.ssh}
KEY_NAME=${KEY_NAME:-shield_deploy_ed25519}

GSC="ssh -i /keys/$KEY_NAME -o IdentitiesOnly=yes -o UserKnownHostsFile=/keys/known_hosts -o StrictHostKeyChecking=yes"

$DOCKER image inspect "$GIT_IMG" >/dev/null 2>&1 || $DOCKER pull "$GIT_IMG"

run_git() {  # run git inside the container with the deploy key
  $DOCKER run --rm --network host \
    -v /data:/data -v "$SSH_DIR":/keys:ro \
    -e GIT_SSH_COMMAND="$GSC" \
    "$GIT_IMG" -c safe.directory='*' "$@"
}

if [ -d "$REPO_DIR/.git" ]; then
  echo "=== pull $REPO_DIR ==="
  run_git -C "$REPO_DIR" pull --ff-only
else
  echo "=== clone -> $REPO_DIR ==="
  run_git clone "$REPO_SSH" "$REPO_DIR"
fi

# current HEAD — last line of stdout, consumed by pull-and-deploy.sh for change detection
run_git -C "$REPO_DIR" rev-parse HEAD
