# Real Docker on a kernel-4.9 Shield (no reflash)

Native Docker runs on this Shield (foster, LineageOS 22.x userdebug, Android 15, **kernel 4.9.141 aarch64**) over network ADB — **no reflash, no custom kernel**. Proven 2026-06-18 (a busybox container printed hello and exited 0; later overlay2 + DNS + a real `docker pull` + a persistent stack). The launchers live in [`../docker-bringup/`](../docker-bringup/); `gov3.sh` is the final working bring-up.

> Access model: device at `10.0.0.88`, ADB on `:5555`, root via `adb root` (userdebug; no on-device `su`/Magisk). `/data` is ext4, ~444 GB free, **not `noexec`** — so binaries run straight from `/data`.

---

## The five Android-isms that each break stock Docker — and the fixes

Android is not a Linux userland, so five separate things break Docker. Each fix:

1. **No Linux userland** → use **static arm64 Docker binaries** (`download.docker.com/linux/static/stable/aarch64/docker-24.0.9.tgz`). They exec directly on Android's kernel. Pinned **24.0.9** (not 29.x) for solid **cgroup-v1** support on an old kernel.
2. **Read-only rootfs** (dockerd wants `/run/docker`, `/opt`) → `mount -o remount,rw /`, then `mkdir /run /opt` (ramdisk, non-persistent — dm-verity is off on userdebug).
3. **SELinux enforcing** → `setenforce 0` (the boot script sets **permissive** every boot).
4. **Kernel 4.9 + cgroup v2 is fatal.** runc's device control needs `bpf_prog_query(BPF_CGROUP_DEVICE)`, which is **kernel ≥ 4.15**. Android mounts `/sys/fs/cgroup` as cgroup2, so dockerd auto-picks v2 and dies. **Fix:** launch dockerd inside `busybox unshare -m` (private mount namespace), `umount -l /sys/fs/cgroup`, mount a tmpfs over it, then mount **cgroup v1** controllers (`devices freezer memory cpu cpuacct blkio` — **skip `pids`**, it fails; **skip `cpuset`**, Android mounts it `noprefix` which breaks libcontainer). dockerd then reports `Cgroup Version: 1` and device control is file-based. Android's real cgroups stay untouched in the root namespace.
5. **This busybox has no `pkill`/`pgrep`.** `pkill -f dockerd` is a silent no-op, so a stale root-namespace dockerd survives and hogs the socket (symptom: your v1 daemon is up but `docker info` still says v2 — you're talking to the zombie). **Kill via** `ps -ef | grep dockerd | awk '{print $1}' | xargs kill -9`.

**Daemon flags (final):** `--storage-driver overlay2 --iptables=false --bridge=none`.

---

## Storage: overlay2 + DNS for `docker pull`

- **overlay2** works: the kernel has `CONFIG_OVERLAY_FS`, `/data` is ext4 → `Backing Filesystem: extfs`, copy-on-write + shared layers. (Started on `vfs` for bulletproofing, switched to overlay2.)
- **DNS:** the static dockerd uses Go's resolver → needs `/etc/resolv.conf`, which Android lacks. `/etc` → `/system/etc` (persistent on `sda22`). Pushed `/system/etc/resolv.conf` = `nameserver 10.0.0.1 / 8.8.8.8 / 1.1.1.1`.
  - ⚠️ **Push the file via `adb push`** — do *not* `printf` it through `adb shell`; the quoting eats the spaces and you get a file containing just "nameserver". With resolv.conf present, `docker pull` works (verified fresh after deleting the cached image and cold-rebooting).

---

## Reboot persistence (works, no Magisk)

`/` is a real ext4 partition (`/dev/block/sda22`), **no dm-verity**, so `/system/etc/init/` is writable **and** persistent. Installed `/system/etc/init/dockerd.rc` — an init service named `dockerd` (`seclabel u:r:su:s0`, `disabled`, started `on property:sys.boot_completed=1`) that runs [`../docker-bringup/dockerd-svc.sh`](../docker-bringup/dockerd-svc.sh). Logs to `/data/docker/boot.log`. Revert = delete the `.rc`.

Two non-obvious gotchas (each cost a reboot):
- **The service must be non-`oneshot` and must `exec` dockerd as its main PID.** `dockerd-svc.sh` does setup then `exec unshare -m sh nsstart.sh`, and `nsstart` `exec`s dockerd. A `oneshot` service that backgrounds dockerd (`&`) and exits gets its children **killed by init** seconds after boot. Non-oneshot = init supervises and auto-restarts dockerd.
- **Android remounts `/` read-only after boot**, and `make-rprivate` doesn't fully stop it leaking into the daemon's mount namespace → the runc shim can't write its socket under `/run` (`bind: read-only file system`). **Fix:** `mount -t tmpfs tmpfs /run` (+ `/opt`) *inside the private namespace*.

Reload after editing `dockerd-svc.sh` without rebooting: `setprop ctl.restart dockerd`. (`adb push` to `/system` needs `mount -o remount,rw /` **first** or it silently fails on read-only `/system`.)

---

## Networking: `--network host` works, bridge is dead

- ✅ **`--network host` FULLY WORKS** — containers get internet (ping + HTTP verified) and can **serve** on ports reachable from the Shield's LAN IP (busybox httpd on `:8088` reachable at `10.0.0.88:8088` from other LAN hosts). **This is the practical mode for everything.**
- ❌ **Bridge networking (`-p`, isolated nets) does NOT work — a kernel-level bug.** The kernel has all the config (`MASQUERADE`, nat/filter/conntrack/addrtype all `=y`) and `iptables v1.8.10` works; enabling iptables+bridge correctly creates `docker0`, the MASQUERADE rule, and the DOCKER FORWARD chains. After also fixing Android's policy routing, `ip route get` resolves — **but containers still can't reach even their gateway: ARP stays INCOMPLETE both directions across `docker0`** despite `brport` forwarding, STP off, `rp_filter=0`, no `br_netfilter`. Frames don't traverse the docker0 bridge/veth on this Tegra 4.9 kernel. Fixing it = kernel patch + reflash (not worth it). The `net-*`, `route-*`, `l2-diag`, `brport-test`, `conn-matrix` scripts in `docker-bringup/` are the investigation that established this.
- Untried alternative: the **macvlan** driver (bypasses the Linux bridge, gives containers LAN IPs) — needs `CONFIG_MACVLAN`, untested.

**Consequence:** every container below runs `--network host`. `-p` port publishing will not route on this kernel.

---

## ADB-over-network persistence

Root cause of the toggle resetting every boot: only the non-persistent `service.adb.tcp.port` was being set (wiped each boot); `persist.adb.tcp.port` was empty. **Fix:** `setprop persist.adb.tcp.port 5555` (written to `/data/property/persistent_properties`, survives reboot). After any reboot, `adbd` auto-listens on `10.0.0.88:5555` and the `dockerd` init service auto-starts — fully hands-off. See [`../docker-bringup/adb-persist.sh`](../docker-bringup/adb-persist.sh).

---

## The stack (all `--network host`, all `--restart=always`)

| Service | Image | URL | Notes |
|---|---|---|---|
| **Portainer** | `portainer/portainer-ce:lts` (2.39.3 arm64) | `:9000` (9443 HTTPS, 8000 edge) | `-v /data/docker/docker.sock:/var/run/docker.sock` (our socket is non-standard) + `-v /data/docker/portainer:/data`. First-run admin has a ~5-min timeout — set it promptly. Containers it launches must use host networking. [`portainer.sh`](../docker-bringup/portainer.sh) |
| **Uptime-Kuma** | `louislam/uptime-kuma:2.4.0-slim` | `:3001` | `-v /data/docker/uptime-kuma:/app/data`. **ICMP ping monitors need** `--cap-add NET_RAW --group-add 3003 --group-add 3004` (Android paranoid networking gates raw sockets on AID_INET/AID_NET_RAW even as root) — see [`kuma-netfix.sh`](../docker-bringup/kuma-netfix.sh). TCP/HTTP monitors work without it. |
| **shield-c2** | custom SvelteKit (adapter-node), 213 MB | `:8888` | Live CPU/RAM/disk/net/thermal + container start/stop/restart/logs behind a server-side allowlist. Source in [`../shield-c2/`](../shield-c2/), launcher [`c2.sh`](../docker-bringup/c2.sh). |

**On-device build gotchas** (baked into the launchers): classic builder only — **`DOCKER_BUILDKIT=0`** (static docker has no buildx) **and `--network=host`** on `docker build` (else RUN steps get no DNS → `EAI_AGAIN registry.npmjs.org`). For arm64 base images, **pin the real arm64 manifest digest** (resolve on a PC via `docker buildx imagetools inspect`; a guessed/index digest fails).

---

## Script map

See [`../docker-bringup/README.md`](../docker-bringup/README.md) for what each script does. Everything is driven live with `setprop ctl.restart dockerd` (re-runs `dockerd-svc.sh`) — no reboot needed.
