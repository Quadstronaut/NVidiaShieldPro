# Refresh the LAN->WSL browserless port-proxy to the CURRENT WSL IP.
#
# Why: WSL2 (NAT mode) gives the Debian VM a dynamic 172.x IP that changes on
# every `wsl --shutdown` / host reboot. The Shield (Kuma remote browser) reaches
# browserless via a Windows portproxy on the PC's LAN IP -> that WSL IP, so the
# proxy must be re-pointed whenever the WSL IP changes. The one-time root cause
# (WSL Hyper-V firewall DefaultInboundAction=Block) is already fixed to Allow and
# persists; only the IP mapping needs refreshing. Runs at logon (scheduled task).
#
# Needs admin (netsh portproxy). Idempotent.

$ErrorActionPreference = 'SilentlyContinue'
$LISTEN_PORT = 3000
$WSL_PORT = 3000

# PC's LAN IPv4 (the address the Shield targets).
$lan = Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -like '10.0.0.*' } |
  Select-Object -First 1 -ExpandProperty IPAddress
if (-not $lan) { Write-Output "no 10.0.0.x LAN IP; abort"; exit 1 }

# Make sure the Debian distro + browserless are up, then read the live WSL IP.
wsl -d Debian -- bash -lc "docker start browserless >/dev/null 2>&1" | Out-Null
$wslip = ((wsl -d Debian -- hostname -I) -join ' ').Trim().Split(' ')[0]
if ($wslip -notmatch '^\d+\.\d+\.\d+\.\d+$') { Write-Output "bad WSL IP '$wslip'; abort"; exit 1 }

netsh interface portproxy delete v4tov4 listenaddress=$lan listenport=$LISTEN_PORT 2>$null | Out-Null
netsh interface portproxy add    v4tov4 listenaddress=$lan listenport=$LISTEN_PORT connectaddress=$wslip connectport=$WSL_PORT | Out-Null
Write-Output ("browserless proxy: {0}:{1} -> {2}:{3}" -f $lan, $LISTEN_PORT, $wslip, $WSL_PORT)
