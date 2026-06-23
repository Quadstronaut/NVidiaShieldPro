# claude-term — on-Shield bringup notes

**Status: LIVE and verified on the Shield at `http://10.0.0.88:7777`** (2026-06-22;
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
