BB=/data/docker/bin/busybox
echo "=== current adb tcp properties ==="
echo "  service.adb.tcp.port (non-persistent) = $(getprop service.adb.tcp.port)"
echo "  persist.adb.tcp.port (persistent)     = $(getprop persist.adb.tcp.port)"
echo
echo "=== set persist.adb.tcp.port=5555 ==="
setprop persist.adb.tcp.port 5555
$BB sleep 1
echo "  persist.adb.tcp.port now = $(getprop persist.adb.tcp.port)"
echo
echo "=== written to the persistent store on /data (survives reboot)? ==="
$BB ls -l /data/property/persistent_properties 2>/dev/null
$BB grep -a -o 'persist.adb.tcp.port' /data/property/persistent_properties 2>/dev/null && echo "  ^ key is on disk"
$BB grep -a -o '5555' /data/property/persistent_properties 2>/dev/null | $BB head -1 && echo "  ^ value present"
