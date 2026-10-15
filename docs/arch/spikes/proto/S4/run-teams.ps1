# S4 spike: teammate-command execution (Claude Code's POSIX "cd ... && env ... '<claude>' ..." shape) and
# tmux shim lookup. Dummies only: native\claude.exe and teams\tmux.exe are ident.exe copies.
param([Parameter(Mandatory)] [string] $Root)
. "$PSScriptRoot\common.ps1"
$B = $script:S4Base
$bash = 'C:\Program Files\Git\bin\bash.exe'
$log = Join-Path $Root 'logs\teams.txt'
function Log($title, $r) { Add-Content $log ("==== {0}`n{1}`n--- stderr ---`n{2}`n--- exit {3} ({4} ms)" -f $title, $r.Out, $r.Err, $r.Code, $r.Ms) }
function Brief($r) {
    $o = ($r.Out + "`n" + $r.Err) -split "`r?`n" | Where-Object { $_ -match 'S4IDENT (exe|cwd|env|argv\[[1-9])|S4TMUX|error|not recognized|cannot|incorrect|No such|SPAWNER' }
    (($o | Select-Object -First 9) -join ' / ').Replace("$Root\", '<R>\')
}
$rows = [System.Collections.Generic.List[object]]::new()
$fgLog = Join-Path $Root 'logs\fg-teams.txt'
$job = Start-S4FgSampler $fgLog

# T-A: the teammate launch line, shaped like the one Claude Code sends (public issue #42848 / cmux tests):
#      POSIX sh, Windows paths inside single quotes, env-assignment prefix, absolute path to claude.exe.
$proj = "$Root\proj dir with spaces"
$teammate = "cd '$proj' && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 S4_MARK=teammate '$Root\native\claude.exe' --agent-id alice@team-x --agent-name alice --team-name team-x --agent-color blue --parent-session-id 0b7c9a5e-1f2d-4c3b-9a8e-7f6d5c4b3a21"
foreach ($t in @(
        @{ Id = 'bash -c (structured argv)'; File = $bash; Args = @('-c', $teammate) },
        @{ Id = 'bash -lc (structured argv)'; File = $bash; Args = @('-lc', $teammate) },
        @{ Id = 'cmd /c'; File = 'C:\Windows\System32\cmd.exe'; Raw = "/d /s /c `"$teammate`"" },
        @{ Id = 'pwsh -c'; File = 'C:\Program Files\PowerShell\7\pwsh.exe'; Args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $teammate) })) {
    $r = Invoke-S4 -File $t.File -ArgList $t.Args -RawArgs $t.Raw -Path "$Root\shims\agents;$B" -Cwd $Root -TimeoutMs 120000
    Log "T-A $($t.Id)" $r
    $rows.Add([pscustomobject]@{ Test = 'teammate line'; Via = $t.Id; Result = "exit=$($r.Code) $($r.Ms)ms :: $(Brief $r)" })
}

# T-B: which bash would a launcher pick?
$whereBash = (& where.exe bash 2>&1) -join ' > '
$gfw = (Get-ItemProperty 'HKLM:\SOFTWARE\GitForWindows' -ErrorAction SilentlyContinue).InstallPath
$gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
$sys32bash = (Get-Item 'C:\Windows\System32\bash.exe' -ErrorAction SilentlyContinue).VersionInfo.FileDescription
$rows.Add([pscustomobject]@{ Test = 'bash discovery'; Via = 'where.exe bash (real PATH)'; Result = $whereBash })
$rows.Add([pscustomobject]@{ Test = 'bash discovery'; Via = 'System32\bash.exe description'; Result = "$sys32bash" })
$rows.Add([pscustomobject]@{ Test = 'bash discovery'; Via = 'HKLM\SOFTWARE\GitForWindows InstallPath'; Result = "$gfw -> $(Test-Path "$gfw\bin\bash.exe")" })
$rows.Add([pscustomobject]@{ Test = 'bash discovery'; Via = 'git.exe on PATH -> ..\..\bin\bash.exe'; Result = "$gitExe -> $(Test-Path (Join-Path (Split-Path (Split-Path $gitExe)) 'bin\bash.exe'))" })
$rows.Add([pscustomobject]@{ Test = 'bash discovery'; Via = 'CLAUDE_CODE_GIT_BASH_PATH / SHELL in this env'; Result = "[$env:CLAUDE_CODE_GIT_BASH_PATH] / [$env:SHELL]" })

# T-C: tmux shim lookup (teams\tmux.exe first; a later dir holds tmux (sh) and tmux.cmd).
$T1 = "$Root\teams;$Root\tmuxlater;$B"
$T2 = "$Root\tmuxlater;$Root\teams;$B"
foreach ($p in @(@{ Id = 'teams first'; Path = $T1 }, @{ Id = 'tmuxlater first'; Path = $T2 })) {
    $w = Invoke-S4 -File 'C:\Windows\System32\where.exe' -ArgList @('tmux') -Path $p.Path -Cwd $Root
    $rows.Add([pscustomobject]@{ Test = "tmux lookup ($($p.Id))"; Via = 'where.exe tmux'; Result = (($w.Out -split "`r?`n" | Where-Object { $_ }) -join ' > ').Replace("$Root\", '<R>\') })
    foreach ($l in @(@{ Id = 'CreateProcess "tmux -V"'; File = "$Root\bin\spawner.exe"; Args = @('create', 'tmux', '-V') },
                     @{ Id = 'cmd /c tmux -V'; File = 'C:\Windows\System32\cmd.exe'; Args = @('/d', '/c', 'tmux', '-V') },
                     @{ Id = 'pwsh tmux -V'; File = 'C:\Program Files\PowerShell\7\pwsh.exe'; Args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'tmux -V') },
                     @{ Id = 'bash -c tmux -V'; File = $bash; Args = @('-c', 'tmux -V') })) {
        $r = Invoke-S4 -File $l.File -ArgList $l.Args -Path $p.Path -Cwd $Root
        Log "T-C $($p.Id) $($l.Id)" $r
        $rows.Add([pscustomobject]@{ Test = "tmux lookup ($($p.Id))"; Via = $l.Id; Result = (Brief $r) })
    }
    # A resolver that trusts the first where.exe line and spawns it directly:
    $first = ($w.Out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
    $r = Invoke-S4 -File "$Root\bin\spawner.exe" -RawArgs "create `"$first`" -V" -Path $p.Path -Cwd $Root
    $rows.Add([pscustomobject]@{ Test = "tmux lookup ($($p.Id))"; Via = 'spawn first where.exe hit'; Result = (Brief $r) })
}

# T-D: argv shapes a tmux shim must accept (lone command string; global flags before the verb).
foreach ($a in @(@('display-message -p #{pane_id}'), @('-L', 'claude-swarm', 'has-session', '-t', 'x'), @('-S', 'C:\tmp\sock', 'split-window', '-d', '-t', '%1', '-h', '-l', '70%', '-P', '-F', '#{pane_id}', '--', 'cat'))) {
    $r = Invoke-S4 -File "$Root\teams\tmux.exe" -ArgList $a -Path $T1 -Cwd $Root
    $argv = @([regex]::Matches($r.Out, 'S4IDENT argv\[(\d+)\]=<(.*)>') | Select-Object -Skip 1 | ForEach-Object { '<' + $_.Groups[2].Value + '>' }) -join ' '
    $rows.Add([pscustomobject]@{ Test = 'tmux argv'; Via = ($a -join ' '); Result = $argv })
}

# T-E: MSYS argument conversion when bash runs a native exe (POSIX-looking args get rewritten).
$r = Invoke-S4 -File $bash -ArgList @('-c', "'$Root\native\claude.exe' /c/Users --settings=/tmp/x.json -p /etc C:/already/win %1 '#{pane_id}'") -Path "$B" -Cwd $Root
Log 'T-E msys conversion' $r
$conv = @([regex]::Matches($r.Out, 'S4IDENT argv\[(\d+)\]=<(.*)>') | Select-Object -Skip 1 | ForEach-Object { '<' + $_.Groups[2].Value + '>' }) -join ' '
$rows.Add([pscustomobject]@{ Test = 'msys argv conversion'; Via = "/c/Users --settings=/tmp/x.json -p /etc C:/already/win %1 '#{pane_id}'"; Result = $conv })
$r = Invoke-S4 -File $bash -ArgList @('-c', "'$Root\native\claude.exe' /c/Users --settings=/tmp/x.json -p /etc") -Path "$B" -Cwd $Root -Env @{ MSYS2_ARG_CONV_EXCL = '*' }
$conv = @([regex]::Matches($r.Out, 'S4IDENT argv\[(\d+)\]=<(.*)>') | Select-Object -Skip 1 | ForEach-Object { '<' + $_.Groups[2].Value + '>' }) -join ' '
$rows.Add([pscustomobject]@{ Test = 'msys argv conversion'; Via = 'same with MSYS2_ARG_CONV_EXCL=*'; Result = $conv })

$fg = Stop-S4FgSampler $job $fgLog $Root
foreach ($row in $rows) { "{0} | {1} | {2}" -f $row.Test, $row.Via, $row.Result }
"foreground samples=$($fg.Samples) violations=$($fg.Violations.Count)"
