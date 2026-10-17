<#
.SYNOPSIS
    Build wmux for Windows and package it as an Inno Setup installer.

.DESCRIPTION
    Steps:
      1. zig build (ReleaseFast, win32 app runtime, x86_64-windows-gnu) into
         -Prefix (default zig-out)
      2. Stage into dist\windows\_staging\ (or -StageDir) the install layout
         of ARCHITECTURE ADR-4.1 (W1-2b):
           wmux.exe, WebView2Loader.dll, LICENSE.txt
           cli\cmux.exe, cli\wmux.exe and cli\wmux.com (byte copies of the
             console CLI; wmux.exe relays CLI argv to cli\cmux.exe)
           cli\posix\cmux, cli\posix\wmux (LF sh launchers running ..\cmux.exe)
           share\terminfo, share\ghostty\{themes,shell-integration}
           share\wmux\** (web apps, settings schema and every other wmux
             resource the build installs)
      3. Compile dist\windows\installer.iss with Inno Setup 6 (ISCC.exe),
         emitting the setup exe to dist\windows\output\ (or -OutputDir);
         skipped with -NoInstaller

    WebView2Loader.dll origin: the Microsoft.Web.WebView2 NuGet package,
    path build/native/x64/WebView2Loader.dll inside the .nupkg. It is
    redistributable per the WebView2 SDK license.

    This script runs NO git write commands (the only git use is the
    read-only `git describe` for the default version string) and makes
    NO changes to PATH or any other environment variables.

.PARAMETER Version
    Version string embedded in the installer and its filename.
    Default: `git describe --tags --always` in the repo, else "dev".

.PARAMETER SkipBuild
    Skip the zig build and package whatever already exists under -Prefix.

.PARAMETER Prefix
    Install prefix of the zig build (bin\ and share\ below it). Default:
    zig-out in the repo. test/contract/release-smoke.ps1 passes zig-out\release.

.PARAMETER StageDir
    Staging directory (default dist\windows\_staging). It is recreated.

.PARAMETER OutputDir
    Directory for the compiled setup exe (default dist\windows\output).

.PARAMETER NoInstaller
    Stop after staging (exit 0); ISCC is not needed.

.PARAMETER Smoke
    Compile the installer with /DReleaseSmoke=1: a separate AppId and no
    shortcuts, so a silent test install never touches the user's wmux
    installation (test/contract/release-smoke.ps1).

.PARAMETER NoDownload
    Never download WebView2Loader.dll from NuGet; stage without it (with a
    warning) when no local copy exists.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File dist\windows\release.ps1

.EXAMPLE
    .\dist\windows\release.ps1 -Version 1.2.0 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipBuild,
    [string]$Prefix,
    [string]$StageDir,
    [string]$OutputDir,
    [switch]$NoInstaller,
    [switch]$Smoke,
    [switch]$NoDownload
)

$ErrorActionPreference = 'Stop'

# All paths are derived from this script's location so the script works
# from any current working directory.
$ScriptDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
# Prefer the pinned local toolchain; fall back to `zig` on PATH (CI uses the
# latter via mlugg/setup-zig). Override with $env:ZIG.
$ZigExe = if ($env:ZIG) { $env:ZIG }
          elseif (Test-Path 'C:\Users\ReyColónValero\claude\tools\zig-x86_64-windows-0.15.2\zig.exe') { 'C:\Users\ReyColónValero\claude\tools\zig-x86_64-windows-0.15.2\zig.exe' }
          else { 'zig' }
