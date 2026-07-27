#!/system/bin/sh
BB=/data/docker/bin/busybox
DK=/data/docker/bin/docker
S=unix:///data/docker/docker.sock
echo "== dropbear :22 =="
$BB netstat -ltn 2>/dev/null | $BB grep ":22 " || echo NO_22
echo "== dockerd proc =="
$BB ps -ef 2>/dev/null | $BB grep "bin/dockerd" | $BB grep -v grep | $BB head -1 || echo NO_DOCKERD
echo "== wait for docker.sock + info (up to 60s) =="
n=0
while [ $n -lt 20 ]; do
  [ -S /data/docker/docker.sock ] && $DK -H $S info >/dev/null 2>&1 && break
  sleep 3; n=$((n+1))
done
echo "ready_after=$((n*3))s"
echo "== containers =="
$DK -H $S ps --format '{{.Names}}\t{{.Status}}' 2>&1
echo "== dropbear-boot.log =="
$BB cat /data/ssh/dropbear-boot.log 2>/dev/null
