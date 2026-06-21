# `deploy/` — pull-based GitOps for a single Docker host

This repo is the source of truth; the Shield pulls itself and re-runs the changed launchers. This is the right shape for *this* box — **Flux/k8s GitOps does not apply** (no Kubernetes here; see the root README's Deployment section).

> **Status: LIVE — installed + reboot-verified 2026-06-20.** The read-only deploy key, the clone at `/data/NVidiaShieldPro`, and the `shield-deploy` init service are all on the box. A real reboot confirmed `init.svc.shield_deploy` runs on boot (after `dockerd`). The bootstrap steps below are kept as the reference for a rebuild.

## How it works

```
init service (shield-deploy.rc, on boot)
   └─ pull-and-deploy.sh          # orchestrator (host shell)
        ├─ wait for dockerd socket
        ├─ git-sync.sh            # `git pull` inside an alpine/git CONTAINER → /data/NVidiaShieldPro
        └─ redeploy.sh            # if HEAD moved, re-run the idempotent launchers
```

- **Why git runs in a container:** the Android/Toybox userland has **no `git`**. Docker is the only thing on the box with network + git, so the pull borrows a throwaway `alpine/git` container with `/data` bind-mounted and `--network host`.
- **Auth = a read-only SSH deploy key** (not a PAT). GitHub has no API to mint a PAT, but a deploy key *can* be created via the API, is scoped to **this one repo**, is **read-only**, and is revocable on its own. The key lives at `/data/.ssh/` (outside the repo, so the first clone can bootstrap). A leaked key exposes nothing but read access to this repo.
- **Change detection without host git:** `git-sync.sh` prints the current `HEAD`; `pull-and-deploy.sh` compares it to `deploy/.last-deployed` and only redeploys when it moves.
- **Launchers are idempotent + re-run-safe** (`docker rm -f` *before* any port-free assert, then `run`), so redeploy just bounces each container onto the new image/config. The active set is the `ACTIVE` list in `redeploy.sh`. (`c2.sh` originally asserted the port free *before* removing the old container, so re-running it while c2 was up FATAL'd on "port 8888 in use" — fixed to rm-first.)

## Credentials (read-only deploy key)

The key pair is created on a workstation; the **public** half is registered on the repo as a read-only deploy key (`gh api -X POST repos/<owner>/NVidiaShieldPro/keys -f title=… -f key=… -F read_only=true`), and the **private** half is placed on the Shield at `/data/.ssh/shield_deploy_ed25519` (mode `600`), alongside `/data/.ssh/known_hosts` (GitHub's host keys, from `ssh-keyscan github.com`). Revoke any time by deleting the deploy key in the repo's *Settings → Deploy keys* (or `gh api -X DELETE repos/<owner>/NVidiaShieldPro/keys/<id>`).

## Bootstrap (one-time)

1. **Put the key on the Shield** (done during initial setup):
   ```sh
   adb -s 10.0.0.88:5555 shell 'mkdir -p /data/.ssh'
   adb -s 10.0.0.88:5555 push shield_deploy_ed25519 known_hosts /data/.ssh/
   adb -s 10.0.0.88:5555 shell 'chmod 700 /data/.ssh; chmod 600 /data/.ssh/*'
   ```
2. **First clone** (the init service references files *inside* the repo, so clone first). Push a copy of `git-sync.sh` and run it:
   ```sh
   adb -s 10.0.0.88:5555 shell 'mkdir -p /data/_bootstrap'
   adb -s 10.0.0.88:5555 push deploy/git-sync.sh /data/_bootstrap/
   adb -s 10.0.0.88:5555 shell 'sh /data/_bootstrap/git-sync.sh'   # clones to /data/NVidiaShieldPro
   ```
3. **Install the init service:**
   ```sh
   adb -s 10.0.0.88:5555 root
   adb -s 10.0.0.88:5555 shell 'mount -o remount,rw /'              # /system is ro by default
   adb -s 10.0.0.88:5555 push deploy/shield-deploy.rc /system/etc/init/shield-deploy.rc
   adb -s 10.0.0.88:5555 shell 'setprop ctl.start shield_deploy'   # test now, no reboot
   adb -s 10.0.0.88:5555 shell 'cat /data/docker/deploy.log'       # verify
   ```

## Triggers
- **On boot:** automatic (`on property:sys.boot_completed=1`).
- **Manual / on-demand:** `adb shell setprop ctl.start shield_deploy`.
- **Periodic polling:** init has no cron. If you want it, wrap `pull-and-deploy.sh` in a `while true; do …; sleep 900; done` loop and make the service non-`oneshot` — or push from CI via the manual trigger.

## Revert
Delete `/system/etc/init/shield-deploy.rc` (after `mount -o remount,rw /`). The checkout at `/data/NVidiaShieldPro` and the containers are untouched. Revoke the deploy key separately if desired.

## Verified on-device (2026-06-20)
- [x] `alpine/git` pulled + cloned to `/data/NVidiaShieldPro` over SSH with the read-only deploy key.
- [x] `pull-and-deploy.sh` waits for dockerd, then logs `no change` on an unchanged second run.
- [x] A pushed commit triggered a redeploy — all three launchers re-ran, containers bounced.
- [x] Survived a real reboot: `init.svc.shield_deploy=stopped` (oneshot ran on boot), `init.svc.dockerd=running`, boot run logged a clean pull.
- [x] Private key is mode `600` at `/data/.ssh/` (outside the repo); never appears in `git status`.
