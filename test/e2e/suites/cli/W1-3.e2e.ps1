# wp: W1-3
# covers: cli-terminal-env-identity, cli-terminal-env-terminal-identity, cli-terminal-env-integration-flags, cli-terminal-env-ports, notifications-environment-variables, persistence-shell-integration-bootstrap
# budget-sec: 900
#
# Protected terminal environment, PATH/WSLENV and the per-tab jobs (W1-3, ARCHITECTURE.md
# ADR-3.9). Every check reads the environment from inside a terminal of an isolated hidden
# instance: `echo W13<n>=%NAME%` typed into cmd.exe, the output line read back from the screen.
# * identity: CMUX_WORKSPACE_ID/CMUX_SURFACE_ID match the instance's model ids
#   (wmux.debug.layout on a v2 instance; before W1-1a the spawn identity the app logs to
#   STATE\logs\wmux.log), CMUX_TAB_ID = the workspace id, CMUX_SOCKET_PATH = the instance.json
#   pipe (before W1-1a: the computed control pipe name), CMUX_SOCKET empty, TERM=xterm-256color,
#   the port block and the shell-integration dir;
# * protection: Ghostty `env = CMUX_SURFACE_ID=x` (the same override path a workspace env
#   takes) cannot replace the protected values; `where wmux` resolves to INSTALL\cli first;
#   `wmux +workspace list` inside the terminal prints the legacy output (W1-2b);
#   inherited Anthropic credentials are removed unless wmux.agents.preserveAuthEnv;
# * jobs: a background `ping` started from a tab runs in that tab's job (wmux.debug.layout
#   surface.pids, v2 only) and outlives closing the tab (no kill-on-close);
# * WSL: a WSL process started from a tab sees CMUX_SURFACE_ID through WSLENV (skipped with a
#   notice when WSL or a distro is absent);
# * shell integration: cmd.exe with the default prompt gets PROMPT with OSC 9;9 and 133, and
#   Windows PowerShell 5.1 loads the PowerShell integration.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:NextId = 1000
$script:Tag = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:UuidRe = '[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}'

if (-not ('W13.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace W13 {
public static class Native {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    // True when pid runs in job (IntPtr.Zero: any job).
    public static bool InJob(int pid, IntPtr job) {
        IntPtr p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (p == IntPtr.Zero) return false;
        try { bool r; return IsProcessInJob(p, job, out r) && r; } finally { CloseHandle(p); }
    }
}
}
'@
}

function Invoke-Legacy {
    # One legacy JSON command (the legacy pipe, or the v2 server's legacy adapter); returns data.
    param([Parameter(Mandatory, Position = 0)]$Instance, [Parameter(Mandatory, Position = 1)][string]$Cmd, [Parameter(Position = 2)][hashtable]$Arguments)
    $script:NextId++
    $req = [ordered]@{ id = $script:NextId; cmd = $Cmd }
    if ($null -ne $Arguments) { $req.args = $Arguments }
    $reply = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $Instance (ConvertTo-Json -InputObject $req -Compress -Depth 10) -TimeoutSec 20))
    Assert-True $reply.ok "legacy '$Cmd' failed: $($reply.error)"
    return $reply.data
}

function Get-Screen {
    param($Instance, [hashtable]$Target = @{})
    return [string](Invoke-Legacy $Instance 'read-screen' $Target)
}

function Wait-Screen {
    # Until the addressed terminal's screen matches $Pattern; returns the match.
    param($Instance, [hashtable]$Target = @{}, [string]$Pattern, [double]$TimeoutSec = 30)
    $re = [regex]::new($Pattern)
    return Wait-WmuxCondition -TimeoutSec $TimeoutSec -IntervalMs 150 {
        $m = $re.Match((Get-Screen $Instance $Target))
        if ($m.Success) { $m } else { $null }
    }
}

