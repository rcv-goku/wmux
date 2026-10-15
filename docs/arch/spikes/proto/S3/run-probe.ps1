# S3 spike: run conpty_probe.exe for cmd, pwsh and WSL and print the reports.
# The probe is started with CreateNoWindow=true so it gets its own hidden
# console (its SetConsoleCP calls never touch the caller's console) and no
# window is ever shown.
param(
    [string]$Probe = (Join-Path $PSScriptRoot '..\..\..\..\..\zig-out\s3\conpty_probe.exe'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\..\..\..\zig-out\s3\probe'),
    [int]$Cols = 100,
    [int]$Rows = 30,
    [int]$Flags = 0,
    [int]$RunMs = 5000,
    [int]$ResizeAt = -1,
    [int]$ResizeCols = 100,
    [int]$ResizeRows = 40,
    [int]$InputAt = -1,
    [string]$InputText = '-',
    [string[]]$Shells = @('cmd', 'pwsh', 'wsl'),
    [string]$Tag = 'base'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$cmdlines = @{
    cmd  = 'cmd.exe'
    pwsh = 'pwsh.exe -NoLogo'
    wsl  = 'wsl.exe -d Ubuntu-24.04'
}
foreach ($s in $Shells) {
    $out = Join-Path $OutDir "probe-$Tag-$s.txt"
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Probe)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($a in @($out, $Cols, $Rows, $Flags, $RunMs, $ResizeAt, $ResizeCols, $ResizeRows, $InputAt, $InputText)) {
        $psi.ArgumentList.Add([string]$a)
    }
    foreach ($a in ($cmdlines[$s] -split ' ')) { $psi.ArgumentList.Add($a) }
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($RunMs + 20000)) { $p.Kill(); throw "probe hung for $s" }
    "=== $s (exit $($p.ExitCode)) -> $out"
}
