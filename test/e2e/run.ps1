#Requires -Version 7.0
<#
.SYNOPSIS
    wmux end-to-end test runner (ARCHITECTURE.md Appendix D.5).

.DESCRIPTION
    Discovers test/e2e/suites/**/*.e2e.ps1 (suites/_quarantine only with -Quarantine), runs each
    file in its own pwsh process (at most -Parallel at once), retries a failed file once and marks
    it flaky when the retry passes, aggregates the Test-Case results into test-results/e2e.json and
    test-results/e2e.junit.xml, and keeps per-attempt logs, raw results and failure artifacts
    (screenshots, events.jsonl, logs, toast sink, dialogs) under test-results/.

    Per-test timeout: every Test-Case has a watchdog of -TestTimeoutSec (default 120 s) inside the
    test process, and the runner kills a file whose process outlives
    TestTimeoutSec * <number of Test-Case blocks> plus a grace period (status "timeout"); a
    "# budget-sec: <n>" header line raises that budget for a file.

    Before running, stale instance roots under %RUNNER_TEMP% or %TEMP%\wmux-e2e are swept: roots
    whose owner.json names a harness process that no longer runs, and roots without owner.json
    older than 24 h. Roots of live runs (any worktree) are kept.

    Exit codes:
        0  every file passed or was skipped (flaky files allowed)
        1  at least one file failed, errored or timed out
        2  usage error, or no test file matched
        3  build or environment failure (-Build failed, zig missing)

.PARAMETER Suite
    Glob(s) matched against the area directory (smoke, core, _selftest, ...), the file base name
    (W2-1) or the suite-relative path without .e2e.ps1 (core/W2-1). Default: all suites.
.PARAMETER Filter
    Run only the Test-Cases whose name or file path matches: a substring, or a -like pattern
    when it contains * or ?.
.PARAMETER Parallel
    Number of test files that run at the same time (default 4).
.PARAMETER Build
    Build wmux first (Debug: zig-out\bin\wmux.exe; Release: ReleaseFast into zig-out\release) and
    test that binary. zig comes from $env:ZIG or PATH.
.PARAMETER Quarantine
    Also run suites/_quarantine.
.PARAMETER NoRetry
    Do not retry failed files.
.PARAMETER Exe
    wmux.exe to test (exported to the test processes as WMUX_E2E_EXE).
.PARAMETER SuitesRoot
    Alternative suites directory (used by the harness self-test).
.PARAMETER ResultsDir
    Alternative output directory (default <repo>\test-results).
.PARAMETER TestTimeoutSec
    Per-Test-Case timeout in seconds (default 120).
.PARAMETER List
    Print the files that would run and exit.

.EXAMPLE
    pwsh test/e2e/run.ps1 -Suite smoke
.EXAMPLE
    pwsh test/e2e/run.ps1 -Suite core,cli -Filter workspace -Parallel 2 -Build Debug
#>
[CmdletBinding()]
param(
    [string[]]$Suite,
    [string]$Filter,
    [ValidateRange(1, 64)][int]$Parallel = 4,
    [ValidateSet('Debug', 'Release')][string]$Build,
    [switch]$Quarantine,
    [switch]$NoRetry,
    [string]$Exe,
    [string]$SuitesRoot,
    [string]$ResultsDir,
    [ValidateRange(1, 3600)][int]$TestTimeoutSec = 120,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$runClock = [Diagnostics.Stopwatch]::StartNew()
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $SuitesRoot) { $SuitesRoot = Join-Path $PSScriptRoot 'suites' }
$SuitesRoot = [IO.Path]::GetFullPath($SuitesRoot, (Get-Location).ProviderPath)
if (-not $ResultsDir) { $ResultsDir = Join-Path $repoRoot 'test-results' }
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
# "pwsh -File run.ps1 -Suite core,cli" passes one string; accept comma-separated globs.
if ($Suite) { $Suite = @($Suite | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

function Stop-Run {
    param([int]$Code, [string]$Message)
    if ($Message) { Write-Host "run.ps1: $Message" -ForegroundColor Red }
    exit $Code
}

function Get-FileSlug {
    param([string]$RelativePathNoExt)
    return (($RelativePathNoExt -replace '/', '__') -replace '[^A-Za-z0-9._-]', '_')
}

function ConvertTo-RepoPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $rel = [IO.Path]::GetRelativePath($repoRoot, $Path)
    if ($rel.StartsWith('..')) { return ($Path -replace '\\', '/') }
    return ($rel -replace '\\', '/')
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SuitesRoot -PathType Container)) { Stop-Run 2 "suites root not found: $SuitesRoot" }