function Wait-Prompt {
    param($Instance, [hashtable]$Target = @{}, [string]$Pattern = '(?m)^WMUX>')
    $null = Wait-Screen $Instance $Target $Pattern
}

function Send-Line {
    param($Instance, [hashtable]$Target = @{}, [string]$Text)
    $a = @{ text = $Text; enter = $true }
    foreach ($k in $Target.Keys) { $a[$k] = $Target[$k] }
    $null = Invoke-Legacy $Instance 'send' $a
}

function Get-TerminalEnv {
    # The value of %Name% in the addressed cmd.exe terminal ('<unset>' when cmd does not know it).
    param($Instance, [hashtable]$Target = @{}, [string]$Name)
    $script:Tag++
    $tag = "W13V$($script:Tag)"
    Send-Line $Instance $Target "echo $tag=[%$Name%]"
    $m = Wait-Screen $Instance $Target "(?m)^$tag=\[(.*?)\]\s*$"
    $v = $m.Groups[1].Value
    if ($v -eq "%$Name%") { return '<unset>' }
    return $v
}

function Test-TerminalListHas {
    # Whether the $Sep-separated list in %Name% of the addressed terminal has the entry $Entry
    # (case-insensitive), decided inside cmd so long values never have to fit on one screen row.
    param($Instance, [hashtable]$Target = @{}, [string]$Name, [string]$Sep, [string]$Entry)
    $script:Tag++
    $tag = "W13L$($script:Tag)"
    $list = if ($Sep -eq ';') { "%$Name%" } else { "%${Name}:${Sep}=;%" }
    # The system findstr by path: an inherited PATH may put a POSIX find/findstr first.
    Send-Line $Instance $Target "echo ;$list; | `"%SystemRoot%\System32\findstr.exe`" /i /l /c:`";$Entry;`" >nul && echo $tag=yes || echo $tag=no"
    $m = Wait-Screen $Instance $Target "(?m)^$tag=(yes|no)\s*$"
    return $m.Groups[1].Value -eq 'yes'
}

function Test-TerminalCmd {
    # Runs `<Condition> (echo yes) else (echo no)` in the addressed cmd.exe terminal; $Condition
    # is an `if ...` (optionally inside `for ... do @`).
    param($Instance, [hashtable]$Target = @{}, [string]$Condition)
    $script:Tag++
    $tag = "W13C$($script:Tag)"
    Send-Line $Instance $Target "$Condition (echo $tag=yes) else (echo $tag=no)"
    $m = Wait-Screen $Instance $Target "(?m)^$tag=(yes|no)\s*$"
    return $m.Groups[1].Value -eq 'yes'
}

function Get-AppLog {
    param($Instance)
    $path = Join-Path $Instance.StateDir 'logs\wmux.log'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try { return [IO.StreamReader]::new($fs, $script:Utf8).ReadToEnd() } finally { $fs.Dispose() }
}

function Get-SpawnIdentities {
    # The spawn identities the app logged, in spawn order: @{ Workspace; Surface; Pane; Lifecycle; Job }.
    param($Instance)
    $re = "spawn identity workspace=($script:UuidRe) surface=($script:UuidRe) pane=($script:UuidRe) lifecycle=($script:UuidRe) job=(\w+)"
    foreach ($m in [regex]::Matches((Get-AppLog $Instance), $re)) {
        [pscustomobject]@{ Workspace = $m.Groups[1].Value; Surface = $m.Groups[2].Value; Pane = $m.Groups[3].Value; Lifecycle = $m.Groups[4].Value; Job = $m.Groups[5].Value }
    }
}

function Get-LayoutSurfaces {
    # v2 only: every surface of wmux.debug.layout as @{ Workspace; Surface; Pids }.
    param($Instance)
    $layout = Invoke-WmuxRpc $Instance 'wmux.debug.layout'
    foreach ($win in @($layout.windows)) {
        foreach ($ws in @($win.workspaces)) {
            foreach ($pane in @($ws.panes)) {
                foreach ($s in @($pane.surfaces)) {
                    [pscustomobject]@{ Workspace = [string]$ws.workspace_id; Surface = [string]$s.surface_id; Pids = @($s.pids | ForEach-Object { [int]$_ }) }
                }
            }
        }
    }
}

