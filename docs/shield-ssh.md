# Bidirectional passwordless SSH: Shield ⇄ DEVIL

Key-only SSH both ways between the Shield (`10.0.0.88`) and DEVIL/Archangel
(`10.0.0.73`). Set up 2026-06-22.

Reboot-durable: verified across two power cycles — dropbear, dockerd, and all
containers come back with no manual intervention.

## Quick use
- **DEVIL → Shield:** `ssh shield`  (alias in `~/.ssh/config` → `root@10.0.0.88`)
- **Shield → DEVIL:** `ssh -F /data/ssh/config devil`  (or `archangel`)

## Test it
```powershell
ssh shield "id; getprop ro.product.model"          # -> uid=0(root) ... SHIELD Android TV
adb -s 10.0.0.88:5555 shell /product/bin/ssh -F /data/ssh/config devil hostname   # -> Devil
```
After a reboot, give it ~20s, then `ssh shield` again.

## DEVIL → Shield (the hard direction)
The Shield's stock `/product/bin/sshd` (OpenSSH 9.0p1 / BoringSSL) **cannot load a
host key** on this ROM — `sshkey_shield_private` fails with
`accumulate_host_timing_secret: ssh_digest_start` (RC 255, never listens). The
OpenSSH *client* works fine, which is why Shield → DEVIL needs nothing special.

Fix: a **statically-linked musl `dropbear`** built from official source
(`DROPBEAR_2022.83`) with two minimal Android patches:
1. `common-session.c` `fill_passwd()` — bionic has no `/etc/passwd`, so synthesize
   a root entry (home `/data/ssh`, shell `/system/bin/sh`).
2. `svr-auth.c` — skip the `/etc/shells` validation (absent on Android).

Pubkey-only (password auth + syslog compiled out → no `-s`/`-E` flags).

| Thing | Path |
|---|---|
| daemon binary | `/data/ssh/dropbearmulti` (static, ~500 KB) |
| host key | `/data/ssh/dropbear_ed25519_host_key` |
| authorized_keys | `/data/ssh/.ssh/authorized_keys` (DEVIL's pubkey) |
| launcher | `/data/docker/dropbear.sh` → `dropbear -p 22 -r <hk> -P <pid>` |
| autostart | hooked into `/data/docker/dockerd-svc.sh` (init `dockerd` svc, `sys.boot_completed`) |

Rebuild from `docker-bringup/dropbear-build.sh` (run+commit musl build in a
debian container; `docker build` has no network on this kernel).

## Shield → DEVIL
Windows **OpenSSH Server** on DEVIL (installed + autostart + firewall :22). DEVIL's
account is an admin, so the Shield's pubkey lives in
`C:\ProgramData\ssh\administrators_authorized_keys` (NOT `~/.ssh`), ACL locked to
SYSTEM + Administrators. Shield identity key: `/data/ssh/id_ed25519`.

## Boot order + the dockerd.pid gotcha
At `sys.boot_completed`, init runs the `dockerd` service → `dockerd-svc.sh`, which
starts dropbear (independent of docker) and then `exec`s into dockerd.

`dockerd.pid` lives in `/data` and survives reboot. If its old PID gets reused by
another process after boot, dockerd refuses to start
(`process with PID N is still running`) and init **crash-loops the service every
5s** — containers never come up, and dropbear flaps with each cycle. `dockerd-svc.sh`
now clears `dockerd.pid` (not just `docker.sock`) before launching dockerd, which
makes boot deterministic. If you ever see the loop, the manual unstick is:
`adb shell rm -f /data/docker/dockerd.pid` (the next 5s cycle then starts clean).

## Troubleshooting
- **`ssh shield` refused after reboot:** wait ~20s; if still down,
  `adb shell sh /data/docker/dropbear.sh` restarts dropbear.
- **Host-key changed warning:** the dropbear host key persists, so this only
  happens if `/data/ssh` was wiped — `ssh-keygen -R 10.0.0.88` then reconnect.
- **Containers missing after boot:** check `adb shell tail /data/docker/boot.log`
  for the dockerd.pid crash-loop above.
