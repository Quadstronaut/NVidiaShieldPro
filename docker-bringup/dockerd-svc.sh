#!/system/bin/sh
# Runs AS the init 'dockerd' service's main process. Does non-namespace setup,
# then exec's into unshare -> nsstart -> dockerd so that dockerd inherits this
# PID and init supervises it (non-oneshot). dockerd must NOT be backgrounded.
BIN=/data/docker/bin
ROOT=/data/docker
BB=$BIN/busybox
export PATH=$BIN:/system/bin:/system/xbin
# Rotate BEFORE redirecting: this log is append-only across every boot and every
# crash-restart, and nothing else ever truncates it. Cheap, and it keeps an
# always-on box from growing an unbounded file for years.
[ -f $ROOT/boot.log ] && [ "$($BB stat -c %s $ROOT/boot.log 2>/dev/null || echo 0)" -gt 1048576 ] && \
  $BB mv $ROOT/boot.log $ROOT/boot.log.1
exec >> /data/docker/boot.log 2>&1
echo "===== dockerd-svc start $($BB date 2>/dev/null) ====="

# kill any stale leftovers (busybox here has no pkill)
#
# repo-refresh-svc and tailscaled-svc are in this list ON PURPOSE. They are
# launched below with setsid, so they get their OWN session and process group and
# therefore SURVIVE an init restart of this service -- and init restarts do happen
# (boot.log records three dockerd-svc starts inside two minutes on 2026-06-22).
# Without this, every restart stacked another copy of each loop. Two repo-refresh
# loops means two concurrent `git fetch` passes over the same 55 clones, which
# collide on .git/index.lock, interleave into one shared log, and race to write
# /data/claude/.last-refresh -- so the parity gate reads whichever finished last
# and reports a healthy refresh that never coherently happened.
# install-refresh.sh already killed-before-spawn; this makes the boot path agree.
for pat in bin/dockerd bin/containerd containerd-shim bin/runc nsstart repo-refresh-svc tailscaled-svc; do
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
# Clear BOTH the socket and the pidfile: dockerd.pid persists in /data across
# reboot, and if its old PID gets reused, dockerd refuses to start ("process
# with PID N is still running") and init crash-loops this service. The kill loop
# above already reaped any real dockerd, so the pidfile here is always stale.
rm -f $ROOT/docker.sock $ROOT/dockerd.pid; rm -rf $ROOT/exec/*

# Shield SSH server (dropbear, key-only root on :22). Independent of docker;
# start it before this PID is handed off to dockerd via exec. The stock
# /product/bin/sshd can't shield host keys on this ROM, hence the static build.
sh $ROOT/dropbear.sh >> $ROOT/dropbear-boot.log 2>&1 || true

# Tailscale daemon — also independent of docker; started here (NOT a second init .rc)
# so it shares this one boot trigger and can't race dockerd's. Backgrounded as its own
# self-supervising loop (backoff + log-rotate inside tailscaled-svc.sh); a --network
# host container then inherits the tailnet with no per-container config. No-op-safe if
# tailscale isn't installed yet.
[ -f $ROOT/tailscaled-svc.sh ] && $BB setsid $BB sh $ROOT/tailscaled-svc.sh >/dev/null 2>&1 &

# Daily repo refresh - same slot and same self-supervising pattern as tailscaled.
# Android has no cron; this keeps one boot trigger and one supervision mechanism
# rather than adding busybox crond alongside. It waits for claude-term itself, so
# launching here (before dockerd exec's below) is safe. No-op-safe if absent.
[ -f $ROOT/repo-refresh-svc.sh ] && $BB setsid $BB sh $ROOT/repo-refresh-svc.sh >/dev/null 2>&1 &

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