function Get-ExpectedPipe {
    # instance.json's pipe on a v2 instance; before W1-1a the computed control pipe name.
    param($Instance)
    $marker = Join-Path $Instance.StateDir 'run\instance.json'
    if (Test-Path -LiteralPath $marker) {
        $m = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($m.pipe) { return [string]$m.pipe }
    }
    $mod = Get-Module WmuxTest
    $name = & $mod { param($c) Get-WmuxPipeName -Channel $c } $Instance.Channel
    return "\\.\pipe\$name"
}

function Use-KeptEnv {
    # Lets $Names reach the instance (Start-WmuxInstance strips credentials) for $Body.
    param([Parameter(Mandatory)][hashtable]$Values, [Parameter(Mandatory)][scriptblock]$Body)
    $mod = Get-Module WmuxTest
    $names = @($Values.Keys)
    & $mod { param($n) $script:EnvKeepNames = @($script:EnvKeepNames) + $n } $names
    foreach ($k in $names) { [Environment]::SetEnvironmentVariable($k, $Values[$k]) }
    try { & $Body } finally {
        foreach ($k in $names) { [Environment]::SetEnvironmentVariable($k, $null) }
        & $mod { param($n) $script:EnvKeepNames = @($script:EnvKeepNames | Where-Object { $n -notcontains $_ }) } $names
    }
}

function Get-WslDistroCount {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return 0 }
    try {
        $out = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -ne 0) { return 0 }
        # wsl.exe writes UTF-16; strip the NULs PowerShell leaves in.
        return @($out | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }).Count
    } catch { return 0 }
}

