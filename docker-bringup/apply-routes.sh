BB=/data/docker/bin/busybox
IP=/system/bin/ip
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
# idempotent: drop prior copies
$IP rule del from 172.17.0.0/16 lookup eth0 2>/dev/null
$IP rule del to 172.17.0.0/16 lookup main 2>/dev/null
# outbound container traffic -> eth0 table (has the default route)
$IP rule add from 172.17.0.0/16 lookup eth0 pref 15999
# replies/traffic to containers -> main table (has the docker0 route)
$IP rule add to 172.17.0.0/16 lookup main pref 15998
echo "=== docker-related ip rules ==="
$IP rule | $BB grep 172.17
echo
echo "=== RETEST: container ping 8.8.8.8 (NAT path) ==="
$D run --rm busybox ping -c2 -W3 8.8.8.8 2>&1 | $BB tail -3
echo
echo "=== RETEST: container DNS + HTTP ==="
$D run --rm busybox sh -c 'wget -T8 -qO- http://example.com 2>&1 | grep -i "<title>" || echo "HTTP FAILED"'
