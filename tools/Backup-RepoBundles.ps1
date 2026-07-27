<#
.SYNOPSIS
  Snapshot every local repo as a git bundle, so a rewritten remote history is recoverable.

.DESCRIPTION
  Branch protection and rulesets are Pro-only for PRIVATE repositories. This
  account is on the free plan, so none of the private repos can be protected
  against force-push or branch deletion:

      gh api repos/<owner>/<repo>/rulesets                  -> 403 Upgrade to GitHub Pro
      gh api repos/<owner>/<repo>/branches/<b>/protection   -> 403 Upgrade to GitHub Pro

  That matters because the Shield holds a token that can write to all of them,
  and the Shield is a soft target (ADB on 5555 open to the LAN, `adb root` gives
  uid 0 on this userdebug build). Scoping the token caps the BREADTH of a
  compromise but not its DEPTH -- a write-scoped credential can rewrite the
  history of whatever it can reach, deploy key or PAT alike.

  A bundle is the answer to depth: `git bundle --all` is a single file holding
  every ref and every object. If a remote's history is rewritten or deleted, the
  bundle restores it (`git clone <bundle>`), and nothing on the Shield can touch
  these files.

  This is RECOVERY, not PREVENTION. It does not stop a force-push; it makes one
  survivable. Prevention costs money (GitHub Pro) and is a separate decision.

.PARAMETER Destination
  Where bundles are written. Default is B:\BAKS\repo-bundles.

  The default used to be G:\Documents\_repo-bundles, which was wrong: it sat on
  the SAME physical disk as the repos it protected, so it covered a rewritten
  remote but not a dead drive -- and those are the two failure modes it exists
  for. B: is physical disk 0 (ST4000DM000, 4 TB); G: is disk 3 (WDC NVMe), so the
  default now survives losing either one.

  It is also deliberately NOT under G:\Documents, so the Backup-Documents
  robocopy /MIR job does not duplicate multi-GB bundles onto the same B: volume
  they already live on.

.PARAMETER Keep
  How many dated snapshots to retain per repo. Default 3.

.EXAMPLE
  powershell -File tools\Backup-RepoBundles.ps1
  powershell -File tools\Backup-RepoBundles.ps1 -Destination D:\repo-bundles -Keep 5

.NOTES
  Invoke with Windows PowerShell 5.1 (powershell.exe); `pwsh` is not installed
  on DEVIL. The no-2>&1 rule below is a 5.1-specific hazard.
#>
[CmdletBinding()]
param(
  [string]$Destination = 'B:\BAKS\repo-bundles',
  [int]$Keep = 3,
  [string]$Root = 'G:\Documents\GIT',
  [string[]]$ExtraRepo = @('G:\Documents\book-writing')
)

$ErrorActionPreference = 'Stop'
# Stamp once so every bundle in a run shares a date and -Keep prunes coherently.
$stamp = Get-Date -Format 'yyyyMMdd'

if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

# Collect repos: everything under $Root with a .git, plus any explicitly named.
$repos = @()
Get-ChildItem $Root -Directory -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq '.git' } | ForEach-Object {
    $repos += [pscustomobject]@{
      Name = $_.Parent.FullName.Replace("$Root\", '') -replace '\\', '__'
      Path = $_.Parent.FullName
    }
  }
foreach ($e in $ExtraRepo) {
  if (Test-Path (Join-Path $e '.git')) {
    $repos += [pscustomobject]@{ Name = (Split-Path $e -Leaf); Path = $e }
  }
}

Write-Host "repos: $($repos.Count)   destination: $Destination   keep: $Keep"
Write-Host ''

$ok = 0; $failed = 0; $failList = @()
foreach ($r in $repos) {
  $out = Join-Path $Destination "$($r.Name).$stamp.bundle"
  try {
    # NOTE: do NOT use 2>&1 on these git calls. Under PowerShell 5.1 redirecting a
    # native command's stderr wraps every line in an ErrorRecord, which with
    # $ErrorActionPreference='Stop' becomes a terminating error even on exit 0.
    # `git bundle verify` prints its SUCCESS message ("<file> is okay") to stderr,
    # so 2>&1 made every successful bundle look like a failure -- and the catch
    # below then deleted it. Suppress stdout only and trust $LASTEXITCODE.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # --all captures every ref (branches AND tags), which is what makes this a
    # real recovery artifact rather than a snapshot of one branch.
    & git -C $r.Path bundle create $out --all | Out-Null
    $rcCreate = $LASTEXITCODE

    # A bundle that cannot be verified is not a backup. Prove it before trusting it.
    if ($rcCreate -eq 0) { & git -C $r.Path bundle verify $out | Out-Null; $rcVerify = $LASTEXITCODE }
    else { $rcVerify = 1 }

    $ErrorActionPreference = $prev

    if ($rcCreate -ne 0) { throw "git bundle create exited $rcCreate" }
    if ($rcVerify -ne 0) { throw "git bundle verify exited $rcVerify" }

    $mb = [math]::Round((Get-Item $out).Length / 1MB, 2)
    "{0,-46} {1,8} MB" -f $r.Name, $mb
    $ok++
  } catch {
    $ErrorActionPreference = 'Stop'
    "{0,-46} FAILED: {1}" -f $r.Name, $_.Exception.Message
    $failed++; $failList += $r.Name
    if (Test-Path $out) { Remove-Item $out -Force }   # never leave an unverified bundle
  }

  # Prune old snapshots for THIS repo only.
  Get-ChildItem $Destination -Filter "$($r.Name).*.bundle" |
    Sort-Object Name -Descending | Select-Object -Skip $Keep |
    ForEach-Object { Remove-Item $_.FullName -Force }
}

$total = [math]::Round((Get-ChildItem $Destination -Filter '*.bundle' | Measure-Object Length -Sum).Sum / 1GB, 2)
Write-Host ''
Write-Host "bundled OK : $ok"
Write-Host "failed     : $failed$(if ($failList) { " -> $($failList -join ', ')" })"
Write-Host "store size : $total GB across $((Get-ChildItem $Destination -Filter '*.bundle').Count) bundles"

if ($failed -gt 0) { exit 1 }
