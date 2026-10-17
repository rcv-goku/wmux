# wp: W0-B2
# budget-sec: 1500
# Isolation self-test (spike S2, plan note 7). Checks the harness guarantees that protect the
# user: the visibility guard ("visible test window") and the process-tree focus sampler
# ("focus stolen by test instance") on fixtures that never take focus, process-tree tracking
# with exited children, orphan and root cleanup after Stop-WmuxInstance (Win32_Process query,
# root gone within 60 s), the stale-root sweep of run.ps1, and finally that a nested
# "run.ps1 -Suite smoke,legacy -Parallel 4" leaves every file under %LOCALAPPDATA%\ghostty and
# %LOCALAPPDATA%\wmux unchanged (inconclusive when a non-test wmux.exe ran meanwhile; CI is
# authoritative). It claims no matrix feature ids.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:E2eRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:ModulePath = Join-Path $script:E2eRoot 'WmuxTest.psm1'
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('wmux-e2e-isolation-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $script:TempRoot
$script:Stopped = $null

function Invoke-ChildPwsh {
    param([string[]]$Arguments, [hashtable]$Env = @{}, [int]$TimeoutSec = 110)
    $psi = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass') + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in @('WMUX_E2E_RESULTS', 'WMUX_E2E_ARTIFACTS', 'WMUX_E2E_FILE', 'WMUX_E2E_ATTEMPT', 'WMUX_E2E_FILTER', 'WMUX_E2E_RUNNER')) { $null = $psi.Environment.Remove($k) }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            throw "child pwsh did not exit within ${TimeoutSec}s: $($Arguments -join ' ')"
        }
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
    } finally { $p.Dispose() }
}

function Invoke-ChildTestFile {
    # Runs a generated test file in its own pwsh; returns its Test-Case result records by name.
    param([string]$Name, [string]$Content, [hashtable]$Env = @{})
    $file = Join-Path $script:TempRoot "$Name.e2e.ps1"
    [IO.File]::WriteAllText($file, $Content.Replace('__MODULE__', $script:ModulePath), $script:Utf8)
    $results = Join-Path $script:TempRoot "$Name.results.jsonl"
    $environment = @{ WMUX_E2E_RESULTS = $results; WMUX_E2E_ARTIFACTS = (Join-Path $script:TempRoot "$Name.artifacts"); WMUX_E2E_FILE = "isolation/$Name.e2e.ps1" }
    foreach ($k in $Env.Keys) { $environment[$k] = $Env[$k] }
    $r = Invoke-ChildPwsh -Arguments @('-File', $file) -Env $environment
    $byName = @{}
    if (Test-Path -LiteralPath $results) {
        foreach ($line in [IO.File]::ReadAllLines($results)) { if ($line.Trim()) { $rec = $line | ConvertFrom-Json; $byName[$rec.name] = $rec } }
    }
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Stdout = $r.Stdout; Stderr = $r.Stderr; Results = $byName }
}

function Get-StateHashes {
    # Path -> "sha256" (or "locked:<length>:<mtime>") for every file under the user's legacy and
    # new state roots.
    param([string]$LocalAppData)
    $map = [ordered]@{}
    foreach ($dirName in 'ghostty', 'wmux') {
        $dir = Join-Path $LocalAppData $dirName
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $map["$dirName\"] = '<absent>'; continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($LocalAppData.Length).TrimStart('\')
            try {
                $fs = [IO.FileStream]::new($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
                try { $map[$rel] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fs)) } finally { $fs.Dispose() }
            } catch {
                $map[$rel] = "locked:$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
            }
        }
    }
    return $map
}

