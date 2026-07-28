<#
.SYNOPSIS
  Bidirectional sync of Claude's identity (memory, steering, skills, agents)
  between DEVIL and the Shield. DEVIL wins conflicts.

.DESCRIPTION
  The Shield's claude-term runs Claude Code, but it knew none of this machine's
  623 memory files, because the only existing sync rail is a PUBLIC repo and so
  can only ever carry public-safe steering. This is the private rail: a direct
  push/pull over ssh on the LAN.

  DIRECTION AND CONFLICT RULE
    1. PULL  the Shield's memory first.
    2. Adopt any file DEVIL does not have -- those are Shield-authored, written
       while you were away, and must not be destroyed.
    3. On same-path conflicts DEVIL wins: it is where deliberate curation
       happens, and a device with a drifted clock must never overwrite a
       considered edit.
    4. PUSH the union back.

  PROJECT KEY REMAPPING
    Claude Code derives a project key from the absolute cwd by replacing every
    non-alphanumeric character with '-'. DEVIL's keys therefore never fire on
    the Shield. The mapping rule is a single path substitution:

        G:\Documents\   <->   /data/claude/
        C:\Users\Quadstronaut  <->  /home/claude

    so  G:\Documents\GIT\LOCAL-mod\NVIDIAShield  ->  /data/claude/GIT/LOCAL-mod/NVIDIAShield
    and G--Documents-GIT-LOCAL-mod-NVIDIAShield  ->  -data-claude-GIT-LOCAL-mod-NVIDIAShield

    Keys with no live counterpart (old drives P:\ and C:\, paths that no longer
    exist) are carried as `_archive-<key>`: preserved and greppable, but they
    match no cwd so they never auto-load.

  TRANSPORT -- read before changing it
    Everything moves as base64, verified by md5 on both ends. This is not
    fussiness; four separate failures in this project traced to Windows text
    encoding crossing into Android:
      - PowerShell's native-command pipe prepends a UTF-8 BOM and re-encodes,
        which corrupted a PAT ("HTTP 401"), corrupted base64 itself
        ("invalid input"), and put `ef bb bf` on every transferred file.
      - Set-Content/Out-File write CRLF, which made every git URL end in \r and
        produced "Repository not found" on all 55 repos.
      - scp cannot be used: dropbear ships no /usr/libexec/sftp-server.
    Uploads are chunked because MAX_ARG_STRLEN caps a single argv entry at
    128 KB, so a multi-megabyte payload cannot be one argument.

.PARAMETER PullOnly
  Only bring Shield-authored memory back to DEVIL. Makes no change on the device.

.PARAMETER PushOnly
  Only send DEVIL's identity out. Skips adoption of Shield-authored memory.

.PARAMETER DryRun
  Report what would change; write nothing on either side.

.EXAMPLE
  powershell -File tools\Sync-ShieldIdentity.ps1 -DryRun
  powershell -File tools\Sync-ShieldIdentity.ps1

.NOTES
  Invoke with Windows PowerShell 5.1 (powershell.exe). `pwsh` is NOT installed on
  DEVIL, and every workaround in this file -- the ASCII-only rule, the cmd.exe
  redirection, the no-2>&1 rule -- exists because of 5.1 specifically.
#>
[CmdletBinding()]
param(
  [switch]$PullOnly,
  [switch]$PushOnly,
  [switch]$DryRun,
  [string]$ShieldHost = 'shield',
  [string]$ClaudeHome = "$env:USERPROFILE\.claude",
  [string]$RepoRoot   = 'G:\Documents\GIT'
)

$ErrorActionPreference = 'Stop'
$VolClaude = '/data/docker/data/volumes/claude-home/_data/.claude'
$Stage     = Join-Path $env:TEMP "shield-identity-$(Get-Random)"
$ChunkSize = 60000   # base64 chars per argv entry; well under MAX_ARG_STRLEN (128 KB)

# The key mapping now lives in ShieldKeyMap.ps1 because Test-ShieldParity.ps1
# needs the identical rule to compare content. Two private copies would silently
# drift, and a gate that fails on correctly-synced memory is worse than no gate.
. (Join-Path $PSScriptRoot 'ShieldKeyMap.ps1')
. (Join-Path $PSScriptRoot 'MemoryMerge.ps1')

