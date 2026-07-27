#!/system/bin/sh
# Phase 2: populate /data/claude/GIT/<CATEGORY>/<repo> with REAL clones.
#
# Runs git INSIDE claude-term: the Android host has no git, and the GitHub
# credentials live in the container's claude-home volume.
#
# The manifest is read straight from /data/claude, which is already bind-mounted
# into the container. An earlier version used `docker cp` into /tmp, which lands
# as root and is then unreadable by the in-container `claude` user (uid 1000) —
# producing a silent cloned=0 with exit 0. Hence also the hard assertion at the
# end: a run that clones nothing must FAIL, not report success.
#
# Idempotent: an existing clone is fetched, never re-cloned.
set -e
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
MAN=/data/claude/.clone-manifest.tsv

[ -f "$MAN" ] || { echo "FATAL: no manifest at $MAN"; exit 1; }
chmod 644 "$MAN"
WANT=$(grep -c . "$MAN")
echo "manifest entries: $WANT"

echo "=== archive stale non-git dirs (idempotent; already done = no-op) ==="
SNAP=/data/claude/_pre-parity-snapshot.tgz
if [ -f "$SNAP" ]; then
  echo "  snapshot present, skipping: $SNAP ($(wc -c < $SNAP) bytes)"
else
  cd /data/claude/GIT
  STALE=""
  for d in */; do n=${d%/}; [ -d "$n/.git" ] || STALE="$STALE $n"; done
  if [ -n "$STALE" ]; then
    echo "  archiving:$STALE"; tar czf "$SNAP" $STALE
    for n in $STALE; do rm -rf "$n"; done
  else
    echo "  none found"
  fi
fi

echo
echo "=== clone / fetch every repo (in-container, as claude) ==="
$D exec -u claude claude-term sh -c '
  ok=0; fetched=0; failed=0; faillist=""
  while IFS="	" read -r rel url; do
    [ -n "$rel" ] || continue
    dst="/data/claude/GIT/$rel"
    if [ -d "$dst/.git" ]; then
      if git -C "$dst" fetch --all --prune --quiet 2>/dev/null; then fetched=$((fetched+1))
      else failed=$((failed+1)); faillist="$faillist $rel(fetch)"; fi
    else
      mkdir -p "$(dirname "$dst")"
      if git clone --quiet "$url" "$dst" 2>/dev/null; then ok=$((ok+1))
      else failed=$((failed+1)); faillist="$faillist $rel"; fi
    fi
  done < /data/claude/.clone-manifest.tsv
  echo "cloned=$ok fetched=$fetched failed=$failed"
  [ -n "$faillist" ] && echo "FAILED:$faillist" || true
'

echo
echo "=== result ==="
GOT=$($D exec -u claude claude-term sh -c 'find /data/claude/GIT -maxdepth 3 -name .git -type d | wc -l' | tr -d " \r")
echo "real git repos under /data/claude/GIT: $GOT (wanted $WANT)"
$D exec -u claude claude-term sh -c 'du -sh /data/claude/GIT 2>/dev/null | cut -f1' | sed 's/^/total size: /'

echo
echo "=== ASSERT ==="
[ "$GOT" -gt 0 ] || { echo "FATAL: zero repos cloned — this is a failure, not a success"; exit 1; }
if [ "$GOT" -lt "$WANT" ]; then
  echo "PARTIAL: $GOT of $WANT — see FAILED list above"; exit 2
fi
echo "OK: all $WANT repos present as real git clones"