function Get-NonTestWmux {
    # wmux.exe / ghostty.exe processes that are not harness instances (an instance always runs
    # with --config-file=<...\wmux-e2e\<id>\ghostty.conf>).
    @(Get-CimInstance Win32_Process -Filter "Name='wmux.exe' or Name='ghostty.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and -not ([string]$_.CommandLine -match '--config-file=[^"]*\\wmux-e2e\\[0-9a-f]{8}\\ghostty\.conf') -and -not ([string]$_.CommandLine -match '(^|\s)"?\+') } |
        ForEach-Object { "$($_.Name) pid $($_.ProcessId)" })
}

# ---------------------------------------------------------------------------

Test-Case 'isolation: the visibility guard fails a visible test window and accepts hidden placements' {
    $content = @'
Import-Module '__MODULE__' -Force
function Start-Probe([string]$Placement) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Import-Module '__MODULE__'; exit [WmuxTestHarness.Fixtures]::ShowProbeWindow('$Placement', 20000)") { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}
Test-Case 'fixture window made visible on purpose' {
    $p = Start-Probe 'onscreen'
    [WmuxTestHarness.FocusSampler]::WatchTree($p.Id, $true, $true)
    try {
        $null = Wait-WmuxCondition -TimeoutSec 30 { [WmuxTestHarness.FocusSampler]::VisibleCount -gt 0 }
        $null = Wait-WmuxCondition -TimeoutSec 10 { $p.HasExited }
        Write-Host "GUARD killed=$($p.HasExited) placement=$([WmuxTestHarness.FocusSampler]::PlacementOf($p.Id))"
    } finally { [WmuxTestHarness.FocusSampler]::Unwatch($p.Id); try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
}
foreach ($placement in 'cloaked', 'offscreen') {
    $script:Placement = $placement
    Test-Case "fixture window $placement" {
        $before = [WmuxTestHarness.FocusSampler]::VisibleCount
        $p = Start-Probe $script:Placement
        [WmuxTestHarness.FocusSampler]::WatchTree($p.Id, $true, $true)
        try {
            $null = Wait-WmuxCondition -TimeoutSec 30 { [WmuxTestHarness.FocusSampler]::PlacementOf($p.Id) -ne 'none' -or $p.HasExited }
            Write-Host "PLACEMENT $($script:Placement)=$([WmuxTestHarness.FocusSampler]::PlacementOf($p.Id)) exit=$(if ($p.HasExited) { $p.ExitCode } else { 'running' })"
            Assert-Equal $before ([WmuxTestHarness.FocusSampler]::VisibleCount) 'no visible-window violation'
        } finally { [WmuxTestHarness.FocusSampler]::Unwatch($p.Id); try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    }
}
'@
    $r = Invoke-ChildTestFile -Name 'visible-guard' -Content $content
    Assert-Equal 0 $r.ExitCode "child stderr: $($r.Stderr)"
    $v = $r.Results['fixture window made visible on purpose']
    Assert-True ($null -ne $v) "the fixture test reported a result; stdout: $($r.Stdout)"
    Assert-Equal 'failed' $v.status
    Assert-Equal 'visible' $v.kind
    Assert-Match '^visible test window: ' $v.message
    Assert-Match 'class=Static title="wmux-e2e-probe-onscreen"' $v.message
    Assert-Match 'GUARD killed=True placement=onscreen' $r.Stdout 'the guard killed the violating tree'
    foreach ($placement in 'cloaked', 'offscreen') {
        $rec = $r.Results["fixture window $placement"]
        Assert-True ($null -ne $rec) "the $placement fixture reported a result"
        Assert-Equal 'passed' $rec.status "a $placement window is accepted: $($rec.message)"
        Assert-Match "PLACEMENT $placement=$placement " $r.Stdout "the guard reports the $placement placement"
    }
}

Test-Case 'isolation: a child process of a watched tree taking the foreground fails the test' {
    $content = @'
Import-Module '__MODULE__' -Force
Test-Case 'child of the watched tree owns the foreground' {
    # Never takes focus: cmd.exe stands in for the instance root and starts a child pwsh that
    # shows the off-screen, no-activate probe window. The sampler must discover the child and
    # judge its window as the foreground (SampleWindow is SampleOnce with an injected window).
    $inner = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Import-Module '__MODULE__'; exit [WmuxTestHarness.Fixtures]::ShowProbeWindow('offscreen', 30000)"))
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\cmd.exe'))
    foreach ($a in '/d', '/c', [Environment]::ProcessPath, '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $inner) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $root = [System.Diagnostics.Process]::Start($psi)
    [WmuxTestHarness.FocusSampler]::WatchTree($root.Id, $false, $true)
    try {
        $hit = Wait-WmuxCondition -TimeoutSec 30 {
            foreach ($m in [WmuxTestHarness.FocusSampler]::TreeOf($root.Id)) {
                if ($m.Pid -eq $root.Id) { continue }
                foreach ($h in [WmuxTestHarness.Native]::TopLevelWindows($m.Pid, 'Static')) {
                    if ([WmuxTestHarness.Native]::Title($h) -eq 'wmux-e2e-probe-offscreen') { return [pscustomobject]@{ Hwnd = $h; Pid = $m.Pid; Name = $m.Name } }
                }
            }
        }
        Write-Host "TREE root=$($root.Id) child=$($hit.Pid) ($($hit.Name))"
        $null = [WmuxTestHarness.FocusSampler]::SampleWindow($hit.Hwnd)
        $null = Wait-WmuxCondition -TimeoutSec 10 { $root.HasExited }
        Write-Host "KILLED root=$($root.HasExited)"
    } finally {
        $null = [WmuxTestHarness.FocusSampler]::KillTree($root.Id)
        [WmuxTestHarness.FocusSampler]::Unwatch($root.Id)
    }
}
'@
    $r = Invoke-ChildTestFile -Name 'focus-child' -Content $content
    Assert-Equal 0 $r.ExitCode "child stderr: $($r.Stderr)"
    $rec = $r.Results['child of the watched tree owns the foreground']
    Assert-True ($null -ne $rec) "the fixture test reported a result; stdout: $($r.Stdout)"
    Assert-Match 'TREE root=(\d+) child=(\d+) \(pwsh\.exe\)' $r.Stdout 'the probe window belongs to a discovered child of the root'
    Assert-Match 'KILLED root=True' $r.Stdout 'the violating tree was killed'
    Assert-Equal 'failed' $rec.status
    Assert-Equal 'focus' $rec.kind
    Assert-Match '^focus stolen by test instance: .*\(tree of \d+\) proc=pwsh\.exe .*title="wmux-e2e-probe-offscreen"' $rec.message
}

Test-Case 'isolation: the tree keeps exited children; after Stop-WmuxInstance no process of the run is alive' {
    $w = Start-WmuxInstance
    try {
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^WMUX>' -TimeoutSec 30
        $null = Invoke-WmuxRawLine $w '{"id":11,"cmd":"send","args":{"text":"ping -n 2 127.0.0.1 >nul & echo TREE-DONE","enter":true}}'
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^TREE-DONE\s*$' -TimeoutSec 30
        $opened = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $w '{"id":12,"cmd":"open","args":{"url":"about:blank","target":"tab"}}'))
        Assert-True $opened.ok "open: $($opened.error)"
        $null = Wait-WmuxCondition -TimeoutSec 30 {
            $r = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $w '{"id":13,"cmd":"eval","args":{"js":"1"}}'))
            $r.ok
        }
        [WmuxTestHarness.FocusSampler]::RefreshTrees()
        $tree = @([WmuxTestHarness.FocusSampler]::TreeOf($w.Pid))
        $names = @($tree | ForEach-Object { $_.Name.ToLowerInvariant() })
        Write-Host "tree: $(($tree | ForEach-Object { $_.ToString() }) -join ', ')"
        foreach ($n in 'wmux.exe', 'conhost.exe', 'cmd.exe', 'ping.exe', 'msedgewebview2.exe') { Assert-True ($names -contains $n) "the tree includes $n" }
        $ping = @($tree | Where-Object { $_.Name -ieq 'PING.EXE' })
        Assert-Equal 0 @([WmuxTestHarness.FocusSampler]::AliveMembers($ping)).Count 'the exited ping.exe is kept as a member'
        Stop-WmuxInstance $w
        Assert-True $w.Stopped
        Write-Host "hidden_mode=$($w.HiddenMode) survivors=$($w.Survivors -join ',')"
        $alive = foreach ($m in $tree) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($m.Pid)" -ErrorAction SilentlyContinue
            if ($null -eq $p) { continue }
            if ($m.CreationTime -ne 0 -and $p.CreationDate -and [Math]::Abs($p.CreationDate.ToFileTimeUtc() - $m.CreationTime) -gt 20000000) { continue }
            "$($p.Name) pid $($p.ProcessId)"
        }
        Assert-Equal 0 @($alive).Count "processes of the run still listed by Win32_Process after Stop-WmuxInstance: $(@($alive) -join ', ')"
        $script:Stopped = [pscustomobject]@{ Root = $w.Root }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'isolation: the instance root is gone within 60 s of the stop' {
    if ($null -eq $script:Stopped) { throw [WmuxSkipException]::new('the previous Test-Case did not stop an instance') }
    $root = $script:Stopped.Root
    $null = Wait-WmuxCondition -TimeoutSec 60 -IntervalMs 250 { -not (Test-Path -LiteralPath $root) }
}

