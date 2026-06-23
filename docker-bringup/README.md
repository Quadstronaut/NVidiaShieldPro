# `docker-bringup/` — the on-device scripts

The shell scripts that bring Docker up on this Shield and that investigate the kernel-4.9 networking. They run on the device (Toybox `/system/bin/sh`), driven over ADB. See [`../docs/02-docker-on-kernel-4.9.md`](../docs/02-docker-on-kernel-4.9.md) for the configuration they implement.

Conventions across the launchers:
- `DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"`, `BB=/data/docker/bin/busybox`
- `--network host` (the kernel bridge is broken on this Tegra 4.9 kernel — ARP stays INCOMPLETE across `docker0`)
- `--restart=always`
- idempotent: `docker rm -f` before any port-free assert, then `run`

### Daemon bring-up
| Script | Role |
|---|---|
| `setup1.sh` | Environment prep (remount rw, dirs, static binaries). |
| `gov1.sh`, `gov2.sh`, `gov3.sh` | `gov3.sh` is the dockerd launcher (private-mount-ns + cgroup-v1 + overlay2). |
| `tryflags.sh` | dockerd flag-combination probe. |
| `dockerd-svc.sh` | Entry point of the `/system/etc/init/dockerd.rc` init service — runs setup then `exec`s dockerd inside the private namespace. The reboot-persistence path. |
| `boot-docker.sh` | Boot-time bring-up helper. |

### Verify / smoke tests
| Script | Role |
|---|---|
| `run-hello.sh` | Run a hello-world container. |
| `pull-test.sh` | Verify `docker pull` (DNS / resolv.conf working). |
| `diag.sh`, `final-verify.sh` | General and end-state health checks. |
| `persist-diag.sh`, `verify-persist.sh` | Confirm the daemon survives a reboot. |

### Service launchers
| Script | Role |
|---|---|
| `kuma-netfix.sh`, `kuma-recreate.sh` | Uptime-Kuma (`:3001`); the netfix adds `NET_RAW` + Android net groups so ICMP monitors work. |
| `c2.sh`, `c2-redeploy.sh` | `shield-c2` dashboard (`:8888`) build + run, and redeploy. |
| `claude-term.sh`, `claude-term-build.sh` | `claude-term` web terminal (`:7777`) — phone-driven Claude Code in tmux. Whole-`/home/claude` volume for persistent Claude state + an idempotent first-run seed; reads `CLAUDE_TERM_SECRET` + `CLAUDE_CODE_OAUTH_TOKEN` from an untracked `claude-term.env`. Built run+commit (`docker build` has no host net here). See [`../docs/claude-term-bringup-notes.md`](../docs/claude-term-bringup-notes.md). |

### Networking investigation
`netcheck.sh`, `net-test.sh`, `net-diag.sh`, `net-diag2.sh`, `net-diag3.sh`, `route-diag.sh`, `apply-routes.sh`, `conn-matrix.sh`, `l2-diag.sh`, `brport-test.sh`, `port-test2.sh` — the layered diagnostics that established that bridge/veth networking is dead on this Tegra 4.9 kernel (ARP INCOMPLETE across `docker0`) and that `--network host` is the working mode.

### ADB persistence
`adb-persist.sh` sets `persist.adb.tcp.port=5555`; `adb-verify.sh` confirms it survives without a reboot.

### Power / sleep probes
`cpucheck.sh`, `sleepcheck.sh`, `sleepprobe.sh`, `suspendmech.sh` — probe CPU and suspend behavior of the box as an always-on server.

### Cleanup
`cleanup.sh` — drop failed-build containers and prune dangling images.

> The static Docker binaries themselves (`docker-bringup/docker/`, `bin/busybox`, `data.tar.xz`) are **not committed** (large; `.gitignore`d). Fetch Docker 24.0.9 from `download.docker.com/linux/static/stable/aarch64/docker-24.0.9.tgz`.
