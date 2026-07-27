#!/system/bin/sh
# install-device-scripts.sh - copy the tracked service scripts from the pulled
# repo into /data/docker, byte-verified.
#
# WHY THIS EXISTS
#   /data/docker/*.sh are the scripts the device actually boots and runs. They
#   were copies, made once by hand. deploy/ pulled the repo on every boot but
#   NEVER copied anything out of it, so a fix committed here reached the device
#   only when a human remembered to copy it across. On 2026-07-26 they happened
#   to match, because someone had run the one-off /data/docker/install-refresh.sh
#   -- a script that existed only on the device and was itself untracked. The
#   installer for the boot services was not in the repo.
#
#   That is the same silent-drift failure that left the Shield unusable for a
#   month, just moved down a layer. This closes it: the repo becomes the source
#   of truth for /data/docker, automatically, on every deploy.
#
# WHAT IT DELIBERATELY DOES NOT DO: RESTART ANYTHING.
#   Copy only. Two reasons, and both are load-bearing.
#
#   1. Self-kill. This runs from redeploy.sh, which can be reached from the daily
#      loop in repo-refresh-svc.sh. If installing repo-refresh-svc.sh also
#      restarted it, the install would kill its own ancestor mid-run.
#   2. Bouncing dockerd to pick up a new dockerd-svc.sh would take every
#      container down -- including claude-term, possibly mid-session.
#
#   So: new copies land now, and take effect the next time something starts them.
#   repo-refresh.sh is re-invoked fresh each cycle, so it applies within a day.
#   dockerd-svc.sh applies at the next boot, which is correct: a boot script
#   should change at a boot.
set -e

REPO_DIR=${REPO_DIR:-/data/NVidiaShieldPro}
SRC="$REPO_DIR/docker-bringup"
ROOT=/data/docker

# BOOT SERVICES -- what the device starts on its own. claude-term.sh and
# claude-term-build.sh are here so the working copy tracks the repo, but note
# that redeploy.sh still does not RUN claude-term.sh: that container needs the
# untracked on-device env.
BOOT_FILES="dockerd-svc.sh repo-refresh.sh repo-refresh-svc.sh dropbear.sh
            claude-term.sh claude-term-build.sh c2.sh kuma-netfix.sh cleanup.sh"

# OPERATOR RECIPES -- run by hand, but they are how the device gets REBUILT.
# These lived only on /data/docker and were in no repo at all, which meant the
# recovery procedure for a wiped Shield existed in exactly one place: the Shield.
# gh-provision.sh is how credentials get installed, clone-all.sh is how the 55
# repos come back, c2-build.sh and patch-image.sh are the image recipes that
# `docker build` cannot reproduce on this kernel. Losing these is losing the
# ability to rebuild, which is worse than losing any running service.
#
# Same copy-only, never-restart contract as the boot set -- these are operator
# tools, so nothing here is ever invoked automatically.
TOOL_FILES="gh-provision.sh clone-all.sh install-refresh.sh verify-clones.sh
            verify-mem.sh c2-build.sh patch-image.sh postboot.sh
            check-shield.sh ask.sh"

FILES="$BOOT_FILES $TOOL_FILES"

echo "=== install device scripts from $SRC ==="
updated=0
unchanged=0
for f in $FILES; do
  if [ ! -f "$SRC/$f" ]; then
    echo "  skip $f (absent in repo)"
    continue
  fi

  A=$(md5sum < "$SRC/$f" | cut -d' ' -f1)
  B=$(md5sum < "$ROOT/$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$A" = "$B" ]; then
    unchanged=$((unchanged+1))
    continue
  fi

  # A carriage return is fatal to /system/bin/sh, and DEVIL has core.autocrlf=true.
  # DETECT and abort -- never repair it here. Toybox sed does not interpret \r, so
  # the reflexive `sed -i 's/\r$//'` guard degrades to `s/r$//` and silently strips
  # a trailing literal 'r' from every line. That is how ct-build:/app/server once
  # became /app/serve while the build still reported success.
  if od -c "$SRC/$f" | grep -q '\\r'; then
    echo "  FATAL: CR found in $f - refusing to install. Fix the line endings in git."
    exit 1
  fi

  # Write to a temp file and RENAME into place. Never `cp` over the destination.
  #
  # /system/bin/sh reads a script incrementally, by byte offset, as it executes.
  # `cp` truncates and rewrites the SAME inode, so overwriting a script that is
  # currently running makes the live shell resume at its old offset inside new
  # content -- it starts executing whatever text now sits there. repo-refresh-svc.sh
  # is the worst case: it sleeps for 24 hours between iterations, so it is almost
  # always mid-execution when a deploy lands.
  #
  # `mv` within /data is a rename: atomic, and it gives the new file a NEW inode.
  # The running shell keeps its open descriptor on the old inode and finishes its
  # current pass unharmed; the next invocation picks up the new file.
  T="$ROOT/.$f.new"
  cp "$SRC/$f" "$T"
  C=$(md5sum < "$T" | cut -d' ' -f1)
  if [ "$C" != "$A" ]; then
    rm -f "$T"
    echo "  FATAL: $f differs after write (src $A != staged $C)"
    exit 1
  fi
  mv "$T" "$ROOT/$f"
  echo "  UPDATED $f  md5=$A"
  updated=$((updated+1))
done

echo "=== installed: $updated updated, $unchanged unchanged ==="
# An `if`, not `[ ... ] && echo ...`. Under `set -e` a failing AND-OR list at the
# end of a script is NOT exempt, so the one-liner form would exit 1 on the normal
# "nothing changed" path -- and take redeploy.sh down with it.
if [ "$updated" -gt 0 ]; then
  echo "note: dockerd-svc.sh changes apply at NEXT BOOT; repo-refresh.sh applies next cycle."
fi
exit 0