Test-Case 'isolation: run.ps1 sweeps roots of dead runs and keeps live ones' {
    $tempBase = Join-Path $script:TempRoot 'sweep-temp'
    $base = Join-Path $tempBase 'wmux-e2e'
    $null = New-Item -ItemType Directory -Force -Path $base
    $exited = [System.Diagnostics.Process]::Start([System.Diagnostics.ProcessStartInfo]@{ FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe'); Arguments = '/c exit 0'; UseShellExecute = $false; CreateNoWindow = $true })
    $exited.WaitForExit()
    $deadStart = $exited.StartTime.ToUniversalTime().ToString('o')
    $deadPid = $exited.Id
    $exited.Dispose()
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $roots = [ordered]@{
        dead  = @{ Name = 'aaaa0001'; Owner = @{ harness_pid = $deadPid; harness_started = $deadStart; created_at = [DateTime]::UtcNow.ToString('o') } }
        live  = @{ Name = 'aaaa0002'; Owner = @{ harness_pid = $me.Id; harness_started = $me.StartTime.ToUniversalTime().ToString('o'); created_at = [DateTime]::UtcNow.ToString('o') } }
        fresh = @{ Name = 'aaaa0003'; Owner = $null }
        old   = @{ Name = 'aaaa0004'; Owner = $null; Old = $true }
        other = @{ Name = 'typecache'; Owner = $null; Old = $true }
    }
    foreach ($r in $roots.Values) {
        $dir = Join-Path $base $r.Name
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'state')
        [IO.File]::WriteAllText((Join-Path $dir 'state\x.txt'), 'x', $script:Utf8)
        if ($r.Owner) { [IO.File]::WriteAllText((Join-Path $dir 'owner.json'), (ConvertTo-Json $r.Owner), $script:Utf8) }
        if ($r.Old) { (Get-Item -LiteralPath $dir).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2) }
    }
    $suites = Join-Path $script:TempRoot 'sweep-suites'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $suites 'a')
    [IO.File]::WriteAllText((Join-Path $suites 'a\pass.e2e.ps1'), "Import-Module '$($script:ModulePath)' -Force`nTest-Case 'passes' { Assert-True `$true }`n", $script:Utf8)
    $out = Invoke-ChildPwsh -Arguments @('-File', (Join-Path $script:E2eRoot 'run.ps1'), '-SuitesRoot', $suites, '-ResultsDir', (Join-Path $script:TempRoot 'sweep-results'), '-NoRetry') -Env @{ RUNNER_TEMP = $tempBase }
    Assert-Equal 0 $out.ExitCode "run.ps1 output: $($out.Stdout) $($out.Stderr)"
    Assert-Match 'swept 2 stale instance root' $out.Stdout
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $base 'aaaa0001'))) 'the root of a dead harness is swept'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $base 'aaaa0004'))) 'an ownerless root older than 24 h is swept'
    Assert-True (Test-Path -LiteralPath (Join-Path $base 'aaaa0002')) 'the root of a live harness is kept'
    Assert-True (Test-Path -LiteralPath (Join-Path $base 'aaaa0003')) 'a fresh ownerless root is kept'
    Assert-True (Test-Path -LiteralPath (Join-Path $base 'typecache')) 'non-root directories are never touched'
}

