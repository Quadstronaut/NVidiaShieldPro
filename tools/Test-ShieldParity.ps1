<#
.SYNOPSIS
  Assert the Shield is still a working peer of DEVIL. Exits non-zero if not.

.DESCRIPTION
  The Shield degraded for over a month without anyone noticing: its project
  checkouts were not git repos at all, it had none of DEVIL's memory, and the
  container had no gh/ssh/curl. Nothing ever asserted otherwise, so "it is fine"
  and "it is broken" looked identical until someone tried to use it.

  This is that missing assertion. Run it after any deploy, after a reboot, and
  whenever the Shield is about to be relied on. Every check prints PASS or FAIL
  with the observed value, so a failure says what is actually wrong rather than
  just that something is.

  Checks are ordered cheapest-first and later checks depend on earlier ones, so
  a hard failure early (no ssh, no container) short-circuits the rest instead of
  emitting a wall of misleading errors.

.PARAMETER Quick
  Skip the two slow checks (the `claude -p` round trip and the remote git probe).

.EXAMPLE
  pwsh tools/Test-ShieldParity.ps1
  pwsh tools/Test-ShieldParity.ps1 -Quick
#>
[CmdletBinding()]
param(
  [switch]$Quick,
  [string]$ShieldHost = 'shield',
  [string]$ClaudeHome = "$env:USERPROFILE\.claude",
  [string]$RepoRoot   = 'G:\Documents\GIT'
)

# NOTE: this file is deliberately ASCII-only. PowerShell 5.1 reads a BOM-less
# UTF-8 .ps1 as ANSI, and a single em-dash decodes to a byte that terminates a
# string literal -- producing a parse error far from the offending character.

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Check([string]$Name, [scriptblock]$Test) {
  # A check returns either $true/$false, or "value" plus a bool via [pscustomobject]@{ok=;detail=}
  try {
    $r = & $Test
    if ($r -is [bool]) { $ok = $r; $detail = '' }
    else               { $ok = [bool]$r.ok; $detail = [string]$r.detail }
  } catch {
    $ok = $false; $detail = $_.Exception.Message
  }
  if ($ok) {
    $script:Pass++
    "  [PASS] {0,-44} {1}" -f $Name, $detail
  } else {
    $script:Fail++; $script:Failures += $Name
    "  [FAIL] {0,-44} {1}" -f $Name, $detail
  }
  return $ok
}

function Sh([string]$Cmd) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # No 2>&1: PowerShell 5.1 turns a native command's stderr into terminating
  # ErrorRecords even on exit 0, which would make every check look broken.
  $out = & ssh -o BatchMode=yes -o ConnectTimeout=10 $ShieldHost $Cmd
  $rc = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return [pscustomobject]@{ Out = (($out -join "`n").Trim()); Rc = $rc }
}

$D = '/data/docker/bin/docker -H unix:///data/docker/docker.sock'
function InContainer([string]$Cmd) {
  # Single-quote the inner command so PowerShell cannot eat the quoting on the
  # way through ssh -- a repeated failure mode in this project.
  return (Sh "$D exec -u claude claude-term sh -lc '$Cmd'")
}

Write-Host "=== Shield parity check ===" -ForegroundColor Cyan
Write-Host "host: $ShieldHost"
Write-Host ''

# ---------- reachability ----------
Write-Host 'reachability' -ForegroundColor Yellow
$reach = Check 'ssh reachable' {
  $r = Sh 'echo ok'
  [pscustomobject]@{ ok = ($r.Rc -eq 0 -and $r.Out -eq 'ok'); detail = $(if ($r.Rc -ne 0) { 'ssh failed' } else { '' }) }
}
if (-not $reach) {
  Write-Host ''
  Write-Host 'ssh is down; nothing else can be checked. If Tailscale/LAN is fine, try: adb shell sh /data/docker/dropbear.sh' -ForegroundColor Red
  exit 1
}

Check 'containers running' {
  $r = Sh "$D ps --format '{{.Names}}'"
  $names = $r.Out -split "`n" | ForEach-Object { $_.Trim() }
  $want = @('claude-term', 'shield-c2', 'Uptime-Kuma')
  $missing = $want | Where-Object { $_ -notin $names }
  [pscustomobject]@{ ok = ($missing.Count -eq 0); detail = $(if ($missing) { "missing: $($missing -join ', ')" } else { ($names -join ', ') }) }
} | Out-Null

