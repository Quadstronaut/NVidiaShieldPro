<#
.SYNOPSIS
  Unit tests for the MEMORY.md merge. Exits non-zero on any failure.

.DESCRIPTION
  This logic decides whether a memory the Shield authored while you were away
  survives the trip back to DEVIL, and it is not exercised by any normal run --
  it only fires when the Shield has written something DEVIL lacks, which had not
  happened yet at the time it was written. Untested code on a path that runs
  rarely and destroys data when wrong is the worst combination in this repo, so
  it gets a test that runs in a second and needs no device.

  Deliberately dependency-free (no Pester): DEVIL has only Windows PowerShell
  5.1 and no module install step, and a test nobody can run is not a test.

.EXAMPLE
  powershell -File tools\Test-MemoryMerge.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MemoryMerge.ps1')

$script:Pass = 0
$script:Fail = 0
$Stage = Join-Path $env:TEMP "memmerge-test-$(Get-Random)"
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

function Write-Lines([string]$Name, [string[]]$Lines) {
  $p = Join-Path $Stage $Name
  [IO.File]::WriteAllText($p, ($Lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
  return $p
}

function It([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    $script:Pass++; Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
  } catch {
    $script:Fail++; Write-Host ("  [FAIL] {0}`n         {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
  }
}
function ShouldBe($Actual, $Expected, [string]$What) {
  if ($Actual -ne $Expected) { throw "$What`n         expected: <$Expected>`n         actual:   <$Actual>" }
}

Write-Host "=== MEMORY.md merge ===" -ForegroundColor Cyan

It 'adopts a Shield-only pointer line' {
  $d = Write-Lines 'd1.md' @('# Memory index', '- [A](a.md) - alpha')
  $s = Write-Lines 's1.md' @('# Memory index', '- [A](a.md) - alpha', '- [B](b.md) - beta')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  if (-not $m) { throw 'returned null; expected a merge' }
  ShouldBe ($m -match '\[B\]\(b\.md\)') $true 'Shield-only line missing from merge'
  ShouldBe (([regex]::Matches($m, '\[A\]\(a\.md\)')).Count) 1 'shared line duplicated'
}

It 'returns null when the Shield adds nothing (no needless rewrite)' {
  $d = Write-Lines 'd2.md' @('# Memory index', '- [A](a.md)', '- [B](b.md)')
  $s = Write-Lines 's2.md' @('# Memory index', '- [A](a.md)')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  ShouldBe ($null -eq $m) $true 'expected null when Shield contributes nothing'
}

It 'a reworded pointer to the SAME target is not duplicated' {
  # Keyed on the link target, not the whole line -- otherwise every reworded
  # description would accumulate a second entry for the same memory.
  $d = Write-Lines 'd3.md' @('- [Docker recipe](docker-on-shield-recipe.md) - old wording')
  $s = Write-Lines 's3.md' @('- [Docker on Shield](docker-on-shield-recipe.md) - NEW wording')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  ShouldBe ($null -eq $m) $true 'reworded duplicate should not be adopted'
}

It 'DEVIL ordering and content are preserved; additions are appended' {
  $d = Write-Lines 'd4.md' @('# Memory index', '- [Z](z.md)', '- [A](a.md)')
  $s = Write-Lines 's4.md' @('- [NEW](new.md)')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  $lines = $m -split "`n"
  ShouldBe $lines[0] '# Memory index' 'heading moved'
  ShouldBe $lines[1] '- [Z](z.md)'    'DEVIL ordering changed'
  ShouldBe $lines[2] '- [A](a.md)'    'DEVIL ordering changed'
  ShouldBe $lines[-1] '- [NEW](new.md)' 'addition not appended last'
}

It 'wiki-style [[links]] are matched too' {
  $d = Write-Lines 'd5.md' @('- see [[shield-transport-gotchas]]')
  $s = Write-Lines 's5.md' @('- see [[shield-transport-gotchas]]', '- see [[brand-new-note]]')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  if (-not $m) { throw 'returned null; expected a merge' }
  ShouldBe (([regex]::Matches($m, 'shield-transport-gotchas')).Count) 1 'wiki link duplicated'
  ShouldBe ($m -match 'brand-new-note') $true 'new wiki link not adopted'
}

It 'link matching is case-insensitive' {
  $d = Write-Lines 'd6.md' @('- [A](Notes.md)')
  $s = Write-Lines 's6.md' @('- [A](notes.md)')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  ShouldBe ($null -eq $m) $true 'case difference treated as a new target'
}

It 'prose and blank lines carry no link and are never adopted' {
  $d = Write-Lines 'd7.md' @('# Memory index')
  $s = Write-Lines 's7.md' @('# Memory index', '', 'some prose with no link at all')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath $s
  ShouldBe ($null -eq $m) $true 'linkless lines should not trigger a merge'
}

It 'no DEVIL file: the Shield copy is adopted whole' {
  $s = Write-Lines 's8.md' @('# Memory index', '- [A](a.md)')
  $m = Merge-MemoryIndex -DevilPath (Join-Path $Stage 'does-not-exist.md') -ShieldPath $s
  ShouldBe ($m -match '\[A\]\(a\.md\)') $true 'Shield-only index not adopted'
}

It 'no Shield file: null, and DEVIL is untouched' {
  $d = Write-Lines 'd9.md' @('- [A](a.md)')
  $m = Merge-MemoryIndex -DevilPath $d -ShieldPath (Join-Path $Stage 'nope.md')
  ShouldBe ($null -eq $m) $true 'expected null when the Shield has no index'
}

Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("PASS: {0}   FAIL: {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