function Invoke-Shield([string]$Cmd) {
  $out = & ssh -o BatchMode=yes $ShieldHost $Cmd 2>&1
  if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $out" }
  return $out
}

# --- transport ---------------------------------------------------------------

function Send-File([string]$Local, [string]$Remote) {
  # base64 to a temp file, then ONE hop using cmd.exe's '<' redirection.
  #
  # Why cmd and not PowerShell: PowerShell's native-command pipe re-encodes and
  # prepends a BOM, and PowerShell 5.1 has no '<' operator at all. cmd's
  # redirection passes raw bytes. Verified byte-exact on an 879 KB payload.
  #
  # Why not base64-over-argv here: that works for small files but Windows caps a
  # command line at 32,767 characters, so a multi-hundred-KB payload fails with
  # "The filename or extension is too long". Chunking under that limit would
  # mean ~60 ssh round trips for this payload.
  $tmp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($tmp, [Convert]::ToBase64String([IO.File]::ReadAllBytes($Local)), (New-Object Text.ASCIIEncoding))
    $cl = 'ssh -o BatchMode=yes ' + $ShieldHost + ' "base64 -d > ' + $Remote + '" < "' + $tmp + '"'
    & cmd /c $cl
    if ($LASTEXITCODE -ne 0) { throw "transfer failed (cmd exit $LASTEXITCODE)" }

    $local  = (Get-FileHash $Local -Algorithm MD5).Hash.ToLower()
    $remote = ([string](Invoke-Shield "md5sum < $Remote")).Trim().Split(' ')[0]
    if ($local -ne $remote) { throw "transfer corrupted: $Local (local $local != remote $remote)" }
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Receive-File([string]$Remote, [string]$Local) {
  # Capture base64 on stdout -- safer than a pipe, which PowerShell re-encodes.
  $b64 = (Invoke-Shield "base64 < $Remote") -join ''
  [IO.File]::WriteAllBytes($Local, [Convert]::FromBase64String(($b64 -replace '\s', '')))
  $local  = (Get-FileHash $Local -Algorithm MD5).Hash.ToLower()
  $remote = ([string](Invoke-Shield "md5sum < $Remote")).Trim().Split(' ')[0]
  if ($local -ne $remote) { throw "receive corrupted: $Remote" }
}

# Merge-MemoryIndex lives in MemoryMerge.ps1 so Test-MemoryMerge.ps1 can exercise
# it. Inside this script it could only be tested by running a full device sync,
# which means in practice it would never have been tested at all -- and it is the
# one path that decides whether Shield-authored memory survives.

Write-Host "=== Shield identity sync ===" -ForegroundColor Cyan
Write-Host "host: $ShieldHost   dry-run: $DryRun"
$map    = Get-ShieldKeyMap -RepoRoot $RepoRoot
$revMap = @{}; $map.GetEnumerator() | ForEach-Object { $revMap[$_.Value] = $_.Key }
Write-Host "live path keys: $($map.Count)"

New-Item -ItemType Directory -Path $Stage -Force | Out-Null
try {
  # ========================= PULL =========================
  $adopted = 0; $mergedIdx = 0
  if (-not $PushOnly) {
    Write-Host "`n--- PULL (Shield-authored memory) ---" -ForegroundColor Yellow
    $probe = Invoke-Shield "ls -d $VolClaude/projects/*/memory 2>/dev/null | wc -l"
    $n = [int]([string]$probe).Trim()
    Write-Host "shield memory dirs: $n"

    if ($n -gt 0) {
      Invoke-Shield "cd $VolClaude && tar czf /data/.shield-mem.tgz projects/*/memory 2>/dev/null || true" | Out-Null
      $tgz = Join-Path $Stage 'shield-mem.tgz'
      Receive-File '/data/.shield-mem.tgz' $tgz
      Invoke-Shield 'rm -f /data/.shield-mem.tgz' | Out-Null

      $ex = Join-Path $Stage 'shield'
      New-Item -ItemType Directory -Path $ex -Force | Out-Null
      & tar -xzf $tgz -C $ex
      if ($LASTEXITCODE -ne 0) { throw 'failed to extract shield memory archive' }

      foreach ($pd in Get-ChildItem (Join-Path $ex 'projects') -Directory -ErrorAction SilentlyContinue) {
        # reverse-map, or un-archive an _archive- prefixed key
        $devilKey = if ($revMap.ContainsKey($pd.Name)) { $revMap[$pd.Name] }
                    elseif ($pd.Name -like '_archive-*') { $pd.Name.Substring(9) }
                    else { "shield--$($pd.Name)" }   # Shield-native scratch, kept distinct

        $srcMem = Join-Path $pd.FullName 'memory'
        if (-not (Test-Path $srcMem)) { continue }
        $dstMem = Join-Path $ClaudeHome "projects\$devilKey\memory"

        foreach ($f in Get-ChildItem $srcMem -File) {
          $dst = Join-Path $dstMem $f.Name

          # MEMORY.md is the sole exception to "DEVIL wins". Both sides append to
          # it, so discarding the Shield's copy strands every memory the Shield
          # authored: the file gets adopted, its index pointer does not.
          if ($f.Name -eq 'MEMORY.md' -and (Test-Path $dst)) {
            $u = Merge-MemoryIndex -DevilPath $dst -ShieldPath $f.FullName
            if ($u) {
              Write-Host "  merge: $devilKey/MEMORY.md (Shield-only pointer lines)"
              if (-not $DryRun) {
                [IO.File]::WriteAllText($dst, $u + "`n", (New-Object Text.UTF8Encoding($false)))
              }
              $mergedIdx++
            }
            continue
          }

          if (Test-Path $dst) { continue }   # DEVIL wins; never overwrite
          Write-Host "  adopt: $devilKey/$($f.Name)"
          if (-not $DryRun) {
            New-Item -ItemType Directory -Path $dstMem -Force | Out-Null
            Copy-Item $f.FullName $dst -Force
          }
          $adopted++
        }
      }
    }
    Write-Host "adopted from Shield: $adopted   MEMORY.md merged: $mergedIdx"
  }

  # ========================= PUSH =========================
  if (-not $PullOnly) {
    Write-Host "`n--- PUSH (DEVIL identity -> Shield) ---" -ForegroundColor Yellow
    $out = Join-Path $Stage 'out'
    New-Item -ItemType Directory -Path "$out\projects" -Force | Out-Null

    $mapped = 0; $archived = 0; $files = 0
    foreach ($pd in Get-ChildItem (Join-Path $ClaudeHome 'projects') -Directory) {
      $mem = Join-Path $pd.FullName 'memory'
      if (-not (Test-Path $mem)) { continue }
      if ($map.ContainsKey($pd.Name)) { $shieldKey = $map[$pd.Name]; $mapped++ }
      else                            { $shieldKey = "_archive-$($pd.Name)"; $archived++ }
      $dst = Join-Path $out "projects\$shieldKey\memory"
      New-Item -ItemType Directory -Path $dst -Force | Out-Null
      Copy-Item "$mem\*" $dst -Recurse -Force
      $files += (Get-ChildItem $mem -File).Count
    }
    Write-Host "memory: $files files  ($mapped keys recallable, $archived archived)"

    # CLAUDE.md: drop the sections that are false on the Shield (no ollama, not Windows).
    $md = [IO.File]::ReadAllText((Join-Path $ClaudeHome 'CLAUDE.md'), [Text.Encoding]::UTF8)
    $kept = [regex]::Split($md, '(?m)(?=^## )') | Where-Object { $_ -notmatch '^## (Local LLM offload|Local pre-filter)' }
    $md = ($kept -join '').TrimEnd()
    $md = $md -replace '(?ms)\r?\n\r?\n\*\*Shell selection \(Windows\).*?(?=\r?\n\r?\nAlways batch)', ''
    $md = $md -replace '(?m)^Step \*down\* to \*\*local ollama\*\*.*\r?\n', ''
    $banner = "# Shield Claude - synced from DEVIL ~/.claude`n" +
              "<!-- GENERATED by tools/Sync-ShieldIdentity.ps1. Edit DEVIL's global CLAUDE.md, not this. -->`n" +
              "<!-- Offload + Windows-shell rules stripped: the Shield has no ollama. -->`n`n"
    # Compute the text first: an inline -replace here puts its comma-separated
    # operands into the method's argument list, and WriteAllText gets 4 args.
    $mdOut = ($banner + $md) -replace "`r`n", "`n"
    [IO.File]::WriteAllText((Join-Path $out 'CLAUDE.md'), $mdOut, (New-Object Text.UTF8Encoding($false)))

    # skills + agents, symlinks dereferenced, Windows paths rewritten to Shield paths
    foreach ($d in 'skills', 'agents') {
      $src = Join-Path $ClaudeHome $d
      if (-not (Test-Path $src)) { continue }
      New-Item -ItemType Directory -Path "$out\$d" -Force | Out-Null
      foreach ($e in Get-ChildItem $src -Force) {
        $real = if ($e.LinkType) { Get-Item $e.Target } else { $e }
        Copy-Item $real.FullName (Join-Path "$out\$d" $e.Name) -Recurse -Force
      }
    }
    Get-ChildItem "$out\skills", "$out\agents" -Recurse -File -Include *.md, *.json, *.js, *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
      $t = [IO.File]::ReadAllText($_.FullName)
      $n = $t -replace [regex]::Escape('G:\Documents\GIT'), '/data/claude/GIT' `
              -replace [regex]::Escape('G:\Documents'), '/data/claude' `
              -replace [regex]::Escape("$env:USERPROFILE\.claude"), '/home/claude/.claude' `
              -replace [regex]::Escape($env:USERPROFILE), '/home/claude'
      # normalise the backslashes inside paths we just rewrote
      $n = [regex]::Replace($n, '(/data/claude|/home/claude)(\\[\w.\-\\]+)', { param($m) $m.Groups[1].Value + ($m.Groups[2].Value -replace '\\', '/') })
      if ($n -ne $t) { [IO.File]::WriteAllText($_.FullName, $n, (New-Object Text.UTF8Encoding($false))) }
    }
    # NOTE: compute these first. PowerShell 5.1 cannot parse a nested double-quoted
    # string inside $( ) inside a double-quoted string -- it terminates the outer
    # string early and the whole file fails to parse.
    $nSkills = (Get-ChildItem (Join-Path $out 'skills') -Directory -ErrorAction SilentlyContinue).Count
    $nAgents = (Get-ChildItem (Join-Path $out 'agents') -File -ErrorAction SilentlyContinue).Count
    Write-Host "skills: $nSkills   agents: $nAgents"

    if ($DryRun) {
      Write-Host "`n[dry-run] staged at $out -- nothing sent" -ForegroundColor Green
      return
    }

    $tgz = Join-Path $Stage 'identity.tgz'
    & tar -czf $tgz -C $out .
    if ($LASTEXITCODE -ne 0) { throw 'failed to create identity archive' }
    Write-Host "payload: $([math]::Round((Get-Item $tgz).Length/1KB,1)) KB"

    Send-File $tgz '/data/.identity.tgz'
    # Extract into the volume, then hand ownership to the in-container claude
    # (uid 1000, which Android displays as `system`).
    Invoke-Shield "mkdir -p $VolClaude && tar xzf /data/.identity.tgz -C $VolClaude && chown -R 1000:1000 $VolClaude && rm -f /data/.identity.tgz" | Out-Null

    $check = Invoke-Shield "find $VolClaude/projects -path '*/memory/*' -type f | wc -l"
    $nMem = ([string]$check).Trim()
    Write-Host "memory files now on Shield: $nMem"

    # Freshness stamp. Without this, "is the Shield's identity current?" is
    # unanswerable: file COUNTS can match exactly while content has drifted, so
    # counting proves nothing. /data/claude is the same directory the repo refresh
    # stamps (.last-refresh) -- readable by the gate over ssh AND by the
    # in-container Claude, which is where the user actually is.
    # ASCII, LF, no shell metacharacters: this string crosses PowerShell -> ssh ->
    # Android sh, and every one of those hops has bitten this project before.
    $stamp = "{0} memory={1} skills={2} agents={3}" -f `
             (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $nMem, $nSkills, $nAgents
    Invoke-Shield "echo '$stamp' > /data/claude/.last-identity-sync" | Out-Null
    Write-Host "stamped: $stamp"
  }

  Write-Host "`n=== done ===" -ForegroundColor Cyan
}
finally {
  if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue }
}

# Explicit exit-code contract, because a scheduled caller has nothing else to go
# on: 0 means the identity on the Shield is current, non-zero means it is not.
# Every failure path above is a `throw` under $ErrorActionPreference='Stop', and
# an uncaught throw from `powershell -File` already exits non-zero -- this makes
# the success half just as deliberate rather than "whatever fell out the bottom".
exit 0
