# SPEC — `shield-c2`

SvelteKit status + command-and-control page for the NVIDIA Shield Docker host, shipped as its own minimal arm64 container.

> **Provenance:** Council v2 Stage-0 spec (arch tier). Arbiter: Opus 4.8 (standing in — Fable 5 unavailable). **User-approved 2026-06-18** with two binding amendments applied below. Downstream council stages (blind generation → adversarial verification → arbitration) implement to THIS document; deviations require an arbiter-logged exception.

## 0. User-approved amendments (authoritative — override anything below)

- **A1 — Port = 8888** (not 8080). Admin UI at `http://10.0.0.88:8888`. `SHIELD_C2_PORT` defaults to 8888.
- **A2 — NO AUTHENTICATION.** The page is unauthenticated, matching the host's existing Uptime-Kuma (3001), per explicit user decision on a trusted home LAN. Remove all login/token/session/CSRF-token machinery (`SHIELD_C2_TOKEN`, `/login`, `/logout`, `/api/csrf`, session cookies). **KEEP** the docker-socket allowlist (I2) — it is the real blast-radius limiter and is independent of auth. Mutations stay **POST-only** (not triggerable by a stray GET/img tag). The threat-model doc must state honestly that the surface is unauthenticated by choice and anyone on the LAN can drive containers.

## 1. Device reality (the spec exists to honor these)

