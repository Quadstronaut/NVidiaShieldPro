#!/system/bin/sh
# Repackage claude-term:latest from the on-device build context (picks up any
# server/public change): create a fresh container, copy server+public in, commit.
set -e
DK="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$DK rm -f ct-patch 2>/dev/null || true
$DK create --name ct-patch claude-term:latest
$DK cp /data/docker/claude-term/server ct-patch:/app/
$DK cp /data/docker/claude-term/public ct-patch:/app/
$DK commit ct-patch claude-term:latest
$DK rm -f ct-patch
echo PATCH_DONE
