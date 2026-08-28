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
#   powershell -File poke.ps1 -TargetPid 36208 -Text "/color green"
#   powershell -File poke.ps1 -TargetPid 36208 -Keys "down,enter"
#   powershell -File poke.ps1 -TargetPid 36208 -Probe        # look, touch nothing

param(
    [Parameter(Mandatory = $true)][int]$TargetPid,
    [string]$Text,
    [string]$Keys,          # comma-separated key names, sent without any text
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace Con -Name Poke -MemberDefinition @'
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
    return WriteVk(h, 0x0D, '\r');                                     // VK_RETURN
}

// One bare key press. Arrows and the like carry no character: UnicodeChar stays
// '\0' so the TUI reads them as keys, not as text to insert.
public static int WriteVk(IntPtr h, ushort vk, char ch) {
    var recs = KeyPair(ch, vk, (ushort)MapVirtualKeyW(vk, 0));
    uint written;
    if (!WriteConsoleInput(h, recs, (uint)recs.Length, out written)) return -1;
    return (int)written;
}
'@

# Key names accepted by -Keys. Enter is the only one that carries a character.
$VkNames = @{
    'down'  = @(0x28, [char]0);  'up'    = @(0x26, [char]0)
    'left'  = @(0x25, [char]0);  'right' = @(0x27, [char]0)
    'enter' = @(0x0D, [char]13); 'tab'   = @(0x09, [char]9)
    'esc'   = @(0x1B, [char]27); 'space' = @(0x20, [char]32)
}

if (-not $Probe -and -not $Text -and -not $Keys) { Write-Error 'need -Text, -Keys or -Probe'; exit 2 }

$keyList = @()
if ($Keys) {
    foreach ($k in ($Keys -split ',')) {
        $k = $k.Trim().ToLowerInvariant()
        if (-not $k) { continue }
        if (-not $VkNames.ContainsKey($k)) { Write-Error "unknown key '$k'"; exit 2 }
        $keyList += ,$VkNames[$k]
    }
}

[void][Con.Poke]::FreeConsole()
if (-not [Con.Poke]::AttachConsole([uint32]$TargetPid)) {
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

$h = [Con.Poke]::Conin()
if ($h -eq [IntPtr]::new(-1)) {
    [void][Con.Poke]::FreeConsole()
    Write-Error 'could not open CONIN$ on that console'
    exit 1
}

$failed = $false
$done   = @()

if ($keyList.Count -gt 0) {
    # Bare keys: one at a time, with a gap - the TUI redraws between presses and
    # a menu that has not repainted yet swallows the next key.
    foreach ($key in $keyList) {
        $n = [Con.Poke]::WriteVk($h, [uint16]$key[0], [char]$key[1])
        if ($n -lt 0) { $failed = $true; break }
        $done += "vk$('{0:x2}' -f $key[0])"
        Start-Sleep -Milliseconds 250
    }
} else {
    $n1 = [Con.Poke]::Write($h, $Text)
    Start-Sleep -Milliseconds 150          # let the prompt settle before Enter
    $n2 = [Con.Poke]::WriteEnter($h)
    if ($n1 -lt 0 -or $n2 -lt 0) { $failed = $true }
    $done += "'$Text' + Enter"
}

[void][Con.Poke]::CloseHandle($h)
[void][Con.Poke]::FreeConsole()

if ($failed) { Write-Error "WriteConsoleInput failed. $report"; exit 1 }
Write-Output "sent $($done -join ', '). $report"
