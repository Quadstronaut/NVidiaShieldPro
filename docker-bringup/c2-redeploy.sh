#!/system/bin/sh
# Force a fresh shield-c2 image build + redeploy after a source change.
# (c2.sh skips the build when shield-c2:latest already exists, so drop it first.)
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$D rm -f shield-c2 2>/dev/null
$D rmi shield-c2:latest 2>/dev/null
DOCKER_BUILDKIT=0 /system/bin/sh /data/docker/c2.sh
