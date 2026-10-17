#Requires -Version 7.0
<#
.SYNOPSIS
    Renders WP specs docs/arch/wp/<arch_id>.md from the work-package plan and validates the plan.

.DESCRIPTION
    Wave kickoff tool of the parity program (AF-1, AF-23; ARCHITECTURE section 14.1 and
    Appendix H). Reads docs/arch/plan/WORKPACKAGES.json, selects the work packages of the
    given plan waves (or ids), validates them and writes one spec per WP:

      owns     = files_new + the files_touched that are not frozen
      touches  = the plan's touches entries (path + reason)
      appends  = the plan's appends (shared-appendable files)
      wave     = the architecture wave (W1 -> 1, W5a -> 5a); depends = the arch ids of
                 depends_on; covers = features; Design notes / Tests / Done when from the
                 summary and acceptance lines.

    Validation errors (nothing is written when any is found):
      - placeholder: a path or reason holding <...>, TBD, TODO, FIXME, XXX, ..., ${...} or
        {{...}}, an empty path or title, or an arch_id that is not a WP id;
      - a files_new path (or glob) of a planned WP that already exists in -RepoRoot;
      - a frozen path (ADR-1.7 + plan note 6, see scripts/lib/WmuxTooling.psm1) in files_new
        or files_touched without a touches entry (a frozen shared-appendable file listed in
        appends is fine: a declared append);
      - two WPs of one plan wave touching the same path (glob-aware) outside appends;
      - an existing spec file (unless -Force), or an arch_id listed twice.
    Warnings: a files_touched path that neither exists nor is created by files_new of an
    earlier-wave WP (or the WP itself), and depends_on ids missing from the plan.

.PARAMETER Plan
    The plan file (default docs/arch/plan/WORKPACKAGES.json of this checkout).

.PARAMETER Wave
    Plan waves to render (e.g. 10,11,12,13,19 for W1). Comma strings work.

.PARAMETER Wp
    Arch ids to render (instead of, or in addition to, -Wave).

.PARAMETER OutDir
    Where specs go (default docs/arch/wp of this checkout). Use a temporary directory to
    preview a wave without touching the tree.

.PARAMETER RepoRoot
    Tree the files_new / files_touched paths are checked against (default: this checkout).

.PARAMETER Force
    Overwrite spec files that already exist in -OutDir.

.PARAMETER Check
    Validate only; write nothing.

.PARAMETER IncludeDone
    Also render WPs whose status is done or in_progress (skipped by default: their specs are
    written by hand or exist already, and their files_new exist by design).

.PARAMETER AllowExisting
    Report a files_new path that already exists as a warning instead of an error and render
    it as owned (plan drift: an earlier lane created the file; the wave kickoff fixes the plan).
    The spec's Design notes list such paths.

.EXAMPLE
    pwsh scripts/new-wp-specs.ps1 -Plan docs/arch/plan/WORKPACKAGES.json -Wave 10,11,12,13,19 -OutDir $env:TEMP\w1-specs

.EXAMPLE
    pwsh scripts/new-wp-specs.ps1 -Wave 21 -Check

.NOTES
    Exit codes: 0 = specs written (or -Check clean), 1 = validation errors, 2 = usage error.
#>
[CmdletBinding()]
param(
    [string]$Plan,
    [string[]]$Wave,
    [string[]]$Wp,
    [string]$OutDir,
    [string]$RepoRoot,
    [switch]$Force,
    [switch]$Check,
    [switch]$IncludeDone,
    [switch]$AllowExisting
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib/WmuxTooling.psm1') -Force

$tag = 'new-wp-specs'
$script:errors = [System.Collections.Generic.List[string]]::new()
$script:warnings = 0

function Exit-Usage([string]$Message) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message $Message
    Write-Host 'new-wp-specs: usage error'
    exit 2
}
function Add-PlanError([string]$Message) { $script:errors.Add($Message); Write-WmuxLine -Tag $tag -Level ERROR -Message $Message }
function Add-PlanWarning([string]$Message) { $script:warnings++; Write-WmuxLine -Tag $tag -Level WARN -Message $Message }

