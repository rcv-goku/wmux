# S4 spike: resolution cost on a realistic PATH, non-ASCII paths, launch overhead (interleaved runs).
param([Parameter(Mandatory)] [string] $Root)
. "$PSScriptRoot\common.ps1"
$B = $script:S4Base
$wrap = "$Root\shims\wrap\claude.exe"

# 1. Realistic PATH: this machine's Machine+User PATH minus any directory that holds a claude.* (the
#    real Claude Code lives in ~/.local/bin and must never run here), native dummy appended last.
$entries = (([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')) -split ';') |
    Where-Object { $_ -and -not (Test-Path (Join-Path ([Environment]::ExpandEnvironmentVariables($_)) 'claude*')) }
$realistic = "$Root\shims\wrap;" + ($entries -join ';') + ";$Root\native"
$us = foreach ($i in 1..10) {
    $r = Invoke-S4 -File $wrap -ArgList @('x') -Path $realistic -Cwd $Root -Env @{ S4_WRAP_VERBOSE = '1' }
    if ($r.Err -match 'resolved in (\d+) us') { [int]$Matches[1] }
    if ($i -eq 1) { "ran: " + $(if ($r.Out -match 'S4IDENT exe=(.+)') { $Matches[1].Trim().Replace("$Root\", '<R>\') } else { 'NONE ' + $r.Err }) }
}
"PATH entries scanned before the hit: $($entries.Count + 1); resolve time us (10 runs): $($us -join ', '); median $(($us | Sort-Object)[5])"

# 2. Non-ASCII directory names.
$uni = Join-Path $Root 'nativé dir ü'
New-Item -ItemType Directory -Force $uni | Out-Null
Copy-Item "$Root\bin\ident.exe" (Join-Path $uni 'claude.exe') -Force
$r = Invoke-S4 -File $wrap -ArgList @('ünï', 'x y') -Path "$Root\shims\wrap;$uni;$B" -Cwd $Root
"non-ASCII: " + (($r.Out -split "`r?`n" | Where-Object { $_ -match 'S4IDENT (exe|argv\[[12]\])' }) -join ' / ').Replace("$Root\", '<R>\')

# 3. Launch overhead, interleaved: direct vs ReleaseSafe wrapper vs ReleaseSmall wrapper.
$smallDir = Join-Path $Root 'shims\wrapsmall'
New-Item -ItemType Directory -Force $smallDir | Out-Null
if (-not (Test-Path "$smallDir\claude.exe")) { New-Item -ItemType HardLink -Path "$smallDir\claude.exe" -Target "$Root\bin\wrapper-small.exe" | Out-Null }
$d = @(); $ws = @(); $wm = @()
foreach ($i in 1..20) {
    $d += (Invoke-S4 -File "$Root\native\claude.exe" -ArgList @('x') -Path "$Root\native;$B" -Cwd $Root).Ms
    $ws += (Invoke-S4 -File $wrap -ArgList @('x') -Path "$Root\shims\wrap;$Root\native;$B" -Cwd $Root).Ms
    $wm += (Invoke-S4 -File "$smallDir\claude.exe" -ArgList @('x') -Path "$smallDir;$Root\native;$B" -Cwd $Root).Ms
}
$med = { param($xs) ($xs | Sort-Object)[[int][Math]::Floor($xs.Count / 2)] }
"launch ms median of 20 (interleaved): direct=$(& $med $d) wrapper(ReleaseSafe)=$(& $med $ws) wrapper(ReleaseSmall)=$(& $med $wm)"
"  direct: $($d -join ',')"
"  safe:   $($ws -join ',')"
"  small:  $($wm -join ',')"
