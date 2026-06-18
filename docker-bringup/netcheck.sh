BB=/data/docker/bin/busybox
echo "=== kernel netfilter/bridge config (Docker bridge NAT needs these) ==="
KEYS='CONFIG_IP_NF_TARGET_MASQUERADE|CONFIG_NETFILTER_XT_TARGET_MASQUERADE|CONFIG_BRIDGE_NETFILTER|CONFIG_IP_NF_NAT|CONFIG_NF_NAT|CONFIG_NF_NAT_IPV4|CONFIG_IP_NF_FILTER|CONFIG_IP_NF_IPTABLES|CONFIG_NETFILTER_XT_MATCH_CONNTRACK|CONFIG_NETFILTER_XT_MATCH_ADDRTYPE|CONFIG_NF_CONNTRACK_IPV4|CONFIG_NETFILTER_XT_TARGET_MASQUERADE|CONFIG_IP_NF_TARGET_REJECT'
$BB zcat /proc/config.gz 2>/dev/null | $BB grep -E "^($KEYS)=" | $BB sort
echo
echo "=== iptables binary on device? ==="
for p in /system/bin/iptables /system/bin/iptables-legacy /vendor/bin/iptables; do
  [ -e "$p" ] && echo "  found $p -> $($p --version 2>&1 | $BB head -1)"
done
which iptables 2>/dev/null || echo "  (iptables not in PATH)"
echo
echo "=== can iptables read the NAT table right now? ==="
iptables -t nat -L -n 2>&1 | $BB head -8
echo
echo "=== bridge netfilter sysctl present? ==="
ls -l /proc/sys/net/bridge/ 2>&1 | $BB head
echo
echo "=== ip command + current interfaces ==="
$BB ip -o link 2>/dev/null | $BB head
echo "iptables-restore: $(which iptables-restore 2>/dev/null || echo missing)"
echo "iptables-save:    $(which iptables-save 2>/dev/null || echo missing)"
