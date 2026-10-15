# wmux spike S6: shared helpers (dot-source). PowerShell 7.
# Every file this spike puts into WindowsApps is named wmuxspikefwd*; s6-cleanup.ps1
# removes all of them plus the spike registry keys.
$ErrorActionPreference = 'Stop'
$S6 = [ordered]@{}
$S6.Proto = $PSScriptRoot
$S6.Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
$S6.Scratch = Join-Path $S6.Root 'zig-out\spike-s6'
$S6.Bin = Join-Path $S6.Scratch 'bin'
$S6.Run = Join-Path $S6.Scratch 'run'
$S6.Results = Join-Path $S6.Scratch 'results'
$S6.Install = Join-Path $S6.Scratch 'Programs X\wmux spike'          # path with spaces
$S6.InstallU = Join-Path $S6.Scratch ('Pr' + [char]0x00F3 + 'grams ' + [char]0x00E9 + '\wmux')  # non-ASCII path
$S6.TargetName = 'wmuxspikefwd-target.exe'
$S6.Target = Join-Path $S6.Install "cli\$($S6.TargetName)"
$S6.TargetU = Join-Path $S6.InstallU "cli\$($S6.TargetName)"
$S6.Fwd = Join-Path $S6.Bin 'wmuxspikefwd-fwd-x64.exe'
$S6.WA = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$S6.RegKey = 'HKCU:\Software\wmuxspikefwd'
$S6.AppPathsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
$S6.Bash = 'C:\Program Files\Git\bin\bash.exe'
$S6.Pwsh = (Get-Command pwsh.exe).Source
$S6.WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$S6.Cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
foreach ($d in $S6.Run, $S6.Results) { New-Item -ItemType Directory -Force $d | Out-Null }

function ConvertTo-MsysPath([string]$p) {
    if ($p -match '^([A-Za-z]):\\(.*)$') { return '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/') }
    return ($p -replace '\\', '/')
}

# MSVCRT / CommandLineToArgvW quoting of one argument.
function ConvertTo-MsvcrtArg([string]$a) {
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    $sb = [Text.StringBuilder]::new('"')
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append([char]92, 2 * $bs + 1).Append([char]34); $bs = 0; continue }
        if ($bs) { [void]$sb.Append([char]92, $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs) { [void]$sb.Append([char]92, 2 * $bs) }
    [void]$sb.Append('"')
    return $sb.ToString()
}
# Escape a command line for one pass of cmd.exe parsing (caret before every
# metacharacter, quotes included, so cmd never enters a quoted region).
function ConvertTo-CmdEscaped([string]$line) { return ($line -replace '([\^&|<>()"])', '^$1') }
function ConvertTo-PsSingle([string]$a) { return "'" + $a.Replace("'", "''") + "'" }
function ConvertTo-BashSingle([string]$a) { return "'" + $a.Replace("'", "'\''") + "'" }

# Start a process hidden (no window, never foreground), capture stdout/stderr as
# bytes, optional stdin bytes, optional full environment replacement.
function Invoke-Proc {
    param(
        [Parameter(Mandatory)][string]$File,
        [string]$Arguments = '',
        [byte[]]$Stdin = $null,
        [System.Collections.IDictionary]$Env = $null,
        [hashtable]$EnvAdd = $null,
        [int]$TimeoutMs = 60000
    )
    $psi = [Diagnostics.ProcessStartInfo]::new($File)
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $S6.Run
    if ($Env) { $psi.Environment.Clear(); foreach ($k in $Env.Keys) { $psi.Environment[$k] = $Env[$k] } }
    if ($EnvAdd) { foreach ($k in $EnvAdd.Keys) { $psi.Environment[$k] = $EnvAdd[$k] } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $outMs = [IO.MemoryStream]::new(); $errMs = [IO.MemoryStream]::new()
    $t1 = $p.StandardOutput.BaseStream.CopyToAsync($outMs)
    $t2 = $p.StandardError.BaseStream.CopyToAsync($errMs)
    if ($Stdin) { try { $p.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Length) } catch {} }
    try { $p.StandardInput.Close() } catch {}
    $timedOut = -not $p.WaitForExit($TimeoutMs)
    if ($timedOut) { try { $p.Kill($true) } catch {}; $p.WaitForExit() }
    [void][Threading.Tasks.Task]::WaitAll(@($t1, $t2), 10000)
    $sw.Stop()
    $ob = $outMs.ToArray(); $eb = $errMs.ToArray()
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Out      = [Text.Encoding]::UTF8.GetString($ob)
        OutBytes = $ob
        Err      = [Text.Encoding]::UTF8.GetString($eb)
        Ms       = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        TimedOut = $timedOut
        Pid      = $p.Id
    }
}

