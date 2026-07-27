<#
  Shared DEVIL <-> Shield project-key mapping. Dot-source this; it defines
  functions and does nothing on its own.

  WHY IT IS SHARED
    Claude Code derives a project's memory key from its absolute cwd by replacing
    every non-alphanumeric character with '-'. DEVIL's keys therefore never fire
    on the Shield and must be rewritten in transit.

    Two tools need the identical mapping: Sync-ShieldIdentity.ps1 applies it, and
    Test-ShieldParity.ps1 must reverse it to compare content. When each carried
    its own copy, any divergence produced a gate that failed on correctly-synced
    memory -- a false alarm that trains you to ignore the gate, which is worse
    than having no gate.

  THE RULE
    A single path substitution, from which every key rewrite follows:

        G:\Documents\          <->  /data/claude/
        C:\Users\<user>        <->  /home/claude

    so  G:\Documents\GIT\LOCAL-mod\NVIDIAShield  ->  /data/claude/GIT/LOCAL-mod/NVIDIAShield
    and G--Documents-GIT-LOCAL-mod-NVIDIAShield  ->  -data-claude-GIT-LOCAL-mod-NVIDIAShield

    Stated as a rule rather than a table on purpose: it decides where any FUTURE
    repo lands with no fresh judgement call, and keeps the Shield a faithful
    mirror rather than an invention. book-writing is the case that proves it --
    it sits outside the GIT tree on DEVIL, so it sits outside it on the Shield.

  ASCII-only: PowerShell 5.1 reads a BOM-less UTF-8 .ps1 as ANSI, and one
  em-dash decodes to a byte that terminates a string literal.
#>

function ConvertTo-ClaudeKey {
  # Claude Code's own transform: every non-alphanumeric character becomes '-'.
  param([Parameter(Mandatory)][string]$Path)
  return ($Path -replace '[^A-Za-z0-9]', '-')
}

function Get-ShieldKeyMap {
  <#
    Returns a hashtable of DEVIL project key -> Shield project key, covering
    every repo that currently exists plus the three fixed paths.

    Only LIVE repos are mapped. A key with no live counterpart is not this
    function's business: callers archive it as `_archive-<key>` so it is
    preserved and greppable but matches no cwd, and so never auto-loads.
  #>
  param(
    [string]$RepoRoot    = 'G:\Documents\GIT',
    [string]$UserProfile = $env:USERPROFILE
  )

  $map = @{}

  # Depth 2 finds GIT\<CATEGORY>\<repo>\.git. A repo nested deeper is not part of
  # the layout and is intentionally out of scope.
  Get-ChildItem $RepoRoot -Directory -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq '.git' } | ForEach-Object {
      $rel = $_.Parent.FullName.Replace("$RepoRoot\", '') -replace '\\', '/'
      $map[(ConvertTo-ClaudeKey "$RepoRoot\$($rel -replace '/','\')")] = (ConvertTo-ClaudeKey "/data/claude/GIT/$rel")
    }

  $map[(ConvertTo-ClaudeKey $RepoRoot)]                   = (ConvertTo-ClaudeKey '/data/claude/GIT')
  $map[(ConvertTo-ClaudeKey 'G:\Documents\book-writing')] = (ConvertTo-ClaudeKey '/data/claude/book-writing')
  $map[(ConvertTo-ClaudeKey $UserProfile)]                = (ConvertTo-ClaudeKey '/home/claude')

  return $map
}

function Get-ShieldReverseKeyMap {
  param(
    [string]$RepoRoot    = 'G:\Documents\GIT',
    [string]$UserProfile = $env:USERPROFILE
  )
  $rev = @{}
  (Get-ShieldKeyMap -RepoRoot $RepoRoot -UserProfile $UserProfile).GetEnumerator() |
    ForEach-Object { $rev[$_.Value] = $_.Key }
  return $rev
}
