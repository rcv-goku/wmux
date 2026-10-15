#Requires -Version 7.0
<#
.SYNOPSIS
    Local WP gate (-Wp <id>) and integrator merge gate (-Full) of the wmux parity program.

.DESCRIPTION
    Implements docs/arch/ARCHITECTURE.md ADR-12.5, ADR-14.9 and section 15.6. Every step
    prints PASS / FAIL / SKIP / WARN; steps whose prerequisites do not exist yet (build
    steps defined by W0-A3, the W0-B e2e harness, contract tests) are skipped with a notice.
    A summary table is printed at the end and written to <log dir>/summary.json.

    Steps (id: what)                                         -Wp   -Full
      fmt        zig fmt --check on .zig/.zon changed vs base   x     x
      pslint     PowerShell parse check of changed .ps1/.psm1   x     x
      ownership  scripts/check-ownership.ps1 -Wp <id>           x     x (when the WP id is known)
      manifest   scripts/check-manifest.ps1                     x     x
      build      zig build (debug)                              x     x
      release    zig build -Doptimize=ReleaseFast                     x (prefix zig-out\release)
      test-fast  zig build test-fast (if the step exists)       x     x
      test-cli   zig build test-cli (if the step exists)        x     x
      unit       zig build test with -Dtest-filter=...          x     x
                   -Wp:   "unit: <feature>" for the features the WP owns/changed; plus
                          "unit: " and the legacy filters when shared code changed
                   -Full: "unit: ", sidebar, wsl, win-pwd, ipc:
                   (all filters go into ONE compile; -SplitFilters runs them one by one)
      e2e        test/e2e/run.ps1 (if present)                  x     x
                   -Wp:   suite "smoke" + the areas holding the WP's <id>*.e2e.ps1 suites
                   -Full: all suites
      contract   settings-schema golden, test/cli/probes.ps1,         x
                 test/contract/*.ps1 (each when present)
      fulltest   zig build test, unfiltered, failures checked against test/known-failures.txt
                 (only with -FullTest; ADR-12.2 nightly / wave tag)

.PARAMETER Wp
    Work-package id (W2-5, W1-1a, W0-D-S1 ...). Default: inferred from the worktree directory
    or the wp/<id>-<slug> branch. Required for the local gate; optional with -Full.

.PARAMETER Full
    Integrator merge gate (run on the rebased WP head before merging --no-ff).

.PARAMETER FullTest
    Also run the full, unfiltered `zig build test` and fail on failures not listed in
    test/known-failures.txt.

.PARAMETER Base
    Integration branch (default master; origin/master as fallback).

.PARAMETER UnitFilter
    Replace the computed unit test filters (e.g. -UnitFilter 'unit: notifications').

.PARAMETER Only
    Run only these step ids.

.PARAMETER Skip
    Skip these step ids.

.PARAMETER SplitFilters
    Run every unit filter as its own zig invocation (one compile each; slower).

.PARAMETER FailFast
    Stop at the first failing step.

.PARAMETER AllowMissingSpec
    Report the ownership step as SKIP instead of FAIL when docs/arch/wp/<id>.md is missing.

.PARAMETER E2ETimeoutSec
    Budget for the whole e2e step (default 600 s); the process tree is killed after it.

.PARAMETER Quiet
    Do not stream command output; print the tail of a log when its step fails.

.PARAMETER DryRun
    Print the plan (commands, filters, suites) without running anything.

.PARAMETER Zig
    Path to zig.exe (default: $env:ZIG, zig on PATH, ~\zig-x86_64-windows-0.15.2\zig.exe).

.PARAMETER LogDir
    Where step logs and summary.json go (default .zig-cache\wmux-gate\<timestamp>-<mode>).

.EXAMPLE
    pwsh scripts/gate.ps1 -Wp W2-5

.EXAMPLE
    pwsh scripts/gate.ps1 -Full -Wp W2-5

.EXAMPLE
    pwsh scripts/gate.ps1 -Wp W2-5 -Only fmt,ownership,manifest -DryRun

.NOTES
    Exit codes: 0 = no step failed, 1 = at least one step failed, 2 = usage error.
#>
[CmdletBinding()]
param(
    [string]$Wp,
    [switch]$Full,
    [switch]$FullTest,
    [string]$Base = 'master',
    [string[]]$UnitFilter,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$SplitFilters,
    [switch]$FailFast,
    [switch]$AllowMissingSpec,
    [int]$E2ETimeoutSec = 600,
    [switch]$Quiet,
    [switch]$DryRun,
    [string]$Zig,
    [string]$LogDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib/WmuxTooling.psm1') -Force

$tag = 'gate'
$LegacyFilters = @('sidebar', 'wsl', 'win-pwd', 'ipc:')
$AllStepIds = @('fmt', 'pslint', 'ownership', 'manifest', 'build', 'release', 'test-fast', 'test-cli', 'unit', 'e2e', 'contract', 'fulltest')

function Exit-Usage([string]$Message) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message $Message
    exit 2
}

function New-StepResult([string]$Result, [string]$Notes = '') {
    return [pscustomobject]@{ Result = $Result; Notes = $Notes }
}

# ------------------------------------------------------------------ context
try {
    $repo = Get-WmuxRepoRoot -Path $PSScriptRoot
} catch {
    Exit-Usage $_.Exception.Message
}
$mode = if ($Full) { 'full' } else { 'local' }
# `pwsh -File gate.ps1 -Only a,b` passes "a,b" as one string: accept both forms.
$Only = @($Only | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Skip = @($Skip | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($s in @($Only) + @($Skip)) {
    if ($s -and $AllStepIds -notcontains $s) { Exit-Usage "Unknown step '$s'. Steps: $($AllStepIds -join ', ')" }
}
if (-not $Wp) { $Wp = Resolve-WmuxWpId -RepoRoot $repo }
if ($mode -eq 'local' -and -not $Wp) { Exit-Usage 'Cannot infer the WP id; pass -Wp <id> (or -Full for the integrator gate).' }
if ($Wp -and -not (Test-WmuxWpId $Wp)) { Exit-Usage "'$Wp' is not a WP id (expected e.g. W2-5, W1-1a, W0-D-S1)." }

try {
    $baseRef = Resolve-WmuxBaseRef -RepoRoot $repo -Base $Base
    $changes = Get-WmuxChangedFiles -RepoRoot $repo -BaseRef $baseRef
} catch {
    Exit-Usage $_.Exception.Message
}
$branch = Get-WmuxCurrentBranch -RepoRoot $repo
# Zig is resolved up front but only required by the steps that run it.
$zigExe = $null
$zigError = $null
try { $zigExe = Resolve-WmuxZig -Zig $Zig -Tag $tag } catch { $zigError = $_.Exception.Message }
$cache = Get-WmuxZigCache -WorktreeRoot $repo -WorktreesRoot (Split-Path $repo -Parent)
$childEnv = @{}
if ($cache.Override) { $childEnv['ZIG_GLOBAL_CACHE_DIR'] = $cache.Dir }
$T = Get-WmuxTargetArgs
$pwshExe = Get-WmuxPwshExe

$spec = $null
$specError = $null
if ($Wp) {
    try { $spec = Get-WmuxWpSpec -RepoRoot $repo -Wp $Wp -BaseRef $baseRef } catch { $specError = $_.Exception.Message }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($LogDir) {
    $LogDir = Resolve-WmuxPath $LogDir
} else {
    $suffix = if ($Wp) { "$mode-$Wp" } else { $mode }
    $LogDir = Join-Path $repo ".zig-cache/wmux-gate/$stamp-$suffix"
}
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

$changed = @($changes.Files)
$existing = @($changed | Where-Object { $_.Status -ne 'D' -and (Test-Path -LiteralPath (Join-Path $repo $_.Path) -PathType Leaf) })
$uncommitted = @($changed | Where-Object { $_.Uncommitted -or $_.Untracked })

Write-WmuxLine -Tag $tag -Message "mode=$mode wp=$(if ($Wp) { $Wp } else { '-' }) branch=$branch base=$baseRef merge-base=$($changes.MergeBase.Substring(0, 10)) head=$($changes.Head.Substring(0, 10))"
Write-WmuxLine -Tag $tag -Message "repo=$repo"
Write-WmuxLine -Tag $tag -Message "zig=$(if ($zigExe) { $zigExe } else { "<not found: $zigError>" }) cache=$($cache.Dir) ($($cache.Reason))"
Write-WmuxLine -Tag $tag -Message "changed vs ${baseRef}: $($changed.Count) path(s), $($uncommitted.Count) uncommitted/untracked; logs: $LogDir"
if ($uncommitted.Count -gt 0) {
    Write-WmuxLine -Tag $tag -Level NOTE -Message 'uncommitted changes are included in fmt/pslint/unit selection; only committed work is merged.'
}

# ------------------------------------------------------------------ helpers
$script:stepIndex = 0
function Get-StepLog([string]$Id) { return (Join-Path $LogDir ('{0:D2}-{1}.log' -f $script:stepIndex, $Id)) }

function Invoke-Logged {
    param([string]$Id, [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSec = 0, [string]$Suffix = '')
    $log = Get-StepLog ($Id + $Suffix)
    $res = Invoke-WmuxProcess -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $repo `
        -LogFile $log -TimeoutSec $TimeoutSec -Quiet:$Quiet -Environment $childEnv
    if ($res.ExitCode -ne 0 -and $Quiet) {
        Write-Host "---- last lines of $log"
        Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Host $_ }
    }
    return $res
}

function Invoke-Zig([string]$Id, [string[]]$Arguments, [string]$Suffix = '') {
    if (-not $zigExe) { throw $zigError }
    return (Invoke-Logged -Id $Id -FilePath $zigExe -Arguments $Arguments -Suffix $Suffix)
}

$script:buildSteps = $null
function Get-BuildStepNames {
    if ($DryRun) { return (Get-WmuxDeclaredSteps -RepoRoot $repo) }
    if (-not $zigExe) { throw $zigError }
    if ($null -eq $script:buildSteps) {
        $names = Get-WmuxBuildSteps -Zig $zigExe -RepoRoot $repo -LogFile (Join-Path $LogDir 'zig-build-steps.log') -Environment $childEnv
        $script:buildSteps = if ($null -eq $names) { , @('<unavailable>') } else { , @($names) }
    }
    return $script:buildSteps
}

function Get-CheckWarnings([string]$Log) {
    $last = Get-Content -LiteralPath $Log -Tail 3 | Where-Object { $_ -match '(\d+) warning\(s\)' } | Select-Object -Last 1
    if ($last -and $last -match '(\d+) warning\(s\)') { return [int]$Matches[1] }
    return 0
}

function Get-FeatureAreas {
    # Feature ids from owns globs and changed paths; $true in .Shared when code outside features changed.
    $areas = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $shared = $false
    $relevant = 0
    foreach ($f in $changed) {
        $p = $f.Path
        if ($p -notmatch '^(src/|build\.zig$|build\.zig\.zon$|pkg/|vendor/|include/)') { continue }
        $relevant++
        if ($p -match '^src/apprt/win32/features/([^/]+)/') { [void]$areas.Add($Matches[1]) }
        elseif ($p -match '^src/wmux_proto/settings/specs/([^/]+)\.zig$') { [void]$areas.Add($Matches[1]) }
        elseif ($p -match '^src/wmux_cli/' -or $p -match '^src/web/') { }
        else { $shared = $true }
    }
    if ($spec) {
        foreach ($e in $spec.Owns) {
            if ($e.Path -match '^src/apprt/win32/features/([A-Za-z0-9_]+)/') { [void]$areas.Add($Matches[1]) }
        }
    }
    return [pscustomobject]@{ Areas = @($areas); Shared = $shared; Relevant = $relevant }
}

function Get-UnitPlan {
    if ($UnitFilter) { return [pscustomobject]@{ Filters = @($UnitFilter); Reason = 'from -UnitFilter' } }
    if ($mode -eq 'full') { return [pscustomobject]@{ Filters = @('unit: ') + $LegacyFilters; Reason = 'merge gate filter set' } }
    $a = Get-FeatureAreas
    if ($a.Relevant -eq 0) { return [pscustomobject]@{ Filters = @(); Reason = 'no changes under src/, build.zig, pkg/, vendor/ or include/' } }
    if ($a.Shared) { return [pscustomobject]@{ Filters = @('unit: ') + $LegacyFilters; Reason = 'shared (non-feature) code changed' } }
    if ($a.Areas.Count -eq 0) { return [pscustomobject]@{ Filters = @(); Reason = 'only CLI or web assets changed (test-cli / e2e cover them)' } }
    return [pscustomobject]@{ Filters = @($a.Areas | ForEach-Object { "unit: $_" }); Reason = "features $($a.Areas -join ', ')" }
}

function Get-WpSuites {
    $suitesDir = Join-Path $repo 'test/e2e/suites'
    if (-not (Test-Path -LiteralPath $suitesDir -PathType Container) -or -not $Wp) { return , @() }
    $rx = '^' + [regex]::Escape($Wp) + '(?![0-9A-Za-z])'
    $all = @(Get-ChildItem -LiteralPath $suitesDir -Recurse -File -Filter '*.e2e.ps1')
    $out = foreach ($f in $all) {
        $rel = [System.IO.Path]::GetRelativePath($repo, $f.FullName).Replace('\', '/')
        if ($rel -match '/_quarantine/') { continue }
        $byName = $f.Name -match $rx
        $byGlob = $false
        if ($spec) { foreach ($e in $spec.Owns) { if ($e.Path -like 'test/e2e/suites/*' -and (Test-WmuxGlobMatch -Path $rel -Glob $e.Path)) { $byGlob = $true; break } } }
        if ($byName -or $byGlob) { $rel }
    }
    return , @($out)
}

function Get-E2ERuns {
    # Returns a list of argument arrays for test/e2e/run.ps1 plus a description.
    $run = Join-Path $repo 'test/e2e/run.ps1'
    $params = Get-WmuxScriptParameters -Path $run
    $common = @('-NoProfile', '-NonInteractive', '-File', $run)
    $runs = [System.Collections.Generic.List[object]]::new()
    $buildArgs = if ($params.ContainsKey('build')) { @('-Build', 'Debug') } else { @() }
    if ($mode -eq 'full') {
        $extra = $buildArgs
        if ($params.ContainsKey('parallel')) { $extra += @('-Parallel', '4') }
        $runs.Add([pscustomobject]@{ Label = 'all suites'; Extra = $extra; Args = ($common + $extra) })
        return , $runs.ToArray()
    }
    $suites = Get-WpSuites
    $areas = @(@('smoke') + @($suites | ForEach-Object { ($_ -split '/')[3] } | Where-Object { $_ -and $_ -ne 'smoke' }) | Select-Object -Unique)
    if ($params.ContainsKey('suite')) {
        foreach ($a in $areas) {
            $extra = @('-Suite', $a) + $buildArgs
            $runs.Add([pscustomobject]@{ Label = "suite $a"; Extra = $extra; Args = ($common + $extra) })
        }
    } else {
        $runs.Add([pscustomobject]@{ Label = 'all suites (run.ps1 has no -Suite)'; Extra = $buildArgs; Args = ($common + $buildArgs) })
    }
    return , $runs.ToArray()
}

# ------------------------------------------------------------------ steps
$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$Id, [string]$Title, [string[]]$Modes, [scriptblock]$Plan, [scriptblock]$Run) {
    $steps.Add([pscustomobject]@{ Id = $Id; Title = $Title; Modes = $Modes; Plan = $Plan; Run = $Run })
}

Add-Step 'fmt' 'zig fmt --check (changed files)' @('local', 'full') {
    $files = @($existing | Where-Object { $_.Path -match '\.(zig|zon)$' })
    if ($files.Count -eq 0) { return 'skip: no changed .zig/.zon files' }
    return "zig fmt --check $($files.Count) file(s): $(($files | Select-Object -First 5 | ForEach-Object Path) -join ' ')$(if ($files.Count -gt 5) { ' ...' })"
} {
    $files = @($existing | Where-Object { $_.Path -match '\.(zig|zon)$' } | ForEach-Object { $_.Path })
    if ($files.Count -eq 0) { return (New-StepResult SKIP 'no changed .zig/.zon files') }
    $bad = 0
    for ($i = 0; $i -lt $files.Count; $i += 40) {
        $batch = @($files[$i..([Math]::Min($i + 39, $files.Count - 1))])
        $res = Invoke-Zig 'fmt' (@('fmt', '--check') + $batch) -Suffix "-$([int]($i / 40))"
        if ($res.ExitCode -ne 0) { $bad++ }
    }
    if ($bad) { return (New-StepResult FAIL "files need zig fmt (listed above); run: zig fmt <file>") }
    return (New-StepResult PASS "$($files.Count) file(s) formatted")
}

Add-Step 'pslint' 'PowerShell parse (changed .ps1/.psm1/.psd1)' @('local', 'full') {
    $files = @($existing | Where-Object { $_.Path -match '\.(ps1|psm1|psd1)$' })
    if ($files.Count -eq 0) { return 'skip: no changed PowerShell files' }
    return "parse $($files.Count) file(s)"
} {
    $files = @($existing | Where-Object { $_.Path -match '\.(ps1|psm1|psd1)$' } | ForEach-Object { $_.Path })
    if ($files.Count -eq 0) { return (New-StepResult SKIP 'no changed PowerShell files') }
    $log = Get-StepLog 'pslint'
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        foreach ($e in (Test-WmuxPowerShellSyntax -Path (Join-Path $repo $f))) {
            $problems.Add("${f}:$($e.Extent.StartLineNumber):$($e.Extent.StartColumnNumber): $($e.Message)")
        }
    }
    Set-Content -LiteralPath $log -Value (@("# parsed $($files.Count) file(s)") + $problems) -Encoding utf8
    foreach ($p in $problems) { Write-Host $p }
    if ($problems.Count) { return (New-StepResult FAIL "$($problems.Count) parse error(s)") }
    return (New-StepResult PASS "$($files.Count) file(s) parse")
}

Add-Step 'ownership' 'scripts/check-ownership.ps1' @('local', 'full') {
    if (-not $Wp) { return 'skip: no WP id' }
    return "pwsh scripts/check-ownership.ps1 -Wp $Wp -Base $Base"
} {
    if (-not $Wp) { return (New-StepResult SKIP 'no WP id (pass -Wp, or run on a wp/<id>-<slug> branch)') }
    $res = Invoke-Logged -Id 'ownership' -FilePath $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'check-ownership.ps1'), '-Wp', $Wp, '-Base', $Base)
    $warn = Get-CheckWarnings $res.LogFile
    switch ($res.ExitCode) {
        0 { if ($warn) { return (New-StepResult WARN "$warn warning(s)") } else { return (New-StepResult PASS 'all changed paths covered by the spec') } }
        1 { return (New-StepResult FAIL 'paths outside owns/touches/appends (see log)') }
        2 {
            if ($AllowMissingSpec -and -not $spec -and -not $specError) { return (New-StepResult SKIP "docs/arch/wp/$Wp.md missing (-AllowMissingSpec)") }
            return (New-StepResult FAIL 'spec missing or invalid (see log)')
        }
        default { return (New-StepResult FAIL "exit code $($res.ExitCode)") }
    }
}

Add-Step 'manifest' 'scripts/check-manifest.ps1' @('local', 'full') {
    return 'pwsh scripts/check-manifest.ps1'
} {
    $res = Invoke-Logged -Id 'manifest' -FilePath $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'check-manifest.ps1'))
    $warn = Get-CheckWarnings $res.LogFile
    $skeleton = [bool](Select-String -LiteralPath $res.LogFile -Pattern 'skeleton not present yet' -SimpleMatch -Quiet)
    $note = if ($skeleton) { 'skeleton not present yet; ' } else { '' }
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "${note}registry errors (see log)") }
    if ($warn) { return (New-StepResult WARN "$note$warn warning(s)") }
    return (New-StepResult PASS "${note}consistent")
}

Add-Step 'build' 'zig build (debug)' @('local', 'full') {
    return "zig build $($T -join ' ')"
} {
    $res = Invoke-Zig 'build' (@('build') + $T)
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "exit code $($res.ExitCode)") }
    return (New-StepResult PASS 'zig-out\bin\wmux.exe')
}

Add-Step 'release' 'zig build -Doptimize=ReleaseFast' @('full') {
    return "zig build $($T -join ' ') -Doptimize=ReleaseFast --prefix zig-out\release"
} {
    $prefix = Join-Path $repo 'zig-out/release'
    $res = Invoke-Zig 'release' (@('build') + $T + @('-Doptimize=ReleaseFast', '--prefix', $prefix))
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "exit code $($res.ExitCode)") }
    $dll = Join-Path $repo 'zig-out/bin/WebView2Loader.dll'
    if (Test-Path -LiteralPath $dll) { Copy-Item -LiteralPath $dll -Destination (Join-Path $prefix 'bin') -Force }
    return (New-StepResult PASS 'zig-out\release\bin\wmux.exe')
}

# test-fast and test-cli: the step id is also the zig build step name.
$optionalTestPlan = {
    param($step)
    if ((Get-BuildStepNames) -notcontains $step.Id) { return "skip: build step $($step.Id) not defined yet (W0-A3)" }
    return "zig build $($step.Id) $($T -join ' ')"
}
$optionalTestRun = {
    param($step)
    $names = Get-BuildStepNames
    if ($names -contains '<unavailable>') { return (New-StepResult FAIL 'zig build -l failed (see zig-build-steps.log)') }
    if ($names -notcontains $step.Id) { return (New-StepResult SKIP "build step $($step.Id) not defined yet (W0-A3)") }
    $res = Invoke-Zig $step.Id (@('build', $step.Id) + $T)
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "exit code $($res.ExitCode)") }
    return (New-StepResult PASS '')
}
Add-Step 'test-fast' 'zig build test-fast' @('local', 'full') $optionalTestPlan $optionalTestRun
Add-Step 'test-cli' 'zig build test-cli' @('local', 'full') $optionalTestPlan $optionalTestRun

Add-Step 'unit' 'zig build test -Dtest-filter=...' @('local', 'full') {
    $plan = Get-UnitPlan
    if ($plan.Filters.Count -eq 0) { return "skip: $($plan.Reason)" }
    $how = if ($SplitFilters) { 'one compile per filter' } else { 'one compile' }
    return "filters [$(($plan.Filters | ForEach-Object { "'$_'" }) -join ', ')] ($($plan.Reason); $how)"
} {
    $plan = Get-UnitPlan
    if ($plan.Filters.Count -eq 0) { return (New-StepResult SKIP $plan.Reason) }
    $src = Join-Path $repo 'src'
    $empty = @()
    if ($mode -eq 'local' -and -not $UnitFilter) {
        $names = @(Get-ChildItem -LiteralPath $src -Recurse -File -Filter '*.zig' | Select-String -Pattern 'test\s+"[^"]*"' -AllMatches |
                ForEach-Object { $_.Matches } | ForEach-Object { $_.Value })
        foreach ($f in $plan.Filters) {
            if (-not @($names | Where-Object { $_.Contains($f) }).Count) { $empty += $f }
        }
        foreach ($f in $empty) { Write-WmuxLine -Tag $tag -Level NOTE -Message "no test name contains '$f' yet (the filter will run nothing)." }
    }
    $groups = [System.Collections.Generic.List[object]]::new()
    if ($SplitFilters) { foreach ($f in $plan.Filters) { $groups.Add([string[]]@($f)) } } else { $groups.Add([string[]]@($plan.Filters)) }
    $failed = 0
    $n = 0
    foreach ($g in $groups) {
        $filterArgs = @($g | ForEach-Object { "-Dtest-filter=$_" })
        $res = Invoke-Zig 'unit' (@('build', 'test') + $T + $filterArgs) -Suffix "-$n"
        $n++
        if ($res.ExitCode -ne 0) { $failed++ }
    }
    $desc = ($plan.Filters | ForEach-Object { "'$_'" }) -join ', '
    if ($failed) { return (New-StepResult FAIL "$desc failed") }
    if ($empty.Count -eq $plan.Filters.Count) { return (New-StepResult WARN "$desc matched no test names") }
    return (New-StepResult PASS $desc)
}

Add-Step 'e2e' 'test/e2e/run.ps1' @('local', 'full') {
    if (-not (Test-Path -LiteralPath (Join-Path $repo 'test/e2e/run.ps1'))) { return 'skip: test/e2e/run.ps1 not present yet (W0-B harness)' }
    $runs = Get-E2ERuns
    return (($runs | ForEach-Object { "run.ps1 $($_.Extra -join ' ')".TrimEnd() }) -join '; ')
} {
    if (-not (Test-Path -LiteralPath (Join-Path $repo 'test/e2e/run.ps1'))) { return (New-StepResult SKIP 'test/e2e/run.ps1 not present yet (W0-B harness)') }
    if ($script:results.Contains('build') -and $script:results['build'].Result -eq 'FAIL') { return (New-StepResult SKIP 'debug build failed') }
    $runs = Get-E2ERuns
    $deadline = [DateTime]::UtcNow.AddSeconds($E2ETimeoutSec)
    $failedRuns = @()
    $i = 0
    foreach ($r in $runs) {
        $left = [int]($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($left -le 0) { $failedRuns += "$($r.Label) (budget exhausted)"; continue }
        $res = Invoke-Logged -Id 'e2e' -FilePath $pwshExe -Arguments $r.Args -TimeoutSec $left -Suffix "-$i"
        $i++
        if ($res.TimedOut) { $failedRuns += "$($r.Label) (timeout)" }
        elseif ($res.ExitCode -ne 0) { $failedRuns += $r.Label }
    }
    $wpNote = ''
    $wpSuites = Get-WpSuites
    if ($mode -eq 'local' -and $wpSuites.Count -eq 0) {
        $wpNote = "no $Wp*.e2e.ps1 suite (ADR-12.5 expects one per WP); "
    }
    if ($failedRuns.Count) { return (New-StepResult FAIL "$wpNote$($failedRuns -join ', ') failed") }
    if ($wpNote) { return (New-StepResult WARN "${wpNote}smoke passed") }
    return (New-StepResult PASS (($runs | ForEach-Object Label) -join ', '))
}

Add-Step 'contract' 'contract checks' @('full') {
    $parts = @()
    if ((Get-BuildStepNames) -contains 'settings-schema') { $parts += 'settings-schema golden' }
    if (Test-Path -LiteralPath (Join-Path $repo 'test/cli/probes.ps1')) { $parts += 'test/cli/probes.ps1' }
    $parts += @(Get-ChildItem -LiteralPath (Join-Path $repo 'test/contract') -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { "test/contract/$($_.Name)" })
    if ($parts.Count -eq 0) { return 'skip: no contract checks present yet' }
    return ($parts -join ', ')
} {
    $ran = @(); $failedChecks = @()
    $names = Get-BuildStepNames
    if ($names -contains 'settings-schema') {
        $ran += 'settings-schema'
        $res = Invoke-Zig 'contract' (@('build', 'settings-schema') + $T) -Suffix '-schema'
        if ($res.ExitCode -ne 0) { $failedChecks += 'settings-schema (build step failed)' }
        else {
            $st = Invoke-WmuxGit -RepoRoot $repo -Arguments @('status', '--porcelain', '--', 'docs/wmux/schema')
            if ($st.Output.Trim()) {
                Write-Host $st.Output
                $failedChecks += 'settings-schema (docs/wmux/schema differs from the committed golden; commit the regenerated file)'
            }
        }
    }
    $scripts = @()
    $probes = Join-Path $repo 'test/cli/probes.ps1'
    if (Test-Path -LiteralPath $probes) { $scripts += $probes }
    $scripts += @(Get-ChildItem -LiteralPath (Join-Path $repo 'test/contract') -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $k = 0
    foreach ($s in $scripts) {
        $rel = [System.IO.Path]::GetRelativePath($repo, $s).Replace('\', '/')
        $ran += $rel
        $res = Invoke-Logged -Id 'contract' -FilePath $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', $s) -TimeoutSec 600 -Suffix "-$k"
        $k++
        if ($res.ExitCode -ne 0) { $failedChecks += $rel }
    }
    if ($ran.Count -eq 0) { return (New-StepResult SKIP 'no contract checks present yet (settings-schema step, test/cli/probes.ps1, test/contract/*.ps1)') }
    if ($failedChecks.Count) { return (New-StepResult FAIL ($failedChecks -join '; ')) }
    return (New-StepResult PASS ($ran -join ', '))
}

Add-Step 'fulltest' 'zig build test (unfiltered) vs test/known-failures.txt' @('fulltest') {
    return "zig build test $($T -join ' ')  (allowlist: test/known-failures.txt)"
} {
    $kfPath = Join-Path $repo 'test/known-failures.txt'
    $known = Read-WmuxKnownFailures -Path $kfPath
    $res = Invoke-Zig 'fulltest' (@('build', 'test') + $T)
    $parsed = ConvertFrom-WmuxZigTestLog -Lines ([System.IO.File]::ReadAllLines($res.LogFile))
    $summary = if ($parsed.Summary) { $parsed.Summary -replace '^Build Summary: ', '' } else { '' }
    # Compile errors leave no test results; error-looking lines printed by tests do not count.
    if ($parsed.CompileErrors.Count -gt 0 -and $null -eq $parsed.TestsTotal -and $parsed.Failures.Count -eq 0) {
        return (New-StepResult FAIL "test binary failed to compile ($($parsed.CompileErrors.Count) error line(s), first: $($parsed.CompileErrors[0]))")
    }
    $unexpected = @(); $expected = @()
    foreach ($name in $parsed.Failures.Keys) {
        if (Find-WmuxKnownFailure -Name $name -Entries $known) { $expected += $name } else { $unexpected += "$name ($($parsed.Failures[$name]))" }
    }
    $unused = @($known | Where-Object { $e = $_; -not @($parsed.Failures.Keys | Where-Object { Find-WmuxKnownFailure -Name $_ -Entries @($e) }).Count })
    $unusedNote = if ($unused.Count) { "; $($unused.Count) known-failures entr(ies) did not fail (prune when stable)" } else { '' }
    if ($unexpected.Count) {
        foreach ($u in $unexpected) { Write-WmuxLine -Tag $tag -Level ERROR -Message "unexpected test failure: $u" }
        return (New-StepResult FAIL "$($unexpected.Count) failure(s) not in test/known-failures.txt: $($unexpected -join '; ')")
    }
    if ($res.ExitCode -ne 0 -and $parsed.Failures.Count -eq 0) {
        return (New-StepResult FAIL "zig build test exited $($res.ExitCode) without parseable test failures (see log)")
    }
    if ($expected.Count) { return (New-StepResult PASS "$summary; known failures only: $($expected.Count)$unusedNote") }
    return (New-StepResult PASS "$summary$unusedNote")
}

# ------------------------------------------------------------------ run
$script:results = [ordered]@{}
$selected = @($steps | Where-Object {
        $s = $_
        ($s.Modes -contains $mode) -or ($FullTest -and $s.Modes -contains 'fulltest')
    })
$total = $selected.Count
$stopped = $false
$gateTimer = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($s in $selected) {
    $script:stepIndex++
    $r = $null
    $elapsed = [TimeSpan]::Zero
    if ($Only -and $Only -notcontains $s.Id) { $r = New-StepResult SKIP 'not selected (-Only)' }
    elseif ($Skip -and $Skip -contains $s.Id) { $r = New-StepResult SKIP 'skipped (-Skip)' }
    elseif ($stopped) { $r = New-StepResult SKIP 'not run (-FailFast)' }
    elseif ($DryRun) {
        $desc = (@(& $s.Plan $s) | ForEach-Object { "$_" }) -join ' '
        Write-WmuxLine -Tag $tag -Message ("[{0}/{1}] {2,-9} {3}" -f $script:stepIndex, $total, $s.Id, $desc)
        $r = New-StepResult PLAN $desc
    } else {
        Write-Host ''
        Write-WmuxLine -Tag $tag -Message ("==> [{0}/{1}] {2}: {3}" -f $script:stepIndex, $total, $s.Id, $s.Title)
        $t0 = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Keep only the step's result object, even if a command leaked pipeline output.
            $r = @(& $s.Run $s) | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties['Result'] } | Select-Object -Last 1
        } catch {
            $r = New-StepResult FAIL "error: $($_.Exception.Message)"
        }
        $t0.Stop()
        $elapsed = $t0.Elapsed
        if ($null -eq $r) { $r = New-StepResult FAIL 'internal error: step returned no result' }
        $level = switch ($r.Result) { 'PASS' { 'OK' } 'FAIL' { 'ERROR' } 'WARN' { 'WARN' } default { 'SKIP' } }
        Write-WmuxLine -Tag $tag -Level $level -Message ("{0} {1} ({2:mm\:ss}) {3}" -f $s.Id, $r.Result, $elapsed, $r.Notes)
        if ($FailFast -and $r.Result -eq 'FAIL') { $stopped = $true }
    }
    $script:results[$s.Id] = [pscustomobject]@{ Id = $s.Id; Title = $s.Title; Result = $r.Result; Seconds = [int]$elapsed.TotalSeconds; Notes = $r.Notes }
}
$gateTimer.Stop()

# ------------------------------------------------------------------ summary
$rows = @($script:results.Values)
$failedCount = @($rows | Where-Object Result -EQ 'FAIL').Count
$skipCount = @($rows | Where-Object Result -EQ 'SKIP').Count
$warnCount = @($rows | Where-Object Result -EQ 'WARN').Count
Write-Host ''
Write-Host ("==== gate summary: {0} {1} @ {2} ====" -f $mode, $(if ($Wp) { $Wp } else { '-' }), $changes.Head.Substring(0, 10))
Write-Host ('{0,-10} {1,-5} {2,6}  {3}' -f 'step', 'result', 'time', 'notes')
foreach ($row in $rows) {
    $time = if ($row.Seconds -gt 0) { '{0}:{1:D2}' -f [int][Math]::Floor($row.Seconds / 60), ($row.Seconds % 60) } else { '-' }
    $notes = if ($row.Notes.Length -gt 150) { $row.Notes.Substring(0, 147) + '...' } else { $row.Notes }
    Write-Host ('{0,-10} {1,-5} {2,6}  {3}' -f $row.Id, $row.Result, $time, $notes)
}
$verdict = if ($DryRun) { 'DRY RUN (nothing executed)' } elseif ($failedCount) { "GATE FAILED ($failedCount failed, $warnCount warned, $skipCount skipped)" } else { "GATE PASSED ($warnCount warned, $skipCount skipped)" }
Write-Host ("{0} in {1:hh\:mm\:ss}" -f $verdict, $gateTimer.Elapsed)
if (-not $DryRun) {
    Write-Host "logs: $LogDir"
    $summaryObj = [ordered]@{
        mode       = $mode
        wp         = $Wp
        branch     = $branch
        base       = $baseRef
        merge_base = $changes.MergeBase
        head       = $changes.Head
        started    = $stamp
        seconds    = [int]$gateTimer.Elapsed.TotalSeconds
        passed     = ($failedCount -eq 0)
        steps      = $rows
    }
    $summaryObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LogDir 'summary.json') -Encoding utf8
}
exit ([int]($failedCount -gt 0))
