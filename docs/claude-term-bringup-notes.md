# claude-term — on-Shield bringup notes

> **v2 (2026-06-26): the interface was pivoted from a terminal to a native
> Claude Code UI.** The v1 xterm.js → tmux → Claude-Code-TUI path was illegible on
> a phone (overlapping panels, horizontal overflow, a 6×-stacked tmux status bar at
> 390px — reproduced live). v2 renders Claude Code's **headless `stream-json`
> event stream** as native HTML (streamed markdown, ⏺ tool-call cards, diffs, `>`
> composer, cost footer). See [`SPEC-claude-term-v2.md`](SPEC-claude-term-v2.md) and
> the [v2 section](#v2--native-claude-code-ui-2026-06-26) at the bottom. The v1
> notes below remain as the historical record of the path v2 supersedes.

**Status (v1): LIVE on the Shield at `http://10.0.0.88:7777`** (2026-06-22;
full Claude-state persistence + collapsible Prompts panel + login-link banner added 2026-06-23).
Deployed over adb (`10.0.0.88:5555`). Build context lives at `/data/docker/claude-term`,
launcher + secret env at `/data/docker/claude-term.sh` / `claude-term.env`.

## How it runs
- `docker-bringup/claude-term.sh` is the launcher (host-net, `--restart=always`,
  `--group-add 3003`, rw `/data/claude` + the `claude-home` volume **mounted at the whole
  `/home/claude`** (see *State persistence*), **no** docker socket).
  Idempotent: re-running replaces the container.
- Image is built by `docker-bringup/claude-term-build.sh` (run+commit — NOT `docker build`).
- To reach it: browser → `http://10.0.0.88:7777` → passphrase (in `claude-term.env`) →
  create/attach a tmux-backed Claude Code session. Or the `shield-c2` dashboard (`:8888`)
  "Claude Code" link. `claude` auto-starts in each session, authenticated via the OAuth token.

## State persistence (everything Claude survives restart/reboot)

`claude-code` keeps its first-run + runtime state in **`~/.claude.json`** (onboarding flag,
theme, OAuth account, per-project `hasTrustDialogAccepted`) — a *sibling* of `~/.claude/`,
not inside it. The original mount (`claude-home → /home/claude/.claude`) left that file on the
**ephemeral container layer**, so every container restart wiped it and re-triggered the theme
picker, the trust dialog, and `/login` — none of which are answerable on the
tmux→browser→mobile path.

Fix (commit `609c19c`): mount `claude-home` at the **whole `/home/claude`**, steering nested
under `/home/claude/.claude` (one-time migration: `mkdir .claude; mv * .claude/`). Now
`~/.claude.json` lives in the volume and survives. The launcher also runs an **idempotent
node seed** after `docker run` that fills only *missing* `hasCompletedOnboarding` / `theme` /
`bypassPermissionsModeAccepted` and per-project trust for `/data/claude` + every
`/data/claude/GIT/*` — so a fresh/re-provisioned volume skips all first-run prompts without
clobbering later choices. Verified: `~/.claude.json` md5 identical across `docker restart`;
a clean recreate from the committed image lands on "Welcome back!" with no picker/trust/login.

> **vs I6:** tmux *sessions* still do not survive a container restart (fresh tmux server) —
> that invariant is unchanged. What now persists is Claude's *config/auth state*, not the
> live sessions.

## Web UI (reclaimed TTY + usable login on mobile)

- **Collapsible Prompts panel.** The snippet chips used to occupy an always-on row (a big
  bite of a phone screen). They now live in a floating overlay behind a `⌨ Prompts ▾` header
  button; the panel floats *over* the terminal, so the TTY keeps full height at all times (no
  resize/reflow on toggle). Measured at 390px: TTY **65-70% → 84%** of the screen.
- **Login-link banner.** When Claude prints an OAuth URL it soft-wraps in the TTY and can't be
  tapped or copied. The client buffers pty output, strips ANSI, **rejoins the wrap-broken
  URL**, and surfaces it as **Open / Copy** plus a paste-code box for the step where Claude
  asks you to paste the auth code back. Host-scoped (claude.ai/oauth, console/auth.
  anthropic.com) so doc links don't false-trigger. Safety net only — persistence above makes
  re-login rare.

## Deploying app changes without an image rebuild

The app is baked into the image at `/app/public`; `server/static.js` reads each file
per-request, so no restart is needed. For a frontend/server edit: `adb push` to the CTX
`/data/docker/claude-term/public/`, `docker cp` into the **running** container's
`/app/public/`, then `docker commit claude-term claude-term:latest` to persist across
recreate/reboot. This skips the slow run+commit build (which exists only because `docker
build` has no host network here). Verify from a LAN host (`Invoke-WebRequest
http://10.0.0.88:7777/app.js`) — the slim image has no `wget` for in-container checks.

## Device gotchas discovered during bringup (all worked around in the scripts)

1. **`docker build` has no network on this kernel.** The legacy builder doesn't apply
   `--network=host` to RUN steps, the docker0 bridge is broken (ARP INCOMPLETE), and
   BuildKit is absent (can't switch). `docker run --network=host` DOES get host net, so
   the image is built inside a live host-net container and `docker commit`-ed
   (`claude-term-build.sh`).
2. **apt can't resolve DNS** even with host net: apt drops to the sandboxed `_apt` user
   which can't do DNS here (`Temporary failure resolving` while root `getent`/npm resolve
   fine). Fix: `apt-get -o APT::Sandbox::User=root`.
3. **Flaky resolver / no IPv6 route.** The LAN router (`10.0.0.1`, first nameserver) flakes
   under apt's burst; deb.debian.org also returns AAAA with no IPv6 route. Fix: pin
   `8.8.8.8`/`1.1.1.1` in resolv.conf + `Acquire::ForceIPv4=true`.
4. **uid 1000 already taken.** `node:20` ships a `node` user at uid 1000. Fix:
   `useradd -m -o -u 1000 claude` (`-o` allows the shared uid; keeps `/home/claude`).
5. **EACCES binding the port.** Android requires the `inet` group (gid 3003) to create
   sockets; the non-root `claude` user lacks it. Fix: `--group-add 3003` on `docker run`
   (stays non-root, satisfies I8).
6. **tmux mangles TAB to `_` in `-F` output** on this build, so a tab-delimited
   `list-sessions -F` line came back as `name_windows_created_attached`. Fix:
   `listSessions` queries `#{session_name}` alone, then per-session `display-message`.

## Verified acceptance (spec §6)
- AC1 fail-closed auth: `/` → 302, `/login` → 200, `/api/sessions` (no cookie) → 401;
  with cookie, login → 200, create → 201.
- AC2 session lifecycle: create/list/delete via the API; tmux session created with the
  correct name.
- R2 (node-pty arm64): `require('@homebridge/node-pty-prebuilt-multiarch')` → `NODE_PTY_OK`.
- R3 (headless Claude auth): a new session reaches an authenticated, ready prompt
  ("Welcome back!", no `/login`, no theme picker / trust dialog) — the
  `CLAUDE_CODE_OAUTH_TOKEN` works and first-run state is pre-seeded (see *State persistence*).
- AC12 runs on kernel 4.9: container serves `:7777`, no ENOSYS.

## Still manual / not yet verified
- AC4/AC5 live WS attach + reattach — browser/phone checks; do them from the phone once.
- AC6/AC7 snippet chips + the new Prompts overlay and login-link banner were verified in a
  headless browser (Playwright, 390px viewport) against the live `:7777` — chips inject, the
  overlay opens with zero term reflow, and a synthetic 3-line ANSI-wrapped OAuth URL
  reassembled to one clean clickable link. A real phone pass is still worth doing once.
- The `shield-c2` dashboard wasn't redeployed, so its "Claude Code" link only appears
  after a `c2-redeploy`. Direct `:7777` works regardless.

## v2 — native Claude Code UI (2026-06-26)

**Status: LIVE and verified on the Shield at `http://10.0.0.88:7777`.** The terminal
is gone; the page now renders Claude Code's headless event stream natively.

### What changed on-box
- The app bridge is `server/agent.js` (spawns `claude -p --output-format stream-json
  --verbose --include-partial-messages [--resume <id>] --dangerously-skip-permissions`,
  **one process per turn**) + `server/hub.js` (one process, N attached sockets) +
  a rewritten `server/sessions.js` over Claude Code's own `.jsonl` transcripts under
  `/home/claude/.claude/projects/`. `node-pty`, `tmux`-attach, and xterm are gone.
- The image already had `node` + `ws` + globally-installed `@anthropic-ai/claude-code
  2.1.185`, and v2 adds **no new npm deps** — so deploy was the fast path, no rebuild.

### Deploy recipe used (no image rebuild)
```sh
# from the PC (PowerShell — Git Bash mangles the absolute /data path):
adb push server public package.json /data/docker/claude-term/      # update CTX
DK="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
adb shell "$DK cp /data/docker/claude-term/server  claude-term:/app/"
adb shell "$DK cp /data/docker/claude-term/public  claude-term:/app/"
adb shell "$DK cp /data/docker/claude-term/package.json claude-term:/app/package.json"
adb shell "$DK exec claude-term sh -c 'rm -f /app/server/pty-bridge.js /app/server/bracketed-paste.js'"
adb shell "$DK exec -u 0 claude-term sh -c 'chown -R 1000:1000 /app/server /app/public /app/package.json'"
adb shell "$DK restart claude-term"           # restart: new SERVER code needs a fresh node
adb shell "$DK commit claude-term claude-term:latest"   # persist across recreate/reboot
```
Gotcha (Windows): drive `adb` from **PowerShell**, not Git Bash — MSYS rewrites a
leading-`/` remote path to the Git install prefix and the push/exec silently target
the wrong place.

### Verified live (screenshots captured during bringup — `/*.png` is gitignored, so they stay local)
- **AC4 native render, no garble** — at 390px the transcript shows streamed markdown,
  ⏺ Bash cards, and results with zero overlap/overflow (vs the v1 `ct-02` garble).
- **AC5/AC6 streaming + tool cards**, **AC7 bypass-on** (a Bash tool ran with no
  approval prompt), footer live (`claude-sonnet-4-6 · ctx % · $cost`).
- **AC8 multi-attach** — two browser tabs on one session; a message sent from tab 0
  streamed into tab 1.
- **AC9 persistence** — the transcript replayed from `.jsonl` after the deploy
  `docker restart` (the same path survives a Shield reboot).
- Scriptable §6: no docker socket, `/data/claude` writable, `/system` not, 6 snippet
  chips, no `ENOSYS`.
- Local: `node --test` (server/agent.test.js) 10/10 green for the event normalizer +
  turn-runner.