# Run a script in a shell. cmd: one line (cmd /d /s /c). pwsh/winps: .ps1 file
# (UTF-8 BOM). bash: Git Bash login shell with an LF .sh file.
function Invoke-InShell {
    param(
        [Parameter(Mandatory)][ValidateSet('cmd', 'pwsh', 'winps', 'bash')][string]$Shell,
        [Parameter(Mandatory)][string]$Script,
        [byte[]]$Stdin = $null,
        [System.Collections.IDictionary]$Env = $null,
        [hashtable]$EnvAdd = $null,
        [int]$TimeoutMs = 120000
    )
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    switch ($Shell) {
        'cmd' { return Invoke-Proc -File $S6.Cmd -Arguments "/d /s /c `"$Script`"" -Stdin $Stdin -Env $Env -EnvAdd $EnvAdd -TimeoutMs $TimeoutMs }
        { $_ -in 'pwsh', 'winps' } {
            $f = Join-Path $S6.Run "s-$id.ps1"
            [IO.File]::WriteAllText($f, $Script, [Text.UTF8Encoding]::new($true))
            $exe = if ($Shell -eq 'pwsh') { $S6.Pwsh } else { $S6.WinPs }
            return Invoke-Proc -File $exe -Arguments "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$f`"" -Stdin $Stdin -Env $Env -EnvAdd $EnvAdd -TimeoutMs $TimeoutMs
        }
        'bash' {
            $f = Join-Path $S6.Run "s-$id.sh"
            [IO.File]::WriteAllText($f, ($Script -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
            return Invoke-Proc -File $S6.Bash -Arguments "--login `"$(ConvertTo-MsysPath $f)`"" -Stdin $Stdin -Env $Env -EnvAdd $EnvAdd -TimeoutMs $TimeoutMs
        }
    }
}

# "@@KEY value" marker lines out of shell output (profiles may print noise).
function Get-Markers([string]$text) {
    @($text -split "`r?`n" | Where-Object { $_ -match '^@@' })
}
function Get-Marker([string]$text, [string]$key) {
    foreach ($line in ($text -split "`r?`n")) { if ($line -match "^@@$([regex]::Escape($key)) ?(.*)$") { return $Matches[1] } }
    return $null
}

# argv[i] of a target JSON report, or $null (no report / too short).
function JArg($j, [int]$i) { if ($null -eq $j -or $null -eq $j.argv -or @($j.argv).Count -le $i) { return $null }; return @($j.argv)[$i] }

function Get-JsonLines([string]$text) {
    @($text -split "`r?`n" | Where-Object { $_.StartsWith('{"cmdline"') } | ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate })
}

function Save-Result([string]$name, $obj) {
    $path = Join-Path $S6.Results "$name.json"
    $json = $obj | ConvertTo-Json -Depth 12
    $json = $json.Replace($env:USERPROFILE.Replace('\', '\\'), '%USERPROFILE%').Replace($env:USERPROFILE, '%USERPROFILE%')
    $json = $json.Replace((ConvertTo-MsysPath $env:USERPROFILE), '/c/%USERPROFILE%')
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

function Install-SpikeTarget {
    foreach ($dir in $S6.Install, $S6.InstallU) {
        New-Item -ItemType Directory -Force (Join-Path $dir 'cli') | Out-Null
        Copy-Item (Join-Path $S6.Bin $S6.TargetName) (Join-Path $dir "cli\$($S6.TargetName)") -Force
    }
    New-Item -Path $S6.RegKey -Force | Out-Null
    New-ItemProperty -Path $S6.RegKey -Name InstallDir -Value $S6.Install -PropertyType String -Force | Out-Null
}

function Join-Bytes([byte[]]$a, [byte[]]$b) {
    $r = [byte[]]::new($a.Length + $b.Length)
    [Array]::Copy($a, 0, $r, 0, $a.Length)
    [Array]::Copy($b, 0, $r, $a.Length, $b.Length)
    return , $r
}

function Get-SpikeWindowsAppsFiles { @(Get-ChildItem -Force -LiteralPath $S6.WA -Filter 'wmuxspikefwd*' -ErrorAction SilentlyContinue) }
