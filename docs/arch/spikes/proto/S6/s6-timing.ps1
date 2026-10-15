# wmux spike S6: launch overhead (steady state, interleaved/paired) and first launch
# of never-seen binaries (AV/EDR cost). Must run inside ONE hidden console (start it
# through Invoke-Proc / CreateNoWindow): children are started without CreateNoWindow
# so they share that console instead of each getting a new conhost.exe.
param([int]$Rounds = 60, [int]$Fresh = 8, [switch]$Inner)
. (Join-Path $PSScriptRoot 's6-common.ps1')
$ErrorActionPreference = 'Stop'

if (-not $Inner) {
    # Outer: re-launch self hidden, then print the result file.
    $r = Invoke-Proc -File $S6.Pwsh -Arguments "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Rounds $Rounds -Fresh $Fresh" -TimeoutMs 1800000
    $r.Out; $r.Err
    return
}

function Start-Wait([string]$file, [string]$a, [hashtable]$envAdd) {
    $psi = [Diagnostics.ProcessStartInfo]::new($file, $a)
    $psi.UseShellExecute = $false   # no CreateNoWindow: inherit our hidden console
    if ($envAdd) { foreach ($k in $envAdd.Keys) { $psi.Environment[$k] = $envAdd[$k] } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit()
    $sw.Stop()
    return [pscustomobject]@{ ms = $sw.Elapsed.TotalMilliseconds; exit = $p.ExitCode }
}
function Stat([double[]]$xs) {
    $s = @($xs | Sort-Object); $n = $s.Count
    [ordered]@{ n = $n; min = [math]::Round($s[0], 1); median = [math]::Round($s[[int][math]::Floor($n / 2)], 1); p90 = [math]::Round($s[[int][math]::Floor($n * 0.9)], 1) }
}

$res = [ordered]@{ started = (Get-Date).ToString('o'); cpu_load_start = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average }
try {
    if (@(Get-SpikeWindowsAppsFiles).Count) { throw 'run s6-cleanup.ps1 first' }
    Install-SpikeTarget
    $fwd = Join-Path $S6.WA 'wmuxspikefwd.exe'; Copy-Item $S6.Fwd $fwd -Force
    $shim = Join-Path $S6.WA 'wmuxspikefwdcmd.cmd'; [IO.File]::WriteAllText($shim, "@`"$($S6.Target)`" %*`r`n", [Text.Encoding]::ASCII)
    $hl = Join-Path $S6.WA 'wmuxspikefwdhl.exe'; New-Item -ItemType HardLink -Path $hl -Target $S6.Target | Out-Null
    $variants = [ordered]@{
        'direct'     = @{ f = $S6.Target; e = $null }
        'fwd(job)'   = @{ f = $fwd; e = $null }
        'fwd(nojob)' = @{ f = $fwd; e = @{ WMUXSPIKEFWD_MODE = 'nojob' } }
        'hardlink'   = @{ f = $hl; e = $null }
        'cmd-shim'   = @{ f = $shim; e = $null }
    }
    $ms = @{}; foreach ($k in $variants.Keys) { $ms[$k] = [Collections.Generic.List[double]]::new() }
    for ($i = 0; $i -lt $Rounds + 3; $i++) {
        foreach ($k in $variants.Keys) {
            $r = Start-Wait $variants[$k].f 'exit 0' $variants[$k].e
            if ($r.exit -ne 0) { throw "$k exit $($r.exit)" }
            if ($i -ge 3) { $ms[$k].Add($r.ms) }
        }
    }
    $steady = [ordered]@{}
    foreach ($k in $variants.Keys) { $steady[$k] = Stat $ms[$k].ToArray() }
    foreach ($k in 'fwd(job)', 'fwd(nojob)', 'hardlink', 'cmd-shim') {
        $d = for ($j = 0; $j -lt $ms[$k].Count; $j++) { $ms[$k][$j] - $ms['direct'][$j] }
        $steady["paired overhead vs direct: $k"] = Stat $d
    }
    $res.steady_state_ms = $steady

    # First launch of never-seen binaries (unique bytes => unknown hash for AV/EDR).
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $fb = [IO.File]::ReadAllBytes($S6.Fwd); $tb = [IO.File]::ReadAllBytes($S6.Target)
    $ctl = Join-Path $S6.Run 'fresh-bin'; New-Item -ItemType Directory -Force $ctl | Out-Null
    $first = [ordered]@{}
    $lists = @{}
    try {
        for ($i = 1; $i -le $Fresh; $i++) {
            foreach ($case in 'fwd@WindowsApps', 'fwd@scratch', 'cli@scratch') {
                $salt = [byte[]]::new(64); $rng.GetBytes($salt)
                $src = if ($case -like 'cli*') { $tb } else { $fb }
                $dst = switch ($case) { 'fwd@WindowsApps' { Join-Path $S6.WA "wmuxspikefwdnew$i.exe" } 'fwd@scratch' { Join-Path $ctl "wmuxspikefwdnew$i.exe" } 'cli@scratch' { Join-Path $ctl "wmuxspikefwdcli$i.exe" } }
                [IO.File]::WriteAllBytes($dst, (Join-Bytes $src $salt))
                $a = Start-Wait $dst 'exit 0' $null
                $b = Start-Wait $dst 'exit 0' $null
                $c = Start-Wait $dst 'exit 0' $null
                foreach ($x in 'first', 'second', 'third') { if (-not $lists["$case/$x"]) { $lists["$case/$x"] = [Collections.Generic.List[double]]::new() } }
                $lists["$case/first"].Add($a.ms); $lists["$case/second"].Add($b.ms); $lists["$case/third"].Add($c.ms)
                if (-not (Test-Path $dst)) { $first["$case/$i"] = 'deleted by AV' }
                Remove-Item -ErrorAction SilentlyContinue $dst
            }
        }
    } finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ctl; Get-ChildItem $S6.WA -Filter 'wmuxspikefwdnew*' | Remove-Item -Force }
    foreach ($k in ($lists.Keys | Sort-Object)) { $first[$k] = Stat $lists[$k].ToArray() }
    $res.first_launch_ms = $first
    $res.cpu_load_end = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
}
finally {
    foreach ($f in Get-SpikeWindowsAppsFiles) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    if (Test-Path $S6.RegKey) { Remove-Item -Path $S6.RegKey -Recurse -Force }
    $res.cleanup_remaining = @(Get-SpikeWindowsAppsFiles).Count
    $res.finished = (Get-Date).ToString('o')
    Save-Result "timing-$((Get-Date).ToString('HHmm'))" $res | Out-Null
    $res | ConvertTo-Json -Depth 6
}