Check 'claude-term web UI :7777' {
  try { $c = (Invoke-WebRequest "http://10.0.0.88:7777/" -TimeoutSec 10 -UseBasicParsing).StatusCode }
  catch { $c = 0 }
  [pscustomobject]@{ ok = ($c -eq 200); detail = "HTTP $c" }
} | Out-Null

# ---------- tooling ----------
Write-Host ''
Write-Host 'tooling' -ForegroundColor Yellow
Check 'gh / ssh / curl / git / claude present' {
  $r = InContainer 'for b in gh ssh curl git claude; do command -v $b >/dev/null || echo MISSING:$b; done; echo DONE'
  $miss = ($r.Out -split "`n" | Where-Object { $_ -like 'MISSING:*' })
  [pscustomobject]@{ ok = ($miss.Count -eq 0); detail = $(if ($miss) { $miss -join ' ' } else { 'all present' }) }
} | Out-Null

# ---------- credentials ----------
Write-Host ''
Write-Host 'credentials' -ForegroundColor Yellow
Check 'gh authenticates' {
  $r = InContainer 'gh api user -q .login'
  [pscustomobject]@{ ok = ($r.Out -eq 'Quadstronaut'); detail = $r.Out }
} | Out-Null

if (-not $Quick) {
  Check 'can reach a PRIVATE repo remote' {
    $r = InContainer 'git -C /data/claude/GIT/LOCAL-mod/NVIDIAShield ls-remote --heads origin >/dev/null 2>&1 && echo OK || echo FAIL'
    [pscustomobject]@{ ok = ($r.Out -eq 'OK'); detail = $r.Out }
  } | Out-Null
}

Check 'no key material under the container mount' {
  # /data/claude is visible to the in-container Claude by design; private keys
  # must never end up inside it.
  $r = Sh "find /data/claude -name '*_ed25519*' -o -name 'id_rsa*' -o -name '*.pem' | head -5"
  [pscustomobject]@{ ok = ([string]::IsNullOrWhiteSpace($r.Out)); detail = $(if ($r.Out) { "LEAK: $($r.Out)" } else { 'clean' }) }
} | Out-Null

# ---------- projects ----------
Write-Host ''
Write-Host 'projects' -ForegroundColor Yellow
$wantRepos = (Get-ChildItem $RepoRoot -Directory -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq '.git' }).Count
Check "repo count matches DEVIL ($wantRepos)" {
  $r = Sh "find /data/claude/GIT -maxdepth 3 -name .git -type d | wc -l"
  $got = [int]($r.Out.Trim())
  [pscustomobject]@{ ok = ($got -ge $wantRepos); detail = "shield=$got devil=$wantRepos" }
} | Out-Null

Check 'clones are real git repos, not copies' {
  $r = InContainer 'git -C /data/claude/GIT/LOCAL-mod/NVIDIAShield rev-parse --short HEAD'
  [pscustomobject]@{ ok = ($r.Out -match '^[0-9a-f]{7,}$'); detail = "HEAD=$($r.Out)" }
} | Out-Null

Check 'book-writing present and reachable in-container' {
  $r = InContainer 'test -d /data/claude/book-writing/.git && echo OK || echo MISSING'
  [pscustomobject]@{ ok = ($r.Out -eq 'OK'); detail = $r.Out }
} | Out-Null

# ---------- identity ----------
Write-Host ''
Write-Host 'identity' -ForegroundColor Yellow
$wantMem = (Get-ChildItem (Join-Path $ClaudeHome 'projects') -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'memory') } |
            ForEach-Object { (Get-ChildItem (Join-Path $_.FullName 'memory') -File).Count } |
            Measure-Object -Sum).Sum
Check "memory file count >= DEVIL ($wantMem)" {
  $r = Sh "find /data/docker/data/volumes/claude-home/_data/.claude/projects -path '*/memory/*' -type f | wc -l"
  $got = [int]($r.Out.Trim())
  [pscustomobject]@{ ok = ($got -ge $wantMem); detail = "shield=$got devil=$wantMem" }
} | Out-Null

