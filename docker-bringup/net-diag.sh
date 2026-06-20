BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "ip_forward before = $($BB cat /proc/sys/net/ipv4/ip_forward)"
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "ip_forward after  = $($BB cat /proc/sys/net/ipv4/ip_forward)"
echo
echo "=== filter FORWARD (policy + rules) ==="
iptables -t filter -S FORWARD
echo
echo "=== DOCKER-USER / DOCKER-ISOLATION present? ==="
iptables -t filter -S DOCKER-USER 2>&1 | $BB head -3
echo
echo "=== eth0 addr ==="
$BB ip -o addr show eth0 | $BB grep -o 'inet [0-9./]*'
echo
echo "=== RETEST: container ping 8.8.8.8 after ip_forward=1 ==="
$D run --rm busybox ping -c2 -W3 8.8.8.8 2>&1 | $BB tail -3
echo
echo "=== RETEST: container DNS+HTTP ==="
$D run --rm busybox sh -c 'wget -T8 -qO- http://example.com 2>&1 | grep -i title || echo "(failed)"'
