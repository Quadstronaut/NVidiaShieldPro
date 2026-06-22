#!/system/bin/sh
# Bring up claude-term: phone-driven Claude Code web terminal on the Shield,
# port 7777 (D5). Host networking (bridge dead on this kernel, I4) -> reachable
# at http://10.0.0.88:7777. Workspace /data/claude is the ONLY writable host
# mount besides the ~/.claude creds volume (I2); NO docker socket (I9).
# Secret + OAuth token come from a sourced untracked claude-term.env (I11).
# --restart=always = returns when dockerd does. Idempotent: re-run replaces it.
set -e

HERE=$(dirname "$0")
[ -f "$HERE/claude-term.env" ] && . "$HERE/claude-term.env"

BB=/data/docker/bin/busybox
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
IMG=claude-term:latest
NAME=claude-term
PORT=${CLAUDE_TERM_PORT:-7777}
CTX=${CLAUDE_TERM_CTX:-/data/docker/claude-term}
VOL=claude-home

echo "=== fail-closed: secret must be set (I1) ==="
[ -n "$CLAUDE_TERM_SECRET" ] || { echo "FATAL: CLAUDE_TERM_SECRET unset (source claude-term.env)"; exit 1; }
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || echo "WARN: CLAUDE_CODE_OAUTH_TOKEN empty — Claude will demand /login (R3)"

echo "=== dockerd reachable? ==="
$DOCKER version --format 'server {{.Server.Version}}' || { echo "FATAL: dockerd not responding"; exit 1; }

echo "=== drop any previous $NAME FIRST (frees the port on re-run) ==="
$DOCKER rm -f $NAME 2>/dev/null || true

echo "=== assert port $PORT free (vs 8888 c2 / 3001 kuma) ==="
if $BB netstat -ltn 2>/dev/null | $BB grep -qE "[:.]$PORT[[:space:]]"; then
  echo "FATAL: port $PORT already in use"; exit 1
fi
echo "port $PORT free"

echo "=== obtain image $IMG (load tar, else build from $CTX) ==="
if $DOCKER image inspect $IMG >/dev/null 2>&1; then echo "image present"
elif [ -f /data/docker/claude-term.tar ]; then $DOCKER load -i /data/docker/claude-term.tar
elif [ -f "$HERE/claude-term-build.sh" ]; then
  # `docker build` can't get host networking on this kernel (bridge dead, BuildKit
  # absent) -> build via run+commit instead. See claude-term-build.sh header.
  echo "building image via run+commit ($HERE/claude-term-build.sh)"
  CLAUDE_TERM_CTX="$CTX" sh "$HERE/claude-term-build.sh"
else echo "FATAL: no image, no tar, no claude-term-build.sh"; exit 1
fi

echo "=== ensure workspace /data/claude writable by in-container claude (uid 1000) ==="
mkdir -p /data/claude
chown 1000:1000 /data/claude 2>/dev/null || true
chmod 755 /data/claude

echo "=== run $NAME (host net, rw /data/claude + creds vol, NO socket, port $PORT) ==="
$DOCKER run -d \
  --name $NAME \
  --restart=always \
  --network host \
  --group-add 3003 \
  -e CLAUDE_TERM_PORT=$PORT \
  -e CLAUDE_TERM_SECRET="$CLAUDE_TERM_SECRET" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  -e CLAUDE_TERM_WORKSPACE=/data/claude \
  -e CLAUDE_TERM_SNIPPETS=/data/claude/snippets.json \
  -v /data/claude:/data/claude \
  -v $VOL:/home/claude/.claude \
  $IMG

echo "=== container state ==="
$DOCKER ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo "claude-term up at http://10.0.0.88:$PORT  (secret-gated, LAN only)"