$Prefix = if ($Prefix) { [IO.Path]::GetFullPath($Prefix) } else { Join-Path $RepoRoot 'zig-out' }
$BinDir = Join-Path $Prefix 'bin'
$ShareDir = Join-Path $Prefix 'share'
# WebView2Loader.dll from the Microsoft.Web.WebView2 NuGet package
# (build/native/x64). Search order: $env:WEBVIEW2LOADER_PATH, the dll beside
# this script, the dll in the build's bin\, the local dev staging copy, then
# an installed wmux.
$WebView2LoaderSource = @(
    $env:WEBVIEW2LOADER_PATH,
    (Join-Path $ScriptDir 'WebView2Loader.dll'),
    (Join-Path $BinDir 'WebView2Loader.dll'),
    'C:\Users\ReyColónValero\claude\ghostty-staging\WebView2Loader.dll',
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\wmux\WebView2Loader.dll' })
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $WebView2LoaderSource) { $WebView2LoaderSource = 'WebView2Loader.dll' }
$StageDir  = if ($StageDir) { [IO.Path]::GetFullPath($StageDir) } else { Join-Path $ScriptDir '_staging' }
$IssFile   = Join-Path $ScriptDir 'installer.iss'
$OutputDir = if ($OutputDir) { [IO.Path]::GetFullPath($OutputDir) } else { Join-Path $ScriptDir 'output' }

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------------------
# Version
# --------------------------------------------------------------------------
if (-not $Version) {
    try {
        # Read-only git usage; this script never runs git write commands.
        $Version = [string](& git -C $RepoRoot describe --tags --always 2>$null | Select-Object -First 1)
    } catch {
        $Version = ''
    }
    if (-not $Version) { $Version = 'dev' }
}
$Version = $Version.Trim()
# Keep the version safe for use inside the output filename.
$Version = $Version -replace '[^A-Za-z0-9._+\-]', '_'

# Derive a numeric a.b.c.d for the VERSIONINFO resource (Inno requires a
# purely numeric VersionInfoVersion; git-describe strings are not).
$VersionNumeric = '0.0.0.0'
if ($Version -match '(\d+)\.(\d+)\.(\d+)(?:-(\d+))?') {
    $rev = 0
    if ($Matches.ContainsKey(4) -and $Matches[4]) { $rev = [int]$Matches[4] }
    $VersionNumeric = '{0}.{1}.{2}.{3}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $rev
}

Write-Host "wmux Windows installer build" -ForegroundColor Cyan
Write-Host "  Version:         $Version  (VERSIONINFO: $VersionNumeric)"
Write-Host "  Repo root:       $RepoRoot"
Write-Host "  Staging dir:     $StageDir"
Write-Host ''

