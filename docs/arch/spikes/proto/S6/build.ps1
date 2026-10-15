# wmux spike S6: build the forwarder (x64 + arm64) and the fake CLI target.
# Outputs go to <worktree>\zig-out\spike-s6\bin (gitignored).
param(
    [string]$Zig = 'C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe'
)
$ErrorActionPreference = 'Stop'
$proto = $PSScriptRoot
$root = (Resolve-Path (Join-Path $proto '..\..\..\..\..')).Path
$out = Join-Path $root 'zig-out\spike-s6\bin'
New-Item -ItemType Directory -Force $out | Out-Null
$cache = Join-Path $root '.zig-cache'

function Build([string]$src, [string]$name, [string]$target, [string]$opt, [string[]]$extra = @()) {
    $emit = Join-Path $out $name
    $a = @('build-exe', (Join-Path $proto $src), '-O', $opt, '-target', $target, "-femit-bin=$emit", '--cache-dir', $cache) + $extra
    & $Zig @a
    if ($LASTEXITCODE -ne 0) { throw "zig build-exe $src ($target) failed: $LASTEXITCODE" }
    Remove-Item -ErrorAction SilentlyContinue ($emit -replace '\.exe$', '.pdb')
    Get-Item $emit | Select-Object Name, Length
}

Build 'fwd.zig' 'wmuxspikefwd-fwd-x64.exe' 'x86_64-windows-gnu' 'ReleaseSmall' @('-fstrip')
Build 'fwd.zig' 'wmuxspikefwd-fwd-arm64.exe' 'aarch64-windows-gnu' 'ReleaseSmall' @('-fstrip')
Build 'target.zig' 'wmuxspikefwd-target.exe' 'x86_64-windows-gnu' 'ReleaseSafe'
