# `docker-bringup/` — the on-device scripts

The real shell scripts used to bring Docker up on this Shield and to investigate the kernel-4.9 networking. They run on the device (Toybox `/system/bin/sh`), driven over ADB. Kept verbatim for the record — some are the working path, many are the diagnostics that *established* what works (see [`../docs/02-docker-on-kernel-4.9.md`](../docs/02-docker-on-kernel-4.9.md)).

> Conventions across the launchers: `DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"`, `BB=/data/docker/bin/busybox`, `--network host` (bridge is dead), `--restart=always`, idempotent (`docker rm -f` then `run`).

### Daemon bring-up
| Script | Role |
|---|---|
| `setup1.sh` | Initial environment prep (remount rw, dirs, static binaries). |
| `gov1.sh`, `gov2.sh`, **`gov3.sh`** | Iterations of the dockerd launcher; **`gov3.sh` is the final working one** (private-mount-ns + cgroup-v1 + overlay2). |
| `tryflags.sh` | Experiments with dockerd flag combinations. |
| `dockerd-svc.sh` | **Entry point of the `/system/etc/init/dockerd.rc` init service** — does setup then `exec`s dockerd inside the private namespace. The reboot-persistence path. |
| `boot-docker.sh` | Boot-time bring-up helper. |

### Verify / smoke tests
| Script | Role |
|---|---|
| `run-hello.sh` | Run a hello-world container (the first proof). |
| `pull-test.sh` | Verify `docker pull` (DNS / resolv.conf working). |
| `diag.sh`, `final-verify.sh` | General + end-state health checks. |
| `persist-diag.sh`, `verify-persist.sh` | Confirm the daemon survives a reboot. |

### Service launchers
| Script | Role |
|---|---|
| `portainer.sh` | Portainer CE (`:9000`). |
| `kuma-netfix.sh`, `kuma-recreate.sh` | Uptime-Kuma (`:3001`) — the netfix adds `NET_RAW` + Android net groups so ICMP monitors work. |
| `c2.sh`, `c2-redeploy.sh` | `shield-c2` dashboard (`:8888`) build + run, and redeploy. |

### Networking investigation (the broken-bridge saga)
`netcheck.sh`, `net-test.sh`, `net-diag.sh`, `net-diag2.sh`, `net-diag3.sh`, `route-diag.sh`, `apply-routes.sh`, `conn-matrix.sh`, `l2-diag.sh`, `brport-test.sh`, `port-test2.sh` — the layered diagnostics that proved bridge/veth networking is dead on this Tegra 4.9 kernel (ARP INCOMPLETE across `docker0`) and that `--network host` is the answer.

### ADB persistence
`adb-persist.sh` (set `persist.adb.tcp.port=5555`), `adb-verify.sh` (confirm it survives without a reboot).

### Power / sleep probes
`cpucheck.sh`, `sleepcheck.sh`, `sleepprobe.sh`, `suspendmech.sh` — probing CPU/suspend behavior of the box as an always-on server.

### Cleanup
`cleanup.sh` — drop failed-build containers + prune dangling images.

> ⚠️ The static Docker binaries themselves (`docker-bringup/docker/`, `bin/busybox`, `data.tar.xz`) are **not committed** (large; `.gitignore`d). Fetch Docker 24.0.9 from `download.docker.com/linux/static/stable/aarch64/docker-24.0.9.tgz`.
