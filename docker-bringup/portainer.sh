#!/system/bin/sh
# Bring up Portainer CE as the management UI for the Shield's Docker.
# Host networking (bridge is dead on this kernel) -> UI lands on the Shield's LAN IP.
# Socket is at our non-standard /data/docker/docker.sock, bind-mounted to the place
# Portainer expects (/var/run/docker.sock). --restart=always = comes back when dockerd does.
BB=/data/docker/bin/busybox
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
SOCK=/data/docker/docker.sock
IMG=portainer/portainer-ce:lts

echo "=== dockerd reachable? ==="
$DOCKER version --format 'server {{.Server.Version}}' || { echo "FATAL: dockerd not responding"; exit 1; }
echo

echo "=== persistent data dir for portainer ==="
mkdir -p /data/docker/portainer
$BB ls -ld /data/docker/portainer
echo

echo "=== pull $IMG (needs DNS/resolv.conf) ==="
$DOCKER pull $IMG || { echo "FATAL: pull failed"; exit 1; }
echo

echo "=== drop any previous portainer container ==="
$DOCKER rm -f portainer 2>/dev/null
echo

echo "=== run portainer (host net, socket mounted, http UI enabled) ==="
$DOCKER run -d \
  --name portainer \
  --restart=always \
  --network host \
  -v $SOCK:/var/run/docker.sock \
  -v /data/docker/portainer:/data \
  $IMG \
  --http-enabled
echo

echo "=== container state ==="
$DOCKER ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
