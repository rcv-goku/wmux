#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the wmux parity-program tooling (scripts/*.ps1).

.DESCRIPTION
    Used by new-worktree.ps1, gate.ps1, check-ownership.ps1 and check-manifest.ps1
    (docs/arch/ARCHITECTURE.md ADR-1.7, ADR-12.5, ADR-14.9, section 15).
    No external modules: a small YAML-subset parser reads the WP spec front matter
    (docs/arch/wp/<id>.md, Appendix H), git and child processes are driven through
    System.Diagnostics.Process with UTF-8 pipes so console code pages never matter.
#>

Set-StrictMode -Version 3.0

$script:WpIdPattern = '^W\d+(?:-[A-Za-z0-9]+)+$'
$script:TargetArgs = @('-Dapp-runtime=win32', '-Dtarget=x86_64-windows-gnu')
$script:ExpectedZigVersion = '0.15.2'
$script:GitExe = $null

# --------------------------------------------------------------------------
# Console output
# --------------------------------------------------------------------------

function Write-WmuxLine {
    <# Writes "[tag] LEVEL: message" to the host; colors only on an interactive console. #>
    param(
        [Parameter(Mandatory)][string]$Tag,
        [ValidateSet('', 'INFO', 'NOTE', 'OK', 'WARN', 'ERROR', 'SKIP')][string]$Level = '',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $text = if ($Level) { "[$Tag] ${Level}: $Message" } else { "[$Tag] $Message" }
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        'OK' { 'Green' }
        'NOTE' { 'Cyan' }
        'SKIP' { 'DarkGray' }
        default { $null }
    }
    if ($color -and -not [Console]::IsOutputRedirected) {
        Write-Host $text -ForegroundColor $color
    } else {
        Write-Host $text
    }
}

# --------------------------------------------------------------------------
# Identifiers, repo layout, toolchain
# --------------------------------------------------------------------------

function Resolve-WmuxPath {
    <#
    .SYNOPSIS
        Absolute filesystem path for $Path, relative to the PowerShell location. Needed
        because .NET APIs and child processes resolve relative paths against the process
        working directory, which Set-Location does not change.
    #>
    param([Parameter(Mandatory)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-WmuxWpId {
    <# True if $Wp looks like a work-package id: W2-5, W1-1a, W0-D-S1, W0-C. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Wp)
    return [bool]($Wp -cmatch $script:WpIdPattern)
}

function Get-WmuxTargetArgs {
    <# The build options every wmux build and test command uses (section 15.6). #>
    return , @($script:TargetArgs)
}

function Get-WmuxGitExe {
    if (-not $script:GitExe) {
        $cmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { throw 'git was not found on PATH.' }
        $script:GitExe = $cmd.Source
    }
    return $script:GitExe
}

function Invoke-WmuxGit {
    <#
    .SYNOPSIS
        Runs git -C <repo> with UTF-8 pipes; returns { ExitCode, Output, Error }.
        Throws on a non-zero exit unless -AllowFailure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-WmuxGitExe))
    foreach ($a in @('-C', (Resolve-WmuxPath $RepoRoot), '-c', 'core.quotepath=off') + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $result = [pscustomobject]@{
            ExitCode = $p.ExitCode
            Output   = $outTask.GetAwaiter().GetResult()
            Error    = $errTask.GetAwaiter().GetResult()
        }
    } finally {
        $p.Dispose()
    }
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with exit code $($result.ExitCode): $($result.Error.Trim())"
    }
    return $result
}

function Split-WmuxLines {
    <# Splits command output into non-empty lines (LF or CRLF); emits one string per line. #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return }
    $Text -split "`r?`n" | Where-Object { $_ -ne '' }
}

function Get-WmuxRepoRoot {
    <# Top level of the worktree containing $Path (default: the scripts' repo). #>
    param([string]$Path = (Split-Path $PSScriptRoot -Parent))
    $r = Invoke-WmuxGit -RepoRoot $Path -Arguments @('rev-parse', '--show-toplevel')
    return [System.IO.Path]::GetFullPath($r.Output.Trim())
}

function Get-WmuxMainRepoRoot {
    <# The main checkout (owner of the common .git dir), from any of its worktrees. #>
    param([Parameter(Mandatory)][string]$Path)
    $r = Invoke-WmuxGit -RepoRoot $Path -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    $common = [System.IO.Path]::GetFullPath($r.Output.Trim())
    if ((Split-Path $common -Leaf) -ne '.git') {
        throw "Unsupported repository layout: common git dir '$common' is not a '.git' directory of a checkout."
    }
    return (Split-Path $common -Parent)
}

function Resolve-WmuxBaseRef {
    <# Resolves the integration branch (default master); falls back to origin/<base>. #>
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$Base = 'master')
    foreach ($candidate in @($Base, "origin/$Base")) {
        $r = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "$candidate^{commit}") -AllowFailure
        if ($r.ExitCode -eq 0) { return $candidate }
    }
    throw "Base ref '$Base' not found (also tried origin/$Base)."
}

