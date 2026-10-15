# S2 hidden-instance spike (W0-D-S2): launch a patched debug wmux.exe with
# WMUX_TEST_HIDDEN=1 in an isolated state root and verify, under a foreground
# sampler watching the whole process tree:
#   (1) ConPTY + shell over the legacy pipe (send "echo hi", read-screen)
#   (2) OpenGL output visible to PrintWindow(PW_RENDERFULLCONTENT) -> PNG
#   (3) a WebView2 browser tab is created and navigated (eval round trips)
#   (4) the foreground never belongs to the instance tree; user fg unchanged
#   (5) no taskbar button (UI Automation) and no Alt-Tab candidate
#
#   pwsh -NoProfile -File run-wmux-hidden.ps1 -Exe <wmux.exe> -OutDir <dir> [-Placement offscreen|cloak] [-Focus gate|keep] [-WebView2Args '<flags>'] [-Taskbar]
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $OutDir,
    [ValidateSet('offscreen', 'cloak')] [string] $Placement = 'offscreen',
    [ValidateSet('gate', 'keep')] [string] $Focus = 'gate',
    [string] $WebView2Args = '',
    [string] $Tag = 'wmux',
    [switch] $Taskbar,
    [switch] $NoBrowser,
    [switch] $GracefulStop,
    [int] $IntervalMs = 50,
    [int] $TimeoutSec = 45
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'S2Native.cs')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$clock = [Diagnostics.Stopwatch]::StartNew()
$report = [ordered]@{ tag = $Tag; placement = $Placement; focus = $Focus; webview2_args = $WebView2Args; steps = [ordered]@{} }
function Step([string]$name, $value) { $report.steps[$name] = $value; Write-Host ("[{0,6}ms] {1}: {2}" -f $clock.ElapsedMilliseconds, $name, ($value | ConvertTo-Json -Compress -Depth 5)) }

function Get-TaskbarButtons {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [System.Windows.Automation.AutomationElement]
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($cls in 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd') {
        $cond = [System.Windows.Automation.PropertyCondition]::new($A::ClassNameProperty, $cls)
        foreach ($tray in $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            $bc = [System.Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
            foreach ($b in $tray.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
                if ($b.Current.AutomationId -like 'Appid:*') { $out.Add("$cls|$($b.Current.AutomationId)|$($b.Current.Name)") }
            }
        }
    }
    return , $out
}

function Wait-Until([scriptblock]$cond, [int]$timeoutMs, [int]$intervalMs = 100) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $v = & $cond
        if ($v) { return $v }
        Start-Sleep -Milliseconds $intervalMs
    }
    return $null
}

