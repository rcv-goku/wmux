# wp: W1-2c
# covers: cli-global-options, cli-no-socket-help-probes, cli-help-command-topics, cli-version-command, cli-guide-skill-command, agents-guide-skill-cli, cli-docs-command, cli-welcome-command, cli-focus-default-detection, cli-id-format-output
#
# CLI offline conformance (W1-2c):
# * the cmux no-socket probe contract (test/cli/probes.ps1) passes against cli\cmux.exe with no
#   instance and no socket environment, in the cmux and the wmux spelling;
# * global/presentation option grammar and --id-format reach a live instance identically before
#   and after the command, and `rpc` stays raw without --id-format;
# * the focus default: cli\cmux.exe run under a ConPTY (stdin and stdout are a console, so it is
#   interactive) focuses a new workspace opened with `cmux open <dir>`; with CLAUDECODE=1 it stays
#   in the background, and WMUX_FOCUS_NEW=0 overrides the interactive default.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).ProviderPath

if (-not ('W12c.ConPty' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace W12c {
public sealed class ConPtyResult { public int ExitCode; public string Output; public bool TimedOut; }

// Runs one process attached to a fresh pseudoconsole, so GetConsoleMode succeeds on its stdin
// and stdout exactly as in an interactive terminal; the output is drained on a thread.
public static class ConPty {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;

    // CommandLineToArgvW quoting.
    public static string Quote(string a) {
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in a) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') sb.Append('\\', slashes * 2 + 1); else sb.Append('\\', slashes);
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', slashes * 2).Append('"');
        return sb.ToString();
    }

    static string EnvBlock(IDictionary env) {
        var keys = new List<string>();
        foreach (var k in env.Keys) keys.Add((string)k);
        keys.Sort(StringComparer.OrdinalIgnoreCase);
        var sb = new StringBuilder();
        foreach (var k in keys) sb.Append(k).Append('=').Append((string)env[k]).Append('\0');
        return sb.Append('\0').ToString();
    }

    public static ConPtyResult Run(string exe, string[] args, IDictionary env, string cwd, int timeoutMs) {
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0)) throw new Win32Exception();
        if (!CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) throw new Win32Exception();
        IntPtr hpc;
        int hr = CreatePseudoConsole(new COORD { X = 200, Y = 50 }, inRead, outWrite, 0, out hpc);
        if (hr != 0) throw new Win32Exception(hr);
        // The pseudoconsole keeps its own references.
        inRead.Dispose();
        outWrite.Dispose();
        var output = new StringBuilder();
        var reader = new Thread(() => {
            try {
                using (var fs = new FileStream(outRead, FileAccess.Read)) {
                    var buf = new byte[4096];
                    int n;
                    while ((n = fs.Read(buf, 0, buf.Length)) > 0) lock (output) output.Append(Encoding.UTF8.GetString(buf, 0, n));
                }
            } catch (IOException) { }
        });
        reader.IsBackground = true;
        reader.Start();
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        IntPtr list = Marshal.AllocHGlobal(size);
        IntPtr envBlock = IntPtr.Zero;
        var pi = new PROCESS_INFORMATION();
        try {
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Win32Exception();
            if (!UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
            var si = new STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.lpAttributeList = list;
            envBlock = Marshal.StringToHGlobalUni(EnvBlock(env));
            var cmd = new StringBuilder(Quote(exe));
            foreach (var a in args) cmd.Append(' ').Append(Quote(a));
            if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, envBlock, cwd, ref si, out pi))
                throw new Win32Exception();
            bool timedOut = WaitForSingleObject(pi.hProcess, (uint)timeoutMs) != 0;
            if (timedOut) TerminateProcess(pi.hProcess, 1);
            uint code;
            GetExitCodeProcess(pi.hProcess, out code);
            // Closing the pseudoconsole ends the output stream.
            ClosePseudoConsole(hpc);
            hpc = IntPtr.Zero;
            reader.Join(5000);
            string text;
            lock (output) text = output.ToString();
            return new ConPtyResult { ExitCode = (int)code, Output = text, TimedOut = timedOut };
        } finally {
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (hpc != IntPtr.Zero) ClosePseudoConsole(hpc);
            DeleteProcThreadAttributeList(list);
            Marshal.FreeHGlobal(list);
            if (envBlock != IntPtr.Zero) Marshal.FreeHGlobal(envBlock);
            inWrite.Dispose();
        }
    }
}
}
'@
}

$script:DropEnv = '^(CMUX_|WMUX_|CMUXTERM_|GHOSTTY_|CLAUDECODE$|CLAUDE_CODE|CODEX_|OPENCODE|AI_AGENT$|NO_COLOR$)'

