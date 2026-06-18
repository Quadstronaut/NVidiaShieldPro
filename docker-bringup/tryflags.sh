BB=/data/docker/bin/busybox
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"

echo "=== 1) --privileged ==="
$D run --rm --privileged --network none hello-shield /bin/sh -c 'echo PRIV_OK uid=$(id -u)' 2>&1 | $BB tail -2

echo "=== 2) --privileged --cgroupns host ==="
$D run --rm --privileged --cgroupns host --network none hello-shield /bin/sh -c 'echo CGNS_OK' 2>&1 | $BB tail -2

echo "=== 3) --device-cgroup-rule allow-all ==="
$D run --rm --device-cgroup-rule 'a *:* rwm' --network none hello-shield /bin/sh -c 'echo RULE_OK' 2>&1 | $BB tail -2
