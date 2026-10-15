# wmux spike S6: interactive-console behavior of forwarders under a pseudoconsole
# (ConPTY: no window, nothing can take the foreground). Checks that the target sees
# a console on stdin/stdout through the forwarder, and Ctrl+C delivery / exit codes
# for the exe forwarder (handler / NULL-handler / no-handler) vs the .cmd shim.
. (Join-Path $PSScriptRoot 's6-common.ps1')
. (Join-Path $PSScriptRoot 's6-native.ps1')
$ErrorActionPreference = 'Stop'
if (-not ('S6ConPty' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public sealed class S6ConPty : IDisposable {
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr hpc);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hpc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);

    IntPtr hpc, attrs;
    PROCESS_INFORMATION pi;
    FileStream input;
    Thread reader;
    readonly StringBuilder output = new StringBuilder();
    readonly object gate = new object();

    public int Pid { get { return pi.dwProcessId; } }
    public string Output { get { lock (gate) return output.ToString(); } }

    public static S6ConPty Start(string commandLine, string cwd, short cols, short rows) {
        var c = new S6ConPty();
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0)) throw new System.ComponentModel.Win32Exception();
        if (!CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) throw new System.ComponentModel.Win32Exception();
        int hr = CreatePseudoConsole(new COORD { X = cols, Y = rows }, inRead, outWrite, 0, out c.hpc);
        if (hr != 0) throw new Exception("CreatePseudoConsole 0x" + hr.ToString("X8"));
        inRead.Dispose(); outWrite.Dispose();   // the pseudoconsole owns its ends now
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        c.attrs = Marshal.AllocHGlobal(size);
        if (!InitializeProcThreadAttributeList(c.attrs, 1, 0, ref size)) throw new System.ComponentModel.Win32Exception();
        if (!UpdateProcThreadAttribute(c.attrs, 0, (IntPtr)0x00020016, c.hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.StartupInfo.dwFlags = 0x100;   // STARTF_USESTDHANDLES with NULL handles: use the pseudoconsole, not our pipes
        si.lpAttributeList = c.attrs;
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, cwd, ref si, out c.pi))
            throw new System.ComponentModel.Win32Exception();
        c.input = new FileStream(inWrite, FileAccess.Write);
        var outStream = new FileStream(outRead, FileAccess.Read);
        c.reader = new Thread(() => {
            var buf = new byte[8192];
            var dec = Encoding.UTF8.GetDecoder();
            var chars = new char[16384];
            try {
                int n;
                while ((n = outStream.Read(buf, 0, buf.Length)) > 0) {
                    int k = dec.GetChars(buf, 0, n, chars, 0);
                    lock (c.gate) c.output.Append(chars, 0, k);
                }
            } catch (Exception) { }
        });
        c.reader.IsBackground = true;
        c.reader.Start();
        return c;
    }

    public bool WaitFor(string text, int ms) {
        var deadline = DateTime.UtcNow.AddMilliseconds(ms);
        while (DateTime.UtcNow < deadline) { if (Output.Contains(text)) return true; Thread.Sleep(50); }
        return Output.Contains(text);
    }
    public void Send(string s) { var b = Encoding.UTF8.GetBytes(s); input.Write(b, 0, b.Length); input.Flush(); }
    // Exit code, or null on timeout.
    public long? WaitExit(int ms) {
        if (WaitForSingleObject(pi.hProcess, (uint)ms) != 0) return null;
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        return (long)code;
    }
    public void Dispose() {
        if (WaitForSingleObject(pi.hProcess, 0) != 0) TerminateProcess(pi.hProcess, 1);
        Thread.Sleep(200);
        if (hpc != IntPtr.Zero) { ClosePseudoConsole(hpc); hpc = IntPtr.Zero; }
        if (reader != null) reader.Join(3000);
        try { input.Dispose(); } catch { }
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        if (attrs != IntPtr.Zero) { DeleteProcThreadAttributeList(attrs); Marshal.FreeHGlobal(attrs); attrs = IntPtr.Zero; }
    }
}
'@
}

