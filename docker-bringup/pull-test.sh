BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== daemon status ==="
$D info 2>/dev/null | $BB grep -iE "Server Version|Storage Driver|Backing Filesystem|Cgroup Version"
echo "=== boot.log tail (resolv.conf + start) ==="
$BB grep -E "resolv|start|selinux" /data/docker/boot.log | $BB tail -4
echo "=== docker pull hello-world (real image, Docker Hub) ==="
$D pull hello-world 2>&1 | $BB tail -10
echo "=== docker images ==="
$D images
echo "=== run it (no bridge net on this box -> --network none) ==="
$D run --rm --network none hello-world 2>&1 | $BB tail -18
echo "RUN_EXIT_CODE=$?"
