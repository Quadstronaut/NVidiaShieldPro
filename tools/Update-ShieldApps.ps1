<#
.SYNOPSIS
    Checks and performs SAFE in-place upgrades of the official YouTube for Android TV
    and Plex apps on an NVIDIA Shield over network ADB. Fully dynamic and robust.

.DESCRIPTION
    Source of truth is APKMirror (Plex ships no standalone APK; the YouTube TV client
    isn't on Aptoide). Key robustness facts baked in from investigation:

    * APKMirror sits behind Cloudflare, which blocks PowerShell's TLS fingerprint -> all
      HTTP goes through curl.exe (whose fingerprint passes). Requests are paced to avoid
      rate-limiting.

    * Upgrades are gated on versionCode, never the version string. The official
      com.google.android.youtube.tv has TWO lineages on APKMirror: a legacy line
      (5.x / 7.x, code ~5-7e8) and a newer REWRITE (2.x, code ~2e7). The rewrite's code
      is LOWER, so Android refuses to install it over a legacy build. This script reads
      each candidate's real versionCode from APKMirror's release table and only installs
      when candidate.versionCode > installed.versionCode.

    * Google encodes ABI in the versionCode tail (...320 armeabi-v7a, ...330 arm64-v8a,
      ...360 x86). Variants also differ by minimum Android version. The script parses
      arch + min-Android + versionCode + bundle/APK per variant from the release table,
      then picks the best variant that is ABI-compatible AND minSdk <= device SDK,
      preferring a single APK and arm64.

    * Signature pinning: the downloaded APK's signing cert SHA-256 must match the
      installed app's cert (genuine Google / Plex key) before install. Android enforces
      this too, but we fail early and clearly. Never uninstalls anything.

.PARAMETER DryRun  Evaluate and report only; no install. (Still downloads the winner to verify.)
.EXAMPLE  .\Update-ShieldApps.ps1 -DryRun
.EXAMPLE  .\Update-ShieldApps.ps1
#>
[CmdletBinding()]
param(
    [string]   $DeviceMac      = '',   # set to your Shield's eth0 MAC for ARP-based IP discovery, or just pass -KnownIp 10.0.0.88
    [int]      $AdbPort        = 5555,
    [string]   $KnownIp,
    [int]      $ReleasesToScan = 6,
    [ValidateSet('YouTubeTV', 'Plex')]
    [string[]] $Apps           = @('YouTubeTV', 'Plex'),
    [switch]   $DryRun,
    [int]      $ThrottleMs     = 1200,
    [string]   $WorkDir        = (Join-Path $env:TEMP 'shield-apps'),
    [string]   $CacheFile      = (Join-Path $PSScriptRoot 'Update-ShieldApps.cache.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

$Catalog = @{
    YouTubeTV = @{
        Name      = 'YouTube for Android TV'
        Package   = 'com.google.android.youtube.tv'
        AppUrl    = 'https://www.apkmirror.com/apk/google-inc/youtube-for-android-tv-android-tv/'
        ReleaseRx = '/apk/google-inc/youtube-for-android-tv-android-tv/youtube-for-android-tv[a-z0-9-]*-release/'
    }
    Plex = @{
        Name      = 'Plex'
        Package   = 'com.plexapp.android'
        AppUrl    = 'https://www.apkmirror.com/apk/plex-inc/plex/'
        ReleaseRx = '/apk/plex-inc/plex/plex-[0-9a-z-]+-release/'
    }
}

# Android marketing version -> API level (for parsing "Android X+" in the variant table)
$ApiMap = @{
    '4.0'=14;'4.0.3'=15;'4.1'=16;'4.2'=17;'4.3'=18;'4.4'=19;'4.4W'=20;'5.0'=21;'5.1'=22;
    '6.0'=23;'7.0'=24;'7.1'=25;'8.0'=26;'8.1'=27;'9'=28;'9.0'=28;'10'=29;'11'=30;'12'=31;
    '12L'=32;'13'=33;'14'=34;'15'=35;'16'=36;'17'=37
}

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host ("[{0}] {1,-4} {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Msg) -ForegroundColor $color
}

function ConvertTo-Api {
    param([string]$Ver)
    if (-not $Ver) { return 99 }
    $v = $Ver.Trim()
    if ($ApiMap.ContainsKey($v)) { return $ApiMap[$v] }
    $maj = $v -replace 'L$',''
    if ($ApiMap.ContainsKey($maj)) { return $ApiMap[$maj] }
    if ($v -match '^(\d+)') {
        $n = [int]$Matches[1]
        if ($n -ge 13) { return ($n + 20) }   # 13->33 .. 16->36
        if ($n -ge 9)  { return ($n + 19) }   # 9->28 .. 12->31
    }
    return 99   # unknown -> treat as incompatible (safe)
}

# --------------------------------------------------------------------------- tools
function Resolve-Tools {
    $t = @{}
    foreach ($n in 'adb','curl','nmap') { $c = Get-Command $n -ErrorAction SilentlyContinue; if ($c) { $t[$n] = $c.Source } }
    if (-not $t.adb)  { throw "adb not found on PATH." }
    if (-not $t.curl) { $sys = Join-Path $env:WINDIR 'System32\curl.exe'; if (Test-Path $sys) { $t.curl = $sys } else { throw "curl.exe not found (needed to pass Cloudflare)." } }

    $btRoots = New-Object System.Collections.Generic.List[string]
    $btRoots.Add((Join-Path (Split-Path (Split-Path $t.adb -Parent) -Parent) 'build-tools'))
    $btRoots.Add((Join-Path $env:USERPROFILE 'scoop\apps\android-clt\current\build-tools'))
    foreach ($r in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) { if ($r) { $btRoots.Add((Join-Path $r 'build-tools')) } }
    $best = $null
    foreach ($bt in ($btRoots | Select-Object -Unique)) {
        if (-not (Test-Path $bt)) { continue }
        foreach ($d in (Get-ChildItem $bt -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $d.FullName 'aapt.exe'))) { continue }
            try { $v = [version]$d.Name } catch { $v = [version]'0.0' }
            if (-not $best -or $v -gt $best.Ver) { $best = @{ Ver=$v; Dir=$d.FullName } }
        }
    }
    if ($best) {
        $t.aapt = Join-Path $best.Dir 'aapt.exe'
        $sig = Join-Path $best.Dir 'apksigner.bat'; if (Test-Path $sig) { $t.apksigner = $sig }
    }
    if (-not $t.aapt) { $c = Get-Command aapt -ErrorAction SilentlyContinue; if ($c) { $t.aapt = $c.Source } }
    if (-not $t.nmap)      { Write-Log "nmap not found; discovery limited to ARP cache." 'WARN' }
    if (-not $t.aapt)      { Write-Log "aapt not found; bundle inspection limited." 'WARN' }
    if (-not $t.apksigner) { Write-Log "apksigner not found; relying on Android's own signature check." 'WARN' }
    return $t
}

# --------------------------------------------------------------------------- curl (paced)
function Invoke-Throttle { if ($script:LastReq) { $d = ((Get-Date) - $script:LastReq).TotalMilliseconds; if ($d -lt $ThrottleMs) { Start-Sleep -Milliseconds ([int]($ThrottleMs - $d)) } }; $script:LastReq = Get-Date }

function Curl-Text {
    param([string]$Url, [string]$Referer)
    Invoke-Throttle
    $a = @('-sS','-L','--compressed','-A',$script:UA,'-b',$script:Jar,'-c',$script:Jar)
    if ($Referer) { $a += @('-e',$Referer) }
    $a += $Url
    return ((& $script:Tools.curl @a 2>$null) -join "`n")
}
function Curl-File {
    param([string]$Url, [string]$Referer, [string]$OutFile)
    Invoke-Throttle
    $a = @('-sS','-L','--retry','3','--retry-delay','2','-A',$script:UA,'-b',$script:Jar,'-c',$script:Jar,'-o',$OutFile,'-w','%{http_code}')
    if ($Referer) { $a += @('-e',$Referer) }
    $a += $Url
    return [string]((& $script:Tools.curl @a 2>$null) | Select-Object -Last 1)
}

# --------------------------------------------------------------------------- device
function Normalize-Hex { param([string]$m) ($m -replace '[:\-\s]','').ToLower() }
function Get-LocalSubnets {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and $_.PrefixLength -ge 16 } |
        ForEach-Object { ($_.IPAddress -split '\.')[0..2] -join '.' } | Select-Object -Unique
}
function Find-ShieldIp {
    param([string]$Mac)
    $target = Normalize-Hex $Mac
    foreach ($line in (arp -a 2>$null)) {
        if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5})' -and (Normalize-Hex $Matches[2]) -eq $target) { return $Matches[1] }
    }
    if ($script:Tools.nmap) {
        foreach ($net in Get-LocalSubnets) {
            Write-Log "Scanning $net.0/24 for the Shield ($Mac)..." 'STEP'
            $ip = $null
            foreach ($l in (& $script:Tools.nmap -sn -T4 "$net.0/24" 2>$null)) {
                if ($l -match 'Nmap scan report for .*?(\d{1,3}(?:\.\d{1,3}){3})') { $ip = $Matches[1] }
                elseif ($l -match 'MAC Address:\s*([0-9A-Fa-f:]{17})' -and (Normalize-Hex $Matches[1]) -eq $target -and $ip) { return $ip }
            }
        }
    }
    return $null
}
function Connect-Shield {
    $adb = $script:Tools.adb
    foreach ($l in (& $adb devices 2>$null)) { if ($l -match ('^(\S+:' + $AdbPort + ')\s+device')) { Write-Log "ADB already connected: $($Matches[1])" 'OK'; return $Matches[1] } }
    $ip = if ($KnownIp) { $KnownIp } else { Find-ShieldIp -Mac $DeviceMac }
    if (-not $ip) { throw "Could not locate the Shield (MAC $DeviceMac). Is it on with network ADB enabled?" }
    $serial = "${ip}:$AdbPort"
    Write-Log "Connecting to $serial ..." 'STEP'
    & $adb connect $serial *>$null; Start-Sleep -Milliseconds 600
    if ((& $adb -s $serial get-state 2>$null) -ne 'device') { throw "ADB connect to $serial failed. Approve the RSA prompt on the TV if shown." }
    Write-Log "Connected: $serial" 'OK'; return $serial
}
function Get-DeviceProps {
    param([string]$Serial)
    $adb = $script:Tools.adb
    $abilist = (& $adb -s $Serial shell getprop ro.product.cpu.abilist 2>$null).Trim()
    $sdk     = [int]((& $adb -s $Serial shell getprop ro.build.version.sdk 2>$null).Trim())
    $density = 0; $d = (& $adb -s $Serial shell wm density 2>$null) -join "`n"; if ($d -match '(\d+)') { $density = [int]$Matches[1] }
    return @{ Abis = @($abilist -split ',' | Where-Object { $_ }); Sdk = $sdk; Density = $density }
}
function Get-InstalledApp {
    param([string]$Serial, [string]$Package)
    $dump = (& $script:Tools.adb -s $Serial shell dumpsys package $Package 2>$null) -join "`n"
    if ($dump -notmatch 'versionCode=') { return $null }
    $vc = if ($dump -match 'versionCode=(\d+)')   { [int64]$Matches[1] } else { 0 }
    $vn = if ($dump -match 'versionName=([^\s]+)') { $Matches[1] } else { '?' }
    $sig = if ($dump -match 'Signatures:\s*\[([0-9A-Fa-f:]+)\]') { Normalize-Hex $Matches[1] } else { $null }
    return @{ VersionCode = $vc; VersionName = $vn; Signer = $sig }
}
function Get-DensityBucket {
    param([int]$Density)
    $map = [ordered]@{ 120='ldpi';160='mdpi';213='tvdpi';240='hdpi';320='xhdpi';480='xxhdpi';640='xxxhdpi' }
    $best='xhdpi'; $bd=[int]::MaxValue
    foreach ($k in $map.Keys) { $diff=[math]::Abs([int]$k-$Density); if ($diff -lt $bd){$bd=$diff;$best=$map[$k]} }
    return $best
}

