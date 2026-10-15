# Launch s7proto.exe hidden (UseShellExecute=false, CreateNoWindow=true) with a
# 100 ms foreground sampler (C#, Toolhelp32 parent chain; no WMI in the loop);
# kill the run if our process or a descendant (msedgewebview2.exe) ever owns
# the foreground window.
#
# Usage: pwsh run-s7.ps1 -Exe <s7proto.exe> -Out <dir> -Run 'tag|--mode=hwndrt --tests=all' [-Run ...]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string[]]$Run,
    [int]$TimeoutSec = 240
)
$ErrorActionPreference = 'Stop'
if (-not ('S7Fg2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class S7Fg2 {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr s, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr s, ref PROCESSENTRY32W e);

    static Dictionary<uint, uint> Parents() {
        var d = new Dictionary<uint, uint>();
        IntPtr s = CreateToolhelp32Snapshot(2, 0);
        var e = new PROCESSENTRY32W(); e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
        if (Process32FirstW(s, ref e)) { do { d[e.th32ProcessID] = e.th32ParentProcessID; } while (Process32NextW(s, ref e)); }
        CloseHandle(s);
        return d;
    }
    static bool Descends(uint pid, uint root) {
        var d = Parents();
        for (int i = 0; i < 8 && pid > 4; i++) {
            if (pid == root) return true;
            uint pp; if (!d.TryGetValue(pid, out pp)) return false; pid = pp;
        }
        return false;
    }
    // Returns "samples|changes|violation".
    public static string Watch(Process p, int timeoutMs) {
        var sw = Stopwatch.StartNew();
        int samples = 0, changes = 0; string violation = "";
        IntPtr last = GetForegroundWindow(); uint lastPid = 0; bool lastOurs = false;
        while (!p.HasExited) {
            IntPtr fg = GetForegroundWindow(); uint pid; GetWindowThreadProcessId(fg, out pid);
            samples++;
            if (fg != last) { changes++; last = fg; }
            bool ours;
            if (pid == lastPid) ours = lastOurs; else { ours = pid == (uint)p.Id || Descends(pid, (uint)p.Id); lastPid = pid; lastOurs = ours; }
            if (ours) { violation = "foreground owned by pid " + pid; try { p.Kill(); } catch {} break; }
            if (sw.ElapsedMilliseconds > timeoutMs) { violation = "timeout"; try { p.Kill(); } catch {} break; }
            System.Threading.Thread.Sleep(50);
        }
        return samples + "|" + changes + "|" + violation;
    }
}
'@
}
New-Item -ItemType Directory -Force $Out | Out-Null
$summary = Join-Path $Out 'runs.jsonl'

foreach ($r in $Run) {
    $tag, $argLine = $r.Split('|', 2)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe, "$argLine --out=$Out --tag=$tag")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Out
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $samples, $changes, $violation = ([S7Fg2]::Watch($p, $TimeoutSec * 1000)).Split('|', 3)
    $p.WaitForExit()
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    Set-Content -Path (Join-Path $Out "$tag.stdout.txt") -Value $stdout
    # Leftover WebView2 processes of THIS run only (identified by our data dir).
    $udf = (Join-Path $Out 'wv2data')
    Start-Sleep -Milliseconds 500
    Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($udf) } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
    $rec = [ordered]@{
        t = 'run'; tag = $tag; args = $argLine; exit = $p.ExitCode; ms = [int]$sw.Elapsed.TotalMilliseconds
        fg_samples = [int]$samples; fg_changes_seen = [int]$changes; violation = $violation
        stderr = if ($stderr) { $stderr.Substring(0, [Math]::Min(2000, $stderr.Length)) } else { '' }
    }
    ($rec | ConvertTo-Json -Compress) | Add-Content -Path $summary
    "== $tag exit=$($p.ExitCode) ms=$($rec.ms) fg_samples=$samples fg_changes=$changes violation=$violation"
    if ($stderr) { "stderr: $($rec.stderr)" }
}
