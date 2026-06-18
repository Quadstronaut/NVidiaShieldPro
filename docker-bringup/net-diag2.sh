BB=/data/docker/bin/busybox
IP=/system/bin/ip
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== rp_filter values ==="
for f in all default eth0 docker0; do echo "  $f = $($BB cat /proc/sys/net/ipv4/conf/$f/rp_filter 2>/dev/null)"; done
echo "=== set rp_filter=0 everywhere ==="
for f in all default eth0 docker0; do echo 0 > /proc/sys/net/ipv4/conf/$f/rp_filter 2>/dev/null; done
echo "=== container's own addr + route ==="
$D run --rm busybox sh -c 'ip addr show eth0 | grep -w inet; echo route:; ip route'
echo "=== host egress test: ping sourced from docker0 IP ==="
ping -I 172.17.0.1 -c2 -W3 8.8.8.8 2>&1 | $BB tail -3
echo "=== retest container ping after rp_filter=0 ==="
$D run --rm busybox ping -c2 -W3 8.8.8.8 2>&1 | $BB tail -3
echo "=== conntrack for 8.8.8.8 (did the SNAT happen?) ==="
$BB cat /proc/net/nf_conntrack 2>/dev/null | $BB grep 8.8.8.8 | $BB head -3 || echo "(no conntrack entry / not readable)"
