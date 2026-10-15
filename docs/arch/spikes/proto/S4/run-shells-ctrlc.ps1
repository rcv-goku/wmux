# S4 spike: the realistic chain, typed into an interactive shell running in a ConPTY:
#   shell (cmd | pwsh | Git Bash) -> claude.exe (wrapper) -> real agent (child.exe), user presses Ctrl+C.
# Each case also runs "direct" (the agent typed without any wrapper) as the control.
param([Parameter(Mandatory)] [string] $Root)
. "$PSScriptRoot\common.ps1"
$B = $script:S4Base
$H = "$Root\bin\conpty_harness.exe"
$C = "$Root\bin\child.exe"
$log = Join-Path $Root 'logs\shells-ctrlc.txt'
$shells = @(
    @{ Id = 'cmd'; Cmd = 'C:\Windows\System32\cmd.exe /d /q /k prompt S4READY$G'; Echo = 'echo EXIT=%ERRORLEVEL%'; Direct = "`"$C`"" }
    @{ Id = 'pwsh 7'; Cmd = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -NoExit -Command "function prompt { ''S4READY> '' }"'; Echo = 'Write-Output (''EXIT='' + $LASTEXITCODE)'; Direct = "& '$C'" }
    @{ Id = 'git bash'; Cmd = '"C:\Program Files\Git\bin\bash.exe" --norc --noprofile -i'; Echo = 'echo EXIT=$?'; Direct = "'$C'" }
)
# MSVCRT quoting for these values: escape '"'; backslashes stay literal (none precedes a quote here)
function Q([string] $s) { '"' + $s.Replace('"', '\"') + '"' }
foreach ($s in $shells) {
    foreach ($via in @('wrapper', 'direct')) {
        foreach ($mode in @('handler 15000', 'sleep 15000', 'raw 15000')) {
            $envs = @{ S4_WRAP_REAL = $C; PS1 = 'S4READY> ' }
            $typed = if ($via -eq 'wrapper') { "claude $mode" } else { "$($s.Direct) $mode" }
            # type the command at the first prompt; Ctrl+C 1 s after the agent announced itself (CHILDPID=,
            # i.e. after its handler/raw mode is set up); then print the exit status and leave
            $hargs = @('--pre', "S4READY|$typed\r", '--arm', 'CHILDPID=', '--ctrlc-at', '1500', '--input-at', "5000:$($s.Echo)\r", '--input-at', '7000:exit\r', '--timeout', '60000', '--linger', '500')
            # values go through the harness's argv parser: quote anything with spaces/quotes
            $raw = (($hargs | ForEach-Object { if ($_ -match '[\s"|]') { Q $_ } else { $_ } }) -join ' ') + ' -- ' + $s.Cmd
            $r = Invoke-S4 -File $H -RawArgs $raw -Path "$Root\shims\wrap;$B" -Cwd $Root -Env $envs -TimeoutMs 90000
            Add-Content $log ("==== {0} :: {1} :: {2}`n{3}`n{4}" -f $s.Id, $via, $mode, $r.Out, $r.Err)
            $o = $r.Out
            $got = if ($o -match 'CHILD got ctrl event (\d)') { "child got event $($Matches[1])" } elseif ($o -match 'CHILD raw got 0x03') { 'child got 0x03 key' } elseif ($o -match 'CHILD timeout') { 'child saw nothing' } elseif ($o -match 'child pid=\d+ alive=no exitcode=3221225786') { 'child killed by ^C' } else { 'no child verdict' }
            $exit = if ($o -match 'EXIT=(-?\d+)') { $Matches[1] } else { '?' }
            $shellExit = if ($o -match 'root exited code=(\S+)') { $Matches[1] } else { 'still running (TIMEOUT)' }
            $batch = if ($o -match 'Terminate batch job') { ' [Terminate batch job prompt!]' } else { '' }
            "{0,-9} {1,-8} {2,-14} -> {3,-19} shell saw EXIT={4,-12} shell exit={5}{6}" -f $s.Id, $via, $mode, $got, $exit, $shellExit, $batch
        }
    }
}
