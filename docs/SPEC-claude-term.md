# SPEC — `claude-term`

> **STATUS: NOT YET BUILT — forward design only.** `claude-term` does not run on the Shield. No `claude-term` container exists and port `:7777` is unoccupied. This document is a design spec for a service that is intended to be built; nothing here describes current running state.

A LAN-only, browser-based way to launch and reattach **Claude Code** sessions running **on the Shield**, driven from a phone. A self-contained arm64 container serves a single terminal page (xterm.js) bridged to `tmux`-managed Claude Code sessions, with tap-to-inject "stance" snippet chips. Sibling of `shield-c2` (see [SPEC-shield-c2.md](SPEC-shield-c2.md)); reuses its host/Docker/launcher conventions.

## 0. Authoritative amendments (override anything below)

- **A1 — Access = LAN-only, browser-based.** No VPN/tunnel. Reachable from any browser on the home LAN. The phone is just a browser; nothing installed phone-side.
- **A2 — Launch surface = a button in `shield-c2` (`:8888`) that opens the `claude-term` app at `:7777`.** The dashboard-button → on-device web terminal architecture runs Claude Code on this hardware with these files; cloud-hosted Claude surfaces (mobile app, claude.ai, web) run in Anthropic's cloud and cannot reach the Shield's filesystem, LAN, or processes.
- **A3 — Session model = multiple named, persistent `tmux` sessions.** The page lists sessions, lets you create a new one (name + working dir under `/data/claude`), and reattach an existing one. Reattach survives phone sleep / app switch / page reload.
- **A4 — Snippet chips = bracketed-paste prepend, editable config, optional per-chip submit.** Tapping a chip injects a (possibly multi-line) instruction block onto the input line WITHOUT submitting; you then type your prompt and hit Enter. A per-chip `submit:true` flag makes a chip fire immediately. Snippet text lives in an editable `snippets.json` (no rebuild to change).
- **A5 — Auth = shared-secret gate.** One passphrase (env var), checked server-side, remembered via a cookie. Fail-closed: if no secret is configured the app refuses to serve. Plain HTTP on the LAN (secret crosses the LAN in cleartext — accepted for a trusted home LAN; HTTPS named as the upgrade path).

## 1. Device reality (the spec exists to honor these)

- Host: NVIDIA Shield TV "foster" (Pro, 3 GB RAM), LineageOS 22.x userdebug, Android 15, **kernel 4.9.141 aarch64**, Tegra X1. LAN IP 10.0.0.88.
- Docker: static 24.0.9, cgroup v1, storage overlay2, daemon socket `unix:///data/docker/docker.sock`, binaries `/data/docker/bin`, `--restart=always`, daemon auto-started by Android init on `sys.boot_completed=1`. `/data` is ext4, ~444 GB free, **not noexec**.
- Networking: bridge/veth is **broken** on this kernel (ARP INCOMPLETE across docker0). **MANDATORY `--network host`.** No `-p`, no bridge nets. Container binds a host port directly on 10.0.0.88. Occupied host ports: `shield-c2` 8888, Portainer 9000/9443/8000, Uptime-Kuma 3001. Port 7777 is currently free.
- On-device builds: classic builder only — `DOCKER_BUILDKIT=0` and `--network=host` on `docker build` (else npm install gets no DNS → `EAI_AGAIN registry.npmjs.org`). arm64 base images must be **digest-pinned** to the real arm64 manifest (resolve via `docker buildx imagetools inspect` on the PC).
- SELinux permissive, root available.

## 2. Resolved design decisions (with justification)

