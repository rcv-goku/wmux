# S4 spike: end-to-end behaviour of the wrapper prototype (shims\wrap\claude.exe = hardlink of wrapper.exe).
param([Parameter(Mandatory)] [string] $Root)
. "$PSScriptRoot\common.ps1"
$B = $script:S4Base
$W = "$Root\shims\wrap"
$wrap = "$W\claude.exe"
$bash = 'C:\Program Files\Git\bin\bash.exe'
$log = Join-Path $Root 'logs\wrapper.txt'
function Log($title, $r) { Add-Content $log ("==== {0}`n{1}`n--- stderr ---`n{2}`n--- exit {3} ({4} ms)" -f $title, $r.Out, $r.Err, $r.Code, $r.Ms) }
function Argv($r) { @([regex]::Matches($r.Out, 'S4IDENT argv\[(\d+)\]=<(.*)>') | ForEach-Object { $_.Groups[2].Value }) }
function Exe($r) { if ($r.Out -match 'S4IDENT exe=(.+)') { $Matches[1].Trim().Replace("$Root\", '') } else { '-' } }
$fgLog = Join-Path $Root 'logs\fg-wrapper.txt'
$job = Start-S4FgSampler $fgLog
$rows = [System.Collections.Generic.List[object]]::new()

# E1/E2: typed in each shell; exit code must come back through the wrapper (S4_EXIT=42).
$shellCmds = [ordered]@{
    # cmd: raw command line (cmd does not parse MSVCRT quoting) and delayed expansion for the exit code
    'cmd'      = @('C:\Windows\System32\cmd.exe', @(), '/d /v:on /s /c "claude a "b c" & echo EXIT=!ERRORLEVEL!"')
    'pwsh 7'   = @('C:\Program Files\PowerShell\7\pwsh.exe', @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'claude a ''b c''; "EXIT=$LASTEXITCODE"'), $null)
    'ps 5.1'   = @('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'claude a ''b c''; "EXIT=$LASTEXITCODE"'), $null)
    'git bash' = @($bash, @('-c', 'claude a ''b c''; echo EXIT=$?'), $null)
}
foreach ($real in @(@{ Id = 'E1 native'; Path = "$W;$Root\native;$B" }, @{ Id = 'E2 npm (bypass)'; Path = "$W;$Root\npm;$B" })) {
    foreach ($sh in $shellCmds.Keys) {
        $file, $argList, $raw = $shellCmds[$sh]
        $r = Invoke-S4 -File $file -ArgList $argList -RawArgs $raw -Path $real.Path -Cwd $Root -Env @{ S4_EXIT = '42'; S4_WRAP_VERBOSE = '1' }
        Log "$($real.Id) :: $sh" $r
        $exit = if ($r.Out -match 'EXIT=(\d+)') { $Matches[1] } else { '?' }
        $rows.Add([pscustomobject]@{ Test = $real.Id; Via = $sh; Ran = (Exe $r); Argv = ((Argv $r) -join ' | '); ShellSaw = $exit })
    }
}

# E3: argv fidelity through every real-binary kind (argv handed to the wrapper by CreateProcess directly).
$nasty = @('plain', 'with space', 'quote"inside', 'amp&echo INJECTED', 'pct%PATH%pct', 'caret^x', 'bang!x', 'paren(x)', 'trail\', 'back\\"slash', '', 'pipe|x', 'lt<x>gt', 'uni-é')
foreach ($k in @(@{ Id = 'native exe (verbatim tail)'; Path = "$W;$Root\native;$B"; Env = @{} },
                 @{ Id = 'npm .cmd bypass -> node.exe'; Path = "$W;$Root\npm;$B"; Env = @{ S4_WRAP_CMDSHIM = 'bypass' } },
                 @{ Id = 'npm .cmd via cmd.exe (safe quoting)'; Path = "$W;$Root\npm;$B"; Env = @{ S4_WRAP_CMDSHIM = 'cmd' } },
                 @{ Id = 'npm .cmd via cmd.exe (raw tail, unsafe)'; Path = "$W;$Root\npm;$B"; Env = @{ S4_WRAP_CMDSHIM = 'raw' } },
                 @{ Id = 'npm .ps1 via pwsh -File'; Path = "$W;$Root\npm;$B"; Env = @{ S4_WRAP_REAL = "$Root\npm\claude.ps1" } })) {
    $envs = $k.Env + @{ S4_WRAP_VERBOSE = '1' }
    $r = Invoke-S4 -File $wrap -ArgList $nasty -Path $k.Path -Cwd $Root -Env $envs
    Log "E3 $($k.Id)" $r
    $got = Argv $r
    # node.exe/ps1 targets get the script path as argv[1]; compare the tail only
    $skip = if ($got.Count -gt 1 -and $got[1] -like '*cli.js') { 2 } else { 1 }
    $tail = @($got | Select-Object -Skip $skip)
    $diff = for ($i = 0; $i -lt [Math]::Max($nasty.Count, $tail.Count); $i++) { if ($nasty[$i] -cne $tail[$i]) { "[$i] sent<$($nasty[$i])> got<$($tail[$i])>" } }
    $inj = if ($r.Out -match '(?m)^INJECTED') { ' INJECTION!' } else { '' }
    $rows.Add([pscustomobject]@{ Test = 'E3 argv fidelity'; Via = $k.Id; Ran = (Exe $r); Argv = ("{0}/{1} identical{2}" -f ($nasty.Count - @($diff).Count), $nasty.Count, $inj); ShellSaw = (@($diff) -join '; ') })
}

# E4: self-recursion guards.
$short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($W).ShortPath
$copyDir = Join-Path $Root 'shims\wrapcopy'
New-Item -ItemType Directory -Force $copyDir | Out-Null
Copy-Item "$Root\bin\wrapper.exe" "$copyDir\claude.exe" -Force
foreach ($t in @(
        @{ Id = 'explicit real = the shim itself'; Path = "$W;$Root\native;$B"; Env = @{ S4_WRAP_REAL = $wrap } },
        @{ Id = 'PATH has 8.3 alias of shim dir, string skip'; Path = "$W;$short;$Root\native;$B"; Env = @{ S4_WRAP_SELFSKIP = 'string' } },
        @{ Id = 'PATH has 8.3 alias of shim dir, file-id skip'; Path = "$W;$short;$Root\native;$B"; Env = @{} },
        @{ Id = 'stale wrapper copy later on PATH'; Path = "$W;$copyDir;$Root\native;$B"; Env = @{} })) {
    $r = Invoke-S4 -File $wrap -ArgList @('x') -Path $t.Path -Cwd $Root -Env ($t.Env + @{ S4_WRAP_VERBOSE = '1' })
    Log "E4 $($t.Id)" $r
    $hops = ([regex]::Matches($r.Err, 'WRAPPER real=')).Count
    $rows.Add([pscustomobject]@{ Test = 'E4 recursion'; Via = $t.Id; Ran = (Exe $r); Argv = "wrapper hops=$hops"; ShellSaw = "exit=$($r.Code) " + (($r.Err -split "`r?`n" | Where-Object { $_ -match 'recursion|skip' }) -join ' / ').Replace("$Root\", '') })
}

# E5: stdin/stdout redirection through the wrapper (pipe in, pipe out), both handle strategies.
foreach ($h in 'list', 'inherit') {
    $r = Invoke-S4 -File $wrap -ArgList @('pipe-test') -Path "$W;$Root\native;$B" -Cwd $Root -Env @{ S4_READ_STDIN = '1'; S4_WRAP_HANDLES = $h } -StdIn "hello from pipe`n"
    Log "E5 stdin/stdout handles=$h" $r
    $line = if ($r.Out -match 'S4IDENT stdin (.+)') { $Matches[1].Trim() } else { 'no stdin line' }
    $rows.Add([pscustomobject]@{ Test = 'E5 pipes'; Via = "handles=$h"; Ran = (Exe $r); Argv = $line; ShellSaw = "exit=$($r.Code)" })
}

# E6: exit codes (wrapper's own exit code as seen by CreateProcess/GetExitCodeProcess, and by shells).
foreach ($code in @('0', '1', '42', '255', '256', '-1', '0xC000013A')) {
    $r = Invoke-S4 -File $wrap -ArgList @() -Path "$W;$Root\native;$B" -Cwd $Root -Env @{ S4_EXIT = $code }
    $c = Invoke-S4 -File 'C:\Windows\System32\cmd.exe' -RawArgs '/d /v:on /s /c "claude & echo EXIT=!ERRORLEVEL!"' -Path "$W;$Root\native;$B" -Cwd $Root -Env @{ S4_EXIT = $code }
    $p = Invoke-S4 -File 'C:\Program Files\PowerShell\7\pwsh.exe' -ArgList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'claude; "EXIT=$LASTEXITCODE"') -Path "$W;$Root\native;$B" -Cwd $Root -Env @{ S4_EXIT = $code }
    $b = Invoke-S4 -File $bash -ArgList @('-c', 'claude; echo EXIT=$?') -Path "$W;$Root\native;$B" -Cwd $Root -Env @{ S4_EXIT = $code }
    $sx = { param($x) if ($x.Out -match 'EXIT=(-?\d+)') { $Matches[1] } else { '?' } }
    $rows.Add([pscustomobject]@{ Test = 'E6 exit code'; Via = "child exits $code"; Ran = ('wrapper exit={0} (0x{0:X8})' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$r.Code), 0)); Argv = ''; ShellSaw = ("cmd={0} pwsh={1} bash={2}" -f (& $sx $c), (& $sx $p), (& $sx $b)) })
}

# E7: launch overhead (median of 15 runs each, process start to exit, measured by the parent).
$direct = foreach ($i in 1..15) { (Invoke-S4 -File "$Root\native\claude.exe" -ArgList @('x') -Path "$Root\native;$B" -Cwd $Root).Ms }
$viaW = foreach ($i in 1..15) { (Invoke-S4 -File $wrap -ArgList @('x') -Path "$W;$Root\native;$B" -Cwd $Root).Ms }
$med = { param($xs) ($xs | Sort-Object)[[int][Math]::Floor($xs.Count / 2)] }
$rows.Add([pscustomobject]@{ Test = 'E7 overhead'; Via = 'median ms (15 runs)'; Ran = "direct=$(& $med $direct) wrapper=$(& $med $viaW)"; Argv = "direct: $($direct -join ',')"; ShellSaw = "wrapper: $($viaW -join ',')" })

$fg = Stop-S4FgSampler $job $fgLog $Root
foreach ($row in $rows) { "{0} | {1} | {2} | {3} | {4}" -f $row.Test, $row.Via, $row.Ran, $row.Argv.Replace("$Root\", '<R>\'), $row.ShellSaw }
"foreground samples=$($fg.Samples) violations=$($fg.Violations.Count)"
