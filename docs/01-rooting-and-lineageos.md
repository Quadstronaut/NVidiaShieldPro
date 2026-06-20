# How this Shield was unlocked, reformatted, and put on LineageOS 22.2

This is a **reconstruction**, not a transcript. The original bootloader unlock was done by the owner long ago from now-forgotten instructions; the *current* LineageOS 22.2 install was done in a later automated session. No step-by-step log survives, so everything below is rebuilt from what the device still reports plus the artifacts on hand — and tagged with how sure we are:

| Tag | Meaning |
|---|---|
| ✅ **Verified** | Read directly from the device over ADB on 2026-06-20. |
| 🟡 **Inferred** | Strong circumstantial evidence; reconstructed, not observed. |
| ⚪ **Generic** | The standard `foster` procedure — consistent with the evidence, but not a record of the exact commands originally typed. |

---

## What the device still proves (evidence)

- ✅ **Bootloader is unlocked:** `androidboot.bllock=0` in `/proc/cmdline`.
- ✅ **Bootloader build:** `32.00.2019.50-t210-c5cc57a8`; secure OS `tlk` (Trusted Little Kernel); `androidboot.security=enabled`.
- ✅ **SoC:** Tegra X1 / T210 — `tegraid=21.1.2.0.0` (chip `0x21`).
- ✅ **OS:** `lineage_foster-userdebug`, `22.2-20260608-NIGHTLY-foster`, Android 15 (SDK 35), security patch 2026-06-01, kernel `4.9.141` built 2026-06-08.
- ✅ **Build provenance:** `ro.build.type=userdebug`, `ro.build.tags=release-keys`, `ro.build.user=root`, `ro.build.host=ea7fe48de6dd`.
- ✅ **Root works:** `adb root` → `uid=0(root) … context=u:r:su:s0`. No Magisk, no on-device `su` binary.
- 🟡 **Reformat date:** the oldest stable directory under `/data` (`/data/misc`) has mtime **2026-05-24**; this is the best available proxy for when `/data` was last wiped/first-booted.

### What the provenance means
`ro.build.host=ea7fe48de6dd` is a 12-hex-character string — the classic short ID of a **Docker build container**. Combined with `ro.build.user=root` and `userdebug`+`release-keys`, this says the ROM was compiled in a containerized build environment. foster's **official** LineageOS support ended at roughly **LOS 18.1 (Android 11)** years ago, so a **22.2 / Android 15** build for foster is necessarily **unofficial** — either self-built or pulled from a community maintainer. 🟡

This also explains the root model: a **userdebug** build sets `ro.debuggable=1`, which lets `adbd` restart as root (`adb root`). That *is* the root — there's no Magisk and no `su` on the device. Everything in the Docker recipe depends on this.

> ⚠️ **Do not OTA to an official `user` build** — it would set `ro.debuggable=0` and kill `adb root`, breaking the whole stack. Stay on the userdebug build.

---

## Reconstructed timeline

| When | Event | Confidence |
|---|---|---|
| (years ago) | Owner unlocks the bootloader from "ancient instructions"; some earlier ROM is installed. | ⚪ |
| ~2026-05-24 | `/data` last established — i.e. the clean reflash to LineageOS 22.x. | 🟡 |
| 2026-06-08 | The running ROM (`22.2-20260608` nightly) was built; flashed fresh or OTA'd to. | ✅ build date |
| 2026-06-18 | Docker bring-up (`/data/docker` created; see [`02-docker-on-kernel-4.9.md`](02-docker-on-kernel-4.9.md)). | ✅ |
| 2026-06-20 | This documentation pass. | ✅ |

---

## How to reproduce the current state (the faithful procedure)

`foster` is a **non-A/B** device (empty `slot_suffix`) with a dedicated recovery partition. Given an already-unlocked bootloader, the path to *this* state is:

1. ⚪ **Unlock the bootloader** (one-time, already done): on stock, enable Developer options → **OEM unlocking**, then `fastboot oem unlock`. **This wipes userdata.** *(The owner's original commands aren't recorded; this is the standard foster unlock.)*
2. 🟡 **Flash the LineageOS recovery:**
   ```
   fastboot flash recovery recovery-22.2-foster.img
   ```
   *(`recovery-22.2-foster.img` is the LineageOS recovery for foster. It is NOT committed here — it's a large binary; keep it with your build.)*
3. 🟡 **Boot to recovery → factory reset / format data** (the "reformat"), then sideload the ROM:
   ```
   adb sideload lineage-22.2-foster.zip
   ```
   *(the unofficial userdebug build; also not committed — large blob.)*
4. ✅ **First boot → enable network ADB persistently** (so the box is hands-off at `10.0.0.88:5555` across reboots):
   ```
   setprop persist.adb.tcp.port 5555
   ```
   See [`../docker-bringup/adb-persist.sh`](../docker-bringup/adb-persist.sh) / [`adb-verify.sh`](../docker-bringup/adb-verify.sh).
5. ✅ **Root** needs nothing further: `adb root` returns a root shell because the build is `userdebug`.

> **Honesty box:** Steps 2–3 are the reconstruction. They match every fact the device still reports and the artifacts kept alongside the build, but they are *how to recreate the current state*, not a log of what was originally typed. Step 1's exact original commands, and which intermediate ROMs preceded the current one, are not recorded.

---

## Artifacts used (what to obtain — exact versions + hashes)

The flashing blobs are **not committed** (large; `.gitignore`d), but here is exactly what was used so the record is complete and reproducible. Verify any download with `sha256sum` / `Get-FileHash -Algorithm SHA256` before flashing.

| File | Identity | Size | SHA-256 |
|---|---|---|---|
| `lineage-22.2-foster.zip` | unofficial LineageOS **22.2** userdebug for foster (running build reports `22.2-20260608-NIGHTLY-foster`) | 803,654,832 B (~766 MiB) | `2E8568071432407CE20B6B365F2483F46DBD4DC4A49E1EE96D059FF5D9448848` |
| `recovery-22.2-foster.img` | LineageOS **22.2** recovery for foster | 21,913,600 B (~20.9 MiB) | `937F5C503DAFD26BD2421C19C5F44F0D609B590408048E195E03B78CA3470364` |

> The zip's name is the release line (`22.2`); the *running* OS is the `20260608` nightly within it — the box may have been OTA'd to a later nightly after the initial flash (see timeline). Keep these with your build set; they are not redistributed here.
