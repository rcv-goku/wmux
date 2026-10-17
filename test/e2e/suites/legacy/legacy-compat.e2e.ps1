# wp: W0-B2
# Legacy wmux JSON compatibility (ADR-3.7, AF-11, AF-19). All 37 legacy commands of the
# \\.\pipe\wmux-ipc-<pid> protocol run against isolated hidden instances; every reply (success
# and the documented error cases) is matched against the reply shapes pinned under
# test/e2e/fixtures/legacy/<command>.json, plus the protocol-level replies in _protocol.json.
# The last Test-Case checks that the fixtures cover exactly the command list of
# src/apprt/win32/rpc/compat/legacy_json.zig and that every pinned case was exercised.
# Workspaces and tabs are closed only after their shell prompt appeared (the known teardown
# hang of a just-created tab or workspace, ADR-12.7 / W0-ST, is covered by the runner's retry).
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:FixtureDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\fixtures\legacy'))
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$script:Fixtures = @{}
$script:Used = [System.Collections.Generic.HashSet[string]]::new()
$script:Completed = [System.Collections.Generic.HashSet[string]]::new()
$script:NextId = 100

function Get-LegacyFixture {
    param([string]$Cmd)
    if (-not $script:Fixtures.ContainsKey($Cmd)) {
        $path = Join-Path $script:FixtureDir "$Cmd.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "no fixture $path" }
        $script:Fixtures[$Cmd] = [WmuxTestHarness.Json]::Parse([IO.File]::ReadAllText($path))
    }
    return $script:Fixtures[$Cmd]
}

function Send-Legacy {
    # One legacy request; the reply envelope must match fixtures/legacy/<Cmd>.json[<Expect>].
    # Returns the reply's data.
    param(
        [Parameter(Mandatory, Position = 0)]$Instance,
        [Parameter(Mandatory, Position = 1)][string]$Cmd,
        [Parameter(Position = 2)][hashtable]$Arguments,
        [string]$Expect = 'ok',
        [double]$TimeoutSec = 20
    )
    $shape = (Get-LegacyFixture $Cmd).PSObject.Properties[$Expect]
    Assert-True ($null -ne $shape) "fixtures/legacy/$Cmd.json has no case '$Expect'"
    $script:NextId++
    $id = $script:NextId
    $req = [ordered]@{ id = $id; cmd = $Cmd }
    if ($null -ne $Arguments) { $req.args = $Arguments }
    $line = Invoke-WmuxRawLine $Instance (ConvertTo-Json -InputObject $req -Compress -Depth 10) -TimeoutSec $TimeoutSec
    $reply = [WmuxTestHarness.Json]::Parse($line)
    Assert-Equal ([long]$id) $reply.id "reply id of $Cmd"
    Assert-JsonShape $reply $shape.Value "$Cmd ($Expect)"
    $null = $script:Used.Add("$Cmd/$Expect")
    # No unary comma: callers wrap list replies in @() (see smoke.e2e.ps1).
    return $reply.data
}

function Wait-Prompt {
    param($Instance, [hashtable]$Surface = @{})
    $null = Wait-WmuxScreen $Instance -Surface $Surface -Pattern '(?m)^WMUX>' -TimeoutSec 30
}

function Get-FirstUnusedSurfaceId {
    # A u64 that is no surface id of the instance (ids are random 64-bit values).
    param([object[]]$Rows)
    $ids = @($Rows | ForEach-Object { [string]$_.id })
    $candidate = 4242
    while ($ids -contains [string]$candidate) { $candidate++ }
    return $candidate
}

