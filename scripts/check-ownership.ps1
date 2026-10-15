#Requires -Version 7.0
<#
.SYNOPSIS
    Fails when a work package changes paths outside its WP spec (owns / touches / appends).

.DESCRIPTION
    Merge-gate check of docs/arch/ARCHITECTURE.md ADR-1.7 and section 15.3.

    Reads the YAML front matter of docs/arch/wp/<id>.md (template: docs/arch/wp/_template.md)
    and compares every path changed on this branch against merge-base(<Base>, HEAD):
      - committed changes and uncommitted changes to tracked files must match a glob in
        owns, touches (path) or appends; violations fail the check;
      - untracked files outside the spec only warn (they are not part of the merge);
      - from wave 1 on, frozen files (ADR-1.7 "Frozen" class) are accepted only through an
        explicit touches entry, never through an owns glob;
      - a WP may always edit its own spec docs/arch/wp/<id>.md and its CCRs
        docs/arch/ccr/<id>-<n>.md;
      - shared-appendable files (appends) that lose lines produce a warning.

    The spec is read from <Base> (a branch cannot grant itself ownership). Only when the
    spec does not exist on <Base> yet is the worktree copy used, with a warning.

    Globs: ** spans directories, * and ? stay within one path segment, {a,b} alternates;
    paths are repo-relative with forward slashes and match case-insensitively.

.PARAMETER Wp
    Work-package id (e.g. W2-5, W1-1a, W0-D-S1). Default: inferred from the worktree
    directory name or the wp/<id>-<slug> branch.

.PARAMETER Base
    Integration branch to diff against (default master; origin/master as fallback).

.PARAMETER SpecPath
    Read the spec from this file instead of docs/arch/wp/<id>.md (testing, drafts).

.PARAMETER CommittedOnly
    Ignore uncommitted and untracked changes.

.PARAMETER RepoRoot
    Worktree to check (default: the worktree containing this script).

.EXAMPLE
    pwsh scripts/check-ownership.ps1 -Wp W2-5

.NOTES
    Exit codes: 0 = every changed path is covered (warnings allowed), 1 = violations,
    2 = spec missing/invalid or usage error.
#>
[CmdletBinding()]
param(
    [string]$Wp,
    [string]$Base = 'master',
    [string]$SpecPath,
    [switch]$CommittedOnly,
    [string]$RepoRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib/WmuxTooling.psm1') -Force

$tag = 'check-ownership'
$warnings = 0
$violations = [System.Collections.Generic.List[string]]::new()

function Exit-Usage([string]$Message) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message $Message
    Write-Host "check-ownership: spec error, 0 warning(s)"
    exit 2
}

try {
    $RepoRoot = if ($RepoRoot) { Get-WmuxRepoRoot -Path $RepoRoot } else { Get-WmuxRepoRoot -Path $PSScriptRoot }
    if (-not $Wp) { $Wp = Resolve-WmuxWpId -RepoRoot $RepoRoot }
    if (-not $Wp) { Exit-Usage 'Cannot infer the WP id from the worktree or branch; pass -Wp <id>.' }
    if (-not (Test-WmuxWpId $Wp)) { Exit-Usage "'$Wp' is not a WP id (expected e.g. W2-5, W1-1a, W0-D-S1)." }
    $baseRef = Resolve-WmuxBaseRef -RepoRoot $RepoRoot -Base $Base
    $spec = Get-WmuxWpSpec -RepoRoot $RepoRoot -Wp $Wp -BaseRef $baseRef -SpecPath $SpecPath
} catch {
    Exit-Usage $_.Exception.Message
}

if ($null -eq $spec) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message "No spec docs/arch/wp/$Wp.md on $baseRef or in this worktree. Write it from docs/arch/wp/_template.md (ARCHITECTURE Appendix H); ownership cannot be checked without it."
    Write-Host 'check-ownership: spec missing, 0 warning(s)'
    exit 2
}