# --------------------------------------------------------------------------
# Build (ReleaseFast)
# --------------------------------------------------------------------------
if ($SkipBuild) {
    Write-Host "Skipping zig build (-SkipBuild); using existing $BinDir." -ForegroundColor Yellow
} else {
    # $ZigExe may be a full path or a bare command on PATH (CI). Test-Path
    # only resolves the former, so fall back to Get-Command for the latter.
    if (-not (Test-Path $ZigExe) -and -not (Get-Command $ZigExe -ErrorAction SilentlyContinue)) {
        Fail "Zig compiler not found: $ZigExe"
    }
    Write-Host 'Building wmux (ReleaseFast)...' -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        # When building from an exact git tag, build.zig requires the tag to
        # match its declared version. Pass an explicit semantic version to
        # bypass that check (and stamp the build) whenever $Version is a
        # plain a.b.c; otherwise let the build derive it from git.
        $zigArgs = @('build', '-Dapp-runtime=win32', '-Dtarget=x86_64-windows-gnu', '-Doptimize=ReleaseFast', '--prefix', $Prefix)
        if ($Version -match '^\d+\.\d+\.\d+$') { $zigArgs += "-Dversion-string=$Version" }
        & $ZigExe @zigArgs
        if ($LASTEXITCODE -ne 0) {
            Fail "zig build failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

$ExePath = Join-Path $BinDir 'wmux.exe'
if (-not (Test-Path $ExePath)) {
    # Builds before the wmux rename produced ghostty.exe.
    $ExePath = Join-Path $BinDir 'ghostty.exe'
}
if (-not (Test-Path $ExePath)) {
    Fail "wmux.exe (or ghostty.exe) not found in $BinDir. Run without -SkipBuild, or run the zig build first."
}
$CliExe = Join-Path $BinDir 'cli\cmux.exe'
if (-not (Test-Path $CliExe)) {
    Fail "cli\cmux.exe not found in $BinDir (the build installs it next to wmux.exe, ADR-4.1)."
}

# --------------------------------------------------------------------------
# Stage files for the installer
# --------------------------------------------------------------------------
Write-Host 'Staging files...' -ForegroundColor Cyan
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

Copy-Item $ExePath -Destination (Join-Path $StageDir 'wmux.exe')
Write-Host "  wmux.exe  ($([math]::Round((Get-Item $ExePath).Length / 1MB, 1)) MB)"

# cli\: the console CLI and its byte copies (ADR-4.1; amendments of spike S4
# and S6), and the POSIX launchers in cli\posix\ running ..\cmux.exe.
$CliStage = Join-Path $StageDir 'cli'
New-Item -ItemType Directory -Path (Join-Path $CliStage 'posix') -Force | Out-Null
foreach ($name in 'cmux.exe', 'wmux.exe', 'wmux.com') {
    Copy-Item $CliExe -Destination (Join-Path $CliStage $name)
}
Write-Host '  cli\cmux.exe, cli\wmux.exe, cli\wmux.com'
foreach ($name in 'cmux', 'wmux') {
    $src = Join-Path $RepoRoot "src\wmux_cli\scripts\$name"
    if (-not (Test-Path $src)) { Fail "POSIX launcher not found: $src" }
    # The source launcher runs its sibling cmux.exe; staged in cli\posix\ it
    # runs ..\cmux.exe. LF line endings, no BOM (sh reads it).
    $text = [IO.File]::ReadAllText($src).Replace("`r`n", "`n")
    $text = $text.Replace('"$(dirname "$0")/cmux.exe"', '"$(dirname "$0")/../cmux.exe"')
    if ($text -notmatch [regex]::Escape('"$(dirname "$0")/../cmux.exe"')) { Fail "unexpected launcher contents in $src" }
    [IO.File]::WriteAllText((Join-Path $CliStage "posix\$name"), $text, [Text.UTF8Encoding]::new($false))
}
Write-Host '  cli\posix\cmux, cli\posix\wmux'

if (Test-Path $WebView2LoaderSource) {
    Copy-Item $WebView2LoaderSource -Destination $StageDir
    Write-Host '  WebView2Loader.dll  (Microsoft.Web.WebView2 NuGet, build/native/x64)'
} elseif ($NoDownload) {
    Write-Host '  WARNING: WebView2Loader.dll not found locally and -NoDownload is set; staged without it.' -ForegroundColor Yellow
} else {
    Write-Host '  WebView2Loader.dll not found locally; downloading from NuGet...' -ForegroundColor Yellow
    $NuGetTmp = Join-Path $env:TEMP 'webview2-nuget'
    $NuGetZip = "$NuGetTmp.zip"
    try {
        Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $NuGetZip -UseBasicParsing
        if (Test-Path $NuGetTmp) { Remove-Item -Recurse -Force $NuGetTmp }
        Expand-Archive $NuGetZip $NuGetTmp
        $DownloadedDll = Join-Path $NuGetTmp 'build\native\x64\WebView2Loader.dll'
        if (-not (Test-Path $DownloadedDll)) {
            Fail "Downloaded NuGet package but WebView2Loader.dll not found at expected path: $DownloadedDll"
        }
        Copy-Item $DownloadedDll -Destination $StageDir
        # Also cache a copy beside this script for future builds.
        Copy-Item $DownloadedDll -Destination (Join-Path $ScriptDir 'WebView2Loader.dll')
        Write-Host '  WebView2Loader.dll  (auto-downloaded from Microsoft.Web.WebView2 NuGet)'
    } catch {
        Fail @"
WebView2Loader.dll not found and auto-download failed.
Error: $($_.Exception.Message)

This DLL comes from the Microsoft.Web.WebView2 NuGet package
(path inside the package: build/native/x64/WebView2Loader.dll).
It is redistributable per the WebView2 SDK license. To fetch it manually:

  `$tmp = Join-Path `$env:TEMP 'webview2-nuget'
  Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile "`$tmp.zip"
  Expand-Archive "`$tmp.zip" `$tmp
  Copy-Item "`$tmp\build\native\x64\WebView2Loader.dll" '$(Join-Path $ScriptDir 'WebView2Loader.dll')'

(or: nuget.exe install Microsoft.Web.WebView2, then copy from build\native\x64\)
"@
    } finally {
        # Clean up temp files.
        if (Test-Path $NuGetZip) { Remove-Item -Force $NuGetZip -ErrorAction SilentlyContinue }
        if (Test-Path $NuGetTmp) { Remove-Item -Recurse -Force $NuGetTmp -ErrorAction SilentlyContinue }
    }
}

# share/ resources: terminfo sentinel + themes + shell integration.
# resourcesDir() (src/os/resourcesdir.zig) climbs from the exe looking for
# share/terminfo/ghostty.terminfo; without it, theme loading silently fails.
$TerminfoSource = Join-Path $ShareDir 'terminfo\ghostty.terminfo'
if (Test-Path $TerminfoSource) {
    $dest = Join-Path $StageDir 'share\terminfo'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $TerminfoSource -Destination $dest
    Write-Host '  share\terminfo\ghostty.terminfo  (resource-dir sentinel)'
} else {
    Write-Host "  WARNING: $TerminfoSource not found; skipping (theme loading may fail at runtime)." -ForegroundColor Yellow
}

foreach ($sub in 'themes', 'shell-integration') {
    $src = Join-Path $ShareDir "ghostty\$sub"
    if (Test-Path $src) {
        $dest = Join-Path $StageDir 'share\ghostty'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item $src -Destination $dest -Recurse
        Write-Host "  share\ghostty\$sub\"
    } else {
        Write-Host "  note: $src not found; skipping." -ForegroundColor Yellow
    }
}

# share\wmux\**: everything the build installs for wmux (web apps, settings
# schema, and later icons and shell integration), copied as a whole so the
# installed layout matches the build's share\ (ADR-4.1, W1-2b).
$WmuxShare = Join-Path $ShareDir 'wmux'
if (Test-Path $WmuxShare) {
    $dest = Join-Path $StageDir 'share'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $WmuxShare -Destination $dest -Recurse
    $subs = @(Get-ChildItem -LiteralPath $WmuxShare -Directory | ForEach-Object Name) -join ', '
    Write-Host "  share\wmux\  ($subs)"
} else {
    Write-Host "  WARNING: $WmuxShare not found; the web panels and the settings schema are missing." -ForegroundColor Yellow
}

$LicenseSource = Join-Path $RepoRoot 'LICENSE'
if (Test-Path $LicenseSource) {
    Copy-Item $LicenseSource -Destination (Join-Path $StageDir 'LICENSE.txt')
    Write-Host '  LICENSE.txt'
}

if ($NoInstaller) {
    Write-Host ''
    Write-Host "Staging complete (-NoInstaller): $StageDir" -ForegroundColor Green
    exit 0
}

# --------------------------------------------------------------------------
# Locate Inno Setup 6 (ISCC.exe)
# --------------------------------------------------------------------------
$IsccCandidates = @()
foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if ($base) { $IsccCandidates += (Join-Path $base 'Inno Setup 6\ISCC.exe') }
}
if ($env:LOCALAPPDATA) {
    $IsccCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
}
$Iscc = $IsccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Iscc) {
    $cmd = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $Iscc = $cmd.Source }
}

