# shield-c2

Status + command-and-control dashboard for the NVIDIA Shield Docker host.
SvelteKit (`adapter-node`), one Node process, shipped as a minimal arm64
container. **Unauthenticated by design** (A2) — see `../docs/THREAT-MODEL.md`.

## What it shows

Live over SSE (`/api/stream`, default 2 s, single shared sampler): CPU per-core +
aggregate + load/runnable/total, RAM (used = total − available, cached shown
separately), Drive (ext4 usage + `/proc/diskstats` rates; SMART honestly absent),
Network per-iface rates, Temps. Plus a Containers card with per-container
start/stop/restart and a logs viewer.

All host metrics come from the **read-only** bind mounts `/host/proc`,
`/host/sys`, `/host/data` — never the container's own `/proc`.

## Endpoints (no auth)

- `GET /api/metrics` — one-shot `MetricsSnapshot`.
- `GET /api/stream` — SSE, `event: metrics` every interval.
- `GET /api/containers` — list.
- `POST /api/containers/:id/{start,stop,restart}` — 204 on success (POST-only).
- `GET /api/containers/:id/logs?tail=N` — `text/plain` (default 200, cap 1000).

The server only ever performs the docker allowlist
`{list, inspect, start, stop, restart, logs}`. No generic socket passthrough
(I2).

## Run

On the Shield, via the launcher:

```sh
sh docker-bringup/c2.sh
```

It builds/loads `shield-c2:latest`, removes any prior container, asserts port 8888
is free, and runs with `--network host`, `--restart=always`, ro `/proc`/`/sys`/
`/data`, and the rw docker socket. Idempotent.

## Env

| var | default | meaning |
|-----|---------|---------|
| `SHIELD_C2_PORT` | `8888` | listen port |
| `SHIELD_C2_INTERVAL_MS` | `2000` | sampler cadence (floor 1000) |
| `HOST_PROC` | `/host/proc` | host /proc mount |
| `HOST_SYS` | `/host/sys` | host /sys mount |
| `HOST_DATA` | `/host/data` | host /data mount |

No `SHIELD_C2_TOKEN` — there is no auth (A2).

## Dev

```sh
cd shield-c2
npm install
# point collectors at the real host paths for local testing:
HOST_PROC=/proc HOST_SYS=/sys HOST_DATA=/ npm run dev
```
