#!/system/bin/sh
# Bring up shield-c2: the status + command-and-control dashboard for the
# Shield's Docker host, on port 8888 (A1/D4).
#
# Host networking (bridge is dead on this kernel, I5) -> UI lands on the Shield's
# LAN IP at http://10.0.0.88:8888. Host /proc /sys /data are bind-mounted
# READ-ONLY at /host/* (I6); the docker socket is mounted rw (control needs it,
# blast radius bounded by the server-side allowlist, I2). --restart=always =
# comes back when dockerd does. Idempotent: re-running replaces the container.
#
# NO AUTH by user decision (A2) — anyone on the LAN can reach this. See
# docs/THREAT-MODEL.md.
set -e

BB=/data/docker/bin/busybox
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
SOCK=/data/docker/docker.sock
IMG=shield-c2:latest
NAME=shield-c2
PORT=${SHIELD_C2_PORT:-8888}
# Build context = the shield-c2 app dir next to this script's repo checkout.
CTX=${SHIELD_C2_CTX:-/data/docker/shield-c2}

echo "=== dockerd reachable? ==="
$DOCKER version --format 'server {{.Server.Version}}' || { echo "FATAL: dockerd not responding"; exit 1; }
echo

echo "=== drop any previous $NAME container FIRST (so re-runs free the port) ==="
$DOCKER rm -f $NAME 2>/dev/null || true
echo

echo "=== assert port $PORT is free (vs Kuma 3001) ==="
# netstat on busybox: look for a LISTEN on :$PORT. If occupied by a NON-$NAME service, bail.
if $BB netstat -ltn 2>/dev/null | $BB grep -qE "[:.]$PORT[[:space:]]"; then
  echo "FATAL: port $PORT already in use on this host"; exit 1
fi
echo "port $PORT free"
echo

echo "=== obtain image $IMG (load tar if present, else build from $CTX) ==="
if $DOCKER image inspect $IMG >/dev/null 2>&1; then
  echo "image already present"
elif [ -f /data/docker/shield-c2.tar ]; then
  echo "loading /data/docker/shield-c2.tar"
  $DOCKER load -i /data/docker/shield-c2.tar
elif [ -d "$CTX" ]; then
  echo "building from $CTX (this can take a while on-device)"
  # --network=host: classic-builder RUN steps otherwise get no DNS on this daemon
  # (EAI_AGAIN registry.npmjs.org). Host net gives them the working host resolver.
  $DOCKER build --network=host -t $IMG "$CTX"
else
  echo "FATAL: no image, no tar, no build context at $CTX"; exit 1
fi
echo

echo "=== run $NAME (host net, ro /proc /sys /data, rw socket, port $PORT) ==="
$DOCKER run -d \
  --name $NAME \
  --restart=always \
  --network host \
  -e SHIELD_C2_PORT=$PORT \
  -e SHIELD_C2_INTERVAL_MS=${SHIELD_C2_INTERVAL_MS:-2000} \
  -e HOST_PROC=/host/proc \
  -e HOST_SYS=/host/sys \
  -e HOST_DATA=/host/data \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /data:/host/data:ro \
  -v $SOCK:/var/run/docker.sock \
  $IMG
echo

echo "=== container state ==="
$DOCKER ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo
echo "shield-c2 up at http://10.0.0.88:$PORT  (unauthenticated, LAN only)"