- **D1 — Runtime = plain Node (`http` + `ws` + node-pty) serving a static xterm.js page.** NOT SvelteKit. The core is a WebSocket carrying PTY bytes; adapter-node has no first-class WS story. A single small Node process serving one static page + a WS upgrade is simpler and more robust here. (`shield-c2` stays SvelteKit; the two apps share nothing but conventions.)
- **D2 — Terminal = `@xterm/xterm` (client) + `@homebridge/node-pty-prebuilt-multiarch` (server).** xterm.js is a library embedded in our own page, so a chip tap writes to the PTY directly (I5) — an iframed third-party terminal (ttyd/gotty/wetty serves its own page) would be blocked from snippet injection by the browser's cross-origin rule. The `@homebridge/` node-pty fork is used because upstream `node-pty` 1.x ships a mislabeled (x86_64) "arm64" binary; the fork has a genuine `linux-arm64` glibc prebuilt for Node 18+. *(R2: verify on-device.)*
- **D3 — Session manager = `tmux`.** tmux owns persistence + multiplexing; node-pty stays a thin bridge that runs `tmux new`/`tmux attach`. A session is created shell-rooted then auto-starts Claude Code: `tmux new -d -s <name> -c <cwd>` (default login shell), then `tmux send-keys -t <name> 'claude' Enter`. Exiting Claude Code drops to the shell and the session survives for reattach. The page attaches via `tmux attach -t <name>`. Persists across client disconnects while the container is up (I6).
- **D4 — Base image = `node:20-bookworm-slim` (arm64, digest-pinned), NOT alpine.** Same rationale as `shield-c2` D3/I9: glibc degrades instead of `ENOSYS` on kernel 4.9. Installs `@anthropic-ai/claude-code`, `tmux`, `git`, and the app's deps. `ripgrep` present so Claude Code does not need `USE_BUILTIN_RIPGREP`.
- **D5 — Host port = 7777** (`CLAUDE_TERM_PORT`, env-overridable). Free vs 8888/9000/9443/8000/3001. Launcher asserts free before binding.
- **D6 — Claude Code auth = `CLAUDE_CODE_OAUTH_TOKEN`** generated once on the PC via `claude setup-token` (subscription-backed, ~1-year validity), injected as env + persisted by mounting `~/.claude` as a named volume. The interactive `ANTHROPIC_API_KEY` path is avoided (documented regressions where it still demands `/login`). *(R3: verify the container reaches an authenticated prompt headlessly.)*
- **D7 — Snippet injection = bracketed paste.** A chip's body is wrapped `ESC[200~ … ESC[201~` and sent over the input WS → `pty.write(...)`. Bracketed paste makes Claude Code treat a multi-line block as pasted text (inserted, not submitted at the first newline). `submit:true` chips append a trailing `\r` after the wrapper to fire immediately. *(R1: verify Claude Code honors bracketed paste.)*
- **D8 — Workspace root = `/data/claude` (rw), the ONLY writable host mount** besides the `~/.claude` credential volume. New-session working dirs must resolve under it (I3). The docker socket is **NOT** mounted (I9) — this app needs no Docker control.

## 3. Interface / contract

All paths under `http://10.0.0.88:7777`. Every route AND the WS upgrade require a valid session cookie (A5/I1).

**Auth**
- `GET /login` → passphrase form. `POST /login` (form/JSON `{secret}`) → on match, set `httpOnly` cookie holding a server-issued random session token (held in an in-memory set); redirect to `/`. On mismatch → 401, no cookie.
- `POST /logout` → invalidate the token, clear cookie.
- Any request (incl. `GET /ws`) without a valid cookie → 401 (API) or 302→`/login` (page). The WS upgrade is rejected (`401`, socket closed) without a valid cookie.

**Sessions**
- `GET /api/sessions` → `[{ name, windows, created, attached, cwd }]` from `tmux list-sessions` (+ `display-message` for cwd). `[]` when none.
- `POST /api/sessions` `{ name, cwd }` → 201 | error JSON. Validates `name` (`^[A-Za-z0-9_-]{1,32}$`) and that `realpath(cwd)` is under `/data/claude` (I3); creates the session shell-rooted then auto-starts Claude Code (D3).
- `DELETE /api/sessions/:name` → 204 | error JSON. `tmux kill-session -t <name>`.
- `GET /api/dirs` → `[string]` immediate subdirectories of `/data/claude` (to populate the new-session dir picker). Free-text path also allowed, subject to the I3 confinement check.

**Snippets**
- `GET /api/snippets` → the parsed snippets config: `[{ label, body, submit? }]`. Read from `CLAUDE_TERM_SNIPPETS` (default `/data/claude/snippets.json`); if absent, a baked-in default set is returned. Re-read on each request (edit without rebuild).

**Terminal WS**
- `GET /ws?session=<name>` (Upgrade: websocket) → bridges xterm.js ↔ node-pty running `tmux attach -t <name>` (rejects if the session does not exist). Messages (JSON or framed):
  - client→server: `{type:'data', data}` (keystrokes; snippet chips send the bracketed-paste-wrapped body through this same channel — no special server path), `{type:'resize', cols, rows}`.
  - server→client: `{type:'data', data}` (PTY output).
- On client disconnect the PTY detaches from tmux (session keeps running, I6); on reconnect a new `tmux attach` re-renders current state.

**Error contract:** every API endpoint returns JSON `{error, detail?}` with a 4xx/5xx on failure.

