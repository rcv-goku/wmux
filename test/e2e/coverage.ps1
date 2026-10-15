#Requires -Version 7.0
<#
.SYNOPSIS
    Parity coverage of the e2e suites (ARCHITECTURE.md ADR-12.7, Appendix D.5).

.DESCRIPTION
    Joins the "# covers:" and "# manual:" header tags of test/e2e/suites/**/*.e2e.ps1 with the
    in-scope feature ids of matrix.csv and reports coverage per area, the uncovered critical ids,
    stale tags (ids that are not in the matrix) and tags of ids that exist but are out of scope.

    In-scope ids are the matrix rows whose scope is local-core or local-extended and whose status
    is partial or missing. The matrix is looked up in this order: -Matrix, $env:WMUX_PARITY_MATRIX,
    <repo>\docs\arch\matrix.csv, <repo>\..\research\parity\matrix.csv,
    <repo>\..\..\research\parity\matrix.csv, C:\Users\Rey.ColonValero\claude\research\parity\matrix.csv.
    When no matrix is available, -InScopeIds <file> (a JSON array such as
    research\parity\design\inscope-ids.json, or one id per line) supplies the ids; the area is
    then the id prefix and importance is unknown.

    Header grammar (leading comment block of a suite file; keys are case-insensitive):
        # wp: <wp-id>
        # covers: <id>[, <id> ...]        repeatable; ids separated by commas and/or spaces
        # manual: <id> <reason>            repeatable; the reason may be quoted
    A covered id beats a waiver for the same id. Tags in suites/_quarantine count as covered
    and are listed separately.

    Exit codes: 0 = report produced; 1 = -FailOnStale or -FailOnUncoveredCritical tripped;
    2 = no matrix and no -InScopeIds (unless -TagsOnly), or the suites root is missing.

.PARAMETER TagsOnly
    Only parse the suite headers (no matrix needed). With -PassThru returns one object per file;
    run.ps1 uses this to annotate its JSON output.

.EXAMPLE
    pwsh test/e2e/coverage.ps1
.EXAMPLE
    pwsh test/e2e/coverage.ps1 -Area notifications,cli -Json test-results/coverage.json
.EXAMPLE
    pwsh test/e2e/coverage.ps1 -InScopeIds ..\research\parity\design\inscope-ids.json
#>
[CmdletBinding()]
param(
    [string]$Matrix,
    [string]$InScopeIds,
    [string]$SuitesRoot,
    [string[]]$Area,
    [string]$Json,
    [switch]$TagsOnly,
    [switch]$PassThru,
    [switch]$Quiet,
    [switch]$FailOnStale,
    [switch]$FailOnUncoveredCritical
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
# .NET resolves relative paths against the process directory, not the PowerShell location.
$here = (Get-Location).ProviderPath
if (-not $SuitesRoot) { $SuitesRoot = Join-Path $PSScriptRoot 'suites' }
$SuitesRoot = [IO.Path]::GetFullPath($SuitesRoot, $here)
if ($Matrix) { $Matrix = [IO.Path]::GetFullPath($Matrix, $here) }
if ($InScopeIds) { $InScopeIds = [IO.Path]::GetFullPath($InScopeIds, $here) }

$idPattern = '^[a-z0-9][a-z0-9-]*$'
$inScopeScopes = @('local-core', 'local-extended')
$inScopeStatuses = @('partial', 'missing')

function Write-Report {
    param([string]$Text, [string]$Color)
    if ($Quiet) { return }
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Read-SuiteHeader {
    # Parses the leading comment block of one suite file.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $rel = ([IO.Path]::GetRelativePath($Root, $Path)) -replace '\\', '/'
    $segments = $rel.Split('/')
    $area = if ($segments.Count -gt 1) { $segments[0] } else { '(root)' }
    $wp = $null
    $covers = [System.Collections.Generic.List[string]]::new()
    $manual = [System.Collections.Generic.List[object]]::new()
    $invalid = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [IO.File]::ReadLines($Path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if (-not $t.StartsWith('#')) { break }
        if ($t -notmatch '^#\s*(wp|covers|manual)\s*:\s*(.*)$') { continue }
        $key = $Matches[1].ToLowerInvariant()
        $value = $Matches[2].Trim()
        if ($key -eq 'wp') {
            if (-not $wp -and $value) { $wp = $value }
        } elseif ($key -eq 'covers') {
            foreach ($tok in ($value -split '[,\s]+')) {
                if (-not $tok) { continue }
                if ($tok -cmatch $idPattern) { $covers.Add($tok) } else { $invalid.Add($tok) }
            }
        } elseif ($key -eq 'manual') {
            if ($value -match '^(\S+)\s*(.*)$') {
                $id = $Matches[1].TrimEnd(',')
                $reason = $Matches[2].Trim()
                if ($reason.Length -ge 2 -and (($reason.StartsWith('"') -and $reason.EndsWith('"')) -or ($reason.StartsWith("'") -and $reason.EndsWith("'")))) {
                    $reason = $reason.Substring(1, $reason.Length - 2)
                }
                if ($id -cmatch $idPattern) {
                    $manual.Add([pscustomobject]@{ Id = $id; Reason = $reason })
                } else {
                    $invalid.Add($id)
                }
            }
        }
    }
    [pscustomobject]@{
        Path         = $Path
        RelativePath = $rel
        Area         = $area
        Quarantined  = ($area -eq '_quarantine')
        Wp           = $wp
        Covers       = @($covers | Select-Object -Unique)
        Manual       = @($manual)
        Invalid      = @($invalid)
    }
}

function Get-SuiteTag {
    param([string]$Root)
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.e2e.ps1' |
        Sort-Object FullName |
        ForEach-Object { Read-SuiteHeader -Path $_.FullName -Root $Root }
}

function Find-Matrix {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Matrix) { $candidates.Add($Matrix) }
    if ($env:WMUX_PARITY_MATRIX) { $candidates.Add($env:WMUX_PARITY_MATRIX) }
    $candidates.Add((Join-Path $repoRoot 'docs\arch\matrix.csv'))
    $candidates.Add((Join-Path $repoRoot '..\research\parity\matrix.csv'))
    $candidates.Add((Join-Path $repoRoot '..\..\research\parity\matrix.csv'))
    $candidates.Add('C:\Users\Rey.ColonValero\claude\research\parity\matrix.csv')
    if ($Matrix) {
        # An explicit -Matrix must exist; do not silently fall back.
        if (Test-Path -LiteralPath $Matrix -PathType Leaf) { return [IO.Path]::GetFullPath($Matrix) }
        return $null
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return [IO.Path]::GetFullPath($c) }
    }
    return $null
}