# ------------------------------------------------------------------ inputs
$scriptRepo = Split-Path $PSScriptRoot -Parent
$RepoRoot = if ($RepoRoot) { Resolve-WmuxPath $RepoRoot } else { $scriptRepo }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Exit-Usage "-RepoRoot '$RepoRoot' does not exist." }
$Plan = if ($Plan) { Resolve-WmuxPath $Plan } else { Join-Path $scriptRepo 'docs/arch/plan/WORKPACKAGES.json' }
if (-not (Test-Path -LiteralPath $Plan -PathType Leaf)) {
    # A relative -Plan is also tried against the repo root (the documented form).
    $alt = Join-Path $scriptRepo $Plan
    if (Test-Path -LiteralPath $alt -PathType Leaf) { $Plan = $alt } else { Exit-Usage "plan '$Plan' not found." }
}
$OutDir = if ($OutDir) { Resolve-WmuxPath $OutDir } else { Join-Path $scriptRepo 'docs/arch/wp' }
$Wave = @($Wave | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Wp = @($Wp | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Wave.Count -eq 0 -and $Wp.Count -eq 0) { Exit-Usage 'pass -Wave <plan waves> and/or -Wp <arch ids>.' }
$waveNums = foreach ($w in $Wave) {
    if ($w -notmatch '^\d+$') { Exit-Usage "-Wave '$w' is not a plan wave number." }
    [int]$w
}

try {
    $planObj = [System.IO.File]::ReadAllText($Plan) | ConvertFrom-Json -Depth 32
} catch {
    Exit-Usage "cannot parse '$Plan': $($_.Exception.Message)"
}
if (-not $planObj.PSObject.Properties['work_packages']) { Exit-Usage "'$Plan' has no work_packages array." }
$all = @($planObj.work_packages)
$planRel = if ($Plan.StartsWith($scriptRepo, [System.StringComparison]::OrdinalIgnoreCase)) { [System.IO.Path]::GetRelativePath($scriptRepo, $Plan).Replace('\', '/') } else { $Plan }

function Get-Field($Obj, [string]$Name) {
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Get-List($Obj, [string]$Name) { return , @(@(Get-Field $Obj $Name) | Where-Object { $null -ne $_ }) }
function Get-TouchList($Obj) {
    # touches entries are { path, reason } objects (a bare string is accepted with no reason).
    $out = foreach ($t in (Get-List $Obj 'touches')) {
        if ($t -is [string]) { [pscustomobject]@{ Path = $t; Reason = '' } }
        else { [pscustomobject]@{ Path = [string](Get-Field $t 'path'); Reason = [string](Get-Field $t 'reason') } }
    }
    return , @($out)
}

$byPlanId = @{}
foreach ($w in $all) { $byPlanId[[string](Get-Field $w 'id')] = $w }
foreach ($dup in @($all | Group-Object { [string](Get-Field $_ 'arch_id') } | Where-Object { $_.Count -gt 1 -and $_.Name })) {
    Add-PlanError "arch_id '$($dup.Name)' is used by $($dup.Count) work packages ($(($dup.Group | ForEach-Object { Get-Field $_ 'id' }) -join ', '))."
}

$selected = @($all | Where-Object {
        $aw = [string](Get-Field $_ 'arch_id')
        $inWave = $waveNums -contains [int](Get-Field $_ 'wave')
        $inWp = $Wp -contains $aw
        ($inWave -or $inWp)
    })
foreach ($id in $Wp) {
    if (-not @($all | Where-Object { (Get-Field $_ 'arch_id') -eq $id }).Count) { Add-PlanError "-Wp '$id' is not an arch_id of the plan." }
}
$skipped = @($selected | Where-Object { -not $IncludeDone -and (Get-Field $_ 'status') -in @('done', 'in_progress') })
$selected = @($selected | Where-Object { $IncludeDone -or (Get-Field $_ 'status') -notin @('done', 'in_progress') })
foreach ($s in $skipped) { Write-WmuxLine -Tag $tag -Level SKIP -Message "$(Get-Field $s 'arch_id') ($(Get-Field $s 'id')) is $(Get-Field $s 'status'); not rendered (-IncludeDone renders it)" }
Write-WmuxLine -Tag $tag -Message "plan: $planRel ($($all.Count) work packages); selected $($selected.Count) WP(s) of wave(s) $(if ($waveNums) { $waveNums -join ',' } else { '-' })$(if ($Wp) { " + ids $($Wp -join ',')" }); out: $OutDir"

# ------------------------------------------------------------------ tree index
$isGit = $false
try { $isGit = ((Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure).Output.Trim() -eq 'true') } catch { $isGit = $false }
if ($isGit) {
    $topLevel = [System.IO.Path]::GetFullPath((Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--show-toplevel')).Output.Trim())
    $treeFiles = @(Split-WmuxLines (Invoke-WmuxGit -RepoRoot $topLevel -Arguments @('ls-files', '--cached', '--others', '--exclude-standard')).Output)
    $RepoRoot = $topLevel
} else {
    $treeFiles = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](?:\.git|\.zig-cache|zig-cache|zig-out|node_modules)[\\/]' } |
            ForEach-Object { [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/') })
}
$treeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$treeFiles, [System.StringComparer]::OrdinalIgnoreCase)

function Test-InTree([string]$PathOrGlob) {
    $p = $PathOrGlob.Trim().Replace('\', '/').TrimStart('/')
    if (-not (Test-WmuxGlobPattern $p)) {
        if ($treeSet.Contains($p)) { return $true }
        return (Test-Path -LiteralPath (Join-Path $RepoRoot $p))
    }
    foreach ($f in $treeFiles) { if (Test-WmuxGlobMatch -Path $f -Glob $p) { return $true } }
    return $false
}

$frozenGlobs = Get-WmuxFrozenGlobs
function Test-Frozen([string]$PathOrGlob) {
    foreach ($g in $frozenGlobs) { if (Test-WmuxGlobOverlap -A $PathOrGlob -B $g) { return $true } }
    return $false
}

# ------------------------------------------------------------------ validation
$placeholder = '<[^>]*>|\bTBD\b|\bTODO\b|\bFIXME\b|\bXXX\b|\.\.\.|\$\{|\{\{|\?\?\?'
$titlePlaceholder = '\bTBD\b|\bTODO\b|\bFIXME\b|\bXXX\b|\?\?\?'
$records = [System.Collections.Generic.List[object]]::new()
$drift = [System.Collections.Generic.List[string]]::new()
foreach ($w in $selected) {
    $planId = [string](Get-Field $w 'id')
    $archId = [string](Get-Field $w 'arch_id')
    $where = "$archId ($planId)"
    if (-not (Test-WmuxWpId $archId)) { Add-PlanError "${where}: arch_id '$archId' is not a WP id." }
    $title = [string](Get-Field $w 'title')
    # Titles may quote CLI syntax (`cmux <path>`): only the word placeholders count there.
    if (-not $title.Trim() -or $title -cmatch $titlePlaceholder) { Add-PlanError "${where}: placeholder or empty title '$title'." }
    $filesNew = Get-List $w 'files_new'
    $filesTouched = Get-List $w 'files_touched'
    $touches = Get-TouchList $w
    $appends = Get-List $w 'appends'
    foreach ($pair in @(@('files_new', $filesNew), @('files_touched', $filesTouched), @('appends', $appends), @('touches', @($touches | ForEach-Object Path)))) {
        foreach ($p in $pair[1]) {
            if (-not ([string]$p).Trim()) { Add-PlanError "${where}: empty path in $($pair[0])." }
            elseif ($p -cmatch $placeholder) { Add-PlanError "${where}: placeholder path in $($pair[0]): '$p'." }
        }
    }
    foreach ($t in $touches) {
        if (-not $t.Reason.Trim()) { Add-PlanError "${where}: touches entry '$($t.Path)' has no reason." }
        elseif ($t.Reason -cmatch $placeholder) { Add-PlanError "${where}: placeholder reason for touches '$($t.Path)': '$($t.Reason)'." }
    }
    $status = [string](Get-Field $w 'status')
    if ($status -notin @('done', 'in_progress')) {
        foreach ($p in $filesNew) {
            if ($p -and $p -cnotmatch $placeholder -and (Test-InTree $p)) {
                $msg = "${where}: files_new path '$p' already exists in the tree (move it to files_touched in the plan, or drop it)."
                if ($AllowExisting) { Add-PlanWarning "$msg Rendered as owned (-AllowExisting)."; $drift.Add("$($archId)|$p") }
                else { Add-PlanError $msg }
            }
        }
    }
    $touchPaths = @($touches | ForEach-Object Path)
    $owns = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $filesNew) {
        if (Test-Frozen $p) {
            if (-not @($touchPaths | Where-Object { Test-WmuxGlobOverlap -A $_ -B $p }).Count) { Add-PlanError "${where}: files_new '$p' is a frozen path without a touches entry." }
            continue
        }
        if (-not $owns.Contains($p)) { $owns.Add($p) }
    }
    foreach ($p in $filesTouched) {
        if (Test-Frozen $p) {
            $declared = @($touchPaths | Where-Object { Test-WmuxGlobOverlap -A $_ -B $p }).Count -or @($appends | Where-Object { $_ -ieq $p }).Count
            if (-not $declared) { Add-PlanError "${where}: files_touched '$p' is a frozen path without a touches entry." }
            continue
        }
        if (@($appends | Where-Object { $_ -ieq $p }).Count) { continue }
        if (-not $owns.Contains($p)) { $owns.Add($p) }
    }
    foreach ($d in (Get-List $w 'depends_on')) {
        if (-not $byPlanId.ContainsKey([string]$d)) { Add-PlanWarning "${where}: depends_on '$d' is not a plan id." }
    }
    $records.Add([pscustomobject]@{
            Wp = $w; PlanId = $planId; ArchId = $archId; Where = $where; Wave = [int](Get-Field $w 'wave')
            FilesNew = $filesNew; FilesTouched = $filesTouched; Touches = $touches; Appends = $appends; Owns = $owns.ToArray()
        })
}

# files_touched must exist or be created earlier in the plan (warning).
foreach ($r in $records) {
    foreach ($p in $r.FilesTouched) {
        if (-not $p -or $p -cmatch $placeholder -or (Test-InTree $p)) { continue }
        $creator = @($all | Where-Object {
                $ww = [int](Get-Field $_ 'wave')
                ($ww -lt $r.Wave -or (Get-Field $_ 'id') -eq $r.PlanId) -and @((Get-List $_ 'files_new') | Where-Object { Test-WmuxGlobOverlap -A $_ -B $p }).Count
            } | Select-Object -First 1)
        if (-not $creator.Count) { Add-PlanWarning "$($r.Where): files_touched '$p' neither exists nor is created by an earlier WP." }
    }
}

# Same plan wave: no shared path outside appends (glob-aware). Checked against every WP of
# each selected wave, rendered or not.
$wavesToCheck = @($records | ForEach-Object Wave | Select-Object -Unique)
foreach ($wn in $wavesToCheck) {
    $members = @($all | Where-Object { [int](Get-Field $_ 'wave') -eq $wn })
    for ($i = 0; $i -lt $members.Count; $i++) {
        for ($j = $i + 1; $j -lt $members.Count; $j++) {
            $a = $members[$i]; $b = $members[$j]
            $aArch = Get-Field $a 'arch_id'; $bArch = Get-Field $b 'arch_id'
            if (-not (@($records | Where-Object { $_.ArchId -in @($aArch, $bArch) }).Count)) { continue }
            $aOwn = @((Get-List $a 'files_new') + (Get-List $a 'files_touched') + @((Get-TouchList $a) | ForEach-Object Path) | Where-Object { $_ } | Select-Object -Unique)
            $bOwn = @((Get-List $b 'files_new') + (Get-List $b 'files_touched') + @((Get-TouchList $b) | ForEach-Object Path) | Where-Object { $_ } | Select-Object -Unique)
            $aApp = Get-List $a 'appends'; $bApp = Get-List $b 'appends'
            # A path both WPs only append to is fine; an append by one and an edit by the other is not.
            $aOwn = @($aOwn | Where-Object { $p = $_; -not @($aApp | Where-Object { $_ -ieq $p }).Count })
            $bOwn = @($bOwn | Where-Object { $p = $_; -not @($bApp | Where-Object { $_ -ieq $p }).Count })
            $hits = [System.Collections.Generic.List[string]]::new()
            foreach ($x in $aOwn) { foreach ($y in @($bOwn) + @($bApp)) { if (Test-WmuxGlobOverlap -A $x -B $y) { $hits.Add("'$x' / '$y'") } } }
            foreach ($y in $bOwn) { foreach ($x in $aApp) { if (Test-WmuxGlobOverlap -A $x -B $y) { $hits.Add("'$x' / '$y'") } } }
            foreach ($h in ($hits | Select-Object -Unique)) {
                Add-PlanError "plan wave ${wn}: $aArch and $bArch both touch $h outside appends."
            }
        }
    }
}

# Existing spec files.
foreach ($r in $records) {
    $target = Join-Path $OutDir "$($r.ArchId).md"
    if ((Test-Path -LiteralPath $target) -and -not $Force -and -not $Check) {
        Add-PlanError "$($r.Where): $target exists (pass -Force to overwrite)."
    }
}

if ($script:errors.Count -gt 0) {
    Write-Host "new-wp-specs: $($script:errors.Count) error(s), $($script:warnings) warning(s); nothing written"
    exit 1
}

# ------------------------------------------------------------------ rendering
function Format-YamlScalar([AllowEmptyString()][string]$Value) {
    # Plain when the parser (and YAML) reads it back verbatim, else double-quoted.
    if ($Value -match '^[A-Za-z0-9_./][^#]*$' -and $Value -notmatch ': |:$|\s$|^(?:null|Null|NULL|~|true|false)$') { return $Value }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Format-Wrapped([string]$Text, [string]$First, [string]$Rest, [int]$Width = 100) {
    $words = @($Text -split '\s+' | Where-Object { $_ })
    $lines = [System.Collections.Generic.List[string]]::new()
    $cur = $First
    $empty = $true
    foreach ($word in $words) {
        if (-not $empty -and ($cur.Length + 1 + $word.Length) -gt $Width) {
            $lines.Add($cur)
            $cur = $Rest + $word
        } else {
            $cur = if ($empty) { $cur + $word } else { "$cur $word" }
        }
        $empty = $false
    }
    $lines.Add($cur)
    return , $lines.ToArray()
}

function ConvertTo-ArchWave([string]$ArchWave) {
    if ($ArchWave -match '^W(\d+[a-z]?)$') { return $Matches[1] }
    return $ArchWave
}

function Format-Comment([string]$Key, [string]$Comment) {
    return ('{0,-28} # {1}' -f $Key, $Comment)
}

$written = 0
if (-not $Check) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
foreach ($r in $records) {
    $w = $r.Wp
    $archWave = [string](Get-Field $w 'arch_wave')
    $size = [string](Get-Field $w 'est_size')
    $deps = @((Get-List $w 'depends_on') | ForEach-Object { if ($byPlanId.ContainsKey([string]$_)) { [string](Get-Field $byPlanId[[string]$_] 'arch_id') } else { [string]$_ } })
    $mergeAfter = @((Get-List $w 'merge_after') | ForEach-Object { if ($byPlanId.ContainsKey([string]$_)) { [string](Get-Field $byPlanId[[string]$_] 'arch_id') } else { [string]$_ } })
    $features = Get-List $w 'features'
    $acceptance = Get-List $w 'acceptance'
    $o = [System.Collections.Generic.List[string]]::new()
    $o.Add('---')
    $o.Add("id: $($r.ArchId)")
    $o.Add("title: $(Format-YamlScalar ([string](Get-Field $w 'title')))")
    $o.Add((Format-Comment "wave: $(ConvertTo-ArchWave $archWave)" "architecture wave $archWave (plan wave $($r.Wave), $($r.PlanId))"))
    $o.Add((Format-Comment "size: $(if ($size) { $size } else { 'M' })" 'S < 1 agent-day, M 1-2, L 2-4 (XL must be split)'))
    $o.Add("depends: [$(($deps | ForEach-Object { Format-YamlScalar $_ }) -join ', ')]")
    if ($features.Count) {
        $o.Add((Format-Comment 'covers:' 'matrix.csv ids; each needs an e2e `# covers:` tag or a `# manual:` waiver'))
        foreach ($f in $features) { $o.Add("  - $(Format-YamlScalar ([string]$f))") }
    } else {
        $o.Add((Format-Comment 'covers: []' 'no matrix.csv feature ids'))
    }
    if ($r.Owns.Count) {
        $o.Add((Format-Comment 'owns:' 'plan files_new + non-frozen files_touched'))
        foreach ($p in $r.Owns) { $o.Add("  - $(Format-YamlScalar $p)") }
    } else {
        $o.Add((Format-Comment 'owns: []' 'plan files_new + non-frozen files_touched'))
    }
    if ($r.Touches.Count) {
        $o.Add((Format-Comment 'touches:' 'frozen/hot paths of the plan entry, with its reasons'))
        foreach ($t in $r.Touches) {
            $o.Add("  - path: $(Format-YamlScalar $t.Path)")
            $o.Add("    reason: $(Format-YamlScalar $t.Reason)")
        }
    } else {
        $o.Add('touches: []')
    }
    if ($r.Appends.Count) {
        $o.Add((Format-Comment 'appends:' 'shared-appendable files: one sorted entry per line'))
        foreach ($p in $r.Appends) { $o.Add("  - $(Format-YamlScalar ([string]$p))") }
    } else {
        $o.Add('appends: []')
    }
    $o.Add((Format-Comment 'apis_needed: []' "other features' api.zig functions (stubbed by the wave interface commit)"))
    $o.Add((Format-Comment 'ccr: []' 'docs/arch/ccr/<wp>-<n>.md'))
    $o.Add((Format-Comment 'deviations: []' 'Appendix E rows requested'))
    $o.Add('---')
    $o.Add('')
    $o.Add("<!-- Generated by scripts/new-wp-specs.ps1 from $planRel ($($r.PlanId)); change the plan and regenerate rather than editing by hand (the WP may update ccr:). -->")
    $o.Add('')
    $o.Add('## Design notes')
    $units = Get-Field $w 'units'
    $exec = [string](Get-Field $w 'executor')
    $o.AddRange([string[]](Format-Wrapped "Plan entry ``$($r.PlanId)`` (``$planRel``), executor $exec, est. size $size$(if ($units) { " ($units units)" })." '- ' '  '))
    $summary = [string](Get-Field $w 'summary')
    if ($summary.Trim()) { $o.AddRange([string[]](Format-Wrapped $summary '- ' '  ')) }
    if ($deps.Count) { $o.AddRange([string[]](Format-Wrapped "Depends on: $($deps -join ', ')." '- ' '  ')) }
    if ($mergeAfter.Count) { $o.AddRange([string[]](Format-Wrapped "Merges after: $($mergeAfter -join ', ') (same plan wave)." '- ' '  ')) }
    $mine = @($drift | Where-Object { $_.StartsWith("$($r.ArchId)|") } | ForEach-Object { $_.Substring($r.ArchId.Length + 1) })
    if ($mine.Count) {
        $tick = [char]0x60
        $mineText = ($mine | ForEach-Object { $tick + $_ + $tick }) -join ', '
        $o.AddRange([string[]](Format-Wrapped "Plan drift: files_new already in the tree (edit, do not create): $mineText." '- ' '  '))
    }
    $derived = Get-List $w 'derived_from'
    if ($derived.Count) { $o.AddRange([string[]](Format-Wrapped "Derived from the old plan ids $($derived -join ', ') (docs/arch/plan/mapping.md)." '- ' '  ')) }
    $o.Add('')
    $o.Add('## Tests')
    $testLines = @($acceptance | Where-Object { $_ -match '^(?:unit|e2e|cli|contract|web)\b' })
    foreach ($a in $testLines) { $o.AddRange([string[]](Format-Wrapped ([string]$a) '- ' '  ')) }
    $o.AddRange([string[]](Format-Wrapped "Standard deliverables (plan note 10): unit tests named ``unit: <module>: ...`` in logic/ files listed in an appendable logic/tests.zig; e2e suite ``test/e2e/suites/<area>/$($r.ArchId).e2e.ps1`` with ``# wp:`` and ``# covers:`` tags for every feature id (or ``# manual:`` waivers backed by a row in docs/arch/manual-checks.md); CLI goldens and offline ``--help``; settings specs (the schema is regenerated at merge)." '- ' '  '))
    $o.Add('')
    $o.Add('## Done when')
    foreach ($a in $acceptance) { $o.AddRange([string[]](Format-Wrapped ([string]$a) '- ' '  ')) }
    $o.AddRange([string[]](Format-Wrapped "``pwsh scripts/gate.ps1 -Wp $($r.ArchId)`` green (legacy-compat suite green, zero focus violations); docs fragment ``docs/wmux/features/<module>/$($r.ArchId).md`` and ``changes/$($r.ArchId).md`` written." '- ' '  '))
    $text = ($o -join "`n") + "`n"

    # The spec must read back through the tooling's own parser (owns/touches/appends intact).
    $parsed = Read-WmuxFrontMatter -Text $text -Source "$($r.ArchId).md"
    $back = @(@($parsed['owns']) | Where-Object { $null -ne $_ })
    if (($back -join "`n") -cne ($r.Owns -join "`n")) { Add-PlanError "$($r.Where): rendered owns do not read back (internal error)." }

    if ($Check) {
        Write-WmuxLine -Tag $tag -Level OK -Message "$($r.ArchId): valid ($($r.Owns.Count) owns, $($r.Touches.Count) touches, $($r.Appends.Count) appends)"
        continue
    }
    $target = Join-Path $OutDir "$($r.ArchId).md"
    [System.IO.File]::WriteAllText($target, $text, [System.Text.UTF8Encoding]::new($false))
    $written++
    Write-WmuxLine -Tag $tag -Level OK -Message "wrote $target ($($r.Owns.Count) owns, $($r.Touches.Count) touches, $($r.Appends.Count) appends)"
}

if ($script:errors.Count -gt 0) {
    Write-Host "new-wp-specs: $($script:errors.Count) error(s), $($script:warnings) warning(s)"
    exit 1
}
$verb = if ($Check) { "validated $($records.Count)" } else { "wrote $written" }
Write-Host "new-wp-specs: $verb spec(s), 0 error(s), $($script:warnings) warning(s)"
exit 0