function Get-WmuxCurrentBranch {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $r = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('branch', '--show-current') -AllowFailure
    return $r.Output.Trim()
}

function Resolve-WmuxWpId {
    <#
    .SYNOPSIS
        Infers the WP id of a worktree: the worktree directory name (new-worktree.ps1
        layout ..\wmux-wt\<id>) when the branch is wp/<id>-..., else the longest
        docs/arch/wp/<id>.md id that prefixes the branch name. Returns $null if unknown.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $branch = Get-WmuxCurrentBranch -RepoRoot $RepoRoot
    $leaf = Split-Path $RepoRoot -Leaf
    if ((Test-WmuxWpId $leaf) -and ($branch -eq "wp/$leaf" -or $branch.StartsWith("wp/$leaf-"))) { return $leaf }
    if ($branch -notlike 'wp/*') { return $null }
    $specDir = Join-Path $RepoRoot 'docs/arch/wp'
    $ids = @(Get-ChildItem -LiteralPath $specDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName } | Where-Object { Test-WmuxWpId $_ } |
            Sort-Object -Property Length -Descending)
    foreach ($id in $ids) {
        if ($branch -eq "wp/$id" -or $branch.StartsWith("wp/$id-")) { return $id }
    }
    return $null
}

function Resolve-WmuxZig {
    <#
    .SYNOPSIS
        Finds zig.exe: -Zig, then $env:ZIG, then zig on PATH, then
        ~\zig-x86_64-windows-0.15.2\zig.exe. Warns when the version is not 0.15.2.
    #>
    param([string]$Zig, [string]$Tag = 'tooling')
    if ($Zig) {
        if (-not (Test-Path -LiteralPath $Zig -PathType Leaf)) { throw "-Zig '$Zig' does not exist." }
        $found = (Resolve-Path -LiteralPath $Zig).ProviderPath
    } else {
        $candidates = [System.Collections.Generic.List[string]]::new()
        if ($env:ZIG) { $candidates.Add($env:ZIG) }
        $cmd = Get-Command zig -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $candidates.Add($cmd.Source) }
        $candidates.Add((Join-Path $HOME "zig-x86_64-windows-$script:ExpectedZigVersion\zig.exe"))
        $found = $null
        foreach ($c in $candidates) {
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $found = (Resolve-Path -LiteralPath $c).ProviderPath; break }
        }
        if (-not $found) {
            throw "zig not found. Pass -Zig <path>, set `$env:ZIG, or put Zig $script:ExpectedZigVersion on PATH."
        }
    }
    $version = (& $found version 2>$null | Out-String).Trim()
    if ($version -ne $script:ExpectedZigVersion) {
        Write-WmuxLine -Tag $Tag -Level WARN -Message "zig at '$found' reports version '$version'; the repo requires $script:ExpectedZigVersion."
    }
    return $found
}

function Get-WmuxZigCache {
    <#
    .SYNOPSIS
        Decides the Zig global cache all worktrees share (ADR-12.5). Zig's default
        (%LOCALAPPDATA%\zig) is already per-user and shared, so nothing is overridden
        unless the worktree sits on another drive than the cache (zig build asserts on
        cross-drive relative paths), in which case <WorktreesRoot>\.zig-global-cache
        is used. Returns { Dir, Override, Reason }.
    #>
    param([Parameter(Mandatory)][string]$WorktreeRoot, [Parameter(Mandatory)][string]$WorktreesRoot)
    $fromEnv = [bool]$env:ZIG_GLOBAL_CACHE_DIR
    $dir = if ($fromEnv) { $env:ZIG_GLOBAL_CACHE_DIR } else { Join-Path $env:LOCALAPPDATA 'zig' }
    $wtDrive = [System.IO.Path]::GetPathRoot((Resolve-WmuxPath $WorktreeRoot))
    $cacheDrive = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($dir))
    if ($wtDrive -ieq $cacheDrive) {
        $reason = if ($fromEnv) { 'ZIG_GLOBAL_CACHE_DIR from the environment' } else { 'Zig default, shared by every worktree of this user' }
        return [pscustomobject]@{ Dir = $dir; Override = $false; Reason = $reason }
    }
    $alt = Join-Path $WorktreesRoot '.zig-global-cache'
    return [pscustomobject]@{
        Dir      = $alt
        Override = $true
        Reason   = "worktree drive $wtDrive differs from cache drive $cacheDrive (zig build asserts on cross-drive paths)"
    }
}

function Test-WmuxPeMachine {
    <# True if $Path is a PE image for the given machine (default x64 = 0x8664). #>
    param([Parameter(Mandatory)][string]$Path, [uint16]$Machine = 0x8664)
    $fs = [System.IO.File]::OpenRead((Resolve-WmuxPath $Path))
    try {
        $br = [System.IO.BinaryReader]::new($fs)
        if ($fs.Length -lt 0x40 -or $br.ReadUInt16() -ne 0x5A4D) { return $false }
        $fs.Position = 0x3C
        $peOffset = $br.ReadInt32()
        if ($peOffset -le 0 -or ($peOffset + 6) -gt $fs.Length) { return $false }
        $fs.Position = $peOffset
        if ($br.ReadUInt32() -ne 0x00004550) { return $false }
        return ($br.ReadUInt16() -eq $Machine)
    } finally {
        $fs.Dispose()
    }
}

