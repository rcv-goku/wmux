<#
.SYNOPSIS
  Runs the S5 prototype hidden (no console, off-screen WS_EX_NOACTIVATE windows)
  under an external foreground sampler, snapshots its WebView2 process tree
  during the hold phase, probes the proxies from a foreign process (curl.exe),
  and verifies cleanup.

.EXAMPLE
  pwsh -File run-s5.ps1 -Exe C:\...\s5proto.exe -Scratch C:\...\.s5-scratch\run1
#>
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Scratch,
    [int] $TimeoutSec = 300,
    [string] $ExtraArgs = ''
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class S5Fg {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static uint ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
    public static HashSet<uint> Tree(uint root) {
        var parent = new Dictionary<uint, uint>();
        IntPtr h = CreateToolhelp32Snapshot(2, 0);
        var e = new PROCESSENTRY32W(); e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
        if (Process32FirstW(h, ref e)) { do { parent[e.th32ProcessID] = e.th32ParentProcessID; } while (Process32NextW(h, ref e)); }
        CloseHandle(h);
        var set = new HashSet<uint> { root }; bool grew = true;
        while (grew) { grew = false; foreach (var kv in parent) if (!set.Contains(kv.Key) && set.Contains(kv.Value)) { set.Add(kv.Key); grew = true; } }
        return set;
    }
}
'@

New-Item -ItemType Directory -Force $Scratch | Out-Null
$report = Join-Path $Scratch 'runner.txt'
function Say([string] $s) { $s | Tee-Object -FilePath $report -Append }

$lwvBefore = if (Test-Path "$env:LOCALAPPDATA\Microsoft\EdgeWebView") { (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\EdgeWebView" -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count } else { -1 }

$psi = [System.Diagnostics.ProcessStartInfo]::new($Exe, ("--scratch `"$Scratch`" " + $ExtraArgs).Trim())
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $Scratch
$p = [System.Diagnostics.Process]::Start($psi)
$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
Say "started pid=$($p.Id)"

$samples = 0; $violations = 0; $fgChanges = 0; $lastFg = [uint32]0
$tree = [S5Fg]::Tree([uint32]$p.Id); $treeAt = [DateTime]::UtcNow; $maxTree = 0
$sw = [Diagnostics.Stopwatch]::StartNew(); $holdDone = $false
while (-not $p.HasExited) {
    if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
        Say 'TIMEOUT: killing prototype tree'
        & taskkill.exe /PID $p.Id /T /F | Out-Null
        break
    }
    if (([DateTime]::UtcNow - $treeAt).TotalMilliseconds -ge 1000) {
        $tree = [S5Fg]::Tree([uint32]$p.Id); $treeAt = [DateTime]::UtcNow
        if ($tree.Count -gt $maxTree) { $maxTree = $tree.Count }
    }
    $fg = [S5Fg]::ForegroundPid(); $samples++
    if ($fg -ne $lastFg) { $fgChanges++; $lastFg = $fg }
    if ($tree.Contains($fg)) {
        $violations++
        Say "FOREGROUND VIOLATION: pid $fg is in the prototype tree; killing it"
        & taskkill.exe /PID $p.Id /T /F | Out-Null
        break
    }
    if (-not $holdDone -and (Test-Path (Join-Path $Scratch 'hold.flag'))) {
        $holdDone = $true
        Start-Sleep -Milliseconds 200
        $info = Get-Content (Join-Path $Scratch 'hold.flag') -Raw | ConvertFrom-Json
        $tree = [S5Fg]::Tree([uint32]$p.Id)
        $procs = Get-CimInstance Win32_Process | Where-Object { $tree.Contains([uint32]$_.ProcessId) -and $_.ProcessId -ne $p.Id }
        $lines = foreach ($pr in $procs) {
            $cl = [string]$pr.CommandLine
            $type = if ($cl -match '--type=(\S+)') { $Matches[1] } else { 'browser' }
            $sub = if ($cl -match '--utility-sub-type=(\S+)') { $Matches[1] } else { '' }
            $proxy = if ($cl -match '--proxy-server=(\S+)') { $Matches[1] } else { '' }
            $bypass = if ($cl -match '--proxy-bypass-list=(\S+)') { $Matches[1] } else { '' }
            $udd = if ($cl -match '--user-data-dir="?([^"]+?)"?(\s|$)') { Split-Path $Matches[1] -Leaf } else { '' }
            '{0,6} ppid={1,6} {2,-20} type={3,-18} sub={4,-36} ws={5,5}MB priv={6,5}MB proxy={7} bypass={8} udd={9}' -f $pr.ProcessId, $pr.ParentProcessId, $pr.Name, $type, $sub, [int]($pr.WorkingSetSize / 1MB), [int]($pr.PrivatePageCount / 1MB), $proxy, $bypass, $udd
        }
        $lines | Set-Content (Join-Path $Scratch 'processes.txt')
        Say "hold: $($procs.Count) descendant processes captured"
        # Memory per environment (browser process subtree).
        foreach ($prop in $info.browsers.PSObject.Properties) {
            $sub = [S5Fg]::Tree([uint32]$prop.Value)
            $mine = $procs | Where-Object { $sub.Contains([uint32]$_.ProcessId) }
            $wsMB = [int](($mine | Measure-Object WorkingSetSize -Sum).Sum / 1MB)
            $pvMB = [int](($mine | Measure-Object PrivatePageCount -Sum).Sum / 1MB)
            Say ("env {0}: browser pid {1}: {2} processes, working set {3} MB, private {4} MB" -f $prop.Name, $prop.Value, @($mine).Count, $wsMB, $pvMB)
        }
        # Foreign-process probes: curl.exe through an admission-enforcing proxy and an open one.
        $curl = "$env:SystemRoot\System32\curl.exe"
        foreach ($pp in @(@('socksA', $info.socksA), @('socksOpen', $info.socksOpen))) {
            $o = & $curl -s -S -m 5 --socks5-hostname "127.0.0.1:$($pp[1])" "http://127.0.0.1:$($info.origin)/curl-via-$($pp[0])" -o NUL -w '%{http_code}' 2>&1
            Say ("curl via {0}: exit={1} out={2}" -f $pp[0], $LASTEXITCODE, ($o -join ' '))
        }
        New-Item -ItemType File (Join-Path $Scratch 'hold.done') | Out-Null
    }
    Start-Sleep -Milliseconds 100
}
$p.WaitForExit(30000) | Out-Null
$out = $outTask.Result; $err = $errTask.Result
Say "exit code: $($p.ExitCode) after $([int]$sw.Elapsed.TotalSeconds) s"
Say "external foreground sampler: samples=$samples changes=$fgChanges violations=$violations max_tree=$maxTree"
if ($err) { Say "stderr: $err" }
Start-Sleep -Seconds 2
$left = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" | Where-Object { $_.CommandLine -like "*$Scratch*" }
Say "leftover msedgewebview2 processes referencing the scratch dir: $(@($left).Count)"
$udfs = Get-ChildItem $Scratch -Directory -Filter 'udf-*' -ErrorAction SilentlyContinue
Say "leftover user-data folders: $(@($udfs).Count)"
$lwvAfter = if (Test-Path "$env:LOCALAPPDATA\Microsoft\EdgeWebView") { (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\EdgeWebView" -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count } else { -1 }
Say "%LOCALAPPDATA%\Microsoft\EdgeWebView entries before/after: $lwvBefore/$lwvAfter"
