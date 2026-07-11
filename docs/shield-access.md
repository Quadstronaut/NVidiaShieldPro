<div align="center">

# 🔑 Shield remote access — GitHub · Starhold · qflix

**One-time provisioning so the Shield's `claude-term` Claude can `git push`, use `gh`, and SSH your servers — with the gaming PC off.**

![GitHub](https://img.shields.io/badge/GitHub-fine--grained_PAT-24292e?style=flat-square&logo=github)
![Tailscale](https://img.shields.io/badge/Starhold-Tailscale_tag:shield-6159F7?style=flat-square&logo=tailscale&logoColor=white)
![qflix](https://img.shields.io/badge/qflix-ssh-1e8e3e?style=flat-square&logo=openssh&logoColor=white)
![secrets](https://img.shields.io/badge/secrets-on--device_only-critical?style=flat-square)

</div>

---

> [!IMPORTANT]
> **No topology in this public repo.** Real server IPs / hostnames / usernames live only in the **untracked** `docker-bringup/shield-access.env` (copy it from `shield-access.env.example`) and are injected over the **LAN** at provisioning time. This doc uses placeholders. Every secret is born or entered **on the device**, outside any repo tree; nothing here is committed. Provisioning is **idempotent**.

## What the Shield gets

| Capability | Mechanism | Reaches |
|---|---|---|
| 🐙 **GitHub read+write** | one fine-grained **PAT** → `gh` + git HTTPS push | all your repos (public + private) |
| 🛡️ **Starhold SSH** | Shield joins the **tailnet** as `tag:shield`, ACL-scoped to the two boxes:22 | the Starhold fleet + everything hosted on it |
| 🎬 **qflix SSH** | dedicated key → the arr box over the **public internet** | the arr stack |

## Where each secret lives (none in any repo)

| Secret | Location | Mode |
|---|---|---|
| GitHub PAT | claude-home volume · `~/.config/gh/hosts.yml` | 600 |
| Starhold private key | claude-home volume · `~/.ssh/starhold_ed25519` | 600 |
| qflix private key | claude-home volume · `~/.ssh/qflix_ed25519` | 600 |
| Tailscale node state | host · `/data/tailscale/tailscaled.state` | 600 |
| Tailscale auth key | entered once at enroll; delete any on-disk copy after | — |
| **Topology** (IPs/hosts/users) | DEVIL · untracked `docker-bringup/shield-access.env` | — |

The `claude-home` volume and `/data/tailscale` are **outside** `/data/NVidiaShieldPro`, so `git status` can never see them. `.gitignore` also blocks the key/token/env names belt-and-suspenders.

---

## Runbook (one-time, idempotent)

### 🧑‍💻 Step 0 — YOU: fill the topology
```
cp docker-bringup/shield-access.env.example docker-bringup/shield-access.env
# edit shield-access.env with the real Starhold tailnet IPs + qflix host/user
```

### 🧑‍💻 Step 1 — YOU: create the GitHub fine-grained PAT
github.com → Settings → Developer settings → **Fine-grained tokens** → Generate:
- **Resource owner:** your account · **Repository access:** All repositories
- **Permissions:** Contents **RW**, Metadata **RO** (auto), Workflows **RW** *(else pushes touching `.github/workflows/**` are rejected)*, Pull requests **RW**, Issues **RW**
- **Expiry:** set one (max 366d). *Never-expire = don't.*

Hand me the `github_pat_…` (or drop it straight into Step 5). It is entered on-device only.

### 🧑‍💻 Step 2 — YOU: Tailscale auth key + ACL
Tailscale admin console:
1. **Access Controls** → merge [`docker-bringup/tailscale-acl.hujson`](../docker-bringup/tailscale-acl.hujson), swapping the `STARHOLD_*_IP` placeholders for your real IPs (keeps DEVIL's access, scopes `tag:shield` → the two Starhold boxes:22).
2. **Keys** → Generate auth key → **Reusable off**, **Ephemeral off**, **Tags: `tag:shield`**. Hand me the `tskey-auth-…`.

### 🤖 Step 3 — ME: bake `gh` + `openssh-client` into the image
`docker-bringup/claude-term-build.sh` installs both (run+commit) with a sha256-verified `gh v2.96.0`. Rebuild + recreate the container — the `claude-home` volume (and any existing auth) persists.

### 🤖 Step 4 — ME: install + enroll Tailscale (host)
```sh
sh /data/docker/tailscale-install.sh                       # fetch+verify tailscale 1.98.8
# boot service (dockerd-svc.sh) starts tailscaled; enroll once:
/data/tailscale/tailscale up --authkey tskey-… \
    --hostname=shield --advertise-tags=tag:shield --accept-dns=false --ssh=false
```
`--accept-dns=false` keeps tailscaled from rewriting `/etc/resolv.conf` (docker pulls / apt / deploy depend on it). `--ssh=false` keeps Tailscale-SSH **out** of the Shield. Reboot-durable: `tailscaled-svc.sh` runs from `dockerd-svc.sh` at `sys.boot_completed` (same slot as dropbear — one trigger, no race).

### 🤖 Step 5 — ME: provision the container creds
```sh
set -a; . docker-bringup/shield-access.env; set +a      # load topology (LAN-side)
docker cp docker-bringup/provision-access.sh claude-term:/tmp/
docker exec -u claude \
  -e GH_PAT='github_pat_…' \
  -e STARHOLD_USER -e STARHOLD_DEDI -e STARHOLD_VPS -e QFLIX_USER -e QFLIX_HOST \
  claude-term sh /tmp/provision-access.sh
```
Generates the two dedicated SSH keys (atomic, locked — no TOCTOU), authenticates `gh`, wires `gh auth setup-git`, writes `~/.ssh/config` (real IPs land only here, on-device), and prints the two **public** keys.

### 🤖 Step 6 — ME: authorize the public keys from DEVIL
```powershell
pwsh tools/authorize-shield-keys.ps1 -StarholdPub '…' -QflixPub '…'
```
Reads topology from `shield-access.env`; idempotent, newline-safe append to the Starhold boxes and the qflix host. Only public keys move.

---

## ✅ Verification matrix (run from INSIDE the container)

```sh
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
X(){ $D exec -u claude claude-term sh -lc "$1"; }

X 'gh api user -q .login'                                   # -> your login
X 'R=$(gh repo create shield-access-probe --private -y -q 2>/dev/null || echo Quadstronaut/shield-access-probe); \
   cd /tmp && git clone https://github.com/$R _b && cd _b \
     && date -u>>.probe && git add -A \
     && git -c user.email=shield@local -c user.name=shield commit -m probe && git push && cd / && rm -rf /tmp/_b'
X 'ssh -o BatchMode=yes starhold-dedi hostname'            # -> dedi hostname
X 'ssh -o BatchMode=yes starhold-vps  hostname'            # -> vps hostname
X 'ssh -o BatchMode=yes qflix          hostname'           # -> qflix hostname
```
Host-side: `/data/tailscale/tailscale status` shows `shield` online, tagged `tag:shield`, both Starhold peers listed. Reboot test: `adb reboot`, wait ~60s, re-run — all pass, zero manual steps.

## 🔄 Rotation / revocation (each cuts one access independently)
- **PAT:** new token → re-run Step 5 (overwrites) → delete old at github.com/settings/tokens.
- **Starhold/qflix key:** remove the Shield's line from the remote `authorized_keys`.
- **Tailnet:** disable/delete the `shield` node in the admin console.
