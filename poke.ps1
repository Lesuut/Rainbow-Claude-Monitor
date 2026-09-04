# Types a line into another console process's input buffer, exactly as if it had
# been typed at that window's keyboard, then presses Enter.
#
# Target is a pid, not a window title: the Claude windows are Windows Terminal
# tabs whose titles Claude Code rewrites to the conversation topic, so titles are
# useless for aiming. A pid maps straight onto the ConPTY behind that tab.
#
# Runs as its own short-lived process on purpose: AttachConsole binds to one
# console at a time and requires dropping the caller's own console first, so the
# server must never do this in-process.
#
# The interop is compiled once into .cache\poke.dll and loaded from there on
# every later run. Compiling the C# from source costs a second or two of csc on
# each poke, which used to be most of the delay between clicking Launch and the
# window taking its colour; loading the cached assembly costs milliseconds.
#
# -WaitFor holds the keys back until that text is actually on the target's
# screen. A brand-new window needs an unknown moment before its trust prompt is
# drawn, and a fixed sleep has to be either too long or too short; waiting for
# the prompt itself is both faster and safer - when the folder was trusted long
# ago the prompt never appears, the wait times out, and nothing is typed into
# what is by then a live input line.
#
#   powershell -File poke.ps1 -TargetPid 36208 -Text "/color green"
#   powershell -File poke.ps1 -TargetPid 36208 -Keys "down,enter"
#   powershell -File poke.ps1 -TargetPid 36208 -Keys "down,enter" -WaitFor trust
#   powershell -File poke.ps1 -TargetPid 36208 -Keys "down,enter" -Text "/color green"
#   powershell -File poke.ps1 -Warm                          # build the cache, touch nothing
#   powershell -File poke.ps1 -TargetPid 36208 -Probe        # look, touch nothing
#   powershell -File poke.ps1 -TargetPid 36208 -Screen       # dump that screen
#
# Exit codes: 0 sent, 1 could not reach the console, 2 bad arguments,
# 3 -WaitFor never showed up and nothing was sent.