# --------------------------------------------------------------------------- APKMirror parsing
function Get-ReleaseUrls {
    param([hashtable]$App, [int]$Count)
    $html = Curl-Text -Url $App.AppUrl
    if (-not $html) { throw "Failed to load APKMirror app page for $($App.Name)." }
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($html, $App.ReleaseRx)) {
        $u = 'https://www.apkmirror.com' + $m.Value
        if (-not $seen.Contains($u)) { $seen.Add($u) }
        if ($seen.Count -ge $Count) { break }
    }
    return $seen
}

# Parse the release-page variant table -> one object per variant.
function Get-ReleaseVariants {
    param([string]$ReleaseUrl)
    $html = Curl-Text -Url $ReleaseUrl
    if (-not $html) { return @() }
    $out = @()
    foreach ($chunk in ($html -split '(?i)<div class="table-row')) {
        if ($chunk -notmatch '-android-apk-download/') { continue }
        $link = [regex]::Match($chunk, '/apk/[^"'']*?-android-apk-download/').Value
        if (-not $link) { continue }
        $text = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($chunk, '<[^>]+>', ' ')))
        $arch = ([regex]::Match($text, 'arm64-v8a|armeabi-v7a|x86_64|x86|universal|noarch')).Value
        $minApi = $null
        $am = [regex]::Match($text, 'Android\s+([0-9]+(?:\.[0-9]+)?L?)\s*\+')
        if ($am.Success) { $minApi = ConvertTo-Api $am.Groups[1].Value }
        $vc = $null
        $vm = [regex]::Match($text, '(\d{6,12})\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)')
        if ($vm.Success) { $vc = [int64]$vm.Groups[1].Value }
        $bundle = ($text -match '\bBUNDLE\b')
        if ($link -and $vc) {
            $out += [pscustomobject]@{
                Url = 'https://www.apkmirror.com' + $link; Arch = $arch
                MinApi = (&{ if ($null -eq $minApi) { 99 } else { $minApi } }); VersionCode = $vc; Bundle = $bundle
            }
        }
    }
    return $out
}

