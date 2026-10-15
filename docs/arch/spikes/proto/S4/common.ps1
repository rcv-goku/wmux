# S4 spike helpers: run a process hidden (CreateNoWindow, no shell execute) with a controlled PATH,
# capture output, and sample the foreground window so a test can prove it never took focus.
$ErrorActionPreference = 'Stop'
$script:S4Spawned = [System.Collections.Generic.List[int]]::new()
$script:S4Base = 'C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0\;C:\Program Files\PowerShell\7\;C:\Program Files\Git\cmd'

function Invoke-S4 {
    # Default Unset: this driver runs under Claude Code, which exports NoDefaultCurrentDirectoryInExePath=1
    # and CLAUDECODE=1; drop them so launchers behave as in a plain user shell unless a test sets them.
    param([string] $File, [string[]] $ArgList = @(), [string] $Path, [string] $Cwd, [hashtable] $Env = @{},
          [string[]] $Unset = @('NoDefaultCurrentDirectoryInExePath', 'CLAUDECODE'), [int] $TimeoutMs = 30000, [string] $StdIn = $null,
          [string] $RawArgs = $null)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($File)
    # RawArgs: verbatim command-line tail (needed for cmd.exe, which does not use MSVCRT quoting rules)
    if ($null -ne $RawArgs -and $RawArgs -ne '') { $psi.Arguments = $RawArgs } else { foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) } }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.RedirectStandardInput = $null -ne $StdIn
    if ($Cwd) { $psi.WorkingDirectory = $Cwd }
    if ($Path) { $psi.Environment['PATH'] = $Path }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    foreach ($k in $Unset) { if (-not $Env.ContainsKey($k)) { [void]$psi.Environment.Remove($k) } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:S4Spawned.Add($p.Id)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if ($null -ne $StdIn) { $p.StandardInput.Write($StdIn); $p.StandardInput.Close() }
    if (-not $p.WaitForExit($TimeoutMs)) { $p.Kill($true); return [pscustomobject]@{ Out = 'TIMEOUT'; Err = ''; Code = -1; Ms = $sw.ElapsedMilliseconds } }
    $p.WaitForExit()
    [pscustomobject]@{ Out = $o.Result; Err = $e.Result; Code = $p.ExitCode; Ms = $sw.ElapsedMilliseconds }
}

function Start-S4FgSampler([string] $LogFile) {
    Start-Job -ArgumentList $LogFile -ScriptBlock {
        param($log)
        Add-Type -Namespace S4 -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@
        $last = 0
        while ($true) {
            $h = [S4.U]::GetForegroundWindow(); $fgPid = 0
            [void][S4.U]::GetWindowThreadProcessId($h, [ref]$fgPid)
            if ($fgPid -ne $last) {
                $gp = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
                Add-Content -Path $log -Value ("{0:o} pid={1} name={2} path={3}" -f (Get-Date), $fgPid, $gp.ProcessName, $gp.Path)
                $last = $fgPid
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Stop-S4FgSampler($Job, [string] $LogFile, [string] $Root) {
    Stop-Job $Job; Remove-Job $Job -Force
    $seen = @(Get-Content $LogFile -ErrorAction SilentlyContinue)
    $bad = foreach ($line in $seen) {
        $byPid = $line -match 'pid=(\d+)' -and $script:S4Spawned.Contains([int]$Matches[1])
        $byPath = $Root -and $line.Contains("path=$Root")
        if ($byPid -or $byPath) { $line }
    }
    [pscustomobject]@{ Samples = $seen.Count; Violations = @($bad) }
}
