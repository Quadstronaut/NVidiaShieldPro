#!/system/bin/sh
# tailscale-install.sh — fetch the pinned arm64 tailscale + tailscaled onto the host,
# sha256-verified, into /data/tailscale (persistent, OUTSIDE any repo tree). Provision-
# time + idempotent: a no-op when the exact pinned version is already installed.
#
# Download+verify happen inside a throwaway alpine CONTAINER (Toybox has no curl/tar/
# sha256 workflow; this mirrors deploy/git-sync.sh's "tools live in a container" pattern).
# The version is pinned in the URL AND the bytes are checked against tailscale's own
# published .sha256 sidecar, so a tampered/mismatched download fails closed.
set -e

TS_VER=${TS_VER:-1.98.8}
TS_DIR=${TS_DIR:-/data/tailscale}
DOCKER="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
GIT_IMG=${GIT_IMG:-alpine:latest}

mkdir -p "$TS_DIR"

# Idempotence: EXACT version match (anchored `=`, not a substring grep — 1.98.8 must
# not be satisfied by 1.98.80). tailscale --version prints the version on line 1.
if [ -x "$TS_DIR/tailscaled" ]; then
  cur=$("$TS_DIR/tailscale" --version 2>/dev/null | head -1 | tr -d '[:space:]')
  if [ "$cur" = "$TS_VER" ]; then
    echo "tailscale $TS_VER already installed at $TS_DIR — no-op"
    exit 0
  fi
  echo "installed tailscale '$cur' != pin '$TS_VER' — re-fetching"
fi

$DOCKER image inspect "$GIT_IMG" >/dev/null 2>&1 || $DOCKER pull "$GIT_IMG"

# tar is a pinned name; the sidecar is <tarball>.sha256 at the same origin.
$DOCKER run --rm --network host -v "$TS_DIR":/out "$GIT_IMG" sh -c '
  set -e
  ver="'"$TS_VER"'"
  base="https://pkgs.tailscale.com/stable"
  tgz="tailscale_${ver}_arm64.tgz"
  cd /tmp
  wget -qO "$tgz"      "$base/$tgz"
  wget -qO "$tgz.sha256" "$base/$tgz.sha256"
  # sidecar holds the bare hash (or "hash  name"); take field 1 and check.
  hash=$(cut -d" " -f1 "$tgz.sha256")
  echo "$hash  $tgz" | sha256sum -c -
  tar -xzf "$tgz"
  install -m 0755 "tailscale_${ver}_arm64/tailscale"  /out/tailscale
  install -m 0755 "tailscale_${ver}_arm64/tailscaled" /out/tailscaled
'
echo "installed tailscale $TS_VER -> $TS_DIR"
"$TS_DIR/tailscale" --version | head -1