$specId = [string]$spec.Data['id']
if ($specId -and $specId -ne $Wp) { Exit-Usage "$($spec.Path) declares id '$specId' but the WP is '$Wp'." }
if (-not $specId) {
    Write-WmuxLine -Tag $tag -Level WARN -Message "$($spec.Path) has no 'id' field."
    $warnings++
}
switch ($spec.Source) {
    'base' {
        Write-WmuxLine -Tag $tag -Message "spec: $($spec.Path) @ $baseRef"
        if ($spec.ModifiedOnBranch) {
            Write-WmuxLine -Tag $tag -Level NOTE -Message "the spec differs on this branch; the $baseRef version is authoritative for ownership."
        }
    }
    'worktree' {
        Write-WmuxLine -Tag $tag -Level WARN -Message "$($spec.Path) is not on $baseRef yet; using the worktree copy (self-declared ownership until the integrator merges the spec)."
        $warnings++
    }
    default { Write-WmuxLine -Tag $tag -Message "spec: $($spec.Path) (explicit file)" }
}

$wave = $null
$waveRaw = [string]$spec.Data['wave']
if ($waveRaw -match '^(\d+)[a-z]?$') { $wave = [int]$Matches[1] }   # 5a/5b count as wave 5

# Rules in precedence order. Frozen files are special-cased below.
$rules = [System.Collections.Generic.List[object]]::new()
foreach ($e in $spec.Owns) { $rules.Add([pscustomobject]@{ Glob = $e.Path; Kind = 'owns'; Reason = '' }) }
foreach ($e in $spec.Appends) { $rules.Add([pscustomobject]@{ Glob = $e.Path; Kind = 'appends'; Reason = '' }) }
foreach ($e in $spec.Touches) { $rules.Add([pscustomobject]@{ Glob = $e.Path; Kind = 'touches'; Reason = $e.Reason }) }
$rules.Add([pscustomobject]@{ Glob = "docs/arch/wp/$Wp.md"; Kind = 'implicit'; Reason = 'own WP spec' })
$rules.Add([pscustomobject]@{ Glob = "docs/arch/ccr/$Wp-*.md"; Kind = 'implicit'; Reason = 'own CCRs' })
if ($spec.Owns.Count + $spec.Touches.Count + $spec.Appends.Count -eq 0) {
    Write-WmuxLine -Tag $tag -Level WARN -Message "$($spec.Path) declares no owns, touches or appends."
    $warnings++
}
foreach ($e in $spec.Touches) {
    if (-not $e.Reason) {
        Write-WmuxLine -Tag $tag -Level WARN -Message "touches entry '$($e.Path)' has no reason (Appendix H requires one)."
        $warnings++
    }
}

# ADR-1.7 "Frozen" class. From wave 1 on these need an explicit touches entry.
$frozen = @(
    'src/apprt/win32/App.zig', 'src/apprt/win32/ui/Window.zig', 'src/apprt/win32/model/**',
    'src/apprt/win32/rpc/types.zig', 'src/apprt/win32/rpc/registry.zig', 'src/apprt/win32/input/actions.zig',
    'src/apprt/win32/ui/contrib.zig', 'src/apprt/win32/features/manifest.zig', 'src/apprt/win32/features/ext.zig',
    'src/apprt/win32/features/lifecycle.zig', 'src/apprt/win32/fast_tests.zig', 'src/apprt/win32/test_index.zig',
    'src/wmux_cli/commands/manifest.zig', 'src/wmux_cli/agents/manifest.zig', 'src/wmux_proto/settings/specs_manifest.zig',
    'src/config/Config.zig', 'src/input/Binding.zig', 'src/input/command.zig', 'src/apprt/action.zig',
    'include/ghostty.h', 'src/Surface.zig', 'src/apprt/surface.zig', 'src/Command.zig', 'src/termio/**',
    'build.zig', 'src/build/**', 'src/apprt/win32/platform/webview2.zig', 'src/apprt/win32/platform/d2d.zig',
    'src/apprt/win32/platform/dwrite.zig'
)
$enforceFrozen = ($null -ne $wave -and $wave -ge 1)
if ($null -eq $wave) {
    Write-WmuxLine -Tag $tag -Level NOTE -Message "spec has no numeric 'wave'; frozen-file rules (wave >= 1) are not applied."
}

