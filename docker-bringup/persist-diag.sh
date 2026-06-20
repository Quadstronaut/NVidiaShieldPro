BB=/data/docker/bin/busybox
echo "=== boot/verity props ==="
for p in ro.build.type ro.boot.slot_suffix ro.boot.verifiedbootstate ro.boot.veritymode partition.system.verified ro.build.system_root_image ro.product.device; do
  echo "  $p = $(getprop $p)"
done
echo
echo "=== what are / /system /vendor ? ==="
$BB mount | $BB grep -E " / | /system | /vendor " | $BB grep -vE "/sys|/proc|emulated|mirror"
echo
echo "=== is /system/etc/init writable (persistent init hook target)? ==="
ls -ld /system /system/etc/init 2>&1 | $BB head -4
mount -o remount,rw /system 2>&1; echo "remount /system rw rc=$?"
mount -o remount,rw / 2>&1; echo "remount / rw rc=$?"
TESTF=/system/etc/init/.dockwrite_test
( echo "x" > $TESTF ) 2>&1 && { echo "WRITE_OK to /system/etc/init"; rm -f $TESTF; } || echo "WRITE_FAIL to /system/etc/init"
echo
echo "=== existing boot-script mechanisms? ==="
ls -ld /system/etc/init.d 2>/dev/null && echo "  init.d EXISTS" || echo "  no /system/etc/init.d"
ls /system/etc/init/ 2>/dev/null | $BB grep -iE "lineage|addon|local" | $BB head
echo
echo "=== where do cgroup controllers live at boot (already mounted by init)? ==="
$BB grep -E "cpuctl|memcg|cpuset" /proc/mounts | $BB head -4