if (-not $Iscc) {
    Write-Host ''
    Write-Host 'Staging complete, but Inno Setup 6 (ISCC.exe) was not found, so no installer was compiled.' -ForegroundColor Yellow
    Write-Host "Staged files are in: $StageDir"
    Write-Host ''
    Write-Host 'Install Inno Setup 6 with:' -ForegroundColor Yellow
    Write-Host '  winget install -e --id JRSoftware.InnoSetup'
    Write-Host 'then re-run this script (add -SkipBuild to reuse the existing build).'
    exit 1
}

# --------------------------------------------------------------------------
# Compile the installer
# --------------------------------------------------------------------------
Write-Host ''
Write-Host "Compiling installer with: $Iscc" -ForegroundColor Cyan
$IsccArgs = @("/DAppVersion=$Version", "/DAppVersionNumeric=$VersionNumeric", "/DStagingDir=$StageDir", "/O$OutputDir")
if ($Smoke) { $IsccArgs += '/DReleaseSmoke=1' }
& $Iscc @IsccArgs $IssFile
if ($LASTEXITCODE -ne 0) {
    Fail "ISCC failed with exit code $LASTEXITCODE"
}

$SetupExe = Join-Path $OutputDir "wmux-windows-x64-$Version-setup.exe"
if (-not (Test-Path $SetupExe)) {
    Fail "ISCC reported success but $SetupExe was not found."
}

Write-Host ''
Write-Host 'Installer created:' -ForegroundColor Green
Write-Host "  $SetupExe  ($([math]::Round((Get-Item $SetupExe).Length / 1MB, 1)) MB)"
Write-Host "  SHA256: $((Get-FileHash -Algorithm SHA256 $SetupExe).Hash)"
Write-Host ''
Write-Host 'Note: the installer is unsigned; Windows SmartScreen will warn on first run.' -ForegroundColor Yellow
