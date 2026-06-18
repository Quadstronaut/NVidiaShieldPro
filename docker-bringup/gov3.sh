BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
DOCKER="$BIN/docker -H unix://$ROOT/docker.sock"
log(){ echo ">>> $*"; }

# 0. REAL cleanup (this busybox has no pkill/pgrep) -- ps|grep|awk|kill
killdock() {
  for pat in bin/dockerd bin/containerd "containerd --config" containerd-shim bin/runc nsstart; do
    for p in $($BB ps -ef 2>/dev/null | $BB grep "$pat" | $BB grep -v grep | $BB awk '{print $1}'); do
      kill -9 "$p" 2>/dev/null
    done
  done
}
killdock; sleep 2; killdock; sleep 1
log "remaining docker procs: $($BB ps -ef | $BB grep -E 'bin/dockerd|bin/containerd' | $BB grep -v grep | $BB wc -l)"
rm -f $ROOT/docker.sock
rm -rf $ROOT/exec/*

mount -o remount,rw / 2>/dev/null
mkdir -p /run /opt
setenforce 0 2>/dev/null
log "selinux=$(getenforce)"

for a in sh ash mount umount awk sed tail head cat grep ln sleep mkdir chmod rm cp mv tr cut find xargs id wc ls setsid unshare tar gzip stat kill; do
  ln -sf busybox $BIN/$a
done
printf '#!/system/bin/sh\nexit 0\n' > $BIN/modprobe; chmod 755 $BIN/modprobe
mkdir -p $ROOT/data $ROOT/exec

cat > $ROOT/nsstart.sh <<'NS'
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
mount --make-rprivate / 2>/dev/null
umount -l /sys/fs/cgroup 2>/dev/null
mount -t tmpfs tmpfs /sys/fs/cgroup
echo "NSLOG cgfs_type=$($BB stat -f -c %T /sys/fs/cgroup)"
for c in devices freezer pids memory cpu cpuacct blkio; do
  mkdir -p /sys/fs/cgroup/$c
  mount -t cgroup -o $c cgroup /sys/fs/cgroup/$c 2>/dev/null && echo "NSLOG v1ok $c" || echo "NSLOG v1FAIL $c"
done
exec $BIN/dockerd \
  --data-root $ROOT/data --exec-root $ROOT/exec \
  --host unix://$ROOT/docker.sock --pidfile $ROOT/dockerd.pid \
  --storage-driver vfs --iptables=false --bridge=none
NS

$BB setsid $BB unshare -m $BB sh $ROOT/nsstart.sh </dev/null >$ROOT/dockerd.log 2>&1 &
log "launching v1 dockerd in private ns..."

i=0
while [ $i -lt 40 ]; do
  if [ -S $ROOT/docker.sock ] && $DOCKER info >/dev/null 2>&1; then break; fi
  sleep 1; i=$((i+1))
done
log "daemon ready after ${i}s"
$BB grep NSLOG $ROOT/dockerd.log
echo "=== docker info: cgroup (want Version: 1) ==="
$DOCKER info 2>/dev/null | $BB grep -i cgroup

RF=$ROOT/rootfs
rm -rf $RF; mkdir -p $RF/bin
cp $BIN/busybox $RF/bin/busybox
for a in sh echo cat ls uname id hostname; do ln -sf busybox $RF/bin/$a; done
$BB tar -c -C $RF . | $DOCKER import - hello-shield >/dev/null 2>&1
log "image:"; $DOCKER images | $BB grep hello-shield

echo "============ CONTAINER OUTPUT ============"
$DOCKER run --rm --network none hello-shield /bin/sh -c '
echo "  Hello from inside a Docker container"
echo "  running on an NVIDIA Shield TV (Tegra X1)"
echo "  ----------------------------------------"
echo "  container uid : $(id -u)"
echo "  kernel        : $(uname -r)"
echo "  arch          : $(uname -m)"
echo "  i am          : pid $$ in my own namespace"
'
rc=$?
echo "=========================================="
echo "RUN_EXIT_CODE=$rc"
[ $rc -ne 0 ] && { echo "--- dockerd.log tail ---"; $BB tail -n 12 $ROOT/dockerd.log; }
