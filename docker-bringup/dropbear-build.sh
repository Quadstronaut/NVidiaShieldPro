#!/system/bin/sh
# Build a STATIC musl dropbear (server+keygen) from patched official source, so
# it runs standalone on Android bionic and provides DEVIL->Shield ssh (the stock
# /product/bin/sshd can't shield host keys on this BoringSSL build). Patches:
#   - common-session.c: synthesize a root passwd entry (bionic has no /etc/passwd)
#     -> home /data/ssh, shell /system/bin/sh
#   - svr-auth.c: skip the /etc/shells validation (absent on Android)
# Output: /data/ssh/dropbearmulti (multi-call: dropbear, dropbearkey, scp).
set -e
DK="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
IMG=node:20-bookworm-slim
SRCDIR=dropbear-DROPBEAR_2022.83

$DK rm -f db-build 2>/dev/null || true
echo "== host-net build container =="
$DK run -d --network=host --name db-build -v /data/docker:/dkr -v /data/ssh:/out "$IMG" sleep infinity

echo "== extract patched source =="
$DK exec db-build sh -c 'rm -rf /build && mkdir -p /build && tar -xzf /dkr/dropbear-patched.tar.gz -C /build && ls /build'

echo "== apt: build-essential + musl-tools (pinned DNS, root apt sandbox) =="
$DK exec db-build sh -c 'printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf'
$DK exec db-build sh -c 'apt-get -o APT::Sandbox::User=root -o Acquire::ForceIPv4=true update'
$DK exec db-build sh -c 'apt-get -o APT::Sandbox::User=root -o Acquire::ForceIPv4=true install -y build-essential musl-tools'

echo "== configure (musl, static, no zlib/syslog) + build multi binary =="
$DK exec -w /build/$SRCDIR db-build sh -c 'chmod +x configure config.sub config.guess install-sh 2>/dev/null; CC=musl-gcc sh ./configure --enable-static --disable-zlib --disable-syslog'
$DK exec -w /build/$SRCDIR db-build sh -c 'make -j4 PROGRAMS="dropbear dropbearkey scp" MULTI=1'

echo "== verify it is a static ELF, then export =="
$DK exec -w /build/$SRCDIR db-build sh -c 'file dropbearmulti; cp dropbearmulti /out/dropbearmulti && chmod 755 /out/dropbearmulti'

$DK rm -f db-build
echo "DROPBEAR_BUILD_DONE"
ls -la /data/ssh/dropbearmulti
