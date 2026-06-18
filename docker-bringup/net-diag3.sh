BB=/data/docker/bin/busybox
IP=/system/bin/ip
echo "=== route decision for a FORWARDED packet (iif docker0) ==="
$IP route get 8.8.8.8 from 172.17.0.2 iif docker0 2>&1
echo
echo "=== route decision from 172.17.0.2 WITHOUT iif (local-style) ==="
$IP route get 8.8.8.8 from 172.17.0.2 2>&1
echo
echo "=== eth0 table contents ==="
$IP route show table eth0 2>&1
echo
echo "=== does Android mark forwarded packets? mangle PREROUTING ==="
iptables -t mangle -S PREROUTING 2>&1 | $BB head -15
echo
echo "=== mangle FORWARD ==="
iptables -t mangle -S FORWARD 2>&1 | $BB head -15