**Container / run contract**
- Image FROM `node:20-bookworm-slim` (digest-pinned), arm64. Installs `@anthropic-ai/claude-code`, `tmux`, `git`, `ripgrep`, app deps. ENTRYPOINT starts the Node server.
- A non-root user (e.g. `claude`, uid 1000) owns the app and runs Claude Code (I8); `/data/claude` + `~/.claude` writable by that uid.
- Env: `CLAUDE_TERM_PORT` (default 7777), `CLAUDE_TERM_SECRET` (**required**; empty → refuse to start, I1), `CLAUDE_TERM_SNIPPETS` (default `/data/claude/snippets.json`), `CLAUDE_CODE_OAUTH_TOKEN` (Claude auth, D6), `CLAUDE_TERM_WORKSPACE` (default `/data/claude`).
- Bind mounts (set by launcher): `rw /data/claude → /data/claude`, `rw <named vol> → /home/claude/.claude`. **No** `/proc`/`/sys`/`/system`/full-`/data`, **no** docker socket.
- Run flags: `--network host`, `--restart=always`, `--name claude-term`.

**Launcher contract — `docker-bringup/claude-term.sh`** mirrors `c2.sh`: `BB`/`DOCKER` vars, `docker version` preflight, port-free assertion (7777), build-or-load image (`DOCKER_BUILDKIT=0`, `--network=host`), `docker rm -f` prior container, then `docker run -d` with the flags/mounts/env above, finish with a `docker ps` table. Idempotent. Reads `CLAUDE_TERM_SECRET` and `CLAUDE_CODE_OAUTH_TOKEN` from the environment / a sourced untracked file — never hardcoded (I11).

**`shield-c2` integration** — a single nav link/card pointing to `http://10.0.0.88:7777` ("Claude Code"). No deeper coupling; the dashboard is just a launcher.

## 4. Invariants

- **I1 AUTH FAIL-CLOSED:** every route incl. the WS upgrade requires a valid session cookie; missing/invalid → 401 / redirect. If `CLAUDE_TERM_SECRET` is empty the server refuses to start (never silently serves an open shell).
- **I2 WORKSPACE-CONFINED MOUNTS:** only `/data/claude` (rw) + the `~/.claude` volume are writable host resources. No `/system`, no full `/data`, no `/proc`/`/sys`, no docker socket.
- **I3 CWD CONFINEMENT:** a new session's `cwd` must `realpath` to a path under `/data/claude`; traversal/symlink-escape is rejected before any `tmux new`.
- **I4 HOST-NET-ONLY:** `--network host`, binds `CLAUDE_TERM_PORT` on the LAN IP. No `-p`, no bridge, no docker0 dependency.
- **I5 INJECTION VIA OWN-PAGE TERMINAL:** the terminal is an embedded xterm.js in our own origin (not an iframed third-party terminal), so snippet chips write to the PTY directly. No cross-origin injection, no undocumented-protocol reverse engineering.
- **I6 PERSISTENCE SCOPE:** tmux sessions persist across client disconnect / reload / phone sleep while the container runs. They do **NOT** survive a container restart or Shield reboot (fresh tmux server) — documented and accepted.
- **I7 CONSERVATIVE SYSCALL BASE:** runtime runs on kernel 4.9.141 without `ENOSYS` at startup (glibc `node:20-bookworm-slim`; documented `node:18-bullseye-slim` fallback).
- **I8 NON-ROOT CLAUDE:** Claude Code + the server run as a non-root in-container user; the OAuth token and `~/.claude` are readable only by that user.
- **I9 NO DOCKER SOCKET:** `claude-term` never mounts or contacts `/data/docker/docker.sock`. (This is the bright line vs. `shield-c2`.)
- **I10 CREDENTIAL PERSISTENCE, NO BAKING:** `~/.claude` is a named volume; the OAuth token + passphrase arrive via env at run time; neither is baked into the image or committed.
- **I11 NO SECRETS IN HISTORY:** `snippets.json` (no secrets) may be committed; `CLAUDE_TERM_SECRET` and `CLAUDE_CODE_OAUTH_TOKEN` never are. `.gitignore` excludes `node_modules`/build and any local secret file.

## 5. Acceptance criteria

