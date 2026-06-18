BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$D rm -f web >/dev/null 2>&1
$D run -d --name web --network host busybox httpd -f -p 8088 -h /etc >/dev/null 2>&1
sleep 2
echo "web container: $($D ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | $BB grep web)"
echo "--- fetch :8088 from a SECOND --network host container ---"
$D run --rm --network host busybox wget -T5 -qO- http://127.0.0.1:8088/hostname 2>&1 | $BB head -3
echo "--- and from the Shield's LAN IP ---"
$D run --rm --network host busybox wget -T5 -qO- http://10.0.0.88:8088/hostname 2>&1 | $BB head -3
$D rm -f web >/dev/null 2>&1
echo "(a hostname printed above = the container's HTTP server was reachable on the Shield's port 8088)"