# --------------------------------------------------------------------------
# Child processes with live output, log file and timeout
# --------------------------------------------------------------------------

function Stop-WmuxProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    & taskkill.exe /PID $ProcessId /T /F *> $null
}

function Invoke-WmuxProcess {
    <#
    .SYNOPSIS
        Runs a console program without a window, streaming stdout+stderr live to the
        host (unless -Quiet) and to -LogFile. Arguments are passed through
        ProcessStartInfo.ArgumentList (no quoting pitfalls). The whole process tree is
        killed on timeout or when the caller is interrupted (Ctrl+C).
        Returns { ExitCode, TimedOut, Duration, LogFile }; ExitCode 124 on timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [string]$LogFile,
        [int]$TimeoutSec = 0,
        [switch]$Quiet,
        [hashtable]$Environment
    )
    $WorkingDirectory = Resolve-WmuxPath $WorkingDirectory
    if ($LogFile) { $LogFile = Resolve-WmuxPath $LogFile }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    if ($Environment) {
        foreach ($k in $Environment.Keys) {
            if ($null -eq $Environment[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = [string]$Environment[$k] }
        }
    }

    $writer = $null
    if ($LogFile) {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        $writer = [System.IO.StreamWriter]::new($LogFile, $false, $utf8)
        $writer.AutoFlush = $true
        $writer.WriteLine("# $FilePath $($ArgumentList -join ' ')")
        $writer.WriteLine("# cwd: $WorkingDirectory")
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $started = $false
    $timedOut = $false
    $exitCode = -1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$proc.Start()
        $started = $true
        $proc.StandardInput.Close()
        $outTask = $proc.StandardOutput.ReadLineAsync()
        $errTask = $proc.StandardError.ReadLineAsync()
        $drainDeadline = $null
        while ($null -ne $outTask -or $null -ne $errTask) {
            $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
            if ($null -ne $outTask) { $pending.Add($outTask) }
            if ($null -ne $errTask) { $pending.Add($errTask) }
            [void][System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), 250)
            foreach ($which in 'out', 'err') {
                $task = if ($which -eq 'out') { $outTask } else { $errTask }
                if ($null -eq $task -or -not $task.IsCompleted) { continue }
                $line = $task.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    if ($which -eq 'out') { $outTask = $null } else { $errTask = $null }
                    continue
                }
                if ($writer) { $writer.WriteLine($line) }
                if (-not $Quiet) { Write-Host $line }
                if ($which -eq 'out') { $outTask = $proc.StandardOutput.ReadLineAsync() } else { $errTask = $proc.StandardError.ReadLineAsync() }
            }
            if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                $timedOut = $true
                Stop-WmuxProcessTree -ProcessId $proc.Id
                break
            }
            # A grandchild that inherited our pipes (e.g. a leaked app instance) must not
            # keep us waiting: once the main process is gone, drain for 5 s, then stop.
            if ($proc.HasExited) {
                if ($null -eq $drainDeadline) { $drainDeadline = [DateTime]::UtcNow.AddSeconds(5) }
                elseif ([DateTime]::UtcNow -gt $drainDeadline) { break }
            }
        }
        if ($timedOut) {
            [void]$proc.WaitForExit(10000)
            $exitCode = 124
            if ($writer) { $writer.WriteLine("# TIMEOUT after $TimeoutSec s; process tree killed") }
        } else {
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
        }
    } finally {
        if ($started -and -not $proc.HasExited) { Stop-WmuxProcessTree -ProcessId $proc.Id }
        $sw.Stop()
        if ($writer) {
            $writer.WriteLine("# exit code $exitCode after $([int]$sw.Elapsed.TotalSeconds) s")
            $writer.Dispose()
        }
        $proc.Dispose()
    }
    return [pscustomobject]@{ ExitCode = $exitCode; TimedOut = $timedOut; Duration = $sw.Elapsed; LogFile = $LogFile }
}

function Get-WmuxPwshExe {
    <# The pwsh running this script (child scripts use the same PowerShell). #>
    $path = (Get-Process -Id $PID).Path
    if ($path -and (Split-Path $path -Leaf) -match '^pwsh(\.exe)?$') { return $path }
    $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw 'pwsh (PowerShell 7) was not found.'
}

function Get-WmuxScriptParameters {
    <# Parameter names (lower-case) -> declared type name of a .ps1, read from its AST. #>
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-WmuxPath $Path), [ref]$tokens, [ref]$errors)
    $map = @{}
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $map[$p.Name.VariablePath.UserPath.ToLowerInvariant()] = $p.StaticType.Name
        }
    }
    return $map
}

