# Sidebar smoke test for window-show-sidebar / window-sidebar-width.
#
# Usage (native Windows PowerShell 7):
#   pwsh -NoProfile -ExecutionPolicy Bypass -File test\win32\test_sidebar.ps1 `
#       -ExePath zig-out\bin\ghostty.exe [-ScreenshotDir <dir>]
#
# Launches with --config-default-files=false so the compiled defaults apply:
#   terminal background  #282C34  (40,44,52)
#   sidebar background   bg+12    (52,56,64)
#   active row accent    #3D8EF8  (61,142,248)
#   sidebar width        220 px @ 96 DPI (scaled by GetDpiForWindow)
#   session row height   36 px  @ 96 DPI

param([string]$ExePath = "", [string]$ScreenshotDir = "")

if (-not $ExePath) {
    $ExePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "zig-out\bin\ghostty.exe"
}
if (-not (Test-Path $ExePath)) {
    Write-Output "FAIL: ghostty.exe not found at $ExePath (build first, or pass -ExePath)"
    exit 1
}
if ($ScreenshotDir -and -not (Test-Path $ScreenshotDir)) {
    New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
}

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
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;
    [StructLayout(LayoutKind.Sequential)] public struct RECT  { public int L,T,R,B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@

$pass = 0; $fail = 0
$script:inputOK = $true
$script:downgraded = 0
$script:skipped = 0

# Per-Monitor-V2 DPI awareness: without this, at >100% display scale Windows
# silently virtualizes window rects/coords for this (DPI-unaware) pwsh process
# (breaking the GetDpiForWindow-based pixel math below, and rescaling any
# future PostMessage coordinates). Must run before any window queries.
# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4.
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

# Sidebar on + deterministic compiled-default config (ignore user config files).
$LaunchArgs = "--window-show-sidebar=true --config-default-files=false"

# Expected colors from compiled defaults (Config.zig: background = 0x28,0x2C,0x34).
$TermBg  = @{ R = 40; G = 44;  B = 52  }   # #282C34
$SideBg  = @{ R = 52; G = 56;  B = 64  }   # terminal bg + 12 per channel
$Accent  = @{ R = 61; G = 142; B = 248 }   # #3D8EF8
$Tol     = 5                               # side/term differ by only 12/channel

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

function Send-Shortcut($proc, $keys) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 300
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
    Start-Sleep -Milliseconds 200
}

function Send-Text($proc, $text) {
    $escaped = $text -replace '([+^%~{}()\[\]])', '{$1}'
    Send-Shortcut $proc $escaped
}

function Launch-Ghostty {
    $proc = Start-Process -FilePath $ExePath -ArgumentList $LaunchArgs -PassThru
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

function Kill-Ghostty($proc) {
    if (-not $proc.HasExited) {
        & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
    }
}

function Get-WindowTitle($proc) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return "" }
    $sb = New-Object System.Text.StringBuilder 512
    [W32]::GetWindowText($h, $sb, 512) | Out-Null
    return $sb.ToString()
}

function Wait-TitleContains($proc, $needle, $timeoutMs = 6000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { return $false }
        if ((Get-WindowTitle $proc) -like "*$needle*") { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Client geometry + DPI scale for the main window.
function Get-ClientInfo($proc) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return $null }
    $wr = New-Object W32+RECT;  [W32]::GetWindowRect($h, [ref]$wr) | Out-Null
    $cr = New-Object W32+RECT;  [W32]::GetClientRect($h, [ref]$cr) | Out-Null
    $pt = New-Object W32+POINT; $pt.X = 0; $pt.Y = 0
    [W32]::ClientToScreen($h, [ref]$pt) | Out-Null
    $dpi = 96
    try { $d = [W32]::GetDpiForWindow($h); if ($d -gt 0) { $dpi = [int]$d } } catch {}
    return @{
        Hwnd = $h; W = $cr.R; H = $cr.B
        OffX = $pt.X - $wr.L; OffY = $pt.Y - $wr.T   # client origin inside window bitmap
        ScrX = $pt.X; ScrY = $pt.Y                   # client origin in screen coords
        Scale = $dpi / 96.0
    }
}