function Resolve-W12cCli {
    param($Instance)
    $candidates = @()
    if ($null -ne $Instance -and $Instance.CliExe) { $candidates += $Instance.CliExe }
    if ($env:WMUX_E2E_CLI) { $candidates += $env:WMUX_E2E_CLI }
    if ($env:WMUX_E2E_EXE) { $candidates += (Join-Path (Split-Path -Parent $env:WMUX_E2E_EXE) 'cli\cmux.exe') }
    $candidates += (Join-Path $script:RepoRoot 'zig-out\bin\cli\cmux.exe')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).ProviderPath }
    }
    throw [WmuxSkipException]::new('cli\cmux.exe is not built (W1-2): build it or set WMUX_E2E_CLI')
}

function Get-W12cProp {
    param($Object, [string[]]$Names)
    foreach ($n in $Names) {
        if ($null -ne $Object -and $Object.PSObject.Properties[$n]) { return $Object.$n }
    }
    return $null
}

function Get-W12cCurrentWorkspace {
    param($Instance)
    $r = Invoke-WmuxRpc $Instance 'workspace.current' @{}
    $id = Get-W12cProp $r @('workspace_id', 'id')
    if ($null -eq $id) { $id = Get-W12cProp (Get-W12cProp $r @('workspace')) @('workspace_id', 'id') }
    if ($null -eq $id) { throw "workspace.current returned no workspace id: $($r | ConvertTo-Json -Compress -Depth 5)" }
    return [string]$id
}

function Get-W12cWorkspaceCount {
    param($Instance)
    $r = Invoke-WmuxRpc $Instance 'workspace.list' @{}
    return @(Get-W12cProp $r @('workspaces')).Count
}

# Runs cli\cmux.exe under a ConPTY against the instance. The environment is the harness process
# environment without socket, agent and color variables, plus the instance's pipe and $Extra.
function Invoke-W12cConPty {
    param($Instance, [string[]]$Arguments, [hashtable]$Extra = @{})
    if (-not $IsWindows) { throw [WmuxSkipException]::new('ConPTY runs need Windows') }
    $cli = Resolve-W12cCli $Instance
    $envMap = [System.Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ([string]$e.Key -notmatch $script:DropEnv) { $envMap[[string]$e.Key] = [string]$e.Value }
    }
    $envMap['WMUX_SOCKET_PATH'] = $Instance.Pipe
    $envMap['CMUX_SOCKET_PATH'] = $Instance.Pipe
    $envMap['WMUX_CHANNEL'] = $Instance.Channel
    if ($Instance.LocalAppData) { $envMap['LOCALAPPDATA'] = $Instance.LocalAppData }
    $envMap['CMUX_QUIET'] = '1'
    foreach ($k in $Extra.Keys) { $envMap[[string]$k] = [string]$Extra[$k] }
    $cwd = if ($Instance.WorkDir -and (Test-Path -LiteralPath $Instance.WorkDir)) { $Instance.WorkDir } else { (Get-Location).ProviderPath }
    $r = [W12c.ConPty]::Run($cli, $Arguments, $envMap, $cwd, 60000)
    if ($r.TimedOut) { throw "cmux $($Arguments -join ' ') did not exit within 60 s under the ConPTY: $($r.Output)" }
    return $r
}

