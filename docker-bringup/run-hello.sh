BIN=/data/docker/bin
ROOT=/data/docker
export PATH=$BIN:/system/bin:/system/xbin
DOCKER="$BIN/docker -H unix://$ROOT/docker.sock"

# 1. minimal rootfs: static busybox + applet symlinks
RF=$ROOT/rootfs
rm -rf $RF
mkdir -p $RF/bin
cp $BIN/busybox $RF/bin/busybox
for a in sh echo cat ls uname id hostname uptime; do
  ln -sf busybox $RF/bin/$a
done

# 2. import the rootfs as a docker image
$BIN/busybox tar -c -C $RF . | $DOCKER import - hello-shield
echo "=== images ==="
$DOCKER images

# 3. run a container, no networking
echo "=== RUN (this is the moment of truth) ==="
$DOCKER run --rm --network none hello-shield /bin/sh -c '
echo "=========================================="
echo " Hello from inside a Docker container"
echo " running on an NVIDIA Shield TV"
echo "=========================================="
echo "container uid : $(id -u) ($(id -un 2>/dev/null || echo root))"
echo "kernel        : $(uname -r)"
echo "arch          : $(uname -m)"
echo "hostname      : $(hostname)"
echo "pid 1 is me   : $$"
echo "what is pid 1 : $(cat /proc/1/comm)"
'
echo "exit code: $?"