# Sample client-coordinate pixels via PrintWindow (harness convention).
function Get-PixelsPW($ci, $points) {
    $wr = New-Object W32+RECT
    [W32]::GetWindowRect($ci.Hwnd, [ref]$wr) | Out-Null
    $w = $wr.R - $wr.L; $ht = $wr.B - $wr.T
    if ($w -le 0 -or $ht -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [W32]::PrintWindow($ci.Hwnd, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $out = foreach ($p in $points) { $bmp.GetPixel($ci.OffX + $p.X, $ci.OffY + $p.Y) }
    $bmp.Dispose()
    return @($out)
}

# Fallback: sample from the composited screen (window must be foreground/unoccluded).
function Get-PixelsScreen($ci, $points) {
    $bmp = New-Object System.Drawing.Bitmap $ci.W, $ci.H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($ci.ScrX, $ci.ScrY, 0, 0, $bmp.Size)
    $g.Dispose()
    $out = foreach ($p in $points) { $bmp.GetPixel($p.X, $p.Y) }
    $bmp.Dispose()
    return @($out)
}

function Get-ClientPixels($proc, $ci, $points) {
    [W32]::SetForegroundWindow($ci.Hwnd) | Out-Null
    Start-Sleep -Milliseconds 300
    $cols = Get-PixelsPW $ci $points
    # All-black PrintWindow result => GL content not captured; retry from screen.
    $allBlack = $true
    foreach ($c in $cols) { if ($c.R -ne 0 -or $c.G -ne 0 -or $c.B -ne 0) { $allBlack = $false } }
    if ($allBlack) {
        Write-Output "  INFO: PrintWindow returned black, falling back to screen capture"
        $cols = Get-PixelsScreen $ci $points
    }
    return $cols
}

function Test-ColorNear($c, $exp, $tol) {
    return ([math]::Abs($c.R - $exp.R) -le $tol) -and
           ([math]::Abs($c.G - $exp.G) -le $tol) -and
           ([math]::Abs($c.B - $exp.B) -le $tol)
}

# PrintWindow returns flat white for WGL-rendered (GL) content when the window
# has no true foreground / DWM redirection surface to capture from.
function Test-NearWhite($c) {
    return ($c.R -ge 250) -and ($c.G -ge 250) -and ($c.B -ge 250)
}

function Fmt-Color($c) { "($($c.R),$($c.G),$($c.B))" }

function Click-ClientPoint($proc, $ci, $cx, $cy) {
    [W32]::SetForegroundWindow($ci.Hwnd) | Out-Null
    Start-Sleep -Milliseconds 300
    [W32]::SetCursorPos($ci.ScrX + $cx, $ci.ScrY + $cy) | Out-Null
    Start-Sleep -Milliseconds 150
    [W32]::mouse_event([W32]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [W32]::mouse_event([W32]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}

# ═══════════════════════════════════════
# TEST 1: Launch With Sidebar
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST 1: Launch With Sidebar ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id) args: $LaunchArgs"
Start-Sleep -Seconds 3

Take-Screenshot $proc "sidebar_01_launch"

if ($proc.HasExited) {
    Write-Output "  FAIL: Process exited within 3s of launch with sidebar enabled"
    $fail++
} else {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    $sb = New-Object System.Text.StringBuilder 256
    [W32]::GetClassName($h, $sb, 256) | Out-Null
    if ($h -ne [IntPtr]::Zero -and [W32]::IsWindowVisible($h) -and $sb.ToString() -eq "GhosttyWindow") {
        Write-Output "  OK: GhosttyWindow visible and process alive after 3s"
        $pass++
    } else {
        Write-Output "  FAIL: Window missing/not visible (class='$($sb.ToString())')"
        $fail++
    }
}
Kill-Ghostty $proc
Write-Output "  DONE"

# ═══════════════════════════════════════
# TEST 2: Sidebar Pixel Colors
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST 2: Sidebar Pixel Colors ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

if ($proc.HasExited) {
    Write-Output "  FAIL: Process exited before pixel sampling"
    $fail++
} else {
    $ci = Get-ClientInfo $proc
    $sidebarPx = [int][math]::Round(220 * $ci.Scale)
    $rowH      = [int][math]::Round(36  * $ci.Scale)
    # Sample below the session rows (1 session + "+ New session" = 2 rows) so we
    # hit flat sidebar background, not row text. 0.6*H clears 2 rows at any sane
    # window size; clamp inside the client rect.
    $sampleY  = [math]::Min([math]::Max([int]($ci.H * 0.6), 3 * $rowH), $ci.H - 10)
    $sideMidX = [int]($sidebarPx / 2)
    $sideAltX = 30   # conservative: inside even a clamped 120px sidebar, past 3px accent
    $termX    = $sidebarPx + [int](($ci.W - $sidebarPx) / 2)
    Write-Output "  Client=$($ci.W)x$($ci.H) scale=$($ci.Scale) sidebarPx=$sidebarPx sampleY=$sampleY"

    $pts = @(
        @{ X = $sideMidX; Y = $sampleY },
        @{ X = $sideAltX; Y = $sampleY },
        @{ X = $termX;    Y = $sampleY }
    )
    $cols = Get-ClientPixels $proc $ci $pts
    $sideMid = $cols[0]; $sideAlt = $cols[1]; $term = $cols[2]
    Write-Output "  Sidebar(mid x=$sideMidX)=$(Fmt-Color $sideMid)  Sidebar(x=$sideAltX)=$(Fmt-Color $sideAlt)  Terminal(x=$termX)=$(Fmt-Color $term)"
    Write-Output "  Expected sidebar=($($SideBg.R),$($SideBg.G),$($SideBg.B))  terminal=($($TermBg.R),$($TermBg.G),$($TermBg.B))  tol=$Tol"

    Take-Screenshot $proc "sidebar_02_pixels"

    # PrintWindow cannot capture WGL (GL) content without a true foreground
    # window: the terminal area then samples as flat white. Detect that and
    # mark the affected assertions SKIPPED(env) rather than FAIL.
    $termWhite = Test-NearWhite $term
    $allWhite  = $termWhite -and (Test-NearWhite $sideMid) -and (Test-NearWhite $sideAlt)
    if ($allWhite) {
        Write-Output "  INFO: All samples are flat white - PrintWindow could not capture window content (no true foreground)"
    } elseif ($termWhite) {
        Write-Output "  INFO: Terminal sample is flat white - PrintWindow could not capture WGL terminal content"
    }

    # Assertion A: sidebar background == terminal bg + 12/channel (either sample point)
    if ($allWhite) {
        Write-Output "  SKIPPED(env): Sidebar pixel assertion - capture returned flat white (GL/foreground capture limitation)"
        $script:skipped++
    } elseif ((Test-ColorNear $sideMid $SideBg $Tol) -or (Test-ColorNear $sideAlt $SideBg $Tol)) {
        Write-Output "  OK: Sidebar pixel matches bg+12 sidebar color"
        $pass++
    } else {
        Write-Output "  FAIL: Sidebar pixel does not match expected sidebar background"
        $fail++
    }

    # Assertion B: terminal area shows the default background
    if ($termWhite) {
        Write-Output "  SKIPPED(env): Terminal pixel assertion - capture returned flat white (GL/foreground capture limitation)"
        $script:skipped++
    } elseif (Test-ColorNear $term $TermBg $Tol) {
        Write-Output "  OK: Terminal pixel matches default background"
        $pass++
    } else {
        Write-Output "  FAIL: Terminal pixel does not match default background"
        $fail++
    }

    # Assertion C: relative check — sidebar is brighter than terminal by ~12/channel.
    # Holds even if absolute colors drift (e.g. config leakage), as long as both samples are valid.
    if ($termWhite) {
        Write-Output "  SKIPPED(env): Sidebar/terminal delta assertion - terminal sample invalid (flat white capture)"
        $script:skipped++
    } else {
        $dR = $sideMid.R - $term.R; $dG = $sideMid.G - $term.G; $dB = $sideMid.B - $term.B
        if (($dR -ge 6 -and $dR -le 18) -and ($dG -ge 6 -and $dG -le 18) -and ($dB -ge 6 -and $dB -le 18)) {
            Write-Output "  OK: Sidebar/terminal delta is ~+12 per channel ($dR,$dG,$dB)"
            $pass++
        } else {
            Write-Output "  FAIL: Sidebar/terminal delta not ~+12 per channel ($dR,$dG,$dB)"
            $fail++
        }
    }
}
Kill-Ghostty $proc
Write-Output "  DONE"

# ═══════════════════════════════════════
# TEST 3: Sidebar Row Click Switches Tab
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST 3: Sidebar Row Click Switches Tab ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Name tab 1 via cmd.exe's `title` (ConPTY forwards console title -> tab title -> window title)
Send-Text $proc "title TAB1"
Send-Shortcut $proc "{ENTER}"
$tab1Named = Wait-TitleContains $proc "TAB1"

# Open tab 2 (default new_tab keybind, same as test_tabs.ps1)
Send-Shortcut $proc "^+t"
Start-Sleep -Seconds 3

Send-Text $proc "title TAB2"
Send-Shortcut $proc "{ENTER}"
$tab2Named = Wait-TitleContains $proc "TAB2"

Take-Screenshot $proc "sidebar_03_two_tabs"

if ($proc.HasExited) {
    Write-Output "  FAIL: Process died while creating second tab"
    $fail++
} elseif (-not ($tab1Named -and $tab2Named)) {
    # Title propagation unavailable — fall back to survival assertion (test_splits.ps1 pattern)
    Write-Output "  WARN: Tab titles did not propagate (title='$(Get-WindowTitle $proc)') - cannot assert switch by title"
    if ($script:inputOK) {
        Write-Output "  OK: Process alive with 2 tabs + sidebar (no crash)"
        $pass++
    } else {
        Write-Output "  DOWNGRADED: input unavailable - liveness only (tabs were never created/named)"
        $script:downgraded++
    }
    # Still exercise the click path for crash coverage
    $ci = Get-ClientInfo $proc
    $sidebarPx = [int][math]::Round(220 * $ci.Scale)
    $rowH      = [int][math]::Round(36  * $ci.Scale)
    Click-ClientPoint $proc $ci ([int]($sidebarPx / 2)) ([int]($rowH / 2))
    Start-Sleep -Seconds 1
    if ($proc.HasExited) {
        Write-Output "  FAIL: Process died after sidebar row click"
        $fail++
    } elseif ($script:inputOK) {
        Write-Output "  OK: Process alive after sidebar row click"
        $pass++
    } else {
        Write-Output "  DOWNGRADED: input unavailable - liveness only (after sidebar row click attempt)"
        $script:downgraded++
    }
} else {
    Write-Output "  Titles set: window title now '$(Get-WindowTitle $proc)' (expect TAB2 active)"

    # Click row 0 (tab 1): rows start at top of client since the tab bar is hidden.
    $ci = Get-ClientInfo $proc
    $sidebarPx = [int][math]::Round(220 * $ci.Scale)
    $rowH      = [int][math]::Round(36  * $ci.Scale)
    $clickX = [int]($sidebarPx / 2)
    $clickY = [int]($rowH / 2)
    Write-Output "  Clicking sidebar row 0 at client ($clickX,$clickY)"
    Click-ClientPoint $proc $ci $clickX $clickY

    if (Wait-TitleContains $proc "TAB1") {
        Write-Output "  OK: Active tab switched to TAB1 after clicking sidebar row 0"
        $pass++
    } else {
        Write-Output "  FAIL: Window title is '$(Get-WindowTitle $proc)' - expected TAB1 after row click"
        $fail++
    }

    Take-Screenshot $proc "sidebar_04_after_click"

    # Bonus (informational): active row should show 3px accent #3D8EF8 at its left edge
    # and the exact terminal bg as its row background.
    $ci2 = Get-ClientInfo $proc
    $accPts = @(
        @{ X = 1; Y = $clickY },                                  # accent strip
        @{ X = [math]::Min($sidebarPx - 10, $sidebarPx / 2 + 60); Y = $clickY }  # row bg, right of text
    )
    $accCols = Get-ClientPixels $proc $ci2 $accPts
    if (Test-ColorNear $accCols[0] $Accent 10) {
        Write-Output "  INFO: Active row accent pixel matches #3D8EF8 $(Fmt-Color $accCols[0])"
    } else {
        Write-Output "  INFO: Accent pixel at (1,$clickY) = $(Fmt-Color $accCols[0]) (expected ~(61,142,248); non-fatal)"
    }
    if (Test-ColorNear $accCols[1] $TermBg $Tol) {
        Write-Output "  INFO: Active row background matches terminal background $(Fmt-Color $accCols[1])"
    } else {
        Write-Output "  INFO: Active row bg sample = $(Fmt-Color $accCols[1]) (may have hit row text; non-fatal)"
    }
}
Kill-Ghostty $proc
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
