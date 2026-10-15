# wmux spike S1: external foreground sampler (read-only).
# Samples GetForegroundWindow every 100 ms, logs every foreground change as
# JSONL and flags any sample where a spike process (s1.exe / s1w.exe) owns the
# foreground. Stops after -Minutes or when the -StopFile appears.
param(
    [Parameter(Mandatory)] [string] $Out,
    [string] $StopFile = "$Out.stop",
    [int] $Minutes = 30,
    [string[]] $Watch = @('s1', 's1w')
)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class S1Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@
$deadline = (Get-Date).AddMinutes($Minutes)
$lastPid = -1
$violations = 0
$samples = 0
function Emit($o) { ($o | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Out -Encoding utf8 }
Emit @{ t = (Get-Date).ToString('o'); ev = 'sampler_start'; watch = $Watch }
while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopFile)) {
    $h = [S1Fg]::GetForegroundWindow()
    $fgPid = [uint32]0
    [void][S1Fg]::GetWindowThreadProcessId($h, [ref]$fgPid)
    $samples++
    if ($fgPid -ne $lastPid) {
        $name = ''
        try { $name = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName } catch { }
        $bad = $Watch -contains $name
        if ($bad) { $violations++ }
        Emit @{ t = (Get-Date).ToString('o'); ev = 'fg_change'; pid = $fgPid; name = $name; spike_process = $bad }
        $lastPid = $fgPid
    }
    Start-Sleep -Milliseconds 100
}
Emit @{ t = (Get-Date).ToString('o'); ev = 'sampler_stop'; samples = $samples; violations = $violations }
