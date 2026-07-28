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
  powershell -File tools\Test-ShieldParity.ps1
  powershell -File tools\Test-ShieldParity.ps1 -Quick

.NOTES
  Invoke with Windows PowerShell 5.1 (powershell.exe); `pwsh` is not installed on
  DEVIL. The ASCII-only rule and the no-2>&1 rule below are both 5.1-specific.
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

# Same key mapping the sync applies, so the content check below can reverse it.
# Shared rather than reimplemented: a gate using a slightly different rule fails
# on correctly-synced memory, and a gate that cries wolf gets ignored.
. (Join-Path $PSScriptRoot 'ShieldKeyMap.ps1')

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
  # Write-Host, not pipeline output: callers use `| Out-Null` to discard the
  # boolean return, which would swallow an emitted string too and leave the
  # tool silent about the very thing it exists to report.
  if ($ok) {
    $script:Pass++
    Write-Host ("  [PASS] {0,-44} {1}" -f $Name, $detail) -ForegroundColor Green
  } else {
    $script:Fail++; $script:Failures += $Name
    Write-Host ("  [FAIL] {0,-44} {1}" -f $Name, $detail) -ForegroundColor Red
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
# The claude-home volume's real host path. The docker data-root is /data/docker/data,
# not the default, and the driver is `local`, so this is a genuine host directory
# readable over ssh without entering the container.
$VolProjects = '/data/docker/data/volumes/claude-home/_data/.claude/projects'
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
Check 'claude-term container has an OAuth token' {
  # Checked on the RUNNING container, not the launcher script. An empty token
  # produces a container that comes up healthy, serves the UI, and then demands
  # /login on the first turn -- which reads as "Claude is broken", not as a
  # provisioning miss. Presence only; the value is never printed.
  $r = Sh "$D inspect -f '{{range .Config.Env}}{{println .}}{{end}}' claude-term"
  $line = ($r.Out -split "`n" | Where-Object { $_ -like 'CLAUDE_CODE_OAUTH_TOKEN=*' })
  $set = $line -and (($line -join '') -replace '^CLAUDE_CODE_OAUTH_TOKEN=', '').Trim().Length -gt 20
  [pscustomobject]@{ ok = [bool]$set; detail = $(if ($set) { 'present' } else { 'EMPTY - Claude will demand /login on first turn' }) }
} | Out-Null

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

Check 'every repo is trust-accepted (no blocking prompt)' {
  # THE check this whole tool existed to have and did not.
  #
  # An un-accepted cwd stops a claude-code session with a trust prompt before the
  # user can type anything, and that prompt is not answerable on the
  # tmux->browser->phone path. 54 of 55 repos were in that state while this gate
  # reported 17/17, because nothing here ever looked. "Present on disk" and
  # "usable" are different properties; only the second one is the point.
  #
  # Done in node rather than shell: it parses the same JSON claude-code reads, so
  # it cannot disagree with it about what "trusted" means.
  #
  # Shipped BASE64 THROUGH ARGV, not as literal source. PowerShell 5.1 strips
  # embedded double quotes when handing a command to native ssh, so the JS
  # arrived as require(fs) and node died on "Invalid regular expression flags"
  # -- a failure that reads like a device problem and is not. Base64 is
  # [A-Za-z0-9+/=] only: nothing for PowerShell or sh to reinterpret. `node -`
  # then takes the program on stdin.
  #
  # Rule for anything added to this file: no double quotes inside a command
  # passed to Sh/InContainer. Single quotes survive; double quotes do not.
  $js = 'const fs=require("fs");let c={};try{c=JSON.parse(fs.readFileSync("/home/claude/.claude.json"))}catch(e){}' +
        'const t=c.projects||{};const want=[];' +
        'try{for(const cat of fs.readdirSync("/data/claude/GIT")){const cp="/data/claude/GIT/"+cat;' +
        'if(!fs.statSync(cp).isDirectory())continue;' +
        'for(const r of fs.readdirSync(cp)){const rp=cp+"/"+r;if(fs.existsSync(rp+"/.git"))want.push(rp)}}}catch(e){}' +
        'if(fs.existsSync("/data/claude/book-writing/.git"))want.push("/data/claude/book-writing");' +
        'const m=want.filter(d=>!(t[d]&&t[d].hasTrustDialogAccepted));' +
        'console.log(want.length+" "+m.length+" "+m.slice(0,3).map(x=>x.split("/").pop()).join(","));'
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($js))
  $r = Sh "$D exec -u claude claude-term sh -c 'echo $b64 | base64 -d | node -'"
  $p = ($r.Out -split ' ')
  $want = [int]$p[0]; $miss = [int]$p[1]
  [pscustomobject]@{ ok = ($want -gt 0 -and $miss -eq 0)
                     detail = $(if ($miss -gt 0) { "$miss of $want repos WILL PROMPT (e.g. $($p[2]))" } else { "all $want trusted" }) }
} | Out-Null