# Opens a fresh directory with `cmux open <dir>` (workspace.create {cwd, focus}) under a ConPTY
# and checks whether the new workspace took the selection.
function Test-W12cFocusDefault {
    param([hashtable]$Extra, [bool]$ExpectFocus, [string]$Label)
    $w = Start-WmuxInstance
    try {
        $before = Get-W12cCurrentWorkspace $w
        $count = Get-W12cWorkspaceCount $w
        $base = if ($w.WorkDir) { $w.WorkDir } else { [IO.Path]::GetTempPath() }
        $dir = Join-Path $base ('focus-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $r = Invoke-W12cConPty $w @('open', $dir) $Extra
        Assert-Equal 0 $r.ExitCode "cmux open under the ConPTY ($Label) exit code; output: $($r.Output)"
        Wait-WmuxCondition -TimeoutSec 15 { (Get-W12cWorkspaceCount $w) -gt $count } | Out-Null
        $after = Get-W12cCurrentWorkspace $w
        if ($ExpectFocus) {
            Assert-NotEqual $before $after "$Label`: the new workspace should be selected (focus=true)"
        } else {
            Assert-Equal $before $after "$Label`: the selection should stay (focus=false)"
        }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'cli: the no-socket probe contract passes with no instance (cmux and wmux spellings)' {
    $cli = Resolve-W12cCli
    $pwsh = (Get-Process -Id $PID).Path
    $json = Join-Path ([IO.Path]::GetTempPath()) ('w12c-probes-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $out = & $pwsh -NoProfile -File (Join-Path $script:RepoRoot 'test\cli\probes.ps1') -Exe $cli -Json $json 2>&1
        $code = $LASTEXITCODE
        Write-Host (($out | Select-Object -Last 12) -join "`n")
        Assert-Equal 0 $code 'probes.ps1 exit code'
        $records = @(Get-Content -LiteralPath $json -Raw | ConvertFrom-Json)
        Assert-True ($records.Count -ge 500) "probe runs: $($records.Count)"
        Assert-Equal 0 @($records | Where-Object { -not $_.ok }).Count 'failed probes'
    } finally {
        Remove-Item -LiteralPath $json -ErrorAction SilentlyContinue
    }
}

Test-Case 'cli: --json and --id-format work before or after the command; rpc stays raw' {
    $w = Start-WmuxInstance
    try {
        $quiet = @{ CMUX_QUIET = '1' }
        $a = Invoke-WmuxCli $w @('--json', 'list-workspaces') -Env $quiet
        $b = Invoke-WmuxCli $w @('list-workspaces', '--json') -Env $quiet
        Assert-Equal 0 $a.ExitCode "--json list-workspaces: $($a.Stderr)"
        Assert-Equal 0 $b.ExitCode "list-workspaces --json: $($b.Stderr)"
        Assert-Equal $a.Stdout $b.Stdout 'identical JSON before and after the command'
        Assert-Match '"ref"\s*:' $a.Stdout 'refs mode shows ref'
        Assert-True ($a.Stdout -notmatch '"id"\s*:') 'refs mode drops id'
        $u = Invoke-WmuxCli $w @('list-workspaces', '--json', '--id-format', 'uuids') -Env $quiet
        Assert-Match '"id"\s*:' $u.Stdout 'uuids mode shows id'
        Assert-True ($u.Stdout -notmatch '"ref"\s*:') 'uuids mode drops ref'
        $both = Invoke-WmuxCli $w @('--id-format', 'both', 'list-workspaces', '--json') -Env $quiet
        Assert-Match '"ref"\s*:' $both.Stdout 'both mode shows ref'
        Assert-Match '"id"\s*:' $both.Stdout 'both mode shows id'
        $raw = Invoke-WmuxCli $w @('rpc', 'workspace.list')
        Assert-Equal 0 $raw.ExitCode "rpc workspace.list: $($raw.Stderr)"
        Assert-Match '"id"\s*:' $raw.Stdout 'rpc prints the raw result'
        Assert-Match '"ref"\s*:' $raw.Stdout 'rpc prints the raw result'
        $bad = Invoke-WmuxCli $w @('list-workspaces', '--id-format', 'ids')
        Assert-Equal 2 $bad.ExitCode 'invalid --id-format is a usage error'
        Assert-Match ([regex]::Escape('--id-format must be one of: refs, uuids, both')) $bad.Stderr
        $sock = Invoke-WmuxCli $w @('list-workspaces', '--socket', '\\.\pipe\elsewhere') -Env $quiet
        Assert-Equal 2 $sock.ExitCode '--socket after the command is not global'
        $notice = Invoke-WmuxCli $w @('list-workspaces')
        Assert-Match ([regex]::Escape("'list-workspaces' is now an alias for 'workspace list'")) $notice.Stderr 'legacy notice'
        $silent = Invoke-WmuxCli $w @('list-workspaces') -Env $quiet
        Assert-True ($silent.Stderr -notmatch 'is now an alias') 'CMUX_QUIET=1 hides the notice'
        $payload = Invoke-WmuxCli $w @('send', '--', '--version') -Env $quiet
        Assert-True ($payload.Stdout -notmatch '^cmux \S+') '--version after -- is payload, not the version'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'cli: under a ConPTY stdout is a console (focus premise)' {
    $w = Start-WmuxInstance
    try {
        $r = Invoke-W12cConPty $w @('welcome')
        Assert-Equal 0 $r.ExitCode "welcome under the ConPTY: $($r.Output)"
        Assert-Match 'Shortcuts' $r.Output
        # welcome colors its logo only when stdout is a console.
        Assert-Match '\x1b\[38;2;' $r.Output 'truecolor logo (stdout is a console)'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'cli: interactive run without agent markers focuses (focus=true)' {
    Test-W12cFocusDefault -Extra @{} -ExpectFocus $true -Label 'no markers'
}

Test-Case 'cli: CLAUDECODE=1 under a ConPTY stays in the background (focus=false)' {
    Test-W12cFocusDefault -Extra @{ CLAUDECODE = '1' } -ExpectFocus $false -Label 'CLAUDECODE=1'
}

Test-Case 'cli: WMUX_FOCUS_NEW=0 overrides the interactive default (focus=false)' {
    Test-W12cFocusDefault -Extra @{ WMUX_FOCUS_NEW = '0' } -ExpectFocus $false -Label 'WMUX_FOCUS_NEW=0'
}

Test-Case 'cli: CMUX_FOCUS_NEW=1 makes an agent run focus (focus=true)' {
    Test-W12cFocusDefault -Extra @{ CLAUDECODE = '1'; CMUX_FOCUS_NEW = '1' } -ExpectFocus $true -Label 'CLAUDECODE=1 CMUX_FOCUS_NEW=1'
}
