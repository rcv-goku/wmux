#Requires -Version 7.0
<#
.SYNOPSIS
    Creates (or re-uses) the git worktree of a work package and bootstraps it.

.DESCRIPTION
    docs/arch/ARCHITECTURE.md section 15.1 (step 2), ADR-12.5 and ADR-14.9:
      1. git worktree add <Root>\<id> on branch wp/<id>-<slug>, branched from <Base>
         (default master). An existing branch, or an existing registered worktree at that
         path, is re-used, so the script is safe to re-run.
      2. Zig global cache: all worktrees share one cache. Zig's per-user default
         (%LOCALAPPDATA%\zig, or ZIG_GLOBAL_CACHE_DIR when set) already is shared; only when
         the worktree sits on another drive than that cache (zig build asserts on
         cross-drive paths) is ZIG_GLOBAL_CACHE_DIR pointed at <Root>\.zig-global-cache for
         the build run here, and the line to set it in your shell is printed.
      3. Stages an x64 WebView2Loader.dll into <worktree>\zig-out\bin (browser panes need it
         next to wmux.exe). Search order: -WebView2Loader, $env:WEBVIEW2LOADER_PATH,
         <main repo>\zig-out\bin, <main repo>\dist\windows, %LOCALAPPDATA%\Programs\wmux,
         %LOCALAPPDATA%\Programs\wmux\bin, the NuGet cache (microsoft.web.webview2).
      4. Runs the first debug build: zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
         (log: <worktree>\.zig-cache\wmux-tooling\first-build.log).

.PARAMETER Wp
    Work-package id, e.g. W2-5, W1-1a, W0-D-S1.

.PARAMETER Slug
    Branch slug (wp/<id>-<slug>). Default: derived from the title in docs/arch/wp/<id>.md on
    <Base>, else "wip".

.PARAMETER Base
    Branch to start from (default master; origin/master as fallback).

.PARAMETER Root
    Directory holding the worktrees (default: <parent of the main checkout>\wmux-wt).

.PARAMETER Repo
    Any checkout of the repository (default: the one containing this script); the
    worktree is attached to its main checkout.

.PARAMETER Zig
    Path to zig.exe (default: $env:ZIG, zig on PATH, ~\zig-x86_64-windows-0.15.2\zig.exe).

.PARAMETER WebView2Loader
    Explicit path of the WebView2Loader.dll to stage.

.PARAMETER NoBuild
    Skip the first debug build.

.EXAMPLE
    pwsh scripts/new-worktree.ps1 -Wp W2-5 -Slug notifications-core

.EXAMPLE
    pwsh scripts/new-worktree.ps1 -Wp W2-5 -WhatIf

.NOTES
    Exit codes: 0 = ready, 1 = failed (the worktree is kept if it was created), 2 = usage error.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)][string]$Wp,
    [string]$Slug,
    [string]$Base = 'master',
    [string]$Root,
    [string]$Repo,
    [string]$Zig,
    [string]$WebView2Loader,
    [switch]$NoBuild
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib/WmuxTooling.psm1') -Force

$tag = 'new-worktree'

function Exit-Usage([string]$Message) {
    Write-WmuxLine -Tag $tag -Level ERROR -Message $Message
    exit 2
}

function ConvertTo-Slug([string]$Text) {
    $s = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($s.Length -gt 40) {
        $s = $s.Substring(0, 40)
        $cut = $s.LastIndexOf('-')
        if ($cut -gt 10) { $s = $s.Substring(0, $cut) }
    }
    return $s.Trim('-')
}

if (-not (Test-WmuxWpId $Wp)) { Exit-Usage "'$Wp' is not a WP id (expected e.g. W2-5, W1-1a, W0-D-S1)." }

try {
    $main = Get-WmuxMainRepoRoot -Path $(if ($Repo) { $Repo } else { $PSScriptRoot })
    $baseRef = Resolve-WmuxBaseRef -RepoRoot $main -Base $Base
} catch {
    Exit-Usage $_.Exception.Message
}
if (-not $Root) { $Root = Join-Path (Split-Path $main -Parent) 'wmux-wt' }
$Root = Resolve-WmuxPath $Root
if ($WebView2Loader) { $WebView2Loader = Resolve-WmuxPath $WebView2Loader }
$wt = Join-Path $Root $Wp

