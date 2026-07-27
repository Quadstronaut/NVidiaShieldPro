#!/system/bin/sh
BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "uptime      : $(cat /proc/uptime | cut -d. -f1)s   (was 378415s = 4.4 days)"
echo "dockerd svc : $(getprop init.svc.dockerd)"
echo "deploy svc  : $(getprop init.svc.shield_deploy)"
echo "selinux     : $(getenforce)"
echo "adb persist : $(getprop persist.adb.tcp.port)"
echo
echo "containers  :"
$D ps --format '  {{.Names}}  {{.Status}}'
echo
echo "refresh svc : $($BB ps -ef | $BB grep -c '[r]epo-refresh-svc') process(es)"
echo "dropbear    : $($BB ps -ef | $BB grep -c '[d]ropbear') process(es)"
echo
echo "repos       : $(find /data/claude/GIT -maxdepth 3 -name .git -type d | wc -l)   (want 55)"
echo "memory      : $(find /data/docker/data/volumes/claude-home/_data/.claude/projects -path '*/memory/*' -type f | wc -l)   (want 623)"
echo "book-writing: $([ -d /data/claude/book-writing/.git ] && echo present || echo MISSING)"
echo "last refresh: $(head -1 /data/claude/.last-refresh 2>/dev/null)"
echo
echo "refresh log tail:"
tail -3 /data/docker/repo-refresh.log 2>/dev/null || echo "  (no log yet)"