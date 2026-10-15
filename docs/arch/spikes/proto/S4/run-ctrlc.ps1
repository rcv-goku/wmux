# S4 spike: Ctrl+C, kill and console-close behaviour through the wrapper, inside a real ConPTY
# (conpty_harness.exe writes 0x03 into the pseudoconsole input exactly like a terminal does).
param([Parameter(Mandatory)] [string] $Root, [string[]] $Only = @())
. "$PSScriptRoot\common.ps1"
$B = $script:S4Base
$H = "$Root\bin\conpty_harness.exe"
$wrap = "$Root\shims\wrap\claude.exe"
$child = "$Root\bin\child.exe"
$log = Join-Path $Root 'logs\ctrlc.txt'

$tests = @(
    @{ Id = 'T1';  Desc = 'no wrapper; child handler';                      H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$child`" handler 8000"; Env = @{} }
    @{ Id = 'T2';  Desc = 'wrapper handler; child handler';                 H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" handler 8000"; Env = @{ S4_WRAP_CTRL = 'handler' } }
    @{ Id = 'T3';  Desc = 'wrapper SetConsoleCtrlHandler(NULL,TRUE) BEFORE CreateProcess; child handler'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" handler 8000"; Env = @{ S4_WRAP_CTRL = 'ignore-before' } }
    @{ Id = 'T4';  Desc = 'wrapper SetConsoleCtrlHandler(NULL,TRUE) AFTER CreateProcess; child handler'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" handler 8000"; Env = @{ S4_WRAP_CTRL = 'ignore-after' } }
    @{ Id = 'T5a'; Desc = 'wrapper no ctrl handling; child handles ^C and keeps running'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" handler-continue 4000"; Env = @{ S4_WRAP_CTRL = 'none' } }
    @{ Id = 'T5b'; Desc = 'wrapper handler; child handles ^C and keeps running'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" handler-continue 4000"; Env = @{ S4_WRAP_CTRL = 'handler' } }
    @{ Id = 'T6';  Desc = 'wrapper handler; child default ^C (dies)';      H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" sleep 8000"; Env = @{ S4_WRAP_CTRL = 'handler' } }
    @{ Id = 'T7';  Desc = 'wrapper handler; child raw console mode (TUI)'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" raw 8000"; Env = @{ S4_WRAP_CTRL = 'handler' } }
    @{ Id = 'T8a'; Desc = 'TerminateProcess(wrapper); job KILL_ON_JOB_CLOSE'; H = @('--arm', 'GRANDCHILDPID=', '--kill-root-at', '500', '--linger', '1500'); Cmd = "`"$wrap`" grandchild 15000"; Env = @{ S4_WRAP_JOBFLAGS = 'kill' } }
    @{ Id = 'T8b'; Desc = 'TerminateProcess(wrapper); job KILL_ON_JOB_CLOSE|SILENT_BREAKAWAY_OK'; H = @('--arm', 'GRANDCHILDPID=', '--kill-root-at', '500', '--linger', '1500'); Cmd = "`"$wrap`" grandchild 15000"; Env = @{ S4_WRAP_JOBFLAGS = 'kill-silent' } }
    @{ Id = 'T8c'; Desc = 'TerminateProcess(wrapper); NO job (control)';   H = @('--arm', 'GRANDCHILDPID=', '--kill-root-at', '500', '--linger', '1500'); Cmd = "`"$wrap`" grandchild 15000"; Env = @{ S4_WRAP_JOB = 'none' } }
    @{ Id = 'T9';  Desc = 'ClosePseudoConsole while wrapper+child run';    H = @('--arm', 'CHILDPID=', '--close-at', '700', '--linger', '1500'); Cmd = "`"$wrap`" handler-continue 15000"; Env = @{ S4_WRAP_CTRL = 'handler' } }
    @{ Id = 'T10a'; Desc = 'outer tab job (BREAKAWAY_OK) + wrapper job attr, kill'; H = @('--outer-job', '--arm', 'GRANDCHILDPID=', '--check-at', '300', '--kill-root-at', '800', '--linger', '1500'); Cmd = "`"$wrap`" grandchild 15000"; Env = @{ S4_WRAP_JOBFLAGS = 'kill' } }
    @{ Id = 'T10b'; Desc = 'outer tab job + wrapper job attr, kill-silent'; H = @('--outer-job', '--arm', 'GRANDCHILDPID=', '--check-at', '300', '--kill-root-at', '800', '--linger', '1500'); Cmd = "`"$wrap`" grandchild 15000"; Env = @{ S4_WRAP_JOBFLAGS = 'kill-silent' } }
    @{ Id = 'T10c'; Desc = 'outer tab job + wrapper job via CREATE_SUSPENDED+Assign'; H = @('--outer-job', '--arm', 'GRANDCHILDPID=', '--check-at', '300'); Cmd = "`"$wrap`" grandchild 3000"; Env = @{ S4_WRAP_JOB = 'suspend' } }
    @{ Id = 'T11a'; Desc = 'wrapper -> cmd.exe /c claude.cmd -> child default ^C'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700', '--input-at', '2500:n\r', '--timeout', '20000'); Cmd = "`"$wrap`" sleep 8000"; Env = @{ S4_WRAP_REAL = "$Root\ctrlc\claude.cmd"; S4_WRAP_CMDSHIM = 'cmd' } }
    @{ Id = 'T11b'; Desc = 'wrapper -> cmd.exe /c claude.cmd -> child swallows ^C'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700', '--input-at', '4500:n\r', '--timeout', '20000'); Cmd = "`"$wrap`" handler-continue 3000"; Env = @{ S4_WRAP_REAL = "$Root\ctrlc\claude.cmd"; S4_WRAP_CMDSHIM = 'cmd' } }
    @{ Id = 'T11c'; Desc = 'wrapper -> cmd.exe /c claude.cmd -> child raw mode'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700', '--timeout', '20000'); Cmd = "`"$wrap`" raw 3000"; Env = @{ S4_WRAP_REAL = "$Root\ctrlc\claude.cmd"; S4_WRAP_CMDSHIM = 'cmd' } }
    @{ Id = 'T12'; Desc = 'wrapper bypasses npm claude.cmd -> node.exe directly; child default ^C'; H = @('--arm', 'CHILDPID=', '--ctrlc-at', '700', '--timeout', '20000'); Cmd = "`"$wrap`" sleep 8000"; Env = @{ S4_WRAP_REAL = "$Root\ctrlc-npm\claude.cmd"; S4_WRAP_CMDSHIM = 'bypass' } }
    # Agent starts a background daemon with libuv "detached" flags and then exits normally.
    @{ Id = 'T13a'; Desc = 'agent spawns detached daemon, exits; wrapper job KILL_ON_JOB_CLOSE'; H = @('--arm', 'GRANDCHILDPID=', '--linger', '1500'); Cmd = "`"$wrap`" daemon 15000"; Env = @{ S4_WRAP_JOBFLAGS = 'kill' } }
    @{ Id = 'T13b'; Desc = 'agent spawns detached daemon, exits; wrapper job KILL_ON_JOB_CLOSE|SILENT_BREAKAWAY_OK'; H = @('--arm', 'GRANDCHILDPID=', '--linger', '1500'); Cmd = "`"$wrap`" daemon 15000"; Env = @{ S4_WRAP_JOBFLAGS = 'kill-silent' } }
    @{ Id = 'T13c'; Desc = 'agent spawns detached daemon, exits; no wrapper (control)'; H = @('--arm', 'GRANDCHILDPID=', '--linger', '1500'); Cmd = "`"$child`" daemon 15000"; Env = @{} }
    # Ctrl+C as wmux actually sends it once ConPTY enabled win32-input-mode (DEC 9001):
    # Ctrl down, C down (Uc=3), C up, Ctrl up, encoded \e[Vk;Sc;Uc;Kd;Cs;Rc_ like Surface.sendWin32InputEvent.
    @{ Id = 'W1'; Desc = 'win32-input-mode Ctrl+C; wrapper handler; child handler'; H = @('--arm', 'CHILDPID=', '--input-at', '700:\e[17;29;0;1;8;1_\e[67;46;3;1;8;1_\e[67;46;0;0;8;1_\e[17;29;0;0;0;1_'); Cmd = "`"$wrap`" handler 8000"; Env = @{} }
    @{ Id = 'W2'; Desc = 'win32-input-mode Ctrl+C; wrapper handler; child default';  H = @('--arm', 'CHILDPID=', '--input-at', '700:\e[17;29;0;1;8;1_\e[67;46;3;1;8;1_\e[67;46;0;0;8;1_\e[17;29;0;0;0;1_'); Cmd = "`"$wrap`" sleep 8000"; Env = @{} }
    @{ Id = 'W3'; Desc = 'win32-input-mode Ctrl+C; wrapper handler; child raw (TUI)'; H = @('--arm', 'CHILDPID=', '--input-at', '700:\e[17;29;0;1;8;1_\e[67;46;3;1;8;1_\e[67;46;0;0;8;1_\e[17;29;0;0;0;1_'); Cmd = "`"$wrap`" raw 8000"; Env = @{} }
    # Process-group semantics: GenerateConsoleCtrlEvent from a supervisor attached to the same console.
    @{ Id = 'G1';  Desc = 'GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0); wrapper handler; child handler'; H = @('--arm', 'CHILDPID=', '--gen-at', '700:c:0'); Cmd = "`"$wrap`" handler 8000"; Env = @{} }
    @{ Id = 'G2a'; Desc = 'root in NEW process group; CTRL_BREAK_EVENT to that group';  H = @('--new-group', '--arm', 'CHILDPID=', '--gen-at', '700:break:root'); Cmd = "`"$wrap`" handler 8000"; Env = @{} }
    @{ Id = 'G2b'; Desc = 'root in NEW process group; CTRL_C_EVENT to that group';      H = @('--new-group', '--arm', 'CHILDPID=', '--gen-at', '700:c:root'); Cmd = "`"$wrap`" handler 8000"; Env = @{} }
    @{ Id = 'G2c'; Desc = 'root in NEW process group; typed ^C (0x03)';                 H = @('--new-group', '--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$wrap`" handler 8000"; Env = @{} }
    @{ Id = 'G3';  Desc = 'no wrapper; child in NEW process group; typed ^C (0x03)';    H = @('--new-group', '--arm', 'CHILDPID=', '--ctrlc-at', '700'); Cmd = "`"$child`" handler 8000"; Env = @{} }
)
if ($Only.Count) { $tests = $tests | Where-Object { $Only -contains $_.Id } }

foreach ($t in $tests) {
    $envs = @{ S4_WRAP_VERBOSE = '1'; S4_WRAP_REAL = $child } # real binary = child.exe unless the test overrides it
    foreach ($k in $t.Env.Keys) { $envs[$k] = $t.Env[$k] }
    $raw = ($t.H -join ' ') + ' -- ' + $t.Cmd
    $r = Invoke-S4 -File $H -RawArgs $raw -Path "$Root\shims\wrap;$B" -Cwd $Root -Env $envs -TimeoutMs 60000
    Add-Content $log ("==== {0} {1}`n{2}`n{3}" -f $t.Id, $t.Desc, $r.Out, $r.Err)
    $lines = ($r.Out -split "`r?`n")
    $keep = $lines | Where-Object { $_ -match 'root exited|TIMEOUT|wrote|TerminateProcess|ClosePseudoConsole|snapshot|  root alive|child pid|grandchild pid|outer job|VIOLATION|cleanup|GenerateConsoleCtrlEvent|AttachConsole|armed|win32-input-mode|\| CHILD|\| WRAPPER got|\| WRAPPER child exit|\| WRAPPER spawned|Terminate batch|\| S4BATCH|\| \^C|failed' }
    "=== $($t.Id): $($t.Desc)"
    $keep | ForEach-Object { '   ' + $_.Replace("$Root\", '<R>\') }
}