function Remove-Vt([string]$s) {
    $s = [regex]::Replace($s, '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '')
    $s = [regex]::Replace($s, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
    return [regex]::Replace($s, '\x1b[()][0-9A-Za-z]|\x1b[=>]', '')
}

# Run one scenario. $steps: list of @{ wait = 'text'; send = "..." }.
function Invoke-ConPty([string]$cmdline, [object[]]$steps = @(), [int]$exitMs = 30000, [hashtable]$envAdd = @{}) {
    $saved = @{}
    foreach ($k in $envAdd.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envAdd[$k]) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $c = [S6ConPty]::Start($cmdline, $S6.Run, 1000, 50)
    foreach ($k in $envAdd.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    $log = @()
    try {
        foreach ($st in $steps) {
            $seen = $c.WaitFor($st.wait, 20000)
            $log += "wait '$($st.wait)': $seen @ $([int]$sw.Elapsed.TotalMilliseconds) ms"
            if ($seen -and $st.ContainsKey('send')) { Start-Sleep -Milliseconds 300; $c.Send($st.send); $log += "sent $([int][char]$st.send[0]) @ $([int]$sw.Elapsed.TotalMilliseconds) ms" }
        }
        $code = $c.WaitExit($exitMs)
        Start-Sleep -Milliseconds 300
        $text = Remove-Vt $c.Output
        $json = $null
        $m = [regex]::Match($text, '\{"cmdline".*?\}(?=\s*(\r|\n|$))')
        if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch {} }
        return [ordered]@{
            cmdline = $cmdline
            exit = $code
            ms = [int]$sw.Elapsed.TotalMilliseconds
            steps = $log
            lines = @(($text -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ } | Where-Object { -not $_.StartsWith('{"cmdline"') } | Select-Object -First 12)
            target = if ($json) { [ordered]@{ argv0 = $json.argv[0]; stdin = $json.stdin; stdout = $json.stdout; stderr = $json.stderr; ignore_ctrl_c_flag = $json.ignore_ctrl_c_flag; console_cp = $json.console_cp } } else { $null }
        }
    } finally { $c.Dispose() }
}

$sampler = $null
$stopFile = Join-Path $S6.Run 'fgsampler-conpty.stop'
$fgLog = Join-Path $S6.Results 'foreground-conpty.log'
Remove-Item -ErrorAction SilentlyContinue $stopFile, $fgLog
$res = [ordered]@{ started = (Get-Date).ToString('o') }
try {
    $psi = [Diagnostics.ProcessStartInfo]::new($S6.Pwsh, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 's6-fgsampler.ps1')`" -Log `"$fgLog`" -StopFile `"$stopFile`"")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $sampler = [Diagnostics.Process]::Start($psi)
    if (@(Get-SpikeWindowsAppsFiles).Count) { throw 'run s6-cleanup.ps1 first' }
    Install-SpikeTarget
    Copy-Item $S6.Fwd (Join-Path $S6.WA 'wmuxspikefwd.exe') -Force
    [IO.File]::WriteAllText((Join-Path $S6.WA 'wmuxspikefwdcmd.cmd'), "@`"$($S6.Target)`" %*`r`n", [Text.Encoding]::ASCII)
    $cmd = "`"$($S6.Cmd)`" /d /c"
    $direct = "`"$($S6.Target)`""
    $ctrlc = @(@{ wait = 'READY'; send = [string][char]3 })

    $res.console_direct = Invoke-ConPty "$cmd $direct argv con"
    $res.console_fwd = Invoke-ConPty "$cmd wmuxspikefwd argv con"
    $res.console_cmdshim = Invoke-ConPty "$cmd wmuxspikefwdcmd argv con"
    $res.console_fwd_pwsh = Invoke-ConPty "`"$($S6.Pwsh)`" -NoLogo -NoProfile -Command `"& wmuxspikefwd argv con; exit `$LASTEXITCODE`""
    $res.console_fwd_bash = Invoke-ConPty "`"$($S6.Bash)`" --login -c `"wmuxspikefwd argv con`""

    $res.ctrlc_direct = Invoke-ConPty "$cmd $direct ctrlc 15" $ctrlc
    $res.ctrlc_fwd = Invoke-ConPty "$cmd wmuxspikefwd ctrlc 15" $ctrlc
    $res.ctrlc_fwd_nullhandler = Invoke-ConPty "$cmd wmuxspikefwd ctrlc 6" $ctrlc -envAdd @{ WMUXSPIKEFWD_MODE = 'nullhandler' }
    $res.ctrlc_fwd_nohandler = Invoke-ConPty "$cmd wmuxspikefwd ctrlc 15" $ctrlc -envAdd @{ WMUXSPIKEFWD_MODE = 'nohandler' }
    $res.ctrlc_direct_pwsh = Invoke-ConPty "`"$($S6.Pwsh)`" -NoLogo -NoProfile -Command `"& '$($S6.Target)' ctrlc 15; exit `$LASTEXITCODE`"" $ctrlc
    $res.ctrlc_fwd_pwsh = Invoke-ConPty "`"$($S6.Pwsh)`" -NoLogo -NoProfile -Command `"& wmuxspikefwd ctrlc 15; exit `$LASTEXITCODE`"" $ctrlc
    $res.ctrlc_direct_bash = Invoke-ConPty "`"$($S6.Bash)`" --login -c `"'$(ConvertTo-MsysPath $S6.Target)' ctrlc 15; echo RC=`$?`"" $ctrlc
    $res.ctrlc_fwd_bash = Invoke-ConPty "`"$($S6.Bash)`" --login -c `"wmuxspikefwd ctrlc 15; echo RC=`$?`"" $ctrlc
    $res.ctrlc_cmdshim_answer_n = Invoke-ConPty "$cmd wmuxspikefwdcmd ctrlc 15" @(@{ wait = 'READY'; send = [string][char]3 }, @{ wait = '(Y/N)'; send = "n`r" })
    $res.ctrlc_cmdshim_answer_y = Invoke-ConPty "$cmd wmuxspikefwdcmd ctrlc 15" @(@{ wait = 'READY'; send = [string][char]3 }, @{ wait = '(Y/N)'; send = "y`r" })
}
finally {
    & (Join-Path $PSScriptRoot 's6-cleanup.ps1') | ForEach-Object { $res.cleanup += @("$_") }
    if ($sampler) { New-Item -ItemType File -Force $stopFile | Out-Null; [void]$sampler.WaitForExit(5000) }
    $res.finished = (Get-Date).ToString('o')
    Save-Result 'conpty' $res | Out-Null
    $res | ConvertTo-Json -Depth 6
}
