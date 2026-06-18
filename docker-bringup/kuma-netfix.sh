#!/system/bin/sh
# Recreate Uptime-Kuma with the Android net groups so ICMP ping works.
# AID_INET=3003 (IP sockets), AID_NET_RAW=3004 (raw/ICMP) + CAP_NET_RAW.
# Data is preserved via the /data/docker/uptime-kuma volume. Host net, restart=always.
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$D rm -f Uptime-Kuma
$D run -d \
  --name Uptime-Kuma \
  --restart=always \
  --network host \
  --cap-add NET_RAW \
  --group-add 3003 \
  --group-add 3004 \
  -v /data/docker/uptime-kuma:/app/data \
  louislam/uptime-kuma:2.4.0-slim
echo "recreated; container id above"
