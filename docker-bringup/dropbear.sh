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
[ -f "$PIDF" ] && kill "$(cat $PIDF)" 2>/dev/null
rm -f "$PIDF"

# Password auth + syslog are compiled out, so -s/-E don't exist: pubkey-only,
# logs to stderr by default. -p 22 : port. -r : host key. -P : pidfile.
# Daemonizes (no -F).
$DB dropbear -p 22 -r "$HK" -P "$PIDF" >/data/ssh/dropbear.log 2>&1
RC=$?
sleep 1
echo "dropbear start rc=$RC"
$BB netstat -ltn 2>/dev/null | $BB grep ":22 " || echo "NOT LISTENING"
