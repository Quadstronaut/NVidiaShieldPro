#!/system/bin/sh
# One-off cleanup: drop the failed-build leftover container + prune dangling images.
# Dangling prune only touches untagged, unreferenced images (live containers safe).
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== disk BEFORE ==="
$D system df
echo
echo "=== remove failed-build container upbeat_faraday ==="
$D rm upbeat_faraday
echo
echo "=== prune dangling images ==="
$D image prune -f
echo
echo "=== disk AFTER ==="
$D system df
echo
echo "=== remaining images ==="
$D images