Test-Case 'legacy-compat: workspace-list, -new, -select, -set-description and -close' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $list = @(Send-Legacy $w 'workspace-list')
        Assert-Equal 1 $list.Count 'one workspace at startup'
        $created = Send-Legacy $w 'workspace-new' @{ name = 'lc-two' }
        Assert-Equal 1 $created.index
        Wait-Prompt $w @{ workspace = 1 }
        $null = Send-Legacy $w 'workspace-set-description' @{ workspace = 1; text = 'described' }
        $null = Send-Legacy $w 'workspace-set-description' @{ text = 'no index' } -Expect 'missing_index'
        $null = Send-Legacy $w 'workspace-select' @{ index = 1 }
        $list = @(Send-Legacy $w 'workspace-list')
        Assert-Equal 2 $list.Count
        Assert-Equal 'lc-two' $list[1].name
        Assert-True $list[1].active 'workspace-select made workspace 1 active'
        $null = Send-Legacy $w 'workspace-select' @{ index = 0 }
        $null = Send-Legacy $w 'workspace-select' @{ index = 99 } -Expect 'unknown_workspace'
        $null = Send-Legacy $w 'workspace-select' @{} -Expect 'missing_index'
        $null = Send-Legacy $w 'workspace-close' @{ index = 1 }
        $null = Send-Legacy $w 'workspace-close' @{ index = 5 } -Expect 'unknown_workspace'
        $list = @(Send-Legacy $w 'workspace-list')
        Assert-Equal 1 $list.Count 'workspace-close removed it'
        $null = $script:Completed.Add('workspaces')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: tab-list, -new, -select, -close, surface-list and surface-focus' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $tabs = @(Send-Legacy $w 'tab-list')
        Assert-Equal 1 $tabs.Count
        $null = Send-Legacy $w 'tab-list' @{ pane = 7 } -Expect 'unknown_pane'
        $tab = Send-Legacy $w 'tab-new'
        Assert-Equal 1 $tab.index
        Wait-Prompt $w @{ tab = 1 }
        $null = Send-Legacy $w 'tab-select' @{ index = 1 }
        $null = Send-Legacy $w 'tab-select' @{} -Expect 'missing_index'
        $null = Send-Legacy $w 'tab-select' @{ index = 9 } -Expect 'unknown_tab'
        $rows = @(Send-Legacy $w 'surface-list')
        Assert-Equal 2 $rows.Count 'one pane with two tabs'
        Assert-True (@($rows | Where-Object { $_.focused }).Count -eq 1) 'exactly one focused surface'
        $null = Send-Legacy $w 'surface-focus' @{ surface = $rows[0].id }
        $null = Send-Legacy $w 'surface-focus' @{ surface = (Get-FirstUnusedSurfaceId $rows) } -Expect 'unknown_surface'
        $null = Send-Legacy $w 'surface-focus' @{ pane = 0; tab = 1 }
        $null = Send-Legacy $w 'surface-focus' @{ pane = 9 } -Expect 'unknown_pane'
        $null = Send-Legacy $w 'tab-close' @{ index = 1 }
        $null = Send-Legacy $w 'tab-close' @{ index = 9 } -Expect 'unknown_tab'
        $tabs = @(Send-Legacy $w 'tab-list')
        Assert-Equal 1 $tabs.Count 'tab-close removed it'
        $null = $script:Completed.Add('tabs')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: new-split, swap-split, select-layout, sync-input, flash-pane, break-pane and move-pane' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $split = Send-Legacy $w 'new-split' @{ dir = 'right' }
        Assert-True ([System.Numerics.BigInteger]::Parse([string]$split.id) -gt 0) 'new-split returns the new surface id'
        $null = Send-Legacy $w 'new-split' @{} -Expect 'missing_direction'
        $null = Send-Legacy $w 'new-split' @{ dir = 'sideways' } -Expect 'bad_direction'
        $rows = @(Send-Legacy $w 'surface-list')
        Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count 'two panes after the split'
        $null = Send-Legacy $w 'swap-split'
        $null = Send-Legacy $w 'select-layout' @{ layout = 'tiled' }
        $null = Send-Legacy $w 'select-layout' @{} -Expect 'missing_layout'
        $null = Send-Legacy $w 'select-layout' @{ layout = 'bogus' } -Expect 'unknown_layout'
        $null = Send-Legacy $w 'sync-input' @{ action = 'on' }
        $null = Send-Legacy $w 'sync-input' @{ action = 'off' }
        $null = Send-Legacy $w 'sync-input' @{ action = 'maybe' } -Expect 'bad_action'
        $null = Send-Legacy $w 'flash-pane'
        $null = Send-Legacy $w 'break-pane'
        $null = Send-Legacy $w 'move-pane' @{ direction = 'prev' }
        $null = Send-Legacy $w 'move-pane' @{ direction = 'diagonal' } -Expect 'bad_direction'
        $after = @(Send-Legacy $w 'surface-list')
        Assert-Equal $rows.Count $after.Count 'break-pane and move-pane keep every surface'
        $null = $script:Completed.Add('panes')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: send, read-screen and capture-pane' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Send-Legacy $w 'send' @{ text = 'echo LC-MARK-1'; enter = $true }
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^LC-MARK-1\s*$' -TimeoutSec 30
        $tail = Send-Legacy $w 'read-screen' @{ lines = 3 }
        Assert-Match 'LC-MARK-1' $tail
        $full = Send-Legacy $w 'read-screen' @{ scrollback = $true }
        Assert-Match 'WMUX>echo LC-MARK-1' $full
        $screen = Send-Legacy $w 'capture-pane'
        Assert-Match '(?m)^LC-MARK-1' $screen
        $file = Join-Path $w.WorkDir 'lc-capture.txt'
        $path = Send-Legacy $w 'capture-pane' @{ file = $file }
        Assert-Equal $file $path 'capture-pane --file answers with the path'
        Assert-Match 'LC-MARK-1' ([IO.File]::ReadAllText($file))
        $null = Send-Legacy $w 'send' @{} -Expect 'missing_text'
        $null = Send-Legacy $w 'send' @{ text = 'x'; tab = 9 } -Expect 'unknown_tab'
        $null = $script:Completed.Add('terminal-io')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: set-status, set-progress, log, notify and toggle-right-sidebar' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Send-Legacy $w 'notify' @{ action = 'toggle-read' } -Expect 'toggle_read_none'
        $null = Send-Legacy $w 'notify' @{ action = 'next' } -Expect 'next_none'
        $null = Send-Legacy $w 'set-status' @{ text = 'lc-busy' }
        $null = Send-Legacy $w 'set-status' @{}
        $null = Send-Legacy $w 'set-progress' @{ value = 40 }
        $null = Send-Legacy $w 'set-progress' @{ value = -1 }
        $null = Send-Legacy $w 'set-progress' @{ value = 400 } -Expect 'bad_progress'
        $null = Send-Legacy $w 'log' @{ text = 'legacy-compat log line' }
        $null = Send-Legacy $w 'log' @{} -Expect 'missing_text'
        $null = Send-Legacy $w 'notify' @{ action = 'ring' } -Expect 'ring'
        $null = Send-Legacy $w 'notify' @{ action = 'clear' } -Expect 'clear'
        $null = Send-Legacy $w 'notify' @{ action = 'next' } -Expect 'next_jumped'
        $null = Send-Legacy $w 'notify' @{ action = 'toggle-read' } -Expect 'toggle_read'
        $null = Send-Legacy $w 'notify' @{ action = 'mark-oldest-next' } -Expect 'mark_oldest_next'
        $null = Send-Legacy $w 'notify' @{} -Expect 'missing_action'
        $null = Send-Legacy $w 'notify' @{ action = 'bogus' } -Expect 'bad_action'
        $null = Send-Legacy $w 'toggle-right-sidebar'
        $null = Send-Legacy $w 'toggle-right-sidebar'
        $null = $script:Completed.Add('status')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: session-capture, -list, -resume, -save and -restore' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $empty = @(Send-Legacy $w 'session-list')
        Assert-Equal 0 $empty.Count 'the agent session store starts empty'
        $cap = Send-Legacy $w 'session-capture' @{ agent = 'lc-agent'; session = 'lc-session-1' }
        $null = Send-Legacy $w 'session-capture' @{ session = 'x' } -Expect 'missing_agent'
        $null = Send-Legacy $w 'session-capture' @{ agent = 'x' } -Expect 'missing_session'
        $list = @(Send-Legacy $w 'session-list')
        Assert-Equal 1 $list.Count
        Assert-Equal 'lc-session-1' $list[0].session
        Assert-Equal ([string]$cap.surface) ([string]$list[0].surface)
        $null = Send-Legacy $w 'session-resume' @{} -Expect 'no_recipe'
        $rows = @(Send-Legacy $w 'surface-list')
        $null = Send-Legacy $w 'session-resume' @{ surface = (Get-FirstUnusedSurfaceId $rows) } -Expect 'unknown_surface'
        $split = Send-Legacy $w 'new-split' @{ dir = 'down' }
        $null = Send-Legacy $w 'session-resume' @{ surface = $split.id } -Expect 'no_session'
        # session-restore tears the current terminals down: let the new split's shell start
        # first (a just-created terminal can hang its teardown, ADR-12.7 / W0-ST).
        Wait-Prompt $w @{ pane = 1 }
        $null = Send-Legacy $w 'session-save'
        Assert-True (Test-Path -LiteralPath (Join-Path $w.StateDir 'session-state.json') -PathType Leaf) 'session-save writes WMUX_STATE_DIR\session-state.json (never the user profile)'
        $null = Send-Legacy $w 'session-restore'
        $after = @(Send-Legacy $w 'workspace-list')
        Assert-True ($after.Count -ge 1) 'the instance still answers after session-restore'
        $null = $script:Completed.Add('session')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: open, navigate, eval, snapshot, click and fill' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Send-Legacy $w 'open' @{} -Expect 'missing_url'
        $null = Send-Legacy $w 'navigate' @{ url = 'about:blank' } -Expect 'unknown_id'
        $null = Send-Legacy $w 'eval' @{ js = '1' } -Expect 'unknown_id'
        $null = Send-Legacy $w 'snapshot' -Expect 'unknown_id'
        $null = Send-Legacy $w 'click' @{ ref = 1 } -Expect 'unknown_id'
        $opened = Send-Legacy $w 'open' @{ url = 'about:blank'; target = 'tab' }
        $null = Send-Legacy $w 'navigate' @{ id = $opened.id; url = 'data:text/html,<title>lc</title><button onclick="document.title=''lc-clicked''">Go</button><input id=i aria-label=field>' }
        $null = Wait-WmuxCondition -TimeoutSec 30 {
            $r = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $w '{"id":90001,"cmd":"eval","args":{"js":"document.title"}}' -TimeoutSec 10))
            $r.ok -and $r.data -eq 'lc'
        }
        $title = Send-Legacy $w 'eval' @{ js = 'document.title' }
        Assert-Equal 'lc' $title
        $nodes = Wait-WmuxCondition -TimeoutSec 30 {
            $s = @(Send-Legacy $w 'snapshot')
            if (@($s | Where-Object { $_.role -eq 'button' }).Count -gt 0 -and @($s | Where-Object { $_.role -eq 'textbox' }).Count -gt 0) { $s }
        }
        $button = @($nodes | Where-Object { $_.role -eq 'button' })[0].ref
        $field = @($nodes | Where-Object { $_.role -eq 'textbox' })[0].ref
        $null = Send-Legacy $w 'click' @{ ref = $button }
        $null = Send-Legacy $w 'fill' @{ ref = $field; text = 'lc-text' }
        $null = Send-Legacy $w 'fill' @{ ref = $field } -Expect 'missing_text'
        $state = Send-Legacy $w 'eval' @{ js = 'document.title + "|" + document.getElementById("i").value' }
        Assert-Equal 'lc-clicked|lc-text' $state 'click and fill reached the page'
        $null = Send-Legacy $w 'send' @{ text = 'x' } -Expect 'not_a_terminal'
        $null = Send-Legacy $w 'read-screen' @{} -Expect 'not_a_terminal'
        $null = $script:Completed.Add('browser')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: protocol errors keep the pipe serving' {
    $w = Start-WmuxInstance
    try {
        $proto = Get-LegacyFixture '_protocol'
        $cases = @(
            @{ Line = '{"id":7,"cmd":"frobnicate"}'; Case = 'unknown_command' },
            @{ Line = 'not json'; Case = 'not_json' },
            @{ Line = '{"cmd":"workspace-list"}'; Case = 'invalid_request' },
            @{ Line = '{"id":-1,"cmd":"workspace-list"}'; Case = 'invalid_request' },
            @{ Line = '[1,2]'; Case = 'invalid_request' },
            @{ Line = '{"id":8,"cmd":"workspace-list","args":[1]}'; Case = 'invalid_args' }
        )
        foreach ($c in $cases) {
            $reply = Invoke-WmuxRawLine $w $c.Line
            Assert-JsonShape $reply $proto.PSObject.Properties[$c.Case].Value "reply to $($c.Line)"
            $null = $script:Used.Add("_protocol/$($c.Case)")
        }
        $list = @(Send-Legacy $w 'workspace-list')
        Assert-True ($list.Count -ge 1) 'the pipe still serves after protocol errors'
        $null = $script:Completed.Add('protocol')
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy-compat: fixtures cover all 37 legacy commands and every pinned case ran' {
    $files = @(Get-ChildItem -LiteralPath $script:FixtureDir -Filter '*.json' -File | Where-Object { -not $_.Name.StartsWith('_') } | ForEach-Object { $_.BaseName } | Sort-Object)
    Assert-Equal 37 $files.Count "fixtures/legacy holds one file per legacy command (ADR-3.7 lists 37): $($files -join ', ')"
    $source = Join-Path $script:RepoRoot 'src\apprt\win32\rpc\compat\legacy_json.zig'
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        $text = [IO.File]::ReadAllText($source)
        $enum = [regex]::Match($text, '(?s)pub const Command = enum \{(.*?)\n\};').Groups[1].Value
        $names = @([regex]::Matches($enum, '(?m)^\s*(?:@"([a-z-]+)"|([a-z]+)),') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Sort-Object)
        Assert-Equal ($names -join ',') ($files -join ',') 'the fixtures match the Command enum of legacy_json.zig'
    }
    $areas = @('workspaces', 'tabs', 'panes', 'terminal-io', 'status', 'session', 'browser', 'protocol')
    $missingAreas = @($areas | Where-Object { -not $script:Completed.Contains($_) })
    if ($missingAreas.Count -gt 0) {
        throw [WmuxSkipException]::new("case coverage not checked: these Test-Cases did not complete: $($missingAreas -join ', ')")
    }
    $pinned = foreach ($f in $files + @('_protocol')) {
        foreach ($p in (Get-LegacyFixture $f).PSObject.Properties) { if ($p.Name -ne '//') { "$f/$($p.Name)" } }
    }
    $unused = @($pinned | Where-Object { -not $script:Used.Contains($_) })
    Assert-Equal 0 $unused.Count "pinned reply cases never exercised: $($unused -join ', ')"
}