# ------------------------------------------------------------------ branch name
if ($Slug) {
    $clean = ConvertTo-Slug $Slug
    if (-not $clean) { Exit-Usage "-Slug '$Slug' has no usable characters." }
    if ($clean -ne $Slug) { Write-WmuxLine -Tag $tag -Level NOTE -Message "slug normalized to '$clean'" }
    $Slug = $clean
} else {
    $Slug = 'wip'
    $show = Invoke-WmuxGit -RepoRoot $main -Arguments @('show', "${baseRef}:docs/arch/wp/$Wp.md") -AllowFailure
    if ($show.ExitCode -eq 0) {
        try {
            $title = [string](Read-WmuxFrontMatter -Text $show.Output -Source "docs/arch/wp/$Wp.md")['title']
            if ($title -and (ConvertTo-Slug $title)) { $Slug = ConvertTo-Slug $title }
        } catch {
            Write-WmuxLine -Tag $tag -Level WARN -Message "docs/arch/wp/$Wp.md on ${baseRef}: $($_.Exception.Message)"
        }
    }
    if ($Slug -eq 'wip') { Write-WmuxLine -Tag $tag -Level NOTE -Message "no spec title on $baseRef; using slug 'wip' (pass -Slug to choose one)." }
}
$branch = "wp/$Wp-$Slug"

# ------------------------------------------------------------------ worktree
$list = Invoke-WmuxGit -RepoRoot $main -Arguments @('worktree', 'list', '--porcelain')
$worktrees = @()
$current = $null
foreach ($line in (Split-WmuxLines $list.Output)) {
    if ($line.StartsWith('worktree ')) {
        $current = [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($line.Substring(9)); Branch = '' }
        $worktrees += $current
    } elseif ($line.StartsWith('branch ') -and $current) {
        $current.Branch = $line.Substring(7) -replace '^refs/heads/', ''
    }
}
$registered = $worktrees | Where-Object { $_.Path -ieq [System.IO.Path]::GetFullPath($wt) } | Select-Object -First 1
$created = $false

if (Test-Path -LiteralPath $wt) {
    if (-not $registered) {
        Write-WmuxLine -Tag $tag -Level ERROR -Message "$wt exists but is not a worktree of $main; refusing to touch it."
        exit 1
    }
    Write-WmuxLine -Tag $tag -Message "re-using existing worktree $wt (branch $($registered.Branch))"
    if ($registered.Branch -and $registered.Branch -ne $branch) {
        Write-WmuxLine -Tag $tag -Level NOTE -Message "it is on '$($registered.Branch)', not '$branch'; leaving it as is."
        $branch = $registered.Branch
    }
} else {
    $branchExists = (Invoke-WmuxGit -RepoRoot $main -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$branch") -AllowFailure).ExitCode -eq 0
    if ($branchExists) {
        $holder = $worktrees | Where-Object { $_.Branch -eq $branch } | Select-Object -First 1
        if ($holder) {
            Write-WmuxLine -Tag $tag -Level ERROR -Message "branch $branch is already checked out in $($holder.Path)."
            exit 1
        }
        $gitArgs = @('-C', $main, 'worktree', 'add', '--quiet', $wt, $branch)
        $what = "attach existing branch $branch"
    } else {
        $gitArgs = @('-C', $main, 'worktree', 'add', '--quiet', $wt, '-b', $branch, $baseRef)
        $what = "create branch $branch from $baseRef"
    }
    if ($PSCmdlet.ShouldProcess($wt, "git worktree add ($what)")) {
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        Write-WmuxLine -Tag $tag -Message "git worktree add $wt ($what); checking out the tree can take a few minutes..."
        $res = Invoke-WmuxProcess -FilePath (Get-Command git -CommandType Application | Select-Object -First 1).Source -ArgumentList $gitArgs -WorkingDirectory $main
        if ($res.ExitCode -ne 0) {
            Write-WmuxLine -Tag $tag -Level ERROR -Message "git worktree add failed (exit $($res.ExitCode))."
            exit 1
        }
        $created = $true
    }
}

if ($WhatIfPreference) {
    Write-WmuxLine -Tag $tag -Message "WhatIf: would stage WebView2Loader.dll into $wt\zig-out\bin$(if (-not $NoBuild) { ' and run the first debug build' })."
    exit 0
}

# ------------------------------------------------------------------ toolchain and cache
$cache = Get-WmuxZigCache -WorktreeRoot $wt -WorktreesRoot $Root
$childEnv = @{}
if ($cache.Override) {
    $childEnv['ZIG_GLOBAL_CACHE_DIR'] = $cache.Dir
    New-Item -ItemType Directory -Force -Path $cache.Dir | Out-Null
}
Write-WmuxLine -Tag $tag -Message "zig global cache: $($cache.Dir) ($($cache.Reason))"

# ------------------------------------------------------------------ WebView2Loader.dll
$dllTarget = Join-Path $wt 'zig-out\bin\WebView2Loader.dll'
$candidates = [System.Collections.Generic.List[string]]::new()
foreach ($c in @($WebView2Loader, $env:WEBVIEW2LOADER_PATH,
        (Join-Path $main 'zig-out\bin\WebView2Loader.dll'),
        (Join-Path $main 'dist\windows\WebView2Loader.dll'),
        (Join-Path $env:LOCALAPPDATA 'Programs\wmux\WebView2Loader.dll'),
        (Join-Path $env:LOCALAPPDATA 'Programs\wmux\bin\WebView2Loader.dll'))) {
    if ($c) { $candidates.Add($c) }
}
$nuget = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2'
if (Test-Path -LiteralPath $nuget) {
    Get-ChildItem -LiteralPath $nuget -Directory |
        Sort-Object { $v = $null; if ([version]::TryParse(($_.Name -split '-')[0], [ref]$v)) { $v } else { [version]'0.0' } } -Descending |
        ForEach-Object { $candidates.Add((Join-Path $_.FullName 'build\native\x64\WebView2Loader.dll')) }
}
$dllSource = $null
$dllNote = 'missing'
if ((Test-Path -LiteralPath $dllTarget -PathType Leaf) -and -not $WebView2Loader -and (Test-WmuxPeMachine -Path $dllTarget)) {
    $dllNote = 'already staged'
    Write-WmuxLine -Tag $tag -Message 'WebView2Loader.dll already in zig-out\bin'
} else {
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        if (Test-WmuxPeMachine -Path $c) { $dllSource = $c; break }
        Write-WmuxLine -Tag $tag -Level NOTE -Message "skipping $c (not an x64 PE image)"
    }
    if ($null -eq $dllSource) {
        Write-WmuxLine -Tag $tag -Level WARN -Message 'WebView2Loader.dll not found; browser panes stay disabled. Copy build\native\x64\WebView2Loader.dll from the Microsoft.Web.WebView2 NuGet package into zig-out\bin (README "Prerequisites"), or pass -WebView2Loader.'
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $dllTarget) | Out-Null
        Copy-Item -LiteralPath $dllSource -Destination $dllTarget -Force
        $dllNote = "from $dllSource"
        Write-WmuxLine -Tag $tag -Message "staged WebView2Loader.dll from $dllSource"
    }
}

