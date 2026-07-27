#!/system/bin/sh
# Bring up claude-term: phone-driven Claude Code web terminal on the Shield,
# port 7777 (D5). Host networking (bridge dead on this kernel, I4) -> reachable
# at http://10.0.0.88:7777. Workspace /data/claude is the ONLY writable host
# mount besides the claude-home volume (I2); NO docker socket (I9).
# claude-home maps the WHOLE container home (/home/claude), not just .claude/,
# so runtime state outside the dir -- ~/.claude.json (onboarding flag, theme,
# auth/account) -- survives container restarts. Steering lives at
# /home/claude/.claude inside the same volume.
# Secret + OAuth token come from a sourced untracked claude-term.env (I11).
# --restart=always = returns when dockerd does. Idempotent: re-run replaces it.
set -e

HERE=$(dirname "$0")
# This script exists in TWO places on the device: the repo checkout at
# /data/NVidiaShieldPro/docker-bringup/ (pulled by deploy/) and the working copy
# at /data/docker/. The untracked env file -- secret + OAuth token -- only ever
# sits beside the SECOND one. Sourcing relative to $0 alone therefore meant that
# running the repo copy loaded no credentials at all, and the script's first real
# action below is `docker rm -f claude-term`. Search both, and record which won.
ENV_SRC=""
for _c in "$HERE/claude-term.env" /data/docker/claude-term.env; do
  if [ -f "$_c" ]; then . "$_c"; ENV_SRC="$_c"; break; fi
done

BB=/data/docker/bin/busybox
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
IMG=claude-term:latest
NAME=claude-term
PORT=${CLAUDE_TERM_PORT:-7777}
CTX=${CLAUDE_TERM_CTX:-/data/docker/claude-term}
VOL=claude-home

# Auth: OPEN on the LAN by default (no passphrase), like shield-c2. To re-enable
# the passphrase gate, set CLAUDE_TERM_NO_AUTH=0 and a CLAUDE_TERM_SECRET in the env.
NO_AUTH=${CLAUDE_TERM_NO_AUTH:-1}
if [ "$NO_AUTH" != "1" ] && [ -z "$CLAUDE_TERM_SECRET" ]; then
  echo "FATAL: auth enabled but CLAUDE_TERM_SECRET unset"; exit 1
fi
# FATAL, not a warning, and checked HERE -- before the `docker rm -f` below.
# As a warning this was a live footgun: re-running the script from the repo copy
# tore down a working, authenticated container and replaced it with one that
# demands /login (R3), with no obvious way back. Refusing to start is strictly
# better than destroying the thing that worked. Set CLAUDE_TERM_ALLOW_NO_TOKEN=1
# for a genuine first bringup, where there is no container to lose.
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ "${CLAUDE_TERM_ALLOW_NO_TOKEN:-0}" != "1" ]; then
  echo "FATAL: CLAUDE_CODE_OAUTH_TOKEN is empty (env sourced from: ${ENV_SRC:-NONE})."
  echo "  looked for: $HERE/claude-term.env and /data/docker/claude-term.env"
  echo "  refusing to replace the running container with one that cannot authenticate."
  echo "  first-time bringup with no container to lose: CLAUDE_TERM_ALLOW_NO_TOKEN=1 sh $0"
  exit 1
fi
echo "env sourced from: ${ENV_SRC:-NONE}"

echo "=== dockerd reachable? ==="
$DOCKER version --format 'server {{.Server.Version}}' || { echo "FATAL: dockerd not responding"; exit 1; }

echo "=== drop any previous $NAME FIRST (frees the port on re-run) ==="
$DOCKER rm -f $NAME 2>/dev/null || true

echo "=== assert port $PORT free (vs 8888 c2 / 3001 kuma) ==="
if $BB netstat -ltn 2>/dev/null | $BB grep -qE "[:.]$PORT[[:space:]]"; then
  echo "FATAL: port $PORT already in use"; exit 1
fi
echo "port $PORT free"

