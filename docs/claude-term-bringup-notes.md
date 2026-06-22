# claude-term — on-Shield bringup notes

**Status: LIVE and verified on the Shield at `http://10.0.0.88:7777`** (2026-06-22).
Deployed over adb (`10.0.0.88:5555`). Build context lives at `/data/docker/claude-term`,
launcher + secret env at `/data/docker/claude-term.sh` / `claude-term.env`.

## How it runs
- `docker-bringup/claude-term.sh` is the launcher (host-net, `--restart=always`,
  `--group-add 3003`, rw `/data/claude` + `claude-home` volume, **no** docker socket).
  Idempotent: re-running replaces the container.
- Image is built by `docker-bringup/claude-term-build.sh` (run+commit — NOT `docker build`).
- To reach it: browser → `http://10.0.0.88:7777` → passphrase (in `claude-term.env`) →
  create/attach a tmux-backed Claude Code session. Or the `shield-c2` dashboard (`:8888`)
  "Claude Code" link. `claude` auto-starts in each session, authenticated via the OAuth token.

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
- R3 (headless Claude auth): the session pane reached Claude Code's interactive prompt
  (first-run theme picker) with no `/login` — the `CLAUDE_CODE_OAUTH_TOKEN` works.
- AC12 runs on kernel 4.9: container serves `:7777`, no ENOSYS.

## Still manual / not yet verified
- AC4/AC5 live WS attach + reattach, AC6/AC7 snippet chips — these are browser/phone checks;
  do them from the phone once.
- The `shield-c2` dashboard wasn't redeployed, so its new "Claude Code" link only appears
  after a `c2-redeploy`. Direct `:7777` works regardless.
