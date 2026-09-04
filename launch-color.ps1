# Walks one freshly launched Claude window past its startup prompt (Down, Enter
# - "Yes, I trust this folder"), then asks the panel to paint it. Runs
# out-of-process on purpose: the server handles one request at a time, and a
# window needs a moment before it will accept typed input.
#
# The window is found as a claude.exe whose parent is the account's own
# launcher exe, not by its sessions/*.json: that file is written only after the
# trust prompt is answered, so waiting for it would deadlock against the very
# prompt these keys are meant to clear.
#
# Finding it is a hot poll, so it is done in two steps: Get-Process (tens of
# milliseconds) says whether a claude.exe young enough to be ours exists at all,
# and only then is the parent looked up through CIM, which costs ten times as
# much. Enumerating every process on the machine each tick, as this used to,
# added most of a second to every round.
#
# The colour is applied through the server's own /api/color, not by poking the
# console here, so there is a single path that both types /color and records the
# accent in colors.json.
#
# Launch can be clicked several times in a row, so one waiter runs per window.
# A claim file keeps two waiters off the same window: whoever creates
# .claims/<pid>.claim first owns that window, the other keeps looking.
#
# Both steps are optional and driven by config.json: launch.trustPromptKeys ""
# skips the keystrokes, launch.autoColor false skips the paint. The delays below
# are config.json's launch.pollMs / readyMs / keyDelayMs / settleMs, and the
# prompt to wait for is launch.trustPromptText - raise the delays, never lower
# them, if a slow machine starts missing the prompt.
#
#   powershell -File launch-color.ps1 -Dir C:\Users\me\.claude_personal `
#              -Id personal1 -Name blue -Exe "Claude Personal 1.exe"

param(
    [Parameter(Mandatory = $true)][string]$Dir,     # the account's config dir, absolute
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Name,    # accent to apply
    [Parameter(Mandatory = $true)][string]$Exe,     # launcher file name, the parent to match
    [int]$Port = 8777,
    [string]$Keys = 'down,enter',                   # "" - send nothing
    [int]$Color = 1,                                # 0 - do not paint
    [int]$TimeoutSec = 90,
    [int]$PollMs = 120,                             # gap between two looks for the window
    [int]$ReadyMs = 500,                            # blind wait before the keys, when -WaitFor is off
    [int]$KeyDelayMs = 90,                          # gap between the trust-prompt keys
    [int]$SettleMs = 150,                           # wait after the session file, before /color
    [string]$WaitFor = 'trust',                     # text that must be on screen first, "" - just wait
    [int]$WaitMs = 4000                             # how long to wait for it
)

$ErrorActionPreference = 'SilentlyContinue'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PokePath = Join-Path $Root 'poke.ps1'
$ClaimDir = Join-Path $Root '.claims'
if (-not (Test-Path $ClaimDir)) { New-Item -ItemType Directory -Path $ClaimDir | Out-Null }

# The window this waiter was started for cannot be older than the waiter. A
# small margin covers the launch that happened a moment before this process got
# scheduled; windows already open are never this young.
$Since = (Get-Date).AddSeconds(-5)

# The launcher as Get-Process names it - no extension, no path.
$ParentName = [IO.Path]::GetFileNameWithoutExtension($Exe)

# Claims of windows that are gone say nothing about the ones opening now.
foreach ($file in (Get-ChildItem $ClaimDir -Filter '*.claim' -ErrorAction SilentlyContinue)) {
    if (-not (Get-Process -Id ([int]$file.BaseName) -ErrorAction SilentlyContinue)) {
        Remove-Item $file.FullName -ErrorAction SilentlyContinue
    }
}

# Creates the claim, or returns false when another waiter got there first.
function Claim-Pid {
    param([int]$target)
    try {
        $fs = [IO.File]::Open((Join-Path $ClaimDir "$target.claim"),
                              [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $fs.Close()
        return $true
    } catch {
        return $false
    }
}

$sessionFile = { param($p) Join-Path $Dir "sessions\$p.json" }

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$mine = 0

while ($true) {
    # Cheap gate: is there any claude.exe young enough to be the one we opened?
    $young = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
               Where-Object { $_.StartTime -ge $Since -and -not (Test-Path (Join-Path $ClaimDir "$($_.Id).claim")) })

    if ($young.Count -gt 0) {
        # Only now pay for CIM, and only for claude.exe: it is the one source
        # that carries the parent pid.
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue)) {
            $childPid = [int]$p.ProcessId
            if ($young.Id -notcontains $childPid) { continue }
            $parent = Get-Process -Id ([int]$p.ParentProcessId) -ErrorAction SilentlyContinue
            if (-not $parent -or $parent.ProcessName -ne $ParentName) { continue }
            if (-not (Claim-Pid $childPid)) { continue }
            $mine = $childPid
            break
        }
    }
    if ($mine) { break }
    if ((Get-Date) -ge $deadline) { break }
    Start-Sleep -Milliseconds $PollMs
}

if (-not $mine) { exit 1 }

# A window that already registered its session answered the trust prompt on its
# own (the folder was trusted before), and its input line is live - keys sent
# there would be typed into the conversation instead.
#
# The wait for the prompt happens inside poke, on the far side of the attach:
# it watches the window's own screen and presses as soon as the question is up,
# instead of this process guessing a duration from out here. -ReadyMs is only
# the fallback for when that watching is turned off.
if ($Keys -and -not (Test-Path (& $sessionFile $mine))) {
    $pokeArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PokePath`"",
        '-TargetPid', $mine,
        '-Keys', "`"$Keys`"",
        '-KeyDelayMs', $KeyDelayMs
    )
    if ($WaitFor) {
        $pokeArgs += @('-WaitFor', "`"$WaitFor`"", '-WaitMs', $WaitMs)
    } else {
        $pokeArgs += @('-ReadyMs', $ReadyMs)
    }
    Start-Process powershell -WindowStyle Hidden -Wait -ArgumentList $pokeArgs | Out-Null
}

if (-not $Color) { exit 0 }

# Colour goes on only once the window is past the prompt and has a session -
# that is also what the panel counts as running.
$colourBy = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $colourBy) {
    if (Test-Path (& $sessionFile $mine)) { break }
    Start-Sleep -Milliseconds 100
}
if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }

try {
    Invoke-WebRequest -Method POST -TimeoutSec 15 -UseBasicParsing `
        -Uri "http://127.0.0.1:$Port/api/color?id=$Id&name=$Name&pid=$mine" | Out-Null
} catch { }