- **AC1 FAIL-CLOSED AUTH:** with `CLAUDE_TERM_SECRET` unset the container exits non-zero / refuses to serve. With it set, `GET /` and `GET /ws` without a cookie return 401/302; after `POST /login` with the right secret they succeed.
- **AC2 SESSION LIFECYCLE:** `POST /api/sessions {name:"t1",cwd:"/data/claude"}` → 201 and `tmux has-session -t t1` succeeds; `GET /api/sessions` lists `t1` with its cwd; `DELETE /api/sessions/t1` → 204 and the session is gone.
- **AC3 CWD CONFINEMENT (I3):** `POST /api/sessions {name:"x",cwd:"/data/../system"}` (and `cwd:"/etc"`) → 4xx, no session created.
- **AC4 ATTACH + LIVE I/O:** a WS to `/ws?session=t1` (with cookie) renders the tmux/Claude Code TUI; typed bytes reach the PTY and output streams back; a resize message reflows.
- **AC5 REATTACH PERSISTENCE (I6):** start a long-running command in `t1`, drop the WS, reconnect → the session shows continued state (not a fresh shell).
- **AC6 SNIPPET PREPEND (D7):** tapping a multi-line, non-`submit` chip places the full block on the input line WITHOUT submitting; the user can append text and submit once. (Bracketed paste verified — R1.)
- **AC7 SNIPPET SUBMIT FLAG:** a `submit:true` chip injects + fires in one tap.
- **AC8 SNIPPETS EDITABLE (no rebuild):** editing `/data/claude/snippets.json` and reloading the page changes the chips with no image rebuild; the 6 seed chips are present by default.
- **AC9 NO DOCKER SOCKET (I9):** the container has no socket mount; `ls /var/run/docker.sock` inside fails; code contains no docker-socket path.
- **AC10 WORKSPACE-ONLY WRITES (I2):** writing under `/data/claude` succeeds; the container cannot write `/system` or read `/data/docker/docker.sock` (not mounted).
- **AC11 CLAUDE AUTH HEADLESS (D6/R3):** with `CLAUDE_CODE_OAUTH_TOKEN` set and `~/.claude` mounted, a new session's `claude` reaches an authenticated, ready prompt with no `/login` step.
- **AC12 RUNS ON 4.9 (I7):** the built arm64 image starts on the Shield with no `ENOSYS` at boot and serves `:7777`.
- **AC13 HOST-NET LAUNCH RECIPE:** `docker-bringup/claude-term.sh` launches with `--network host`, `--restart=always`, rw `/data/claude` + `~/.claude` vol, on 7777, idempotent; reachable from another LAN host at `10.0.0.88:7777`.
- **AC14 NO SECRETS IN HISTORY (I11):** no `CLAUDE_TERM_SECRET`/OAuth token in the image or git; `.gitignore` covers node_modules/build + the local secret file.
- **AC15 DASHBOARD LINK:** `shield-c2` shows a "Claude Code" link to `:7777`.

## 6. Acceptance tests (executable; preserve the assertions if translated)

```sh
BASE=http://10.0.0.88:7777
COOKIE=$(mktemp)

# T1 fail-closed auth (AC1)
curl -s -o /dev/null -w '%{http_code}' $BASE/ | grep -Eq '^(302|401)$'                 # no cookie → blocked
curl -s -c $COOKIE -X POST $BASE/login -d "secret=$CLAUDE_TERM_SECRET" -o /dev/null
curl -s -b $COOKIE -o /dev/null -w '%{http_code}' $BASE/ | grep -q '^200$'              # cookie → ok
# (separate run) empty secret refuses to start:
#   docker run ... -e CLAUDE_TERM_SECRET= ...  → container exits non-zero

# T2 session lifecycle (AC2)
curl -s -b $COOKIE -X POST $BASE/api/sessions -H 'content-type: application/json' \
  -d '{"name":"t1","cwd":"/data/claude"}' -o /dev/null -w '%{http_code}' | grep -q '^201$'
docker exec claude-term tmux has-session -t t1
curl -s -b $COOKIE $BASE/api/sessions | jq -e 'any(.[]; .name=="t1" and (.cwd|startswith("/data/claude")))' >/dev/null
curl -s -b $COOKIE -X DELETE $BASE/api/sessions/t1 -o /dev/null -w '%{http_code}' | grep -q '^204$'

# T3 cwd confinement (AC3/I3)
for bad in '/etc' '/data/../system' '/system'; do
  curl -s -b $COOKIE -X POST $BASE/api/sessions -H 'content-type: application/json' \
    -d "{\"name\":\"x\",\"cwd\":\"$bad\"}" -o /dev/null -w '%{http_code}' | grep -Eq '^4[0-9][0-9]$'
done

# T4 snippets present, editable, default-seeded (AC8)
curl -s -b $COOKIE $BASE/api/snippets | jq -e 'length>=6 and all(.[]; has("label") and has("body"))' >/dev/null

# T5 no docker socket reachable from this container (AC9/I9)
! docker exec claude-term sh -c 'test -S /var/run/docker.sock'
! grep -RInE 'docker\.sock|/var/run/docker' claude-term/  # no socket path in code

# T6 workspace-only writes (AC10/I2)
docker exec claude-term sh -c 'touch /data/claude/_w && rm /data/claude/_w'            # ok
docker exec claude-term sh -c 'touch /system/_w 2>&1' | grep -qiE 'read-only|denied|not found'

# T7 runs on 4.9, serves :7777 (AC12/I7)
curl -s -b $COOKIE -o /dev/null -w '%{http_code}' $BASE/ | grep -q '^200$'
docker logs claude-term 2>&1 | grep -qvi 'ENOSYS'

# T8 launcher host-net + restart (AC13)
docker inspect -f '{{.HostConfig.NetworkMode}}' claude-term | grep -q '^host$'
docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' claude-term | grep -q 'always'

# T9 no secrets in history (AC14/I11)
! docker exec claude-term printenv | grep -q 'CLAUDE_TERM_SECRET=$'                     # set, not empty
! git log -p | grep -iE 'CLAUDE_CODE_OAUTH_TOKEN=sk|CLAUDE_TERM_SECRET='

# --- MANUAL (browser, on the phone) ---
# T10 attach + live I/O + resize (AC4)
# T11 reattach persistence: run `sleep 99`, kill the tab, reopen → still running (AC5/I6)
# T12 snippet prepend: tap a multi-line chip on an empty input → block sits unsent; type + Enter once (AC6/R1)
# T13 submit-flag chip fires in one tap (AC7)
# T14 Claude Code reaches an authed prompt with no /login (AC11/R3)
```