function Test-WmuxPowerShellSyntax {
    <# Parses a PowerShell file; returns the list of parse errors (empty if fine). #>
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-WmuxPath $Path), [ref]$tokens, [ref]$errors)
    return , @($errors)
}

# --------------------------------------------------------------------------
# Build steps
# --------------------------------------------------------------------------

function Get-WmuxBuildSteps {
    <#
    .SYNOPSIS
        Lists the steps of `zig build -l` (with the win32 target options).
        Returns $null if the build script could not be configured.
    #>
    param(
        [Parameter(Mandatory)][string]$Zig,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$LogFile,
        [hashtable]$Environment
    )
    $res = Invoke-WmuxProcess -FilePath $Zig -ArgumentList (@('build', '-l') + (Get-WmuxTargetArgs)) `
        -WorkingDirectory $RepoRoot -LogFile $LogFile -Quiet -Environment $Environment
    if ($res.ExitCode -ne 0) { return $null }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines((Resolve-WmuxPath $LogFile))) {
        if ($line -match '^\s{2}(\S+)\s') { $names.Add($Matches[1]) }
    }
    return , $names.ToArray()
}

function Get-WmuxDeclaredSteps {
    <# Step names declared with b.step("name", ...) in build.zig and src/build/*.zig (static). #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $RepoRoot = Resolve-WmuxPath $RepoRoot
    $files = [System.Collections.Generic.List[string]]::new()
    $buildZig = Join-Path $RepoRoot 'build.zig'
    if (Test-Path -LiteralPath $buildZig) { $files.Add($buildZig) }
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src/build') -Filter '*.zig' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $files.Add($_.FullName) }
    $names = foreach ($f in $files) {
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f), 'b\.step\(\s*"([^"]+)"')) { $m.Groups[1].Value }
    }
    return , @($names | Sort-Object -Unique)
}

# --------------------------------------------------------------------------
# Changed files vs the integration branch
# --------------------------------------------------------------------------

function Get-WmuxChangedFiles {
    <#
    .SYNOPSIS
        Files changed on this branch vs merge-base(<BaseRef>, HEAD), plus (unless
        -CommittedOnly) uncommitted tracked changes and untracked files.
        Renames are reported as delete + add so both paths are checked.
        Returns { MergeBase, Head, Files[] } with Files = { Path, Status, Committed, Uncommitted, Untracked }.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BaseRef,
        [switch]$CommittedOnly
    )
    $mergeBase = (Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('merge-base', $BaseRef, 'HEAD')).Output.Trim()
    $head = (Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('rev-parse', 'HEAD')).Output.Trim()
    $map = [ordered]@{}

    $addEntry = {
        param([string]$Path, [string]$Status, [string]$Kind)
        if (-not $map.Contains($Path)) {
            $map[$Path] = [pscustomobject]@{ Path = $Path; Status = $Status; Committed = $false; Uncommitted = $false; Untracked = $false }
        }
        $entry = $map[$Path]
        switch ($Kind) {
            'committed' { $entry.Committed = $true; $entry.Status = $Status }
            'uncommitted' { $entry.Uncommitted = $true; if (-not $entry.Committed) { $entry.Status = $Status } }
            'untracked' { $entry.Untracked = $true; $entry.Status = '?' }
        }
    }

    $parseNameStatus = {
        param([string]$Raw, [string]$Kind)
        $parts = @($Raw -split "`0" | Where-Object { $_ -ne '' })
        for ($i = 0; $i + 1 -lt $parts.Count; $i += 2) {
            & $addEntry $parts[$i + 1] $parts[$i].Substring(0, 1) $Kind
        }
    }

    $committed = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('diff', '--name-status', '--no-renames', '-z', $mergeBase, 'HEAD')
    & $parseNameStatus $committed.Output 'committed'
    if (-not $CommittedOnly) {
        # Porcelain v1 with -z: "XY <path>" records; ?? = untracked, else index/worktree change.
        $status = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames')
        foreach ($rec in @($status.Output -split "`0" | Where-Object { $_.Length -ge 4 })) {
            $xy = $rec.Substring(0, 2)
            $path = $rec.Substring(3)
            if ($xy -eq '??') { & $addEntry $path '?' 'untracked' }
            elseif ($xy -ne '!!') {
                $letter = if ($xy[1] -ne ' ') { [string]$xy[1] } else { [string]$xy[0] }
                & $addEntry $path $letter 'uncommitted'
            }
        }
    }
    return [pscustomobject]@{ MergeBase = $mergeBase; Head = $head; Files = @($map.Values) }
}

# --------------------------------------------------------------------------
# Globs (owns/touches/appends in WP specs)
# --------------------------------------------------------------------------

