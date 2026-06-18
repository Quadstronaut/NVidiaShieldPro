BB=/data/docker/bin/busybox
IP=/system/bin/ip
echo "=== ip rule (policy routing) ==="
$IP rule 2>&1
echo
echo "=== route table: main (what forwarded/unmarked traffic uses) ==="
$IP route show table main 2>&1
echo
echo "=== ALL default routes across every table ==="
$IP route show table all 2>&1 | $BB grep -w default
echo
echo "=== nat POSTROUTING (full, ordered) ==="
iptables -t nat -S POSTROUTING 2>&1
