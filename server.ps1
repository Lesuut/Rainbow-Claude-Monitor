# Rainbow Claude Monitor - local HTTP server.
# Serves index.html and a JSON feed with CPU/RAM load and Claude usage limits.
# No admin rights needed: the 127.0.0.1 prefix is not a reserved URL namespace.
#
# Everything that can be configured lives in config.json next to this file:
# accounts, port, location, polling, theme, launch behaviour. Nothing about one
# particular machine or account is hard-coded here.
#
# Limits come from two sources, in order:
#   1. live  - GET https://api.anthropic.com/api/oauth/usage with the account's
#              own OAuth token, read from <config>/.credentials.json at request
#              time. The token is never logged, echoed, or sent anywhere else.
#   2. cache - cachedUsageUtilization inside <config>/.claude.json, which only
#              Claude Code itself refreshes (on /status). Used when live fails.
# usage.source in config.json picks between them: auto, api, cache.

# -Port and -NoBrowser override config.json for this run only, which is what a
# second copy on another port needs.
param([int]$Port = 0, [switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Windows launched from here inherit this process's environment. When the server
# is itself started from inside a Claude Code session, that session's markers
# come along, and a new window treats itself as a child of it: it writes no
# sessions/*.json, so the panel never counts it and launch-color.ps1 waits out
# its timeout instead of painting it. Drop the markers before serving.
# CLAUDE_CONFIG_DIR is in here too: inherited, it would point a launched window
# at the wrong account's config.
# NO_COLOR belongs to the same set: a Claude Code shell sets it for its children
# so their output stays plain, and carried this far it reaches the launched
# window's own TUI, which then draws monochrome - no accent, whatever /color says.
foreach ($marker in (Get-ChildItem Env: | Where-Object {
        $_.Name -like 'CLAUDE*' -or $_.Name -eq 'AI_AGENT' -or
        $_.Name -eq 'NO_COLOR' -or $_.Name -eq 'FORCE_COLOR' })) {
    Remove-Item "Env:$($marker.Name)" -ErrorAction SilentlyContinue
}

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$IndexPath  = Join-Path $Root 'index.html'
$ConfigPath = Join-Path $Root 'config.json'
$ColorsPath = Join-Path $Root 'colors.json'
$PokePath   = Join-Path $Root 'poke.ps1'
$LaunchColorPath = Join-Path $Root 'launch-color.ps1'
$SoundPath  = Join-Path $Root 'sound.json'

$UsageUrl   = 'https://api.anthropic.com/api/oauth/usage'
$ColorNames = @('red','orange','yellow','green','cyan','blue','purple','pink','default')

# ---------- configuration ----------
# A missing config.json is written out with one account pointing at the default
# ~/.claude, which is the shape of a first run for someone with one account.
$StarterConfig = @'
{
  "title": "Rainbow Claude Monitor",
  "port": 8777,
  "openBrowser": true,
  "location": { "lat": 50.4501, "lng": 30.5234 },
  "ui": { "columns": "auto", "theme": "auto", "duskMinutes": 45, "refreshMs": 1000,
          "showMachine": true, "showSevenDay": true,
          "hotPercent": 90, "accents": {} },
  "usage": { "source": "auto", "liveOkSec": 120, "liveBadSec": 600 },
  "launch": { "autoColor": true, "trustPromptKeys": "down,enter", "waitSec": 90 },
  "accounts": [
    { "id": "main", "label": "Claude", "configDir": ".claude", "accent": "blue" }
  ]
}
'@

function Get-Prop {
    param($obj, [string]$name, $fallback)
    if ($obj -and ($obj.PSObject.Properties.Name -contains $name) -and $null -ne $obj.$name) {
        return $obj.$name
    }
    return $fallback
}

# Absolute paths are taken as they are; anything else hangs off %USERPROFILE%,
# because that is where every Claude config dir lives.
function Resolve-UserPath {
    param([string]$p)
    if (-not $p) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p.StartsWith('~')) {
        $p = $p.Substring(1).TrimStart('\', '/')
        return (Join-Path $env:USERPROFILE $p)
    }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $env:USERPROFILE $p)
}

# A launcher is usually named, not pathed ("Claude Work.exe" on the Desktop).
# Look where a person would keep it before giving up.
function Resolve-Launcher {
    param([string]$name)
    if (-not $name) { return $null }
    $name = [Environment]::ExpandEnvironmentVariables($name)
    if ($name.StartsWith('~')) { $name = Join-Path $env:USERPROFILE $name.Substring(1).TrimStart('\', '/') }
    if ([IO.Path]::IsPathRooted($name)) {
        if (Test-Path $name) { return $name } else { return $null }
    }
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'), $env:USERPROFILE, $Root)) {
        $try = Join-Path $dir $name
        if (Test-Path $try) { return $try }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

if (-not (Test-Path $ConfigPath)) {
    Set-Content -Path $ConfigPath -Value $StarterConfig -Encoding UTF8
    Write-Host "  config.json was missing - wrote a starter one." -ForegroundColor Yellow
}

try {
    $Cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host ""
    Write-Host "  config.json is not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Fix it (a trailing comma is the usual culprit) and start again." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

$Title       = [string](Get-Prop $Cfg 'title' 'Rainbow Claude Monitor')
if ($Port -le 0) { $Port = [int](Get-Prop $Cfg 'port' 8777) }
$OpenBrowser = [bool](Get-Prop $Cfg 'openBrowser' $true)
$Location    = Get-Prop $Cfg 'location' $null

$UiCfg = Get-Prop $Cfg 'ui' $null
$Ui = [ordered]@{
    title        = $Title
    columns      = (Get-Prop $UiCfg 'columns' 'auto')
    theme        = [string](Get-Prop $UiCfg 'theme' 'auto')
    duskMinutes  = [double](Get-Prop $UiCfg 'duskMinutes' 45)
    refreshMs    = [int](Get-Prop $UiCfg 'refreshMs' 1000)
    showMachine  = [bool](Get-Prop $UiCfg 'showMachine' $true)
    showSevenDay = [bool](Get-Prop $UiCfg 'showSevenDay' $true)
    hotPercent   = [double](Get-Prop $UiCfg 'hotPercent' 90)
    accents      = (Get-Prop $UiCfg 'accents' @{})
}

$UsageCfg      = Get-Prop $Cfg 'usage' $null
$UsageSource   = [string](Get-Prop $UsageCfg 'source' 'auto')
$LiveOkTtlSec  = [int](Get-Prop $UsageCfg 'liveOkSec' 120)
$LiveBadTtlSec = [int](Get-Prop $UsageCfg 'liveBadSec' 600)

$LaunchCfg  = Get-Prop $Cfg 'launch' $null
$AutoColor  = [bool](Get-Prop $LaunchCfg 'autoColor' $true)
$TrustKeys  = [string](Get-Prop $LaunchCfg 'trustPromptKeys' 'down,enter')
$LaunchWait = [int](Get-Prop $LaunchCfg 'waitSec' 90)

# ---------- accounts ----------
$Accounts = @()
$seenIds = @{}
foreach ($a in @(Get-Prop $Cfg 'accounts' @())) {
    $id  = [string](Get-Prop $a 'id' '')
    $dir = [string](Get-Prop $a 'configDir' '')
    if ($id -notmatch '^[A-Za-z0-9_-]{1,32}$') {
        Write-Host "  skipping account with bad id '$id' (letters, digits, - and _ only)" -ForegroundColor Yellow
        continue
    }
    if ($seenIds.ContainsKey($id)) {
        Write-Host "  skipping duplicate account id '$id'" -ForegroundColor Yellow
        continue
    }
    if (-not $dir) {
        Write-Host "  skipping account '$id': no configDir" -ForegroundColor Yellow
        continue
    }
    $seenIds[$id] = $true

    $accent = [string](Get-Prop $a 'accent' 'default')
    if ($ColorNames -notcontains $accent) { $accent = 'default' }

    $launcher = [string](Get-Prop $a 'launcher' '')
    $exeName  = ''
    if ($launcher) { $exeName = Split-Path -Leaf ([Environment]::ExpandEnvironmentVariables($launcher)) }

    $Accounts += @{
        id       = $id
        label    = [string](Get-Prop $a 'label' $id)
        dirPath  = (Resolve-UserPath $dir)
        launcher = $launcher
        exeName  = $exeName
        args     = @(Get-Prop $a 'launchArgs' @())
        workDir  = [string](Get-Prop $a 'workingDir' $env:USERPROFILE)
        accent   = $accent
    }
}

if ($Accounts.Count -eq 0) {
    Write-Host ""
    Write-Host "  No usable accounts in config.json - nothing to show." -ForegroundColor Red
    Write-Host "  See config.example.json for the shape of an account entry." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# ---------- static hardware facts, read once ----------
$cpuInfo   = Get-CimInstance Win32_Processor | Select-Object -First 1
$CpuName   = $cpuInfo.Name.Trim()
$CpuCores  = $cpuInfo.NumberOfCores
$CpuThread = $cpuInfo.NumberOfLogicalProcessors

# For the dusk/dawn theme drift. Skipped entirely when location is null.
$SunUrl = $null
if ($Location) {
    $SunUrl = 'https://api.sunrise-sunset.org/json?lat={0}&lng={1}&formatted=0' -f `
                  ([double]$Location.lat), ([double]$Location.lng)
}
$sunCache = $null

# Per-account accent, kept next to this script. Claude Code's own /color lives
# only in the running window's memory, so a stored accent is only ever true of a
# window that is still open: 'default' - the panel's grey - is the honest state
# for an account with nothing running, and the file is walked back to it both at
# startup and the moment an account's last window goes away.
function New-ColorMap {
    $map = @{}
    foreach ($a in $Accounts) { $map[$a.id] = 'default' }
    return $map
}

function Get-Colors {
    $map = New-ColorMap
    if (Test-Path $ColorsPath) {
        try {
            $saved = Get-Content $ColorsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($map.ContainsKey($p.Name) -and $ColorNames -contains $p.Value) { $map[$p.Name] = $p.Value }
            }
        } catch { }
    }
    return $map
}

function Write-Colors {
    param($map)
    $out = [ordered]@{}
    foreach ($a in $Accounts) { $out[$a.id] = $map[$a.id] }
    ($out | ConvertTo-Json) | Set-Content -Path $ColorsPath -Encoding UTF8
}

function Set-Color {
    param([string]$id, [string]$name)
    $map = Get-Colors
    $map[$id] = $name
    Write-Colors $map
}

# Nothing is coloured until a live window is told to be. Called once at startup.
function Reset-Colors { Write-Colors (New-ColorMap) }
# ---------- notification sound ----------
# The Stop hook (~/.claude/hooks/claude-done-sound.ps1) re-reads sound.json every
# time a session ends, so the slider in the header takes effect on the next play
# without anything having to be restarted.
function Get-SoundVolume {
    if (Test-Path $SoundPath) {
        try {
            $saved = Get-Content $SoundPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $v = [double]$saved.volume
            if ($v -ge 0 -and $v -le 1) { return $v }
        } catch { }
    }
    return 0.7
}

function Set-SoundVolume {
    param([double]$volume)
    if ($volume -lt 0) { $volume = 0 }
    if ($volume -gt 1) { $volume = 1 }
    $volume = [math]::Round($volume, 2)
    ([ordered]@{ volume = $volume } | ConvertTo-Json) | Set-Content -Path $SoundPath -Encoding UTF8
    return $volume
}

# Types "/color <name>" into every open console of this account, the same way the
# user would. poke.ps1 has to run out-of-process - see the note in that file.
function Send-ColorToWindows {
    param([string]$id, [string]$name, [int]$only = 0)

    $acc = $Accounts | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $acc) { return 0 }

    $livePids = @{}
    foreach ($p in (Get-Process)) { $livePids[$p.Id] = $true }

    $sent = 0
    foreach ($target in (Get-SessionState $acc $livePids).pids) {
        # A launch paints only the window it opened; the panel's own colour
        # buttons ($only = 0) still reach every window of the account.
        if ($only -and $target -ne $only) { continue }
        try {
            Start-Process powershell -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$PokePath`"",
                '-TargetPid', $target,
                '-Text', "`"/color $name`""
            ) | Out-Null
            $sent++
        } catch { }
    }
    return $sent
}

$cfgCache  = @{}   # id -> parsed .claude.json, keyed on file mtime
$liveCache = @{}   # id -> last live poll: utilization node + diagnostics
$hdrStyle  = @{}   # id -> index of the header set that worked

function Now-Ms {
    [long][Math]::Floor((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalMilliseconds)
}

# ---------- OAuth token ----------
# Returns the account's bearer token, or $null. Callers must not log the value.
function Read-OAuthToken {
    param($acc)

    $path = Join-Path $acc.dirPath '.credentials.json'
    if (-not (Test-Path $path)) { return $null }

    try {
        $cred = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }

    foreach ($node in @($cred.claudeAiOauth, $cred.oauth, $cred)) {
        if ($null -eq $node) { continue }
        foreach ($key in @('accessToken', 'access_token')) {
            $val = $node.$key
            if ($val -is [string] -and $val.Length -gt 20) { return $val }
        }
    }
    return $null
}

function Get-HeaderSet {
    param([int]$i, [string]$token)

    $base = @{
        'Authorization' = "Bearer $token"
        'Accept'        = 'application/json'
        'User-Agent'    = 'claude-cli/2.1.250 (external, cli)'
    }
    switch ($i) {
        0 { $base['anthropic-beta'] = 'oauth-2025-04-20' }
        1 { $base['anthropic-beta'] = 'oauth-2025-04-20'; $base['anthropic-version'] = '2023-06-01' }
        2 { }
    }
    return $base
}

# ---------- live usage ----------
function Poll-LiveUsage {
    param($acc)

    $state = [ordered]@{
        atMs = Now-Ms; ok = $false; util = $null
        status = $null; err = $null; keys = $null; hasToken = $false
    }

    $token = Read-OAuthToken $acc
    if (-not $token) { $state.err = 'no token in .credentials.json'; return $state }
    $state.hasToken = $true

    $order = if ($hdrStyle.ContainsKey($acc.id)) { @($hdrStyle[$acc.id]) } else { @(0, 1, 2) }

    foreach ($i in $order) {
        try {
            $resp = Invoke-RestMethod -Uri $UsageUrl -Method Get -TimeoutSec 12 `
                        -Headers (Get-HeaderSet $i $token)
            $state.ok = $true
            $state.status = 200
            $state.keys = @($resp.PSObject.Properties.Name)
            $hdrStyle[$acc.id] = $i

            if ($resp.PSObject.Properties.Name -contains 'five_hour') {
                $state.util = $resp
            } elseif ($resp.utilization) {
                $state.util = $resp.utilization
            } else {
                $state.ok = $false
                $state.err = 'unexpected response shape'
            }
            return $state
        } catch {
            $state.err = $_.Exception.Message
            if ($_.Exception.Response) {
                try { $state.status = [int]$_.Exception.Response.StatusCode } catch { }
            }
        }
    }
    return $state
}

function Get-LiveUtilization {
    param($acc)

    if ($UsageSource -eq 'cache') {
        return [ordered]@{
            atMs = Now-Ms; ok = $false; util = $null; status = $null
            err = 'live polling off (usage.source = cache)'; keys = $null; hasToken = $false
        }
    }

    $hit = $liveCache[$acc.id]
    if ($hit) {
        $ttl = if ($hit.ok) { $LiveOkTtlSec } else { $LiveBadTtlSec }
        if (((Now-Ms) - $hit.atMs) -lt ($ttl * 1000)) { return $hit }
    }
    $fresh = Poll-LiveUsage $acc
    $liveCache[$acc.id] = $fresh
    return $fresh
}

# ---------- when it actually gets dark ----------
# Fetched once a day for the configured location. The client dims the panel
# across the hour around each event, so it only needs the two instants, in UTC.
function Get-SunTimes {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (-not $SunUrl) {
        return [ordered]@{ day = $today; ok = $false; sunriseMs = $null; sunsetMs = $null
                           err = 'no location configured' }
    }
    if ($sunCache -and $sunCache.day -eq $today -and $sunCache.ok) { return $sunCache }

    $state = [ordered]@{ day = $today; ok = $false; sunriseMs = $null; sunsetMs = $null; err = $null }
    try {
        $r = Invoke-RestMethod -Uri "$SunUrl&date=$today" -TimeoutSec 12
        if ($r.status -ne 'OK') { throw "api status $($r.status)" }
        $epoch = [datetime]'1970-01-01'
        $state.sunriseMs = [long][Math]::Floor(([datetimeoffset]$r.results.sunrise).UtcDateTime.Subtract($epoch).TotalMilliseconds)
        $state.sunsetMs  = [long][Math]::Floor(([datetimeoffset]$r.results.sunset).UtcDateTime.Subtract($epoch).TotalMilliseconds)
        $state.ok = $true
    } catch {
        $state.err = $_.Exception.Message
    }
    $script:sunCache = $state
    return $state
}

# ---------- is this account's Claude working right now? ----------
# Every running session writes <config>/sessions/<pid>.json and keeps a status
# field in it: 'busy' while the turn runs, 'idle' while it waits for the user.
# Files outlive crashed sessions, so a pid must still be alive to count.
function Get-SessionState {
    param($acc, $livePids)

    $res = [ordered]@{ running = 0; busy = $false; status = 'off'; pids = @() }
    $dir = Join-Path $acc.dirPath 'sessions'
    if (-not (Test-Path $dir)) { return $res }

    $cutoff = (Now-Ms) - (12 * 3600 * 1000)
    foreach ($file in (Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $s = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $s.pid) { continue }
        if (-not $livePids.ContainsKey([int]$s.pid)) { continue }
        if ($s.updatedAt -and $s.updatedAt -lt $cutoff) { continue }

        $res.running++
        $res.pids += [int]$s.pid
        if ($s.status -eq 'busy') { $res.busy = $true }
    }

    $res.status = if ($res.busy) { 'busy' } elseif ($res.running -gt 0) { 'idle' } else { 'off' }
    return $res
}

# ---------- one account, live first then cache ----------
function Get-ClaudeUsage {
    param($acc, $livePids, $colors)

    # An accent only survives as long as the window carrying it. With the last
    # window of an account gone the stored name is a lie about a process that no
    # longer exists, so it is walked back to grey here rather than on some later
    # relaunch - one write, on the poll that first sees the account empty.
    $sess = Get-SessionState $acc $livePids
    if ($sess.running -eq 0 -and $colors[$acc.id] -ne 'default') {
        Set-Color $acc.id 'default'
        $colors[$acc.id] = 'default'
    }

    $res = [ordered]@{
        id = $acc.id; label = $acc.label; colorName = $colors[$acc.id]
        canLaunch = [bool](Resolve-Launcher $acc.launcher)
        email = $null; plan = $null; found = $false
        source = 'none'; fetchedAtMs = $null
        fiveHour = $null; sevenDay = $null
        session = $sess
    }

    $path = Join-Path $acc.dirPath '.claude.json'
    $data = $null
    if (Test-Path $path) {
        try {
            $stamp = (Get-Item $path).LastWriteTimeUtc.Ticks
            $hit = $cfgCache[$acc.id]
            if ($hit -and $hit.stamp -eq $stamp) {
                $data = $hit.data
            } else {
                $data = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $cfgCache[$acc.id] = @{ stamp = $stamp; data = $data }
            }
        } catch { $data = $null }
    }

    if ($data) {
        $res.found = $true
        if ($data.oauthAccount) {
            $res.email = $data.oauthAccount.emailAddress
            $res.plan  = $data.oauthAccount.organizationType
        }
    }

    $live = Get-LiveUtilization $acc
    if ($live.ok -and $live.util) {
        $res.source = 'api'
        $res.fetchedAtMs = $live.atMs
        $util = $live.util
    } elseif ($UsageSource -eq 'api') {
        return $res
    } else {
        $cu = if ($data) { $data.cachedUsageUtilization } else { $null }
        if (-not $cu) { return $res }
        $res.source = 'cache'
        $res.fetchedAtMs = $cu.fetchedAtMs
        $util = $cu.utilization
    }

    foreach ($pair in @(@('five_hour', 'fiveHour'), @('seven_day', 'sevenDay'))) {
        $node = $util.($pair[0])
        if ($null -eq $node) { continue }
        $res[$pair[1]] = [ordered]@{
            percent  = $node.utilization
            resetsAt = $node.resets_at
        }
    }
    return $res
}

function Get-Stats {
    $cpuCounter = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $os = Get-CimInstance Win32_OperatingSystem

    $totalKB = [double]$os.TotalVisibleMemorySize
    $freeKB  = [double]$os.FreePhysicalMemory
    $usedKB  = $totalKB - $freeKB

    # One process sweep serves both the process count and the session liveness check.
    $procList = @(Get-Process)
    $livePids = @{}
    foreach ($p in $procList) { $livePids[$p.Id] = $true }

    $colors = Get-Colors
    $accInfo = @()
    foreach ($a in $Accounts) { $accInfo += (Get-ClaudeUsage $a $livePids $colors) }

    [ordered]@{
        nowMs = Now-Ms
        cpu = [ordered]@{
            percent = [double]$cpuCounter.PercentProcessorTime
            name    = $CpuName
            cores   = $CpuCores
            threads = $CpuThread
        }
        ram = [ordered]@{
            percent = [Math]::Round(($usedKB / $totalKB) * 100, 1)
            usedGB  = [Math]::Round($usedKB / 1048576, 1)
            totalGB = [Math]::Round($totalKB / 1048576, 1)
        }
        host = [ordered]@{
            name      = $env:COMPUTERNAME
            uptimeSec = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
            processes = $procList.Count
        }
        sun = (Get-SunTimes)
        accounts = @($accInfo)
    }
}

# Diagnostics for the live poll. Reports outcomes only - never the token.
function Get-Debug {
    $rows = @()
    foreach ($a in $Accounts) {
        $l = $liveCache[$a.id]
        $rows += [ordered]@{
            id        = $a.id
            configDir = $a.dirPath
            dirExists = (Test-Path $a.dirPath)
            launcher  = (Resolve-Launcher $a.launcher)
            hasToken  = if ($l) { $l.hasToken } else { $null }
            ok        = if ($l) { $l.ok } else { $null }
            status    = if ($l) { $l.status } else { $null }
            error     = if ($l) { $l.err } else { $null }
            keys      = if ($l) { $l.keys } else { $null }
            headerSet = if ($hdrStyle.ContainsKey($a.id)) { $hdrStyle[$a.id] } else { $null }
            polledAt  = if ($l) { $l.atMs } else { $null }
        }
    }
    return @{ source = $UsageSource; accounts = @($rows) }
}

function Send-Bytes {
    param($ctx, [byte[]]$bytes, [string]$type, [int]$code = 200)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Json {
    param($ctx, $obj, [int]$code = 200)
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $code
}

Reset-Colors

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    $listenErr = $_.Exception.Message
    # Port taken. If it is this panel already running, the click that started
    # this copy meant "show me the panel" - open the browser at the live one and
    # leave quietly instead of dying with an error the .bat window never shows.
    $alive = $false
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 3 | Out-Null
        $alive = $true
    } catch { }

    if ($alive) {
        Write-Host ""
        Write-Host "  $Title is already running at http://127.0.0.1:$Port" -ForegroundColor Green
        Write-Host ""
        if ($OpenBrowser -and -not $NoBrowser) {
            try { Start-Process "http://127.0.0.1:$Port/" | Out-Null } catch { }
        }
        exit 0
    }

    Write-Host ""
    Write-Host "  Could not listen on 127.0.0.1:$Port - $listenErr" -ForegroundColor Red
    Write-Host "  Another program is holding the port." -ForegroundColor DarkGray
    Write-Host "  Change 'port' in config.json and start again." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

Write-Host ""
Write-Host "  $Title running at http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host "  accounts: $(($Accounts | ForEach-Object { $_.id }) -join ', ')" -ForegroundColor DarkGray
Write-Host "  Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

if ($OpenBrowser -and -not $NoBrowser) {
    try { Start-Process "http://127.0.0.1:$Port/" | Out-Null } catch { }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $path = $ctx.Request.Url.AbsolutePath

            switch -Regex ($path) {
                '^/(index\.html)?$' {
                    if (Test-Path $IndexPath) {
                        Send-Bytes $ctx ([IO.File]::ReadAllBytes($IndexPath)) 'text/html; charset=utf-8'
                    } else {
                        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('index.html not found')) 'text/plain; charset=utf-8' 404
                    }
                    break
                }
                '^/api/config$' {
                    Send-Json $ctx $Ui
                    break
                }
                '^/api/stats$' {
                    Send-Json $ctx (Get-Stats)
                    break
                }
                '^/api/debug$' {
                    Send-Json $ctx (Get-Debug)
                    break
                }
                '^/api/color$' {
                    $id = $ctx.Request.QueryString['id']
                    $name = $ctx.Request.QueryString['name']
                    if (-not ($Accounts | Where-Object { $_.id -eq $id })) {
                        Send-Json $ctx @{ ok = $false; error = 'unknown id' } 400
                        break
                    }
                    if ($ColorNames -notcontains $name) {
                        Send-Json $ctx @{ ok = $false; error = 'unknown color' } 400
                        break
                    }
                    # Store the pick only once a window has actually taken it.
                    # With nothing open there is no /color to remember, and the
                    # card must stay grey rather than promise a colour no
                    # process is wearing.
                    $only = 0
                    $pidArg = $ctx.Request.QueryString['pid']
                    if ($pidArg -match '^\d+$') { $only = [int]$pidArg }

                    $sent = Send-ColorToWindows $id $name $only
                    if ($sent -gt 0) { Set-Color $id $name }
                    $stored = if ($sent -gt 0) { $name } else { 'default' }
                    Send-Json $ctx @{ ok = $true; id = $id; name = $stored; windows = $sent }
                    break
                }
                '^/api/refresh$' {
                    $liveCache.Clear()
                    Send-Json $ctx @{ ok = $true }
                    break
                }
                '^/api/sound$' {
                    $vol = $ctx.Request.QueryString['volume']
                    if ([string]::IsNullOrEmpty($vol)) {
                        Send-Json $ctx @{ ok = $true; volume = (Get-SoundVolume) }
                        break
                    }
                    # The slider sends an invariant decimal - parse it as one, or a
                    # comma-decimal locale would read 0.5 as 5.
                    $parsed = 0.0
                    $okParse = [double]::TryParse($vol, [Globalization.NumberStyles]::Float,
                                                  [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
                    if (-not $okParse) {
                        Send-Json $ctx @{ ok = $false; error = 'bad volume' } 400
                        break
                    }
                    Send-Json $ctx @{ ok = $true; volume = (Set-SoundVolume $parsed) }
                    break
                }
                '^/api/launch$' {
                    $id = $ctx.Request.QueryString['id']
                    $acc = $Accounts | Where-Object { $_.id -eq $id } | Select-Object -First 1
                    if (-not $acc) {
                        Send-Json $ctx @{ ok = $false; error = 'unknown id' } 400
                        break
                    }
                    $exePath = Resolve-Launcher $acc.launcher
                    if (-not $exePath) {
                        Send-Json $ctx @{ ok = $false; error = "launcher not found: $($acc.launcher)" } 404
                        break
                    }
                    # Launch from the home dir by default, not the server's cwd -
                    # otherwise Claude opens in this folder and asks to trust it.
                    $workDir = Resolve-UserPath $acc.workDir
                    if (-not $workDir -or -not (Test-Path $workDir)) { $workDir = $env:USERPROFILE }

                    if ($acc.args -and $acc.args.Count -gt 0) {
                        Start-Process -FilePath $exePath -ArgumentList $acc.args -WorkingDirectory $workDir | Out-Null
                    } else {
                        Start-Process -FilePath $exePath -WorkingDirectory $workDir | Out-Null
                    }

                    # A window that has just opened wears nothing. Hand the wait
                    # off to its own process - the new console takes seconds to
                    # be ready, and this loop must stay free for the next request.
                    if (($AutoColor -or $TrustKeys) -and $acc.exeName) {
                        Start-Process powershell -WindowStyle Hidden -ArgumentList @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', "`"$LaunchColorPath`"",
                            '-Dir', "`"$($acc.dirPath)`"", '-Id', $acc.id, '-Name', $acc.accent,
                            '-Exe', "`"$($acc.exeName)`"", '-Port', $Port,
                            '-Keys', "`"$TrustKeys`"", '-TimeoutSec', $LaunchWait,
                            '-Color', ([int][bool]$AutoColor)
                        ) | Out-Null
                    }

                    Send-Json $ctx @{ ok = $true; launched = $exePath; accent = $acc.accent }
                    break
                }
                default {
                    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('404')) 'text/plain; charset=utf-8' 404
                }
            }
        } catch {
            try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