# ------------------------------------------------------------ isolation root
$root = Join-Path $OutDir "$Tag-root"
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
$lad = Join-Path $root 'localappdata'
New-Item -ItemType Directory -Force (Join-Path $lad 'ghostty'), (Join-Path $root 'xdg-config\ghostty'), (Join-Path $root 'xdg-state'), (Join-Path $root 'xdg-cache') | Out-Null
# A fresh update_check_at keeps the instance off the network and away from tray balloons.
[DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() | Set-Content -NoNewline (Join-Path $lad 'ghostty\update_check_at')
@(
    'command = cmd.exe /d /k prompt WMUX$G'
    'confirm-close-surface = false'
) | Set-Content (Join-Path $root 'xdg-config\ghostty\config.ghostty')

$exeDir = Split-Path $Exe
if (-not (Test-Path (Join-Path $exeDir 'WebView2Loader.dll'))) { throw "WebView2Loader.dll missing next to $Exe" }

# ------------------------------------------------------------------ launch
if ($Taskbar) { $tbBefore = Get-TaskbarButtons }
$sampler = [FgSampler]::new()
$sampler.IntervalMs = $IntervalMs
$sampler.Start()
Step 'launcher_rights' ([S2Native]::ForegroundRightsProbe())

$psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $true
$psi.WorkingDirectory = $root
foreach ($k in @($psi.Environment.Keys)) { if ($k -match '^(GHOSTTY_|WMUX_|CMUX_)') { [void]$psi.Environment.Remove($k) } }
$psi.Environment['LOCALAPPDATA'] = $lad
$psi.Environment['XDG_CONFIG_HOME'] = Join-Path $root 'xdg-config'
$psi.Environment['XDG_STATE_HOME'] = Join-Path $root 'xdg-state'
$psi.Environment['XDG_CACHE_HOME'] = Join-Path $root 'xdg-cache'
$psi.Environment['WMUX_TEST_HIDDEN'] = '1'
$psi.Environment['WMUX_TEST_HIDDEN_PLACEMENT'] = $Placement
$psi.Environment['WMUX_TEST_HIDDEN_FOCUS'] = $Focus
if ($WebView2Args) { $psi.Environment['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'] = $WebView2Args }

$t0 = $clock.ElapsedMilliseconds
$proc = [System.Diagnostics.Process]::Start($psi)
$sampler.RootPid = [uint32]$proc.Id
$errTask = $proc.StandardError.ReadToEndAsync()
$outTask = $proc.StandardOutput.ReadToEndAsync()
Step 'launched' @{ pid = $proc.Id }

$pipe = $null; $reader = $null; $writer = $null
$script:reqId = 0
function Invoke-Ipc([string]$cmd, [hashtable]$ipcArgs = @{}, [int]$timeoutMs = 15000) {
    $script:reqId++
    $line = (@{ id = $script:reqId; cmd = $cmd; args = $ipcArgs } | ConvertTo-Json -Compress -Depth 5)
    $writer.WriteLine($line); $writer.Flush()
    $task = $reader.ReadLineAsync()
    if (-not $task.Wait($timeoutMs)) { throw "IPC timeout for $cmd" }
    return ($task.Result | ConvertFrom-Json)
}

try {
    # ---------------------------------------------------------- pipe ready
    $pipeName = "wmux-ipc-$($proc.Id)"
    $connected = Wait-Until {
        if ($proc.HasExited) { throw "wmux exited early code=$($proc.ExitCode)" }
        $c = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        try { $c.Connect(100); return $c } catch { $c.Dispose(); return $null }
    } ($TimeoutSec * 1000) 50
    if (-not $connected) { throw "pipe $pipeName never became connectable" }
    $pipe = $connected
    $reader = [System.IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false))
    $writer = [System.IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false))
    Step 'pipe_ready_ms' ($clock.ElapsedMilliseconds - $t0)

    # ------------------------------------------------------- window inventory
    $main = Wait-Until { [S2Native]::TopLevelWindows($sampler.Watched) | Where-Object { $_.Class -eq 'WmuxWindow' -and $_.Visible } | Select-Object -First 1 } 15000
    if (-not $main) { throw 'no visible WmuxWindow' }
    Step 'main_window' $main.ToString()
    $hwnd = [IntPtr]$main.Hwnd
    $hitPid = [S2Native]::HitTestCenterPid($hwnd)
    Step 'hittest_center' @{ pid = $hitPid; proc = [S2Native]::ProcessName($hitPid); is_instance = ($hitPid -eq $proc.Id) }
    Step 'dpi_main_window' ([S2Native]::GetDpiForWindow($hwnd))

    # ----------------------------------------------------- (1) ConPTY + shell
    $prompt = Wait-Until { $r = Invoke-Ipc 'read-screen'; if ($r.ok -and ($r.data -match 'WMUX>')) { $r } } 20000 100
    Step 'prompt_ms' ($clock.ElapsedMilliseconds - $t0)
    $r = Invoke-Ipc 'send' @{ text = 'echo hi'; enter = $true }
    Step 'send_echo_hi' $r
    $hi = Wait-Until { $s = Invoke-Ipc 'read-screen'; if ($s.ok -and ($s.data -match '(?m)^hi\s*$')) { $s } } 10000 100
    Step 'read_screen_has_hi' ([bool]$hi)
    $r = Invoke-Ipc 'send' @{ text = 'set /a 6*7'; enter = $true }
    $calc = Wait-Until { $s = Invoke-Ipc 'read-screen'; if ($s.ok -and ($s.data -match '(?m)^42\s*$')) { $s } } 10000 100
    Step 'read_screen_has_42' ([bool]$calc)
    if ($calc) { ($calc.data -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 12) -join "`n" | Set-Content (Join-Path $OutDir "$Tag-screen.txt") }
    Start-Sleep -Milliseconds 700   # let the renderer present the latest frame

    # --------------------------------------------- (2) GL via PrintWindow
    $cap = [S2Native]::PrintWindowCapture($hwnd, 2)
    [S2Native]::SavePng($cap, (Join-Path $OutDir "$Tag-terminal.png"))
    Step 'printwindow_top' $cap.ToString()
    $children = [S2Native]::ChildWindows($hwnd)
    $term = $children | Where-Object { $_.Class -eq 'WmuxTerminal' -and $_.Visible } | Select-Object -First 1
    if ($term) {
        $tcap = [S2Native]::PrintWindowCapture([IntPtr]$term.Hwnd, 2)
        Step 'printwindow_terminal_child' $tcap.ToString()
        $report.terminal_not_blank = ($tcap.Distinct -ge 3 -and $tcap.DominantFraction -lt 0.999)
    }
    Step 'gui_thread' ([S2Native]::GuiThreadInfo($main.Tid))

    # --------------------------------------------------- (3) WebView2 tab
    if (-not $NoBrowser) {
        $tb = $clock.ElapsedMilliseconds
        $open = Invoke-Ipc 'open' @{ url = 'about:blank'; target = 'tab' }
        Step 'open_about_blank' $open
        $href = Wait-Until { $e = Invoke-Ipc 'eval' @{ js = 'location.href' }; if ($e.ok -and "$($e.data)" -match 'about:blank') { $e } } 30000 250
        Step 'eval_about_blank' $href
        Step 'webview2_ready_ms' ($clock.ElapsedMilliseconds - $tb)
        $html = "data:text/html,<html><body style='margin:0;background:%23cc0000;color:%23ffffff;font:64px sans-serif'><h1>S2 hidden WebView2</h1></body></html>"
        Step 'navigate' (Invoke-Ipc 'navigate' @{ url = $html })
        $txt = Wait-Until { $e = Invoke-Ipc 'eval' @{ js = 'document.body ? document.body.innerText : ""' }; if ($e.ok -and "$($e.data)" -match 'S2 hidden WebView2') { $e } } 15000 200
        Step 'eval_navigated_text' $txt
        [void](Invoke-Ipc 'eval' @{ js = "(function(){window.__raf=0;var f=function(){window.__raf++;requestAnimationFrame(f)};requestAnimationFrame(f);window.__t0=performance.now();return 'armed'})()" })
        Start-Sleep -Milliseconds 1500
        Step 'webview2_state' (Invoke-Ipc 'eval' @{ js = "JSON.stringify({vis:document.visibilityState,hidden:document.hidden,focus:document.hasFocus(),w:innerWidth,h:innerHeight,dpr:devicePixelRatio,raf:window.__raf,ms:Math.round(performance.now()-window.__t0)})" })
        Start-Sleep -Milliseconds 300
        $bcap = [S2Native]::PrintWindowCapture($hwnd, 2)
        [S2Native]::SavePng($bcap, (Join-Path $OutDir "$Tag-browser.png"))
        $red = 0; foreach ($p in $bcap.Pixels) { if (($p -band 0xFFFFFF) -eq 0xCC0000) { $red++ } }
        Step 'printwindow_browser' ($bcap.ToString() + " red_cc0000=$red")
        $report.browser_pixels_captured = ($red -gt 10000)
        Step 'gui_thread_after_browser' ([S2Native]::GuiThreadInfo($main.Tid))
    }

    # ------------------------------------------ (5) taskbar / Alt-Tab
    $tree = $sampler.Watched
    $wins = [S2Native]::TopLevelWindows($tree)
    $report.top_level_windows = @($wins | ForEach-Object { $_.ToString() })
    $report.child_windows = @([S2Native]::ChildWindows($hwnd) | ForEach-Object { $_.ToString() })
    $report.alttab_candidates = @($wins | Where-Object { $_.AltTab } | ForEach-Object { $_.ToString() })
    if ($Taskbar) {
        Start-Sleep -Milliseconds 500
        $tbDuring = Get-TaskbarButtons
        $report.taskbar_new = @($tbDuring | Where-Object { $tbBefore -notcontains $_ })
    }
    $report.process_tree = @($tree | ForEach-Object { "$_=" + [S2Native]::ProcessName($_) })
} catch {
    $report.error = $_.ToString()
    Write-Host "ERROR: $_"
} finally {
    if ($pipe) { $pipe.Dispose() }
    $tree = $sampler.Watched
    if ($GracefulStop -and $hwnd -and -not $proc.HasExited) {
        # WM_CLOSE closes the window (confirm-close-surface=false): WebView2
        # controllers are released and the browser process exits cleanly.
        $gsw = [Diagnostics.Stopwatch]::StartNew()
        [void][S2Native]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        $report.graceful_exit = $proc.WaitForExit(15000)
        $report.graceful_exit_ms = $gsw.ElapsedMilliseconds
    }
    $sampler.CheckVisibility = $false   # teardown: windows die mid-query
    try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { }
    [void]$proc.WaitForExit(10000)
    # Wait for every process of the tree (WebView2 browser/renderers) to exit.
    # Caveat seen in the spike: a terminated msedgewebview2 can stay in
    # teardown (OpenProcess fails, Win32_Process still lists it) and keep the
    # user-data folder locked for ~30-60 s after this check passes.
    $left = Wait-Until { $alive = @($tree | Where-Object { try { [void][Diagnostics.Process]::GetProcessById([int]$_); $true } catch { $false } }); if ($alive.Count -eq 0) { 'none' } } 15000 200
    $report.tree_exited = [bool]$left
    Start-Sleep -Milliseconds 300
    $sampler.Stop()
}

