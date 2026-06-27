# SPEC — `claude-term` v2 (native Claude Code UI)

A LAN-only, phone-first **web app that reproduces the Claude Code interface** — transcript, tool-call cards, diffs, streaming text, the `>` composer, the status footer — driven by real **Claude Code running headless** on the Shield. The garbled xterm.js → tmux → Claude-Code-TUI path is removed. Same brain, same look, finally legible on a phone.

> **Provenance:** Brainstorming session (superpowers:brainstorming), **user-approved 2026-06-26**, after the user reproduced the v1 failure live ("I cannot see what is happening") and a parallel Playwright repro confirmed the v1 TUI renders as overlapping panels, horizontal overflow, and a 6×-stacked tmux status bar at phone width. Amendments B1–B6 below were locked interactively. This spec **supersedes the interaction-model decisions of [`SPEC-claude-term.md`](SPEC-claude-term.md)** (D2 xterm.js + node-pty, D3 tmux, D7 bracketed-paste) and **amends D1** — it keeps v1's plain-Node `http`+`ws` runtime but drops `node-pty` and the static xterm page. It **inherits the rest of v1's infrastructure contract** (container, Dockerfile conventions, launcher, OAuth, persistence volume, auth gate, `/data/claude`, host-net, non-root, no-docker-socket). Where v1 and v2 conflict, v2 wins.

## 0. User-approved amendments (authoritative — override anything below)

- **B1 — Interaction model = native phone-first web UI, NOT a terminal.** The UI renders a *structured event stream* from Claude Code (assistant text, tool calls, results, diffs, status) with Claude Code's own visual grammar, as legible HTML — never an emulated character grid. The xterm.js page is deleted. The whole point of the pivot: the user can **see what is happening**.
- **B2 — Driver = real Claude Code, headless.** Fidelity is non-negotiable: what the UI shows is what Claude Code is actually doing, because the UI is a renderer over Claude Code's headless event stream — not a reimplementation of the agent. Same model, same tools, same skills, same `/data/claude` workspace as the CLI.
- **B3 — Bypass permissions ON by default, every session.** Sessions launch with `--dangerously-skip-permissions` so a phone-driven session never stalls on an approve dialog (LAN-trusted device; user-confirmed 2026-06-26). Native Approve/Deny is an explicit **non-goal for v1** (fast-follow).
- **B4 — Remote control ON by default, every session.** Every session is drivable from the app the moment it exists — **no per-session "enable remote" step, no gating.** The app is the single control surface for all Claude Code sessions on the Shield: list, create, resume, attach, interrupt, close any of them. **Multiple devices may attach to the same session concurrently** (shared live view + shared control). *(Controlling sessions started entirely outside the app — e.g. a bare `claude` over SSH — is a v1.x goal pending a mechanism; see R6. v1 guarantees this for all app-managed sessions.)*
- **B5 — Reuse the v1 infrastructure wholesale.** Same arm64 container family, same launcher pattern (`docker-bringup/claude-term.sh`), same OAuth token, same persistence volume, same auth gate, same `/data/claude` workspace root, same host port **7777**, same `shield-c2` launch link, and **keep the snippet "Prompts" chips** (Council / Brainstorm / Debug / Plan only / Verify / Local offload). Only the frontend + the agent bridge are replaced.
- **B6 — This is the go-forward method.** The user's stated workflow on the Shield from here on is this app. Treat it as the primary, durable surface — not a toy. Sessions must survive container restart / Shield reboot (improving on v1's I6).

## 1. Device reality (the spec exists to honor these)

Unchanged from v1 — restated so this spec stands alone.

