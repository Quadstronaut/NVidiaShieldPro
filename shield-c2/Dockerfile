# syntax=docker/dockerfile:1
# shield-c2 — multi-stage arm64 build on glibc (bookworm), NOT alpine (D3/I9):
# kernel 4.9.141 + musl/newer toolchains trip ENOSYS on absent syscalls; glibc
# 2.36 degrades instead of hard-failing. Runtime stage carries only build output
# + production deps to stay under the 250 MB target (I10).
#
# Digest is for node:20-bookworm-slim linux/arm64. Verify on-device before ship;
# documented fallback is node:18-bullseye-slim (logged exception, I9).

# ---- build stage ----
FROM --platform=linux/arm64 node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df AS build
WORKDIR /app
# Install ALL deps (incl. dev) for the SvelteKit build.
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build
# Prune to production deps only for the runtime copy.
RUN npm prune --omit=dev

# ---- runtime stage ----
FROM --platform=linux/arm64 node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df AS runtime
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
EXPOSE 8888
# adapter-node honours PORT; we mirror SHIELD_C2_PORT into PORT at start so a
# single env controls the listen port.
ENTRYPOINT ["sh", "-c", "PORT=${SHIELD_C2_PORT:-8888} exec node build"]