function ConvertTo-WmuxGlobRegexBody {
    param([AllowEmptyString()][string]$Glob)
    $sb = [System.Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
                $i += 2
                if ($i -lt $Glob.Length -and $Glob[$i] -eq '/') {
                    [void]$sb.Append('(?:[^/]*/)*')   # "**/" = zero or more directories
                    $i++
                } else {
                    [void]$sb.Append('.*')            # "**" = anything, across directories
                }
            } else {
                [void]$sb.Append('[^/]*')
                $i++
            }
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]')
            $i++
        } elseif ($c -eq '{') {
            $depth = 0; $close = -1
            for ($j = $i; $j -lt $Glob.Length; $j++) {
                if ($Glob[$j] -eq '{') { $depth++ }
                elseif ($Glob[$j] -eq '}') { $depth--; if ($depth -eq 0) { $close = $j; break } }
            }
            if ($close -lt 0) {
                [void]$sb.Append('\{')
                $i++
            } else {
                $inner = $Glob.Substring($i + 1, $close - $i - 1)
                $alts = [System.Collections.Generic.List[string]]::new()
                $depth = 0; $startAt = 0
                for ($j = 0; $j -lt $inner.Length; $j++) {
                    if ($inner[$j] -eq '{') { $depth++ }
                    elseif ($inner[$j] -eq '}') { $depth-- }
                    elseif ($inner[$j] -eq ',' -and $depth -eq 0) { $alts.Add($inner.Substring($startAt, $j - $startAt)); $startAt = $j + 1 }
                }
                $alts.Add($inner.Substring($startAt))
                $bodies = foreach ($a in $alts) { ConvertTo-WmuxGlobRegexBody $a }
                [void]$sb.Append('(?:' + ($bodies -join '|') + ')')
                $i = $close + 1
            }
        } else {
            [void]$sb.Append([regex]::Escape([string]$c))
            $i++
        }
    }
    return $sb.ToString()
}

function ConvertTo-WmuxGlobRegex {
    <#
    .SYNOPSIS
        Converts a repo-relative glob to an anchored regex: ** spans directories,
        * and ? stay inside one path segment, {a,b} alternates, a trailing / means
        "everything below". Paths use forward slashes.
    #>
    param([Parameter(Mandatory)][string]$Glob)
    $g = $Glob.Trim().Replace('\', '/')
    while ($g.StartsWith('./')) { $g = $g.Substring(2) }
    $g = $g.TrimStart('/')
    if ($g.EndsWith('/')) { $g += '**' }
    return '^' + (ConvertTo-WmuxGlobRegexBody $g) + '$'
}

function Test-WmuxGlobMatch {
    <# Case-insensitive glob match of a repo-relative path (Windows checkouts are case-insensitive). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Glob)
    $p = $Path.Replace('\', '/').TrimStart('/')
    return [regex]::IsMatch($p, (ConvertTo-WmuxGlobRegex $Glob), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# --------------------------------------------------------------------------
# YAML subset (WP spec front matter)
# --------------------------------------------------------------------------
# Supported: block mappings, block sequences (of scalars or mappings), plain and
# quoted scalars, flow sequences [a, b], flow mappings {a: b}, {} and [], comments.
# Not supported (rejected with a line number): tabs, block scalars (| >), anchors.

function Remove-WmuxYamlComment {
    param([AllowEmptyString()][string]$Line)
    $quote = [char]0
    $canQuote = $true
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote -ne [char]0) {
            if ($quote -eq '"' -and $c -eq '\') { $i++; continue }
            if ($c -eq $quote) { $quote = [char]0 }
            continue
        }
        if (($c -eq '"' -or $c -eq "'") -and $canQuote) { $quote = $c; continue }
        if ($c -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($Line[$i - 1]))) { return $Line.Substring(0, $i).TrimEnd() }
        if (-not [char]::IsWhiteSpace($c)) { $canQuote = ($c -in @(':', '-', '[', ',', '{')) }
    }
    return $Line.TrimEnd()
}

function ConvertFrom-WmuxYamlScalar {
    param([AllowEmptyString()][string]$Text)
    $s = $Text.Trim()
    if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) {
        return ($s.Substring(1, $s.Length - 2) -replace '\\(.)', {
                $escaped = $_.Groups[1].Value
                if ($escaped -ceq 'n') { "`n" } elseif ($escaped -ceq 't') { "`t" } else { $escaped }
            })
    }
    if ($s.Length -ge 2 -and $s.StartsWith("'") -and $s.EndsWith("'")) {
        return $s.Substring(1, $s.Length - 2).Replace("''", "'")
    }
    if ($s -in @('~', 'null', 'Null', 'NULL')) { return $null }
    return $s
}

function Split-WmuxYamlFlow {
    param([AllowEmptyString()][string]$Text)
    $parts = [System.Collections.Generic.List[string]]::new()
    $depth = 0; $quote = [char]0; $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($quote -ne [char]0) { if ($c -eq $quote) { $quote = [char]0 }; continue }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c }
        elseif ($c -eq '[' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ']' -or $c -eq '}') { $depth-- }
        elseif ($c -eq ',' -and $depth -eq 0) { $parts.Add($Text.Substring($start, $i - $start)); $start = $i + 1 }
    }
    $parts.Add($Text.Substring($start))
    return , $parts.ToArray()
}

