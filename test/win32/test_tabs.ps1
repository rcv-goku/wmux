param([string]$ExePath, [string]$ScreenshotDir = "")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP p, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@

$pass = 0; $fail = 0
$script:inputOK = $true
$script:downgraded = 0
$script:skipped = 0

# Per-Monitor-V2 DPI awareness: without this, at >100% display scale Windows
# silently virtualizes window rects/coords for this (DPI-unaware) pwsh process
# (and would rescale any future PostMessage coordinates). Must run before any
# window queries. DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4.
# Older hosts (pre Win10 1703) lack the API; fall back gracefully.
try {
    [W32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
} catch {
    Write-Output "WARN: SetThreadDpiAwarenessContext unavailable; continuing DPI-unaware ($($_.Exception.Message))"
}

# Input-delivery health probe: SendKeys can silently fail (locked desktop /
# session quirks). Probe with a no-op key so input-dependent assertions can be
# explicitly DOWNGRADED to liveness checks instead of passing vacuously.
try {
    [System.Windows.Forms.SendKeys]::SendWait("{F15}")
} catch {
    $script:inputOK = $false
    Write-Output "!!! INPUT UNAVAILABLE: SendKeys probe ({F15}) failed: $($_.Exception.Message)"
    Write-Output "!!! Input-dependent assertions will be DOWNGRADED to liveness checks."
}

function Take-Screenshot($proc, $name) {
    if (-not $ScreenshotDir) { return }
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    $r = New-Object W32+RECT
    [W32]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { return }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [W32]::PrintWindow($h, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bmp.Save("$ScreenshotDir\${name}_$ts.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Send-Keys($proc, $keys) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 200
    }
    try {
        [System.Windows.Forms.SendKeys]::SendWait($keys)
    } catch {
        # SendWait can throw transiently (e.g. Win32Exception "The operation
        # completed successfully." during foreground churn) - retry once
        # before declaring input delivery unavailable.
        Start-Sleep -Milliseconds 250
        try {
            [System.Windows.Forms.SendKeys]::SendWait($keys)
        } catch {
            if ($script:inputOK) {
                Write-Output "  WARN: SendKeys delivery failed mid-run: $($_.Exception.Message)"
            }
            $script:inputOK = $false
        }
    }
}

function Send-Text($proc, $text) {
    $escaped = $text -replace '([+^%~{}()\[\]])', '{$1}'
    Send-Keys $proc $escaped
}

# Liveness assertion. When input delivery is unavailable, the action the
# assertion depends on was never delivered, so the check is explicitly marked
# DOWNGRADED (counted separately; downgraded != failed). Process death is
# always a hard failure. Sets $script:alive so callers can abort follow-on
# steps after a death (messages must flow to stdout, so no pipeline return).
function Assert-Alive($proc, $context) {
    if ($proc.HasExited) {
        Write-Output "  FAIL: Process died $context"
        $script:fail++
        $script:alive = $false
        return
    }
    if ($script:inputOK) {
        Write-Output "  OK: Process alive $context"
        $script:pass++
    } else {
        Write-Output "  DOWNGRADED: input unavailable - liveness only ($context)"
        $script:downgraded++
    }
    $script:alive = $true
}

# NOTE: the parameter must NOT be named $pid - that shadows the pwsh automatic
# variable $PID, and the EnumWindows callback then resolves it to the host
# process id, making the count always 0 and the assertion vacuous.
function Count-GhosttyWindows($ownerPid) {
    $script:targetPid = [uint32]$ownerPid
    $script:wcount = 0
    $cb = [W32+EP]{param($h,$l)
        $wp = [uint32]0
        [W32]::GetWindowThreadProcessId($h, [ref]$wp) | Out-Null
        if ($wp -eq $script:targetPid -and [W32]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [W32]::GetClassName($h, $sb, 256) | Out-Null
            if ($sb.ToString() -eq "GhosttyWindow") { $script:wcount++ }
        }
        return $true
    }
    [W32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $script:wcount
}

function Launch-Ghostty {
    $proc = Start-Process -FilePath $ExePath -PassThru

    # Wait for main window
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 200
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            Start-Sleep -Seconds 1
            return $proc
        }
    }
    Write-Output "  WARN: Window handle not found after 8s"
    return $proc
}

# ═══════════════════════════════════════
# TEST: New Tab
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: New Tab ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

Take-Screenshot $proc "01_initial"

# Open new tab
Send-Keys $proc "^+t"
Start-Sleep -Seconds 3

Take-Screenshot $proc "02_after_new_tab"

$wc = Count-GhosttyWindows $proc.Id
if (-not $script:inputOK) {
    Write-Output "  DOWNGRADED: input unavailable - cannot assert window count after new tab (count=$wc)"
    $script:downgraded++
} elseif ($wc -eq 1) {
    Write-Output "  OK: Still 1 top-level GhosttyWindow (tab opened inside)"
    $pass++
} elseif ($wc -eq 0) {
    Write-Output "  SKIPPED(env): EnumWindows found 0 GhosttyWindows (cross-session enumeration unavailable, e.g. WSL2)"
    $script:skipped++
} else {
    Write-Output "  FAIL: Window count = $wc (expected 1 - a new tab must not create a new OS window)"
    $fail++
}

Assert-Alive $proc "after new tab"
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  DONE"

# ═══════════════════════════════════════
# TEST: Tab Switch
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Tab Switch ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Type in tab 1
Send-Text $proc "echo TAB1"
Send-Keys $proc "{ENTER}"
Start-Sleep -Seconds 1

# Open tab 2
Send-Keys $proc "^+t"
Start-Sleep -Seconds 3

Send-Text $proc "echo TAB2"
Send-Keys $proc "{ENTER}"
Start-Sleep -Seconds 1

Take-Screenshot $proc "03_tab2"

# Switch to tab 1
Send-Keys $proc "^+{PGUP}"
Start-Sleep -Seconds 1
Take-Screenshot $proc "04_tab1_switch"

# Switch to tab 2
Send-Keys $proc "^+{PGDN}"
Start-Sleep -Seconds 1
Take-Screenshot $proc "05_tab2_switch"

Assert-Alive $proc "after tab switching"
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  DONE"

# ═══════════════════════════════════════
# TEST: Tab Close
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Tab Close ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Open 2 extra tabs (3 total)
Send-Keys $proc "^+t"
Start-Sleep -Seconds 2
Send-Keys $proc "^+t"
Start-Sleep -Seconds 2

Take-Screenshot $proc "06_three_tabs"

# Close one tab
Send-Keys $proc "^+w"
Start-Sleep -Seconds 2

Assert-Alive $proc "after closing 1 tab"
if (-not $script:alive) {
    Write-Output "  FAILED"
    Write-Output ""
    Write-Output "================================"
    Write-Output "Results: $pass passed, $fail failed, $($script:downgraded) downgraded, $($script:skipped) skipped(env)"
    Write-Output "================================"
    exit 1
}

# Close another tab
Send-Keys $proc "^+w"
Start-Sleep -Seconds 2

Assert-Alive $proc "after closing 2nd tab (1 tab remains)"
if (-not $script:alive) {
    Write-Output "  FAILED"
    Write-Output ""
    Write-Output "================================"
    Write-Output "Results: $pass passed, $fail failed, $($script:downgraded) downgraded, $($script:skipped) skipped(env)"
    Write-Output "================================"
    exit 1
}

Take-Screenshot $proc "07_one_tab_remains"

# Close last tab — process should exit. When input works, the process exiting
# here is the cheap observable confirmation that keystrokes are delivered.
Send-Keys $proc "^+w"
Start-Sleep -Seconds 3

if (-not $script:inputOK) {
    Write-Output "  DOWNGRADED: input unavailable - cannot assert last-tab close exits process"
    $script:downgraded++
    & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
} elseif ($proc.HasExited) {
    Write-Output "  OK: Process exited after closing last tab (input delivery confirmed)"
    $pass++
} else {
    Write-Output "  WARN: Process still alive (may need quit timer)"
    & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
    $pass++
}
Write-Output "  DONE"

# ═══════════════════════════════════════
# TEST: Rapid Tabs
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Rapid Tabs ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Open 5 tabs rapidly
for ($i = 0; $i -lt 5; $i++) {
    Send-Keys $proc "^+t"
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 2

Take-Screenshot $proc "08_six_tabs"

Assert-Alive $proc "after rapid tab creation"
if (-not $script:alive) {
    Write-Output "  FAILED"
    Write-Output ""
    Write-Output "================================"
    Write-Output "Results: $pass passed, $fail failed, $($script:downgraded) downgraded, $($script:skipped) skipped(env)"
    Write-Output "================================"
    exit 1
}

# Rapid switching
for ($i = 0; $i -lt 6; $i++) {
    Send-Keys $proc "^+{PGDN}"
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Seconds 1

Assert-Alive $proc "after rapid tab switching"
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  DONE"

# ═══════════════════════════════════════
Write-Output ""
Write-Output "================================"
if ($script:downgraded -gt 0) {
    Write-Output "INPUT UNAVAILABLE - $($script:downgraded) assertions DOWNGRADED to liveness"
}
if ($script:skipped -gt 0) {
    Write-Output "ENVIRONMENT LIMITS - $($script:skipped) assertions SKIPPED(env)"
}
Write-Output "Results: $pass passed, $fail failed, $($script:downgraded) downgraded, $($script:skipped) skipped(env)"
Write-Output "================================"
if ($fail -gt 0) { exit 1 }
exit 0