$jobs = foreach ($f in (Get-ChildItem -LiteralPath $SuitesRoot -Recurse -File -Filter '*.e2e.ps1' | Sort-Object FullName)) {
    $rel = ([IO.Path]::GetRelativePath($SuitesRoot, $f.FullName)) -replace '\\', '/'
    $segments = $rel.Split('/')
    $area = if ($segments.Count -gt 1) { $segments[0] } else { '(root)' }
    if ($area -eq '_quarantine' -and -not $Quarantine) { continue }
    $relNoExt = $rel.Substring(0, $rel.Length - '.e2e.ps1'.Length)
    $base = Split-Path -Leaf $relNoExt
    if ($Suite) {
        $hit = $false
        foreach ($pattern in $Suite) {
            if ($area -like $pattern -or $relNoExt -like $pattern -or $base -like $pattern) { $hit = $true; break }
        }
        if (-not $hit) { continue }
    }
    [pscustomobject]@{
        Path        = $f.FullName
        Rel         = $rel
        Area        = $area
        Base        = $base
        Slug        = Get-FileSlug $relNoExt
        TestCount   = @(Select-String -LiteralPath $f.FullName -Pattern '^\s*Test-Case\b').Count
        # "# budget-sec: <n>" in the header raises the file's time budget (files whose Test-Cases
        # are generated in loops or that run nested runs).
        BudgetSec   = [int](@(Select-String -LiteralPath $f.FullName -Pattern '^#\s*budget-sec:\s*(\d+)\s*$' | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value }) + @('0'))[0]
        Quarantined = ($area -eq '_quarantine')
    }
}
$jobs = @($jobs)
if ($jobs.Count -eq 0) {
    $what = if ($Suite) { "-Suite $($Suite -join ',')" } else { 'any suite' }
    Stop-Run 2 "no test file matched $what under $SuitesRoot"
}

$tagsByRel = @{}
try {
    $tags = & (Join-Path $PSScriptRoot 'coverage.ps1') -SuitesRoot $SuitesRoot -TagsOnly -PassThru -Quiet
    foreach ($t in @($tags)) { $tagsByRel[$t.RelativePath] = $t }
} catch {
    Write-Warning "run.ps1: could not read suite headers: $($_.Exception.Message)"
}

if ($List) {
    foreach ($j in $jobs) {
        $t = $tagsByRel[$j.Rel]
        Write-Host ('{0,-56} area={1,-12} tests={2,-3} wp={3} covers={4}' -f $j.Rel, $j.Area, $j.TestCount, $(if ($t) { $t.Wp }), $(if ($t) { $t.Covers.Count } else { 0 }))
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Output directory and optional build
# ---------------------------------------------------------------------------

# The stale outputs below are deleted recursively: only ever in the default directory or in one
# that a previous run marked, never in an unrelated folder passed as -ResultsDir.
$resultsMarker = Join-Path $ResultsDir '.wmux-e2e-results'
$defaultResultsDir = Join-Path $repoRoot 'test-results'
if ($ResultsDir -ne $defaultResultsDir -and (Test-Path -LiteralPath $ResultsDir) -and -not (Test-Path -LiteralPath $resultsMarker) -and
    @(Get-ChildItem -LiteralPath $ResultsDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
    Stop-Run 2 "-ResultsDir $ResultsDir is not empty and was not created by run.ps1 (no .wmux-e2e-results marker); pass an empty or new directory"
}
$null = New-Item -ItemType Directory -Force -Path $ResultsDir
[IO.File]::WriteAllText($resultsMarker, "Output directory of test/e2e/run.ps1; each run replaces e2e.json, e2e.junit.xml, raw, logs and artifacts here.`n", [Text.UTF8Encoding]::new($false))
foreach ($stale in @('e2e.json', 'e2e.junit.xml', 'raw', 'logs', 'artifacts')) {
    $p = Join-Path $ResultsDir $stale
    if (Test-Path -LiteralPath $p) {
        try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop } catch { Write-Warning "run.ps1: could not clear $p ($($_.Exception.Message))" }
    }
}
foreach ($d in @('raw', 'logs', 'artifacts')) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $ResultsDir $d) }

