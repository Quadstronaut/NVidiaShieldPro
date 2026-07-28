#!/system/bin/sh
# One-shot refresh of every clone under /data/claude/GIT.
#
# Runs git INSIDE claude-term: the Android host has no git (Toybox), and the
# GitHub credentials live in the container's claude-home volume, not on the host.
#
# SAFETY: a repo with a dirty worktree is SKIPPED, never touched. The Shield is
# where work happens now, so an unattended job must never be able to discard
# in-progress edits. Merges are --ff-only for the same reason: if history has
# diverged, stop and let a human look rather than create a merge commit nobody
# asked for.
#
# book-writing IS refreshed here now. It was excluded while its transport was
# unresolved: it rode a per-repo deploy key kept outside the container mount, so
# in-container git could not reach it at all. That is fixed -- the container
# rewrites ssh origins to https and authenticates with the PAT -- and the whole
# point of moving the repo onto the Shield was to work on it here. A repo the
# device is primary for is the LAST one that should silently fall behind.
#
# Writes /data/claude/.last-refresh so the parity gate can assert freshness.
set -e
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"

$D exec -u claude claude-term sh -c '
  ok=0; skipped=0; failed=0; behind=0
  faillist=""; skiplist=""
  for d in /data/claude/GIT/*/*/ /data/claude/book-writing/; do
    [ -d "$d/.git" ] || continue
    # Shell parameter expansion, NOT sed. A `sed "s#/$##"` here has its `$#`
    # expanded by the shell (argument count) before sed ever sees it, giving
    # "unterminated `s command" on every iteration.
    # Strip /data/claude/ (not /data/claude/GIT/) so repos living outside the
    # GIT tree get a sensible label instead of their full absolute path.
    rel=${d#/data/claude/}
    rel=${rel%/}

    # never touch a repo with uncommitted work
    if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
      skipped=$((skipped+1)); skiplist="$skiplist $rel"; continue
    fi

    if ! git -C "$d" fetch --all --prune --quiet 2>/dev/null; then
      failed=$((failed+1)); faillist="$faillist $rel"; continue
    fi

    # fast-forward only, and only if a tracking branch exists
    if git -C "$d" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
      if git -C "$d" merge --ff-only --quiet @{u} 2>/dev/null; then
        ok=$((ok+1))
      else
        behind=$((behind+1))   # diverged: left alone on purpose
      fi
    else
      ok=$((ok+1))             # fetched fine, just no upstream to merge
    fi
  done

  printf "%s refreshed=%s skipped_dirty=%s diverged=%s failed=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ok" "$skipped" "$behind" "$failed" \
    > /data/claude/.last-refresh
  [ -n "$skiplist" ] && echo "skipped(dirty):$skiplist" >> /data/claude/.last-refresh
  [ -n "$faillist" ] && echo "failed:$faillist"          >> /data/claude/.last-refresh
  cat /data/claude/.last-refresh
'
