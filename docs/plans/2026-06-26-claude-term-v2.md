# Plan — `claude-term` v2 (native Claude Code UI)

Implements [`SPEC-claude-term-v2.md`](../SPEC-claude-term-v2.md). De-risk probes (R1–R7) were run against the **live** container (Claude Code `2.1.185`) before this plan; the event mapping below is observed, not assumed.

## Confirmed device facts (from on-device probes)

- Flags present: `--print`, `--output-format stream-json`, `--input-format stream-json`, `--include-partial-messages`, `--resume <id>`, `--session-id <uuid>`, `--dangerously-skip-permissions`.
- `--output-format stream-json` requires `--verbose` in print mode.
- Emitted event stream (newline-delimited JSON):
  | Claude Code event | fields used | → WS event |
  |---|---|---|
  | `system`/`init` | `session_id`, `model`, `slash_commands`, `cwd` | record id; `status` (model, slashCommands) |
  | `stream_event` → `content_block_delta`/`text_delta` | `event.delta.text` | `assistant_delta` (live text) |
  | `assistant` | `message.content[]` (text \| tool_use) | `assistant_message` (text→md) + `tool_use` (id,name,input) |
  | `user` | `message.content[]` tool_result | `tool_result` (id=tool_use_id, content, isError) |
  | `result` | `total_cost_usd`, `usage`, `stop_reason` | `result` → footer cost + idle |
  | `rate_limit_event` | (ignored) | — |
- `--resume <session_id>` continues a session; transcripts persist at `/home/claude/.claude/projects/<cwd-with-slashes-as-dashes>/<id>.jsonl` (in the persistence volume → survives restart/reboot). Records are `{type:"user"|"assistant", message:{content}}` — same content shape as the live stream, so one normalizer serves both.
- Diffs (R7): render from the `tool_use.input` of `Edit` (`old_string`/`new_string`) and `Write` (`content`) — no need to diff file state.

## Architecture decision (refines spec D1)

**One Claude Code process per user turn, `--resume` for continuity** (the spec's named R1 fallback, promoted to primary): more robust on this hardware than a long-lived stdin protocol, gives crash isolation, and makes interrupt = kill-the-turn. Continuity + persistence come from `--resume` + the session `.jsonl`. Streaming feel comes from `--include-partial-messages`.

## Build order

1. **`server/agent.js`** — `runTurn({cwd, sessionId, text, skipPermissions, onEvent})`: spawn `claude` headless, line-split stdout, JSON.parse, normalize → WS events via `onEvent`; resolve with the (possibly newly-assigned) `session_id`; expose `kill()` for interrupt. Pure/injectable `spawn` for tests.
2. **`server/sessions.js`** (rewrite) — over the Claude Code session store: `validId` (uuid), `confineCwd` (kept), `projectDir(cwd)`, `listSessions()` (scan `projects/*/*.jsonl` → id/title/cwd/mtime, merged with live hub), `loadTranscript(id,cwd)` (parse `.jsonl` → normalized WS events), `createSession({cwd})` (alloc uuid).
3. **`server/hub.js`** — registry of live `Session`s: `{id,cwd,model,clients:Set,transcript:[],proc,queue}`. `attach(ws,id)` replays transcript (in-mem else `.jsonl`) then live; `userMessage(id,text)` → broadcast user echo, start a turn (or queue), broadcast+buffer each event, idle on done; `interrupt(id)`; `broadcast`.
4. **`server/http.js`** (edit) — POST `/api/sessions` {cwd}→{id}; DELETE; WS `/ws?session=<uuid>` → `hub.attach`; keep `/api/dirs`, `/api/snippets`. Auth gate unchanged (covers WS).
5. **`server/index.js`** (edit) — wire hub; drop tmux deps.
6. **`server/static.js`** (edit) — drop xterm vendor map.
7. **`package.json`** — remove `@homebridge/node-pty-prebuilt-multiarch`, `@xterm/*`; keep `ws`.
8. **`public/index.html` + `app.js` + `style.css`** (rewrite) — native UI: header (session select + new + model/ctx), transcript (streamed markdown bubbles, ⏺ collapsible tool-call cards, red/green unified diffs), `>` composer (native keyboard, send, interrupt, slash hints, snippet-chips overlay), footer (model · ctx% · cost). Dependency-free client (compact markdown + line-diff in JS). Remove `pty-bridge.js`, `bracketed-paste.js`.

## Deploy (no full rebuild — fast path per bringup notes)

App is pure JS over the existing image (claude-code + node + ws already inside; no new npm deps): `adb push` new `server/`+`public/`+`package.json` → CTX `/data/docker/claude-term/` → `docker cp` into running `claude-term:/app/` → `docker commit claude-term claude-term:latest` (durable) → restart node. Also update the repo Dockerfile/build script so a from-scratch rebuild stays correct (drop node-pty verify), but don't run the slow rebuild.

## Verify (evidence required — the whole point is legibility)

Playwright at 390px against live `:7777`: AC4 (native render, **no garble** — screenshot vs the v1 repro), AC5 (streaming), AC6 (tool card + diff), AC8 (two tabs, one session), AC9 (restart → transcript replays), AC11 (interrupt). Plus the scriptable §6 tests. Commit+push repo in small labelled commits; update README row + THREAT-MODEL note.
