# `deploy/` — pull-based GitOps for a single Docker host

This repo is the source of truth; the Shield pulls itself and re-runs the changed launchers. This is the right shape for *this* box — **Flux/k8s GitOps does not apply** (no Kubernetes here; see the root README's Deployment section).

> **Status: DESIGNED, NOT YET DEPLOYED.** The scripts below are written but have **not** been installed or run on the device yet. Install + verify on-device before relying on them.

## How it works

```
init service (shield-deploy.rc, on boot)
   └─ pull-and-deploy.sh          # orchestrator (host shell)
        ├─ wait for dockerd socket
        ├─ git-sync.sh            # `git pull` inside an alpine/git CONTAINER → /data/NVidiaShieldPro
        └─ redeploy.sh            # if HEAD moved, re-run the idempotent launchers
```

- **Why git runs in a container:** the Android/Toybox userland has **no `git`**. Docker is the only thing on the box with network + git, so the pull borrows a throwaway `alpine/git` container with `/data` bind-mounted and `--network host`.
- **Change detection without host git:** `git-sync.sh` prints the current `HEAD`; `pull-and-deploy.sh` compares it to `deploy/.last-deployed` and only redeploys when it moves.
- **Launchers are idempotent** (`docker rm -f` + `run`), so redeploy just bounces each container onto the new image/config. The active set is the `ACTIVE` list in `redeploy.sh`.

## Bootstrap (one-time, by hand)

1. **Secrets** — this repo is private, so create `deploy/deploy.env` (gitignored) on the device checkout:
   ```sh
   GH_TOKEN=github_pat_xxxxxxxx            # a fine-grained PAT with read access to this repo
   REPO_URL=https://github.com/Quadstronaut/NVidiaShieldPro.git
   ```
2. **First clone** (chicken-and-egg: the init service references files inside the repo, so clone it first):
   ```sh
   adb -s 10.0.0.88:5555 push deploy/git-sync.sh deploy/deploy.env /data/_bootstrap/
   adb -s 10.0.0.88:5555 shell 'sh /data/_bootstrap/git-sync.sh'   # clones to /data/NVidiaShieldPro
   ```
3. **Install the init service:**
   ```sh
   adb -s 10.0.0.88:5555 root
   adb -s 10.0.0.88:5555 shell 'mount -o remount,rw /'             # /system is ro by default
   adb -s 10.0.0.88:5555 push deploy/shield-deploy.rc /system/etc/init/shield-deploy.rc
   adb -s 10.0.0.88:5555 shell 'setprop ctl.start shield_deploy'   # test it now, no reboot
   adb -s 10.0.0.88:5555 shell 'cat /data/docker/deploy.log'       # verify
   ```

## Triggers
- **On boot:** automatic (`on property:sys.boot_completed=1`).
- **Manual / on-demand:** `adb shell setprop ctl.start shield_deploy`.
- **Periodic polling:** init has no cron. If you want it, wrap `pull-and-deploy.sh` in a `while true; do …; sleep 900; done` loop and make the service non-`oneshot` — or push from CI via the manual trigger.

## Revert
Delete `/system/etc/init/shield-deploy.rc` (after `mount -o remount,rw /`). The checkout at `/data/NVidiaShieldPro` and the containers are untouched.

## Verify before trusting it (on-device checklist)
- [ ] `alpine/git` pulls and clones to `/data/NVidiaShieldPro`.
- [ ] `pull-and-deploy.sh` waits for dockerd, then logs `no change` on a second run.
- [ ] A pushed commit that edits a launcher triggers a redeploy and bounces only via the idempotent launcher.
- [ ] Survives a real reboot (service fires after dockerd; socket-wait works).
- [ ] `deploy.env` / the token never appear in `git status` (gitignored).
