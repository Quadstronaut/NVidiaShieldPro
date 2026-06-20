#!/system/bin/sh
# Final Uptime-Kuma config:
#  - Android net groups 3003(inet)/3004(net_raw) + CAP_NET_RAW  -> ICMP ping works
#  - /data/docker/uptime-kuma:/app/data                          -> persistent data
#  - /data/docker/docker.sock:/var/run/docker.sock              -> Kuma can monitor host containers
#    (add a Docker Host in Kuma: Connection Type = Socket, Daemon = /var/run/docker.sock)
# Host net, restart=always.
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
  -v /data/docker/docker.sock:/var/run/docker.sock \
  louislam/uptime-kuma:2.4.0-slim
echo "recreated: net-groups + persistent volume + docker.sock mounted"
