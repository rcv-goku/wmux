#Requires -Version 7.0
<#
.SYNOPSIS
    Release smoke (W1-2b): build ReleaseFast, stage the installer payload with
    dist/windows/release.ps1, install it silently to %TEMP% and run the installed CLI.

.DESCRIPTION
    Contract check run by scripts/gate.ps1 (-Merge and -Full run every test/contract/*.ps1).

      1. zig build -Doptimize=ReleaseFast into zig-out\release, the prefix of the gate's
         release step (which completes before the contract step, so this rebuild is cached).
      2. release.ps1 -SkipBuild -Prefix ... -StageDir <temp>: the staged tree must contain
         wmux.exe, cli\cmux.exe, cli\wmux.exe, cli\wmux.com (byte copies), cli\posix\cmux and
         cli\posix\wmux (LF, running ../cmux.exe) and share\wmux\web\about\index.html.
      3. With Inno Setup 6 (ISCC.exe) installed: release.ps1 -Smoke compiles a smoke installer
         (own AppId, no shortcuts, no WebView2 download), which is installed with /VERYSILENT
         to <temp>\install and uninstalled afterwards. Without ISCC the staged tree is copied
         to <temp>\install instead and the installer step is reported as SKIP.
      4. From the installed tree (GUI-subsystem ReleaseFast wmux.exe, every process with
         redirected handles, CREATE_NO_WINDOW and WMUX_TEST_HIDDEN=1, never the user's
         instance: WMUX_SOCKET_PATH names a pipe that does not exist, GHOSTTY_PID is removed):
           - cli\cmux.exe --version exits 0
           - "wmux.exe list-workspaces --json" prints through the relay exactly what
             cli\cmux.exe prints (stdout, stderr, exit code)
           - "wmux.exe +list-themes" runs in-process (exit 0, the staged themes listed)
           - "cli\cmux.exe +version" relays to ..\wmux.exe: same stdout and exit code as
             wmux.exe +version; a failing action (+validate-config on a missing file)
             returns wmux.exe's exit code through the relay

    Exit code 0 when every check passed (SKIP lines allowed), 1 otherwise.

.PARAMETER SkipBuild
    Reuse the existing build under -Prefix.

.PARAMETER Prefix
    Install prefix of the ReleaseFast build (default zig-out\release).

.PARAMETER Keep
    Keep the temp directory for inspection.
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$Prefix,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $RepoRoot 'scripts\lib\WmuxTooling.psm1') -Force
if (-not $Prefix) { $Prefix = Join-Path $RepoRoot 'zig-out\release' }
$Prefix = [IO.Path]::GetFullPath($Prefix)
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('wmux-release-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$StageDir = Join-Path $Temp 'stage'
$OutDir = Join-Path $Temp 'out'
$InstallDir = Join-Path $Temp 'install'
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Write-Result([string]$Status, [string]$Message) {
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("{0,-4} {1}" -f $Status, $Message) -ForegroundColor $color
    if ($Status -eq 'FAIL') { $script:Failures.Add($Message) }
}

function Test-Check([string]$Name, [scriptblock]$Body) {
    try {
        $why = & $Body
        if ($why) { Write-Result 'FAIL' "${Name}: $why" } else { Write-Result 'PASS' $Name }
    } catch {
        Write-Result 'FAIL' "${Name}: $($_.Exception.Message)"
    }
}

# Environment of every process the smoke starts: hidden test mode, isolated state, no route
# to the user's instance.
$NoPipe = '\\.\pipe\wmux-release-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
function New-SmokeEnvironment {
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $vars = [Environment]::GetEnvironmentVariables()
    foreach ($k in $vars.Keys) { $map[[string]$k] = [string]$vars[$k] }
    foreach ($k in @('GHOSTTY_PID', 'CMUX_SOCKET', 'WMUX_ARGV0', 'CMUX_WORKSPACE_ID', 'CMUX_SURFACE_ID', 'WMUX_WORKSPACE_ID', 'WMUX_SURFACE_ID')) { $null = $map.Remove($k) }
    $map['WMUX_SOCKET_PATH'] = $NoPipe
    $map['CMUX_SOCKET_PATH'] = $NoPipe
    $map['WMUX_TEST_MODE'] = '1'
    $map['WMUX_TEST_HIDDEN'] = '1'
    $map['WMUX_CHANNEL'] = 'release-smoke'
    $map['WMUX_STATE_DIR'] = Join-Path $Temp 'state'
    $map['WMUX_CONFIG_DIR'] = Join-Path $Temp 'config'
    $map['XDG_CONFIG_HOME'] = Join-Path $Temp 'xdg'
    $map['LOCALAPPDATA'] = Join-Path $Temp 'localappdata'
    $map['WMUX_QUIET'] = '1'
    return $map
}

function Invoke-Smoke([string]$Exe, [string[]]$Argv, [int]$TimeoutSec = 60) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Argv) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.WorkingDirectory = $Temp
    $envMap = New-SmokeEnvironment
    $psi.Environment.Clear()
    foreach ($k in $envMap.Keys) { $psi.Environment[$k] = $envMap[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        try { $p.StandardInput.Close() } catch { }
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            throw "$([IO.Path]::GetFileName($Exe)) $($Argv -join ' ') timed out after ${TimeoutSec}s"
        }
        $p.WaitForExit()
        $null = $out.Wait(5000)
        $null = $err.Wait(5000)
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
    } finally { $p.Dispose() }
}

function Format-Run($r) {
    $o = ($r.Stdout -replace "`r?`n", '\n'); $e = ($r.Stderr -replace "`r?`n", '\n')
    if ($o.Length -gt 200) { $o = $o.Substring(0, 200) + '...' }
    if ($e.Length -gt 200) { $e = $e.Substring(0, 200) + '...' }
    return "exit=$($r.ExitCode) stdout='$o' stderr='$e'"
}

$pwshExe = (Get-Process -Id $PID).Path
try {
    New-Item -ItemType Directory -Force -Path $Temp | Out-Null
    Write-Host "release-smoke: prefix $Prefix, temp $Temp"

    # 1. ReleaseFast build.
    $zig = Resolve-WmuxZig -Tag 'release-smoke'
    $env:ZIG = $zig
    if (-not $SkipBuild) {
        $zigArgs = @('build', '-Dapp-runtime=win32', '-Dtarget=x86_64-windows-gnu', '-Doptimize=ReleaseFast', '--prefix', $Prefix)
        Write-Host "release-smoke: $zig $($zigArgs -join ' ')"
        Push-Location $RepoRoot
        try { & $zig @zigArgs } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
        Write-Result 'PASS' 'ReleaseFast build'
    }

    # 2. Staging (and the installer when ISCC exists).
    $iscc = @(
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' }),
        $(Get-Command 'iscc.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source)
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    $relArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'dist\windows\release.ps1'),
        '-SkipBuild', '-Prefix', $Prefix, '-StageDir', $StageDir, '-OutputDir', $OutDir, '-Version', 'smoke', '-NoDownload')
    $relArgs += if ($iscc) { '-Smoke' } else { '-NoInstaller' }
    & $pwshExe @relArgs
    if ($LASTEXITCODE -ne 0) { throw "release.ps1 failed with exit code $LASTEXITCODE" }

    Test-Check 'staged tree has the ADR-4.1 layout' {
        $missing = @('wmux.exe', 'cli\cmux.exe', 'cli\wmux.exe', 'cli\wmux.com', 'cli\posix\cmux', 'cli\posix\wmux',
            'share\wmux\web\about\index.html', 'share\wmux\schema\wmux.schema.json', 'share\ghostty\themes') |
            Where-Object { -not (Test-Path -LiteralPath (Join-Path $StageDir $_)) }
        if ($missing) { return "missing: $($missing -join ', ')" }
    }
    Test-Check 'cli\wmux.exe and cli\wmux.com are byte copies of cli\cmux.exe' {
        $h = @('cmux.exe', 'wmux.exe', 'wmux.com') | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $StageDir "cli\$_")).Hash }
        if (@($h | Select-Object -Unique).Count -ne 1) { return "hashes differ: $($h -join ', ')" }
    }
    Test-Check 'cli\posix launchers are LF and run ../cmux.exe' {
        foreach ($n in 'cmux', 'wmux') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $StageDir "cli\posix\$n"))
            if ($bytes -contains 13) { return "$n has CR bytes" }
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { return "$n has a BOM" }
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            if (-not $text.Contains('exec "$(dirname "$0")/../cmux.exe" "$@"')) { return "$n does not exec ../cmux.exe" }
            if (-not $text.Contains("WMUX_ARGV0=$n")) { return "$n does not set WMUX_ARGV0=$n" }
        }
    }

    # 3. Install.
    $setup = Join-Path $OutDir 'wmux-windows-x64-smoke-setup.exe'
    $installed = $false
    if ($iscc) {
        Test-Check 'silent install of the smoke installer' {
            if (-not (Test-Path -LiteralPath $setup)) { return "$setup was not produced" }
            $p = Start-Process -FilePath $setup -PassThru -Wait -WindowStyle Hidden -ArgumentList @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', '/CURRENTUSER',
                "/DIR=`"$InstallDir`"", "/LOG=`"$(Join-Path $Temp 'install.log')`"")
            if ($p.ExitCode -ne 0) { return "setup exited with $($p.ExitCode) (see install.log)" }
            if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'cli\cmux.exe'))) { return 'cli\cmux.exe not installed' }
        }
        $installed = Test-Path -LiteralPath (Join-Path $InstallDir 'unins000.exe')
    } else {
        Write-Result 'SKIP' 'installer: Inno Setup 6 (ISCC.exe) not found; the staged tree is copied to the install directory instead (winget install -e --id JRSoftware.InnoSetup)'
        Copy-Item -LiteralPath $StageDir -Destination $InstallDir -Recurse
    }

    # 4. The installed CLI and the relays.
    $gui = Join-Path $InstallDir 'wmux.exe'
    $cli = Join-Path $InstallDir 'cli\cmux.exe'
    Test-Check 'installed cli\cmux.exe --version exits 0' {
        $r = Invoke-Smoke $cli @('--version')
        if ($r.ExitCode -ne 0) { return (Format-Run $r) }
        if (-not $r.Stdout.Trim()) { return 'no version text' }
    }
    Test-Check '"wmux.exe list-workspaces --json" prints through the relay' {
        $direct = Invoke-Smoke $cli @('list-workspaces', '--json')
        $relayed = Invoke-Smoke $gui @('list-workspaces', '--json')
        if (-not ($direct.Stdout + $direct.Stderr).Trim()) { return "cli\cmux.exe printed nothing: $(Format-Run $direct)" }
        # cli\cmux.exe brands itself cmux; through wmux.exe it is wmux (WMUX_ARGV0=wmux).
        $want = [regex]::Replace($direct.Stderr, '\bcmux\b', 'wmux')
        if ($relayed.ExitCode -ne $direct.ExitCode -or $relayed.Stdout -cne $direct.Stdout -or $relayed.Stderr -cne $want) {
            return "relayed $(Format-Run $relayed); direct $(Format-Run $direct)"
        }
    }
    Test-Check '"wmux.exe +list-themes" runs in-process' {
        $r = Invoke-Smoke $gui @('+list-themes', '--plain')
        if ($r.ExitCode -ne 0) { return (Format-Run $r) }
        $themes = @(Get-ChildItem -LiteralPath (Join-Path $InstallDir 'share\ghostty\themes') -File).Count
        $lines = @($r.Stdout -split "`r?`n" | Where-Object { $_ }).Count
        if ($lines -lt [Math]::Min(10, $themes)) { return "listed $lines of $themes themes: $(Format-Run $r)" }
        if ($r.Stderr -match 'cmux|unknown command') { return "went through the CLI: $(Format-Run $r)" }
    }
    Test-Check '"cmux +version" relays to wmux.exe and returns its exit code' {
        $direct = Invoke-Smoke $gui @('+version')
        $relayed = Invoke-Smoke $cli @('+version')
        if ($direct.ExitCode -ne 0) { return "wmux.exe +version: $(Format-Run $direct)" }
        if ($relayed.ExitCode -ne $direct.ExitCode -or $relayed.Stdout -cne $direct.Stdout) {
            return "relayed $(Format-Run $relayed); direct $(Format-Run $direct)"
        }
        $missing = Join-Path $Temp 'no-such-config'
        $d2 = Invoke-Smoke $gui @('+validate-config', "--config-file=$missing")
        $r2 = Invoke-Smoke $cli @('+validate-config', "--config-file=$missing")
        if ($d2.ExitCode -eq 0) { return "+validate-config on a missing file exited 0: $(Format-Run $d2)" }
        if ($r2.ExitCode -ne $d2.ExitCode) { return "failing action: relayed exit $($r2.ExitCode), direct $($d2.ExitCode)" }
    }

    if ($installed) {
        Test-Check 'silent uninstall' {
            $p = Start-Process -FilePath (Join-Path $InstallDir 'unins000.exe') -PassThru -Wait -WindowStyle Hidden -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
            if ($p.ExitCode -ne 0) { return "uninstaller exited with $($p.ExitCode)" }
        }
    }
} catch {
    Write-Result 'FAIL' $_.Exception.Message
} finally {
    if ($Keep) {
        Write-Host "release-smoke: kept $Temp"
    } else {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures.Count) {
    Write-Host "release-smoke: $($script:Failures.Count) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'release-smoke: ok' -ForegroundColor Green
exit 0
