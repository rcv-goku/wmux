# wmux spike S1: passive toast-banner observer (Windows PowerShell 5.1).
# Polls top-level windows every 100 ms for shell notification windows
# (ShellExperienceHost, or title "New notification"), and when one appears
# dumps its UI Automation subtree (read-only: names, control types, ids).
# Never clicks, invokes, focuses or activates anything.
param(
    [Parameter(Mandatory)] [string] $Out,
    [int] $Seconds = 15
)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class S1Uia {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public static List<string> Find(uint shellPid) {
    var r = new List<string>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (pid == shellPid || t.ToString() == "New notification")
        r.Add(h.ToInt64().ToString() + "|" + pid + "|" + c + "|" + t);
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
'@
function Emit($o) { ($o | ConvertTo-Json -Compress -Depth 4) | Add-Content -LiteralPath $Out -Encoding utf8 }
$shell = Get-Process ShellExperienceHost -ErrorAction SilentlyContinue | Select-Object -First 1
$shellPid = if ($shell) { [uint32]$shell.Id } else { [uint32]0 }
Emit @{ t = (Get-Date).ToString('o'); ev = 'observer_start'; shell_pid = $shellPid }
$seen = @{}
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $now = @{}
    foreach ($line in [S1Uia]::Find($shellPid)) {
        $parts = $line.Split('|')
        $hwnd = [int64]$parts[0]
        $now[$hwnd] = $true
        if (-not $seen[$hwnd]) {
            $seen[$hwnd] = $true
            $items = @()
            try {
                $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
                $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($e in $all) {
                    $ct = $e.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
                    $items += ('{0}|{1}|{2}' -f $ct, $e.Current.Name, $e.Current.AutomationId)
                    if ($items.Count -ge 80) { break }
                }
            } catch { $items += "uia-error: $($_.Exception.Message)" }
            $rect = New-Object S1Uia+RECT
            [void][S1Uia]::GetWindowRect([IntPtr]$hwnd, [ref]$rect)
            Emit @{ t = (Get-Date).ToString('o'); ev = 'window_appeared'; ms = $sw.ElapsedMilliseconds; hwnd = $hwnd; pid = $parts[1]; class = $parts[2]; title = $parts[3]; rect = @($rect.L, $rect.T, $rect.R, $rect.B); uia = $items }
        }
    }
    foreach ($k in @($seen.Keys)) {
        if ($seen[$k] -and -not $now.ContainsKey($k)) {
            Emit @{ t = (Get-Date).ToString('o'); ev = 'window_gone'; ms = $sw.ElapsedMilliseconds; hwnd = $k }
            $seen[$k] = $false
        }
    }
    Start-Sleep -Milliseconds 100
}
Emit @{ t = (Get-Date).ToString('o'); ev = 'observer_stop' }
