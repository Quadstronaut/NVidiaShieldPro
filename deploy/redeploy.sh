#!/system/bin/sh
# redeploy.sh — re-run the active service launchers after a pull.
# Each launcher is idempotent (docker rm -f + run), so re-running is safe; it just
# bounces the container onto the new image/config. Edit ACTIVE as the stack grows.
set -e

REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
BR="$REPO_DIR/docker-bringup"

# Order matters loosely: monitors first, app last.
ACTIVE="kuma-netfix.sh c2.sh"

for s in $ACTIVE; do
  if [ -f "$BR/$s" ]; then
    echo "=== launcher: $s ==="
    sh "$BR/$s" || echo "WARN: $s exited non-zero"
  else
    echo "skip (absent): $s"
  fi
done
echo "=== redeploy done ==="
