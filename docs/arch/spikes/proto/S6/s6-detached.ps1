# wmux spike S6: forwarder started WITHOUT a console (DETACHED_PROCESS parent, as GUIs,
# services or `detached` spawns do) and with a window-less console (CREATE_NO_WINDOW,
# e.g. Node windowsHide). Everything runs on a private, never-shown desktop so that a
# console window created by mistake can never appear on (or take focus from) the
# user's desktop.
. (Join-Path $PSScriptRoot 's6-common.ps1')
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class S6Desk {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr devmode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseDesktop(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out IntPtr r, out IntPtr w, ref SECURITY_ATTRIBUTES sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(IntPtr h, byte[] buf, int n, out int read, IntPtr ov);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);

    public static IntPtr Create(string name) {
        IntPtr h = CreateDesktopW(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
        if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        return h;
    }
    // Run commandLine on desktop with creation flags; stdout+stderr -> pipe. Returns "exit|output".
    public static string Run(string commandLine, string desktop, uint flags) {
        var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), bInheritHandle = 1 };
        IntPtr r, w;
        if (!CreatePipe(out r, out w, ref sa, 0)) throw new System.ComponentModel.Win32Exception();
        SetHandleInformation(r, 1, 0);   // our read end is not inherited
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.lpDesktop = desktop;
        si.dwFlags = 0x100;   // STARTF_USESTDHANDLES
        si.hStdOutput = w; si.hStdError = w;
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, null, ref si, out pi)) {
            int e = Marshal.GetLastWin32Error(); CloseHandle(r); CloseHandle(w); return "error " + e + "|";
        }
        CloseHandle(w);
        var sb = new StringBuilder(); var buf = new byte[65536]; int n;
        while (ReadFile(r, buf, buf.Length, out n, IntPtr.Zero) && n > 0) sb.Append(Encoding.UTF8.GetString(buf, 0, n));
        CloseHandle(r);
        if (WaitForSingleObject(pi.hProcess, 15000) != 0) TerminateProcess(pi.hProcess, 1);
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return code + "|" + sb.ToString();
    }
}
'@

$deskName = 'wmuxspikefwd-desk'
$desktop = "WinSta0\$deskName"
$res = [ordered]@{ started = (Get-Date).ToString('o'); desktop = $desktop }
$hDesk = [IntPtr]::Zero
try {
    if (@(Get-SpikeWindowsAppsFiles).Count) { throw 'run s6-cleanup.ps1 first' }
    Install-SpikeTarget
    $fwd = Join-Path $S6.WA 'wmuxspikefwd.exe'
    Copy-Item $S6.Fwd $fwd -Force
    $hDesk = [S6Desk]::Create($deskName)
    $DETACHED = 0x8; $NOWINDOW = 0x08000000
    $cases = [ordered]@{
        'direct target, parent DETACHED_PROCESS'          = @{ cmd = "`"$($S6.Target)`" argv detached"; flags = $DETACHED; mode = $null }
        'forwarder, parent DETACHED_PROCESS'              = @{ cmd = "`"$fwd`" argv detached"; flags = $DETACHED; mode = $null }
        'forwarder nodetach (bug), parent DETACHED_PROCESS' = @{ cmd = "`"$fwd`" argv detached"; flags = $DETACHED; mode = 'nodetach' }
        'forwarder, parent CREATE_NO_WINDOW'              = @{ cmd = "`"$fwd`" argv nowindow"; flags = $NOWINDOW; mode = $null }
    }
    $report = Join-Path $S6.Run 'detached-report.json'
    foreach ($k in $cases.Keys) {
        $c = $cases[$k]
        Remove-Item -ErrorAction SilentlyContinue $report
        if ($c.mode) { $env:WMUXSPIKEFWD_MODE = $c.mode }
        $env:WMUXSPIKEFWD_REPORT = $report
        try { $out = [S6Desk]::Run($c.cmd, $desktop, [uint32]$c.flags) } finally { Remove-Item Env:\WMUXSPIKEFWD_MODE, Env:\WMUXSPIKEFWD_REPORT -ErrorAction SilentlyContinue }
        $exit, $text = $out -split '\|', 2
        $j = Get-JsonLines $text | Select-Object -First 1
        $f = if (Test-Path $report) { Get-JsonLines (Get-Content -Raw $report) | Select-Object -First 1 } else { $null }
        $res[$k] = [ordered]@{
            exit = $exit
            report_reached_caller_stdout = ($null -ne $j)
            target_console_cp = $f.console_cp; target_console_window = $f.console_window
            target_stdin = $f.stdin; target_stdout = $f.stdout
        }
    }
}
finally {
    Get-Process -Name 'wmuxspikefwd*' -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($hDesk -ne [IntPtr]::Zero) { $res.desktop_closed = [S6Desk]::CloseDesktop($hDesk) }
    & (Join-Path $PSScriptRoot 's6-cleanup.ps1') | ForEach-Object { $res.cleanup += @("$_") }
    $res.finished = (Get-Date).ToString('o')
    Save-Result 'detached' $res | Out-Null
    $res | ConvertTo-Json -Depth 5
}
