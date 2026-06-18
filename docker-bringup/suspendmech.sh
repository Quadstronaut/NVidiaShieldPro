#!/system/bin/sh
# READ-ONLY. Characterize the Shield's sleep: is "pulsing green LED" a full
# suspend-to-RAM (CPU halted, everything frozen) or just deep CPU idle (C-states)?
# Triggers NOTHING. timeout-wraps sysfs reads that can block.
BB=/data/docker/bin/busybox
rd() { $BB timeout 4 $BB cat "$1" 2>/dev/null || echo "  (unreadable: $1)"; }

echo "=== /sys/power inventory ==="
$BB ls /sys/power/ 2>/dev/null | $BB tr '\n' ' '; echo

echo
echo "=== supported sleep states (/sys/power/state) ==="
echo "  states: $(rd /sys/power/state)"
echo "  meaning: 'mem' = suspend-to-RAM (deep). 'freeze' = s2idle (light)."

echo
echo "=== what does 'mem' map to? (/sys/power/mem_sleep) ==="
echo "  mem_sleep: $(rd /sys/power/mem_sleep)"
echo "  [deep] = devices powered off, CPU halted (S3-like / Tegra LP0)."
echo "  [s2idle] = CPU parked in idle, devices kept, lighter."

echo
echo "=== opportunistic autosleep target (how Android auto-suspends) ==="
echo "  autosleep: $(rd /sys/power/autosleep)"

echo
echo "=== suspend stats (has it ever suspended this boot?) ==="
echo "  success: $(rd /sys/power/suspend_stats/success)"
echo "  fail:    $(rd /sys/power/suspend_stats/fail)"
echo "  last_failed_step: $(rd /sys/power/suspend_stats/last_failed_step)"

echo
echo "=== suspend blockers currently held (these PREVENT suspend) ==="
echo "  held wakelocks: $(rd /sys/power/wake_lock)"

echo
echo "=== armed wake sources (what could resume it) ==="
$BB timeout 4 $BB cat /sys/kernel/debug/wakeup_sources 2>/dev/null | $BB awk 'NR==1 || $6>0 {print "  "$0}' | $BB head -12 || echo "  (wakeup_sources unreadable without debugfs)"
