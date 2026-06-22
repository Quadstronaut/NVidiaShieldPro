# `deploy/` — pull-based deploy for the Shield Docker host

This repo is the source of truth; the Shield pulls itself and re-runs the changed launchers. The read-only deploy key, the clone at `/data/NVidiaShieldPro`, and the `shield-deploy` Android `init` service are installed on the box, and the service runs on boot.

## How it works

```
init service (shield-deploy.rc, on boot)
   └─ pull-and-deploy.sh          # orchestrator (host shell)
        ├─ wait for dockerd socket
        ├─ git-sync.sh            # `git pull` inside an alpine/git container → /data/NVidiaShieldPro
        └─ redeploy.sh            # if HEAD moved, re-run the idempotent launchers
```

- **Git runs in a container** because the Android/Toybox userland has no `git` binary. Docker is the only thing on the box with network and git, so the pull borrows a throwaway `alpine/git` container with `/data` bind-mounted and `--network host`.
- **Auth is a read-only SSH deploy key** (not a PAT). The deploy key is created via the GitHub API, scoped to this one repo, read-only, and individually revocable. The key lives at `/data/.ssh/` (outside the repo, so the first clone can bootstrap). A leaked key exposes nothing but read access to this repo.
- **Change detection without host git:** `git-sync.sh` prints the current `HEAD`; `pull-and-deploy.sh` compares it to `deploy/.last-deployed` and only redeploys when it moves. On an unchanged `HEAD` the run logs `no change` and does nothing.
- **Launchers are idempotent and re-run-safe** (`docker rm -f` before any port-free assert, then `run`), so a redeploy bounces each container onto the new image/config. The active set is the `ACTIVE` list in `redeploy.sh`.

## Credentials (read-only deploy key)

The key pair is created on a workstation; the **public** half is registered on the repo as a read-only deploy key (`gh api -X POST repos/<owner>/NVidiaShieldPro/keys -f title=… -f key=… -F read_only=true`), and the **private** half is placed on the Shield at `/data/.ssh/shield_deploy_ed25519` (mode `600`), alongside `/data/.ssh/known_hosts` (GitHub's host keys, from `ssh-keyscan github.com`). Revoke by deleting the deploy key in the repo's *Settings → Deploy keys* (or `gh api -X DELETE repos/<owner>/NVidiaShieldPro/keys/<id>`).

## Bootstrap (one-time, to reproduce the installed state)

1. **Put the key on the Shield:**
   ```sh
   adb -s 10.0.0.88:5555 shell 'mkdir -p /data/.ssh'
   adb -s 10.0.0.88:5555 push shield_deploy_ed25519 known_hosts /data/.ssh/
   adb -s 10.0.0.88:5555 shell 'chmod 700 /data/.ssh; chmod 600 /data/.ssh/*'
   ```
2. **First clone** (the init service references files inside the repo, so clone first). Push a copy of `git-sync.sh` and run it:
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
   adb -s 10.0.0.88:5555 shell 'setprop ctl.start shield_deploy'   # run now, no reboot
   adb -s 10.0.0.88:5555 shell 'cat /data/docker/deploy.log'       # check the result
   ```

## Triggers
- **On boot:** automatic (`on property:sys.boot_completed=1`).
- **Manual / on-demand:** `adb shell setprop ctl.start shield_deploy`.
- **Periodic polling:** init has no cron. To poll, wrap `pull-and-deploy.sh` in a `while true; do …; sleep 900; done` loop and make the service non-`oneshot`, or push from CI via the manual trigger.

## Revert
Delete `/system/etc/init/shield-deploy.rc` (after `mount -o remount,rw /`). The checkout at `/data/NVidiaShieldPro` and the containers are untouched. Revoke the deploy key separately if desired.

## Behavior summary
- `git-sync.sh` clones/updates `/data/NVidiaShieldPro` over SSH using the read-only deploy key, via an `alpine/git` container.
- `pull-and-deploy.sh` waits for dockerd, runs the sync, and logs `no change` when `HEAD` is unchanged.
- On a moved `HEAD`, `redeploy.sh` re-runs the launchers in its `ACTIVE` list and the containers bounce onto the new config.
- The service is `oneshot`: it runs on boot, completes, and exits (`init.svc.shield_deploy=stopped` is the healthy post-run state), while `init.svc.dockerd` stays `running`.
- The private key is mode `600` at `/data/.ssh/` (outside the repo) and never appears in `git status`.
