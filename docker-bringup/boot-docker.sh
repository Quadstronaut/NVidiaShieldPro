#!/system/bin/sh
# Brings Docker up on the NVIDIA Shield after a reboot. Idempotent.
# Invoked by /system/etc/init/dockerd.rc on sys.boot_completed.
exec >> /data/docker/boot.log 2>&1
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
echo "===== boot-docker start $($BB date 2>/dev/null) ====="

# kill any stale daemon (this busybox has no pkill -> ps|grep|awk|kill)
for pat in bin/dockerd bin/containerd containerd-shim bin/runc nsstart; do
  for p in $($BB ps -ef 2>/dev/null | $BB grep "$pat" | $BB grep -v grep | $BB awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
done
sleep 1

mount -o remount,rw / 2>/dev/null
mkdir -p /run /opt $ROOT/data $ROOT/exec
setenforce 0 2>/dev/null
echo "selinux=$(getenforce)"

for a in sh ash mount umount awk sed tail head cat grep ln sleep mkdir chmod rm cp mv tr cut find xargs id wc ls setsid unshare tar gzip stat kill date; do
  ln -sf busybox $BIN/$a
done
printf '#!/system/bin/sh\nexit 0\n' > $BIN/modprobe; chmod 755 $BIN/modprobe
rm -f $ROOT/docker.sock; rm -rf $ROOT/exec/*

cat > $ROOT/nsstart.sh <<'NS'
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
mount --make-rprivate / 2>/dev/null
umount -l /sys/fs/cgroup 2>/dev/null
mount -t tmpfs tmpfs /sys/fs/cgroup
for c in devices freezer pids memory cpu cpuacct blkio; do
  mkdir -p /sys/fs/cgroup/$c
  mount -t cgroup -o $c cgroup /sys/fs/cgroup/$c 2>/dev/null
done
exec $BIN/dockerd \
  --data-root $ROOT/data --exec-root $ROOT/exec \
  --host unix://$ROOT/docker.sock --pidfile $ROOT/dockerd.pid \
  --storage-driver vfs --iptables=false --bridge=none
NS

$BB setsid $BB unshare -m $BB sh $ROOT/nsstart.sh </dev/null >> $ROOT/dockerd.log 2>&1 &
echo "dockerd launching..."
i=0
while [ $i -lt 60 ]; do
  if [ -S $ROOT/docker.sock ] && $BIN/docker -H unix://$ROOT/docker.sock info >/dev/null 2>&1; then break; fi
  sleep 1; i=$((i+1))
done
echo "ready after ${i}s; $($BIN/docker -H unix://$ROOT/docker.sock info 2>/dev/null | $BB grep -i 'Cgroup Version')"
echo "===== boot-docker done ====="