function Test-WmuxYamlSeqItem([string]$Text) { return ($Text -eq '-' -or $Text.StartsWith('- ')) }

function Test-WmuxYamlMapStart([string]$Text) {
    return [bool]($Text -match '^(?:"[^"]*"|''[^'']*''|[^\s:"''#\[\{][^:]*?)\s*:(?:\s|$)')
}

function ConvertFrom-WmuxYamlInline {
    param($St, $Item, [string]$Text)
    $where = "$($St.Source):$($Item.Line)"
    if ($Text.StartsWith('[')) {
        if (-not $Text.EndsWith(']')) { throw "${where}: unterminated flow sequence '$Text'" }
        $list = [System.Collections.Generic.List[object]]::new()
        $inner = $Text.Substring(1, $Text.Length - 2).Trim()
        if ($inner -ne '') {
            foreach ($part in (Split-WmuxYamlFlow $inner)) { $list.Add((ConvertFrom-WmuxYamlScalar $part)) }
        }
        return , $list
    }
    if ($Text.StartsWith('{')) {
        if (-not $Text.EndsWith('}')) { throw "${where}: unterminated flow mapping '$Text'" }
        $map = [ordered]@{}
        $inner = $Text.Substring(1, $Text.Length - 2).Trim()
        if ($inner -ne '') {
            foreach ($part in (Split-WmuxYamlFlow $inner)) {
                if ($part -notmatch '^\s*(?<k>[^:]+?)\s*:\s*(?<v>.*?)\s*$') { throw "${where}: bad flow mapping entry '$part'" }
                $map[(ConvertFrom-WmuxYamlScalar $Matches['k'])] = ConvertFrom-WmuxYamlScalar $Matches['v']
            }
        }
        return $map
    }
    if ($Text[0] -in @('|', '>', '&', '!', '%', '@', '`')) {
        throw "${where}: unsupported YAML construct '$Text' (quote the value)"
    }
    return (ConvertFrom-WmuxYamlScalar $Text)
}

function Read-WmuxYamlBlock {
    param($St, [int]$Indent)
    if (Test-WmuxYamlSeqItem $St.Items[$St.Pos].Text) { return , (Read-WmuxYamlSeq $St $Indent) }
    return (Read-WmuxYamlMap $St $Indent)
}

function Read-WmuxYamlMap {
    param($St, [int]$Indent)
    $map = [ordered]@{}
    while ($St.Pos -lt $St.Items.Count) {
        $it = $St.Items[$St.Pos]
        if ($it.Indent -lt $Indent) { break }
        if ($it.Indent -gt $Indent) { throw "$($St.Source):$($it.Line): unexpected indentation before '$($it.Text)'" }
        if (Test-WmuxYamlSeqItem $it.Text) { break }
        if ($it.Text -notmatch '^(?<k>"[^"]*"|''[^'']*''|[^\s:"''#\[\{][^:]*?)\s*:(?:\s+(?<v>.*))?$') {
            throw "$($St.Source):$($it.Line): expected 'key: value', got '$($it.Text)'"
        }
        $key = ConvertFrom-WmuxYamlScalar $Matches['k']
        $rest = $Matches['v']
        if ($map.Contains($key)) { throw "$($St.Source):$($it.Line): duplicate key '$key'" }
        $St.Pos++
        if ($rest -and $rest.Trim() -ne '') {
            $map[$key] = ConvertFrom-WmuxYamlInline $St $it $rest.Trim()
        } elseif ($St.Pos -lt $St.Items.Count -and $St.Items[$St.Pos].Indent -gt $Indent) {
            $map[$key] = Read-WmuxYamlBlock $St $St.Items[$St.Pos].Indent
        } elseif ($St.Pos -lt $St.Items.Count -and $St.Items[$St.Pos].Indent -eq $Indent -and (Test-WmuxYamlSeqItem $St.Items[$St.Pos].Text)) {
            $map[$key] = Read-WmuxYamlSeq $St $Indent
        } else {
            $map[$key] = $null
        }
    }
    return $map
}

function Read-WmuxYamlSeq {
    param($St, [int]$Indent)
    $list = [System.Collections.Generic.List[object]]::new()
    while ($St.Pos -lt $St.Items.Count) {
        $it = $St.Items[$St.Pos]
        if ($it.Indent -gt $Indent) { throw "$($St.Source):$($it.Line): unexpected indentation before '$($it.Text)'" }
        if ($it.Indent -lt $Indent -or -not (Test-WmuxYamlSeqItem $it.Text)) { break }
        $rest = if ($it.Text -eq '-') { '' } else { $it.Text.Substring(2).Trim() }
        if ($rest -eq '') {
            $St.Pos++
            if ($St.Pos -lt $St.Items.Count -and $St.Items[$St.Pos].Indent -gt $Indent) {
                $list.Add((Read-WmuxYamlBlock $St $St.Items[$St.Pos].Indent))
            } else {
                $list.Add($null)
            }
        } elseif (Test-WmuxYamlMapStart $rest) {
            # "- key: value": the mapping's keys sit at the column of the first key.
            $afterDash = $it.Text.Substring(1)
            $column = $Indent + 1 + ($afterDash.Length - $afterDash.TrimStart().Length)
            $St.Items[$St.Pos] = [pscustomobject]@{ Indent = $column; Text = $rest; Line = $it.Line }
            $list.Add((Read-WmuxYamlMap $St $column))
        } else {
            $St.Pos++
            $list.Add((ConvertFrom-WmuxYamlInline $St $it $rest))
        }
    }
    return , $list
}

