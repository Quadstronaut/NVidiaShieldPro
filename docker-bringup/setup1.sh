BIN=/data/docker/bin
ROOT=/data/docker
export PATH=$BIN:/system/bin:/system/xbin

# busybox helper applets at front of PATH (Android toybox lacks awk etc.)
for a in sh ash mount umount awk sed tail head cat grep egrep ln sleep mkdir chmod rm cp mv tr cut find xargs id wc ls pkill ps; do
  ln -sf busybox $BIN/$a
done

# noop modprobe (dockerd may try to load modules; overlay/bridge unneeded here)
printf '#!/system/bin/sh\nexit 0\n' > $BIN/modprobe
chmod 755 $BIN/modprobe

setenforce 0 2>/dev/null
echo "selinux=$(getenforce)"

mkdir -p $ROOT/data $ROOT/exec
$BIN/busybox pkill dockerd 2>/dev/null
$BIN/busybox pkill containerd 2>/dev/null
sleep 1

$BIN/dockerd \
  --data-root $ROOT/data \
  --exec-root $ROOT/exec \
  --host unix://$ROOT/docker.sock \
  --pidfile $ROOT/dockerd.pid \
  --storage-driver vfs \
  --iptables=false \
  --bridge=none \
  > $ROOT/dockerd.log 2>&1 &

echo "dockerd launched pid $!"
sleep 10
echo "=== docker info ==="
$BIN/docker -H unix://$ROOT/docker.sock info 2>&1 | head -50
echo "=== dockerd.log tail ==="
$BIN/busybox tail -n 40 $ROOT/dockerd.log
