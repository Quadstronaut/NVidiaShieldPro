#!/system/bin/sh
BB=/data/docker/bin/busybox

echo "=== uptime (how long since last boot) ==="
$BB uptime

echo
echo "=== stay-awake dev option (stay_on_while_plugged_in: bitmask, 0=off) ==="
echo "  global stay_on_while_plugged_in = $(settings get global stay_on_while_plugged_in)"
echo "  (bit1=AC bit2=USB bit4=wireless; e.g. 7 = stay on for all)"

echo
echo "=== current power state ==="
dumpsys power 2>/dev/null | $BB grep -iE 'mWakefulness=|mWakefulnessRaw|mIsPowered|mStayOn|mScreenOn=|mHoldingDisplay' | $BB head -8

echo
echo "=== sleep timeout setting (screen_off_timeout, ms) ==="
echo "  system screen_off_timeout = $(settings get system screen_off_timeout)"
echo "  secure sleep_timeout       = $(settings get secure sleep_timeout)"

echo
echo "=== has the SoC actually SUSPENDED since boot? ==="
echo "  /sys/power/suspend_stats/success = $($BB cat /sys/power/suspend_stats/success 2>/dev/null || echo n/a)"
echo "  /sys/power/suspend_stats/fail    = $($BB cat /sys/power/suspend_stats/fail 2>/dev/null || echo n/a)"
echo "  /sys/power/wakeup_count          = $($BB cat /sys/power/wakeup_count 2>/dev/null || echo n/a)"

echo
echo "=== active wakelocks holding it awake right now ==="
$BB cat /sys/power/wake_lock 2>/dev/null || echo "  (wake_lock node not readable)"

echo
echo "=== kernel suspend/resume events (most recent) ==="
dmesg 2>/dev/null | $BB grep -iE 'PM: suspend|PM: resume|suspend entry|suspend exit|Suspending|active wakeup' | $BB tail -6 || echo "  (dmesg unavailable)"

echo
echo "=== docker stack still alive? ==="
/data/docker/bin/docker -H unix:///data/docker/docker.sock ps --format '{{.Names}} {{.Status}}'