A pass is every scripted command exiting 0 plus the manual checks confirmed, with evidence retained.

## 7. Risks / to verify before/at implementation (research leads, not ground truth)

- **R1 — Bracketed paste honored by Claude Code's TUI.** Load-bearing for multi-line snippets. Verify a wrapped multi-line block lands on the input line unsent. Fallback if not: send the block as plain input and accept single-line snippets, or use a clipboard-paste affordance.
- **R2 — `@homebridge/node-pty-prebuilt-multiarch` arm64 prebuilt** loads and spawns a PTY on this glibc/kernel-4.9 box. Verify by `require()` + a trivial `pty.spawn` on-device. Fallback: build node-pty from source in the image.
- **R3 — `CLAUDE_CODE_OAUTH_TOKEN` headless auth.** Verify a containerized `claude` is authenticated from the env token + mounted `~/.claude` with no browser/`/login`. Fallback: bootstrap `~/.claude` once interactively, then rely on the persisted volume.
- **R4 — PTY device availability** inside the container (`/dev/pts`, `openpty`). Usually fine with default Docker; verify.
- **R5 — Claude Code version drift** can change input handling. Consider pinning a known-good `@anthropic-ai/claude-code` version in the image.

## 8. Setup prerequisites / open items

- **Repo transfer to the Shield.** The `NVIDIAShield` tree must be placed at e.g. `/data/claude/NVIDIAShield` for self-admin from the Shield. Mechanism options: push to a private remote then clone; push to a bare repo on the Shield over the LAN; or `adb push` a `git bundle`.
- **Generate `CLAUDE_CODE_OAUTH_TOKEN`** on the PC via `claude setup-token`; store it for the launcher to read from the environment (never committed).
- **Choose `CLAUDE_TERM_SECRET`** (the gate passphrase); supply it the same way.

## 9. Deliverables

- `claude-term/` — the Node app: static xterm.js terminal page + snippet-chip UI + session list/new/attach UI; server with the auth gate, `tmux` session API, `/api/snippets`, and the node-pty WS bridge.
- `claude-term/Dockerfile` — arm64, `node:20-bookworm-slim` (digest-pinned), installs `@anthropic-ai/claude-code` + `tmux` + `git` + `ripgrep` + app deps; non-root `claude` user.
- `claude-term/snippets.json` — the 6 seed chips (Council, Brainstorm-first, Debug, Plan only, Verify, Local offload) as the default/example config.
- `docker-bringup/claude-term.sh` — launcher mirroring `c2.sh` (host net, `--restart=always`, rw `/data/claude` + `~/.claude` vol, port-free assertion, reads secret + OAuth token from env, idempotent).
- `shield-c2` — a one-line "Claude Code" nav link to `:7777`.
- `docs/THREAT-MODEL.md` — append a `claude-term` section: a full root-capable shell behind a single shared-secret gate on plain-HTTP LAN; blast radius = `/data/claude` + the Claude token + LAN reach; upgrade path = HTTPS + per-user auth.

## 10. Git preflight

Commit this spec and (at build) the new app under `master`. `.gitignore` already excludes `node_modules`/build/blobs; add the local secret file (e.g. `docker-bringup/claude-term.env`) to it. No OAuth token or passphrase enters history (I11).