$finalFg = [S2Native]::GetForegroundWindow()
$report.samples = $sampler.Samples
$report.violations = $sampler.Violations
$report.first_violation = $sampler.FirstViolation
$report.visible_violations = $sampler.VisibleViolations
$report.first_visible = $sampler.FirstVisible
$report.fg_initial = '0x{0:X}' -f $sampler.InitialFg.ToInt64()
$report.fg_final = '0x{0:X}' -f $finalFg.ToInt64()
$report.fg_unchanged = ($finalFg -eq $sampler.InitialFg)
$report.transitions = $sampler.GetTransitions()
$stderr = $errTask.Result + $outTask.Result
$stderr | Set-Content (Join-Path $OutDir "$Tag-stderr.log")
$report.hidden_mode_log = @($stderr -split "`n" | Where-Object { $_ -match 'hidden_mode' } | Select-Object -First 60)
$report.warnings = @($stderr -split "`n" | Where-Object { $_ -match '^(warning|error)' } | Select-Object -First 40)
$report.elapsed_ms = $clock.ElapsedMilliseconds
# Remove the isolated state root (WebView2 user data, config) once the tree is gone.
$rmErr = $null
$rmSw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 40 -and (Test-Path $root); $i++) {
    try { Remove-Item -Recurse -Force $root -ErrorAction Stop } catch {
        $rmErr = $_.Exception.Message
        if ($i -eq 0) {
            # Who still references the state root (e.g. WebView2 processes outside the tree)?
            $report.root_holders = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { "$($_.ProcessId) parent=$($_.ParentProcessId) $($_.Name)" })
        }
        Start-Sleep -Milliseconds 500
    }
}
$report.root_removed = -not (Test-Path $root)
$report.root_remove_ms = $rmSw.ElapsedMilliseconds
$report.root_remove_last_error = $rmErr
$report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $OutDir "$Tag.json")
$report | ConvertTo-Json -Depth 6
