#!/system/bin/sh
# Runs AS the init 'dockerd' service's main process. Does non-namespace setup,
# then exec's into unshare -> nsstart -> dockerd so that dockerd inherits this
# PID and init supervises it (non-oneshot). dockerd must NOT be backgrounded.
exec >> /data/docker/boot.log 2>&1
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
echo "===== dockerd-svc start $($BB date 2>/dev/null) ====="

# kill any stale leftovers (busybox here has no pkill)
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
# DNS for the daemon's registry pulls. Android has no /etc/resolv.conf; the static
# dockerd uses Go's pure resolver which reads it. /etc -> /system/etc (persistent).
# Written persistently once; only recreate if missing (/ may be read-only at boot).
[ -s /etc/resolv.conf ] || { mount -o remount,rw / 2>/dev/null; printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null; }
echo "resolv.conf=$($BB cat /etc/resolv.conf 2>/dev/null | $BB tr '\n' ' ')"
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
# /run and /opt: tmpfs so they stay writable even after Android remounts / read-only
mount -t tmpfs tmpfs /run 2>/dev/null
mkdir -p /run/containerd /run/docker
mount -t tmpfs tmpfs /opt 2>/dev/null
umount -l /sys/fs/cgroup 2>/dev/null
mount -t tmpfs tmpfs /sys/fs/cgroup
for c in devices freezer pids memory cpu cpuacct blkio; do
  mkdir -p /sys/fs/cgroup/$c
  mount -t cgroup -o $c cgroup /sys/fs/cgroup/$c 2>/dev/null
done
exec $BIN/dockerd \
  --data-root $ROOT/data --exec-root $ROOT/exec \
  --host unix://$ROOT/docker.sock --pidfile $ROOT/dockerd.pid \
  --storage-driver overlay2 --iptables=false --bridge=none >> $ROOT/dockerd.log 2>&1
NS

echo "exec -> unshare -> dockerd (init supervises dockerd as this PID)"
exec $BB unshare -m $BB sh $ROOT/nsstart.sh
