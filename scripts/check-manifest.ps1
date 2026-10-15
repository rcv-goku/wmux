#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the feature-module registries, logic test wiring and W0 aliases.

.DESCRIPTION
    Merge-gate check of docs/arch/ARCHITECTURE.md ADR-1.3, ADR-1.4, ADR-1.9 and ADR-12.1.
    Static text analysis only (no build), so it runs in a second.

    Errors (fail):
      - src/apprt/win32/features/<id>/mod.zig exists but is not listed in features/manifest.zig
      - a manifest entry points at a missing features/<id>/mod.zig, or is listed twice
      - a feature has no field in one of the *Ext structs of features/ext.zig, or an ext
        field names no feature directory
      - features/<id>/mod.zig declares `pub const id` different from the directory name
      - features/<id>/state.zig is missing
      - a logic/*.zig file (any logic/ directory under src/apprt/win32) is not referenced
        from its logic/tests.zig, or logic/tests.zig is missing
      - a feature's logic/tests.zig is not referenced from its mod.zig
      - a logic/tests.zig is not reachable from fast_tests.zig (when fast_tests.zig exists)
    Warnings:
      - manifest entries or ext fields not sorted; an expected *Ext struct missing; an ext
        field type that does not import <id>/state.zig; a features/ subdirectory without
        mod.zig; a pre-seeded module of ARCHITECTURE section 1.5 missing from the manifest
      - new alias lines (pub const f = @import("x.zig").f; or pub const f = x.f;) in App.zig /
        ui/Window.zig after Wave 0, i.e. lines absent from the -AliasBaseline tag (default
        wave-0). Before that tag exists aliases are allowed (W0 migration) and only counted.

    Before W0-A3 lands the skeleton, the registry checks report "skeleton not present yet"
    and pass; the logic and alias checks still run.

.PARAMETER RepoRoot
    Checkout to check (default: the one containing this script). Need not be a git repo.

.PARAMETER AliasBaseline
    Git tag (or ref) that marks the end of Wave 0 (default wave-0).

.PARAMETER WarningsAsErrors
    Treat warnings as errors.

.EXAMPLE
    pwsh scripts/check-manifest.ps1

.NOTES
    Exit codes: 0 = no errors, 1 = errors (or warnings with -WarningsAsErrors).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$AliasBaseline = 'wave-0',
    [switch]$WarningsAsErrors
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib/WmuxTooling.psm1') -Force

$tag = 'check-manifest'
$script:errorCount = 0
$script:warningCount = 0

function Add-Error([string]$Message) { $script:errorCount++; Write-WmuxLine -Tag $tag -Level ERROR -Message $Message }
function Add-Warning([string]$Message) { $script:warningCount++; Write-WmuxLine -Tag $tag -Level WARN -Message $Message }
function Write-Note([string]$Message) { Write-WmuxLine -Tag $tag -Level NOTE -Message $Message }

function Get-RelPath([string]$Path) {
    return [System.IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('\', '/')
}

function Remove-ZigComment([string]$Line) {
    # Strips a // comment that is not inside a "..." or '...' literal.
    $quote = [char]0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote -ne [char]0) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c; continue }
        if ($c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { return $Line.Substring(0, $i) }
    }
    return $Line
}

function Get-ZigCodeLines([string]$Path) {
    return , @([System.IO.File]::ReadAllLines($Path) | ForEach-Object { Remove-ZigComment $_ })
}

function Get-ZigImports([string]$Path) {
    # Relative .zig imports of a file, resolved to full paths.
    $dir = Split-Path -Parent $Path
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-ZigCodeLines $Path)) {
        foreach ($m in [regex]::Matches($line, '@import\(\s*"([^"]+\.zig)"\s*\)')) {
            $out.Add([System.IO.Path]::GetFullPath((Join-Path $dir $m.Groups[1].Value)))
        }
    }
    return , $out.ToArray()
}

function Get-ZigStructFields([string[]]$Lines, [string]$StructName) {
    # Returns $null if the struct is absent, else the list of { Name, Type, Line } at depth 1.
    $header = "pub\s+const\s+$([regex]::Escape($StructName))\s*=\s*(?:extern\s+|packed\s+)?struct\s*\{"
    for ($h = 0; $h -lt $Lines.Count; $h++) {
        $m = [regex]::Match($Lines[$h], $header)
        if (-not $m.Success) { continue }
        $fields = [System.Collections.Generic.List[object]]::new()
        $depth = 1
        $rest = $Lines[$h].Substring($m.Index + $m.Length)
        foreach ($c in $rest.ToCharArray()) { if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { $depth-- } }
        for ($i = $h + 1; $i -lt $Lines.Count -and $depth -gt 0; $i++) {
            $line = $Lines[$i]
            if ($depth -eq 1 -and $line -match '^\s*(@"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                $fields.Add([pscustomobject]@{ Name = $Matches[1].Trim('@', '"'); Type = $Matches[2]; Line = $i + 1 })
            }
            $quote = [char]0
            for ($k = 0; $k -lt $line.Length; $k++) {
                $c = $line[$k]
                if ($quote -ne [char]0) { if ($c -eq '\') { $k++ } elseif ($c -eq $quote) { $quote = [char]0 }; continue }
                if ($c -eq '"' -or $c -eq "'") { $quote = $c }
                elseif ($c -eq '{') { $depth++ }
                elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { break } }
            }
        }
        return , $fields.ToArray()
    }
    return $null
}

function Test-Sorted([string[]]$Names) {
    $sorted = [string[]]$Names.Clone()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Names.Count; $i++) { if ($Names[$i] -cne $sorted[$i]) { return $false } }
    return $true
}

$RepoRoot = if ($RepoRoot) { (Resolve-Path -LiteralPath $RepoRoot).ProviderPath } else { Split-Path $PSScriptRoot -Parent }
$win32 = Join-Path $RepoRoot 'src/apprt/win32'
$featuresDir = Join-Path $win32 'features'
$manifestPath = Join-Path $featuresDir 'manifest.zig'
$extPath = Join-Path $featuresDir 'ext.zig'

if (-not (Test-Path -LiteralPath $win32 -PathType Container)) {
    Add-Error "src/apprt/win32 not found under '$RepoRoot'."
    Write-Host "check-manifest: $script:errorCount error(s), $script:warningCount warning(s)"
    exit 1
}

# ---------------------------------------------------------------- registries
$featureIds = @()
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $present = @(Get-ChildItem -LiteralPath $featuresDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'mod.zig') })
    Write-Note "skeleton not present yet: src/apprt/win32/features/manifest.zig does not exist (created by W0-A3); registry checks skipped ($($present.Count) feature dir(s) with mod.zig so far)."
} else {
    $dirs = @(Get-ChildItem -LiteralPath $featuresDir -Directory | Where-Object { -not $_.Name.StartsWith('_') -and -not $_.Name.StartsWith('.') })
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'mod.zig') -PathType Leaf) { $featureIds += $d.Name }
        else { Add-Warning "src/apprt/win32/features/$($d.Name)/ has no mod.zig (helper directories should start with '_')." }
    }
    $featureIds = @($featureIds | Sort-Object -CaseSensitive)

    # Manifest entries.
    $manifestLines = Get-ZigCodeLines $manifestPath
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $manifestLines.Count; $i++) {
        foreach ($m in [regex]::Matches($manifestLines[$i], '@import\(\s*"(?:\./)?([^"/]+)/mod\.zig"\s*\)')) {
            $entries.Add([pscustomobject]@{ Id = $m.Groups[1].Value; Line = $i + 1 })
        }
    }
    $listed = @($entries | ForEach-Object { $_.Id })
    Write-WmuxLine -Tag $tag -Message "features: $($featureIds.Count) module dir(s), $($entries.Count) manifest entr(ies)"
    foreach ($dup in @($listed | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 })) {
        Add-Error "features/manifest.zig lists '$($dup.Name)' $($dup.Count) times."
    }
    foreach ($e in $entries) {
        if ($featureIds -cnotcontains $e.Id) { Add-Error "features/manifest.zig:$($e.Line) imports '$($e.Id)/mod.zig', which does not exist." }
    }
    foreach ($id in $featureIds) {
        if ($listed -cnotcontains $id) { Add-Error "features/$id/mod.zig is not listed in features/manifest.zig (add one sorted line)." }
    }
    if ($listed.Count -gt 1 -and -not (Test-Sorted $listed)) { Add-Warning 'features/manifest.zig entries are not sorted.' }

    # Pre-seeded module list (ARCHITECTURE section 1.5).
    $archPath = Join-Path $RepoRoot 'docs/arch/ARCHITECTURE.md'
    if (Test-Path -LiteralPath $archPath -PathType Leaf) {
        $arch = [System.IO.File]::ReadAllLines($archPath)
        $h = [Array]::FindIndex($arch, [Predicate[string]] { param($l) $l.StartsWith('### 1.5 ') })
        if ($h -ge 0) {
            $preseeded = @()
            for ($i = $h + 1; $i -lt $arch.Count -and -not $arch[$i].StartsWith('#'); $i++) {
                $preseeded += @([regex]::Matches($arch[$i], '`([a-z0-9_]+)`\[') | ForEach-Object { $_.Groups[1].Value })
            }
            $missing = @($preseeded | Where-Object { $listed -cnotcontains $_ })
            if ($missing.Count -gt 0) { Add-Warning "pre-seeded module(s) of ARCHITECTURE section 1.5 missing from the manifest: $($missing -join ', ')" }
        }
    }

    # Ext structs.
    if (-not (Test-Path -LiteralPath $extPath -PathType Leaf)) {
        Add-Error 'features/ext.zig is missing (required next to features/manifest.zig).'
    } else {
        $extLines = Get-ZigCodeLines $extPath
        $structNames = @($extLines | ForEach-Object { [regex]::Matches($_, 'pub\s+const\s+([A-Za-z_][A-Za-z0-9_]*Ext)\s*=\s*(?:extern\s+|packed\s+)?struct\b') } | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($structNames.Count -eq 0) { Add-Error 'features/ext.zig declares no *Ext structs.' }
        foreach ($expected in 'AppExt', 'WindowExt', 'WorkspaceExt', 'PaneExt', 'TabExt') {
            if ($structNames -cnotcontains $expected) { Add-Warning "features/ext.zig has no $expected (ADR-1.4)." }
        }
        foreach ($sn in $structNames) {
            $fields = Get-ZigStructFields $extLines $sn
            $names = @($fields | ForEach-Object { $_.Name })
            foreach ($id in $featureIds) {
                if ($names -cnotcontains $id) { Add-Error "features/ext.zig: $sn has no field '$id' (one line per feature, sorted)." }
            }
            foreach ($f in $fields) {
                if ($featureIds -cnotcontains $f.Name) { Add-Error "features/ext.zig:$($f.Line): $sn.$($f.Name) names no feature directory." }
                elseif ($f.Type -notmatch [regex]::Escape("`"$($f.Name)/state.zig`"")) { Add-Warning "features/ext.zig:$($f.Line): $sn.$($f.Name) does not import `"$($f.Name)/state.zig`"." }
            }
            if ($names.Count -gt 1 -and -not (Test-Sorted $names)) { Add-Warning "features/ext.zig: $sn fields are not sorted." }
        }
    }

    # Per-feature files.
    foreach ($id in $featureIds) {
        $dir = Join-Path $featuresDir $id
        $modLines = Get-ZigCodeLines (Join-Path $dir 'mod.zig')
        $declared = $null
        foreach ($l in $modLines) { if ($l -match '^\s*pub\s+const\s+id\s*=\s*"([^"]*)"\s*;') { $declared = $Matches[1]; break } }
        if ($null -eq $declared) { Add-Warning "features/$id/mod.zig does not declare pub const id = `"$id`";" }
        elseif ($declared -cne $id) { Add-Error "features/$id/mod.zig declares id `"$declared`" (must equal the directory name, ADR-1.3)." }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'state.zig') -PathType Leaf)) { Add-Error "features/$id/state.zig is missing (ADR-1.3: always exists)." }
        if (Test-Path -LiteralPath (Join-Path $dir 'logic/tests.zig') -PathType Leaf) {
            if (-not (@($modLines | Where-Object { $_ -match '@import\(\s*"(?:\./)?logic/tests\.zig"\s*\)' }).Count)) {
                Add-Error "features/$id/mod.zig does not reference logic/tests.zig (test { _ = @import(`"logic/tests.zig`"); }, ADR-12.1)."
            }
        }
    }
}

# ---------------------------------------------------------------- logic tests
$logicDirs = @(Get-ChildItem -LiteralPath $win32 -Directory -Recurse -Filter 'logic' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](?:\.zig-cache|zig-cache|zig-out)[\\/]' } |
        Where-Object { $_.Parent.Name -ne 'logic' -and $_.FullName -notmatch '[\\/]logic[\\/].*[\\/]logic$' })
$rootTests = [System.Collections.Generic.List[string]]::new()
$logicFiles = 0
foreach ($ld in $logicDirs) {
    $zigFiles = @(Get-ChildItem -LiteralPath $ld.FullName -Filter '*.zig' -File -Recurse)
    $members = @($zigFiles | Where-Object { $_.Name -ne 'tests.zig' })
    $rootTest = Join-Path $ld.FullName 'tests.zig'
    if (Test-Path -LiteralPath $rootTest -PathType Leaf) { $rootTests.Add([System.IO.Path]::GetFullPath($rootTest)) }
    if ($members.Count -eq 0) { continue }
    $logicFiles += $members.Count
    if (-not (Test-Path -LiteralPath $rootTest -PathType Leaf)) {
        Add-Error "$(Get-RelPath $ld.FullName)/ has $($members.Count) file(s) but no tests.zig (ADR-12.1)."
        continue
    }
    $importCache = @{}
    foreach ($f in $members) {
        $full = [System.IO.Path]::GetFullPath($f.FullName)
        $referenced = $false
        $dir = $f.Directory
        while ($null -ne $dir) {
            $t = Join-Path $dir.FullName 'tests.zig'
            if (Test-Path -LiteralPath $t -PathType Leaf) {
                if (-not $importCache.ContainsKey($t)) { $importCache[$t] = Get-ZigImports $t }
                if (@($importCache[$t] | Where-Object { $_ -ieq $full }).Count) { $referenced = $true; break }
            }
            if ([System.IO.Path]::GetFullPath($dir.FullName) -ieq [System.IO.Path]::GetFullPath($ld.FullName)) { break }
            $dir = $dir.Parent
        }
        if (-not $referenced) { Add-Error "$(Get-RelPath $f.FullName) is not referenced from $(Get-RelPath $rootTest) (ADR-12.1)." }
    }
}
Write-WmuxLine -Tag $tag -Message "logic: $($logicDirs.Count) logic dir(s), $logicFiles logic file(s)"

$fastTests = Join-Path $win32 'fast_tests.zig'
if (Test-Path -LiteralPath $fastTests -PathType Leaf) {
    $srcRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'src')) + [System.IO.Path]::DirectorySeparatorChar
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue([System.IO.Path]::GetFullPath($fastTests))
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        if (-not $seen.Add($p)) { continue }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        foreach ($imp in (Get-ZigImports $p)) {
            if ($imp.StartsWith($srcRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $queue.Enqueue($imp) }
        }
    }
    foreach ($t in $rootTests) {
        if (-not $seen.Contains($t)) { Add-Error "$(Get-RelPath $t) is not reachable from src/apprt/win32/fast_tests.zig (ADR-12.1)." }
    }
} elseif ($rootTests.Count -gt 0) {
    Write-Note 'src/apprt/win32/fast_tests.zig does not exist yet (W0-A3); fast-test reachability not checked.'
}

# ---------------------------------------------------------------- W0 aliases
$aliasFiles = @('src/apprt/win32/App.zig', 'src/apprt/win32/ui/Window.zig', 'src/apprt/win32/Window.zig') |
    Where-Object { Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf }
# Both alias forms W0 uses: `pub const f = @import("x.zig").f;` and, with the file imported
# once as `const x = @import("x.zig");`, `pub const f = x.f;` (the form W0-A1 writes).
$aliasPattern = '^\s*pub\s+const\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:@import\(\s*"[^"]+"\s*\)|[A-Za-z_][A-Za-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_]*)+\s*;'
$isGit = $false
try { $isGit = ((Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure).Output.Trim() -eq 'true') } catch { $isGit = $false }
$baselineOk = $false
if ($isGit) {
    $baselineOk = ((Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "$AliasBaseline^{commit}") -AllowFailure).ExitCode -eq 0)
}
$aliasTotal = 0
foreach ($rel in $aliasFiles) {
    $lines = [System.IO.File]::ReadAllLines((Join-Path $RepoRoot $rel))
    $current = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $aliasPattern) { $current += [pscustomobject]@{ Line = $i + 1; Text = ($lines[$i].Trim() -replace '\s+', ' ') } }
    }
    $aliasTotal += $current.Count
    if (-not $baselineOk) { continue }
    $old = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('show', "${AliasBaseline}:$rel") -AllowFailure
    $baseline = [System.Collections.Generic.HashSet[string]]::new()
    if ($old.ExitCode -eq 0) {
        foreach ($l in (Split-WmuxLines $old.Output)) { if ($l -match $aliasPattern) { [void]$baseline.Add(($l.Trim() -replace '\s+', ' ')) } }
    }
    foreach ($a in $current) {
        if (-not $baseline.Contains($a.Text)) { Add-Warning "${rel}:$($a.Line): new alias after Wave 0 ($($a.Text)); call the moved function directly (section 0.4, ADR-1.9)." }
    }
}
if (-not $isGit) {
    Write-Note 'not a git checkout; alias baseline check skipped.'
} elseif (-not $baselineOk) {
    Write-Note "W0 in progress (no '$AliasBaseline' tag yet): $aliasTotal alias line(s) in App.zig/Window.zig, allowed until Wave 0 ends."
}

# ---------------------------------------------------------------- result
$failed = $script:errorCount -gt 0 -or ($WarningsAsErrors -and $script:warningCount -gt 0)
if (-not $failed) { Write-WmuxLine -Tag $tag -Level OK -Message 'registries and logic test wiring are consistent.' }
Write-Host "check-manifest: $script:errorCount error(s), $script:warningCount warning(s)"
exit ([int]$failed)