echo "=== obtain image $IMG (load tar, else build from $CTX) ==="
if $DOCKER image inspect $IMG >/dev/null 2>&1; then echo "image present"
elif [ -f /data/docker/claude-term.tar ]; then $DOCKER load -i /data/docker/claude-term.tar
elif [ -f "$HERE/claude-term-build.sh" ]; then
  # `docker build` can't get host networking on this kernel (bridge dead, BuildKit
  # absent) -> build via run+commit instead. See claude-term-build.sh header.
  echo "building image via run+commit ($HERE/claude-term-build.sh)"
  CLAUDE_TERM_CTX="$CTX" sh "$HERE/claude-term-build.sh"
else echo "FATAL: no image, no tar, no claude-term-build.sh"; exit 1
fi

echo "=== ensure workspace /data/claude writable by in-container claude (uid 1000) ==="
mkdir -p /data/claude
chown 1000:1000 /data/claude 2>/dev/null || true
chmod 755 /data/claude

echo "=== run $NAME (host net, rw /data/claude + home vol, NO socket, port $PORT) ==="
$DOCKER run -d \
  --name $NAME \
  --restart=always \
  --network host \
  --group-add 3003 \
  -e CLAUDE_TERM_NO_AUTH=$NO_AUTH \
  -e CLAUDE_TERM_PORT=$PORT \
  -e CLAUDE_TERM_SECRET="$CLAUDE_TERM_SECRET" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  -e CLAUDE_TERM_WORKSPACE=/data/claude \
  -e CLAUDE_TERM_SNIPPETS=/data/claude/snippets.json \
  -e HOME=/home/claude \
  -v /data/claude:/data/claude \
  -v $VOL:/home/claude \
  $IMG

# Seed claude-code's first-run state into the persistent ~/.claude.json so a
# fresh/re-provisioned home volume never re-triggers the theme picker, trust
# dialog, or bypass-permissions prompt (none of which are answerable on the
# tmux->browser->mobile path). IDEMPOTENT: only fills MISSING keys, never
# clobbers the user's later choices. Version-sensitive (claude-code field
# names) -> guarded; a no-op just means a one-time prompt, not a failure.
#
# DEPTH MATTERS. This originally walked one level of /data/claude/GIT, which was
# right when clones were flat. Phase 2 moved them to GIT/<CATEGORY>/<repo>, so
# one level started returning CATEGORY directories -- which are not repos and are
# never a cwd. The result: 54 of 55 repositories had no trust record, and the one
# that did was added by hand. Walk BOTH levels, and book-writing, which lives
# outside GIT/ on purpose.
#
# This is the single most user-visible fix in the stack: an untrusted cwd stops a
# session before the user can type anything, and the prompt is not answerable on
# a phone. Do not "simplify" this back to one level.
echo "=== seed first-run state into ~/.claude.json (idempotent) ==="
$DOCKER exec $NAME node -e 'const fs=require("fs"),p="/home/claude/.claude.json";let c={};try{c=JSON.parse(fs.readFileSync(p))}catch(e){}let ch=false;if(!c.hasCompletedOnboarding){c.hasCompletedOnboarding=true;ch=true}if(!c.theme){c.theme="dark-ansi";ch=true}if(!c.bypassPermissionsModeAccepted){c.bypassPermissionsModeAccepted=true;ch=true}c.projects=c.projects||{};const dirs=["/data/claude","/data/claude/GIT","/data/claude/book-writing"];try{for(const cat of fs.readdirSync("/data/claude/GIT")){const cp="/data/claude/GIT/"+cat;if(!fs.statSync(cp).isDirectory())continue;dirs.push(cp);try{for(const r of fs.readdirSync(cp)){const rp=cp+"/"+r;if(fs.statSync(rp).isDirectory())dirs.push(rp)}}catch(e){}}}catch(e){}let n=0;for(const d of dirs){if(!c.projects[d]||!c.projects[d].hasTrustDialogAccepted){c.projects[d]=Object.assign({},c.projects[d]||{},{hasTrustDialogAccepted:true});ch=true;n++}}if(ch){fs.writeFileSync(p,JSON.stringify(c,null,2));console.log("seeded "+n+" new of "+dirs.length+" paths")}else{console.log("already seeded ("+dirs.length+" paths)")}' 2>/dev/null || echo "  (seed skipped: node/exec unavailable)"

echo "=== container state ==="
$DOCKER ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo "claude-term up at http://10.0.0.88:$PORT  (secret-gated, LAN only)"
