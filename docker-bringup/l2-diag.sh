BB=/data/docker/bin/busybox
IP=/system/bin/ip
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== arp-related sysctls on docker0 ==="
for k in forwarding rp_filter arp_ignore arp_filter proxy_arp; do
  echo "  docker0/$k = $($BB cat /proc/sys/net/ipv4/conf/docker0/$k 2>/dev/null)"
done
echo "=== bridge stp/forward_delay ==="
echo "  stp_state=$($BB cat /sys/class/net/docker0/bridge/stp_state 2>/dev/null) forward_delay=$($BB cat /sys/class/net/docker0/bridge/forward_delay 2>/dev/null)"
echo "=== /proc/sys/net/bridge present (br_netfilter loaded)? ==="
ls /proc/sys/net/bridge 2>&1
echo
echo "=== from inside container: link state + ARP attempt to gateway ==="
$D run --rm busybox sh -c '
ip link show eth0
echo "--- ping gw 172.17.0.1 (1 pkt) ---"; ping -c1 -W2 172.17.0.1 >/dev/null 2>&1; echo "exit=$?"
echo "--- neigh table after ping (did gw MAC resolve?) ---"; ip neigh
'
echo "=== host side: docker0 neigh / has it learned container MAC? ==="
$IP neigh show dev docker0 2>&1
