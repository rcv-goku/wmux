# wp: W1-7a
# covers: persistence-session-snapshot-autosave, persistence-session-restore-on-launch, persistence-restored-layout-and-metadata, persistence-restore-working-directories
# budget-sec: 900
# Session v3 core (ARCHITECTURE.md ADR-9.1-9.4, 9.6, 9.8): the autosave, the full save of the
# last WM_CLOSE, restore on launch with saved identities, split ratios and working directories,
# the crash-loop guard, the one-time v2 migration and the test-mode gating (ADR-12.3).
#
# A relaunch needs the same STATE directory: Start-SharedInstance points a new -Restore instance
# at an existing state directory through a module-scoped wrapper of the harness's child
# environment (everything else, the focus sampler and the visibility guard included, is the
# harness's). "Stop gracefully" posts WM_CLOSE to the instance's top-level windows (never
# activates anything) and waits for the process to exit. Identities, ratios and cwds are read
# from the session files the instances write (wmux.debug.layout arrives with W1-1a); the
# CMUX_SURFACE_ID check runs when the terminal environment exports it (W1-3) and is reported as
# pending otherwise.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:Mod = Get-Module WmuxTest
$script:NextId = 700

Add-Type -Namespace W17a -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@

# Module-scoped override: when $script:W17aStateDir is set, the next instance uses that state
# directory instead of its own (the relaunch of a previous instance).
& $script:Mod {
    if (-not (Get-Command 'New-WmuxChildEnvironmentW17aBase' -ErrorAction SilentlyContinue)) {
        ${function:script:New-WmuxChildEnvironmentW17aBase} = ${function:New-WmuxChildEnvironment}
        ${function:script:New-WmuxChildEnvironment} = {
            param(
                [Parameter(Mandatory)][System.Collections.IDictionary]$BaseEnvironment,
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Id,
                [switch]$Visible,
                [switch]$Restore,
                [switch]$KeepLocalAppData
            )
            $m = New-WmuxChildEnvironmentW17aBase @PSBoundParameters
            if ($script:W17aStateDir) { $m['WMUX_STATE_DIR'] = $script:W17aStateDir }
            return , $m
        }
    }
}

function Start-SharedInstance {
    # A -Restore instance whose WMUX_STATE_DIR is $StateDir.
    param([Parameter(Mandatory)][string]$StateDir, [string]$Shell)
    & $script:Mod { param($d) $script:W17aStateDir = $d } $StateDir
    try {
        if ($Shell) { return Start-WmuxInstance -Restore -Shell $Shell -TimeoutSec 60 }
        return Start-WmuxInstance -Restore -TimeoutSec 60
    } finally {
        & $script:Mod { $script:W17aStateDir = $null }
    }
}

function Invoke-Legacy {
    param([Parameter(Mandatory, Position = 0)]$Instance, [Parameter(Mandatory, Position = 1)][string]$Cmd, [Parameter(Position = 2)][hashtable]$Arguments, [switch]$AllowError)
    $script:NextId++
    $req = [ordered]@{ id = $script:NextId; cmd = $Cmd }
    if ($null -ne $Arguments) { $req.args = $Arguments }
    $reply = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $Instance (ConvertTo-Json -InputObject $req -Compress -Depth 10) -TimeoutSec 20))
    if ($AllowError) { return $reply }
    Assert-True $reply.ok "legacy '$Cmd' failed: $($reply.error)"
    return $reply.data
}

