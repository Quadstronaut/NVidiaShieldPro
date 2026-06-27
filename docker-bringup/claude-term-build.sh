#!/system/bin/sh
# Build claude-term:latest ON THE SHIELD via run+exec+commit.
#
# WHY NOT `docker build`: on this kernel (4.9.141) the legacy builder does NOT
# apply --network=host to RUN steps (BuildKit is absent, so we can't switch),
# and the docker0 bridge is broken (ARP INCOMPLETE) -> build RUN steps have no
# network -> apt/npm can't resolve. `docker run --network=host` DOES get host
# net, so we build inside a live host-net container and commit it.
#
# Gotchas baked in (all verified on-device):
#   - apt drops to the sandboxed _apt user which can't do DNS here ->
#     APT::Sandbox::User=root keeps fetches as root.
#   - the LAN router (10.0.0.1, first nameserver) flakes under apt's burst, and
#     no IPv6 route -> pin 8.8.8.8/1.1.1.1 + ForceIPv4.
#   - node:20 already has uid 1000 (the `node` user) -> useradd -o for `claude`.
# Secret/token are NOT baked here; the launcher injects them at run time.
set -e
DK="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
IMG="node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df"
CTX=${CLAUDE_TERM_CTX:-/data/docker/claude-term}

$DK rm -f ct-build 2>/dev/null || true

echo "== start host-net build container =="
$DK run -d --network=host --name ct-build "$IMG" sleep infinity

echo "== apt: tmux git ripgrep ca-certificates (sandbox=root, pinned DNS, IPv4) =="
$DK exec ct-build sh -c 'printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf && apt-get -o APT::Sandbox::User=root -o Acquire::ForceIPv4=true update && apt-get -o APT::Sandbox::User=root -o Acquire::ForceIPv4=true install -y --no-install-recommends tmux git ripgrep ca-certificates && rm -rf /var/lib/apt/lists/*'

echo "== non-root claude (uid 1000; -o: node:20 already uses 1000) + dirs =="
$DK exec ct-build sh -c 'useradd -m -o -u 1000 claude && mkdir -p /app /data/claude'

echo "== copy app into /app =="
$DK cp "$CTX/package.json"  ct-build:/app/package.json
$DK cp "$CTX/server"        ct-build:/app/server
$DK cp "$CTX/public"        ct-build:/app/public
$DK cp "$CTX/snippets.json" ct-build:/app/snippets.json

echo "== npm: app deps (ws only — v2 dropped node-pty/xterm) + claude-code CLI (pinned, R5) =="
$DK exec -w /app ct-build sh -c 'printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf && npm install --no-audit --no-fund --omit=dev && npm install -g @anthropic-ai/claude-code@2.1.185'

echo "== ownership =="
$DK exec ct-build sh -c 'chown -R claude:claude /app /home/claude /data/claude'

echo "== verify: claude headless drives the v2 UI; node server parses =="
$DK exec ct-build sh -c 'which claude && claude --version'
$DK exec -w /app ct-build node --check server/index.js && echo SERVER_PARSE_OK

echo "== commit -> claude-term:latest =="
$DK commit \
  --change 'WORKDIR /app' \
  --change 'USER claude' \
  --change 'ENV CLAUDE_TERM_PORT=7777' \
  --change 'ENV CLAUDE_TERM_WORKSPACE=/data/claude' \
  --change 'ENV CLAUDE_TERM_SNIPPETS=/data/claude/snippets.json' \
  --change 'ENV NODE_ENV=production' \
  --change 'EXPOSE 7777' \
  --change 'ENTRYPOINT ["node","server/index.js"]' \
  ct-build claude-term:latest

$DK rm -f ct-build
echo "claude-term:latest built (run+commit)"
