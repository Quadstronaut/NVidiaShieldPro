BB=/data/docker/bin/busybox
echo "=== load + cpu count ==="
$BB uptime
echo "cpus: $($BB nproc 2>/dev/null)"
echo
echo "=== top 12 processes by CPU (one-shot) ==="
top -b -n1 2>/dev/null | $BB head -20 || top -n1 2>/dev/null | $BB head -20
echo
echo "=== our docker stack processes ==="
$BB ps -eo pid,pcpu,pmem,comm 2>/dev/null | $BB grep -iE 'docker|containerd|runc' | $BB grep -v grep
echo
echo "=== is anything in uninterruptible/runnable state (load can be I/O wait)? ==="
$BB cat /proc/loadavg
echo "procs running/total: see field 4 above"