function ConvertFrom-WmuxYaml {
    <# Parses the YAML subset described above; returns an ordered dictionary (or list). #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [string]$Source = 'yaml',
        [int]$LineOffset = 0
    )
    $items = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $raw = $Lines[$i]
        $lineNo = $i + 1 + $LineOffset
        if ($raw -match '^\s*\t') { throw "${Source}:${lineNo}: tab indentation is not allowed in YAML" }
        $t = Remove-WmuxYamlComment $raw
        if ($t.Trim() -eq '') { continue }
        $items.Add([pscustomobject]@{ Indent = ($t.Length - $t.TrimStart(' ').Length); Text = $t.Trim(); Line = $lineNo })
    }
    if ($items.Count -eq 0) { return [ordered]@{} }
    $st = @{ Items = $items; Pos = 0; Source = $Source }
    $value = Read-WmuxYamlBlock $st $items[0].Indent
    if ($st.Pos -lt $items.Count) {
        $it = $items[$st.Pos]
        throw "${Source}:$($it.Line): unexpected content '$($it.Text)' (check indentation)"
    }
    return $value
}

function Read-WmuxFrontMatter {
    <# Parses the '---' delimited YAML front matter at the top of a markdown file. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Source = 'spec')
    $lines = $Text -split "`r?`n"
    if ($lines.Count -gt 0) { $lines[0] = $lines[0].TrimStart([char]0xFEFF) }
    if ($lines.Count -eq 0 -or $lines[0].TrimEnd() -ne '---') {
        throw "${Source}: missing YAML front matter (the first line must be '---')"
    }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd() -in @('---', '...')) { $end = $i; break }
    }
    if ($end -lt 0) { throw "${Source}: unterminated front matter (no closing '---')" }
    $body = if ($end -gt 1) { [string[]]$lines[1..($end - 1)] } else { [string[]]@() }
    return (ConvertFrom-WmuxYaml -Lines $body -Source $Source -LineOffset 1)
}

# --------------------------------------------------------------------------
# WP specs (docs/arch/wp/<id>.md)
# --------------------------------------------------------------------------

function ConvertTo-WmuxPathEntries {
    <# Normalizes owns/touches/appends values to { Path, Reason } objects. #>
    param($Value, [string]$Field, [string]$Source)
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return , $out.ToArray() }
    # A single string or mapping becomes a one-element list; lists are enumerated.
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        if ($v -is [System.Collections.IDictionary]) {
            if (-not $v.Contains('path') -or -not $v['path']) { throw "${Source}: every '$Field' mapping needs a 'path'" }
            $out.Add([pscustomobject]@{ Path = [string]$v['path']; Reason = [string]$v['reason'] })
        } else {
            $out.Add([pscustomobject]@{ Path = [string]$v; Reason = '' })
        }
    }
    return , $out.ToArray()
}

function Get-WmuxWpSpec {
    <#
    .SYNOPSIS
        Loads docs/arch/wp/<id>.md. The version on <BaseRef> is authoritative (a branch
        cannot grant itself ownership); the worktree copy is used only when the spec is
        not on the base yet. -SpecPath reads an explicit file instead. Returns $null if
        no spec exists.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Wp,
        [string]$BaseRef,
        [string]$SpecPath
    )
    $rel = "docs/arch/wp/$Wp.md"
    $modified = $false
    if ($SpecPath) {
        if (-not (Test-Path -LiteralPath $SpecPath -PathType Leaf)) { throw "-SpecPath '$SpecPath' does not exist." }
        $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $SpecPath).ProviderPath)
        $source = 'file'
        $rel = $SpecPath
    } else {
        $baseText = $null
        if ($BaseRef) {
            $r = Invoke-WmuxGit -RepoRoot $RepoRoot -Arguments @('show', "${BaseRef}:$rel") -AllowFailure
            if ($r.ExitCode -eq 0) { $baseText = $r.Output }
        }
        $wtPath = Join-Path $RepoRoot $rel
        $wtText = if (Test-Path -LiteralPath $wtPath -PathType Leaf) { [System.IO.File]::ReadAllText($wtPath) } else { $null }
        if ($null -ne $baseText) {
            $text = $baseText
            $source = 'base'
            if ($null -ne $wtText -and ($wtText -replace "`r`n", "`n") -ne ($baseText -replace "`r`n", "`n")) { $modified = $true }
        } elseif ($null -ne $wtText) {
            $text = $wtText
            $source = 'worktree'
        } else {
            return $null
        }
    }
    $data = Read-WmuxFrontMatter -Text $text -Source $rel
    if ($data -isnot [System.Collections.IDictionary]) { throw "${rel}: front matter must be a mapping" }
    return [pscustomobject]@{
        Wp               = $Wp
        Path             = $rel
        Source           = $source
        ModifiedOnBranch = $modified
        Data             = $data
        Owns             = (ConvertTo-WmuxPathEntries $data['owns'] 'owns' $rel)
        Touches          = (ConvertTo-WmuxPathEntries $data['touches'] 'touches' $rel)
        Appends          = (ConvertTo-WmuxPathEntries $data['appends'] 'appends' $rel)
    }
}