Check 'new-session picker can reach every repo' {
  # The actual reason "use my Claude on the Shield" did not work, and nothing
  # here ever looked. /api/dirs is what the phone UI offers as a working
  # directory; it returned six entries, of which exactly one was a git repo and
  # none were among the 55 projects. Everything else was green at the time.
  #
  # Asserted against the live HTTP endpoint rather than the source, because what
  # matters is what the running container serves to the browser.
  $want = [int](Sh 'find /data/claude/GIT -maxdepth 3 -name .git -type d | wc -l').Out.Trim()
  try { $dirs = Invoke-RestMethod "http://10.0.0.88:7777/api/dirs" -TimeoutSec 15 } catch { $dirs = @() }
  $repoish = @($dirs | Where-Object { $_ -like '/data/claude/GIT/*/*' })
  [pscustomobject]@{ ok = ($repoish.Count -ge $want -and $want -gt 0)
                     detail = "picker offers $($repoish.Count) of $want repos ($($dirs.Count) entries total)" }
} | Out-Null

Check 'ssh origins are rewritten to https for the PAT' {
  # Work that cannot leave the device is not work, and book-writing -- the repo
  # the user explicitly moved here to write on -- could not fetch or push from
  # inside the container: "Host key verification failed". Its origin is
  # git@github.com:, and the deploy keys are deliberately kept OUTSIDE the
  # container mount, so there was no key to offer and no known_hosts to check.
  #
  # The fix is a container-scoped insteadOf rewrite, NOT editing origins.
  # Rewriting each repo's stored origin to https would have broken the host-side
  # /data/book-git.sh, which drives the SAME repo through alpine/git with the
  # deploy key -- that path is a different container with its own config and
  # never sees this rule. One rule, both transports intact, no repo mutated, and
  # it covers every ssh origin that ever appears rather than the ones we noticed.
  $r = InContainer 'git config --global --get url.https://github.com/.insteadOf'
  [pscustomobject]@{ ok = ($r.Out.Trim() -eq 'git@github.com:'); detail = $(if ($r.Out) { $r.Out.Trim() } else { 'RULE MISSING - ssh-origin repos cannot push' }) }
} | Out-Null

if (-not $Quick) {
  Check 'book-writing actually reachable from in-container' {
    # The end-to-end proof of the rule above, on the repo that was broken. Checked
    # by ls-remote rather than by config, because "the setting is present" and
    # "the network call succeeds" are different claims and only the second is the
    # one the user cares about.
    $r = InContainer 'git -C /data/claude/book-writing ls-remote --heads origin >/dev/null 2>&1 && echo OK || echo FAIL'
    [pscustomobject]@{ ok = ($r.Out -eq 'OK'); detail = $r.Out }
  } | Out-Null
}

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

if (-not $Quick) {
  Check 'memory CONTENT matches, not just the count' {
    # Counting proved nothing. On 2026-07-26 this gate read shield=625 devil=625
    # and passed, while six DEVIL memory files had newer content the Shield had
    # never seen -- because the sync had not run since the day it was written and
    # nothing measured content. Equal counts are exactly what drift looks like
    # once both sides have stopped gaining files.
    #
    # Compare a path->md5 map. All normalisation happens here, on one side, in one
    # language: the device only runs md5sum. Doing the sorting or hashing on both
    # sides invites a spurious mismatch from locale collation or line endings.
    $r = Sh "cd $VolProjects && find . -path '*/memory/*' -type f | xargs md5sum"
    if ($r.Rc -ne 0) { return [pscustomobject]@{ ok = $false; detail = 'could not read device manifest' } }

    $shield = @{}
    foreach ($line in ($r.Out -split "`n")) {
      if ($line -match '^\s*([0-9a-f]{32})\s+\./(.+)$') { $shield[$Matches[2].Trim()] = $Matches[1] }
    }

    $map = Get-ShieldKeyMap -RepoRoot $RepoRoot
    $devil = @{}
    foreach ($pd in Get-ChildItem (Join-Path $ClaudeHome 'projects') -Directory) {
      $mem = Join-Path $pd.FullName 'memory'
      if (-not (Test-Path $mem)) { continue }
      $sk = if ($map.ContainsKey($pd.Name)) { $map[$pd.Name] } else { "_archive-$($pd.Name)" }
      foreach ($f in Get-ChildItem $mem -File) {
        $devil["$sk/memory/$($f.Name)"] = (Get-FileHash $f.FullName -Algorithm MD5).Hash.ToLower()
      }
    }

    # Shield-only files are NOT a failure: those are memories the Shield authored
    # and the next pull will adopt. Only missing-or-stale on the device is drift.
    $missing = @($devil.Keys | Where-Object { -not $shield.ContainsKey($_) })
    $stale   = @($devil.Keys | Where-Object { $shield.ContainsKey($_) -and $shield[$_] -ne $devil[$_] })
    $extra   = @($shield.Keys | Where-Object { -not $devil.ContainsKey($_) })

    $bad = $missing.Count + $stale.Count
    $detail = if ($bad -eq 0) {
      "$($devil.Count) files identical" + $(if ($extra.Count) { ", $($extra.Count) shield-authored" } else { '' })
    } else {
      "$($stale.Count) stale, $($missing.Count) missing (e.g. $(@($stale + $missing)[0]))"
    }
    [pscustomobject]@{ ok = ($bad -eq 0); detail = $detail }
  } | Out-Null
}

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

