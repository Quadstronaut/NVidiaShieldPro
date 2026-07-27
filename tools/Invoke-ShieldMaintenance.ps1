<#
.SYNOPSIS
  The one scheduled entry point that keeps the Shield current and proves it.

.DESCRIPTION
  Every tool in this directory worked. None of them were scheduled. The Shield
  therefore degraded silently for a month, was repaired by hand on 2026-07-25,
  and began drifting again immediately: DEVIL memory changed, the Shield kept the
  old copies, and the parity gate still reported 17/17 because it compared file
  COUNTS. Building the machinery and leaving it human-triggered reproduces the
  exact failure it was built to prevent, one layer up.

  This is that missing scheduler hook. It runs the three tools in dependency
  order, logs one line per run, and makes a failure visible in three places at
  once so it cannot pass unnoticed:

    1. a non-zero exit code, which Task Scheduler surfaces as LastTaskResult
    2. a rolling log next to the other backups on B:
    3. a status file ON THE SHIELD at /data/claude/.maintenance-status, which is
       inside the container mount -- so the Shield's own Claude can read it and
       tell the user their identity is stale. That last one matters most: it puts
       the warning where the user actually is.

  ORDER IS LOAD-BEARING
    bundles -> sync -> gate.
    Bundles first because they are the only step that needs nothing but this PC,
    so a Shield that is off or unplugged still gets its off-disk backup taken.
    Sync before the gate because the gate asserts the sync stamp's freshness; the
    other order would fail the gate on its own scheduling.

.PARAMETER LogDir
  Where the rolling log and the last-status file are written. Defaults to B:,
  the same physical disk (0) as the other backups and a different one from the
  repos on G: (disk 3).

.PARAMETER SkipBundles / SkipSync / SkipGate
  Run a subset. Intended for manual invocation while debugging one stage.

.EXAMPLE
  powershell -File tools\Invoke-ShieldMaintenance.ps1
  powershell -File tools\Invoke-ShieldMaintenance.ps1 -SkipBundles

.NOTES
  Windows PowerShell 5.1 only (pwsh is not installed on DEVIL).

  Deliberately ASCII-only. 5.1 reads a BOM-less UTF-8 .ps1 as ANSI, and one
  em-dash decodes to a byte that terminates a string literal, producing a parse
  error nowhere near the offending character.

  Each tool is invoked as a CHILD powershell.exe rather than dot-sourced. The
  tools set $ErrorActionPreference = 'Stop' and throw on failure; dot-sourcing
  would let one tool's throw abort this whole script, so a Shield that was merely
  switched off would also silently skip the bundle backup. A child process turns
  that throw into an exit code we can record and carry on from.
#>
[CmdletBinding()]
param(
  [string]$LogDir     = 'B:\BAKS\shield',
  [string]$ShieldHost = 'shield',
  [switch]$SkipBundles,
  [switch]$SkipSync,
  [switch]$SkipGate
)

$ErrorActionPreference = 'Stop'
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$PS      = (Get-Command powershell.exe).Source
$Started = Get-Date
$Steps   = @()

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Log = Join-Path $LogDir 'maintenance.log'

function Write-Log([string]$Line) {
  $stamped = "{0} {1}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Line
  Write-Host $stamped
  Add-Content -Path $Log -Value $stamped -Encoding UTF8
}

