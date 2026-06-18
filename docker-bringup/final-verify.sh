BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== daemon ==="
$D info 2>/dev/null | $BB grep -iE "Server Version|Storage Driver|Cgroup Version"
echo
echo "=== container internet via --network host ==="
$D run --rm --network host busybox sh -c 'ping -c1 -W3 8.8.8.8 | tail -1; wget -T8 -qO- http://example.com 2>&1 | grep -i "<title>"'
echo
echo "=== container SERVING a port (busybox httpd on :8088, host net) ==="
$D run -d --name web --network host busybox httpd -f -p 8088 -h / >/dev/null 2>&1
sleep 2
echo "fetch via 127.0.0.1:8088 ->"
$BB wget -T5 -qO- http://127.0.0.1:8088/etc/hostname 2>&1 | $BB head -1
echo "fetch via LAN 10.0.0.88:8088 ->"
$BB wget -T5 -qO- http://10.0.0.88:8088/etc/hostname 2>&1 | $BB head -1
$D rm -f web >/dev/null 2>&1
echo "(the line(s) above are the container's /etc/hostname served over HTTP)"
