#!/system/bin/sh
# Install the refresh service from the freshly pulled repo, byte-verified.
set -e
R=/data/NVidiaShieldPro
ROOT=/data/docker

echo "=== pull ==="
sh $R/deploy/git-sync.sh 2>&1 | tail -2

echo
echo "=== install (copy verbatim, verify md5, NEVER transform) ==="
for f in repo-refresh.sh repo-refresh-svc.sh dockerd-svc.sh; do
  cp "$R/docker-bringup/$f" "$ROOT/$f"
  A=$(md5sum < "$R/docker-bringup/$f" | cut -d' ' -f1)
  B=$(md5sum < "$ROOT/$f" | cut -d' ' -f1)
  [ "$A" = "$B" ] || { echo "FATAL: $f copy differs"; exit 1; }
  # CR would be fatal to /system/bin/sh; detect and abort rather than sed it
  if od -c "$ROOT/$f" | grep -q '\\r'; then echo "FATAL: CR in $f"; exit 1; fi
  echo "  ok $f ($(wc -c < $ROOT/$f) bytes, md5 $A)"
done

echo
echo "=== boot wiring present? ==="
grep -c 'repo-refresh-svc.sh' $ROOT/dockerd-svc.sh | { read n; [ "$n" -ge 1 ] && echo "  wired into dockerd-svc.sh" || { echo "  FATAL: not wired"; exit 1; }; }
grep -c 'claude-steer' $R/deploy/redeploy.sh | { read n; [ "$n" = "0" ] && echo "  claude-steer.sh correctly NOT in redeploy" || echo "  WARN: claude-steer still referenced"; }

echo
echo "=== start the loop NOW (do not wait for a reboot) ==="
BB=$ROOT/bin/busybox
for p in $($BB ps -ef 2>/dev/null | $BB grep repo-refresh-svc | $BB grep -v grep | $BB awk '{print $1}'); do kill -9 "$p" 2>/dev/null; done
$BB setsid $BB sh $ROOT/repo-refresh-svc.sh >/dev/null 2>&1 &
sleep 2
$BB ps -ef 2>/dev/null | $BB grep repo-refresh-svc | $BB grep -v grep | head -2

echo
echo "=== run one refresh immediately so the gate has a stamp ==="
sh $ROOT/repo-refresh.sh
