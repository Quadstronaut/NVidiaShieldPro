# syntax=docker/dockerfile:1
# claude-term — single-stage arm64 on glibc bookworm (D4/I7). kernel 4.9.141 +
# musl trips ENOSYS; glibc 2.36 degrades instead. Digest is node:20-bookworm-slim
# linux/arm64 (same pin as shield-c2). Fallback node:18-bullseye-slim (logged).
FROM --platform=linux/arm64 node:20-bookworm-slim@sha256:10fc5f5f33cba34a4befa58fcf95f724e67707fab7c32fb8cd3fcf90ebcc20df

# OS deps: tmux (sessions), git + ripgrep (Claude Code), ca-certificates (TLS).
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux git ripgrep ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root user owns the app and runs Claude Code (I8).
RUN useradd -m -u 1000 claude
WORKDIR /app

# App deps (node-pty prebuilt fetched here) + Claude Code CLI on PATH.
COPY package.json ./
RUN npm install --no-audit --no-fund --omit=dev \
    && npm install -g @anthropic-ai/claude-code

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
