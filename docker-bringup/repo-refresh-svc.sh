#!/system/bin/sh
# Self-supervising daily loop around repo-refresh.sh.
#
# Android has no cron. Busybox here HAS a crond applet, but the proven pattern on
# this device is a setsid'd loop launched from dockerd-svc.sh at
# sys.boot_completed -- the same slot dropbear and tailscaled use. One boot
# trigger, one supervision mechanism, no races between two schedulers.
#
# Waits for claude-term before the first run: at boot this starts before dockerd
# has finished coming up, so an immediate refresh would fail every time.
#
# Log is rotated at ~1 MB so an always-on device cannot fill /data over months.
BIN=/data/docker/bin
BB=$BIN/busybox
ROOT=/data/docker
LOG=$ROOT/repo-refresh.log
D="$BIN/docker -H unix://$ROOT/docker.sock"
INTERVAL=${REPO_REFRESH_INTERVAL:-86400}   # 24h

export PATH=$BIN:/system/bin:/system/xbin

log() { echo "$($BB date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

log "repo-refresh-svc started (interval ${INTERVAL}s)"

while :; do
  # wait (up to ~10 min) for claude-term to be running
  waited=0
  while [ $waited -lt 600 ]; do
    if $D inspect -f '{{.State.Running}}' claude-term 2>/dev/null | $BB grep -q true; then break; fi
    sleep 15; waited=$((waited+15))
  done

  if [ $waited -ge 600 ]; then
    log "claude-term not running after ${waited}s - skipping this cycle"
  else
    # 1) Pull THIS repo and redeploy on change.
    #
    # shield-deploy.rc fires only on sys.boot_completed, and this box stays up for
    # days (4.4 days at one measurement). So a fix pushed to GitHub sat unapplied
    # until someone happened to reboot -- which is how /data/docker drifted from
    # the repo in the first place. Reusing this loop keeps the design's rule of one
    # boot trigger and one supervision mechanism, instead of adding a scheduler.
    #
    # Safe to call from in here: redeploy.sh -> install-device-scripts.sh only
    # COPIES (by atomic rename) and never restarts anything, so this cannot kill
    # its own ancestor, and a new copy of this very file cannot corrupt the
    # running one.
    if [ -f /data/NVidiaShieldPro/deploy/pull-and-deploy.sh ]; then
      if sh /data/NVidiaShieldPro/deploy/pull-and-deploy.sh >/dev/null 2>&1; then
        log "deploy: ok"
      else
        log "deploy: FAILED - see /data/docker/deploy.log"
      fi
    fi

    # 2) Refresh the 55 clones.
    if [ -f $ROOT/repo-refresh.sh ]; then
      out=$(sh $ROOT/repo-refresh.sh 2>&1)
      log "refresh: $(echo "$out" | $BB tr '\n' ' ')"
    else
      log "repo-refresh.sh absent - nothing to do"
    fi
  fi

  # rotate at ~1 MB
  sz=$($BB stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$sz" -gt 1048576 ] && $BB mv "$LOG" "$LOG.1"

  sleep "$INTERVAL"
done