Check 'this project key resolves and holds memory' {
  # If key remapping regresses, memory is present but never recalled -- which is
  # indistinguishable from having no memory at all.
  $r = InContainer 'ls /home/claude/.claude/projects/-data-claude-GIT-LOCAL-mod-NVIDIAShield/memory/ | wc -l'
  $got = [int]($r.Out.Trim())
  [pscustomobject]@{ ok = ($got -gt 0); detail = "$got files" }
} | Out-Null

Check 'steering present (CLAUDE.md + skills + agents)' {
  $r = InContainer 'echo "$(wc -c < /home/claude/.claude/CLAUDE.md):$(ls /home/claude/.claude/skills | wc -l):$(ls /home/claude/.claude/agents | wc -l)"'
  $p = $r.Out -split ':'
  $ok = ($p.Count -eq 3 -and [int]$p[0] -gt 1000 -and [int]$p[1] -ge 3 -and [int]$p[2] -ge 4)
  [pscustomobject]@{ ok = $ok; detail = "CLAUDE.md=$($p[0])B skills=$($p[1]) agents=$($p[2])" }
} | Out-Null

Check 'claude-env rail stays retired' {
  # If this comes back, it will overwrite the synced steering at every boot.
  # Match the ACTIVE= line ONLY: redeploy.sh carries a comment explaining why
  # claude-steer.sh was removed, so grepping the whole file always "finds" it
  # and the check would fail forever on its own documentation.
  $r = Sh "grep '^ACTIVE=' /data/NVidiaShieldPro/deploy/redeploy.sh"
  $wired = $r.Out -match 'claude-steer'
  [pscustomobject]@{ ok = (-not $wired); detail = $(if ($wired) { "RE-WIRED: $($r.Out)" } else { $r.Out.Trim() }) }
} | Out-Null

# ---------- freshness ----------
Write-Host ''
Write-Host 'freshness' -ForegroundColor Yellow
Check 'repo refresh ran within 48h' {
  $r = Sh 'cat /data/claude/.last-refresh 2>/dev/null | head -1'
  if (-not $r.Out) { return [pscustomobject]@{ ok = $false; detail = 'never run' } }
  $stampText = ($r.Out -split ' ')[0]
  try { $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($stampText).ToUniversalTime() }
  catch { return [pscustomobject]@{ ok = $false; detail = "unparseable: $($r.Out)" } }
  [pscustomobject]@{ ok = ($age.TotalHours -lt 48); detail = "$([math]::Round($age.TotalHours,1))h ago" }
} | Out-Null

# ---------- the real test ----------
if (-not $Quick) {
  Write-Host ''
  Write-Host 'end-to-end' -ForegroundColor Yellow
  Check 'claude -p round-trips' {
    $r = Sh "$D exec -u claude claude-term claude -p 'Reply with exactly: PARITY_OK'"
    [pscustomobject]@{ ok = ($r.Out -match 'PARITY_OK'); detail = $r.Out.Substring(0, [Math]::Min(40, $r.Out.Length)) }
  } | Out-Null

  Check 'Claude actually RECALLS synced memory' {
    # Structure can be perfect while recall is broken. This asks a question that
    # is only answerable from a synced memory file.
    $q = 'Answer in one word only, from memory: which SSH username is used for the Starhold fleet?'
    $r = Sh "$D exec -u claude -w /data/claude/GIT/LOCAL-mod/NVIDIAShield claude-term claude -p '$q'"
    [pscustomobject]@{ ok = ($r.Out -match 'grasp'); detail = $r.Out.Substring(0, [Math]::Min(40, $r.Out.Length)) }
  } | Out-Null
}

# ---------- verdict ----------
Write-Host ''
Write-Host ('=' * 60)
Write-Host "PASS: $script:Pass   FAIL: $script:Fail"
if ($script:Fail -gt 0) {
  Write-Host "failed: $($script:Failures -join ', ')" -ForegroundColor Red
  Write-Host 'Shield is NOT at parity.' -ForegroundColor Red
  exit 1
}
Write-Host 'Shield is at parity.' -ForegroundColor Green
exit 0
