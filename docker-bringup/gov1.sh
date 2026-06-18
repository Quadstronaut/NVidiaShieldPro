BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
DOCKER="$BIN/docker -H unix://$ROOT/docker.sock"
log(){ echo ">>> $*"; }

# 0. clean any prior daemon
$BB pkill -f dockerd 2>/dev/null
$BB pkill -f containerd 2>/dev/null
$BB pkill -f nsstart 2>/dev/null
sleep 2

# 1. writable /run /opt on the ramdisk rootfs + permissive selinux
mount -o remount,rw / 2>/dev/null
mkdir -p /run /opt
setenforce 0 2>/dev/null
log "selinux=$(getenforce)"

# 2. busybox helper applets + noop modprobe
for a in sh ash mount umount awk sed tail head cat grep ln sleep mkdir chmod rm cp mv tr cut find xargs id wc ls pkill ps setsid unshare tar gzip; do
  ln -sf busybox $BIN/$a
done
printf '#!/system/bin/sh\nexit 0\n' > $BIN/modprobe; chmod 755 $BIN/modprobe
mkdir -p $ROOT/data $ROOT/exec

# 3. dockerd launcher that runs INSIDE a private mount namespace on cgroup v1.
#    kernel 4.9 has no BPF_CGROUP_DEVICE -> cgroup v2 device control fails in runc.
#    v1 device control is file-based and works. We hide Android's cgroup2 ONLY
#    inside our private ns so the rest of the system is untouched.
cat > $ROOT/nsstart.sh <<'NS'
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
mount --make-rprivate / 2>/dev/null
mount -t tmpfs tmpfs /sys/fs/cgroup
for c in devices freezer pids memory cpu cpuacct blkio; do
  mkdir -p /sys/fs/cgroup/$c
  if mount -t cgroup -o $c cgroup /sys/fs/cgroup/$c 2>/dev/null; then
    echo "NSLOG v1-mounted $c"
  else
    echo "NSLOG v1-FAILED $c"
  fi
done
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
log "dockerd launching in private mount ns (cgroup v1)..."

# 4. wait for the daemon
i=0
while [ $i -lt 40 ]; do
  if [ -S $ROOT/docker.sock ] && $DOCKER info >/dev/null 2>&1; then break; fi
  sleep 1; i=$((i+1))
done
log "daemon ready after ${i}s"
echo "=== ns cgroup setup ==="
$BB grep NSLOG $ROOT/dockerd.log
echo "=== docker info: cgroup ==="
$DOCKER info 2>/dev/null | $BB grep -i cgroup

# 5. build a tiny local image (no registry / no DNS needed)
RF=$ROOT/rootfs
rm -rf $RF; mkdir -p $RF/bin
cp $BIN/busybox $RF/bin/busybox
for a in sh echo cat ls uname id hostname; do ln -sf busybox $RF/bin/$a; done
$BB tar -c -C $RF . | $DOCKER import - hello-shield >/dev/null 2>&1
log "image:"; $DOCKER images | $BB grep hello-shield

# 6. RUN THE CONTAINER
echo "============ CONTAINER OUTPUT ============"
$DOCKER run --rm --network none hello-shield /bin/sh -c '
echo "Hello from inside a Docker container on an NVIDIA Shield TV"
echo "container uid : $(id -u)"
echo "kernel        : $(uname -r)"
echo "arch          : $(uname -m)"
echo "i am          : pid $$ in my own namespace"
'
rc=$?
echo "=========================================="
echo "RUN_EXIT_CODE=$rc"
if [ $rc -ne 0 ]; then
  echo "--- last dockerd.log lines (for diagnosis) ---"
  $BB tail -n 15 $ROOT/dockerd.log
fi