param(
    [int]$TargetPid,
    [string]$Text,
    [string]$Keys,              # comma-separated key names, sent before -Text
    [int]$KeyDelayMs = 90,      # gap between two bare key presses
    [int]$EnterDelayMs = 40,    # gap between the typed line and its Enter
    [string]$WaitFor,           # hold the keys until this text is on screen
    [int]$WaitMs = 4000,        # how long to wait for it
    [int]$WaitPollMs = 60,      # gap between two looks at the screen
    [int]$GraceMs = 100,        # after the text shows up, before the first key
    [int]$ReadyMs = 0,          # flat wait after attaching, before anything else
    [int]$AttachMs = 2500,      # keep retrying AttachConsole for this long
    [switch]$Probe,
    [switch]$Screen,            # print the target's visible screen and exit
    [switch]$Warm               # compile the cache and exit
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$CacheDir = Join-Path $Root '.cache'
$DllPath  = Join-Path $CacheDir 'poke.dll'

$Source = @'
using System;
using System.Runtime.InteropServices;

namespace Con {
public static class Poke {
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint GetConsoleProcessList(uint[] buf, uint count);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disposition, uint flags, IntPtr template);

    [DllImport("user32.dll")] public static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT { public short Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CSBI {
        public COORD dwSize;
        public COORD dwCursorPosition;
        public ushort wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len,
                                                          COORD at, out uint read);

    // What the target window is showing right now, one line per screen row, or
    // null when its screen cannot be read. Only the visible rows are taken: the
    // scrollback behind them can be thousands of lines and says nothing about
    // the prompt that is up at this moment.
    public static string Screen() {
        IntPtr h = CreateFile("CONOUT$", 0x80000000u | 0x40000000u, 1u | 2u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
        if (h == new IntPtr(-1)) return null;
        try {
            CSBI info;
            if (!GetConsoleScreenBufferInfo(h, out info)) return null;
            int w = info.dwSize.X;
            if (w <= 0) return null;
            var sb = new System.Text.StringBuilder();
            var buf = new char[w];
            for (short y = info.srWindow.Top; y <= info.srWindow.Bottom; y++) {
                uint read;
                COORD at; at.X = 0; at.Y = y;
                if (!ReadConsoleOutputCharacterW(h, buf, (uint)w, at, out read)) break;
                sb.Append(buf, 0, (int)read);
                sb.Append('\n');
            }
            return sb.ToString();
        } finally {
            CloseHandle(h);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD {
        [MarshalAs(UnmanagedType.Bool)] public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char   UnicodeChar;
        public uint   dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);

    public static IntPtr Conin() {
        // CONIN$, not GetStdHandle: our inherited handles belong to the console we
        // just detached from and are stale the moment we attach elsewhere.
        return CreateFile("CONIN$", 0x80000000 | 0x40000000, 1 | 2, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }

    public static uint[] Attached() {
        var buf = new uint[16];
        uint n = GetConsoleProcessList(buf, (uint)buf.Length);
        var outp = new uint[n];
        for (int i = 0; i < n && i < buf.Length; i++) outp[i] = buf[i];
        return outp;
    }

    // A key press is two records: down then up. Real virtual-key and scan codes
    // matter - a TUI that reads key events, not just characters, ignores a record
    // whose wVirtualKeyCode is zero.
    static INPUT_RECORD[] KeyPair(char ch, ushort vk, ushort sc) {
        var pair = new INPUT_RECORD[2];
        for (int d = 0; d < 2; d++) {
            pair[d].EventType = 1;                        // KEY_EVENT
            pair[d].KeyEvent.bKeyDown = (d == 0);
            pair[d].KeyEvent.wRepeatCount = 1;
            pair[d].KeyEvent.wVirtualKeyCode = vk;
            pair[d].KeyEvent.wVirtualScanCode = sc;
            pair[d].KeyEvent.UnicodeChar = ch;
            pair[d].KeyEvent.dwControlKeyState = 0;
        }
        return pair;
    }

    public static int Write(IntPtr h, string text) {
        var recs = new System.Collections.Generic.List<INPUT_RECORD>();
        foreach (char ch in text) {
            short scan = VkKeyScanW(ch);
            ushort vk = (ushort)(scan == -1 ? 0 : (scan & 0xFF));
            ushort sc = (ushort)MapVirtualKeyW(vk, 0);    // MAPVK_VK_TO_VSC
            recs.AddRange(KeyPair(ch, vk, sc));
        }
        uint written;
        var arr = recs.ToArray();
        if (!WriteConsoleInput(h, arr, (uint)arr.Length, out written)) return -1;
        return (int)written;
    }

    public static int WriteEnter(IntPtr h) {
        return WriteVk(h, 0x0D, '\r');                    // VK_RETURN
    }

    // One bare key press. Arrows and the like carry no character: UnicodeChar stays
    // '\0' so the TUI reads them as keys, not as text to insert.
    public static int WriteVk(IntPtr h, ushort vk, char ch) {
        var recs = KeyPair(ch, vk, (ushort)MapVirtualKeyW(vk, 0));
        uint written;
        if (!WriteConsoleInput(h, recs, (uint)recs.Length, out written)) return -1;
        return (int)written;
    }
}
}
'@

# Loads Con.Poke, compiling it into the cache first when that file is missing or
# older than this script. The build goes to a private name and is then moved into
# place, so two pokes racing at the same moment cannot read a half-written dll; a
# lost race is harmless, both files hold the same code.
function Import-Poke {
    param([switch]$Rebuild)

    $fresh = (Test-Path $DllPath) -and
             ((Get-Item $DllPath).LastWriteTimeUtc -ge (Get-Item $PSCommandPath).LastWriteTimeUtc)

    if ($fresh -and -not $Rebuild) {
        try {
            [void][Reflection.Assembly]::LoadFrom($DllPath)
            return
        } catch { }   # unreadable, or built by another runtime - make it again
    }

    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $tmp = Join-Path $CacheDir ("poke-{0}.dll" -f [Guid]::NewGuid().ToString('N'))
    Add-Type -TypeDefinition $Source -OutputAssembly $tmp -OutputType Library
    try {
        Move-Item -LiteralPath $tmp -Destination $DllPath -Force
        $load = $DllPath
    } catch {
        # Another poke won the race and holds the file open. Load our own copy.
        $load = $tmp
    }
    [void][Reflection.Assembly]::LoadFrom($load)
}

if ($Warm) {
    Import-Poke -Rebuild
    Write-Output "poke.dll ready: $DllPath"
    exit 0
}

if (-not $TargetPid) { Write-Error 'need -TargetPid'; exit 2 }
if (-not $Probe -and -not $Screen -and -not $Text -and -not $Keys) {
    Write-Error 'need -Text, -Keys, -Probe or -Screen'
    exit 2
}

# Key names accepted by -Keys. Enter is the only one that carries a character.
$VkNames = @{
    'down'  = @(0x28, [char]0);  'up'    = @(0x26, [char]0)
    'left'  = @(0x25, [char]0);  'right' = @(0x27, [char]0)
    'enter' = @(0x0D, [char]13); 'tab'   = @(0x09, [char]9)
    'esc'   = @(0x1B, [char]27); 'space' = @(0x20, [char]32)
}

$keyList = @()
if ($Keys) {
    foreach ($k in ($Keys -split ',')) {
        $k = $k.Trim().ToLowerInvariant()
        if (-not $k) { continue }
        if (-not $VkNames.ContainsKey($k)) { Write-Error "unknown key '$k'"; exit 2 }
        $keyList += ,$VkNames[$k]
    }
}

Import-Poke

[void][Con.Poke]::FreeConsole()

# A console that belongs to a process started a moment ago is not attachable
# for the first fraction of a second. Retrying beats being launched late.
$attachBy = (Get-Date).AddMilliseconds($AttachMs)
$attached = $false
while ($true) {
    if ([Con.Poke]::AttachConsole([uint32]$TargetPid)) { $attached = $true; break }
    if ((Get-Date) -ge $attachBy) { break }
    Start-Sleep -Milliseconds 50
}
if (-not $attached) {
    Write-Error "AttachConsole($TargetPid) failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"
    exit 1
}

$names = foreach ($p in [Con.Poke]::Attached()) {
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($proc) { "$($proc.ProcessName)($p)" } else { "?($p)" }
}
$report = "console of pid ${TargetPid}: " + ($names -join ', ')

if ($Probe) {
    [void][Con.Poke]::FreeConsole()
    Write-Output $report
    exit 0
}

if ($Screen) {
    $shot = [Con.Poke]::Screen()
    [void][Con.Poke]::FreeConsole()
    if ($null -eq $shot) { Write-Error "could not read the screen of pid $TargetPid"; exit 1 }
    Write-Output $shot
    exit 0
}

if ($ReadyMs -gt 0) { Start-Sleep -Milliseconds $ReadyMs }

# Wait for the prompt these keys are meant to answer. A screen that cannot be
# read at all is not evidence that the prompt is absent - on such a console fall
# back to the old blind wait rather than leaving the window sitting on its
# question forever.
if ($WaitFor) {
    $seen = $false
    $readable = $true
    $waitBy = (Get-Date).AddMilliseconds($WaitMs)
    while ($true) {
        $shot = [Con.Poke]::Screen()
        if ($null -eq $shot) { $readable = $false; break }
        if ($shot.IndexOf($WaitFor, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $seen = $true; break }
        if ((Get-Date) -ge $waitBy) { break }
        Start-Sleep -Milliseconds $WaitPollMs
    }

    if (-not $readable) {
        Start-Sleep -Milliseconds 600
    } elseif (-not $seen) {
        [void][Con.Poke]::FreeConsole()
        Write-Output "'$WaitFor' never appeared, sent nothing. $report"
        exit 3
    } elseif ($GraceMs -gt 0) {
        Start-Sleep -Milliseconds $GraceMs      # let the prompt finish drawing
    }
}

$h = [Con.Poke]::Conin()
if ($h -eq [IntPtr]::new(-1)) {
    [void][Con.Poke]::FreeConsole()
    Write-Error 'could not open CONIN$ on that console'
    exit 1
}

$failed = $false
$done   = @()

# Bare keys: one at a time, with a gap - the TUI redraws between presses and a
# menu that has not repainted yet swallows the next key.
foreach ($key in $keyList) {
    $n = [Con.Poke]::WriteVk($h, [uint16]$key[0], [char]$key[1])
    if ($n -lt 0) { $failed = $true; break }
    $done += "vk$('{0:x2}' -f $key[0])"
    if ($KeyDelayMs -gt 0) { Start-Sleep -Milliseconds $KeyDelayMs }
}

# -Keys and -Text in one run: the trust prompt and the /color line are answered
# by a single process instead of paying PowerShell's startup twice.
if (-not $failed -and $Text) {
    $n1 = [Con.Poke]::Write($h, $Text)
    if ($EnterDelayMs -gt 0) { Start-Sleep -Milliseconds $EnterDelayMs }   # let the prompt settle
    $n2 = [Con.Poke]::WriteEnter($h)
    if ($n1 -lt 0 -or $n2 -lt 0) { $failed = $true }
    $done += "'$Text' + Enter"
}

[void][Con.Poke]::CloseHandle($h)
[void][Con.Poke]::FreeConsole()

if ($failed) { Write-Error "WriteConsoleInput failed. $report"; exit 1 }
Write-Output "sent $($done -join ', '). $report"
