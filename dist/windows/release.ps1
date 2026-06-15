<#
.SYNOPSIS
    Build Ghostty for Windows and package it as an Inno Setup installer.

.DESCRIPTION
    Unofficial community build of the Ghostty terminal emulator for Windows.
    Not affiliated with or endorsed by the Ghostty project.

    Steps:
      1. zig build (ReleaseFast, win32 app runtime, x86_64-windows-gnu)
      2. Stage ghostty.exe, WebView2Loader.dll, and share/ resources into
         dist\windows\_staging\
      3. Compile dist\windows\installer.iss with Inno Setup 6 (ISCC.exe),
         emitting the setup exe to dist\windows\output\

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
    Skip the zig build and package whatever already exists in zig-out\bin.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File dist\windows\release.ps1

.EXAMPLE
    .\dist\windows\release.ps1 -Version 1.2.0 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipBuild
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
# WebView2Loader.dll from the Microsoft.Web.WebView2 NuGet package
# (build/native/x64). Search order: $env:WEBVIEW2LOADER_PATH, the dll beside
# this script, the dll in zig-out\bin, then the local dev staging copy.
$WebView2LoaderSource = @(
    $env:WEBVIEW2LOADER_PATH,
    (Join-Path $ScriptDir 'WebView2Loader.dll'),
    (Join-Path $RepoRoot 'zig-out\bin\WebView2Loader.dll'),
    'C:\Users\ReyColónValero\claude\ghostty-staging\WebView2Loader.dll'
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $WebView2LoaderSource) { $WebView2LoaderSource = 'WebView2Loader.dll' }
$StageDir  = Join-Path $ScriptDir '_staging'
$IssFile   = Join-Path $ScriptDir 'installer.iss'
$OutputDir = Join-Path $ScriptDir 'output'

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

Write-Host "Ghostty Windows installer build" -ForegroundColor Cyan
Write-Host "  Version:         $Version  (VERSIONINFO: $VersionNumeric)"
Write-Host "  Repo root:       $RepoRoot"
Write-Host "  Staging dir:     $StageDir"
Write-Host ''

# --------------------------------------------------------------------------
# Build (ReleaseFast)
# --------------------------------------------------------------------------
if ($SkipBuild) {
    Write-Host 'Skipping zig build (-SkipBuild); using existing zig-out\bin.' -ForegroundColor Yellow
} else {
    # $ZigExe may be a full path or a bare command on PATH (CI). Test-Path
    # only resolves the former, so fall back to Get-Command for the latter.
    if (-not (Test-Path $ZigExe) -and -not (Get-Command $ZigExe -ErrorAction SilentlyContinue)) {
        Fail "Zig compiler not found: $ZigExe"
    }
    Write-Host 'Building ghostty (ReleaseFast)...' -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        # When building from an exact git tag, Ghostty's build.zig requires the
        # tag to match its declared version. Pass an explicit semantic version
        # to bypass that check (and stamp the build) whenever $Version is a
        # plain a.b.c; otherwise let the build derive it from git.
        $zigArgs = @('build', '-Dapp-runtime=win32', '-Dtarget=x86_64-windows-gnu', '-Doptimize=ReleaseFast')
        if ($Version -match '^\d+\.\d+\.\d+$') { $zigArgs += "-Dversion-string=$Version" }
        & $ZigExe @zigArgs
        if ($LASTEXITCODE -ne 0) {
            Fail "zig build failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

$ExePath = Join-Path $RepoRoot 'zig-out\bin\ghostty.exe'
if (-not (Test-Path $ExePath)) {
    Fail "ghostty.exe not found at $ExePath. Run without -SkipBuild, or run the zig build first."
}

# --------------------------------------------------------------------------
# Stage files for the installer
# --------------------------------------------------------------------------
Write-Host 'Staging files...' -ForegroundColor Cyan
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

Copy-Item $ExePath -Destination $StageDir
Write-Host "  ghostty.exe  ($([math]::Round((Get-Item $ExePath).Length / 1MB, 1)) MB)"

if (Test-Path $WebView2LoaderSource) {
    Copy-Item $WebView2LoaderSource -Destination $StageDir
    Write-Host '  WebView2Loader.dll  (Microsoft.Web.WebView2 NuGet, build/native/x64)'
} else {
    Fail @"
WebView2Loader.dll not found at:
  $WebView2LoaderSource

This DLL comes from the Microsoft.Web.WebView2 NuGet package
(path inside the package: build/native/x64/WebView2Loader.dll).
It is redistributable per the WebView2 SDK license. To fetch it:

  `$tmp = Join-Path `$env:TEMP 'webview2-nuget'
  Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile "`$tmp.zip"
  Expand-Archive "`$tmp.zip" `$tmp
  Copy-Item "`$tmp\build\native\x64\WebView2Loader.dll" '$WebView2LoaderSource'

(or: nuget.exe install Microsoft.Web.WebView2, then copy from build\native\x64\)
"@
}

# share/ resources: terminfo sentinel + themes + shell integration.
# resourcesDir() (src/os/resourcesdir.zig) climbs from the exe looking for
# share/terminfo/ghostty.terminfo; without it, theme loading silently fails.
$TerminfoSource = Join-Path $RepoRoot 'zig-out\share\terminfo\ghostty.terminfo'
if (Test-Path $TerminfoSource) {
    $dest = Join-Path $StageDir 'share\terminfo'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $TerminfoSource -Destination $dest
    Write-Host '  share\terminfo\ghostty.terminfo  (resource-dir sentinel)'
} else {
    Write-Host '  WARNING: zig-out\share\terminfo\ghostty.terminfo not found; skipping (theme loading may fail at runtime).' -ForegroundColor Yellow
}

foreach ($sub in 'themes', 'shell-integration') {
    $src = Join-Path $RepoRoot "zig-out\share\ghostty\$sub"
    if (Test-Path $src) {
        $dest = Join-Path $StageDir 'share\ghostty'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item $src -Destination $dest -Recurse
        Write-Host "  share\ghostty\$sub\"
    } else {
        Write-Host "  note: zig-out\share\ghostty\$sub not found; skipping." -ForegroundColor Yellow
    }
}

$LicenseSource = Join-Path $RepoRoot 'LICENSE'
if (Test-Path $LicenseSource) {
    Copy-Item $LicenseSource -Destination (Join-Path $StageDir 'LICENSE.txt')
    Write-Host '  LICENSE.txt'
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
& $Iscc "/DAppVersion=$Version" "/DAppVersionNumeric=$VersionNumeric" "/DStagingDir=$StageDir" "/O$OutputDir" $IssFile
if ($LASTEXITCODE -ne 0) {
    Fail "ISCC failed with exit code $LASTEXITCODE"
}

$SetupExe = Join-Path $OutputDir "ghostty-windows-x64-$Version-setup.exe"
if (-not (Test-Path $SetupExe)) {
    Fail "ISCC reported success but $SetupExe was not found."
}

Write-Host ''
Write-Host 'Installer created:' -ForegroundColor Green
Write-Host "  $SetupExe  ($([math]::Round((Get-Item $SetupExe).Length / 1MB, 1)) MB)"
Write-Host "  SHA256: $((Get-FileHash -Algorithm SHA256 $SetupExe).Hash)"
Write-Host ''
Write-Host 'Note: the installer is unsigned; Windows SmartScreen will warn on first run.' -ForegroundColor Yellow
