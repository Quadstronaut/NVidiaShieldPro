BB=/data/docker/bin/busybox
echo "=== docker/containerd/shim processes ==="
$BB ps -ef 2>/dev/null | $BB grep -E "dockerd|containerd|runc" | $BB grep -v grep
echo
DPID=$($BB pgrep -f "bin/dockerd" | $BB head -1)
CPID=$($BB pgrep -f "bin/containerd" | $BB head -1)
echo "dockerd pid=$DPID    containerd pid=$CPID"
echo "=== mount namespaces (differ => separate ns) ==="
echo "  init(1)   : $($BB readlink /proc/1/ns/mnt)"
echo "  this shell: $($BB readlink /proc/$$/ns/mnt)"
echo "  dockerd   : $($BB readlink /proc/$DPID/ns/mnt 2>/dev/null)"
echo "  containerd: $($BB readlink /proc/$CPID/ns/mnt 2>/dev/null)"
echo "=== what does dockerd see at /sys/fs/cgroup ? ==="
$BB grep " /sys/fs/cgroup " /proc/$DPID/mountinfo 2>/dev/null | $BB head -3
echo "=== what does containerd see at /sys/fs/cgroup ? ==="
$BB grep " /sys/fs/cgroup " /proc/$CPID/mountinfo 2>/dev/null | $BB head -3
echo "=== is containerd a child of dockerd? ==="
echo "  containerd PPID: $($BB cat /proc/$CPID/stat 2>/dev/null | $BB awk '{print $4}')"