function Invoke-Tool([string]$Name, [string]$Script, [string[]]$ToolArgs) {
  # Returns the child's exit code; never throws. A tool that cannot run is a
  # recorded failure, not a reason to abandon the remaining stages.
  $path = Join-Path $Here $Script
  if (-not (Test-Path $path)) {
    Write-Log "  $Name SKIPPED (missing: $Script)"
    $script:Steps += [pscustomobject]@{ Name = $Name; Rc = 127; Note = 'script missing' }
    return 127
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = Join-Path $LogDir ("last-$Name.txt")
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $ToolArgs
  # Capture the tool's own output to its own file: the rolling log stays one line
  # per stage and stays readable, while the full detail is still there to read
  # after a failure.
  & $PS $argv *>&1 | Out-File -FilePath $out -Encoding UTF8
  $rc = $LASTEXITCODE
  $sw.Stop()
  $verdict = if ($rc -eq 0) { 'OK' } else { "FAILED rc=$rc" }
  Write-Log ("  {0,-22} {1}  ({2}s, detail: {3})" -f $Name, $verdict, [math]::Round($sw.Elapsed.TotalSeconds), (Split-Path $out -Leaf))
  $script:Steps += [pscustomobject]@{ Name = $Name; Rc = $rc; Note = '' }
  return $rc
}

Write-Log "===== shield maintenance start ====="

# ---------- 1. bundles: PC-only, so it runs whether or not the Shield is up ----
if (-not $SkipBundles) { Invoke-Tool 'bundles' 'Backup-RepoBundles.ps1' @() | Out-Null }
else                   { Write-Log '  bundles                SKIPPED (-SkipBundles)' }

# ---------- 2. is the Shield reachable at all? -------------------------------
# Checked once, here, rather than letting each tool discover it separately: a
# powered-off Shield should read as one clear "unreachable" line, not as two
# confusing tool failures.
$reachable = $false
if (-not ($SkipSync -and $SkipGate)) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $probe = & ssh -o BatchMode=yes -o ConnectTimeout=10 $ShieldHost 'echo ok'
  $reachable = ($LASTEXITCODE -eq 0 -and ($probe -join '') -match 'ok')
  $ErrorActionPreference = $prev
  Write-Log ("  shield reachable       {0}" -f $(if ($reachable) { 'yes' } else { 'NO - skipping sync + gate' }))
}

# ---------- 3. identity sync, then 4. the gate -------------------------------
if ($reachable) {
  if (-not $SkipSync) { Invoke-Tool 'identity-sync' 'Sync-ShieldIdentity.ps1' @() | Out-Null }
  else                { Write-Log '  identity-sync          SKIPPED (-SkipSync)' }

  if (-not $SkipGate) { Invoke-Tool 'parity-gate'  'Test-ShieldParity.ps1'   @() | Out-Null }
  else                { Write-Log '  parity-gate            SKIPPED (-SkipGate)' }
} elseif (-not ($SkipSync -and $SkipGate)) {
  # Unreachable is a real failure -- the whole point is that a Shield which has
  # quietly fallen off the LAN must not look identical to a healthy one.
  $Steps += [pscustomobject]@{ Name = 'shield-reachable'; Rc = 1; Note = 'ssh failed' }
}

# ---------- 5. verdict -------------------------------------------------------
$failed  = @($Steps | Where-Object { $_.Rc -ne 0 })
$elapsed = [math]::Round(((Get-Date) - $Started).TotalSeconds)
$summary = if ($failed.Count -eq 0) {
  "OK all $($Steps.Count) stages passed in ${elapsed}s"
} else {
  "FAIL $($failed.Count)/$($Steps.Count) stages: " + (($failed | ForEach-Object { "$($_.Name)(rc=$($_.Rc))" }) -join ' ')
}
Write-Log "===== $summary ====="

$statusLine = "{0} {1}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $summary
Set-Content -Path (Join-Path $LogDir 'last-status.txt') -Value $statusLine -Encoding UTF8

# Put the verdict where the user actually is. /data/claude is the container mount,
# so the Shield's own Claude can read this file and say "your identity sync last
# failed 3 days ago" instead of confidently working from stale memory.
# Single-quoted through ssh and stripped of quote characters first: this string
# crosses PowerShell -> ssh -> Android sh, and quoting has broken every one of
# those hops in this project before.
if ($reachable) {
  $safe = $statusLine -replace "[`"'``$]", ''
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & ssh -o BatchMode=yes -o ConnectTimeout=10 $ShieldHost "echo '$safe' > /data/claude/.maintenance-status"
  $ErrorActionPreference = $prev
}

# Rotate at ~2 MB so an always-on box cannot fill the backup volume over years.
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 2MB) {
  Move-Item $Log "$Log.1" -Force
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
