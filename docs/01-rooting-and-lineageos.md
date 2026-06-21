# Rooting and LineageOS 22.2 on this Shield

The device is a `foster` NVIDIA SHIELD TV Pro with an **unlocked bootloader**, running **LineageOS 22.2 / Android 15** (`userdebug`), rooted via `adb root`. This file states that current state and gives a procedure to reproduce it on a rebuild.

## Current state (read from the device)

- **Bootloader unlocked:** `androidboot.bllock=0` in `/proc/cmdline`.
- **Bootloader build:** `32.00.2019.50-t210-c5cc57a8`; secure OS `tlk` (Trusted Little Kernel); `androidboot.security=enabled`.
- **SoC:** Tegra X1 / T210 — `tegraid=21.1.2.0.0` (chip `0x21`).
- **OS:** `lineage_foster-userdebug`, `22.2-20260608-NIGHTLY-foster`, Android 15 (SDK 35), security patch 2026-06-01, kernel `4.9.141` built 2026-06-08.
- **Build provenance:** `ro.build.type=userdebug`, `ro.build.tags=release-keys`, `ro.build.user=root`, `ro.build.host=ea7fe48de6dd`.
- **Root:** `adb root` returns `uid=0(root) … context=u:r:su:s0`. No Magisk, no on-device `su` binary.

## What the build implies

`ro.build.host=ea7fe48de6dd` is a 12-hex string — the short ID of a Docker build container. Combined with `ro.build.user=root`, `userdebug`, and `release-keys`, this shows the ROM was compiled in a containerized build environment. foster's official LineageOS support ended at roughly LOS 18.1 (Android 11), so a 22.2 / Android 15 build for foster is an unofficial, self-built or community build.

The `userdebug` build sets `ro.debuggable=1`, which lets `adbd` restart as root (`adb root`). That is the root model on this device: there is no Magisk and no `su` binary. The Docker stack depends on this.

> **Do not OTA to an official `user` build.** A `user` build sets `ro.debuggable=0` and kills `adb root`, which breaks the whole stack. Stay on the `userdebug` build.

## Reproduce the current state

`foster` is a non-A/B device (empty `slot_suffix`) with a dedicated recovery partition. Given an unlocked bootloader, the path to this state is:

1. **Unlock the bootloader** (one-time): on stock, enable Developer options → OEM unlocking, then `fastboot oem unlock`. **This wipes userdata.**
2. **Flash the LineageOS recovery:**
   ```
   fastboot flash recovery recovery-22.2-foster.img
   ```
   (`recovery-22.2-foster.img` is the LineageOS recovery for foster. Not committed here — large binary; keep it with your build set.)
3. **Boot to recovery → factory reset / format data, then sideload the ROM:**
   ```
   adb sideload lineage-22.2-foster.zip
   ```
   (the unofficial userdebug build; also not committed.)
4. **First boot → enable network ADB persistently** (so the box is hands-off at `10.0.0.88:5555` across reboots):
   ```
   setprop persist.adb.tcp.port 5555
   ```
   See [`../docker-bringup/adb-persist.sh`](../docker-bringup/adb-persist.sh) and [`adb-verify.sh`](../docker-bringup/adb-verify.sh).
5. **Root** needs nothing further: `adb root` returns a root shell because the build is `userdebug`.

## Flash artifacts (versions + hashes)

The flashing blobs are **not committed** (large; `.gitignore`d). The exact artifacts that produce this state are below. Verify any download with `sha256sum` / `Get-FileHash -Algorithm SHA256` before flashing.

| File | Identity | Size | SHA-256 |
|---|---|---|---|
| `lineage-22.2-foster.zip` | unofficial LineageOS **22.2** userdebug for foster (running build reports `22.2-20260608-NIGHTLY-foster`) | 803,654,832 B (~766 MiB) | `2E8568071432407CE20B6B365F2483F46DBD4DC4A49E1EE96D059FF5D9448848` |
| `recovery-22.2-foster.img` | LineageOS **22.2** recovery for foster | 21,913,600 B (~20.9 MiB) | `937F5C503DAFD26BD2421C19C5F44F0D609B590408048E195E03B78CA3470364` |

The zip's name is the release line (`22.2`); the running OS is the `20260608` nightly within it. Keep these with your build set; they are not redistributed here.