function Get-Percent {
    param([int]$Part, [int]$Total)
    if ($Total -le 0) { return 0.0 }
    return [Math]::Round(100.0 * $Part / $Total, 1)
}

if (-not (Test-Path -LiteralPath $SuitesRoot -PathType Container)) {
    Write-Host "coverage.ps1: suites root not found: $SuitesRoot" -ForegroundColor Red
    exit 2
}

$files = @(Get-SuiteTag -Root $SuitesRoot)

if ($TagsOnly) {
    if (-not $Quiet) {
        foreach ($f in $files) {
            Write-Report ('{0,-48} wp={1,-8} covers={2,-3} manual={3}' -f $f.RelativePath, $f.Wp, $f.Covers.Count, $f.Manual.Count)
        }
    }
    if ($PassThru) { return $files }
    return
}

# ---------------------------------------------------------------------------
# In-scope ids
# ---------------------------------------------------------------------------

$matrixPath = Find-Matrix
$allRows = [ordered]@{}
$inScope = [ordered]@{}
$source = $null
if ($matrixPath) {
    $source = $matrixPath
    foreach ($row in (Import-Csv -LiteralPath $matrixPath)) {
        if (-not $row.id) { continue }
        $allRows[$row.id] = $row
        if ($inScopeScopes -contains $row.scope -and $inScopeStatuses -contains $row.status) {
            $inScope[$row.id] = [pscustomobject]@{ id = $row.id; area = $row.area; name = $row.name; imp = $row.imp; scope = $row.scope; status = $row.status }
        }
    }
}
if ($InScopeIds) {
    if (-not (Test-Path -LiteralPath $InScopeIds -PathType Leaf)) {
        Write-Host "coverage.ps1: -InScopeIds file not found: $InScopeIds" -ForegroundColor Red
        exit 2
    }
    $text = [IO.File]::ReadAllText($InScopeIds).Trim()
    $ids = if ($text.StartsWith('[')) { @(ConvertFrom-Json -InputObject $text) } else { @($text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) }
    $restricted = [ordered]@{}
    foreach ($id in $ids) {
        $id = [string]$id
        if ($allRows.Contains($id)) {
            $row = $allRows[$id]
            $restricted[$id] = [pscustomobject]@{ id = $id; area = $row.area; name = $row.name; imp = $row.imp; scope = $row.scope; status = $row.status }
        } else {
            $prefix = ($id -split '-', 2)[0]
            $restricted[$id] = [pscustomobject]@{ id = $id; area = $prefix; name = $null; imp = $null; scope = $null; status = $null }
        }
    }
    $inScope = $restricted
    $source = if ($matrixPath) { "$InScopeIds (areas from $matrixPath)" } else { $InScopeIds }
}
if ($inScope.Count -eq 0 -and -not $matrixPath -and -not $InScopeIds) {
    Write-Host 'coverage.ps1: matrix.csv not found; pass -Matrix <path> or -InScopeIds <file> (see Get-Help for the lookup order)' -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Join
# ---------------------------------------------------------------------------

$coveredFiles = @{}
$quarantinedIds = [System.Collections.Generic.HashSet[string]]::new()
$waivers = @{}
$stale = [System.Collections.Generic.List[object]]::new()
$outOfScope = [System.Collections.Generic.List[object]]::new()
$invalid = [System.Collections.Generic.List[object]]::new()

function Add-TagCheck {
    param([string]$Id, [string]$Kind, $File)
    if ($inScope.Contains($Id)) { return $true }
    if ($allRows.Contains($Id)) {
        $row = $allRows[$Id]
        $outOfScope.Add([pscustomobject]@{ id = $Id; kind = $Kind; file = $File.RelativePath; scope = $row.scope; status = $row.status })
    } else {
        $stale.Add([pscustomobject]@{ id = $Id; kind = $Kind; file = $File.RelativePath })
    }
    return $false
}

foreach ($f in $files) {
    foreach ($bad in $f.Invalid) { $invalid.Add([pscustomobject]@{ tag = $bad; file = $f.RelativePath }) }
    foreach ($id in $f.Covers) {
        if (-not (Add-TagCheck -Id $id -Kind 'covers' -File $f)) { continue }
        if (-not $coveredFiles.ContainsKey($id)) { $coveredFiles[$id] = [System.Collections.Generic.List[string]]::new() }
        $coveredFiles[$id].Add($f.RelativePath)
        if ($f.Quarantined) { $null = $quarantinedIds.Add($id) }
    }
    foreach ($m in $f.Manual) {
        if (-not (Add-TagCheck -Id $m.Id -Kind 'manual' -File $f)) { continue }
        if (-not $waivers.ContainsKey($m.Id)) { $waivers[$m.Id] = [System.Collections.Generic.List[object]]::new() }
        $waivers[$m.Id].Add([pscustomobject]@{ file = $f.RelativePath; reason = $m.Reason })
    }
}

$areaNames = @($inScope.Values | ForEach-Object { $_.area } | Select-Object -Unique | Sort-Object)
if ($Area) { $areaNames = @($areaNames | Where-Object { $a = $_; @($Area | Where-Object { $a -like $_ }).Count -gt 0 }) }

$areaRows = foreach ($an in $areaNames) {
    $ids = @($inScope.Values | Where-Object { $_.area -eq $an })
    $cov = @($ids | Where-Object { $coveredFiles.ContainsKey($_.id) })
    $wai = @($ids | Where-Object { -not $coveredFiles.ContainsKey($_.id) -and $waivers.ContainsKey($_.id) })
    $unc = @($ids | Where-Object { -not $coveredFiles.ContainsKey($_.id) -and -not $waivers.ContainsKey($_.id) })
    $crit = @($ids | Where-Object { $_.imp -eq 'critical' })
    $critUnc = @($unc | Where-Object { $_.imp -eq 'critical' })
    [pscustomobject]@{
        area                  = $an
        in_scope              = $ids.Count
        covered               = $cov.Count
        waived                = $wai.Count
        uncovered             = $unc.Count
        covered_pct           = Get-Percent $cov.Count $ids.Count
        covered_or_waived_pct = Get-Percent ($cov.Count + $wai.Count) $ids.Count
        critical              = $crit.Count
        critical_uncovered    = $critUnc.Count
    }
}
$areaRows = @($areaRows)

$selected = @($inScope.Values | Where-Object { $areaNames -contains $_.area })
$uncoveredCritical = @($selected | Where-Object { $_.imp -eq 'critical' -and -not $coveredFiles.ContainsKey($_.id) -and -not $waivers.ContainsKey($_.id) } |
        ForEach-Object { [pscustomobject]@{ id = $_.id; area = $_.area; name = $_.name } })

$totalIn = ($areaRows | Measure-Object -Property in_scope -Sum).Sum
$totalCov = ($areaRows | Measure-Object -Property covered -Sum).Sum
$totalWai = ($areaRows | Measure-Object -Property waived -Sum).Sum
$totalUnc = ($areaRows | Measure-Object -Property uncovered -Sum).Sum
$totalCrit = ($areaRows | Measure-Object -Property critical -Sum).Sum
if ($null -eq $totalIn) { $totalIn = 0; $totalCov = 0; $totalWai = 0; $totalUnc = 0; $totalCrit = 0 }

$report = [pscustomobject]@{
    schema             = 'wmux-e2e-coverage/1'
    generated_at       = [DateTime]::UtcNow.ToString('o')
    in_scope_source    = $source
    suites_root        = $SuitesRoot
    areas_filter       = $Area
    totals             = [pscustomobject]@{
        in_scope              = [int]$totalIn
        covered               = [int]$totalCov
        waived                = [int]$totalWai
        uncovered             = [int]$totalUnc
        covered_pct           = Get-Percent $totalCov $totalIn
        covered_or_waived_pct = Get-Percent ($totalCov + $totalWai) $totalIn
        critical              = [int]$totalCrit
        critical_uncovered    = $uncoveredCritical.Count
    }
    areas              = $areaRows
    uncovered_critical = $uncoveredCritical
    stale_tags         = @($stale)
    out_of_scope_tags  = @($outOfScope)
    invalid_tags       = @($invalid)
    quarantined_ids    = @($quarantinedIds | Sort-Object)
    covered            = @($coveredFiles.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ id = $_; files = @($coveredFiles[$_]) } })
    waived             = @($waivers.Keys | Sort-Object | Where-Object { -not $coveredFiles.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ id = $_; files = @($waivers[$_] | ForEach-Object { $_.file }); reasons = @($waivers[$_] | ForEach-Object { $_.reason }) } })
    files              = @($files | ForEach-Object { [pscustomobject]@{ path = $_.RelativePath; area = $_.Area; wp = $_.Wp; covers = $_.Covers; manual = @($_.Manual | ForEach-Object { [pscustomobject]@{ id = $_.Id; reason = $_.Reason } }) } })
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

