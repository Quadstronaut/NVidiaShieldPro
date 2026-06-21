# NVidiaShieldPro

Always-on home server + remote dev box built on a rooted **NVIDIA SHIELD TV Pro (2015, "foster")** running **LineageOS 22.2 / Android 15** — *without* reflashing the kernel. This repo documents the box, **how it was rooted and re-flashed**, the Docker stack that runs on it, and how it pulls its own updates.

> **Provenance:** every hardware/OS figure below was read **directly from the device over network ADB (`10.0.0.88:5555`) on 2026-06-20** — not copied from a spec sheet. Manufacturer specs that can't be read over ADB are marked **_(spec)_**. Where the device disagrees with the marketing, the device wins and it's called out. Personal identifiers (serial, full MAC, public IPv6) are intentionally redacted; the LAN IP `10.0.0.88` is kept on purpose.

---

## Hardware (verified via ADB @ 10.0.0.88)

### Identity
| Field | Value | Source |
|---|---|---|
| Model | `SHIELD Android TV` (NVIDIA) | `ro.product.model` |
| Device / variant | `foster` / `foster_e_hdd` — the **500 GB HDD Pro** | `ro.product.device`, `ro.product.name` |
| SoC | **NVIDIA Tegra X1 (T210)** — verified: `tegraid=21.1.2.0.0` (chip `0x21` = T210) in the kernel cmdline | `/proc/cmdline`, `ro.board.platform=tegra` |
| Bootloader | `32.00.2019.50-t210-c5cc57a8`, **unlocked** (`androidboot.bllock=0`) | `/proc/cmdline` |
| Secure OS | TLK (Trusted Little Kernel), `androidboot.secureos=tlk` | `/proc/cmdline` |

### CPU — `/proc/cpuinfo` + `sysfs`
- **4 cores online** (`present = 0-3`, `online = 0-3`, cmdline `maxcpus=4`), and **every one is a Cortex-A57** (`CPU part 0xd07`, implementer `0x41` = ARM, ARMv8-A `v8l`).
- ⚠️ **Marketing says "octa-core" (4×A57 + 4×A53). The device exposes only the 4× A57 cluster** — the A53 cluster is not presented to the OS. Verified: nothing past `cpu3`, all cores report part `0xd07`.
- **Max clock: 1.734 GHz** per core (`cpufreq/cpuinfo_max_freq = 1734000` kHz) — not the ~2.0 GHz often quoted.
- Features: `fp asimd aes pmull sha1 sha2 crc32`. ABI `arm64-v8a` (+ `armeabi-v7a`). 4 KB pages.

### GPU
- **Verified renderer** (`dumpsys SurfaceFlinger`): **NVIDIA Corporation / NVIDIA Tegra**, **OpenGL ES 3.2**, driver **NVIDIA 495.00**, **EGL 1.5**. Full `GL_NV_*` extension set present.
- Architecture **_(spec)_**: Maxwell **GM20B**, 256 CUDA cores.

### Memory
- **`MemTotal` = 3,009,644 kB ≈ 2.87 GiB (~3 GB)** (`/proc/meminfo`).
- **`zram0` swap ≈ 882 MiB** (compressed-RAM swap).

### Storage
- Physical disk **`sda` ≈ 465.8 GiB (~500 GB)** — the Pro's drive (`foster_e_hdd`), on the SATA controller (`androidboot.boot_devices=…tegra-sata.0…`). GPT, ~32 partitions.
- Key **ext4** mounts (`df -h`, `/proc/mounts`):
  | Mount | Device | Size | Notes |
  |---|---|---|---|
  | `/data` | `sda32` | **447 GB (≈444 GB free)** | container images + workspaces; `rw,noatime,nobarrier` |
  | `/` | `sda22` | 1.9 GB | system, mounted **ro** |
  | `/vendor` | `sda24` | 758 MB | |
  | `/cache` | `sda23` | 232 MB | |

### Display
- **Physical 3840 × 2160 (4K)**; current render **override 1920 × 1080**; density **320 dpi** (`wm size` / `wm density`).

### Network
- **`eth0` — Gigabit Ethernet, the live link:** MAC `00:04:4b:xx:xx:xx` (NVIDIA OUI; suffix redacted), IPv4 **`10.0.0.88/24`**, plus global + link-local IPv6 (addresses redacted). This is the box's stable address used everywhere below.
- **`wlan0` — present but `DOWN`.** The box runs on wired Ethernet.

### Thermals & load (idle snapshot at capture)
`/sys/class/thermal`: CPU **33 °C** · GPU **31 °C** · PLL 32 °C · board 36 °C · diode 37.75 °C · PMIC 50 °C.
Load average **0.03 / 0.02 / 0.00**, uptime **2 days 11 h** — effectively idle.

---

## Operating system

