#!/system/bin/sh
# Rebuild shield-c2:latest via run+commit (docker build has no host-net here).
# SvelteKit/adapter-node: npm install + vite build, then the client-asset symlink
# fix, then commit with the same runtime config as the original Dockerfile.
set -e
DK="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
IMG="node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df"
CTX=/data/docker/shield-c2-src

$DK rm -f c2-build 2>/dev/null || true

echo "== host-net build container =="
$DK run -d --network=host --name c2-build "$IMG" sleep infinity

echo "== copy source =="
$DK exec c2-build sh -c 'mkdir -p /app'
$DK cp "$CTX/package.json"      c2-build:/app/package.json
$DK cp "$CTX/package-lock.json" c2-build:/app/package-lock.json
$DK cp "$CTX/svelte.config.js"  c2-build:/app/svelte.config.js
$DK cp "$CTX/vite.config.js"    c2-build:/app/vite.config.js
$DK cp "$CTX/.npmrc"            c2-build:/app/.npmrc
$DK cp "$CTX/src"               c2-build:/app/src

echo "== npm install + vite build (DNS pinned) =="
$DK exec -w /app c2-build sh -c 'printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf && npm install --no-audit --no-fund && npm run build'

echo "== adapter-node client-asset symlink fix (else /_app/* 404s) =="
$DK exec -w /app c2-build sh -c 'ln -sfn ../../client build/server/chunks/client'

echo "== commit -> shield-c2:latest =="
$DK commit \
  --change 'WORKDIR /app' \
  --change 'ENV NODE_ENV=production' \
  --change 'ENV SHIELD_C2_PORT=8888' \
  --change 'ENV SHIELD_C2_INTERVAL_MS=2000' \
  --change 'ENV HOST_PROC=/host/proc' \
  --change 'ENV HOST_SYS=/host/sys' \
  --change 'ENV HOST_DATA=/host/data' \
  --change 'EXPOSE 8888' \
  --change 'ENTRYPOINT ["sh","-c","PORT=${SHIELD_C2_PORT:-8888} exec node build"]' \
  c2-build shield-c2:latest

$DK rm -f c2-build
echo C2BUILD_DONE
