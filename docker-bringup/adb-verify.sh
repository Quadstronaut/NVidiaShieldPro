BB=/data/docker/bin/busybox
# SAFETY NET: in 25s, force ADB-over-network back on via the known-good non-persistent
# prop, in case persist.adb.tcp.port alone does not make adbd listen. Detached so it
# survives the adbd restart below.
$BB setsid /system/bin/sh -c 'sleep 25; setprop service.adb.tcp.port 5555; setprop ctl.restart adbd' </dev/null >/dev/null 2>&1 &
# Simulate the post-reboot state: clear the non-persistent prop so ONLY persist.adb.tcp.port remains.
setprop service.adb.tcp.port ""
# Restart adbd. If it comes back listening on tcp 5555, persist.adb.tcp.port works on its own.
setprop ctl.restart adbd