- Host: NVIDIA Shield TV "foster" (Pro, 3 GB RAM), LineageOS 22.x userdebug, Android 15, **kernel 4.9.141 aarch64**, Tegra X1. LAN IP 10.0.0.88.
- Docker: static 24.0.9, cgroup v1 (forced via private-mount-ns trick), storage overlay2, daemon socket `unix:///data/docker/docker.sock`, binaries `/data/docker/bin`, `--restart=always`, daemon auto-started by Android init service `dockerd` on `sys.boot_completed=1`.
- Networking: bridge/veth is **broken** on this kernel (ARP INCOMPLETE across docker0). **MANDATORY `--network host`.** No `-p`, no bridge nets. Container binds a host port directly on 10.0.0.88. Occupied host ports: Uptime-Kuma 3001.
- SELinux permissive, root available. To see HOST cpu/mem/net/thermal the container bind-mounts host `/proc`, `/sys`, `/data` **read-only** and reads from the mount (unambiguous; never the container's own `/proc`).

## 2. Resolved design decisions (locked, with justification)

- **D1 — Adapter: `@sveltejs/adapter-node`.** The C2 backend needs a server runtime inside the container to open the unix docker socket, read bind-mounted `/proc`+`/sys`, and hold the SSE stream. One Node process serves UI + `+server.ts` API. `hooks.server.ts` is the single request chokepoint.
- **D2 — Live updates: Server-Sent Events (SSE)** over `GET /api/stream`, default cadence 2 s (`SHIELD_C2_INTERVAL_MS`, floor 1000). One long-lived HTTP/1.1 response, native `EventSource` auto-reconnect, trivially `curl -N`-testable. **A single shared server-side sampler** reads `/proc`/`/sys` once per tick and fans out to all clients (I7) — `/proc` reads are O(1) in client count, protecting the eMMC. Websocket rejected (full-duplex unneeded; commands go over POST). Poll rejected (per-client read amplification).
- **D3 — Base image: `node:20-bookworm-slim` (arm64, digest-pinned), NOT alpine.** Kernel 4.9 + musl/newer toolchains trip `ENOSYS` on absent syscalls (faccessat2 ~5.8, clone3, statx edges); glibc 2.36 (bookworm) degrades instead of hard-failing. node:20 (conservative LTS). Documented fallback `node:18-bullseye-slim` (glibc 2.31) — a swap only on a failed on-device smoke test, logged as an exception. Multi-stage build; runtime stage carries only `build/` + production `node_modules` + `package.json`. **Size target ≤250 MB, hard ceiling 350 MB.**
- **D4 — Host port: 8888** (per A1; env-overridable). Free vs Uptime-Kuma. Launcher asserts the port is free before binding.
- **D5 — Auth posture & threat model (per A2): UNAUTHENTICATED by user decision.** The docker socket = root-equivalent control of the Shield (a POST that could reach `create` + privileged mount = full host compromise). Because we cannot rely on auth, the **socket allowlist (I2) is the sole and primary control**: the server NEVER proxies the raw socket to the client and only ever performs `{list, inspect, start, stop, restart, logs}` — never `create/exec/commit/build/pull/volume/network`. THREAT MODEL (state honestly in `docs/THREAT-MODEL.md`): trusted operator on a trusted home LAN; the page is open to anyone on that LAN (guest device, IoT junk, a stray browser doing a cross-origin POST). Mutations are POST-only to avoid trivial GET/CSRF-by-image, but with no session there is no token-based CSRF defense — residual risk acknowledged. Plain HTTP ⇒ traffic is sniffable on a hostile L2. The named upgrade path if exposure ever changes: add auth + TLS behind a reverse proxy. The allowlist, not the transport or auth, bounds the blast radius.
- **D6 — Drive health / SMART degradation:** `/data` ext4 usage ALWAYS available (statvfs on bind-mounted `/data`). Per-disk I/O ALWAYS available from `/proc/diskstats` (delta → IOPS + throughput). SMART almost certainly NOT viable (Tegra eMMC has no ATA SMART; SATA SMART needs CAP_SYS_RAWIO + ata passthrough this stack lacks) — do NOT bundle smartctl. The drive card shows ext4 usage + diskstats as the primary signal and a clearly-labelled `smart.available:false` with a human reason. **Absence of SMART never blanks the card (I4).**
- **D7 — Metric sourcing (all from read-only host mounts):** CPU per-core + aggregate from `/proc/stat` (two-sample delta); load average from `/proc/loadavg` WITH runnable/total procs surfaced (I3, the load-vs-idle honesty). RAM from `/proc/meminfo` (`used = MemTotal − MemAvailable`; show Cached separately). Per-interface net from `/proc/net/dev` (delta → rate). Temps from `/sys/class/thermal/thermal_zone*/` (millideg → °C), degrade if absent. Containers via the docker socket REST API.

## 3. Interface / contract

All paths under `http://10.0.0.88:8888`. **No auth** (A2) — every endpoint is reachable without login.

**Metrics (read)**
- `GET /api/stream` → `text/event-stream`. Server pushes `event: metrics` with a `MetricsSnapshot` JSON on the shared timer (default 2 s). One sampler fans out to all clients (I7). On a sampler fault emits `event: error data:{message}` but does NOT terminate the stream.
- `GET /api/metrics` → one-shot JSON `MetricsSnapshot` (same shape) for non-SSE clients / tests.

`MetricsSnapshot` (numeric fields finite, or null when unavailable):
```
{
  ts: number,                              // epoch ms, server clock
  cpu: {
    perCore: [{ id:number, usagePct:number }],   // 0..100, delta-derived
    aggregatePct: number,
    load: { one:number, five:number, fifteen:number, runnable:number, total:number },  // I3
    coreCount: number
  },
  mem: { totalKb, freeKb, availableKb, cachedKb, buffersKb, usedKb },   // usedKb = totalKb - availableKb
  drive: {
    data: { mount:"/data", fsType:"ext4", totalBytes, freeBytes, usedBytes, usedPct },
    diskstats: [{ dev, readsPerSec, writesPerSec, readBytesPerSec, writeBytesPerSec }],
    smart: { available:false, reason:string } | { available:true, devices:[...] }   // I4
  },
  net: [{ iface, rxBytes, txBytes, rxBytesPerSec, txBytesPerSec }],
  temps: [{ zone, type, celsius }],        // [] when no thermal zones — not an error
  sampleIntervalMs: number
}
```

**Container C2**
- `GET  /api/containers` → `[{ id, name, image, state, status, ports }]` (socket `GET /containers/json?all=1`).
- `POST /api/containers/:id/start`   → 204 | error JSON. (socket `POST /containers/:id/start`)
- `POST /api/containers/:id/stop`    → 204 | error JSON.
- `POST /api/containers/:id/restart` → 204 | error JSON.
- `GET  /api/containers/:id/logs?tail=N` → `text/plain` (default 200, cap 1000).
- The server NEVER exposes a generic socket passthrough. ONLY the allowlist {list, inspect, start, stop, restart, logs} is reachable; `create/exec/commit/build/pull` are unreachable (I2).

**Error contract:** every endpoint returns JSON `{error, detail?}` with an appropriate 4xx/5xx on failure.

**Container / run contract**
- Image FROM `node:20-bookworm-slim` (digest-pinned), multi-stage, arm64. ENTRYPOINT `node build`.
- Env: `SHIELD_C2_PORT` (default 8888), `SHIELD_C2_INTERVAL_MS` (default 2000, floor 1000), `HOST_PROC` (default `/host/proc`), `HOST_SYS` (default `/host/sys`), `HOST_DATA` (default `/host/data`). **No `SHIELD_C2_TOKEN`** (A2).
- Bind mounts (set by launcher): `ro /proc→/host/proc`, `ro /sys→/host/sys`, `ro /data→/host/data`, `rw /data/docker/docker.sock→/var/run/docker.sock`.
- Run flags: `--network host`, `--restart=always`, `--name shield-c2`.

**Launcher contract — `docker-bringup/c2.sh`** follows the standard launcher conventions: `BB=/data/docker/bin/busybox`, `DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"`, preflight `docker version` check, build-or-load image, remove any prior `shield-c2`, then `docker run -d` with the flags+mounts+env above, port-free assertion before run, finish with a `docker ps` table. Idempotent.

## 4. Invariants

- **I1′ NO-AUTH BY DECISION** (replaces fail-closed auth): the page is intentionally unauthenticated (A2). The socket allowlist (I2) is the blast-radius control. The container starts without any token.
- **I2 SOCKET ALLOWLIST:** server performs ONLY {list, inspect, start, stop, restart, logs}. No generic passthrough. create/exec/commit/build/pull/volume/network never invoked. Socket mounted rw (control needs it); blast radius bounded by this server-side allowlist.
- **I3 LOAD-VS-IDLE HONESTY:** CPU card shows load average AND runnable/total proc counts together; aggregate% and load both shown so I/O-wait load isn't misread as CPU saturation.
- **I4 DRIVE GRACEFUL DEGRADE:** absence of SMART never blanks/errors the drive card; ext4 usage + diskstats always render; `smart.available:false` + reason is a normal state.
- **I5 HOST-NET-ONLY:** `--network host`, binds `SHIELD_C2_PORT` on the LAN IP. No `-p`, no bridge, no docker0 dependency anywhere.
- **I6 READ-ONLY HOST MOUNTS:** `/proc`,`/sys`,`/data` bind-mounted read-only; server reads host metrics only from these. Only writable host resource is the docker socket.
- **I7 SINGLE SHARED SAMPLER:** exactly one server-side sampling loop per interval, fanned out to all SSE clients. Reads are O(1) in client count.
- **I8′ POST-ONLY MUTATION:** all state changes (start/stop/restart) are POST, never reachable via GET. (No session/CSRF token under A2; residual cross-origin-POST risk documented.)
- **I9 CONSERVATIVE SYSCALL BASE:** runtime image runs on kernel 4.9.141 without `ENOSYS` at startup (glibc base; node:20-bookworm-slim or documented node:18-bullseye-slim fallback). Base change is a logged exception.
- **I10 RESOURCE FRUGALITY:** image ≤250 MB (hard ceiling 350 MB); steady-state RSS target <150 MB so it coexists with Uptime-Kuma and other workloads on 3 GB. No bundled smartctl/heavy deps.
- **I11 SOCKET PATH FIDELITY:** host socket `unix:///data/docker/docker.sock` mapped to where the app expects it; launcher and app agree (mapped to the conventional `/var/run/docker.sock`).
- **I12 NO SECRETS/BLOBS IN HISTORY:** nothing baked into the image or git history; `.gitignore` excludes `node_modules`/build/.svelte-kit and the pre-existing multi-hundred-MB `.apk`/`.zip`/`.img`/`.tgz` blobs.

## 5. Acceptance criteria

- **AC1′ NO-AUTH REACHABLE:** the container starts with no token set; `GET /api/metrics` returns 200 without any login; there is no `/login` endpoint.
- **AC2 ALL METRICS PRESENT:** one `GET /api/metrics` returns a `MetricsSnapshot` where `cpu.perCore.length == cpu.coreCount`, `mem` has used/free/cached, `drive.data.usedPct` is finite 0..100, `drive.diskstats` non-empty, `net` has ≥1 iface with `*PerSec` fields, `temps` is an array.
- **AC3 CPU CORRECTNESS:** `cpu.perCore` usages 0..100 from two `/proc/stat` samples; `load` includes runnable AND total (I3).
- **AC4 RAM SEMANTICS:** `mem.usedKb == totalKb - availableKb`; `cachedKb` reported separately, non-zero on a running box.
- **AC5 DRIVE DEGRADES:** with no SMART, `drive.smart.available:false` + reason; `drive.data` + `drive.diskstats` still render (I4); ext4 used/total match host `/data` within rounding.
- **AC6 NET RATES:** across two snapshots a busy iface shows `rx/txBytesPerSec > 0` from byte deltas; idle ≈0, never negative.
- **AC7 SSE LIVE + SINGLE SAMPLER:** `GET /api/stream` emits `event: metrics` at cadence; with two clients the server still runs ONE sampler (I7) — per-interval `/proc`-read count does not scale with clients.
- **AC8 C2 LIST:** `GET /api/containers` lists the running stack (uptime-kuma, shield-c2, …) with id/name/image/state.
- **AC9′ C2 CONTROL ROUNDTRIP:** `POST .../stop` on a disposable test container → exited; `.../start` → running; `.../restart` bounces it. (POST-only; a GET to the same path does not mutate — I8′.)
- **AC10 C2 LOGS:** `GET /api/containers/:id/logs?tail=50` returns last lines as `text/plain`.
- **AC11 SOCKET ALLOWLIST:** no code path forwards an arbitrary docker call; `create/exec/build` unreachable (I2) — verified by code inspection + a negative test.
- **AC12 IMAGE RUNS ON 4.9:** built arm64 image starts on the Shield (kernel 4.9.141) with no ENOSYS at boot and serves `http://10.0.0.88:8888` (I9).
- **AC13 IMAGE SIZE:** image size ≤250 MB target, hard-fail >350 MB (I10).
- **AC14 HOST-NET RUN RECIPE:** `docker-bringup/c2.sh` launches with `--network host`, `--restart=always`, ro `/proc`/`/sys`/`/data`, rw socket, on port 8888, idempotent; reachable from another LAN host at 10.0.0.88:8888 (I5).
- **AC15 READ-ONLY MOUNTS:** `/proc`,`/sys`,`/data` read-only in the container (write fails); only the socket is writable (I6).
- **AC16 GIT PREFLIGHT:** repo initialized `git init -b master` + `.gitignore` excluding node_modules/build and the existing `.apk`/`.zip`/`.img`/`.tgz` blobs; no blob/secret in history (I12).
- **AC17 PORT JUSTIFIED & FREE:** 8888 documented as unused vs Uptime-Kuma (3001); launcher asserts free; `SHIELD_C2_PORT` makes a collision a one-line change (D4).
- **AC18 THREAT MODEL STATED:** `docs/THREAT-MODEL.md` states honestly: unauthenticated by user choice, socket = root-equivalent, allowlist is the blast-radius limiter, plain-HTTP-on-LAN is sniffable, upgrade path = auth + TLS via reverse proxy (D5/A2).

## 6. Acceptance tests (executable; preserve the assertions if translated to Vitest/Playwright)

```sh
# T1 no-auth reachable (AC1')
curl -s -o /dev/null -w '%{http_code}' http://10.0.0.88:8888/api/metrics | grep -q '^200$'
curl -s -o /dev/null -w '%{http_code}' http://10.0.0.88:8888/login | grep -q '^404$'   # no login route

# T2 metrics present & well-formed (AC2..AC6) — jq assertions
M=$(curl -s http://10.0.0.88:8888/api/metrics)
echo "$M" | jq -e '(.cpu.perCore|length) == .cpu.coreCount' >/dev/null
echo "$M" | jq -e '.cpu.perCore | all(.usagePct>=0 and .usagePct<=100)' >/dev/null
echo "$M" | jq -e '.cpu.load | has("runnable") and has("total")' >/dev/null
echo "$M" | jq -e '.mem.usedKb == (.mem.totalKb - .mem.availableKb)' >/dev/null
echo "$M" | jq -e '.mem.cachedKb > 0' >/dev/null
echo "$M" | jq -e '.drive.data.usedPct>=0 and .drive.data.usedPct<=100' >/dev/null
echo "$M" | jq -e '.drive.diskstats | length >= 1' >/dev/null
echo "$M" | jq -e '.drive.smart.available==false and (.drive.smart.reason|length>0)' >/dev/null
echo "$M" | jq -e '.net | length>=1 and (.[0]|has("rxBytesPerSec"))' >/dev/null
echo "$M" | jq -e '.temps | type=="array"' >/dev/null

# T3 net rate delta-derived, never negative (AC6)
curl -s http://10.0.0.88:8888/api/metrics >/dev/null ; sleep 3
curl -s http://10.0.0.88:8888/api/metrics | jq -e '.net | all(.rxBytesPerSec>=0 and .txBytesPerSec>=0)' >/dev/null

# T4 SSE stream emits metrics (AC7)
timeout 6 curl -N -s http://10.0.0.88:8888/api/stream | grep -m1 -q '^event: metrics'

# T6 container list/control/logs (AC8..AC10) via the real daemon
docker run -d --name t_target busybox:latest sleep 600
CID=$(docker inspect -f '{{.Id}}' t_target)
curl -s http://10.0.0.88:8888/api/containers | jq -e --arg id "$CID" 'any(.[]; .id|startswith($id[0:12]))' >/dev/null
curl -s -X POST http://10.0.0.88:8888/api/containers/$CID/stop -o /dev/null -w '%{http_code}' | grep -q '^204$'
sleep 2 ; test "$(docker inspect -f '{{.State.Running}}' t_target)" = "false"
# GET must NOT mutate (I8'):
curl -s http://10.0.0.88:8888/api/containers/$CID/start -o /dev/null
sleep 1 ; test "$(docker inspect -f '{{.State.Running}}' t_target)" = "false"
curl -s -X POST http://10.0.0.88:8888/api/containers/$CID/start -o /dev/null -w '%{http_code}' | grep -q '^204$'
sleep 2 ; test "$(docker inspect -f '{{.State.Running}}' t_target)" = "true"
curl -s http://10.0.0.88:8888/api/containers/$CID/logs?tail=50 -o /dev/null -w '%{http_code}' | grep -q '^200$'
docker rm -f t_target

# T7 socket allowlist (AC11/I2) — crafted calls must not reach the socket
for p in /api/containers/create /api/exec /api/build /api/images/create ; do
  curl -s -X POST http://10.0.0.88:8888$p -o /dev/null -w '%{http_code}' | grep -Eq '^40[0-9]$'
done
! grep -RInE '/(exec|build|commit)|containers/create|images/create' src/lib/server/docker*

# T8 image runs on kernel 4.9, serves :8888 (AC12/I9)
curl -s -o /dev/null -w '%{http_code}' http://10.0.0.88:8888/ | grep -Eq '^200$'
docker logs shield-c2 2>&1 | grep -qiv 'ENOSYS'

# T9 image size (AC13/I10)
SZ=$(docker image inspect shield-c2 --format '{{.Size}}') ; test "$SZ" -lt 367001600   # 350MB ceiling

# T10 read-only host mounts (AC15/I6)
docker exec shield-c2 sh -c 'touch /host/proc/_w 2>&1' | grep -qi 'read-only\|denied'

# T11 launcher idempotency + host-net + restart (AC14/AC17/I5)
# (run c2.sh twice; second run must not error)
docker inspect -f '{{.HostConfig.NetworkMode}}' shield-c2 | grep -q '^host$'
docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' shield-c2 | grep -q 'always'

# T12 git preflight (AC16/I12) — BEFORE generation
git -C G:/Documents/GIT/LOCAL-mod/NVIDIAShield rev-parse --is-inside-work-tree
grep -qE 'node_modules|\.svelte-kit|/build|\*\.apk|\*\.zip|\*\.img|\*\.tgz' G:/Documents/GIT/LOCAL-mod/NVIDIAShield/.gitignore

# T13 threat-model + port justification present (AC17/AC18)
grep -qi 'root-equivalent' docs/THREAT-MODEL.md
grep -qi '8888' docs/*.md && grep -qiE '9000|3001' docs/*.md
```

PASS = every command exits 0. Per council-v2: a `pass` claim on any AC without the corresponding evidence artifact is treated as `abstain`.

## 7. Deliverables

- `shield-c2/` — the SvelteKit (adapter-node) app: dashboard with CPU / RAM / Drive / Network / Temps / Containers cards live over SSE, per-container start/stop/restart + logs viewer. Server-side metric collectors reading the bind-mounted host paths; typed docker-socket client implementing only the allowlist.
- `shield-c2/Dockerfile` — multi-stage, arm64, `node:20-bookworm-slim` (digest-pinned), ≤250 MB.
- `docker-bringup/c2.sh` — launcher following the standard launcher conventions (host net, `--restart=always`, ro `/proc`/`/sys`/`/data`, rw socket, env, idempotent, port-free assertion).
- `docs/THREAT-MODEL.md` — the honest unauthenticated-by-choice threat model.

## 8. Git preflight (cleared before generation)

`git init -b master` in the repo root (default branch `master` per user convention), commit the `.gitignore` (excludes node_modules/build/.svelte-kit and the existing `.apk`/`.apkm`/`.img`/`.zip`/`.tgz` blobs + `docker-bringup/docker/`), and an initial commit of the existing tree so the worktree-isolated generators branch from a known base. No large blob or secret enters history (I12).
