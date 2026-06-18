BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== daemon up? ==="
$D info 2>/dev/null | $BB grep -iE "Server Version|Storage Driver|Cgroup Version"
echo "--- dockerd.log: bridge/iptables lines ---"
$BB grep -iE "iptables|bridge|firewall|ip_forward|default bridge|failed to|level=error" /data/docker/dockerd.log | $BB tail -18
echo "=== docker networks ==="
$D network ls
echo "=== docker0 interface ==="
$BB ip -o addr show docker0 2>&1 | $BB head -2
echo "=== nat POSTROUTING (docker MASQUERADE rule?) ==="
iptables -t nat -S POSTROUTING 2>&1 | $BB grep -i masq | $BB head
echo "=== pull busybox (has net tools) ==="
$D pull busybox 2>&1 | $BB tail -3
echo "=== TEST: container -> internet via default bridge ==="
$D run --rm busybox sh -c 'echo "ping 8.8.8.8 (NAT):"; ping -c2 -W3 8.8.8.8 | tail -2; echo "DNS+HTTP:"; wget -T8 -qO- http://example.com 2>&1 | grep -i "<title>" || echo "(http failed)"'
echo "container-net exit=$?"
