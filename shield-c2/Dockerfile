# syntax=docker/dockerfile:1
# shield-c2 — multi-stage arm64 build on glibc (bookworm), NOT alpine (D3/I9):
# kernel 4.9.141 + musl/newer toolchains trip ENOSYS on absent syscalls; glibc
# 2.36 degrades instead of hard-failing. Runtime stage carries only build output
# + production deps to stay under the 250 MB target (I10).
#
# Digest is for node:22-bookworm-slim (22.23.3) linux/arm64. Node >=22.17 is required
# by @sveltejs/kit 3 (engines) and cookie 2; Node 20 fails the build. Verify on-device before ship;
# documented fallback is node:18-bullseye-slim (logged exception, I9).

# ---- build stage ----
FROM --platform=linux/arm64 node:22-bookworm-slim@sha256:b20fe038d9592822dd534600a1ddf467e985178aa3fed60ec441a056c2cc45bd AS build
WORKDIR /app
# Install ALL deps (incl. dev) for the SvelteKit build, pinned to the lockfile.
# npm ci = deterministic install of exactly the audited tree (needs package-lock.json,
# which IS tracked in this repo) — closes the lock-bypass drift where `npm install`
# re-resolved from ^ ranges every build.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build
# Prune to production deps only for the runtime copy.
RUN npm prune --omit=dev

# ---- runtime stage ----
FROM --platform=linux/arm64 node:22-bookworm-slim@sha256:b20fe038d9592822dd534600a1ddf467e985178aa3fed60ec441a056c2cc45bd AS runtime
ENV NODE_ENV=production
# Defaults; the launcher overrides as needed. NO token (A2).
ENV SHIELD_C2_PORT=8888 \
    SHIELD_C2_INTERVAL_MS=2000 \
    HOST_PROC=/host/proc \
    HOST_SYS=/host/sys \
    HOST_DATA=/host/data \
    PORT=8888
WORKDIR /app
COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
# adapter-node bundled the static-serving handler into build/server/chunks/, so its
# import.meta.url-relative 'client' dir resolves to build/server/chunks/client (wrong)
# and every /_app/* asset 404s -> the app never hydrates. Symlink the expected path to
# the real client dir so sirv serves the bundle. (server/chunks/ depth is stable.)
RUN ln -sfn ../../client build/server/chunks/client
EXPOSE 8888
# adapter-node honours PORT; we mirror SHIELD_C2_PORT into PORT at start so a
# single env controls the listen port.
ENTRYPOINT ["sh", "-c", "PORT=${SHIELD_C2_PORT:-8888} exec node build"]
