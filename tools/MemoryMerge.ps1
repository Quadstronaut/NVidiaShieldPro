<#
  MEMORY.md line-level merge. Dot-source this; it defines a function and does
  nothing on its own.

  WHY THIS IS THE ONE EXCEPTION TO "DEVIL WINS"

  Every memory is two writes: the memory file itself, and a pointer line added
  to MEMORY.md, the index that is loaded at session start. The identity sync
  pulls Shield-authored files DEVIL does not have and adopts them -- but
  MEMORY.md always exists on both sides, so the plain rule discarded the
  Shield's copy wholesale and the pointer line went with it. The memory arrived
  on DEVIL orphaned from the index that makes it findable, which for an
  index-loaded-at-start file is close to not arriving at all.

  Union by LINK TARGET rather than by whole line, so a reworded pointer to the
  same memory does not produce a duplicate entry. DEVIL's ordering is preserved
  and Shield-only lines are appended, because DEVIL is where deliberate curation
  happens and a reordered index is a worse diff than an appended one.

  Lives in its own file so Test-MemoryMerge.ps1 can exercise it. Inside
  Sync-ShieldIdentity.ps1 it could only be tested by running a full device sync,
  which means in practice it would never have been tested at all.

  ASCII-only: PowerShell 5.1 reads a BOM-less UTF-8 .ps1 as ANSI, and one
  em-dash decodes to a byte that terminates a string literal.
#>

function Get-MemoryLinkKey {
  <#
    The link target a pointer line refers to, lowercased, or $null for a line
    that points at nothing (headings, blank lines, prose).
    Handles both `[[wiki-style]]` and `[text](target.md)` forms.
  #>
  param([string]$Line)
  if ($Line -match '\[\[([^\]]+)\]\]') { return $Matches[1].Trim().ToLower() }
  if ($Line -match '\]\(([^)]+)\)')    { return $Matches[1].Trim().ToLower() }
  return $null
}

function Merge-MemoryIndex {
  <#
    Returns the merged text when the Shield contributed at least one pointer
    line DEVIL lacks, otherwise $null to mean "leave DEVIL's file alone".
    Returning $null rather than an identical string keeps the caller from
    rewriting a file it did not change.
  #>
  param(
    [Parameter(Mandatory)][string]$DevilPath,
    [Parameter(Mandatory)][string]$ShieldPath
  )

  if (-not (Test-Path $ShieldPath)) { return $null }
  $shieldLines = [IO.File]::ReadAllLines($ShieldPath)

  # No DEVIL-side file at all: the Shield's copy is simply adopted.
  if (-not (Test-Path $DevilPath)) { return ($shieldLines -join "`n") }
  $devilLines = [IO.File]::ReadAllLines($DevilPath)

  $seen = @{}
  foreach ($l in $devilLines) {
    $k = Get-MemoryLinkKey $l
    if ($k) { $seen[$k] = $true }
  }

  $added = @()
  foreach ($l in $shieldLines) {
    $k = Get-MemoryLinkKey $l
    if ($k -and -not $seen.ContainsKey($k)) { $added += $l; $seen[$k] = $true }
  }

  if ($added.Count -eq 0) { return $null }
  return ((($devilLines -join "`n").TrimEnd()) + "`n" + ($added -join "`n"))
}
