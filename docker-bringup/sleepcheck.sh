BB=/data/docker/bin/busybox
echo "=== uptime (no reboot if this is hours) ==="
$BB uptime
echo
echo "=== wakefulness / interactive state ==="
dumpsys power 2>/dev/null | $BB grep -iE 'mWakefulness|mScreenOn|mInteractive' | $BB head -5
echo
echo "=== was the SoC ever suspended since boot? ==="
echo "suspend count: $($BB cat /sys/power/suspend_stats/success 2>/dev/null || echo n/a)"
dmesg 2>/dev/null | $BB grep -i suspend | $BB tail -3
echo
echo "=== docker daemon ==="
/data/docker/bin/docker -H unix:///data/docker/docker.sock info 2>/dev/null | $BB grep -i 'server version'
echo "containers running: $(/data/docker/bin/docker -H unix:///data/docker/docker.sock ps -q 2>/dev/null | $BB wc -l)"
