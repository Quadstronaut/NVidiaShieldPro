# shield-c2 — Threat Model (unauthenticated-by-choice)

**Scope:** the `shield-c2` status + command-and-control dashboard running on the
NVIDIA Shield Docker host, reachable at `http://10.0.0.88:8888`.

## Posture: UNAUTHENTICATED by explicit decision (A2 / D5)

There is **no authentication**. No login, no token, no session, no CSRF token.
This matches the host's other unauthenticated service — Uptime-Kuma (3001) —
and is a deliberate choice for a **trusted operator on a
trusted home LAN**. The page is open to **anyone on that LAN**: a guest device, a
piece of IoT junk, or a stray browser issuing a cross-origin POST. This document
states that openly.

## The real risk: the docker socket is root-equivalent

The Shield's docker socket (`unix:///data/docker/docker.sock`) is mounted into
this container read-write because control (start/stop/restart) needs it. **Full,
unrestricted access to that socket is root-equivalent control of the Shield** —
a single `POST /containers/create` with a privileged bind mount, followed by
`start`, is a complete host compromise. SELinux is permissive here, so the socket
is the whole game.

## The blast-radius control: a server-side ALLOWLIST (I2), not auth

Because there is deliberately no auth, the **socket allowlist is the sole and
primary control**. The server **never proxies the raw socket to the client**.
The typed docker client (`src/lib/server/docker.js`) implements **only**:

| Operation | Docker call |
|-----------|-------------|
| list      | `GET /containers/json?all=1` |
| inspect   | `GET /containers/:id/json` |
| start     | `POST /containers/:id/start` |
| stop      | `POST /containers/:id/stop` |
| restart   | `POST /containers/:id/restart` |
| logs      | `GET /containers/:id/logs` |

Operations that would escalate — `create`, `exec`, `commit`, `build`, `pull`,
`volume`, `network` — are **never constructed anywhere in the code**. There is no
generic passthrough route. The set of paths a request can reach the socket
through is fixed at build time. The container id is validated against a strict
character class and URL-encoded before it is embedded in a fixed path, so it
cannot be used to inject an arbitrary docker path.

**Consequence:** the worst an attacker on the LAN can do is start/stop/restart or
read logs of containers that already exist. They cannot create a privileged
container, cannot exec into one, cannot pull or build an image, cannot mount the
host filesystem. The allowlist — not the transport, not auth — bounds the blast
radius.

## Mutations are POST-only (I8'), but there is no CSRF token

All state changes (start/stop/restart) are **POST-only**. A stray `GET` — an
`<img src>`, a link prefetch, a search-engine crawler — **cannot** mutate state;
the routes have no GET handler and return 405. This blocks the trivial
CSRF-by-image class.

**Residual risk (acknowledged):** with no session there is **no token-based CSRF
defense**. A malicious page open in an operator's browser can issue a
cross-origin `POST` (a simple form post or `fetch`) that the operator's browser
will send to `10.0.0.88:8888`. Such a request can stop/start/restart a container.
It still **cannot** exceed the allowlist — so the cap is "bounce an existing
container", not "compromise the host". This residual risk is accepted for the
home-LAN deployment.

## Transport: plain HTTP is sniffable on a hostile L2

Traffic is **plain HTTP**. On a hostile layer-2 segment (rogue AP, ARP spoof) it
is **sniffable and tamperable**. There are no credentials to steal (no auth), but
container names, images, logs, and host metrics are exposed, and responses could
be tampered in transit. Acceptable on the trusted home LAN; not acceptable if the
service is ever exposed beyond it.

## Read-only host exposure (I6)

Host `/proc`, `/sys`, and `/data` are bind-mounted **read-only** at `/host/*`.
The server reads metrics only from these. A write to any of them fails. The
**only writable host resource** is the docker socket, whose use is bounded by the
allowlist above.

## Named upgrade path (if exposure ever changes)

If this service is ever reachable beyond the trusted home LAN, the upgrade path
is explicit:

1. Put it **behind a reverse proxy** (e.g. Caddy/nginx/Traefik).
2. Terminate **TLS** at the proxy (HTTPS).
3. Add **authentication** at the proxy (basic auth at minimum; ideally an
   identity-aware proxy or mTLS).
4. Optionally add a CSRF token in the app once a session exists.

Until then: the allowlist is the control, the LAN is the trust boundary, and this
document is the statement of what that means.

---

# claude-term v2 — Threat Model (a bypass-permissions agent, by design)

**Scope:** the `claude-term` native Claude Code UI at `http://10.0.0.88:7777`
(see [`SPEC-claude-term-v2.md`](SPEC-claude-term-v2.md)). This is a **different and
more powerful surface than `shield-c2`** and is documented honestly as such.

## Posture: open LAN, bypass permissions ON, remote control ON

As currently deployed (`CLAUDE_TERM_NO_AUTH=1`), the page is **unauthenticated on
the LAN**, like Uptime-Kuma and `shield-c2`. Two user-locked defaults raise the
stakes beyond `shield-c2`:

- **Bypass permissions is ON for every session** (`--dangerously-skip-permissions`).
  There is **no per-action approval gate** — the agent runs tools (bash, file
  edits, web fetch) without asking. Mitigation is *visibility*, not gating: every
  tool call is rendered as a card in the transcript (NI6), so actions are auditable
  after the fact, not blocked before it.
- **Remote control is ON for every session by default.** Any client on the LAN can
  list, attach to, drive, and interrupt **any** session with no per-session enable,
  and **multiple devices can drive one session at once**. This is the intended
  ergonomics (the operator's phone is the control surface) — and it means anyone on
  the LAN has the same power.

## Blast radius

A LAN user who opens `:7777` can drive a **full Claude Code agent** that can:

- run arbitrary commands **as the in-container `claude` user** (non-root, uid 1000);
- **read and write `/data/claude`** (the only writable host mount) and anything the
  agent clones/creates there;
- **spend the operator's Claude subscription / credits** via the injected
  `CLAUDE_CODE_OAUTH_TOKEN` (each turn has a real dollar cost — visible in the
  footer);
- reach the **LAN** from the container (host networking).

## The bright line vs `shield-c2`: NO docker socket (I9)

`claude-term` **never mounts or contacts the docker socket** (verified: `ls
/var/run/docker.sock` inside the container fails). So — unlike `shield-c2` — it
**cannot** control Docker, create privileged containers, or escalate to host root.
It is **workspace-confined** to `/data/claude` (a new session's cwd must `realpath`
under it), runs **non-root**, and binds only port 7777. The container can be
messed with from the LAN; the **host and the other containers cannot** be reached
through it.

## Plain HTTP

Same as the rest of the stack: traffic is sniffable/tamperable on a hostile L2.
The OAuth token is **not** sent to the browser (it lives only in the container
env), but prompts, transcripts, and the LAN-crossing secret (if the gate is
re-enabled) are cleartext.

## Named upgrade path

1. Re-enable the **passphrase gate** (`CLAUDE_TERM_NO_AUTH=0` + `CLAUDE_TERM_SECRET`)
   — already supported; or put it behind a reverse proxy with TLS + per-user auth.
2. Turn **bypass off** (`CLAUDE_TERM_SKIP_PERMISSIONS=0`) and add native
   **Approve/Deny** prompts (the deferred v1.x fast-follow) so destructive actions
   gate before they run.
3. **Scope the OAuth token** to bound credit exposure.

Until then: no-docker-socket + workspace-confinement + non-root bound the host
blast radius; "every action is rendered" is the audit aid; the LAN is the trust
boundary; and this section is the honest statement that `:7777` is a
bypass-permissions agent anyone on that LAN can drive.