if ($Build) {
    $zig = if ($env:ZIG) { $env:ZIG } else { (Get-Command zig -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $zig) { Stop-Run 3 '-Build needs zig: set $env:ZIG to zig.exe or put zig on PATH' }
    $zigArgs = @('build', '-Dapp-runtime=win32', '-Dtarget=x86_64-windows-gnu')
    if ($Build -eq 'Release') { $zigArgs += @('-Doptimize=ReleaseFast', '--prefix', (Join-Path $repoRoot 'zig-out\release')) }
    $buildLog = Join-Path $ResultsDir 'logs\build.log'
    Write-Host "run.ps1: building ($Build): $zig $($zigArgs -join ' ')" -ForegroundColor Cyan
    Push-Location $repoRoot
    try {
        & $zig @zigArgs *> $buildLog
        $buildCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($buildCode -ne 0) {
        Write-Host (Get-Content -LiteralPath $buildLog -Tail 40 | Out-String)
        Stop-Run 3 "zig build failed with exit code $buildCode (log: $buildLog)"
    }
    $Exe = if ($Build -eq 'Release') { Join-Path $repoRoot 'zig-out\release\bin\wmux.exe' } else { Join-Path $repoRoot 'zig-out\bin\wmux.exe' }
}
if ($Exe) {
    $Exe = [IO.Path]::GetFullPath($Exe, (Get-Location).ProviderPath)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { Stop-Run 3 "wmux.exe not found: $Exe" }
}

# ---------------------------------------------------------------------------
# Stale instance roots (spike S2): a root whose owning harness process is gone (killed run,
# crashed test, a WebView2 lock that outlived the background deleter) is deleted. Roots of
# live runs, including other worktrees' concurrent runs, are never touched; roots without an
# owner.json (older harness) only after 24 h.
# ---------------------------------------------------------------------------

function Invoke-StaleRootSweep {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $dir = Join-Path ([IO.Path]::GetFullPath($base)) 'wmux-e2e'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $swept = 0
    $kept = 0
    foreach ($root in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-f]{8}$' })) {
        $stale = $false
        $ownerFile = Join-Path $root.FullName 'owner.json'
        if (Test-Path -LiteralPath $ownerFile -PathType Leaf) {
            try {
                $owner = Get-Content -LiteralPath $ownerFile -Raw | ConvertFrom-Json
                $alive = $false
                $p = Get-Process -Id ([int]$owner.harness_pid) -ErrorAction SilentlyContinue
                if ($p) {
                    # ConvertFrom-Json may already have turned the ISO-8601 text into a DateTime.
                    $h = $owner.harness_started
                    $started = if ($h -is [DateTime]) { $h.ToUniversalTime() } else { [DateTime]::Parse([string]$h, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
                    try { $alive = [Math]::Abs(($p.StartTime.ToUniversalTime() - $started).TotalSeconds) -lt 2 } catch { $alive = $true }
                }
                $stale = -not $alive
            } catch {
                $stale = ($root.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddHours(-24))
            }
        } else {
            $stale = ($root.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddHours(-24))
        }
        if (-not $stale) { $kept++; continue }
        try {
            Remove-Item -LiteralPath $root.FullName -Recurse -Force -ErrorAction Stop
            $swept++
        } catch { }
    }
    if ($swept -gt 0) { Write-Host "run.ps1: swept $swept stale instance root(s) under $dir ($kept live kept)" -ForegroundColor DarkGray }
}

Invoke-StaleRootSweep

# ---------------------------------------------------------------------------
# Run (one pwsh per file, retry once)
# ---------------------------------------------------------------------------

$cfg = [pscustomobject]@{
    Pwsh           = [Environment]::ProcessPath
    RepoRoot       = $repoRoot
    ResultsDir     = $ResultsDir
    Filter         = $Filter
    Exe            = $Exe
    TestTimeoutSec = $TestTimeoutSec
    NoRetry        = [bool]$NoRetry
}

$runFileText = @'
param($Job, $Cfg)
$ErrorActionPreference = 'Stop'
$hasDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')

function Invoke-Attempt {
    param([int]$Attempt)
    $raw = Join-Path $Cfg.ResultsDir "raw\$($Job.Slug).attempt$Attempt.jsonl"
    $outLog = Join-Path $Cfg.ResultsDir "logs\$($Job.Slug).attempt$Attempt.out.log"
    $errLog = Join-Path $Cfg.ResultsDir "logs\$($Job.Slug).attempt$Attempt.err.log"
    $artifacts = Join-Path $Cfg.ResultsDir "artifacts\$($Job.Slug)\attempt$Attempt"
    Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue

    $psi = [System.Diagnostics.ProcessStartInfo]::new($Cfg.Pwsh)
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Job.Path)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Cfg.RepoRoot
    $psi.Environment['WMUX_E2E_RUNNER'] = '1'
    $psi.Environment['WMUX_E2E_RESULTS'] = $raw
    $psi.Environment['WMUX_E2E_ARTIFACTS'] = $artifacts
    $psi.Environment['WMUX_E2E_FILE'] = $Job.Rel
    $psi.Environment['WMUX_E2E_ATTEMPT'] = [string]$Attempt
    $psi.Environment['WMUX_E2E_TEST_TIMEOUT_SEC'] = [string]$Cfg.TestTimeoutSec
    if ($Cfg.Filter) { $psi.Environment['WMUX_E2E_FILTER'] = $Cfg.Filter } else { $null = $psi.Environment.Remove('WMUX_E2E_FILTER') }
    if ($Cfg.Exe) { $psi.Environment['WMUX_E2E_EXE'] = $Cfg.Exe }

    $grace = [Math]::Min(60, [Math]::Max(5, [int]($Cfg.TestTimeoutSec / 2)))
    $budgetSec = [Math]::Max($Cfg.TestTimeoutSec * [Math]::Max(1, $Job.TestCount) + $grace, $Job.BudgetSec)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    try { $proc.StandardInput.Close() } catch { }
    $outFile = [IO.File]::Create($outLog)
    $errFile = [IO.File]::Create($errLog)
    $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($outFile)
    $copyErr = $proc.StandardError.BaseStream.CopyToAsync($errFile)
    $timedOut = -not $proc.WaitForExit([int][Math]::Min([int]::MaxValue, $budgetSec * 1000))
    if ($timedOut) {
        try { $proc.Kill($true) } catch { }
        $null = $proc.WaitForExit(10000)
    }
    try { $null = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($copyOut, $copyErr), 5000) } catch { }
    $outFile.Dispose()
    $errFile.Dispose()
    $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
    $proc.Dispose()
    $clock.Stop()

    $tests = @()
    if (Test-Path -LiteralPath $raw -PathType Leaf) {
        $tests = @(foreach ($line in [IO.File]::ReadAllLines($raw)) {
                if (-not $line.Trim()) { continue }
                try {
                    if ($hasDateKind) { ConvertFrom-Json -InputObject $line -DateKind String } else { ConvertFrom-Json -InputObject $line }
                } catch { }
            })
    }
    $failed = @($tests | Where-Object { $_.status -eq 'failed' })
    $notSkipped = @($tests | Where-Object { $_.status -ne 'skipped' })
    if ($timedOut) { $status = 'timeout' }
    elseif ($failed.Count -gt 0) { $status = 'failed' }
    elseif ($exitCode -ne 0) { $status = 'error' }
    elseif ($tests.Count -eq 0) { $status = if ($Cfg.Filter) { 'filtered' } else { 'error' } }
    elseif ($notSkipped.Count -eq 0) { $status = 'skipped' }
    else { $status = 'passed' }

    $message = $null
    if ($status -eq 'timeout') { $message = "file exceeded its time budget of ${budgetSec}s and was killed" }
    elseif ($status -eq 'error') { $message = if ($exitCode -ne 0) { "pwsh exited with code $exitCode" } else { 'no Test-Case results were reported' } }
    if ($status -in @('timeout', 'error')) {
        $tail = @(Get-Content -LiteralPath $errLog -Tail 15 -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath $outLog -Tail 15 -ErrorAction SilentlyContinue)
        $tail = @($tail | Where-Object { $_ -and $_.Trim() })
        if ($tail.Count -gt 0) { $message += "`n" + ($tail -join "`n") }
    }
    [pscustomobject]@{
        attempt     = $Attempt
        status      = $status
        exit_code   = $exitCode
        timed_out   = $timedOut
        budget_sec  = $budgetSec
        duration_ms = [long]$clock.ElapsedMilliseconds
        message     = $message
        tests       = $tests
        raw         = $raw
        log_out     = $outLog
        log_err     = $errLog
        artifacts   = $(if (Test-Path -LiteralPath $artifacts) { $artifacts } else { $null })
    }
}

$attempts = [System.Collections.Generic.List[object]]::new()
$first = Invoke-Attempt -Attempt 1
$attempts.Add($first)
$final = $first
if ($first.status -in @('failed', 'error', 'timeout') -and -not $Cfg.NoRetry) {
    $final = Invoke-Attempt -Attempt 2
    $attempts.Add($final)
}
$status = $final.status
if ($attempts.Count -eq 2 -and $final.status -eq 'passed') { $status = 'flaky' }

$color = switch ($status) { 'passed' { 'Green' } 'flaky' { 'Yellow' } 'skipped' { 'Yellow' } 'filtered' { 'DarkGray' } default { 'Red' } }
$counts = '{0} tests' -f @($final.tests).Count
Write-Host ('{0,-8} {1} ({2}, {3:n1}s{4})' -f $status.ToUpperInvariant(), $Job.Rel, $counts, (($attempts | Measure-Object -Property duration_ms -Sum).Sum / 1000.0), $(if ($attempts.Count -gt 1) { ', retried' } else { '' })) -ForegroundColor $color

[pscustomobject]@{
    Job      = $Job
    Status   = $status
    Attempts = $attempts.ToArray()
    Final    = $final
}
'@

Write-Host ("run.ps1: {0} file(s), parallel {1}, results in {2}" -f $jobs.Count, $Parallel, $ResultsDir) -ForegroundColor Cyan
$fileResults = @($jobs | ForEach-Object -ThrottleLimit $Parallel -Parallel {
        $runFile = [scriptblock]::Create($using:runFileText)
        & $runFile -Job $_ -Cfg $using:cfg
    })
$fileResults = @($fileResults | Sort-Object { $_.Job.Rel })

# ---------------------------------------------------------------------------
# Aggregate
# ---------------------------------------------------------------------------

$allTests = [System.Collections.Generic.List[object]]::new()
foreach ($fr in $fileResults) {
    $flaky = $fr.Status -eq 'flaky'
    foreach ($t in @($fr.Final.tests)) {
        $allTests.Add([pscustomobject]@{
                file        = $fr.Job.Rel
                area        = $fr.Job.Area
                name        = [string]$t.name
                status      = [string]$t.status
                kind        = $t.kind
                duration_ms = [long]$t.duration_ms
                message     = $t.message
                details     = $t.details
                artifacts   = ConvertTo-RepoPath $t.artifacts
                attempt     = $fr.Final.attempt
                flaky       = $flaky
            })
    }
    if ($fr.Status -in @('error', 'timeout') -and @($fr.Final.tests | Where-Object { $_.status -eq 'failed' }).Count -eq 0) {
        # The process died, hung or reported nothing: surface it as a failed pseudo-test.
        $allTests.Add([pscustomobject]@{
                file        = $fr.Job.Rel
                area        = $fr.Job.Area
                name        = '(file)'
                status      = 'failed'
                kind        = $fr.Status
                duration_ms = [long]$fr.Final.duration_ms
                message     = $fr.Final.message
                details     = $null
                artifacts   = ConvertTo-RepoPath $fr.Final.artifacts
                attempt     = $fr.Final.attempt
                flaky       = $false
            })
    }
}

$failedStatuses = @('failed', 'error', 'timeout')
$summary = [ordered]@{
    files           = $fileResults.Count
    tests           = $allTests.Count
    passed          = @($allTests | Where-Object status -EQ 'passed').Count
    failed          = @($allTests | Where-Object status -EQ 'failed').Count
    skipped         = @($allTests | Where-Object status -EQ 'skipped').Count
    passed_files    = @($fileResults | Where-Object Status -EQ 'passed').Count
    flaky_files     = @($fileResults | Where-Object Status -EQ 'flaky').Count
    failed_files    = @($fileResults | Where-Object Status -EQ 'failed').Count
    errored_files   = @($fileResults | Where-Object Status -EQ 'error').Count
    timed_out_files = @($fileResults | Where-Object Status -EQ 'timeout').Count
    skipped_files   = @($fileResults | Where-Object Status -EQ 'skipped').Count
    filtered_files  = @($fileResults | Where-Object Status -EQ 'filtered').Count
}
$exitCode = if (@($fileResults | Where-Object { $failedStatuses -contains $_.Status }).Count -gt 0) { 1 } else { 0 }
$runClock.Stop()

$report = [ordered]@{
    schema           = 'wmux-e2e-results/1'
    started_at       = $startedAt.ToString('o')
    finished_at      = [DateTime]::UtcNow.ToString('o')
    duration_ms      = [long]$runClock.ElapsedMilliseconds
    exit_code        = $exitCode
    suites_root      = ConvertTo-RepoPath $SuitesRoot
    results_dir      = ConvertTo-RepoPath $ResultsDir
    exe              = $(if ($Exe) { ConvertTo-RepoPath $Exe } elseif ($env:WMUX_E2E_EXE) { $env:WMUX_E2E_EXE } else { 'zig-out/bin/wmux.exe' })
    build            = $Build
    parallel         = $Parallel
    suite            = $Suite
    filter           = $Filter
    quarantine       = [bool]$Quarantine
    retry            = -not $NoRetry
    test_timeout_sec = $TestTimeoutSec
    summary          = $summary
    files            = @(foreach ($fr in $fileResults) {
            $t = $tagsByRel[$fr.Job.Rel]
            [ordered]@{
                path        = $fr.Job.Rel
                area        = $fr.Job.Area
                wp          = $(if ($t) { $t.Wp })
                covers      = $(if ($t) { @($t.Covers) } else { @() })
                manual      = $(if ($t) { @($t.Manual | ForEach-Object { [ordered]@{ id = $_.Id; reason = $_.Reason } }) } else { @() })
                quarantined = $fr.Job.Quarantined
                status      = $fr.Status
                attempts    = @(foreach ($a in $fr.Attempts) {
                        [ordered]@{
                            attempt     = $a.attempt
                            status      = $a.status
                            exit_code   = $a.exit_code
                            timed_out   = $a.timed_out
                            budget_sec  = $a.budget_sec
                            duration_ms = $a.duration_ms
                            message     = $a.message
                            log_out     = ConvertTo-RepoPath $a.log_out
                            log_err     = ConvertTo-RepoPath $a.log_err
                            raw         = ConvertTo-RepoPath $a.raw
                            artifacts   = ConvertTo-RepoPath $a.artifacts
                            tests       = @($a.tests | ForEach-Object { [ordered]@{ name = $_.name; status = $_.status; kind = $_.kind; duration_ms = $_.duration_ms; message = $_.message } })
                        }
                    })
            }
        })
    tests            = @($allTests)
}
$jsonPath = Join-Path $ResultsDir 'e2e.json'
[IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $report -Depth 12), [Text.UTF8Encoding]::new($false))

