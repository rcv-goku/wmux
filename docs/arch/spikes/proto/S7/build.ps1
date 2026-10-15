# Build the S7 spike prototype (standalone; not part of the wmux build graph).
# Usage: pwsh docs/arch/spikes/proto/S7/build.ps1 -Out <scratch dir>
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Zig = 'C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe',
    [string]$WebView2Loader = "$env:LOCALAPPDATA\Programs\wmux\WebView2Loader.dll"
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
& $Zig cc -O2 -g -target x86_64-windows-gnu "$PSScriptRoot\s7proto.c" -o "$Out\s7proto.exe" `
    -ld2d1 -ldwrite -ld3d11 -ldxgi -ldwmapi -lopengl32 -lgdi32 -luser32 -lole32 -lpsapi
if ($LASTEXITCODE -ne 0) { throw "zig cc failed ($LASTEXITCODE)" }
if ((Test-Path $WebView2Loader) -and -not (Test-Path "$Out\WebView2Loader.dll")) {
    Copy-Item $WebView2Loader "$Out\WebView2Loader.dll"
}
Get-Item "$Out\s7proto.exe" | Select-Object FullName, Length
