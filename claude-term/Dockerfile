# syntax=docker/dockerfile:1
# claude-term — single-stage arm64 on glibc bookworm (D4/I7). kernel 4.9.141 +
# musl trips ENOSYS; glibc 2.36 degrades instead. Digest is node:20-bookworm-slim
# linux/arm64 (same pin as shield-c2). Fallback node:18-bullseye-slim (logged).
FROM --platform=linux/arm64 node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df

# OS deps: git + ripgrep (Claude Code), ca-certificates (TLS). tmux is kept only
# as an optional on-box shell escape hatch — v2 drives Claude Code headless, not
# via tmux, so it is not on the agent path.
# Force reliable DNS first: the LAN router (10.0.0.1, first nameserver) flakes
# under apt's burst of parallel lookups ("Temporary failure resolving"). Pin
# 8.8.8.8/1.1.1.1, force IPv4, and retry so the on-device build is deterministic.
# openssh-client (ssh + ssh-keygen for Starhold/qflix), curl (fetch gh). NOTE: the
# on-device image is actually built by docker-bringup/claude-term-build.sh (run+commit,
# because this kernel's `docker build` has no host network) — keep the two in sync.
RUN printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf \
    && apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 update \
    && apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 install -y --no-install-recommends \
      tmux git ripgrep ca-certificates openssh-client curl \
    && rm -rf /var/lib/apt/lists/*

# gh CLI — pinned + sha256-verified against the release's own checksums sidecar.
# Baked in (not a runtime install): survives container recreate; verify the version
# in the URL AND the bytes against the signed sidecar.
ARG GH_VER=2.96.0
# The tarball MUST keep its real release filename: `sha256sum -c` opens the name
# recorded in the manifest, so saving it as gh.tgz fails verification every time
# ("FAILED open or read"), independent of the network. Hence curl -O.
RUN set -eux; cd /tmp; base="https://github.com/cli/cli/releases/download/v${GH_VER}"; \
    tgz="gh_${GH_VER}_linux_arm64.tar.gz"; \
    curl -fsSL -O "$base/$tgz"; \
    curl -fsSL -o gh.sums "$base/gh_${GH_VER}_checksums.txt"; \
    grep " $tgz\$" gh.sums | sha256sum -c -; \
    tar -xzf "$tgz"; install -m 0755 "gh_${GH_VER}_linux_arm64/bin/gh" /usr/local/bin/gh; \
    rm -rf "$tgz" gh.sums "gh_${GH_VER}_linux_arm64"; gh --version

# Non-root user owns the app and runs Claude Code (I8).
RUN useradd -m -u 1000 claude
WORKDIR /app

# App deps (ws only — v2 dropped node-pty/xterm) + Claude Code CLI on PATH,
# version-pinned for reproducibility (R5). Same DNS pin for registry fetches.
COPY package.json ./
RUN printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf \
    && npm install --no-audit --no-fund --omit=dev \
    && npm install -g @anthropic-ai/claude-code@2.1.185

COPY server ./server
COPY public ./public
COPY snippets.json ./snippets.json

# /data/claude (workspace) + /home/claude/.claude (creds vol) are writable by claude.
RUN mkdir -p /data/claude && chown -R claude:claude /app /data/claude /home/claude
USER claude

ENV CLAUDE_TERM_PORT=7777 \
    CLAUDE_TERM_WORKSPACE=/data/claude \
    CLAUDE_TERM_SNIPPETS=/data/claude/snippets.json \
    NODE_ENV=production
EXPOSE 7777
ENTRYPOINT ["node", "server/index.js"]