# JUnit XML ------------------------------------------------------------------

function ConvertTo-XmlSafe {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $sb = [Text.StringBuilder]::new($Text.Length)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ([System.Xml.XmlConvert]::IsXmlChar($c)) {
            $null = $sb.Append($c)
        } elseif ($i + 1 -lt $Text.Length -and [System.Xml.XmlConvert]::IsXmlSurrogatePair($Text[$i + 1], $c)) {
            $null = $sb.Append($c).Append($Text[$i + 1])
            $i++
        } else {
            $null = $sb.Append('?')
        }
    }
    return $sb.ToString()
}

$junitPath = Join-Path $ResultsDir 'e2e.junit.xml'
$xmlSettings = [System.Xml.XmlWriterSettings]::new()
$xmlSettings.Indent = $true
$xmlSettings.Encoding = [Text.UTF8Encoding]::new($false)
$xw = [System.Xml.XmlWriter]::Create($junitPath, $xmlSettings)
try {
    $xw.WriteStartDocument()
    $xw.WriteStartElement('testsuites')
    $xw.WriteAttributeString('name', 'wmux-e2e')
    $xw.WriteAttributeString('tests', [string]$summary.tests)
    $xw.WriteAttributeString('failures', [string]@($allTests | Where-Object { $_.status -eq 'failed' -and $_.kind -notin @('error', 'timeout') }).Count)
    $xw.WriteAttributeString('errors', [string]@($allTests | Where-Object { $_.status -eq 'failed' -and $_.kind -in @('error', 'timeout') }).Count)
    $xw.WriteAttributeString('skipped', [string]$summary.skipped)
    $xw.WriteAttributeString('time', ('{0:0.###}' -f ($runClock.ElapsedMilliseconds / 1000.0)))
    foreach ($fr in $fileResults) {
        if ($fr.Status -eq 'filtered') { continue }
        $tests = @($allTests | Where-Object { $_.file -eq $fr.Job.Rel })
        $xw.WriteStartElement('testsuite')
        $xw.WriteAttributeString('name', (ConvertTo-XmlSafe $fr.Job.Rel))
        $xw.WriteAttributeString('tests', [string]$tests.Count)
        $xw.WriteAttributeString('failures', [string]@($tests | Where-Object { $_.status -eq 'failed' -and $_.kind -notin @('error', 'timeout') }).Count)
        $xw.WriteAttributeString('errors', [string]@($tests | Where-Object { $_.status -eq 'failed' -and $_.kind -in @('error', 'timeout') }).Count)
        $xw.WriteAttributeString('skipped', [string]@($tests | Where-Object { $_.status -eq 'skipped' }).Count)
        $xw.WriteAttributeString('time', ('{0:0.###}' -f ((($fr.Attempts | Measure-Object -Property duration_ms -Sum).Sum) / 1000.0)))
        $xw.WriteStartElement('properties')
        foreach ($prop in @(@('area', $fr.Job.Area), @('status', $fr.Status), @('attempts', [string]$fr.Attempts.Count))) {
            $xw.WriteStartElement('property')
            $xw.WriteAttributeString('name', $prop[0])
            $xw.WriteAttributeString('value', (ConvertTo-XmlSafe $prop[1]))
            $xw.WriteEndElement()
        }
        $xw.WriteEndElement()
        foreach ($t in $tests) {
            $xw.WriteStartElement('testcase')
            $xw.WriteAttributeString('classname', (ConvertTo-XmlSafe ('e2e.{0}.{1}' -f $fr.Job.Area, $fr.Job.Base)))
            $xw.WriteAttributeString('name', (ConvertTo-XmlSafe $t.name))
            $xw.WriteAttributeString('time', ('{0:0.###}' -f ($t.duration_ms / 1000.0)))
            if ($t.status -eq 'failed') {
                $element = if ($t.kind -in @('error', 'timeout')) { 'error' } else { 'failure' }
                $xw.WriteStartElement($element)
                $msg = [string]$t.message
                $xw.WriteAttributeString('message', (ConvertTo-XmlSafe (($msg -split "`n")[0])))
                $xw.WriteAttributeString('type', (ConvertTo-XmlSafe $(if ($t.kind) { [string]$t.kind } else { 'failure' })))
                $body = $msg
                if ($t.details) { $body += "`n" + [string]$t.details }
                if ($t.artifacts) { $body += "`nartifacts: $($t.artifacts)" }
                $xw.WriteString((ConvertTo-XmlSafe $body))
                $xw.WriteEndElement()
            } elseif ($t.status -eq 'skipped') {
                $xw.WriteStartElement('skipped')
                if ($t.message) { $xw.WriteAttributeString('message', (ConvertTo-XmlSafe ([string]$t.message))) }
                $xw.WriteEndElement()
            }
            if ($t.flaky) {
                $xw.WriteStartElement('properties')
                $xw.WriteStartElement('property')
                $xw.WriteAttributeString('name', 'flaky')
                $xw.WriteAttributeString('value', 'true')
                $xw.WriteEndElement()
                $xw.WriteEndElement()
                $first = $fr.Attempts[0]
                $xw.WriteElementString('system-out', (ConvertTo-XmlSafe ("passed on retry; attempt 1 was $($first.status)" + $(if ($first.message) { ": $($first.message)" } else { '' }))))
            }
            $xw.WriteEndElement()
        }
        $xw.WriteEndElement()
    }
    $xw.WriteEndElement()
    $xw.WriteEndDocument()
} finally {
    $xw.Dispose()
}