# --------------------------------------------------------------------------
# Zig test output and test/known-failures.txt
# --------------------------------------------------------------------------

function Read-WmuxKnownFailures {
    <#
    .SYNOPSIS
        Reads test/known-failures.txt: one fully qualified Zig test name per line,
        optional trailing '*' = prefix match, ' # reason' comment; '#' lines are comments.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , $entries.ToArray() }
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines((Resolve-WmuxPath $Path))) {
        $n++
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $reason = ''
        $hash = $t.IndexOf(' #')
        if ($hash -ge 0) { $reason = $t.Substring($hash + 2).Trim(); $t = $t.Substring(0, $hash).TrimEnd() }
        $prefix = $t.EndsWith('*')
        $name = if ($prefix) { $t.Substring(0, $t.Length - 1) } else { $t }
        $entries.Add([pscustomobject]@{ Name = $name; Prefix = $prefix; Reason = $reason; Line = $n })
    }
    return , $entries.ToArray()
}

function Find-WmuxKnownFailure {
    <# Returns the known-failures entry matching a test name (exact or prefix), else $null. #>
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][object[]]$Entries = @())
    foreach ($e in $Entries) {
        if ($e.Prefix) {
            if ($Name.StartsWith($e.Name, [System.StringComparison]::Ordinal)) { return $e }
        } elseif ($Name -ceq $e.Name) {
            return $e
        }
    }
    return $null
}

function ConvertFrom-WmuxZigTestLog {
    <#
    .SYNOPSIS
        Extracts test results from `zig build test` output (Zig 0.15 build runner):
          error: '<name>' failed|leaked|logged errors[: ...]
          error: while executing test '<name>', the following command <term> ...  (crash)
        Compile errors are lines of the form <file>:<line>:<col>: error: ...
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $failures = [ordered]@{}
    $compileErrors = [System.Collections.Generic.List[string]]::new()
    $summary = $null
    foreach ($l in $Lines) {
        if ($l -match "^error: '(.+?)' (failed|leaked|logged errors)(?::|$)") {
            if (-not $failures.Contains($Matches[1])) { $failures[$Matches[1]] = $Matches[2] }
            continue
        }
        if ($l -match "^error: while executing test '(.+?)', the following command ") {
            if (-not $failures.Contains($Matches[1])) { $failures[$Matches[1]] = 'crashed' }
            continue
        }
        if ($l -match ':\d+:\d+: error: ') { $compileErrors.Add($l.Trim()) ; continue }
        if ($l -match '^Build Summary: ') { $summary = $l.Trim() }
    }
    $passed = $null; $total = $null
    if ($summary -and $summary -match '(\d+)/(\d+) tests passed') { $passed = [int]$Matches[1]; $total = [int]$Matches[2] }
    return [pscustomobject]@{
        Failures      = $failures
        CompileErrors = $compileErrors.ToArray()
        Summary       = $summary
        TestsPassed   = $passed
        TestsTotal    = $total
    }
}

Export-ModuleMember -Function @(
    'Write-WmuxLine', 'Resolve-WmuxPath', 'Test-WmuxWpId', 'Get-WmuxTargetArgs', 'Invoke-WmuxGit', 'Split-WmuxLines',
    'Get-WmuxRepoRoot', 'Get-WmuxMainRepoRoot', 'Resolve-WmuxBaseRef', 'Get-WmuxCurrentBranch',
    'Resolve-WmuxWpId', 'Resolve-WmuxZig', 'Get-WmuxZigCache', 'Test-WmuxPeMachine',
    'Stop-WmuxProcessTree', 'Invoke-WmuxProcess', 'Get-WmuxPwshExe', 'Get-WmuxScriptParameters',
    'Test-WmuxPowerShellSyntax', 'Get-WmuxBuildSteps', 'Get-WmuxDeclaredSteps', 'Get-WmuxChangedFiles',
    'ConvertTo-WmuxGlobRegex', 'Test-WmuxGlobMatch', 'ConvertFrom-WmuxYaml', 'Read-WmuxFrontMatter',
    'Get-WmuxWpSpec', 'Read-WmuxKnownFailures', 'Find-WmuxKnownFailure', 'ConvertFrom-WmuxZigTestLog'
)