- Host: NVIDIA Shield TV "foster" (Pro, 3 GB RAM), LineageOS 22.x userdebug, Android 15, **kernel 4.9.141 aarch64**, Tegra X1. LAN IP 10.0.0.88.
- Docker: static 24.0.9, cgroup v1, overlay2, daemon socket `unix:///data/docker/docker.sock`, `--restart=always`, daemon auto-started by Android init on `sys.boot_completed=1`. `/data` is ext4, ~445 GB free, not noexec.
- Networking: bridge/veth **broken** on this kernel (ARP INCOMPLETE across docker0). **MANDATORY `--network host`.** No `-p`, no bridge nets. Occupied host ports: `shield-c2` 8888, Uptime-Kuma 3001, `claude-term` 7777.
- On-device builds: classic builder only — `DOCKER_BUILDKIT=0` and `--network=host`; apt under `APT::Sandbox::User=root`; pin `8.8.8.8`/`1.1.1.1` + `Acquire::ForceIPv4=true`; arm64 base images digest-pinned. (All captured in [`claude-term-bringup-notes.md`](claude-term-bringup-notes.md).)
- SELinux permissive, root available. `@anthropic-ai/claude-code` already proven to run on this box (v1 is live).

## 2. Resolved design decisions (locked, with justification)

- **D1 — Agent bridge = Claude Code headless, JSON event stream in and out.** The server spawns `claude` in print/headless mode emitting a structured JSON event stream (`--output-format stream-json`) and accepting messages on stdin (`--input-format stream-json`), one long-lived process per live session, with token-level streaming (`--include-partial-messages`) so text appears as it generates. This **replaces** v1's `node-pty` + `tmux attach` bridge (v1 D2/D3). Headless is strictly *less* demanding than the TUI (no terminal rendering), so kernel-4.9 viability is already established by v1. *(R1: confirm the exact flags + event shape on the pinned Claude Code version on-device.)*
- **D2 — Session persistence = Claude Code's own session store.** Headless sessions are identified by a session id and resumed with `--resume <id>` (or `--continue`); their transcripts live in Claude Code's session files under `$HOME` (`~/.claude/…`), which **already sits in the persistence volume** mounted at the whole `/home/claude` (v1 fix `609c19c`). So sessions survive container restart **and Shield reboot** — a strict improvement over v1's I6 (tmux sessions died on restart). The app lists sessions from this store; "resume" re-attaches a fresh headless process to an existing session id. *(R2: confirm resume semantics + where the session id is surfaced in the event stream.)*
- **D3 — Transport = one WebSocket per attached client, carrying JSON events both directions.** Reuses v1's `ws` upgrade + auth gate. **server→client:** `assistant_delta` (streaming text), `assistant_message`, `tool_use`, `tool_result`, `result`, `status` (model / context-left / cost / running|idle), `session_event` (created/renamed/closed), `error`. **client→server:** `user_message`, `interrupt`, `slash_command`, `attach {session_id}`, `detach`. A small server-side **session hub** owns each headless process and fans its event stream out to *every* attached WebSocket (B4 multi-attach) — exactly one `claude` process per session regardless of viewer count.
- **D4 — Frontend = native HTML/CSS/JS reproducing the Claude Code interface.** No xterm, no canvas terminal. Components, each a legible web rendering of its TUI counterpart:
  - **Transcript** — assistant text as rendered **markdown** (code blocks monospaced + syntax-tinted); user turns echoed; **⏺ tool-call cards** = tool name + one-line summary, **tap to expand** full input/output; file edits shown as **unified diffs** with red/green gutters.
  - **Live** — `assistant_delta` streams token-by-token; a **"✻ working…"** indicator with an **Interrupt** button while `status=running`.
  - **Composer** — bottom **`>` input** with the device's native keyboard, send button, slash-command autocomplete, and the **snippet Prompts chips** carried over from v1 (collapsible overlay so the transcript keeps full height).
  - **Footer** — model · context-left % · session cost, mirroring the TUI status line.
  - **Look** — Claude Code's palette (amber accent, muted grays, dark ground), monospace for code, generous line-height. Phone-first; usable down to 360px.
