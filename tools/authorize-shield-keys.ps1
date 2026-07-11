<#
authorize-shield-keys.ps1 — run on DEVIL (which already has SSH to all three targets)
to append the Shield's PUBLIC keys to the remote authorized_keys files. Only PUBLIC
keys move; nothing secret transits. Idempotent + newline-safe.

  Starhold key (grasp) -> starhold-dedi + starhold-vps
  qflix key (quadstronaut) -> qflix host

Topology (users/IPs/hostnames) is read from the UNTRACKED docker-bringup/shield-access.env
so it never lives in this public file. Copy shield-access.env.example -> shield-access.env
and fill it first.

Usage (paste the two pub lines printed by provision-access.sh):
  pwsh tools/authorize-shield-keys.ps1 `
    -StarholdPub 'ssh-ed25519 AAAA... shield-starhold-...' `
    -QflixPub    'ssh-ed25519 AAAA... shield-qflix-...'

Security notes (council-hardened):
  - ssh is invoked as a native command with ARRAY args — never spliced into a cmd.exe
    string (kills the command-injection class).
  - the pubkey is sent to the remote over STDIN and read with `KEY=$(cat)` — never
    interpolated into the remote command, so a key/comment can't inject either.
  - the append adds a separating newline ONLY when the file doesn't already end in one,
    so it can't corrupt the last existing line.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^ssh-ed25519 [A-Za-z0-9+/=]+')] [string]$StarholdPub,
  [Parameter(Mandatory)] [ValidatePattern('^ssh-ed25519 [A-Za-z0-9+/=]+')] [string]$QflixPub,
  [string]$EnvFile = (Join-Path $PSScriptRoot '..\docker-bringup\shield-access.env')
)
$ErrorActionPreference = 'Stop'

# --- load topology from the untracked env file (KEY=VALUE lines) --------------------
if (-not (Test-Path $EnvFile)) {
  throw "missing $EnvFile — copy docker-bringup/shield-access.env.example to shield-access.env and fill it in."
}
$cfg = @{}
foreach ($line in Get-Content $EnvFile) {
  if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
  $k, $v = $line -split '=', 2
  $cfg[$k.Trim()] = ($v -split '#', 2)[0].Trim()   # strip inline comments
}
foreach ($req in 'STARHOLD_USER','STARHOLD_DEDI','STARHOLD_VPS','QFLIX_USER','QFLIX_HOST') {
  if (-not $cfg[$req]) { throw "$EnvFile is missing $req" }
}
$hostPattern = '^[A-Za-z0-9.\-]+$'
foreach ($h in $cfg['STARHOLD_DEDI'],$cfg['STARHOLD_VPS'],$cfg['QFLIX_HOST']) {
  if ($h -notmatch $hostPattern) { throw "refusing suspicious host value: '$h'" }
}

# Fixed, idempotent, newline-safe remote appender. $KEY arrives on stdin, never in argv.
$remote = @'
set -e
KEY=$(cat)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
if grep -qxF "$KEY" ~/.ssh/authorized_keys; then
  echo PRESENT
else
  if [ -s ~/.ssh/authorized_keys ] && [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then echo >> ~/.ssh/authorized_keys; fi
  printf '%s\n' "$KEY" >> ~/.ssh/authorized_keys
  echo APPENDED
fi
'@

function Add-Key {
  param([string]$Target, [string]$Pub)
  Write-Host "-> $Target ... " -NoNewline
  $result = $Pub | ssh -o BatchMode=yes -o ConnectTimeout=10 $Target $remote 2>&1
  if ($LASTEXITCODE -ne 0) { throw "ssh $Target failed: $result" }
  Write-Host ($result | Select-Object -Last 1)
}

Add-Key ("{0}@{1}" -f $cfg['STARHOLD_USER'], $cfg['STARHOLD_DEDI']) $StarholdPub
Add-Key ("{0}@{1}" -f $cfg['STARHOLD_USER'], $cfg['STARHOLD_VPS'])  $StarholdPub
Add-Key ("{0}@{1}" -f $cfg['QFLIX_USER'],    $cfg['QFLIX_HOST'])    $QflixPub

Write-Host "`nDone. Verify from inside the Shield container:"
Write-Host "  ssh -o BatchMode=yes starhold-dedi hostname"
Write-Host "  ssh -o BatchMode=yes starhold-vps  hostname"
Write-Host "  ssh -o BatchMode=yes qflix          hostname"