Write-Report "e2e parity coverage"
Write-Report "  in-scope ids: $source"
Write-Report "  suites:       $SuitesRoot ($($files.Count) files)"
Write-Report ''
Write-Report ('{0,-15} {1,9} {2,8} {3,7} {4,10} {5,9} {6,14}' -f 'area', 'in-scope', 'covered', 'waived', 'uncovered', 'coverage', 'crit-uncovered')
foreach ($r in $areaRows) {
    Write-Report ('{0,-15} {1,9} {2,8} {3,7} {4,10} {5,8}% {6,14}' -f $r.area, $r.in_scope, $r.covered, $r.waived, $r.uncovered, $r.covered_pct, $r.critical_uncovered)
}
$t = $report.totals
Write-Report ('{0,-15} {1,9} {2,8} {3,7} {4,10} {5,8}% {6,14}' -f 'total', $t.in_scope, $t.covered, $t.waived, $t.uncovered, $t.covered_pct, $t.critical_uncovered)
Write-Report ''
if ($uncoveredCritical.Count -gt 0) {
    Write-Report "Uncovered critical ids ($($uncoveredCritical.Count)):" 'Yellow'
    foreach ($u in $uncoveredCritical) { Write-Report ('  {0,-48} {1}' -f $u.id, $u.name) }
    Write-Report ''
}
if ($stale.Count -gt 0) {
    Write-Report "Stale tags, ids not in the matrix ($($stale.Count)):" 'Red'
    foreach ($s in $stale) { Write-Report ('  {0,-48} {1} in {2}' -f $s.id, $s.kind, $s.file) }
    Write-Report ''
}
if ($outOfScope.Count -gt 0) {
    Write-Report "Tags of ids outside the in-scope set ($($outOfScope.Count)):" 'DarkYellow'
    foreach ($o in $outOfScope) { Write-Report ('  {0,-48} {1} in {2} (scope={3}, status={4})' -f $o.id, $o.kind, $o.file, $o.scope, $o.status) }
    Write-Report ''
}
if ($invalid.Count -gt 0) {
    Write-Report "Malformed tags ($($invalid.Count)):" 'Red'
    foreach ($i in $invalid) { Write-Report ('  {0,-48} in {1}' -f $i.tag, $i.file) }
    Write-Report ''
}

if ($Json) {
    $jsonPath = [IO.Path]::GetFullPath($Json, $here)
    $dir = Split-Path -Parent $jsonPath
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $report -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Report "wrote $jsonPath"
}

$exitCode = 0
if ($FailOnStale -and ($stale.Count -gt 0 -or $invalid.Count -gt 0)) { $exitCode = 1 }
if ($FailOnUncoveredCritical -and $uncoveredCritical.Count -gt 0) { $exitCode = 1 }

if ($PassThru) { $report }
if ($exitCode -ne 0) { exit $exitCode }