- **D5 — Permissions = `--dangerously-skip-permissions`, default on (per B3).** Every tool call is still **rendered visibly** in the transcript, so "skipped approval" never means "invisible action." Native per-action Approve/Deny (via a headless permission-prompt callback) is explicitly deferred. `CLAUDE_TERM_SKIP_PERMISSIONS=0` may disable per env, but default is on.
- **D6 — Remote control = default-on, app is the control surface (per B4).** No per-session opt-in: every app-created session is, from creation, listed and drivable by any authorized client. The session hub permits **N concurrent attachments** to one session — all see the same live stream and can all send input (last-writer-wins on the input queue; Claude Code already serializes a single agent loop). Interrupt and close are available to any attached client.
- **D7 — Auth / infra inherited from v1.** Auth gate unchanged (shared-secret cookie, or `CLAUDE_TERM_NO_AUTH=1` open-LAN mode as currently deployed) and **applies to the WebSocket upgrade too**. OAuth via `CLAUDE_CODE_OAUTH_TOKEN`. Host-net, non-root `claude` uid 1000 + `--group-add 3003`, **no docker socket**, `/data/claude` the only writable workspace mount, persistence volume at `/home/claude`. Port 7777.

## 3. Interface / contract

All paths under `http://10.0.0.88:7777`. Every route AND the WebSocket upgrade pass through the inherited auth gate (cookie, or open mode).

**Pages**
- `GET /` → the single-page app (session list + active conversation + composer).

**Sessions (REST)**
- `GET /api/sessions` → `[{ id, title, cwd, model, created, lastActive, running, attachedClients }]`, sourced from Claude Code's session store + the live hub. `[]` when none.
- `POST /api/sessions` `{ title?, cwd }` → 201 `{ id, … }`. Validates `realpath(cwd)` is under `/data/claude` (inherited I3). Spawns a headless session **bypass-on, remote-on** (B3/B4).
- `POST /api/sessions/:id/resume` → 200; re-attaches a headless process to an existing session id (D2).
- `DELETE /api/sessions/:id` → 204; interrupts + ends the headless process. Transcript (Claude Code session file) is retained unless `?purge=1`.
- `GET /api/dirs` → `[string]` immediate subdirectories of `/data/claude` for the new-session picker (free-text also allowed, confinement-checked).

**Snippets**
- `GET /api/snippets` → `[{ label, body, submit? }]`, read per-request from `CLAUDE_TERM_SNIPPETS` (default `/data/claude/snippets.json`), baked-in defaults if absent. (Inherited from v1 unchanged.)

**Conversation WebSocket**
- `GET /ws?session=<id>` (Upgrade: websocket) → attaches this client to session `<id>`'s hub.
  - **client→server** (JSON): `{type:'user_message', text}`, `{type:'interrupt'}`, `{type:'slash_command', command}`, `{type:'attach', session}`, `{type:'detach'}`.
  - **server→client** (JSON): `{type:'assistant_delta', text}`, `{type:'assistant_message', blocks}`, `{type:'tool_use', id, name, input, summary}`, `{type:'tool_result', id, content, isError}`, `{type:'result', stopReason, usage}`, `{type:'status', model, contextLeftPct, costUsd, running}`, `{type:'session_event', event, session}`, `{type:'error', message}`.
- On attach, the hub **replays the current session transcript** (from the session file) so a freshly-attached phone shows full history, then streams live. Multiple sockets per session are first-class (B4/D6).

**Error contract:** every REST endpoint returns JSON `{error, detail?}` with 4xx/5xx on failure; the WS emits `{type:'error', message}` and stays open where recoverable.

