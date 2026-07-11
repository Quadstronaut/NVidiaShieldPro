#!/system/bin/sh
# tailscaled-svc.sh — boot launcher for the host tailscale daemon, backgrounded from
# dockerd-svc.sh at sys.boot_completed (same slot as dropbear). It is a supervise loop
# with a fixed 5s backoff so a failing daemon can NEVER hot-loop the shared-/data log,
# and it rotates its own log at 1 MB. tailscaled is independent of dockerd.
#
# --tun=tun0 uses the REAL kernel TUN (/dev/net/tun exists, CONFIG_TUN=y): a real TUN is
# required because every container runs --network host and inherits the host netns, so
# the tailnet routes must live in that netns (userspace-networking/SOCKS can't be
# transparently inherited). --netfilter-mode=off: this leaf only makes OUTBOUND SSH to
# Starhold; it is not a subnet router, and the minimal Android userland has no iptables —
# peer reachability is enforced by the tailnet ACL server-side, not local netfilter.
TS_DIR=/data/tailscale
STATE=$TS_DIR/tailscaled.state
SOCK=$TS_DIR/tailscaled.sock
LOG=$TS_DIR/tailscaled.log
BB=/data/docker/bin/busybox

sz() { $BB stat -c%s "$1" 2>/dev/null || echo 0; }
[ -f "$LOG" ] && [ "$(sz "$LOG")" -gt 1048576 ] && mv -f "$LOG" "$LOG.1"

# Fail SOFT (exit 0, no crash-loop) if prerequisites are missing — a missing binary or
# TUN is an install problem to fix with tailscale-install.sh, not a reason to thrash.
[ -x "$TS_DIR/tailscaled" ] || { echo "$($BB date): tailscaled missing — run tailscale-install.sh" >> "$LOG"; exit 0; }
[ -e /dev/net/tun ]        || { echo "$($BB date): /dev/net/tun absent — cannot start" >> "$LOG"; exit 0; }

n=0
while :; do
  echo "===== tailscaled start $($BB date) (run $n) =====" >> "$LOG"
  "$TS_DIR/tailscaled" --state="$STATE" --socket="$SOCK" --tun=tun0 --netfilter-mode=off >> "$LOG" 2>&1
  n=$((n + 1))
  sleep 5
done