Test-Case 'identity: ids match the model, CMUX_TAB_ID is the workspace, socket path, CMUX_SOCKET empty, TERM' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $ws = Get-TerminalEnv $w @{} 'CMUX_WORKSPACE_ID'
        $sf = Get-TerminalEnv $w @{} 'CMUX_SURFACE_ID'
        Assert-Match "^$script:UuidRe$" $ws 'CMUX_WORKSPACE_ID is an uppercase UUID'
        Assert-Match "^$script:UuidRe$" $sf 'CMUX_SURFACE_ID is an uppercase UUID'

        if ($w.Protocol -eq 'v2') {
            $surfaces = @(Get-LayoutSurfaces $w)
            $mine = @($surfaces | Where-Object { $_.Surface -eq $sf })
            Assert-Equal 1 $mine.Count 'CMUX_SURFACE_ID names a surface of wmux.debug.layout'
            Assert-Equal $ws $mine[0].Workspace 'CMUX_WORKSPACE_ID is the workspace of that surface'
        } else {
            Write-Host 'legacy instance (W1-1a not merged): comparing with the spawn identity in wmux.log'
            $ids = @(Wait-WmuxCondition -TimeoutSec 10 { $x = @(Get-SpawnIdentities $w); if ($x.Count -ge 1) { , $x } else { $null } })
            Assert-Equal 1 $ids.Count 'one terminal spawned'
            Assert-Equal $ids[0].Surface $sf 'CMUX_SURFACE_ID = the spawned tab id'
            Assert-Equal $ids[0].Workspace $ws 'CMUX_WORKSPACE_ID = the spawned workspace id'
            Assert-Equal 'tab' $ids[0].Job 'the terminal spawned in a tab job'
            Assert-Equal $ids[0].Pane (Get-TerminalEnv $w @{} 'CMUX_PANE_ID') 'CMUX_PANE_ID'
            Assert-Equal $ids[0].Lifecycle (Get-TerminalEnv $w @{} 'CMUX_TERMINAL_LIFECYCLE_ID') 'CMUX_TERMINAL_LIFECYCLE_ID'
        }

        Assert-Equal $ws (Get-TerminalEnv $w @{} 'CMUX_TAB_ID') 'CMUX_TAB_ID keeps the cmux legacy meaning (workspace id)'
        Assert-Equal $ws (Get-TerminalEnv $w @{} 'WMUX_WORKSPACE_ID') 'WMUX_WORKSPACE_ID twin'
        Assert-Equal $sf (Get-TerminalEnv $w @{} 'WMUX_SURFACE_ID') 'WMUX_SURFACE_ID twin'
        Assert-Equal $sf (Get-TerminalEnv $w @{} 'CMUX_PANEL_ID') 'CMUX_PANEL_ID alias'

        $pipe = Get-ExpectedPipe $w
        Assert-Equal $pipe (Get-TerminalEnv $w @{} 'CMUX_SOCKET_PATH') 'CMUX_SOCKET_PATH = the control pipe'
        Assert-Equal $pipe (Get-TerminalEnv $w @{} 'WMUX_SOCKET_PATH') 'WMUX_SOCKET_PATH twin'
        # Set to "" in the spawn environment; cmd.exe drops empty variables, so it reads unset.
        Assert-True (@('', '<unset>') -contains (Get-TerminalEnv $w @{} 'CMUX_SOCKET')) 'CMUX_SOCKET is empty'
        Assert-Equal 'xterm-256color' (Get-TerminalEnv $w @{} 'TERM') 'TERM'
        Assert-Equal 'truecolor' (Get-TerminalEnv $w @{} 'COLORTERM') 'COLORTERM'
        Assert-Equal 'ghostty' (Get-TerminalEnv $w @{} 'TERM_PROGRAM') 'TERM_PROGRAM'
        Assert-Equal "wmux.app.$($w.Channel)" (Get-TerminalEnv $w @{} 'CMUX_BUNDLE_ID') 'CMUX_BUNDLE_ID'

        $install = Split-Path -Parent $w.Exe
        $cliExe = Join-Path $install 'cli\cmux.exe'
        Assert-True (Test-TerminalCmd $w @{} "if /i `"%CMUX_BUNDLED_CLI_PATH%`"==`"$cliExe`"") 'CMUX_BUNDLED_CLI_PATH = INSTALL\cli\cmux.exe'
        Assert-True (Test-TerminalCmd $w @{} "if /i `"%WMUX_BUNDLED_CLI_PATH%`"==`"$cliExe`"") 'WMUX_BUNDLED_CLI_PATH twin'
        Assert-True (Test-TerminalCmd $w @{} 'if exist "%CMUX_SHELL_INTEGRATION_DIR%\powershell\ghostty-shell-integration.ps1"') 'CMUX_SHELL_INTEGRATION_DIR holds the shell integration scripts'

        # The first workspace's port block (automation.portBase 9100, portRange 10).
        Assert-Equal '9100' (Get-TerminalEnv $w @{} 'CMUX_PORT') 'CMUX_PORT'
        Assert-Equal '9109' (Get-TerminalEnv $w @{} 'CMUX_PORT_END') 'CMUX_PORT_END'
        Assert-Equal '10' (Get-TerminalEnv $w @{} 'CMUX_PORT_RANGE') 'CMUX_PORT_RANGE'

        foreach ($entry in 'CMUX_WORKSPACE_ID/u', 'CMUX_SURFACE_ID/u', 'CMUX_TAB_ID/u', 'CMUX_SOCKET_PATH/u', 'CMUX_BUNDLED_CLI_PATH/up', 'WMUX_SURFACE_ID/u') {
            Assert-True (Test-TerminalListHas $w @{} 'WSLENV' ':' $entry) "WSLENV lists $entry"
        }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'protection: env overrides cannot replace protected values; PATH, legacy CLI, auth removal' {
    Use-KeptEnv @{ ANTHROPIC_API_KEY = 'w13-secret'; ANTHROPIC_MODEL = 'w13-model' } {
        $w = Start-WmuxInstance -Ghostty @('env = CMUX_SURFACE_ID=x', 'env = CMUX_SOCKET=bogus', 'env = TERM_PROGRAM=other', 'env = W13_PLAIN=kept')
        try {
            Wait-Prompt $w
            $sf = Get-TerminalEnv $w @{} 'CMUX_SURFACE_ID'
            Assert-Match "^$script:UuidRe$" $sf 'the configured env = CMUX_SURFACE_ID=x does not override the surface id'
            Assert-True (@('', '<unset>') -contains (Get-TerminalEnv $w @{} 'CMUX_SOCKET')) 'env = CMUX_SOCKET=bogus does not survive'
            Assert-Equal 'ghostty' (Get-TerminalEnv $w @{} 'TERM_PROGRAM') 'TERM_PROGRAM stays protected'
            Assert-Equal 'kept' (Get-TerminalEnv $w @{} 'W13_PLAIN') 'unprotected env entries still apply'

            # Inherited Anthropic credentials are removed by default.
            Assert-Equal '<unset>' (Get-TerminalEnv $w @{} 'ANTHROPIC_API_KEY') 'ANTHROPIC_API_KEY removed'
            Assert-Equal '<unset>' (Get-TerminalEnv $w @{} 'ANTHROPIC_MODEL') 'ANTHROPIC_MODEL removed'

            # INSTALL\cli is first on PATH; `where wmux` lists it first.
            $install = Split-Path -Parent $w.Exe
            $cli = Join-Path $install 'cli'
            # (Paths are compared inside cmd: a long path would wrap on the screen.)
            Send-Line $w @{} 'set W13FIRST='
            Send-Line $w @{} 'for /f "delims=;" %a in ("%PATH%") do @set "W13FIRST=%a"'
            Assert-True (Test-TerminalCmd $w @{} "for %b in (`"%W13FIRST%\.`") do @if /i `"%~fb`"==`"$cli`"") 'INSTALL\cli is the first PATH entry'
            Assert-True (Test-TerminalListHas $w @{} 'PATH' ';' $install) 'the INSTALL append stays on PATH'
            Send-Line $w @{} 'set W13FIRST='
            Send-Line $w @{} 'for /f "delims=" %a in (''where wmux'') do @if not defined W13FIRST set "W13FIRST=%a"'
            Assert-True (Test-TerminalCmd $w @{} "for %b in (`"%W13FIRST%`") do @if /i `"%~dpb`"==`"$cli\`"") 'where wmux resolves in INSTALL\cli first'
            $script:Tag++
            Send-Line $w @{} "for %b in (`"%W13FIRST%`") do @echo W13N$($script:Tag)=[%~nxb]"
            $firstName = (Wait-Screen $w @{} "(?m)^W13N$($script:Tag)=\[(.*?)\]\s*$").Groups[1].Value
            Write-Host "where wmux -> INSTALL\cli\$firstName"
            if (Test-Path -LiteralPath (Join-Path $cli 'wmux.exe')) {
                Send-Line $w @{} 'set W13FIRST='
                Send-Line $w @{} 'for /f "delims=" %a in (''where wmux.exe'') do @if not defined W13FIRST set "W13FIRST=%a"'
                Assert-True (Test-TerminalCmd $w @{} "if /i `"%W13FIRST%`"==`"$cli\wmux.exe`"") 'where resolves wmux.exe to INSTALL\cli\wmux.exe first'
            } else {
                Write-Host "notice: cli\wmux.exe is staged by dist/windows/release.ps1 only; this build's cli\ has $((Get-ChildItem -LiteralPath $cli -Name) -join ', ')"
            }

            # The legacy +verb through the CLI that PATH now resolves (W1-2b).
            Send-Line $w @{} 'wmux +workspace list'
            $null = Wait-Screen $w @{} '(?m)^\[\{"index":0,"name":"","active":true,"tab_count":1\}\]\s*$'
        } finally { Stop-WmuxInstance $w }

        $w = Start-WmuxInstance -Settings @{ 'wmux.agents.preserveAuthEnv' = $true }
        try {
            Wait-Prompt $w
            Assert-Equal 'w13-secret' (Get-TerminalEnv $w @{} 'ANTHROPIC_API_KEY') 'preserveAuthEnv keeps ANTHROPIC_API_KEY'
        } finally { Stop-WmuxInstance $w }
    }
}

Test-Case 'jobs: a background ping is in the tab job and survives closing the tab; ports per workspace' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $t = Invoke-Legacy $w 'tab-new'
        $tab = @{ tab = [int]$t.index }
        Wait-Prompt $w $tab
        $sf = Get-TerminalEnv $w $tab 'CMUX_SURFACE_ID'
        # The second tab of the first workspace shares its port block.
        Assert-Equal '9100' (Get-TerminalEnv $w $tab 'CMUX_PORT') 'tabs of one workspace share the port block'

        # The spec's background ping shares the tab's console; a second one is started without
        # a console of its own (CREATE_NO_WINDOW), as a GUI app or a detached tool would be.
        $before = Get-Date
        Send-Line $w $tab 'cmd /c start /b ping -n 30 127.0.0.1'
        Send-Line $w $tab "powershell -NoProfile -Command `"[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName='ping.exe';Arguments='-n 31 127.0.0.1';CreateNoWindow=`$true;UseShellExecute=`$false}) | Out-Null`""
        $findPing = {
            param([int]$Count)
            @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object {
                    $_.CommandLine -match "-n $Count 127\.0\.0\.1" -and $_.CreationDate -ge $before.AddSeconds(-2) -and
                    [W13.Native]::InJob([int]$_.ProcessId, $w.JobHandle)
                })[0]
        }
        $pingPid = [int](Wait-WmuxCondition -TimeoutSec 20 { & $findPing 30 }).ProcessId
        $detachedPid = [int](Wait-WmuxCondition -TimeoutSec 20 { & $findPing 31 }).ProcessId
        Write-Host "ping pids: background $pingPid, detached $detachedPid"

        if ($w.Protocol -eq 'v2') {
            $s = @(Get-LayoutSurfaces $w | Where-Object { $_.Surface -eq $sf })
            Assert-Equal 1 $s.Count 'the tab is in wmux.debug.layout'
            Assert-True ($s[0].Pids -contains $pingPid) "surface.pids of the tab lists the background ping ($pingPid): $($s[0].Pids -join ',')"
            Assert-True ($s[0].Pids -contains $detachedPid) "surface.pids of the tab lists the detached ping ($detachedPid)"
            $other = @(Get-LayoutSurfaces $w | Where-Object { $_.Surface -ne $sf -and $_.Pids -contains $pingPid })
            Assert-Equal 0 $other.Count 'no other surface lists ping'
        } else {
            Write-Host 'notice: surface.pids needs wmux.debug.layout (W1-1a); the tab-job membership is checked through the log only'
            $id = @(Get-SpawnIdentities $w | Where-Object { $_.Surface -eq $sf })
            Assert-Equal 'tab' $id[0].Job 'the tab spawned in its own job'
        }

        # Close the tab: the detached ping keeps running (the tab job has no KILL_ON_JOB_CLOSE).
        # The console-sharing one ends with the pseudoconsole (ClosePseudoConsole terminates the
        # clients attached to it), which is console semantics, not the job.
        $null = Invoke-Legacy $w 'tab-close' @{ index = [int]$t.index }
        $null = Wait-WmuxCondition -TimeoutSec 10 { @(Invoke-Legacy $w 'tab-list').Count -eq 1 }
        Start-Sleep -Milliseconds 1500
        $alive = Get-Process -Id $detachedPid -ErrorAction SilentlyContinue
        Assert-True ($null -ne $alive -and -not $alive.HasExited) "the detached ping ($detachedPid) still runs after its tab closed"
        $shared = Get-Process -Id $pingPid -ErrorAction SilentlyContinue
        Write-Host "console-sharing ping after tab close: $(if ($shared) { 'running' } else { 'ended with the pseudoconsole' })"

        # A second workspace gets the next port block.
        $ws2 = Invoke-Legacy $w 'workspace-new' @{ name = 'w13-two' }
        $t2 = @{ workspace = [int]$ws2.index }
        Wait-Prompt $w $t2
        Assert-Equal '9110' (Get-TerminalEnv $w $t2 'CMUX_PORT') 'the second workspace gets the next block'
        Assert-Equal '9119' (Get-TerminalEnv $w $t2 'CMUX_PORT_END') 'its CMUX_PORT_END'
    } finally {
        Stop-WmuxInstance $w
    }
}

Test-Case 'wsl: a WSL process started from a tab sees CMUX_SURFACE_ID through WSLENV' {
    if ((Get-WslDistroCount) -eq 0) { throw [WmuxSkipException]::new('notice: WSL or a WSL distro is not installed') }
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $sf = Get-TerminalEnv $w @{} 'CMUX_SURFACE_ID'
        Send-Line $w @{} 'wsl.exe -e sh -c "echo W13WSL=[$CMUX_SURFACE_ID]; echo W13WSLWS=[$WMUX_WORKSPACE_ID]"'
        try {
            $m = Wait-Screen $w @{} '(?m)^W13WSL=\[(.*?)\]\s*$' -TimeoutSec 90
            $m2 = Wait-Screen $w @{} '(?m)^W13WSLWS=\[(.*?)\]\s*$'
        } catch {
            Write-Host "screen:`n$(Get-Screen $w)"
            throw
        }
        Assert-Equal $sf $m.Groups[1].Value 'the WSL process sees CMUX_SURFACE_ID'
        Assert-Match "^$script:UuidRe$" $m2.Groups[1].Value 'and the WMUX_ twins'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'shell integration: cmd.exe default prompt gets OSC 9;9/133; PowerShell 5.1 loads its integration' {
    $w = Start-WmuxInstance -Shell 'cmd.exe /d'
    try {
        Wait-Prompt $w @{} '(?m)^[A-Za-z]:\\[^\r\n]*>'
        $prompt = Get-TerminalEnv $w @{} 'PROMPT'
        Assert-Equal '$e]9;9;$P$e\$e]133;A$e\$P$G$e]133;B$e\' $prompt 'cmd PROMPT with OSC 9;9 and OSC 133 A/B'
    } finally { Stop-WmuxInstance $w }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { Write-Host 'notice: Windows PowerShell 5.1 not installed'; return }
    $w = Start-WmuxInstance -Shell "`"$ps`" -NoLogo -NoProfile"
    try {
        # The prompt text depends on the user's profile: wait for any output, then type.
        $null = Wait-Screen $w @{} '\S' -TimeoutSec 45
        Send-Line $w @{} "'W13PS=' + `$PSVersionTable.PSVersion.Major + ':' + [bool]((Get-Command prompt).ScriptBlock.ToString() -match '133;A')"
        $m = Wait-Screen $w @{} '(?m)^W13PS=(\d+):(True|False)\s*$' -TimeoutSec 30
        Assert-Equal '5' $m.Groups[1].Value 'the shell is Windows PowerShell 5.1'
        Assert-Equal 'True' $m.Groups[2].Value 'the integration prompt (OSC 133) is installed'
        Assert-True (-not ((Get-Screen $w) -match 'ghostty-shell-integration\.ps1:\d+')) 'the integration script loaded without errors'
    } finally { Stop-WmuxInstance $w }
}