# ------------------------------------------------------------------ first build
$buildNote = 'skipped (-NoBuild)'
$exit = 0
if (-not $NoBuild) {
    try {
        $zigExe = Resolve-WmuxZig -Zig $Zig -Tag $tag
    } catch {
        Write-WmuxLine -Tag $tag -Level ERROR -Message $_.Exception.Message
        exit 1
    }
    $log = Join-Path $wt '.zig-cache\wmux-tooling\first-build.log'
    $buildArgs = @('build') + (Get-WmuxTargetArgs)
    Write-WmuxLine -Tag $tag -Message "first debug build: zig $($buildArgs -join ' ') (a fresh worktree takes ~5 min)"
    $res = Invoke-WmuxProcess -FilePath $zigExe -ArgumentList $buildArgs -WorkingDirectory $wt -LogFile $log -Environment $childEnv
    $mins = '{0:mm\:ss}' -f $res.Duration
    if ($res.ExitCode -eq 0) {
        $buildNote = "ok in $mins"
        Write-WmuxLine -Tag $tag -Level OK -Message "debug build finished in $mins"
    } else {
        $buildNote = "FAILED (exit $($res.ExitCode)) after $mins; log $log"
        Write-WmuxLine -Tag $tag -Level ERROR -Message "debug build failed (exit $($res.ExitCode)); log: $log"
        $exit = 1
    }
}

# ------------------------------------------------------------------ summary
$head = (Invoke-WmuxGit -RepoRoot $wt -Arguments @('rev-parse', '--short', 'HEAD')).Output.Trim()
Write-Host ''
Write-Host "worktree : $wt$(if ($created) { ' (created)' } else { '' })"
Write-Host "branch   : $branch @ $head (base $baseRef)"
Write-Host "dll      : WebView2Loader.dll $dllNote"
Write-Host "build    : $buildNote"
Write-Host 'next     :'
Write-Host "  Set-Location '$wt'"
if ($cache.Override) { Write-Host "  `$env:ZIG_GLOBAL_CACHE_DIR = '$($cache.Dir)'" }
Write-Host "  # spec: docs/arch/wp/$Wp.md; conventions: docs/arch/ARCHITECTURE.md section 15"
Write-Host "  pwsh scripts/gate.ps1 -Wp $Wp"
exit $exit
