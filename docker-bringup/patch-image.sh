#!/system/bin/sh
# Repackage claude-term:latest with the current server/ + public/ sources.
#
# Fast path for an app-only change: a full claude-term-build.sh re-runs apt, an
# npm install and a pinned gh download over a router that is known to flake, for
# a change that touches nothing but JavaScript. This starts from the existing
# image instead, so it needs no network at all.
#
# SOURCE OF TRUTH IS THE REPO. The default context used to be the on-device copy
# at /data/docker/claude-term, which nothing kept in step with git -- the same
# drift that let /data/docker/*.sh diverge for a month. Prefer the pulled repo
# and fall back to the on-device copy only if the repo is absent.
set -e
DK="/data/docker/bin/docker -H unix:///data/docker/docker.sock"

if [ -n "${CLAUDE_TERM_CTX:-}" ]; then CTX="$CLAUDE_TERM_CTX"
elif [ -d /data/NVidiaShieldPro/claude-term/server ]; then CTX=/data/NVidiaShieldPro/claude-term
else CTX=/data/docker/claude-term
fi
[ -d "$CTX/server" ] || { echo "FATAL: no server/ under $CTX"; exit 1; }
echo "context: $CTX"

CAND=claude-term:patch-candidate

$DK rm -f ct-patch 2>/dev/null || true
$DK create --name ct-patch claude-term:latest >/dev/null

# `docker cp DIR container:/app/` copies DIR *into* /app, i.e. onto /app/server.
# It MERGES: a file deleted in git is not removed from the image. Delete first so
# the image matches the tree rather than accumulating whatever used to be there.
$DK exec ct-patch true 2>/dev/null || true   # no-op; container is created, not running
$DK cp "$CTX/server" ct-patch:/app/
$DK cp "$CTX/public" ct-patch:/app/

$DK commit ct-patch "$CAND" >/dev/null
$DK rm -f ct-patch >/dev/null
echo "candidate committed: $CAND"

# ---- VERIFY BEFORE THE LIVE TAG MOVES -------------------------------------
# `docker commit` bakes a broken image without complaint, and `set -e` does NOT
# fire for the left-hand side of an && list -- so a failed check cannot by itself
# stop a commit. This project already shipped an image whose app was missing
# while the build reported success. Therefore: commit to a CANDIDATE tag, prove
# the candidate runs, and only then move claude-term:latest. The running
# container keeps working throughout; a failure here costs nothing.
#
# Assert on a SUCCESS MARKER in the output, never on an exit code alone.
set +e
OUT=$($DK run --rm --entrypoint node "$CAND" --check server/index.js 2>&1 && echo SERVER_PARSE_OK)
RC=$?
set -e
case "$OUT" in
  *SERVER_PARSE_OK*) echo "verify: server/index.js parses" ;;
  *) echo "FATAL: candidate fails node --check (rc=$RC). claude-term:latest UNTOUCHED."
     echo "$OUT"
     $DK rmi "$CAND" >/dev/null 2>&1 || true
     exit 1 ;;
esac

# The picker lives in dirs.js; assert it actually landed rather than trusting cp.
set +e
OUT2=$($DK run --rm --entrypoint node "$CAND" -e 'import("./server/dirs.js").then(m=>console.log(typeof m.listDirs==="function"?"DIRS_OK":"DIRS_BAD")).catch(e=>{console.log("DIRS_BAD",e.message)})' 2>&1)
set -e
case "$OUT2" in
  *DIRS_OK*) echo "verify: dirs.js exports listDirs" ;;
  *) echo "FATAL: dirs.js missing or broken in candidate. claude-term:latest UNTOUCHED."
     echo "$OUT2"
     $DK rmi "$CAND" >/dev/null 2>&1 || true
     exit 1 ;;
esac

$DK tag "$CAND" claude-term:latest
$DK rmi "$CAND" >/dev/null 2>&1 || true
echo PATCH_DONE
echo "note: the RUNNING container still uses the old image until it is recreated:"
echo "      sh /data/docker/claude-term.sh"
