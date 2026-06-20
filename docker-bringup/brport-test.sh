BB=/data/docker/bin/busybox
IP=/system/bin/ip
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$D run -d --name nt busybox sleep 60 >/dev/null 2>&1; sleep 2
VETH=$($BB ls /sys/class/net 2>/dev/null | $BB grep '^veth' | $BB head -1)
echo "veth=$VETH"
echo "docker0 ports: $($BB ls /sys/class/net/docker0/brif 2>/dev/null)"
echo "brport state = $($BB cat /sys/class/net/$VETH/brport/state 2>/dev/null) (0=disabled 3=forwarding)"
echo "docker0 forwarding flags: $($BB cat /sys/class/net/docker0/bridge/forward_delay 2>/dev/null) stp=$($BB cat /sys/class/net/docker0/bridge/stp_state 2>/dev/null)"
echo "--- force veth + docker0 brport to forwarding ---"
echo 3 > /sys/class/net/$VETH/brport/state 2>/dev/null; echo "set veth state rc=$?"
echo "brport state now = $($BB cat /sys/class/net/$VETH/brport/state 2>/dev/null)"
echo "--- retest container -> gateway ---"
$D exec nt ping -c1 -W2 172.17.0.1 >/dev/null 2>&1 && echo "GW PING OK" || echo "GW PING FAIL"
$D rm -f nt >/dev/null 2>&1
echo
echo "=== FALLBACK: --network host (no bridge involved) ==="
$D run --rm --network host busybox sh -c 'echo ping:; ping -c2 -W3 8.8.8.8 | tail -2; echo http:; wget -T8 -qO- http://example.com 2>&1 | grep -i "<title>" || echo HTTP_FAIL'
