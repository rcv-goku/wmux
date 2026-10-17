#Requires -Version 7.0
<#
.SYNOPSIS
    Tiered gates of the wmux parity program: local WP gate (-Wp), per-merge gate (-Merge),
    batched merge gate (-Batch a,b) and wave-end/nightly gate (-Full).

.DESCRIPTION
    Implements docs/arch/ARCHITECTURE.md ADR-12.5, ADR-14.9, section 15.6 and AF-23 (tiered
    gating, Appendix F.2). Every step prints PASS / FAIL / SKIP / WARN; steps whose
    prerequisites do not exist yet (build steps, e2e suites, the web harness, contract tests)
    are skipped with a notice. A summary table is printed at the end and written to
    <log dir>/summary.json (step durations, total seconds, budget).

    Tiers
      -Wp <id>        local gate of a WP worktree (before asking for a merge)
      -Merge [-Wp]    per merge, run by the integrator on the rebased WP head or on the merge
                      commit (budget 12 min, -BudgetSec): area unit filters + legacy filters,
                      e2e smoke + legacy + regression + affected areas, contract tests; the
                      settings schema is regenerated on the merged tree and committed
      -Batch a,b      -Merge for two ownership-disjoint WPs gated on one base: HEAD is a batch
                      branch holding both WP branches (section 14.9)
      -Full           wave ends (N9) and the nightly CI job: all e2e suites, the unfiltered
                      `zig build test` against test/known-failures.txt, contract tests

    Steps (id: what)                                          -Wp  -Merge -Full
      batch      both WP branches on the base, disjoint changes       B
      fmt        zig fmt --check on .zig/.zon changed vs base    x     x     x
      pslint     PowerShell parse check of changed scripts       x     x     x
      ownership  check-ownership.ps1 per WP (-Head per branch    x     x     x (WP id known)
                 with -Batch)
      manifest   check-manifest.ps1                              x     x     x
      schema     zig build settings-schema; commit                     x
                 "chore(schema): ..." when the file changed
      build      zig build (debug)                               x     x     x
      release    zig build -Doptimize=ReleaseFast (prefix              x     x
                 zig-out\release); with -Merge it runs in the
                 background beside the other steps
      test-fast  zig build test-fast                             x     x     x
      test-cli   zig build test-cli                              x     x     x
      unit       zig build test -Dtest-filter=...                x     x     x
                   -Wp:    "unit: <feature>" for owned/changed features; "unit: " + legacy
                           filters when shared code changed
                   -Merge: the same area filters, always plus the legacy filters
                   -Full:  "unit: " + legacy filters (fulltest runs everything)
      e2e        test/e2e/run.ps1 (one run, -Suite a,b,...)      x     x     x
                   -Wp:    smoke + the areas of the WP's suites
                   -Merge: smoke, legacy, regression + the areas of the WP's suites, of suites
                           whose "# covers:" tags name the spec's covers ids, of changed suite
                           files and of changed feature ids that have a suite area
                           (missing suites are skipped with a notice)
                   -Full:  all suites
      web        test/web/run.ps1 when src/web or test/web       x     x     x (always)
                 changed (and the script exists)
      contract   test/cli/probes.ps1, test/contract/*.ps1;             x     x
                 -Full also checks the settings-schema golden
      fulltest   zig build test (unfiltered) vs                              x (-NoFullTest
                 test/known-failures.txt (-FullTest adds it                     drops it)
                 to the other tiers)

.PARAMETER Wp
    Work-package id (W2-5, W1-1a, W0-D-S1, PB-notif ...). Default: inferred from the worktree
    directory or the wp/<id>-<slug> branch. Required for -Wp and -Merge (unless -Batch).

.PARAMETER Merge
    Per-merge gate (AF-23).

.PARAMETER Batch
    Two WP ids gated together on one base (implies -Merge).

.PARAMETER BatchRef
    The branches of the -Batch WPs, in the same order (default: the one local branch
    wp/<id> or wp/<id>-* of each id).

.PARAMETER Full
    Wave-end / nightly gate (AF-23).

.PARAMETER FullTest
    Add the unfiltered `zig build test` to -Wp or -Merge.

.PARAMETER NoFullTest
    Drop the unfiltered `zig build test` from -Full.

.PARAMETER NoSchemaCommit
    -Merge: regenerate the settings schema but do not commit it (the step then WARNs when the
    file changed).

.PARAMETER BudgetSec
    Time budget reported in summary.json (default 720 s for -Merge/-Batch, none otherwise).
    Exceeding it is a warning, not a failure.

.PARAMETER Base
    Integration branch (default master; origin/master as fallback). With -Merge on a merge
    commit of the base branch itself, the first parent is the base of the diff.

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
    Budget for the e2e step (default 600 s); the process tree is killed after it.

.PARAMETER Quiet
    Do not stream command output; print the tail of a log when its step fails.

.PARAMETER DryRun
    Print the tier plan (commands, filters, suites) without running anything.

.PARAMETER Zig
    Path to zig.exe (default: $env:ZIG, zig on PATH, ~\zig-x86_64-windows-0.15.2\zig.exe).

.PARAMETER LogDir
    Where step logs and summary.json go (default .zig-cache\wmux-gate\<timestamp>-<mode>-<id>).

.EXAMPLE
    pwsh scripts/gate.ps1 -Wp W2-5

.EXAMPLE
    pwsh scripts/gate.ps1 -Merge -Wp W2-5 -DryRun

.EXAMPLE
    pwsh scripts/gate.ps1 -Batch W1-4a,W1-6b

.EXAMPLE
    pwsh scripts/gate.ps1 -Full

.NOTES
    Exit codes: 0 = no step failed, 1 = at least one step failed, 2 = usage error.
#>
[CmdletBinding()]
param(
    [string]$Wp,
    [switch]$Merge,
    [string[]]$Batch,
    [string[]]$BatchRef,
    [switch]$Full,
    [switch]$FullTest,
    [switch]$NoFullTest,
    [switch]$NoSchemaCommit,
    [int]$BudgetSec = -1,
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
# e2e suite areas every merge runs (AF-11/AF-19: W0-B2 legacy-compat, plus-verbs, w0-regression).
$MergeE2EAreas = @('smoke', 'legacy', 'regression')
$AllStepIds = @('batch', 'fmt', 'pslint', 'ownership', 'manifest', 'schema', 'build', 'release', 'test-fast', 'test-cli', 'unit', 'e2e', 'web', 'contract', 'fulltest')

function Exit-Usage([string]$Message) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message $Message
    exit 2
}

function New-StepResult([string]$Result, [string]$Notes = '') {
    return [pscustomobject]@{ Result = $Result; Notes = $Notes }
}

function Split-List($Values) {
    # `pwsh -File gate.ps1 -Only a,b` passes "a,b" as one string: accept both forms.
    return , @($Values | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ------------------------------------------------------------------ context
try {
    $repo = Get-WmuxRepoRoot -Path $PSScriptRoot
} catch {
    Exit-Usage $_.Exception.Message
}
$Only = Split-List $Only
$Skip = Split-List $Skip
$Batch = Split-List $Batch
$BatchRef = Split-List $BatchRef
foreach ($s in @($Only) + @($Skip)) {
    if ($s -and $AllStepIds -notcontains $s) { Exit-Usage "Unknown step '$s'. Steps: $($AllStepIds -join ', ')" }
}
if ($Batch.Count) { $Merge = [switch]::new($true) }
if ($Merge -and $Full) { Exit-Usage '-Merge (or -Batch) and -Full are different tiers; pass one of them.' }
$mode = if ($Full) { 'full' } elseif ($Merge) { 'merge' } else { 'local' }
$isBatch = $Batch.Count -gt 0

if ($isBatch) {
    if ($Batch.Count -ne 2) { Exit-Usage "-Batch takes two WP ids (section 14.9), got $($Batch.Count)." }
    if ($Wp) { Exit-Usage '-Batch names the WPs; do not pass -Wp as well.' }
    if ($BatchRef.Count -and $BatchRef.Count -ne $Batch.Count) { Exit-Usage '-BatchRef needs one branch per -Batch id.' }
    foreach ($b in $Batch) { if (-not (Test-WmuxWpId $b)) { Exit-Usage "'$b' is not a WP id (expected e.g. W2-5, W1-1a, PB-notif)." } }
    if ($Batch[0] -eq $Batch[1]) { Exit-Usage '-Batch needs two different WPs.' }
    $wps = @($Batch)
} else {
    if (-not $Wp) { $Wp = Resolve-WmuxWpId -RepoRoot $repo }
    if ($mode -ne 'full' -and -not $Wp) { Exit-Usage "Cannot infer the WP id; pass -Wp <id> (or -Full for the wave-end gate)." }
    if ($Wp -and -not (Test-WmuxWpId $Wp)) { Exit-Usage "'$Wp' is not a WP id (expected e.g. W2-5, W1-1a, W0-D-S1, PB-notif)." }
    $wps = @(if ($Wp) { $Wp })
}
if ($BudgetSec -lt 0) { $BudgetSec = if ($mode -eq 'merge') { 720 } else { 0 } }
$runFullTest = ($mode -eq 'full' -and -not $NoFullTest) -or ($mode -ne 'full' -and $FullTest)

$branch = Get-WmuxCurrentBranch -RepoRoot $repo
try {
    $baseRef = Resolve-WmuxBaseRef -RepoRoot $repo -Base $Base
    $diffBase = $baseRef
    $postMerge = $false
    if ($mode -eq 'merge' -and $branch -and ($branch -eq $Base -or "origin/$branch" -eq $baseRef)) {
        # Gate run on the merge commit itself (on the base branch): diff against its first parent.
        $parents = @((Invoke-WmuxGit -RepoRoot $repo -Arguments @('rev-list', '--parents', '-n', '1', 'HEAD')).Output.Trim() -split '\s+')
        if ($parents.Count -ge 3) { $diffBase = 'HEAD^1'; $postMerge = $true }
    }
    $changes = Get-WmuxChangedFiles -RepoRoot $repo -BaseRef $diffBase
} catch {
    Exit-Usage $_.Exception.Message
}
# Zig is resolved up front but only required by the steps that run it.
$zigExe = $null
$zigError = $null
try { $zigExe = Resolve-WmuxZig -Zig $Zig -Tag $tag } catch { $zigError = $_.Exception.Message }
$cache = Get-WmuxZigCache -WorktreeRoot $repo -WorktreesRoot (Split-Path $repo -Parent)
$childEnv = @{}
if ($cache.Override) { $childEnv['ZIG_GLOBAL_CACHE_DIR'] = $cache.Dir }
# Child scripts (test/e2e/run.ps1 -Build, contract scripts) find zig through $env:ZIG or
# PATH only; hand them the zig this gate resolved (it may come from the ~\zig-... fallback).
if ($zigExe) { $childEnv['ZIG'] = $zigExe }
$T = Get-WmuxTargetArgs
$pwshExe = Get-WmuxPwshExe

$specs = [System.Collections.Generic.List[object]]::new()
$specErrors = @{}
foreach ($id in $wps) {
    try {
        $sp = Get-WmuxWpSpec -RepoRoot $repo -Wp $id -BaseRef $baseRef
        if ($sp) { $specs.Add($sp) }
    } catch { $specErrors[$id] = $_.Exception.Message }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($LogDir) {
    $LogDir = Resolve-WmuxPath $LogDir
} else {
    $suffix = if ($wps.Count) { "$mode-$($wps -join '+')" } else { $mode }
    $LogDir = Join-Path $repo ".zig-cache/wmux-gate/$stamp-$suffix"
}
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

$changed = @($changes.Files)
$existing = @($changed | Where-Object { $_.Status -ne 'D' -and (Test-Path -LiteralPath (Join-Path $repo $_.Path) -PathType Leaf) })
$uncommitted = @($changed | Where-Object { $_.Uncommitted -or $_.Untracked })
$schemaRel = Get-WmuxSchemaPath

$wpLabel = if ($wps.Count) { $wps -join '+' } else { '-' }
Write-WmuxLine -Tag $tag -Message "mode=$mode wp=$wpLabel branch=$branch base=$baseRef merge-base=$($changes.MergeBase.Substring(0, 10)) head=$($changes.Head.Substring(0, 10))"
Write-WmuxLine -Tag $tag -Message "repo=$repo"
Write-WmuxLine -Tag $tag -Message "zig=$(if ($zigExe) { $zigExe } else { "<not found: $zigError>" }) cache=$($cache.Dir) ($($cache.Reason))"
Write-WmuxLine -Tag $tag -Message "changed vs ${diffBase}: $($changed.Count) path(s), $($uncommitted.Count) uncommitted/untracked; logs: $LogDir"
if ($postMerge) { Write-WmuxLine -Tag $tag -Level NOTE -Message "HEAD is a merge commit on ${branch}: the diff base is its first parent (post-merge gate)." }
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

function Test-StepSelected([string]$Id) {
    if ($Only -and $Only -notcontains $Id) { return $false }
    if ($Skip -contains $Id) { return $false }
    return $true
}

function Get-FeatureAreas {
    # Feature ids from owns globs and changed paths; .Shared = code outside features changed.
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
        elseif (Test-WmuxAggregatorPath -Path $p) { }   # index lines only; the indexed files decide
        else { $shared = $true }
    }
    foreach ($sp in $specs) {
        foreach ($e in $sp.Owns) {
            if ($e.Path -match '^src/apprt/win32/features/([A-Za-z0-9_]+)/') { [void]$areas.Add($Matches[1]) }
        }
    }
    return [pscustomobject]@{ Areas = @($areas); Shared = $shared; Relevant = $relevant }
}

function Get-UnitPlan {
    if ($UnitFilter) { return [pscustomobject]@{ Filters = @($UnitFilter); Reason = 'from -UnitFilter' } }
    if ($mode -eq 'full') { return [pscustomobject]@{ Filters = @('unit: ') + $LegacyFilters; Reason = 'wave-end filter set' } }
    $a = Get-FeatureAreas
    if ($mode -eq 'merge') {
        if ($a.Shared) { return [pscustomobject]@{ Filters = @('unit: ') + $LegacyFilters; Reason = 'shared (non-feature) code changed; plus the legacy filters' } }
        $area = @($a.Areas | ForEach-Object { "unit: $_" })
        $why = if ($area.Count) { "features $($a.Areas -join ', ') plus the legacy filters" } else { 'legacy filters (no feature code changed)' }
        return [pscustomobject]@{ Filters = $area + $LegacyFilters; Reason = $why }
    }
    if ($a.Relevant -eq 0) { return [pscustomobject]@{ Filters = @(); Reason = 'no changes under src/, build.zig, pkg/, vendor/ or include/' } }
    if ($a.Shared) { return [pscustomobject]@{ Filters = @('unit: ') + $LegacyFilters; Reason = 'shared (non-feature) code changed' } }
    if ($a.Areas.Count -eq 0) { return [pscustomobject]@{ Filters = @(); Reason = 'only CLI, web assets or aggregator lines changed (test-cli / test-fast / e2e cover them)' } }
    return [pscustomobject]@{ Filters = @($a.Areas | ForEach-Object { "unit: $_" }); Reason = "features $($a.Areas -join ', ')" }
}

$script:suiteIndex = $null
function Get-SuiteIndex {
    # Every e2e suite file outside _quarantine: { Rel, Area, Name, Tags }.
    if ($null -ne $script:suiteIndex) { return $script:suiteIndex }
    $suitesDir = Join-Path $repo 'test/e2e/suites'
    $list = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $suitesDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $suitesDir -Recurse -File -Filter '*.e2e.ps1')) {
            $rel = [System.IO.Path]::GetRelativePath($repo, $f.FullName).Replace('\', '/')
            if ($rel -match '/_quarantine/') { continue }
            $list.Add([pscustomobject]@{ Rel = $rel; Area = ($rel -split '/')[3]; Name = $f.Name; Tags = (Read-WmuxSuiteTags -Path $f.FullName) })
        }
    }
    $script:suiteIndex = $list.ToArray()
    return $script:suiteIndex
}

function Get-WpSuites {
    # Suites of the gated WPs: file name <id>*.e2e.ps1, "# wp: <id>", or an owns glob.
    $out = foreach ($s in (Get-SuiteIndex)) {
        $hit = $false
        foreach ($id in $wps) {
            $rx = '^' + [regex]::Escape($id) + '(?![0-9A-Za-z])'
            if ($s.Name -match $rx -or $s.Tags.Wp -eq $id) { $hit = $true; break }
        }
        if (-not $hit) {
            foreach ($sp in $specs) { foreach ($e in $sp.Owns) { if ($e.Path -like 'test/e2e/suites/*' -and (Test-WmuxGlobMatch -Path $s.Rel -Glob $e.Path)) { $hit = $true; break } } }
        }
        if ($hit) { $s }
    }
    return , @($out)
}

function Get-E2EPlan {
    # Returns { Areas (existing), Missing (wanted but absent), Why } for -Wp / -Merge.
    $why = [ordered]@{}
    function Add-Area([string]$Area, [string]$Reason) {
        if (-not $Area) { return }
        if (-not $why.Contains($Area)) { $why[$Area] = [System.Collections.Generic.List[string]]::new() }
        if (-not $why[$Area].Contains($Reason)) { $why[$Area].Add($Reason) }
    }
    $index = Get-SuiteIndex
    $existingAreas = @($index | ForEach-Object Area | Select-Object -Unique)
    Add-Area 'smoke' 'always'
    if ($mode -eq 'merge') { foreach ($a in $MergeE2EAreas) { Add-Area $a 'every merge' } }
    foreach ($s in (Get-WpSuites)) { Add-Area $s.Area 'WP suite' }
    if ($mode -eq 'merge') {
        $covers = @($specs | ForEach-Object { @($_.Data['covers']) } | Where-Object { $_ })
        if ($covers.Count) {
            foreach ($s in $index) { if (@($s.Tags.Covers | Where-Object { $covers -contains $_ }).Count) { Add-Area $s.Area 'covers tag' } }
        }
        foreach ($f in $changed) {
            if ($f.Path -match '^test/e2e/suites/([^/]+)/') { Add-Area $Matches[1] 'changed suite' }
            elseif ($f.Path -match '^test/e2e/(?:[^/]+\.psm1|run\.ps1)$') { Add-Area '_selftest' 'harness changed' }
            elseif ($f.Path -match '^src/apprt/win32/features/([^/]+)/' -and $existingAreas -contains $Matches[1]) { Add-Area $Matches[1] 'changed feature' }
        }
    }
    $areas = @($why.Keys | Where-Object { $existingAreas -contains $_ })
    $missing = @($why.Keys | Where-Object { $existingAreas -notcontains $_ })
    $desc = @($areas | ForEach-Object { "$_ ($($why[$_] -join ', '))" })
    return [pscustomobject]@{ Areas = $areas; Missing = $missing; Desc = $desc }
}

function Get-E2EBinaryArgs($Params) {
    # Test the wmux.exe this gate's build step produced (run.ps1 -Exe); let run.ps1 build it
    # (-Build Debug) only when the build step does not run in this invocation.
    $built = if ($DryRun) { Test-StepSelected 'build' }
    else { $script:results.Contains('build') -and $script:results['build'].Result -eq 'PASS' }
    if ($built -and $Params.ContainsKey('exe')) { return @('-Exe', (Join-Path $repo 'zig-out\bin\wmux.exe')) }
    if ($Params.ContainsKey('build')) { return @('-Build', 'Debug') }
    return @()
}

function Get-E2ERun {
    # One run.ps1 invocation: { Label, Extra, Args, Missing } ($null Args when nothing to run).
    $run = Join-Path $repo 'test/e2e/run.ps1'
    $params = Get-WmuxScriptParameters -Path $run
    $common = @('-NoProfile', '-NonInteractive', '-File', $run)
    $extra = @(Get-E2EBinaryArgs $params)
    if ($params.ContainsKey('parallel')) { $extra += @('-Parallel', '4') }
    if ($mode -eq 'full' -or -not $params.ContainsKey('suite')) {
        $label = if ($mode -eq 'full') { 'all suites' } else { 'all suites (run.ps1 has no -Suite)' }
        return [pscustomobject]@{ Label = $label; Extra = $extra; Args = ($common + $extra); Missing = @(); Desc = @($label) }
    }
    $plan = Get-E2EPlan
    if ($plan.Areas.Count -eq 0) { return [pscustomobject]@{ Label = 'no suite present'; Extra = @(); Args = $null; Missing = $plan.Missing; Desc = @() } }
    $extra = @('-Suite', ($plan.Areas -join ',')) + $extra
    return [pscustomobject]@{ Label = "suites $($plan.Areas -join ',')"; Extra = $extra; Args = ($common + $extra); Missing = $plan.Missing; Desc = $plan.Desc }
}

function Get-BatchRefs {
    # Resolves the branch of each -Batch id: -BatchRef, else the single wp/<id>[-*] branch.
    $refs = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $wps.Count; $i++) {
        if ($BatchRef.Count) { $refs.Add($BatchRef[$i]); continue }
        $id = $wps[$i]
        $names = @(Split-WmuxLines (Invoke-WmuxGit -RepoRoot $repo -Arguments @('for-each-ref', '--format=%(refname:short)', "refs/heads/wp/$id", "refs/heads/wp/$id-*")).Output)
        # wp/W1-1a-* also matches wp/W1-1a-t-*: keep branches whose id part is exactly $id.
        $names = @($names | Where-Object { $_ -eq "wp/$id" -or ($_.StartsWith("wp/$id-") -and -not ($wps | Where-Object { $_ -ne $id -and $_.StartsWith("$id-") -and $names -contains $_ })) })
        if ($names.Count -ne 1) { throw "cannot pick the branch of ${id}: $(if ($names.Count) { $names -join ', ' } else { 'no wp/' + $id + '[-*] branch' }); pass -BatchRef." }
        $refs.Add($names[0])
    }
    return , $refs.ToArray()
}

# ------------------------------------------------------------------ steps
$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$Id, [string]$Title, [string[]]$Modes, [scriptblock]$Plan, [scriptblock]$Run) {
    $steps.Add([pscustomobject]@{ Id = $Id; Title = $Title; Modes = $Modes; Plan = $Plan; Run = $Run })
}

Add-Step 'batch' 'batch: both WP branches on one base, disjoint changes' @('batch') {
    $refs = try { (Get-BatchRefs) -join ', ' } catch { "<$($_.Exception.Message)>" }
    return "branches $refs on $baseRef; HEAD must contain both; changed paths disjoint outside appends"
} {
    $refs = Get-BatchRefs
    $log = Get-StepLog 'batch'
    $lines = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $baseSha = (Invoke-WmuxGit -RepoRoot $repo -Arguments @('rev-parse', "$baseRef^{commit}")).Output.Trim()
    $sets = @()
    for ($i = 0; $i -lt $wps.Count; $i++) {
        $ref = $refs[$i]
        $mb = (Invoke-WmuxGit -RepoRoot $repo -Arguments @('merge-base', $baseRef, $ref)).Output.Trim()
        if ($mb -ne $baseSha) { $problems.Add("$($wps[$i]) ($ref) is not on the current $baseRef; rebase it first (both gates run on one base)") }
        $inHead = (Invoke-WmuxGit -RepoRoot $repo -Arguments @('merge-base', '--is-ancestor', $ref, 'HEAD') -AllowFailure).ExitCode -eq 0
        if (-not $inHead) { $problems.Add("HEAD does not contain $ref; gate a batch branch: git switch -c batch/$($wps -join '+') $baseRef; git merge --no-ff $($refs -join '; git merge --no-ff ')") }
        $files = @((Get-WmuxChangedFiles -RepoRoot $repo -BaseRef $baseRef -Head $ref).Files | ForEach-Object Path)
        $lines.Add("$($wps[$i]) = $ref, $($files.Count) changed path(s)")
        $sets += , $files
    }
    $appends = @($specs | ForEach-Object { $_.Appends } | ForEach-Object Path)
    $shared = @($sets[0] | Where-Object { $sets[1] -contains $_ })
    foreach ($p in $shared) {
        $ok = ($p -eq $schemaRel) -or @($appends | Where-Object { Test-WmuxGlobMatch -Path $p -Glob $_ }).Count
        if ($ok) { $lines.Add("shared, allowed: $p (appends / merge-time artifact)") }
        else { $problems.Add("both WPs change $p (ownership is not disjoint)") }
    }
    if ($specs.Count -eq 2) {
        foreach ($a in @($specs[0].Owns + $specs[0].Touches)) {
            foreach ($b in @($specs[1].Owns + $specs[1].Touches)) {
                if (Test-WmuxGlobOverlap -A $a.Path -B $b.Path) { $lines.Add("NOTE: spec globs overlap: '$($a.Path)' ($($wps[0])) / '$($b.Path)' ($($wps[1]))") }
            }
        }
    }
    Set-Content -LiteralPath $log -Value (@($lines) + @($problems | ForEach-Object { "ERROR: $_" })) -Encoding utf8
    foreach ($l in $lines) { Write-WmuxLine -Tag $tag -Message $l }
    foreach ($p in $problems) { Write-WmuxLine -Tag $tag -Level ERROR -Message $p }
    if ($problems.Count) { return (New-StepResult FAIL ($problems -join '; ')) }
    return (New-StepResult PASS "$($wps -join ' + ') disjoint on $($baseSha.Substring(0, 10))")
}

Add-Step 'fmt' 'zig fmt --check (changed files)' @('local', 'merge', 'full') {
    $files = @($existing | Where-Object { $_.Path -match '\.(zig|zon)$' })
    if ($files.Count -eq 0) { return 'skip: no changed .zig/.zon files' }
    return "zig fmt --check $($files.Count) file(s): $(($files | Select-Object -First 5 | ForEach-Object Path) -join ' ')$(if ($files.Count -gt 5) { ' ...' })"
} {
    $files = @($existing | Where-Object { $_.Path -match '\.(zig|zon)$' } | ForEach-Object { $_.Path })
    if ($files.Count -eq 0) { return (New-StepResult SKIP 'no changed .zig/.zon files') }
    $bad = 0
    for ($i = 0; $i -lt $files.Count; $i += 40) {
        $batchFiles = @($files[$i..([Math]::Min($i + 39, $files.Count - 1))])
        $res = Invoke-Zig 'fmt' (@('fmt', '--check') + $batchFiles) -Suffix "-$([int]($i / 40))"
        if ($res.ExitCode -ne 0) { $bad++ }
    }
    if ($bad) { return (New-StepResult FAIL "files need zig fmt (listed above); run: zig fmt <file>") }
    return (New-StepResult PASS "$($files.Count) file(s) formatted")
}

Add-Step 'pslint' 'PowerShell parse (changed .ps1/.psm1/.psd1)' @('local', 'merge', 'full') {
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

Add-Step 'ownership' 'scripts/check-ownership.ps1' @('local', 'merge', 'full') {
    if (-not $wps.Count) { return 'skip: no WP id' }
    if ($isBatch) {
        $refs = try { Get-BatchRefs } catch { @('<branch?>', '<branch?>') }
        return (@(for ($i = 0; $i -lt $wps.Count; $i++) { "check-ownership.ps1 -Wp $($wps[$i]) -Head $($refs[$i])" }) -join '; ')
    }
    return "pwsh scripts/check-ownership.ps1 -Wp $($wps[0]) -Base $diffBase"
} {
    if (-not $wps.Count) { return (New-StepResult SKIP 'no WP id (pass -Wp, or run on a wp/<id>-<slug> branch)') }
    $refs = @(if ($isBatch) { Get-BatchRefs } else { 'HEAD' })
    $fails = @(); $missing = @(); $warnTotal = 0
    for ($i = 0; $i -lt $wps.Count; $i++) {
        $id = $wps[$i]
        $argList = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'check-ownership.ps1'), '-Wp', $id, '-Base', $(if ($isBatch) { $baseRef } else { $diffBase }))
        if ($isBatch) { $argList += @('-Head', $refs[$i]) }
        $res = Invoke-Logged -Id 'ownership' -FilePath $pwshExe -Arguments $argList -Suffix $(if ($wps.Count -gt 1) { "-$id" } else { '' })
        $warnTotal += Get-CheckWarnings $res.LogFile
        switch ($res.ExitCode) {
            0 { }
            1 { $fails += "$id paths outside owns/touches/appends" }
            2 { $missing += $id }
            default { $fails += "$id exit code $($res.ExitCode)" }
        }
    }
    if ($missing.Count) {
        $allMissing = @($missing | Where-Object { -not $specErrors.ContainsKey($_) -and -not @($specs | Where-Object Wp -EQ $_).Count })
        if ($AllowMissingSpec -and $allMissing.Count -eq $missing.Count -and -not $fails.Count) { return (New-StepResult SKIP "spec missing for $($missing -join ', ') (-AllowMissingSpec)") }
        $fails += "spec missing or invalid: $($missing -join ', ')"
    }
    if ($fails.Count) { return (New-StepResult FAIL "$($fails -join '; ') (see log)") }
    if ($warnTotal) { return (New-StepResult WARN "$warnTotal warning(s)") }
    return (New-StepResult PASS 'all changed paths covered by the spec')
}

Add-Step 'manifest' 'scripts/check-manifest.ps1' @('local', 'merge', 'full') {
    return 'pwsh scripts/check-manifest.ps1'
} {
    $res = Invoke-Logged -Id 'manifest' -FilePath $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'check-manifest.ps1'))
    $warn = Get-CheckWarnings $res.LogFile
    $skeleton = [bool](Select-String -LiteralPath $res.LogFile -Pattern 'skeleton not present yet' -SimpleMatch -Quiet)
    $note = if ($skeleton) { 'skeleton not present yet; ' } else { '' }
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "${note}registry or aggregator errors (see log)") }
    if ($warn) { return (New-StepResult WARN "$note$warn warning(s)") }
    return (New-StepResult PASS "${note}consistent")
}

# Settings schema as a merge-time artifact (AF-15): regenerate on the merged tree, commit.
Add-Step 'schema' 'settings schema: regenerate and commit (merge-time artifact)' @('merge') {
    if ((Get-BuildStepNames) -notcontains 'settings-schema') { return 'skip: build step settings-schema not defined' }
    $how = if ($NoSchemaCommit) { 'report only (-NoSchemaCommit)' } else { "commit 'chore(schema): regenerate the settings schema [$wpLabel]' when it changed" }
    return "zig build settings-schema $($T -join ' '); $how"
} {
    $names = Get-BuildStepNames
    if ($names -contains '<unavailable>') { return (New-StepResult FAIL 'zig build -l failed (see zig-build-steps.log)') }
    if ($names -notcontains 'settings-schema') { return (New-StepResult SKIP 'build step settings-schema not defined') }
    if (Set-WmuxMergeDrivers -RepoRoot $repo) { Write-WmuxLine -Tag $tag -Level NOTE -Message 'defined the merge driver "ours" (git config merge.ours.driver true) for .gitattributes merge=ours.' }
    $res = Invoke-Zig 'schema' (@('build', 'settings-schema') + $T)
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "zig build settings-schema exited $($res.ExitCode)") }
    $st = (Invoke-WmuxGit -RepoRoot $repo -Arguments @('status', '--porcelain', '--', $schemaRel)).Output.Trim()
    if (-not $st) { return (New-StepResult PASS "$schemaRel up to date") }
    Write-Host $st
    if ($NoSchemaCommit) { return (New-StepResult WARN "$schemaRel regenerated but not committed (-NoSchemaCommit)") }
    if (-not $branch) { return (New-StepResult FAIL "$schemaRel changed but HEAD is detached; commit it on a branch") }
    [void](Invoke-WmuxGit -RepoRoot $repo -Arguments @('add', '--', $schemaRel))
    $msg = "chore(schema): regenerate the settings schema [$wpLabel]`n`nMerge-time artifact (AF-15): scripts/gate.ps1 -Merge ran zig build settings-schema on the merged tree."
    $c = Invoke-WmuxGit -RepoRoot $repo -Arguments @('commit', '-q', '-m', $msg, '--', $schemaRel) -AllowFailure
    if ($c.ExitCode -ne 0) { return (New-StepResult FAIL "git commit failed: $($c.Error.Trim())") }
    $sha = (Invoke-WmuxGit -RepoRoot $repo -Arguments @('rev-parse', '--short', 'HEAD')).Output.Trim()
    return (New-StepResult PASS "regenerated and committed $sha chore(schema)")
}

$script:releaseJob = $null
function Start-ReleaseBuild {
    # -Merge: the ReleaseFast build is the longest step; it starts with the debug build and
    # runs beside the remaining steps (the 'release' step waits for it).
    if ($script:releaseJob -or $mode -ne 'merge' -or -not (Test-StepSelected 'release') -or -not $zigExe) { return }
    $script:releaseLog = Join-Path $LogDir 'release-background.log'
    $prefix = Join-Path $repo 'zig-out/release'
    Write-WmuxLine -Tag $tag -Level NOTE -Message "ReleaseFast build started in the background (log $($script:releaseLog))"
    $script:releaseJob = Start-WmuxProcess -FilePath $zigExe -ArgumentList (@('build') + $T + @('-Doptimize=ReleaseFast', '--prefix', $prefix)) `
        -WorkingDirectory $repo -LogFile $script:releaseLog -Environment $childEnv
}

Add-Step 'build' 'zig build (debug)' @('local', 'merge', 'full') {
    $bg = if ($mode -eq 'merge' -and (Test-StepSelected 'release')) { ' (the ReleaseFast build starts beside it)' } else { '' }
    return "zig build $($T -join ' ')$bg"
} {
    Start-ReleaseBuild
    $res = Invoke-Zig 'build' (@('build') + $T)
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "exit code $($res.ExitCode)") }
    return (New-StepResult PASS 'zig-out\bin\wmux.exe')
}

function Complete-Release($Res) {
    if ($Res.ExitCode -ne 0) { return (New-StepResult FAIL "exit code $($Res.ExitCode)") }
    $prefix = Join-Path $repo 'zig-out/release'
    $dll = Join-Path $repo 'zig-out/bin/WebView2Loader.dll'
    if (Test-Path -LiteralPath $dll) { Copy-Item -LiteralPath $dll -Destination (Join-Path $prefix 'bin') -Force }
    return (New-StepResult PASS 'zig-out\release\bin\wmux.exe')
}

Add-Step 'release' 'zig build -Doptimize=ReleaseFast' @('merge', 'full') {
    $how = if ($mode -eq 'merge') { ' (background, joined here)' } else { '' }
    return "zig build $($T -join ' ') -Doptimize=ReleaseFast --prefix zig-out\release$how"
} {
    if ($mode -eq 'merge') {
        if (-not $script:releaseJob) { Start-ReleaseBuild }
        if ($script:releaseJob) {
            $res = Wait-WmuxProcess -Handle $script:releaseJob -TimeoutSec 1800
            $script:releaseJob = $null
            $script:releaseSeconds = [int]$res.Duration.TotalSeconds
            Write-WmuxLine -Tag $tag -Message "background ReleaseFast build took $($script:releaseSeconds) s"
            if ($res.ExitCode -ne 0) { Get-Content -LiteralPath $res.LogFile -Tail 40 | ForEach-Object { Write-Host $_ } }
            $r = Complete-Release $res
            $r.Notes = "$($r.Notes) (background, $($script:releaseSeconds) s wall)"
            return $r
        }
    }
    $prefix = Join-Path $repo 'zig-out/release'
    return (Complete-Release (Invoke-Zig 'release' (@('build') + $T + @('-Doptimize=ReleaseFast', '--prefix', $prefix))))
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
Add-Step 'test-fast' 'zig build test-fast' @('local', 'merge', 'full') $optionalTestPlan $optionalTestRun
Add-Step 'test-cli' 'zig build test-cli' @('local', 'merge', 'full') $optionalTestPlan $optionalTestRun

Add-Step 'unit' 'zig build test -Dtest-filter=...' @('local', 'merge', 'full') {
    $plan = Get-UnitPlan
    if ($plan.Filters.Count -eq 0) { return "skip: $($plan.Reason)" }
    $how = if ($SplitFilters) { 'one compile per filter' } else { 'one compile' }
    return "filters [$(($plan.Filters | ForEach-Object { "'$_'" }) -join ', ')] ($($plan.Reason); $how)"
} {
    $plan = Get-UnitPlan
    if ($plan.Filters.Count -eq 0) { return (New-StepResult SKIP $plan.Reason) }
    $src = Join-Path $repo 'src'
    $empty = @()
    if ($mode -ne 'full' -and -not $UnitFilter) {
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

Add-Step 'e2e' 'test/e2e/run.ps1' @('local', 'merge', 'full') {
    if (-not (Test-Path -LiteralPath (Join-Path $repo 'test/e2e/run.ps1'))) { return 'skip: test/e2e/run.ps1 not present yet (W0-B harness)' }
    $r = Get-E2ERun
    $missing = if ($r.Missing.Count) { "; not present yet, skipped: $($r.Missing -join ', ')" } else { '' }
    if (-not $r.Args) { return "skip: no suite present$missing" }
    return "run.ps1 $($r.Extra -join ' ') [$($r.Desc -join '; ')]$missing"
} {
    if (-not (Test-Path -LiteralPath (Join-Path $repo 'test/e2e/run.ps1'))) { return (New-StepResult SKIP 'test/e2e/run.ps1 not present yet (W0-B harness)') }
    if ($script:results.Contains('build') -and $script:results['build'].Result -eq 'FAIL') { return (New-StepResult SKIP 'debug build failed') }
    $r = Get-E2ERun
    $missingNote = if ($r.Missing.Count) { "; suites not present yet (skipped): $($r.Missing -join ', ')" } else { '' }
    foreach ($m in $r.Missing) { Write-WmuxLine -Tag $tag -Level SKIP -Message "e2e area '$m' has no suite yet (test/e2e/suites/$m/); skipped" }
    if (-not $r.Args) { return (New-StepResult SKIP "no suite present$missingNote") }
    $res = Invoke-Logged -Id 'e2e' -FilePath $pwshExe -Arguments $r.Args -TimeoutSec $E2ETimeoutSec
    $wpNote = ''
    $coversIds = @($specs | ForEach-Object { @($_.Data['covers']) } | Where-Object { $_ })
    if ($mode -ne 'full' -and $wps.Count -and $coversIds.Count -and (Get-WpSuites).Count -eq 0) {
        $wpNote = "no $($wps -join '/')*.e2e.ps1 suite (ADR-12.5 expects one per feature WP); "
    }
    if ($res.TimedOut) { return (New-StepResult FAIL "$wpNote$($r.Label) timed out after $E2ETimeoutSec s$missingNote") }
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "$wpNote$($r.Label) failed (exit $($res.ExitCode))$missingNote") }
    if ($wpNote) { return (New-StepResult WARN "$wpNote$($r.Label) passed$missingNote") }
    return (New-StepResult PASS "$($r.Label)$missingNote")
}

# Headless web-panel harness (PB-web-harness): src/web and test/web changes, every -Full.
function Get-WebPlan {
    $script = Join-Path $repo 'test/web/run.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { return [pscustomobject]@{ Run = $false; Why = 'test/web/run.ps1 not present yet (PB-web-harness)' } }
    if ($mode -eq 'full') { return [pscustomobject]@{ Run = $true; Why = 'every -Full' } }
    $hits = @($changed | Where-Object { $_.Path -match '^(src/web|test/web)/' })
    if ($hits.Count -eq 0) { return [pscustomobject]@{ Run = $false; Why = 'nothing under src/web or test/web changed' } }
    return [pscustomobject]@{ Run = $true; Why = "$($hits.Count) path(s) under src/web or test/web changed" }
}

Add-Step 'web' 'test/web/run.ps1 (headless web panels)' @('local', 'merge', 'full') {
    $p = Get-WebPlan
    if (-not $p.Run) { return "skip: $($p.Why)" }
    return "pwsh test/web/run.ps1 ($($p.Why))"
} {
    $p = Get-WebPlan
    if (-not $p.Run) { return (New-StepResult SKIP $p.Why) }
    $res = Invoke-Logged -Id 'web' -FilePath $pwshExe -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repo 'test/web/run.ps1')) -TimeoutSec 900
    if ($res.TimedOut) { return (New-StepResult FAIL 'test/web/run.ps1 timed out after 900 s') }
    if ($res.ExitCode -ne 0) { return (New-StepResult FAIL "test/web/run.ps1 exited $($res.ExitCode)") }
    return (New-StepResult PASS $p.Why)
}

function Test-SchemaGoldenTracked {
    return ((Invoke-WmuxGit -RepoRoot $repo -Arguments @('ls-files', '--error-unmatch', '--', $schemaRel) -AllowFailure).ExitCode -eq 0)
}

Add-Step 'contract' 'contract checks' @('merge', 'full') {
    $parts = @()
    if ($mode -eq 'full' -and (Get-BuildStepNames) -contains 'settings-schema') {
        $parts += if (Test-SchemaGoldenTracked) { 'settings-schema golden' } else { "settings-schema golden skipped ($schemaRel not committed yet)" }
    }
    if (Test-Path -LiteralPath (Join-Path $repo 'test/cli/probes.ps1')) { $parts += 'test/cli/probes.ps1' }
    $parts += @(Get-ChildItem -LiteralPath (Join-Path $repo 'test/contract') -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { "test/contract/$($_.Name)" })
    if ($parts.Count -eq 0) { return 'skip: no contract checks present yet' }
    return ($parts -join ', ')
} {
    $ran = @(); $failedChecks = @(); $notes = @()
    if ($mode -eq 'full') {
        # The schema golden is checked at wave ends; -Merge regenerates it in the schema step.
        $names = Get-BuildStepNames
        if ($names -contains 'settings-schema') {
            if (-not (Test-SchemaGoldenTracked)) {
                $notes += "settings-schema golden skipped: $schemaRel is not committed yet"
            } else {
                $ran += 'settings-schema'
                $res = Invoke-Zig 'contract' (@('build', 'settings-schema') + $T) -Suffix '-schema'
                if ($res.ExitCode -ne 0) { $failedChecks += 'settings-schema (build step failed)' }
                else {
                    $st = Invoke-WmuxGit -RepoRoot $repo -Arguments @('status', '--porcelain', '--', 'docs/wmux/schema')
                    if ($st.Output.Trim()) {
                        Write-Host $st.Output
                        $failedChecks += 'settings-schema (docs/wmux/schema differs from the committed golden; a merge skipped gate.ps1 -Merge)'
                    }
                }
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
    if ($ran.Count -eq 0) {
        $why = if ($notes.Count) { $notes -join '; ' } else { 'no contract checks present yet (test/cli/probes.ps1, test/contract/*.ps1)' }
        return (New-StepResult SKIP $why)
    }
    if ($failedChecks.Count) { return (New-StepResult FAIL ($failedChecks -join '; ')) }
    return (New-StepResult PASS ((@($ran) + @($notes)) -join ', '))
}

Add-Step 'fulltest' 'zig build test (unfiltered) vs test/known-failures.txt' @('fulltest') {
    return "zig build test $($T -join ' ') --summary all  (allowlist: test/known-failures.txt)"
} {
    $kfPath = Join-Path $repo 'test/known-failures.txt'
    $known = Read-WmuxKnownFailures -Path $kfPath
    # --summary all prints the "Build Summary: ... N/M tests passed" line on success too.
    $res = Invoke-Zig 'fulltest' (@('build', 'test') + $T + @('--summary', 'all'))
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
        ($s.Modes -contains $mode) -or ($isBatch -and $s.Modes -contains 'batch') -or ($runFullTest -and $s.Modes -contains 'fulltest')
    })
$total = $selected.Count
$tierName = if ($isBatch) { 'batch (merge tier)' } else { $mode }
$budgetNote = if ($BudgetSec -gt 0) { ('budget {0}:{1:D2}' -f [int][Math]::Floor($BudgetSec / 60), ($BudgetSec % 60)) } else { 'no budget' }
Write-WmuxLine -Tag $tag -Message "tier plan: $tierName -> $(($selected | ForEach-Object Id) -join ', ') ($budgetNote)"
$stopped = $false
$gateTimer = [System.Diagnostics.Stopwatch]::StartNew()
try {
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
        $seconds = [int]$elapsed.TotalSeconds
        if ($s.Id -eq 'release' -and (Get-Variable -Name releaseSeconds -Scope Script -ErrorAction SilentlyContinue)) { $wall = $script:releaseSeconds } else { $wall = $seconds }
        $script:results[$s.Id] = [pscustomobject]@{ Id = $s.Id; Title = $s.Title; Result = $r.Result; Seconds = $seconds; WallSeconds = $wall; Notes = $r.Notes }
    }
} finally {
    # A background ReleaseFast build never outlives the gate (Ctrl+C, FailFast, -Skip release).
    if ($script:releaseJob) {
        Stop-WmuxProcessTree -ProcessId $script:releaseJob.Process.Id
        [void](Wait-WmuxProcess -Handle $script:releaseJob -TimeoutSec 30)
        $script:releaseJob = $null
    }
}
$gateTimer.Stop()

# ------------------------------------------------------------------ summary
$rows = @($script:results.Values)
$failedCount = @($rows | Where-Object Result -EQ 'FAIL').Count
$skipCount = @($rows | Where-Object Result -EQ 'SKIP').Count
$warnCount = @($rows | Where-Object Result -EQ 'WARN').Count
$totalSeconds = [int]$gateTimer.Elapsed.TotalSeconds
$withinBudget = ($BudgetSec -le 0) -or ($totalSeconds -le $BudgetSec)
Write-Host ''
Write-Host ("==== gate summary: {0} {1} @ {2} ====" -f $tierName, $wpLabel, $changes.Head.Substring(0, 10))
Write-Host ('{0,-10} {1,-5} {2,6}  {3}' -f 'step', 'result', 'time', 'notes')
foreach ($row in $rows) {
    $time = if ($row.Seconds -gt 0) { '{0}:{1:D2}' -f [int][Math]::Floor($row.Seconds / 60), ($row.Seconds % 60) } else { '-' }
    $notes = if ($row.Notes.Length -gt 150) { $row.Notes.Substring(0, 147) + '...' } else { $row.Notes }
    Write-Host ('{0,-10} {1,-5} {2,6}  {3}' -f $row.Id, $row.Result, $time, $notes)
}
$verdict = if ($DryRun) { 'DRY RUN (nothing executed)' } elseif ($failedCount) { "GATE FAILED ($failedCount failed, $warnCount warned, $skipCount skipped)" } else { "GATE PASSED ($warnCount warned, $skipCount skipped)" }
Write-Host ("{0} in {1:hh\:mm\:ss}" -f $verdict, $gateTimer.Elapsed)
if (-not $DryRun -and $BudgetSec -gt 0) {
    if ($withinBudget) { Write-WmuxLine -Tag $tag -Level OK -Message "within the $budgetNote ($totalSeconds s)" }
    else { Write-WmuxLine -Tag $tag -Level WARN -Message "over the $budgetNote ($totalSeconds s > $BudgetSec s); see the step durations in summary.json" }
}
if (-not $DryRun) {
    Write-Host "logs: $LogDir"
    $durations = [ordered]@{}
    foreach ($row in $rows) { $durations[$row.Id] = $row.WallSeconds }
    $summaryObj = [ordered]@{
        mode           = $mode
        tier           = $tierName
        wp             = $(if ($wps.Count -eq 1) { $wps[0] } elseif ($wps.Count) { $wps -join '+' } else { $null })
        wps            = @($wps)
        branch         = $branch
        base           = $baseRef
        diff_base      = $diffBase
        merge_base     = $changes.MergeBase
        head           = $changes.Head
        started        = $stamp
        seconds        = $totalSeconds
        budget_seconds = $BudgetSec
        within_budget  = $withinBudget
        passed         = ($failedCount -eq 0)
        durations      = $durations
        steps          = $rows
    }
    $summaryObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LogDir 'summary.json') -Encoding utf8
}
exit ([int]($failedCount -gt 0))