- **LineageOS 22.2** — `22.2-20260608-NIGHTLY-foster`; **Android 15** (SDK **35**), security patch **2026-06-01**.
- Build `lineage_foster-userdebug 15 BP1A.250505.005`, type **`userdebug`** → `adb root` gives a real root shell on-device (`uid=0`, SELinux `u:r:su:s0`); **no Magisk, no on-device `su`**.
- **This is an *unofficial* build.** foster's official LineageOS support ended years ago (~LOS 18.1 / Android 11), so 22.2 is community/self-built. Evidence: `ro.build.type=userdebug` + `ro.build.tags=release-keys`, built by `ro.build.user=root` on `ro.build.host=ea7fe48de6dd` (a 12-hex Docker container ID — the signature of a containerized ROM build).
- **Kernel `4.9.141`** (`4.9.141-g9d1bd583388e`, SMP PREEMPT, `aarch64`, **Toybox** userland), built 2026-06-08.
- **Vendor base:** stock NVIDIA **Android 11** blobs (`…/foster:11/RQ1A.210105.003`) — Lineage 22.2 (Android 15) runs on top of the Android-11 vendor image.
- **ADB over network is persistent** on `:5555` (`persist.adb.tcp.port=5555`), so the box is reachable at `10.0.0.88:5555` across reboots, hands-off.

The kernel being **4.9** (and the broken Tegra bridge/veth path) is the single biggest constraint shaping the Docker work below.

➡️ Full reconstruction of how it was unlocked, reformatted, and flashed: **[`docs/01-rooting-and-lineageos.md`](docs/01-rooting-and-lineageos.md)**.

---

## What's in this repo

| Path | What |
|---|---|
| [`docs/01-rooting-and-lineageos.md`](docs/01-rooting-and-lineageos.md) | How the device got unlocked + onto LineageOS 22.2 (evidence-based reconstruction). |
| [`docs/02-docker-on-kernel-4.9.md`](docs/02-docker-on-kernel-4.9.md) | The full Docker-on-a-4.9-kernel recipe (the hard part). |
| [`docker-bringup/`](docker-bringup/) | The actual shell scripts used on-device — bring-up, the `dockerd` init service, per-service launchers, and the network diagnostics that mapped the broken-bridge problem. |
| [`shield-c2/`](shield-c2/) | Source of the custom SvelteKit status + control dashboard (`:8888`). |
| [`docs/SPEC-*.md`](docs/), [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md) | Specs for `shield-c2` and the in-design `claude-term`, plus the threat model. |
| [`deploy/`](deploy/) | The pull-deploy mechanism (this repo as source of truth → the Shield pulls itself). |
| [`tools/`](tools/) | Misc host-side tooling (e.g. the app-sideload updater). |

### The stack running on the box
- **Docker 24.0.9** (static arm64) — forced onto **cgroup v1** via a private-mount-namespace trick, **overlay2** on ext4 `/data`, **`--network host`** (the Tegra X1 kernel's bridge/veth path is broken — ARP stays INCOMPLETE across `docker0`). Reboot-persistent via an Android `init` service.
- **Portainer** — `http://10.0.0.88:9000`
- **Uptime-Kuma** — `http://10.0.0.88:3001`
- **`shield-c2`** — `http://10.0.0.88:8888` (live CPU/RAM/disk/net/thermals + container control)
- **`claude-term`** — `http://10.0.0.88:7777` (*in design*: phone-launched Claude Code sessions; see [`docs/SPEC-claude-term.md`](docs/SPEC-claude-term.md))

---

## Deployment / pulling changes

**Flux is the wrong tool here.** Flux CD is a set of **Kubernetes** controllers that reconcile Git-defined manifests into a cluster — it has no concept of a plain Docker host. This box has no Kubernetes (and on kernel 4.9 with cgroup-v1 hacks, broken bridge networking, and 3 GB RAM, standing up k3s/k8s would be a pointless fight for a handful of containers). The right "pull changes" options for a single Docker host:

| Option | What it pulls | Fit |
|---|---|---|
| **Git-pull + re-run changed launchers** (init service) | this repo's `docker-bringup/*.sh` | **Best fit today** — mirrors the existing script-based, build-on-device workflow; fully transparent. Implemented in [`deploy/`](deploy/). |
| **Portainer Git-backed stacks** (poll/webhook) | docker-compose from Git | Strong once services move to compose; you already run Portainer. Stacks must be `network_mode: host`. |
| **Watchtower** | updated container *images* from a registry | Image-pull, not git-pull; only useful if images are built in CI and pushed. |

**Implemented plan:** this repo is the source of truth; the Shield pulls via a small `git pull` + re-run-changed-launchers `init` service (the same pattern that already auto-starts `dockerd`), with Portainer Git stacks as the upgrade path. See [`deploy/README.md`](deploy/README.md).

> _Pull-GitOps live since 2026-06-20 — deploy key + init service installed on the box._
