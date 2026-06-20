BB=/data/docker/bin/busybox
IP=/system/bin/ip
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
# ensure rules + rp_filter (idempotent)
for f in all default eth0 docker0; do echo 0 > /proc/sys/net/ipv4/conf/$f/rp_filter 2>/dev/null; done
$IP rule del from 172.17.0.0/16 lookup eth0 2>/dev/null; $IP rule add from 172.17.0.0/16 lookup eth0 pref 15999
$IP rule del to 172.17.0.0/16 lookup main 2>/dev/null;  $IP rule add to 172.17.0.0/16 lookup main pref 15998
echo "=== graduated ping FROM a container (where does it die?) ==="
$D run --rm busybox sh -c '
for t in 172.17.0.1 10.0.0.88 10.0.0.1 8.8.8.8; do
  printf "  %-12s " "$t"; ping -c1 -W2 "$t" >/dev/null 2>&1 && echo OK || echo FAIL
done'
echo
echo "=== HOST -> running container ping ==="
$D run -d --name nettest busybox sleep 40 >/dev/null 2>&1
sleep 2
CIP=$($D inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nettest 2>/dev/null)
echo "  container ip = $CIP"
echo "  host veths + docker0 state:"; $BB ip -o link 2>/dev/null | $BB grep -E "docker0|veth" | $BB head
ping -c2 -W2 "$CIP" 2>&1 | $BB tail -2
$D rm -f nettest >/dev/null 2>&1
