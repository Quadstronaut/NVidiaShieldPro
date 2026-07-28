#!/system/bin/sh
# Start the patched static dropbear as the Shield's SSH server on :22 — key-only
# root login, pubkeys from /data/ssh/.ssh/authorized_keys (home synthesized by
# our build patch). Replaces the broken stock /product/bin/sshd. Idempotent.
DB=/data/ssh/dropbearmulti
HK=/data/ssh/dropbear_ed25519_host_key
PIDF=/data/ssh/dropbear.pid
BB=/data/docker/bin/busybox

[ -x "$DB" ] || { echo "FATAL: $DB missing/not built"; exit 1; }

# One-time: generate dropbear-format host key.
[ -f "$HK" ] || { echo "generating host key"; $DB dropbearkey -t ed25519 -f "$HK" >/dev/null 2>&1; }

# Stop any previous instance (idempotent re-run). busybox here has no pkill.
#
# VERIFY IDENTITY BEFORE KILLING. This pidfile lives in /data and therefore
# SURVIVES REBOOT, so by the time this runs its PID has usually been reused by
# something else entirely -- and this script runs as root at boot, from
# dockerd-svc.sh. `kill $(cat pidfile)` with no check is a root-privileged kill
# of an arbitrary process; on an unlucky boot that is a random system service.
#
# Exactly the trap already fixed for dockerd.pid in 862dd09, where a reused PID
# made dockerd refuse to start and init crash-loop the service. A stale pidfile
# after reboot is the NORMAL case here, not the exception.
if [ -f "$PIDF" ]; then
  OLD=$($BB cat "$PIDF" 2>/dev/null)
  if [ -n "$OLD" ] && [ -r "/proc/$OLD/cmdline" ] &&
     $BB tr '\0' ' ' < "/proc/$OLD/cmdline" 2>/dev/null | $BB grep -q dropbearmulti; then
    echo "stopping previous dropbear (pid=$OLD)"
    kill "$OLD" 2>/dev/null
  else
    echo "stale pidfile: pid=${OLD:-none} is not dropbear - NOT killing it"
  fi
fi
rm -f "$PIDF"

# Password auth + syslog are compiled out, so -s/-E don't exist: pubkey-only,
# logs to stderr by default. -p 22 : port. -r : host key. -P : pidfile.
# Daemonizes (no -F).
$DB dropbear -p 22 -r "$HK" -P "$PIDF" >/data/ssh/dropbear.log 2>&1
RC=$?
sleep 1
echo "dropbear start rc=$RC"
$BB netstat -ltn 2>/dev/null | $BB grep ":22 " || echo "NOT LISTENING"