Test-Case 'isolation: smoke and legacy suites leave %LOCALAPPDATA%\ghostty and %LOCALAPPDATA%\wmux unchanged' {
    # A nested run takes minutes: this Test-Case gets its own watchdog budget.
    [WmuxTestHarness.Watchdog]::Arm(1200 * 1000)
    $lad = [Environment]::GetFolderPath('LocalApplicationData')
    if ($env:LOCALAPPDATA -and $env:LOCALAPPDATA -ne $lad) { $lad = $env:LOCALAPPDATA }
    $nonTest = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($x in Get-NonTestWmux) { $null = $nonTest.Add($x) }
    $before = Get-StateHashes $lad
    $results = Join-Path $script:TempRoot 'nested-results'
    $psi = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:E2eRoot 'run.ps1'), '-Suite', 'smoke,legacy', '-Parallel', '4', '-ResultsDir', $results)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in @('WMUX_E2E_RESULTS', 'WMUX_E2E_ARTIFACTS', 'WMUX_E2E_FILE', 'WMUX_E2E_ATTEMPT', 'WMUX_E2E_FILTER', 'WMUX_E2E_RUNNER')) { $null = $psi.Environment.Remove($k) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    # Poll for non-test wmux processes while the nested run works (they would make a change
    # in the user's state unattributable).
    while (-not $p.WaitForExit(1000)) { foreach ($x in Get-NonTestWmux) { $null = $nonTest.Add($x) } }
    $p.WaitForExit()
    $nestedExit = $p.ExitCode
    $p.Dispose()
    foreach ($x in Get-NonTestWmux) { $null = $nonTest.Add($x) }
    $after = Get-StateHashes $lad
    $tail = (($out.Result -split "`r?`n") | Where-Object { $_ -match '^(e2e:|  (FAIL|FLAKY|SKIP))' } | Select-Object -First 12) -join "`n"
    Write-Host "nested run exit $nestedExit`n$tail"
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $before.Keys) {
        if (-not $after.Contains($k)) { $changed.Add("deleted $k") } elseif ($before[$k] -ne $after[$k]) { $changed.Add("modified $k") }
    }
    foreach ($k in $after.Keys) { if (-not $before.Contains($k)) { $changed.Add("created $k") } }
    Write-Host "hashed $($before.Count) entries before, $($after.Count) after; changes: $($changed.Count); non-test wmux: $(@($nonTest) -join ', ')"
    Assert-True ($nestedExit -in 0, 1) "the nested run.ps1 ran (exit $nestedExit): $($err.Result)"
    if ($changed.Count -eq 0) { return }
    $list = ($changed | Select-Object -First 15) -join '; '
    if ($nonTest.Count -gt 0) {
        throw [WmuxSkipException]::new("inconclusive: a non-test wmux ran during the nested run ($(@($nonTest) -join ', ')); changed under %LOCALAPPDATA%: $list")
    }
    Assert-True $false "the e2e run changed the user's state under %LOCALAPPDATA%: $list"
}

Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
