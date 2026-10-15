# S2 hidden-instance spike (W0-D-S2): drive hidden_probe.exe under the
# foreground sampler. Optional taskbar/Alt-Tab enumeration while the probe
# holds its window, and optional launch onto an alternate desktop
# (CreateDesktop + STARTUPINFO.lpDesktop; never SwitchDesktop).
#
#   pwsh -NoProfile -File run-probe.ps1 -Probe <exe> -OutDir <dir> [-ProbeArgs '--focus','--hold=3000'] [-Taskbar] [-AltDesktop]
param(
    [Parameter(Mandatory)] [string] $Probe,
    [Parameter(Mandatory)] [string] $OutDir,
    [string[]] $ProbeArgs = @(),
    [string] $Tag = 'probe',
    [switch] $Taskbar,
    [switch] $AltDesktop,
    [int] $IntervalMs = 50,
    [int] $TimeoutSec = 60
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'S2Native.cs')
New-Item -ItemType Directory -Force $OutDir | Out-Null

function Get-TaskbarButtons {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [System.Windows.Automation.AutomationElement]
    $root = $A::RootElement
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($cls in 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd') {
        $cond = [System.Windows.Automation.PropertyCondition]::new($A::ClassNameProperty, $cls)
        foreach ($tray in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            $bc = [System.Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
            foreach ($b in $tray.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
                $id = $b.Current.AutomationId
                if ($id -like 'Appid:*') { $out.Add("$cls|$id|$($b.Current.Name)") }
            }
        }
    }
    return , $out
}

$report = [ordered]@{ tag = $Tag; args = ($ProbeArgs -join ' '); alt_desktop = [bool]$AltDesktop }
$sampler = [FgSampler]::new()
$sampler.IntervalMs = $IntervalMs
$sampler.Start()
$report.launcher_rights = [S2Native]::ForegroundRightsProbe()
if ($Taskbar) { $before = Get-TaskbarButtons }

$desk = [IntPtr]::Zero
$logPath = Join-Path $OutDir "$Tag.log"
$outBase = Join-Path $OutDir $Tag
$allArgs = @($ProbeArgs) + @("--out=$outBase")
try {
    if ($AltDesktop) {
        $deskName = 'S2Desk-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $desk = [S2Native]::CreateHiddenDesktop($deskName)
        $env2 = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $env2[$e.Key] = [string]$e.Value }
        $cmd = '"' + $Probe + '" ' + (($allArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
        $pi = [S2Native]::LaunchOnDesktop("WinSta0\$deskName", $cmd, $OutDir, $env2, $logPath)
        $sampler.RootPid = $pi.dwProcessId
        $report.desktop = "WinSta0\$deskName"
        $report.pid = $pi.dwProcessId
        $wait = [S2Native]::WaitForSingleObject($pi.hProcess, [uint32]($TimeoutSec * 1000))
        $code = [uint32]0
        [void][S2Native]::GetExitCodeProcess($pi.hProcess, [ref]$code)
        $report.exit_code = $code
        $report.wait = $wait
        [void][S2Native]::CloseHandle($pi.hProcess); [void][S2Native]::CloseHandle($pi.hThread)
        $report.output = Get-Content -Raw $logPath
    } else {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Probe)
        foreach ($a in $allArgs) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.WorkingDirectory = $OutDir
        $p = [System.Diagnostics.Process]::Start($psi)
        $sampler.RootPid = [uint32]$p.Id
        $report.pid = $p.Id
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        if ($Taskbar) {
            # Wait until the probe's window is visible, then enumerate.
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            $wins = $null
            while ([DateTime]::UtcNow -lt $deadline) {
                $set = [System.Collections.Generic.HashSet[uint32]]::new(); [void]$set.Add([uint32]$p.Id)
                $wins = [S2Native]::TopLevelWindows($set) | Where-Object { $_.Visible }
                if ($wins) { break }
                Start-Sleep -Milliseconds 50
            }
            Start-Sleep -Milliseconds 700   # let the shell process the new window
            $during = Get-TaskbarButtons
            $report.windows = @($wins | ForEach-Object { $_.ToString() })
            $report.alttab_candidates = @($wins | Where-Object { $_.AltTab } | ForEach-Object { '0x{0:X}' -f $_.Hwnd })
            $report.taskbar_new = @($during | Where-Object { $before -notcontains $_ })
            $report.taskbar_gone = @($before | Where-Object { $during -notcontains $_ })
        }
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill($true); $report.timeout = $true }
        $report.exit_code = $p.ExitCode
        $report.output = $errTask.Result + $outTask.Result
    }
} finally {
    Start-Sleep -Milliseconds 300
    $sampler.Stop()
    if ($desk -ne [IntPtr]::Zero) { $report.close_desktop = [S2Native]::CloseDesktop($desk) }
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
$report | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $OutDir "$Tag.json")
$report | ConvertTo-Json -Depth 4
