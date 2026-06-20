BB=/data/docker/bin/busybox
ROOT=/data/docker
DOCKER="/data/docker/bin/docker -H unix://$ROOT/docker.sock"
echo "=== uptime (proves fresh boot) ==="
$BB uptime
echo "=== /data/docker/boot.log (written by the init service this boot) ==="
$BB cat $ROOT/boot.log
echo "=== is dockerd running, and who started it? ==="
$BB ps -ef | $BB grep -E "bin/dockerd|bin/containerd" | $BB grep -v grep
echo "=== docker info: cgroup ==="
$DOCKER info 2>/dev/null | $BB grep -iE "Server Version|Cgroup Version"
echo "=== run a container (no setup was done this boot) ==="
$DOCKER run --rm --network none hello-shield /bin/sh -c '
echo "  Auto-started Docker survived a reboot."
echo "  uptime inside: fresh boot"
echo "  kernel: $(uname -r)  uid: $(id -u)"
' 2>&1
echo "RUN_EXIT_CODE=$?"