try {
    $changes = Get-WmuxChangedFiles -RepoRoot $RepoRoot -BaseRef $baseRef -CommittedOnly:$CommittedOnly
} catch {
    Exit-Usage $_.Exception.Message
}
$files = @($changes.Files)
Write-WmuxLine -Tag $tag -Message "$Wp vs $baseRef (merge-base $($changes.MergeBase.Substring(0, 10))): $($files.Count) changed path(s)"
if ($files.Count -eq 0) {
    Write-WmuxLine -Tag $tag -Level OK -Message 'nothing changed.'
    Write-Host "check-ownership: 0 violation(s), $warnings warning(s)"
    exit 0
}

$counts = @{ owns = 0; appends = 0; touches = 0; implicit = 0 }
foreach ($f in $files) {
    $isFrozen = $false
    if ($enforceFrozen) {
        foreach ($g in $frozen) { if (Test-WmuxGlobMatch -Path $f.Path -Glob $g) { $isFrozen = $true; break } }
    }
    $match = $null
    foreach ($r in $rules) {
        if ($isFrozen -and $r.Kind -ne 'touches') { continue }
        if (Test-WmuxGlobMatch -Path $f.Path -Glob $r.Glob) { $match = $r; break }
    }
    $where = if ($f.Committed) { 'committed' } elseif ($f.Untracked) { 'untracked' } else { 'uncommitted' }
    if ($null -eq $match) {
        $why = if ($isFrozen) { 'is a frozen file (ADR-1.7) without a touches entry' } else { 'is outside owns/touches/appends' }
        if ($f.Untracked -and -not $f.Committed) {
            Write-WmuxLine -Tag $tag -Level WARN -Message "$($f.Path) [$where] $why (untracked files are not part of the merge)"
            $warnings++
        } else {
            Write-WmuxLine -Tag $tag -Level ERROR -Message "$($f.Status) $($f.Path) [$where] $why"
            $violations.Add($f.Path)
        }
        continue
    }
    $counts[$match.Kind]++
    if ($match.Kind -eq 'touches') {
        $reason = if ($match.Reason) { " ($($match.Reason))" } else { '' }
        Write-WmuxLine -Tag $tag -Message "touches $($f.Path)$reason"
    }
    if ($match.Kind -eq 'appends' -and $f.Status -eq 'M') {
        $diffArgs = if ($f.Committed -and -not $f.Uncommitted) { @('diff', '-U0', $changes.MergeBase, 'HEAD', '--', $f.Path) } else { @('diff', '-U0', $changes.MergeBase, '--', $f.Path) }
        $diff = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments $diffArgs -AllowFailure
        $removed = @(Split-WmuxLines $diff.Output | Where-Object { $_.StartsWith('-') -and -not $_.StartsWith('---') }).Count
        if ($removed -gt 0) {
            Write-WmuxLine -Tag $tag -Level WARN -Message "$($f.Path) is shared-appendable but loses $removed line(s); add one sorted entry per line and change nothing else (section 15.3)."
            $warnings++
        }
    }
}

# Spec lint: owns globs should not cover frozen files from wave 1 on.
if ($enforceFrozen) {
    $samples = foreach ($g in $frozen) { if ($g.EndsWith('/**')) { $g.Substring(0, $g.Length - 2) + 'x.zig' } else { $g } }
    foreach ($e in $spec.Owns) {
        $hits = @($samples | Where-Object { Test-WmuxGlobMatch -Path $_ -Glob $e.Path })
        if ($hits.Count -gt 0) {
            Write-WmuxLine -Tag $tag -Level NOTE -Message "owns glob '$($e.Path)' also covers frozen path(s) $($hits -join ', '); those still need a touches entry."
        }
    }
}

$summary = "$($files.Count) path(s): $($counts.owns) owns, $($counts.appends) appends, $($counts.touches) touches, $($counts.implicit) implicit, $($violations.Count) violation(s)"
if ($violations.Count -gt 0) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message $summary
    Write-WmuxLine -Tag $tag -Message "Revert those changes, or write a Core Change Request docs/arch/ccr/$Wp-<n>.md (template docs/arch/ccr/_template.md) and ship behind a stub (ADR-1.7, section 15.1)."
} else {
    Write-WmuxLine -Tag $tag -Level OK -Message $summary
}
Write-Host "check-ownership: $($violations.Count) violation(s), $warnings warning(s)"
exit ([int]($violations.Count -gt 0))