# Choose the best device-compatible variant from a release: APK over bundle, arm64 over v7a, then highest code.
function Select-BestVariant {
    param([object[]]$Variants, [hashtable]$Dev)
    $wild = @('universal','noarch','')
    $rank = @{ 'arm64-v8a'=0; 'armeabi-v7a'=1; 'universal'=2; 'noarch'=2; ''=3 }
    $ok = $Variants | Where-Object {
        ($_.MinApi -le $Dev.Sdk) -and ( ($Dev.Abis -contains $_.Arch) -or ($wild -contains $_.Arch) ) -and ($_.Arch -notmatch '^x86')
    }
    if (-not $ok) { return $null }
    return $ok | Sort-Object `
        @{ Expression = { if ($_.Bundle) {1} else {0} } }, `
        @{ Expression = { if ($rank.ContainsKey($_.Arch)) { $rank[$_.Arch] } else { 5 } } }, `
        @{ Expression = { $_.VersionCode }; Descending = $true } | Select-Object -First 1
}

# Walk variant page -> /download/?key= -> download.php, download to $OutFile. Returns $true on a valid zip/apk.
function Download-Variant {
    param([string]$VariantUrl, [string]$ReleaseUrl, [string]$OutFile)
    $vhtml = Curl-Text -Url $VariantUrl -Referer $ReleaseUrl
    $km = [regex]::Match($vhtml, [regex]::Escape($VariantUrl.Replace('https://www.apkmirror.com','')) + 'download/\?key=[a-z0-9]+')
    if (-not $km.Success) { return $false }
    $dlPage = 'https://www.apkmirror.com' + $km.Value
    $dhtml  = Curl-Text -Url $dlPage -Referer $VariantUrl
    $fm = [regex]::Match($dhtml, '/wp-content/themes/APKMirror/download\.php\?id=\d+&(?:amp;)?key=[a-z0-9]+')
    if (-not $fm.Success) { return $false }
    $final = 'https://www.apkmirror.com' + ($fm.Value -replace '&amp;','&')
    $code  = Curl-File -Url $final -Referer $dlPage -OutFile $OutFile
    if ($code -ne '200' -or -not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 100000) { return $false }
    $fs = [IO.File]::OpenRead($OutFile); $b = New-Object byte[] 2; [void]$fs.Read($b,0,2); $fs.Close()
    return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)   # 'PK'
}

# Prepare a downloaded file for install. Returns @{ IsBundle; BaseApk; Folder } (extracts bundles).
function Expand-Candidate {
    param([string]$File, [string]$ExtractDir)
    $isBundle = $false
    $zip = [IO.Compression.ZipFile]::OpenRead($File)
    try { $isBundle = [bool]($zip.Entries | Where-Object { $_.FullName -eq 'base.apk' }) } finally { $zip.Dispose() }
    if (-not $isBundle) { return @{ IsBundle=$false; BaseApk=$File; Folder=$null } }
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($File, $ExtractDir)
    return @{ IsBundle=$true; BaseApk=(Join-Path $ExtractDir 'base.apk'); Folder=$ExtractDir }
}
function Get-SignerSha256 {
    param([string]$Apk)
    if (-not $script:Tools.apksigner) { return $null }
    foreach ($l in (& $script:Tools.apksigner verify --print-certs $Apk 2>$null)) {
        if ($l -match 'SHA-256 digest:\s*([0-9a-fA-F]{64})') { return $Matches[1].ToLower() }
    }
    return $null
}

# --------------------------------------------------------------------------- cache
function Load-Cache { if (Test-Path $CacheFile) { try { return (Get-Content $CacheFile -Raw | ConvertFrom-Json) } catch {} } return ([pscustomobject]@{}) }
function Cache-Get  { param($C,$K) if ($C -and ($C.PSObject.Properties.Name -contains $K)) { return $C.$K } return $null }

# --------------------------------------------------------------------------- per app
function Update-App {
    param([string]$Key, [string]$Serial, [hashtable]$Dev, [ref]$Cache)
    $app = $Catalog[$Key]
    Write-Host ""
    Write-Log "=== $($app.Name)  ($($app.Package)) ===" 'STEP'

    $installed = Get-InstalledApp -Serial $Serial -Package $app.Package
    if ($installed) { Write-Log ("Installed: {0} (code {1})" -f $installed.VersionName, $installed.VersionCode) }
    else            { Write-Log "Not installed on device (will treat newest compatible as install)." 'WARN' }

    $releases = Get-ReleaseUrls -App $app -Count $ReleasesToScan
    Write-Log ("Scanning up to {0} APKMirror releases..." -f $releases.Count)

    $chosen = $null   # @{ Variant; Slug }
    $idx = 0
    foreach ($rel in $releases) {
        $idx++
        $slug = ($rel.TrimEnd('/') -split '/')[-1]

        # cache stores, per immutable release: the best compatible variant + all variant codes
        $cached = Cache-Get $Cache.Value $slug
        if ($cached -and $cached.Best -and $cached.Best.VersionCode) {
            $best  = [pscustomobject]@{ Url=$cached.Best.Url; Arch=$cached.Best.Arch; MinApi=[int]$cached.Best.MinApi; VersionCode=[int64]$cached.Best.VersionCode; Bundle=[bool]$cached.Best.Bundle }
            $codes = @($cached.Codes | ForEach-Object { [int64]$_ })
            Write-Log ("  [{0}] {1}: best compatible code {2} ({3}{4}) [cached]" -f $idx, $slug, $best.VersionCode, $best.Arch, $(if($best.Bundle){'/bundle'}else{''}))
        } else {
            $variants = Get-ReleaseVariants -ReleaseUrl $rel
            if (-not $variants) { Write-Log ("  [{0}] {1}: no variants parsed, skipping." -f $idx,$slug) 'WARN'; continue }
            $codes = @($variants.VersionCode | Sort-Object -Unique)
            $best  = Select-BestVariant -Variants $variants -Dev $Dev
            $bestObj = if ($best) { [pscustomobject]@{ Url=$best.Url; Arch=$best.Arch; MinApi=$best.MinApi; VersionCode=$best.VersionCode; Bundle=$best.Bundle } } else { $null }
            $Cache.Value | Add-Member -NotePropertyName $slug -NotePropertyValue ([pscustomobject]@{ Best=$bestObj; Codes=$codes }) -Force
            if ($best) { Write-Log ("  [{0}] {1}: best compatible code {2} ({3}{4}, minApi {5})" -f $idx, $slug, $best.VersionCode, $best.Arch, $(if($best.Bundle){'/bundle'}else{''}), $best.MinApi) }
            else       { Write-Log ("  [{0}] {1}: no device-compatible variant (codes {2})." -f $idx,$slug, ($codes -join '/')) 'WARN' }
        }

        # If the device's installed build is among this release's variants, it's already on this release.
        if ($installed -and ($codes -contains $installed.VersionCode)) { Write-Log "Device already on this release -> up to date." 'OK'; return (New-Result $app $installed '(none)' 'up-to-date') }
        if (-not $best) { continue }
        if ((-not $installed) -or ($best.VersionCode -gt $installed.VersionCode)) { $chosen = @{ Variant=$best; Slug=$slug }; break }
        Write-Log ("      code {0} <= installed {1}; checking older releases for the live lineage..." -f $best.VersionCode, $installed.VersionCode)
    }

    if (-not $chosen) { Write-Log "No installable in-place upgrade found." 'OK'; return (New-Result $app $installed '(none)' 'up-to-date') }

    # download + verify the winner
    $file = Join-Path $WorkDir ("{0}__{1}.bin" -f $Key, $chosen.Slug)
    $extr = Join-Path $WorkDir ("{0}__{1}" -f $Key, $chosen.Slug)
    Write-Log ("UPGRADE candidate: {0} -> code {1} ({2}). Downloading..." -f $(if($installed){$installed.VersionName}else{'fresh'}), $chosen.Variant.VersionCode, $chosen.Variant.Arch) 'OK'
    if (-not (Download-Variant -VariantUrl $chosen.Variant.Url -ReleaseUrl ($chosen.Variant.Url -replace '/[^/]+-android-apk-download/$','/') -OutFile $file)) {
        Write-Log "Download failed." 'ERR'; return (New-Result $app $installed '?' 'download-failed')
    }
    $prep = Expand-Candidate -File $file -ExtractDir $extr

    # signature pin
    if ($installed -and $installed.Signer -and $script:Tools.apksigner) {
        $sig = Get-SignerSha256 -Apk $prep.BaseApk
        if ($sig -and $sig -ne $installed.Signer) { Write-Log ("Signer mismatch (apk $sig vs installed $($installed.Signer)) -> refusing." ) 'ERR'; return (New-Result $app $installed '?' 'signature-mismatch') }
        if ($sig) { Write-Log "Signature pin OK (matches installed cert)." 'OK' }
    }
    # confirm real versionName/code via aapt if available
    $toVer = "code $($chosen.Variant.VersionCode)"
    if ($script:Tools.aapt) {
        foreach ($l in (& $script:Tools.aapt dump badging $prep.BaseApk 2>$null)) { if ($l -match "versionName='([^']+)'") { $toVer = $Matches[1]; break } }
    }

    if ($DryRun) { Write-Log ("DryRun: would upgrade to {0}." -f $toVer) 'WARN'; return (New-Result $app $installed $toVer 'would-upgrade') }

    # install
    $adb = $script:Tools.adb
    if ($prep.IsBundle) {
        $splits = @()
        $abiPick = ($Dev.Abis | Where-Object { Test-Path (Join-Path $prep.Folder ("split_config.{0}.apk" -f ($_ -replace '-','_'))) } | Select-Object -First 1)
        if ($abiPick) { $splits += (Join-Path $prep.Folder ("split_config.{0}.apk" -f ($abiPick -replace '-','_'))) }
        $dp = Join-Path $prep.Folder ("split_config.{0}.apk" -f (Get-DensityBucket $Dev.Density)); if (Test-Path $dp) { $splits += $dp }
        $en = Join-Path $prep.Folder 'split_config.en.apk'; if (Test-Path $en) { $splits += $en }
        $list = @($prep.BaseApk) + $splits
        Write-Log ("Installing bundle: {0}" -f (($list | Split-Path -Leaf) -join ', ')) 'STEP'
        $res = (& $adb -s $Serial install-multiple -r @list 2>&1) -join ' '
    } else {
        Write-Log "Installing APK..." 'STEP'
        $res = (& $adb -s $Serial install -r $file 2>&1) -join ' '
    }

    if ($res -match 'Success') {
        $now = Get-InstalledApp -Serial $Serial -Package $app.Package
        Write-Log ("Installed OK -> {0} (code {1})" -f $now.VersionName, $now.VersionCode) 'OK'
        return (New-Result $app $installed $now.VersionName 'upgraded')
    }
    Write-Log ("Install failed: {0}" -f ($res -replace '\s+',' ').Trim()) 'ERR'
    return (New-Result $app $installed $toVer 'install-failed')
}

function New-Result { param($App,$Installed,$To,$Action) [pscustomobject]@{ App=$App.Name; From=$(if($Installed){$Installed.VersionName}else{'-'}); To=$To; Action=$Action } }

# =========================================================================== main
$summary = @()
try {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $script:Jar = Join-Path $WorkDir 'cookies.txt'
    $script:Tools = Resolve-Tools
    Write-Log ("Tools: adb, curl{0}{1}{2}" -f $(if($script:Tools.aapt){', aapt'}else{''}), $(if($script:Tools.apksigner){', apksigner'}else{''}), $(if($script:Tools.nmap){', nmap'}else{''}))

    $serial = Connect-Shield
    $dev = Get-DeviceProps -Serial $serial
    Write-Log ("Device: Android SDK {0}, density {1}, abis [{2}]" -f $dev.Sdk, $dev.Density, ($dev.Abis -join ','))

    $cacheObj = Load-Cache; $cacheRef = [ref]$cacheObj
    foreach ($k in $Apps) {
        try   { $summary += Update-App -Key $k -Serial $serial -Dev $dev -Cache $cacheRef }
        catch { Write-Log ("$k failed: {0}" -f $_.Exception.Message) 'ERR'; $summary += [pscustomobject]@{ App=$Catalog[$k].Name; From='?'; To='?'; Action='error' } }
    }
    $cacheObj | ConvertTo-Json -Depth 6 | Set-Content -Path $CacheFile -Encoding UTF8
}
catch { Write-Log $_.Exception.Message 'ERR'; exit 1 }
finally { Get-ChildItem $WorkDir -Filter '*__*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Log "Summary:" 'STEP'
$summary | Format-Table -AutoSize | Out-String | Write-Host
if ($DryRun) { Write-Host "(DryRun: no changes were made to the device.)" -ForegroundColor Yellow }