**Container / run contract** (inherited from v1, deltas noted)
- Image FROM `node:20-bookworm-slim` (digest-pinned, arm64); installs `@anthropic-ai/claude-code` (**version-pinned**, R5), `git`, `ripgrep`, app deps. **`tmux` no longer required** (may stay for the shell escape hatch, but the agent path doesn't use it). ENTRYPOINT starts the Node server.
- Non-root `claude` uid 1000, `--group-add 3003` (Android `inet`), `/data/claude` + `/home/claude` writable by that uid.
- Env: `CLAUDE_TERM_PORT` (7777), `CLAUDE_TERM_SECRET` / `CLAUDE_TERM_NO_AUTH`, `CLAUDE_TERM_SNIPPETS`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_TERM_WORKSPACE` (`/data/claude`), `CLAUDE_TERM_SKIP_PERMISSIONS` (default on).
- Mounts: `rw /data/claude → /data/claude`, `rw <named vol> → /home/claude`. **No** docker socket, **no** `/proc`/`/sys`/`/system`/full-`/data`.
- Run flags: `--network host`, `--restart=always`, `--name claude-term`.

**Launcher contract — `docker-bringup/claude-term.sh`** unchanged in shape (port-free assert on 7777, `DOCKER_BUILDKIT=0`, `--network=host`, secret + OAuth from a sourced untracked env file, idempotent `docker rm -f`).

**`shield-c2` integration** — the existing "Claude Code" link to `:7777` is unchanged; it now opens the native app.

## 4. Invariants

Infra invariants **inherited from v1** (`SPEC-claude-term.md` I1–I11): auth fail-closed incl. WS, workspace-confined mounts, cwd confinement, host-net-only, persistence-of-Claude-state, conservative glibc base, non-root Claude, **no docker socket**, credential persistence with no baking, no secrets in history. Plus the v2-specific:

- **NI1 — NATIVE, NOT TERMINAL.** No xterm/ANSI emulation in the client. The UI is a renderer over the structured event stream; a raw escape sequence must never reach the user as visible glyphs.
- **NI2 — FIDELITY VIA REAL CLAUDE CODE.** The agent is the real headless `claude`; the server never fabricates assistant content. Every tool call and result shown corresponds 1:1 to an event Claude Code emitted.
- **NI3 — BYPASS-ON BY DEFAULT** (B3). A new session runs `--dangerously-skip-permissions` unless `CLAUDE_TERM_SKIP_PERMISSIONS=0`.
- **NI4 — REMOTE-ON BY DEFAULT** (B4). Every session is listable + drivable from the app at creation with no per-session enable; ≥2 clients may attach to one session concurrently.
- **NI5 — SESSION PERSISTENCE ACROSS RESTART/REBOOT** (B6). Session transcripts survive container restart and Shield reboot via Claude Code's session files in the persistence volume; a reattach after reboot replays full history.
- **NI6 — EVERY ACTION VISIBLE.** Bypassed approval (NI3) is paired with mandatory rendering of every `tool_use` — skipping the prompt never means hiding the action.

## 5. Acceptance criteria

- **AC1 — FAIL-CLOSED AUTH (inherited):** with a secret set and no cookie, `GET /` and `GET /ws` are blocked; after login they succeed. In open mode (`CLAUDE_TERM_NO_AUTH=1`) both serve, matching current deployment.
- **AC2 — SESSION LIFECYCLE:** `POST /api/sessions {cwd:"/data/claude"}` → 201 with an id; `GET /api/sessions` lists it; `DELETE` ends it.
- **AC3 — CWD CONFINEMENT (inherited I3):** `cwd:"/data/../system"`, `"/etc"` → 4xx, no session.
- **AC4 — NATIVE RENDER, NO GARBLE (the headline fix):** at a 360–414px viewport, sending a prompt that triggers text + a tool call renders: streamed assistant markdown, a ⏺ tool-call card, and a result — **with zero overlapping panels, zero horizontal overflow, and no duplicated status bars.** (Direct contrast with the v1 repro screenshots.)
- **AC5 — STREAMING:** assistant text appears incrementally (token/chunk deltas), not only as a final block.
- **AC6 — TOOL-CALL CARDS + DIFFS:** a tool call shows a collapsed summary; expanding reveals full input/output; a file edit renders as a unified red/green diff.
- **AC7 — BYPASS-ON (NI3):** a new session reaches a working agent that executes tools **without** surfacing an approval prompt; `--dangerously-skip-permissions` is on the spawned command.
- **AC8 — REMOTE-ON + MULTI-ATTACH (NI4):** two browsers open `/ws?session=<id>` for the same session; a message sent from one streams into **both**; interrupt from either stops the run.
- **AC9 — PERSISTENCE ACROSS RESTART (NI5):** create a session, exchange turns, `docker restart claude-term` (or reboot), reopen the app → the session is listed and its transcript replays in full.
- **AC10 — EVERY ACTION VISIBLE (NI6):** every tool Claude Code ran appears as a card in the transcript; none are silently elided.
- **AC11 — INTERRUPT:** pressing Interrupt during a run stops generation and returns the session to idle, ready for the next message.
- **AC12 — SNIPPET CHIPS PRESERVED:** the 6 seed Prompts chips inject into the composer (multi-line without auto-submitting; `submit:true` fires in one tap); editable via `snippets.json` with no rebuild.
- **AC13 — RUNS ON 4.9 / HOST-NET LAUNCH:** the built arm64 image starts on the Shield with no `ENOSYS`, serves `:7777`, `--network host` + `--restart=always`, reachable from another LAN host.
- **AC14 — NO DOCKER SOCKET / WORKSPACE-ONLY (inherited):** no socket mount; writes succeed under `/data/claude`, fail on `/system`.
- **AC15 — NO SECRETS IN HISTORY (inherited):** no `CLAUDE_TERM_SECRET` / OAuth token in image or git.

## 6. Acceptance tests (executable where scriptable; preserve the assertions if translated)

```sh
BASE=http://10.0.0.88:7777
# T1 sessions lifecycle (AC2)
ID=$(curl -s -X POST $BASE/api/sessions -H 'content-type: application/json' \
  -d '{"cwd":"/data/claude"}' | jq -r .id)
curl -s $BASE/api/sessions | jq -e --arg id "$ID" 'any(.[]; .id==$id)' >/dev/null
curl -s -X DELETE $BASE/api/sessions/$ID -o /dev/null -w '%{http_code}' | grep -q '^204$'

# T2 cwd confinement (AC3)
for bad in '/etc' '/data/../system' '/system'; do
  curl -s -X POST $BASE/api/sessions -H 'content-type: application/json' \
    -d "{\"cwd\":\"$bad\"}" -o /dev/null -w '%{http_code}' | grep -Eq '^4[0-9][0-9]$'
done

# T3 bypass-on in the spawned command (AC7)
docker exec claude-term sh -c 'ps -ef | grep -- "--dangerously-skip-permissions" | grep -qv grep'

# T4 no docker socket / workspace-only (AC14)
! docker exec claude-term sh -c 'test -S /var/run/docker.sock'
docker exec claude-term sh -c 'touch /data/claude/_w && rm /data/claude/_w'
docker exec claude-term sh -c 'touch /system/_w 2>&1' | grep -qiE 'read-only|denied|not found'

# T5 snippets present + default-seeded (AC12)
curl -s $BASE/api/snippets | jq -e 'length>=6 and all(.[]; has("label") and has("body"))' >/dev/null

# T6 runs on 4.9, serves :7777, no ENOSYS (AC13)
curl -s -o /dev/null -w '%{http_code}' $BASE/ | grep -q '^200$'
docker logs claude-term 2>&1 | grep -qvi 'ENOSYS'

# T7 no secrets in history (AC15)
! git -C G:/Documents/GIT/LOCAL-mod/NVIDIAShield log -p | grep -iE 'CLAUDE_CODE_OAUTH_TOKEN=sk|CLAUDE_TERM_SECRET='

# --- MANUAL (phone / headless browser at 390px) ---
# T8  native render, no garble (AC4)            — the headline check vs the v1 screenshots
# T9  streaming text appears incrementally (AC5)
# T10 tool-call card expands; edit shows a diff (AC6)
# T11 multi-attach: two tabs, message in one streams into both; interrupt from either (AC8)
# T12 persistence: turn, `docker restart claude-term`, reopen → transcript replays (AC9)
# T13 interrupt stops a run and returns to idle (AC11)
```

PASS = every scripted command exits 0 + the manual checks confirmed (with screenshots, given the whole point is legibility). A `pass` claim without its evidence is treated as not-done.

## 7. Risks / to verify before/at implementation (research leads, not ground truth)

- **R1 — Headless flags + event shape.** Confirm the pinned Claude Code version's `--print --output-format stream-json --input-format stream-json --include-partial-messages` flags and the exact JSON event types/fields on-device. **Load-bearing.** Fallback: if input-stream-json isn't supported, drive one-shot `-p` per turn with `--resume` for continuity (loses nothing semantically, slightly chattier process churn).
- **R2 — Session resume + id surfacing.** Confirm `--resume <id>` / `--continue`, where the session id appears in the stream (e.g. the `system`/`init` event), and that session files persist under `/home/claude` in the volume.
- **R3 — Token-level streaming.** Confirm partial-message streaming so text feels live; degrade gracefully to per-message rendering if absent (AC5 then satisfied at message granularity).
- **R4 — Concurrent input to one session (B4 multi-attach).** Confirm clean behavior when two clients send into one headless process; serialize on the server input queue if needed. Interrupt semantics in headless mode to verify (AC11).
- **R5 — Claude Code version drift.** Pin `@anthropic-ai/claude-code` to a known-good version in the image; headless stream JSON shape can change across releases.
- **R6 — Controlling externally-started sessions (B4 stretch).** Whether a `claude` started outside the app (bare CLI/SSH) can be surfaced + driven by the app. v1 scope guarantees control only for app-managed sessions; investigate a takeover path (shared session store + spawn-resume) as v1.x.
- **R7 — Diff rendering source.** Confirm whether edit tool events carry structured old/new (clean diff) or require server-side diffing of file state; fall back to before/after string diff if needed.

## 8. Deliverables

- `claude-term/public/` — the native app: session list, conversation transcript (markdown + ⏺ tool-call cards + diffs), streaming, `>` composer with snippet chips + slash-command hints, status footer, interrupt. **Replaces** the xterm.js page (`public/index.html`, `app.js`, `style.css` rewritten; xterm assets removed).
- `claude-term/server/agent.js` (new) — the headless Claude Code driver: spawn/resume/interrupt, parse the stream-json event stream, normalize to the WS event schema.
- `claude-term/server/hub.js` (new) — per-session hub: one process, N attached sockets, transcript replay on attach.
- `claude-term/server/sessions.js` (rewritten) — REST over the Claude Code session store (was tmux).
- `claude-term/server/pty-bridge.js`, `bracketed-paste.js` — **removed** (no longer the path).
- `claude-term/Dockerfile` — drop xterm deps + (optionally) tmux; pin `@anthropic-ai/claude-code`; otherwise inherits v1.
- `claude-term/snippets.json` — kept as-is.
- `docs/THREAT-MODEL.md` — append a v2 note: the surface is now a **bypass-permissions, remote-control-by-default** agent on plain-HTTP LAN; blast radius = `/data/claude` + the OAuth token + LAN reach; the bound is still the no-docker-socket + workspace-confinement, plus "every action is rendered" as an audit aid; upgrade path = HTTPS + per-user auth + native Approve/Deny.
- `README.md` — update the `claude-term` row (TUI → native Claude Code UI).

## 9. Git preflight

Commit this spec, then the rewrite, under `master` (user convention), in small labelled commits. `.gitignore` already covers `node_modules`/build/secrets. No OAuth token or passphrase enters history (inherited I11). v1's spec and bringup notes stay as the historical record of the path this supersedes.
