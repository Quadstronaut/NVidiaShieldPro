BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
DOCKER="$BIN/docker -H unix://$ROOT/docker.sock"
log(){ echo ">>> $*"; }

# 0. clean prior daemons
$BB pkill -f dockerd 2>/dev/null
$BB pkill -f containerd 2>/dev/null
$BB pkill -f nsstart 2>/dev/null
sleep 2

mount -o remount,rw / 2>/dev/null
mkdir -p /run /opt
setenforce 0 2>/dev/null
log "selinux=$(getenforce)"

for a in sh ash mount umount awk sed tail head cat grep ln sleep mkdir chmod rm cp mv tr cut find xargs id wc ls pkill ps setsid unshare tar gzip stat; do
  ln -sf busybox $BIN/$a
done
printf '#!/system/bin/sh\nexit 0\n' > $BIN/modprobe; chmod 755 $BIN/modprobe
mkdir -p $ROOT/data $ROOT/exec

# launcher: inside a PRIVATE mount ns, replace cgroup2 at /sys/fs/cgroup with a
# real cgroup v1 tree (file-based device control works on kernel 4.9; v2 needs
# BPF_CGROUP_DEVICE which is 4.15+). Verbose NSLOG lines for diagnosis.
cat > $ROOT/nsstart.sh <<'NS'
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
mount --make-rprivate / 2>/dev/null; echo "NSLOG makeprivate_rc=$?"
umount -l /sys/fs/cgroup 2>/dev/null; echo "NSLOG umount_cg2_rc=$?"
mount -t tmpfs tmpfs /sys/fs/cgroup; echo "NSLOG tmpfs_rc=$?"
echo "NSLOG cgfs_type=$($BB stat -f -c %T /sys/fs/cgroup)"
for c in devices freezer pids memory cpu cpuacct blkio; do
  mkdir -p /sys/fs/cgroup/$c
  if mount -t cgroup -o $c cgroup /sys/fs/cgroup/$c 2>/dev/null; then echo "NSLOG v1ok $c"; else echo "NSLOG v1FAIL $c"; fi
done
echo "NSLOG cgroup2_lines_in_mountinfo=$($BB grep -c cgroup2 /proc/self/mountinfo)"
exec $BIN/dockerd \
  --data-root $ROOT/data \
  --exec-root $ROOT/exec \
  --host unix://$ROOT/docker.sock \
  --pidfile $ROOT/dockerd.pid \
  --storage-driver vfs \
  --iptables=false \
  --bridge=none
NS

$BB setsid $BB unshare -m $BB sh $ROOT/nsstart.sh </dev/null >$ROOT/dockerd.log 2>&1 &
log "dockerd launching in private ns (forcing cgroup v1)..."

i=0
while [ $i -lt 40 ]; do
  if [ -S $ROOT/docker.sock ] && $DOCKER info >/dev/null 2>&1; then break; fi
  sleep 1; i=$((i+1))
done
log "daemon ready after ${i}s"
echo "=== namespace cgroup setup (NSLOG) ==="
$BB grep NSLOG $ROOT/dockerd.log
echo "=== docker info: cgroup ==="
$DOCKER info 2>/dev/null | $BB grep -i cgroup

# build tiny local image
RF=$ROOT/rootfs
rm -rf $RF; mkdir -p $RF/bin
cp $BIN/busybox $RF/bin/busybox
for a in sh echo cat ls uname id hostname; do ln -sf busybox $RF/bin/$a; done
$BB tar -c -C $RF . | $DOCKER import - hello-shield >/dev/null 2>&1
log "image:"; $DOCKER images | $BB grep hello-shield

echo "============ CONTAINER OUTPUT ============"
$DOCKER run --rm --network none hello-shield /bin/sh -c '
echo "Hello from inside a Docker container on an NVIDIA Shield TV"
echo "container uid : $(id -u)"
echo "kernel        : $(uname -r)"
echo "arch          : $(uname -m)"
echo "i am          : pid $$ in my own PID namespace"
'
rc=$?
echo "=========================================="
echo "RUN_EXIT_CODE=$rc"
if [ $rc -ne 0 ]; then
  echo "--- dockerd.log tail ---"; $BB tail -n 12 $ROOT/dockerd.log
fi