# Console summary ------------------------------------------------------------

$s = $summary
$line = 'e2e: {0} files, {1} tests: {2} passed, {3} failed, {4} skipped; {5} flaky file(s); {6:n1}s' -f $s.files, $s.tests, $s.passed, $s.failed, $s.skipped, $s.flaky_files, ($runClock.ElapsedMilliseconds / 1000.0)
Write-Host ''
Write-Host $line -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
foreach ($t in @($allTests | Where-Object status -EQ 'failed')) {
    Write-Host ("  FAIL {0} :: {1}" -f $t.file, $t.name) -ForegroundColor Red
    if ($t.message) { Write-Host ('       ' + ((([string]$t.message) -split "`n" | Select-Object -First 6) -join "`n       ")) -ForegroundColor DarkRed }
    if ($t.artifacts) { Write-Host "       artifacts: $($t.artifacts)" -ForegroundColor DarkGray }
}
foreach ($t in @($allTests | Where-Object status -EQ 'skipped')) {
    Write-Host ("  SKIP {0} :: {1}: {2}" -f $t.file, $t.name, $t.message) -ForegroundColor Yellow
}
foreach ($fr in @($fileResults | Where-Object Status -EQ 'flaky')) {
    Write-Host ("  FLAKY {0} (passed on retry)" -f $fr.Job.Rel) -ForegroundColor Yellow
}
Write-Host "results: $jsonPath"
Write-Host "junit:   $junitPath"
exit $exitCode