Check 'identity sync ran within 48h' {
  # The repo refresh had a stamp and an age assertion from the start; the identity
  # rail had neither, so "when did the Shield last learn anything from DEVIL?" was
  # unanswerable and the answer turned out to be "once, a day and a half ago, by
  # hand". Same stamp, same window, same directory.
  $r = Sh 'cat /data/claude/.last-identity-sync 2>/dev/null | head -1'
  if (-not $r.Out) { return [pscustomobject]@{ ok = $false; detail = 'never run (no stamp)' } }
  $stampText = ($r.Out -split ' ')[0]
  try { $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($stampText).ToUniversalTime() }
  catch { return [pscustomobject]@{ ok = $false; detail = "unparseable: $($r.Out)" } }
  [pscustomobject]@{ ok = ($age.TotalHours -lt 48); detail = "$([math]::Round($age.TotalHours,1))h ago" }
} | Out-Null

Check 'exactly one refresh supervisor (no stacked loops)' {
  # repo-refresh-svc.sh is setsid'd, so it has its own session and survives an init
  # restart of the dockerd service -- and dockerd-svc.sh used to respawn it
  # unconditionally. boot.log records three dockerd-svc starts inside two minutes,
  # so this stacked in practice. Two loops means two concurrent `git fetch` passes
  # over the same 55 clones: .git/index.lock collisions, one interleaved log, and a
  # race to write .last-refresh -- after which the freshness check above happily
  # reads a stamp from a refresh that never coherently completed.
  $r = Sh "/data/docker/bin/busybox ps -ef | grep '[r]epo-refresh-svc' | wc -l"
  $n = [int]($r.Out.Trim())
  [pscustomobject]@{ ok = ($n -eq 1); detail = $(if ($n -eq 1) { '1 loop' } else { "$n loops (want exactly 1)" }) }
} | Out-Null

Check 'device scripts match the repo' {
  # /data/docker/*.sh are what the device actually boots. They were hand-copied
  # once, and the deploy rail pulled the repo without ever installing from it, so
  # the repo was the source of truth for nothing. deploy/install-device-scripts.sh
  # now closes that; this asserts it stayed closed.
  # No double quotes anywhere: PowerShell 5.1 strips them before ssh sees them,
  # which turned `[ "$a" = "$b" ]` into `[ $a = $b ]`. md5sum reading stdin
  # prints "<hash>  -", so the unquoted form word-split into four tokens and
  # every single file reported as drifted -- seven false alarms and no real ones.
  # cut -c1-32 takes just the hash (no space-delimiter to quote), and the x$a
  # idiom keeps the test single-token even when a file is missing entirely.
  $cmd = 'd=0; for f in dockerd-svc.sh repo-refresh.sh repo-refresh-svc.sh dropbear.sh claude-term.sh c2.sh kuma-netfix.sh; do ' +
         'a=$(md5sum < /data/NVidiaShieldPro/docker-bringup/$f 2>/dev/null | cut -c1-32); ' +
         'b=$(md5sum < /data/docker/$f 2>/dev/null | cut -c1-32); ' +
         '[ x$a = x$b ] || { d=$((d+1)); echo DRIFT:$f; }; done; echo TOTAL=$d'
  $r = Sh $cmd
  $drift = if ($r.Out -match 'TOTAL=(\d+)') { [int]$Matches[1] } else { -1 }
  $names = (($r.Out -split "`n") | Where-Object { $_ -match '^DRIFT:' }) -replace '^DRIFT:', ''
  [pscustomobject]@{ ok = ($drift -eq 0); detail = $(if ($drift -eq 0) { 'in sync' } else { "$drift drifted: $($names -join ' ')" }) }
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