function Close-Gracefully {
    # WM_CLOSE to every top-level wmux window (the last one triggers the full save), then wait
    # for the process to exit.
    param([Parameter(Mandatory)]$Instance, [int]$TimeoutSec = 30)
    [WmuxTestHarness.FocusSampler]::BeginTeardown($Instance.Pid)
    foreach ($h in @([WmuxTestHarness.Native]::TopLevelWindows($Instance.Pid, 'WmuxWindow'))) {
        $null = [W17a.Native]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    Assert-True ($Instance.Process.WaitForExit($TimeoutSec * 1000)) "wmux exits after WM_CLOSE of its last window"
}

function Get-SessionDir { param([string]$StateDir) return (Join-Path $StateDir 'session') }

function Read-Session {
    param([string]$StateDir)
    $f = Join-Path (Get-SessionDir $StateDir) 'session.json'
    Assert-True (Test-Path -LiteralPath $f -PathType Leaf) "session.json exists in $StateDir\session"
    return [WmuxTestHarness.Json]::Parse([IO.File]::ReadAllText($f))
}

function Wait-RestoreDone {
    param([Parameter(Mandatory)]$Instance, [Parameter(Mandatory)][string]$StateDir, [int]$Workspaces)
    $marker = Join-Path (Get-SessionDir $StateDir) 'session.restoring'
    $null = Wait-WmuxCondition -TimeoutSec 60 -IntervalMs 200 {
        (-not (Test-Path -LiteralPath $marker)) -and (@(Invoke-Legacy $Instance 'workspace-list').Count -eq $Workspaces)
    }
}

function Get-LeafPanes {
    # Pane ids of a v3 layout, depth-first (a before b).
    param($Layout)
    if ($null -eq $Layout) { return @() }
    if ($null -ne (Get-Member -InputObject $Layout -Name 'pane' -ErrorAction SilentlyContinue)) { return @($Layout.pane) }
    return @(Get-LeafPanes $Layout.split.a) + @(Get-LeafPanes $Layout.split.b)
}

function Get-Ratios {
    param($Layout)
    if ($null -eq $Layout -or $null -ne (Get-Member -InputObject $Layout -Name 'pane' -ErrorAction SilentlyContinue)) { return @() }
    return @([double]$Layout.split.ratio) + @(Get-Ratios $Layout.split.a) + @(Get-Ratios $Layout.split.b)
}

function Get-TabMap {
    # surface UUID -> @{ cwd; title } for every tab of every workspace of window 0.
    param($Session)
    $map = @{}
    foreach ($ws in @($Session.windows[0].workspaces)) {
        foreach ($p in @($ws.panes)) {
            foreach ($t in @($p.tabs)) {
                $map[[string]$t.id] = @{ cwd = [string]$t.panel.cwd; ref = [int]$t.ref; pane = [string]$p.id }
            }
        }
    }
    return $map
}


function Wait-Seconds {
    # A fixed observation window (the "never writes while idle" checks), not a condition wait.
    param([double]$Seconds)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { Start-Sleep -Milliseconds 200 }
}

function Wait-CmdPrompt {
    param($Instance, [hashtable]$Surface = @{})
    $null = Wait-WmuxScreen $Instance -Surface $Surface -Pattern '(?m)^WMUX>' -TimeoutSec 45
}

function Send-Line {
    param($Instance, [hashtable]$Target, [string]$Text)
    $a = @{ text = $Text; enter = $true }
    foreach ($k in $Target.Keys) { $a[$k] = $Target[$k] }
    $null = Invoke-Legacy $Instance 'send' $a
}

$script:Tag = 0

function Invoke-Probe {
    # Types a cmd line whose output is one short "W17A-T<n>-<value>" line and returns <value>.
    # In the typed text the prefix is spelled "W17A-T<n>^-" (cmd drops the caret), so the echoed
    # command line (which may wrap in a narrow pane) never matches the pattern; only the output
    # does. `$Body` writes the prefix as %Q%.
    param($Instance, [hashtable]$Target, [string]$Body)
    $script:Tag++
    $t = "T$($script:Tag)"
    $line = $Body.Replace('%Q%-', "W17A-$t^-")
    Send-Line $Instance $Target $line
    $text = Wait-WmuxScreen $Instance -Surface $Target -Pattern "(?m)^W17A-$t-(\S*)\s*$" -TimeoutSec 30
    return [regex]::Match($text, "(?m)^W17A-$t-(\S*)\s*$").Groups[1].Value
}

function Get-CwdIndex {
    # Which of $Dirs is the terminal's current directory ("X" for none).
    param($Instance, [hashtable]$Target, [string[]]$Dirs)
    $parts = for ($i = 0; $i -lt $Dirs.Count; $i++) { "if /i ""%CD%""==""$($Dirs[$i])"" (echo %Q%-$i)" }
    return Invoke-Probe $Instance $Target (($parts -join ' else ') + ' else (echo %Q%-X)')
}

function Get-SurfaceIdEnv {
    # CMUX_SURFACE_ID in the terminal ("" when not exported).
    param($Instance, [hashtable]$Target)
    $v = Invoke-Probe $Instance $Target 'if defined CMUX_SURFACE_ID (echo %Q%-%CMUX_SURFACE_ID%) else (echo %Q%-)'
    return $v
}

function Set-ReportedCwd {
    # cd into $Dir and report it the way shell integration does (OSC 7, written by a child
    # process: cmd itself has no OSC 7), so the terminal's pwd is $Dir.
    param($Instance, [hashtable]$Target, [string]$Dir)
    $uri = 'file:///' + ($Dir -replace '\\', '/')
    $osc = "powershell -NoLogo -NoProfile -Command ""[Console]::Write([char]27+']7;$uri'+[char]27+'\')"""
    $null = Invoke-Probe $Instance $Target "cd /d ""$Dir"" & $osc & echo %Q%-ok"
}

function Get-MTime {
    # Last write time of the session file; while ReplaceFileW swaps it in the name can be missing
    # for a moment, so a missing file reads as the previous value would (callers skip 1601).
    param([string]$Path)
    for ($i = 0; $i -lt 20; $i++) {
        $t = [IO.File]::GetLastWriteTimeUtc($Path)
        if ($t.Year -gt 1601) { return $t }
        Start-Sleep -Milliseconds 10
    }
    return $t
}

function Read-LogText {
    param([string]$Path)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { return ([IO.StreamReader]::new($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

function New-Dirs {
    param([string]$Base, [int]$Count)
    $out = @()
    foreach ($n in 0..($Count - 1)) {
        $d = Join-Path $Base "w17a-$n"
        $null = New-Item -ItemType Directory -Force -Path $d
        $out += (Get-Item -LiteralPath $d).FullName
    }
    return , $out
}

Test-Case 'session v3: three workspaces with splits come back after a graceful restart (titles, ratios, cwds, surface UUIDs)' {
    $a = $null
    $b = $null
    try {
        $a = Start-WmuxInstance -Restore -TimeoutSec 60
        $state = $a.StateDir
        $dirs = New-Dirs $a.WorkDir 6
        Wait-CmdPrompt $a @{ workspace = 0; pane = 0 }
        $null = Invoke-Legacy $a 'workspace-new' @{ name = 'w17a-one' }
        $null = Invoke-Legacy $a 'workspace-new' @{ name = 'w17a-two' }
        $null = Invoke-Legacy $a 'new-split' @{ workspace = 0; dir = 'right' }
        $null = Invoke-Legacy $a 'new-split' @{ workspace = 1; dir = 'down' }
        $null = Invoke-Legacy $a 'new-split' @{ workspace = 2; dir = 'right' }
        $k = 0
        foreach ($ws in 0..2) {
            foreach ($pane in 0..1) {
                Wait-CmdPrompt $a @{ workspace = $ws; pane = $pane }
                Set-ReportedCwd $a @{ workspace = $ws; pane = $pane } $dirs[$k]
                $k++
            }
        }
        Close-Gracefully $a
        $saved = Read-Session $state
        Assert-Equal 'wmux-session' $saved.schema
        Assert-Equal 3 $saved.version
        Assert-Equal $true $saved.clean_exit 'the last WM_CLOSE writes a full save (clean_exit)'
        Assert-Equal 1 @($saved.windows).Count
        $wss = @($saved.windows[0].workspaces)
        Assert-Equal 3 $wss.Count 'three workspaces are saved'
        Assert-Equal 'w17a-one' $wss[1].title.custom
        Assert-Equal 'w17a-two' $wss[2].title.custom
        foreach ($ws in $wss) { Assert-Equal 2 @($ws.panes).Count "workspace '$($ws.title.custom)' saves its split" }
        $savedTabs = Get-TabMap $saved
        $savedCwds = @($savedTabs.Values | ForEach-Object { $_.cwd } | Sort-Object)
        Assert-Equal (($dirs | Sort-Object) -join '|') ($savedCwds -join '|') 'every terminal saves the directory its shell reported'

        $b = Start-SharedInstance -StateDir $state
        Wait-RestoreDone $b $state 3
        $list = @(Invoke-Legacy $b 'workspace-list')
        Assert-Equal 'w17a-one' $list[1].name 'workspace titles come back'
        Assert-Equal 'w17a-two' $list[2].name
        $seen = @()
        $byIndex = @{}
        foreach ($ws in 0..2) {
            $rows = @(Invoke-Legacy $b 'surface-list' @{ workspace = $ws })
            Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count "workspace $ws comes back with its split"
            foreach ($pane in 0..1) {
                Wait-CmdPrompt $b @{ workspace = $ws; pane = $pane }
                $i = Get-CwdIndex $b @{ workspace = $ws; pane = $pane } $dirs
                Assert-Match '^\d+$' $i "workspace $ws pane $pane restarts in one of the saved directories"
                $seen += [int]$i
                $byIndex["$ws/$pane"] = [int]$i
            }
        }
        Assert-Equal '0,1,2,3,4,5' (($seen | Sort-Object) -join ',') 'every restored terminal opens in its own saved directory'
        # Workspace 1 must survive the restore (W0-ST lost it within seconds).
        Wait-Seconds 5
        Assert-Equal 3 @(Invoke-Legacy $b 'workspace-list').Count 'all workspaces are still there seconds after the restore'
        $null = Invoke-Legacy $b 'read-screen' @{ workspace = 1; pane = 0 }

        # CMUX_SURFACE_ID in a restored shell is the saved surface UUID (exported by W1-3).
        $sid = Get-SurfaceIdEnv $b @{ workspace = 1; pane = 1 }
        $dir = $dirs[$byIndex['1/1']]
        $expected = @($savedTabs.Keys | Where-Object { $savedTabs[$_].cwd -eq $dir })
        Assert-Equal 1 $expected.Count "one saved tab has the directory $dir"
        if ($sid) {
            Assert-Equal $expected[0] $sid 'CMUX_SURFACE_ID in the restored shell equals the saved surface UUID'
        } else {
            Write-Host 'CMUX_SURFACE_ID is not exported yet (W1-3); the surface UUID is checked through the session file'
        }

        Close-Gracefully $b
        $again = Read-Session $state
        $againTabs = Get-TabMap $again
        Assert-Equal (($savedTabs.Keys | Sort-Object) -join ',') (($againTabs.Keys | Sort-Object) -join ',') 'surface UUIDs survive the restart'
        foreach ($id in $savedTabs.Keys) {
            Assert-Equal $savedTabs[$id].ref $againTabs[$id].ref "surface $id keeps its ref"
            Assert-Equal $savedTabs[$id].cwd $againTabs[$id].cwd "surface $id keeps its cwd"
            Assert-Equal $savedTabs[$id].pane $againTabs[$id].pane "surface $id stays in its pane"
        }
        $w0 = @($saved.windows[0].workspaces); $w1 = @($again.windows[0].workspaces)
        Assert-Equal $saved.windows[0].id $again.windows[0].id 'the window UUID survives'
        for ($i = 0; $i -lt 3; $i++) {
            Assert-Equal $w0[$i].id $w1[$i].id "workspace $i keeps its UUID"
            Assert-Equal $w0[$i].ref $w1[$i].ref "workspace $i keeps its ref"
            Assert-Equal ([string]$w0[$i].title.custom) ([string]$w1[$i].title.custom) "workspace $i keeps its title"
            Assert-Equal ((Get-LeafPanes $w0[$i].layout) -join ',') ((Get-LeafPanes $w1[$i].layout) -join ',') "workspace $i keeps its layout"
            $r0 = @(Get-Ratios $w0[$i].layout); $r1 = @(Get-Ratios $w1[$i].layout)
            Assert-Equal $r0.Count $r1.Count
            for ($j = 0; $j -lt $r0.Count; $j++) {
                Assert-True ([Math]::Abs($r0[$j] - $r1[$j]) -le 0.01) "split ratio $($r0[$j]) comes back within 1% (got $($r1[$j]))"
            }
        }
        Assert-Equal $saved.windows[0].selected_workspace $again.windows[0].selected_workspace 'the selected workspace comes back'
    } finally {
        Stop-WmuxInstance $a
        Stop-WmuxInstance $b
    }
}

Test-Case 'session v3: a seeded session restores cwds with the tab -> workspace -> profile fallback and its ratios' {
    $a = $null
    $b = $null
    try {
        # A first instance only provides an isolated state directory.
        $a = Start-WmuxInstance
        $state = $a.StateDir
        Stop-WmuxInstance $a
        $a = $null
        $made = New-Dirs $state 2
        $tabDir = $made[0]
        $wsDir = $made[1]
        $profile = [Environment]::GetFolderPath('UserProfile')
        $gone = Join-Path $state 'w17a-gone'
        $ids = @(1..12 | ForEach-Object { [guid]::NewGuid().ToString().ToUpperInvariant() })
        $doc = [ordered]@{
            schema = 'wmux-session'; version = 3; app_version = 'e2e'; channel = ''; clean_exit = $true
            handles = [ordered]@{ next = [ordered]@{ window = 2; workspace = 3; workspace_group = 1; pane = 4; surface = 4 } }
            windows = @([ordered]@{
                    id = $ids[0]; ref = 1; selected_workspace = $ids[1]
                    workspaces = @(
                        [ordered]@{
                            id = $ids[1]; ref = 1; title = [ordered]@{ custom = 'w17a-seeded'; auto = $null; source = 'user' }; cwd = $wsDir
                            focused_pane = $ids[3]
                            layout = [ordered]@{ split = [ordered]@{ dir = 'horizontal'; ratio = 0.3; a = [ordered]@{ pane = $ids[3] }; b = [ordered]@{ pane = $ids[4] } } }
                            panes = @(
                                [ordered]@{ id = $ids[3]; ref = 1; tabs = @([ordered]@{ id = $ids[6]; ref = 1; title = [ordered]@{ custom = $null; auto = 'tab-a'; source = 'process' }; panel = [ordered]@{ kind = 'terminal'; cwd = $tabDir } }) },
                                [ordered]@{ id = $ids[4]; ref = 2; tabs = @([ordered]@{ id = $ids[7]; ref = 2; title = [ordered]@{ custom = $null; auto = 'tab-b'; source = 'process' }; panel = [ordered]@{ kind = 'terminal'; cwd = $gone } }) }
                            )
                        },
                        [ordered]@{
                            id = $ids[2]; ref = 2; title = [ordered]@{ custom = 'w17a-gone'; auto = $null; source = 'user' }; cwd = $gone
                            layout = [ordered]@{ pane = $ids[5] }
                            panes = @([ordered]@{ id = $ids[5]; ref = 3; tabs = @([ordered]@{ id = $ids[8]; ref = 3; panel = [ordered]@{ kind = 'terminal'; cwd = $gone } }) })
                        }
                    )
                })
        }
        $sdir = Get-SessionDir $state
        $null = New-Item -ItemType Directory -Force -Path $sdir
        [IO.File]::WriteAllText((Join-Path $sdir 'session.json'), (ConvertTo-Json -InputObject $doc -Depth 50), [Text.UTF8Encoding]::new($false))

        $b = Start-SharedInstance -StateDir $state
        Wait-RestoreDone $b $state 2
        $list = @(Invoke-Legacy $b 'workspace-list')
        Assert-Equal 'w17a-seeded' $list[0].name
        Assert-Equal 'w17a-gone' $list[1].name
        $rows = @(Invoke-Legacy $b 'surface-list' @{ workspace = 0 })
        Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count
        $candidates = @($tabDir, $wsDir, $profile)
        $found = @()
        foreach ($pane in 0..1) {
            Wait-CmdPrompt $b @{ workspace = 0; pane = $pane }
            $found += Get-CwdIndex $b @{ workspace = 0; pane = $pane } $candidates
        }
        Assert-Equal '0,1' (($found | Sort-Object) -join ',') 'the tab cwd is used, and a gone tab cwd falls back to the workspace cwd'
        Wait-CmdPrompt $b @{ workspace = 1; pane = 0 }
        Assert-Equal '2' (Get-CwdIndex $b @{ workspace = 1; pane = 0 } $candidates) 'gone tab and workspace directories fall back to %USERPROFILE%'

        $sid = Get-SurfaceIdEnv $b @{ workspace = 1; pane = 0 }
        if ($sid) { Assert-Equal $ids[8] $sid 'CMUX_SURFACE_ID equals the saved surface UUID' } else { Write-Host 'CMUX_SURFACE_ID not exported yet (W1-3)' }

        Close-Gracefully $b
        $again = Read-Session $state
        $ws0 = $again.windows[0].workspaces[0]
        Assert-Equal $ids[0] $again.windows[0].id 'the window keeps its saved UUID'
        Assert-Equal $ids[1] $ws0.id
        Assert-True ([Math]::Abs([double]$ws0.layout.split.ratio - 0.3) -le 0.01) "the 0.3 split ratio comes back within 1% (got $($ws0.layout.split.ratio))"
        Assert-Equal $ids[3] $ws0.focused_pane 'the focused pane comes back'
        Assert-Equal (($ids[6], $ids[7], $ids[8] | Sort-Object) -join ',') (((Get-TabMap $again).Keys | Sort-Object) -join ',') 'surface UUIDs are adopted'
    } finally {
        Stop-WmuxInstance $a
        Stop-WmuxInstance $b
    }
}

Test-Case 'session v3: a restore killed mid-way (session.restoring left behind) is skipped once, set aside and noticed; the next launch restores' {
    $a = $null; $b = $null; $c = $null
    try {
        $a = Start-WmuxInstance -Restore
        $state = $a.StateDir
        Wait-CmdPrompt $a
        $null = Invoke-Legacy $a 'workspace-new' @{ name = 'w17a-crash' }
        Wait-CmdPrompt $a @{ workspace = 1 }
        Close-Gracefully $a
        $sdir = Get-SessionDir $state
        Assert-True (Test-Path -LiteralPath (Join-Path $sdir 'session.json')) 'the first instance saved its session'
        # What a restore killed before it finished leaves behind: the marker (and the snapshot).
        [IO.File]::WriteAllText((Join-Path $sdir 'session.restoring'), '{"pid":1,"started_ms":0}')

        $b = Start-SharedInstance -StateDir $state
        Wait-CmdPrompt $b
        Assert-Equal 1 @(Invoke-Legacy $b 'workspace-list').Count 'the launch after a crashed restore does not restore'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $sdir 'session.restoring'))) 'the restoring marker is gone'
        $crashed = @(Get-ChildItem -LiteralPath $sdir -Filter 'session.crashed-*.json')
        Assert-Equal 1 $crashed.Count 'the snapshot is renamed session.crashed-<ms>.json'
        Assert-Match '^session\.crashed-\d+\.json$' $crashed[0].Name
        Assert-Match 'w17a-crash' ([IO.File]::ReadAllText($crashed[0].FullName)) 'the set-aside file is the crashed snapshot'
        $log = Join-Path $state 'logs\wmux.log'
        $null = Wait-WmuxCondition -TimeoutSec 15 { (Test-Path -LiteralPath $log) -and ((Read-LogText $log) -match 'notice session\.crashed') }
        $null = Invoke-Legacy $b 'workspace-new' @{ name = 'w17a-after' }
        Wait-CmdPrompt $b @{ workspace = 1 }
        Close-Gracefully $b

        $c = Start-SharedInstance -StateDir $state
        Wait-RestoreDone $c $state 2
        Assert-Equal 'w17a-after' (@(Invoke-Legacy $c 'workspace-list'))[1].name 'the launch after that restores normally'
    } finally {
        Stop-WmuxInstance $a
        Stop-WmuxInstance $b
        Stop-WmuxInstance $c
    }
}

Test-Case 'session v3: the autosave writes at most once per 8 s tick under a send loop and never on idle' {
    $w = $null
    try {
        $w = Start-WmuxInstance -Restore
        Wait-CmdPrompt $w
        $file = Join-Path (Get-SessionDir $w.StateDir) 'session.json'
        # The first tick saves the initial state.
        $null = Wait-WmuxCondition -TimeoutSec 20 { Test-Path -LiteralPath $file }
        $writes = [System.Collections.Generic.List[datetime]]::new()
        $last = (Get-MTime $file)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $n = 0
        while ($sw.Elapsed.TotalSeconds -lt 26) {
            # A structural change (the description) and terminal output twice a second.
            $n++
            $null = Invoke-Legacy $w 'workspace-set-description' @{ workspace = 0; text = "w17a loop $n" }
            $null = Invoke-Legacy $w 'send' @{ text = "echo loop $n"; enter = $true }
            $step = [Diagnostics.Stopwatch]::StartNew()
            while ($step.ElapsedMilliseconds -lt 500) {
                $now = (Get-MTime $file)
                if ($now -ne $last -and $now.Year -gt 1601) { $writes.Add($now); $last = $now }
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host "autosave writes during the 26 s loop: $($writes.Count) ($(@($writes | ForEach-Object { $_.ToString('HH:mm:ss.fff') }) -join ', '))"
        Assert-True ($writes.Count -ge 2) 'the autosave saves the changes made under the loop'
        Assert-True ($writes.Count -le 4) "at most one write per 8 s tick (got $($writes.Count) in 26 s)"
        for ($i = 1; $i -lt $writes.Count; $i++) {
            $gap = ($writes[$i] - $writes[$i - 1]).TotalSeconds
            Assert-True ($gap -ge 6.5) "writes are a tick apart (gap $gap s)"
        }
        # Idle: the next tick may still save the loop's last change; after it nothing changes.
        Wait-Seconds 9
        $idle = (Get-MTime $file)
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while ($sw2.Elapsed.TotalSeconds -lt 20) {
            Assert-Equal $idle (Get-MTime $file) 'an idle app never writes session.json'
            Start-Sleep -Milliseconds 500
        }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'session v3: the legacy v2 file is migrated once on launch and its workspaces and splits come back' {
    $a = $null; $b = $null
    try {
        $a = Start-WmuxInstance
        Wait-CmdPrompt $a
        $null = Invoke-Legacy $a 'new-split' @{ dir = 'right' }
        $null = Invoke-Legacy $a 'workspace-new' @{ name = 'w17a-v2' }
        $null = Invoke-Legacy $a 'new-split' @{ workspace = 1; dir = 'down' }
        Wait-CmdPrompt $a @{ workspace = 1; pane = 1 }
        # The explicit legacy session-save still writes the v2 file (owner decision 2026-10-17 b).
        $null = Invoke-Legacy $a 'session-save'
        $state = $a.StateDir
        $v2 = Join-Path $state 'session-state.json'
        Assert-True (Test-Path -LiteralPath $v2) 'session-save writes session-state.json'
        Close-Gracefully $a
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-SessionDir $state) 'session.json'))) 'test mode without WMUX_TEST_SESSION_RESTORE saves nothing automatically, not even on the last WM_CLOSE'
        Stop-WmuxInstance $a
        $a = $null

        $b = Start-SharedInstance -StateDir $state
        Wait-RestoreDone $b $state 2
        Assert-True (Test-Path -LiteralPath "$v2.migrated") 'the legacy file is renamed .migrated'
        Assert-True (-not (Test-Path -LiteralPath $v2)) 'and is not read again'
        $migrated = Read-Session $state
        Assert-Equal 2 @($migrated.windows[0].workspaces).Count
        Assert-Equal 'w17a-v2' (@(Invoke-Legacy $b 'workspace-list'))[1].name
        foreach ($ws in 0..1) {
            $rows = @(Invoke-Legacy $b 'surface-list' @{ workspace = $ws })
            Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count "migrated workspace $ws keeps its split"
            Wait-CmdPrompt $b @{ workspace = $ws; pane = 1 }
        }
    } finally {
        Stop-WmuxInstance $a
        Stop-WmuxInstance $b
    }
}

Test-Case 'session v3: legacy session-restore of two workspaces keeps both and the background splits (W0-ST regression)' {
    $a = $null; $b = $null
    try {
        $a = Start-WmuxInstance
        Wait-CmdPrompt $a
        $null = Invoke-Legacy $a 'new-split' @{ dir = 'right' }
        $null = Invoke-Legacy $a 'workspace-new' @{ name = 'w17a-bg' }
        $null = Invoke-Legacy $a 'new-split' @{ workspace = 1; dir = 'down' }
        Wait-CmdPrompt $a @{ workspace = 1; pane = 1 }
        $null = Invoke-Legacy $a 'session-save'
        $text = [IO.File]::ReadAllText((Join-Path $a.StateDir 'session-state.json'))
        Stop-WmuxInstance $a
        $a = $null

        $b = Start-WmuxInstance
        Wait-CmdPrompt $b
        [IO.File]::WriteAllText((Join-Path $b.StateDir 'session-state.json'), $text, [Text.UTF8Encoding]::new($false))
        $null = Invoke-Legacy $b 'session-restore'
        Assert-Equal 2 @(Invoke-Legacy $b 'workspace-list').Count 'both workspaces are restored'
        foreach ($ws in 0..1) {
            $rows = @(Invoke-Legacy $b 'surface-list' @{ workspace = $ws })
            Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count "workspace $ws keeps its split"
        }
        Wait-CmdPrompt $b @{ workspace = 1; pane = 0 }
        Wait-CmdPrompt $b @{ workspace = 1; pane = 1 }
        # Seconds later the background workspace is still there and answers.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 6) {
            Assert-Equal 2 @(Invoke-Legacy $b 'workspace-list').Count 'workspace 1 does not disappear after the restore'
            $null = Invoke-Legacy $b 'read-screen' @{ workspace = 1; pane = 0 }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Stop-WmuxInstance $a
        Stop-WmuxInstance $b
    }
}
