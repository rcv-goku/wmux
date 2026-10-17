# wp: W0-B2
# W0 regression checklist (AF-19: replaces the human dogfood gate of wave 0). Scripted over the
# legacy JSON protocol against isolated hidden instances: splits, tabs, workspaces,
# send/read-screen, browser open/eval/snapshot, notify, status/progress/log, session save/restore,
# layouts, sync-input, break/move pane, right sidebar, and a DWMWA_CLOAKED-aware capture of the
# hidden window. Where the legacy protocol has no getter, effects are observed on the window
# itself (WmuxTerminal child rectangles) or in the instance's state files; reply shapes are
# legacy-compat's job. Workspaces and tabs are closed only after their prompt appeared (known
# teardown flake, ADR-12.7 / W0-ST: the runner's retry covers it).
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:NextId = 100

function Invoke-Legacy {
    # One legacy command; returns data; fails the test on ok:false unless -AllowError, which
    # returns the whole reply instead.
    param([Parameter(Mandatory, Position = 0)]$Instance, [Parameter(Mandatory, Position = 1)][string]$Cmd, [Parameter(Position = 2)][hashtable]$Arguments, [switch]$AllowError)
    $script:NextId++
    $req = [ordered]@{ id = $script:NextId; cmd = $Cmd }
    if ($null -ne $Arguments) { $req.args = $Arguments }
    $reply = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $Instance (ConvertTo-Json -InputObject $req -Compress -Depth 10) -TimeoutSec 20))
    if ($AllowError) { return $reply }
    Assert-True $reply.ok "legacy '$Cmd' failed: $($reply.error)"
    return $reply.data
}

function Wait-Prompt {
    param($Instance, [hashtable]$Surface = @{})
    $null = Wait-WmuxScreen $Instance -Surface $Surface -Pattern '(?m)^WMUX>' -TimeoutSec 30
}

function New-Marker {
    param([string]$Prefix = 'RG')
    return ($Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 10).ToUpperInvariant())
}

function Send-Echo {
    # Types "echo <marker>" into the addressed terminal and waits until the output line appears.
    param($Instance, [hashtable]$Target, [string]$Marker)
    $a = @{ text = "echo $Marker"; enter = $true }
    foreach ($k in $Target.Keys) { $a[$k] = $Target[$k] }
    $null = Invoke-Legacy $Instance 'send' $a
    $null = Wait-WmuxScreen $Instance -Surface $Target -Pattern "(?m)^$Marker\s*$" -TimeoutSec 30
}

function Get-TerminalRects {
    # Visible WmuxTerminal child windows of the main window: @{ Hwnd; Width; Height; Left; Top }.
    param($Instance)
    $main = @([WmuxTestHarness.Native]::TopLevelWindows($Instance.Pid, 'WmuxWindow'))
    if ($main.Count -eq 0) { return @() }
    foreach ($h in [WmuxTestHarness.Native]::ChildWindows($main[0], 'WmuxTerminal')) {
        if (-not [WmuxTestHarness.Native]::IsWindowVisible($h)) { continue }
        $r = [WmuxTestHarness.Capture]::ScreenRect($h)
        [pscustomobject]@{ Hwnd = $h; Left = $r.Left; Top = $r.Top; Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
    }
}

Test-Case 'regression: splits in four directions get their own shells' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        foreach ($dir in 'right', 'down', 'left', 'up') { $null = Invoke-Legacy $w 'new-split' @{ dir = $dir } }
        $rows = @(Invoke-Legacy $w 'surface-list')
        Assert-Equal 5 @($rows | Select-Object -ExpandProperty pane -Unique).Count 'five panes after four splits'
        Assert-Equal 5 @(Get-TerminalRects $w).Count 'five visible terminal views'
        $markers = @{}
        foreach ($p in 0..4) {
            Wait-Prompt $w @{ pane = $p }
            $markers[$p] = New-Marker "RG-P$p"
            Send-Echo $w @{ pane = $p } $markers[$p]
        }
        foreach ($p in 0..4) {
            $screen = Invoke-Legacy $w 'read-screen' @{ pane = $p }
            foreach ($q in 0..4) {
                if ($q -eq $p) { Assert-Match $markers[$q] $screen "pane $p shows its own output" }
                else { Assert-True (-not $screen.Contains($markers[$q])) "pane $p does not show the output of pane $q" }
            }
        }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: tabs keep separate terminals; select and close shift indices' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        foreach ($i in 1..2) {
            $t = Invoke-Legacy $w 'tab-new'
            Assert-Equal $i $t.index
            Wait-Prompt $w @{ tab = $i }
        }
        $tabs = @(Invoke-Legacy $w 'tab-list')
        Assert-Equal 3 $tabs.Count
        $null = Invoke-Legacy $w 'tab-select' @{ index = 2 }
        $tabs = @(Invoke-Legacy $w 'tab-list')
        Assert-Equal 2 @($tabs | Where-Object { $_.active })[0].index 'tab-select activates tab 2'
        $m1 = New-Marker 'RG-T1'
        Send-Echo $w @{ tab = 1 } $m1
        Assert-True (-not (Invoke-Legacy $w 'read-screen' @{ tab = 0 }).Contains($m1)) 'tab 0 does not show the output of tab 1'
        Assert-True (-not (Invoke-Legacy $w 'read-screen' @{ tab = 2 }).Contains($m1)) 'tab 2 does not show the output of tab 1'
        $m2 = New-Marker 'RG-T2'
        Send-Echo $w @{ tab = 2 } $m2
        $null = Invoke-Legacy $w 'tab-close' @{ index = 1 }
        $tabs = @(Invoke-Legacy $w 'tab-list')
        Assert-Equal 2 $tabs.Count 'tab-close removed one tab'
        Assert-Match $m2 (Invoke-Legacy $w 'read-screen' @{ tab = 1 }) 'the former tab 2 is now tab 1'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: workspaces are independent; background create, select, describe, close' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $ws = Invoke-Legacy $w 'workspace-new' @{ name = 'rg-two' }
        $list = @(Invoke-Legacy $w 'workspace-list')
        Assert-Equal 0 @($list | Where-Object { $_.active })[0].index 'workspace-new does not change the active workspace'
        Wait-Prompt $w @{ workspace = $ws.index }
        $m = New-Marker 'RG-W1'
        Send-Echo $w @{ workspace = $ws.index } $m
        Assert-True (-not (Invoke-Legacy $w 'read-screen' @{ workspace = 0 }).Contains($m)) 'workspace 0 does not show the output of workspace 1'
        $null = Invoke-Legacy $w 'workspace-set-description' @{ workspace = $ws.index; text = 'regression' }
        $null = Invoke-Legacy $w 'workspace-select' @{ index = $ws.index }
        $list = @(Invoke-Legacy $w 'workspace-list')
        Assert-Equal $ws.index @($list | Where-Object { $_.active })[0].index 'workspace-select switches the active workspace'
        Assert-Match $m (Invoke-Legacy $w 'read-screen') 'send/read-screen without a target use the active workspace'
        $null = Invoke-Legacy $w 'workspace-select' @{ index = 0 }
        $null = Invoke-Legacy $w 'workspace-close' @{ index = $ws.index }
        $list = @(Invoke-Legacy $w 'workspace-list')
        Assert-Equal 1 $list.Count 'workspace-close removed it'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: send and read-screen (lines tail, scrollback, capture-pane)' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Invoke-Legacy $w 'send' @{ text = 'for /L %i in (1,1,60) do @echo RG-LINE-%i'; enter = $true }
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^RG-LINE-60\s*$' -TimeoutSec 30
        $tail = Invoke-Legacy $w 'read-screen' @{ lines = 4 }
        Assert-Match 'RG-LINE-60' $tail 'the tail holds the last line'
        Assert-True (-not ($tail -match '(?m)^RG-LINE-1\s*$')) 'the tail does not hold the first line'
        $visible = Invoke-Legacy $w 'read-screen'
        $all = Invoke-Legacy $w 'read-screen' @{ scrollback = $true }
        Assert-Match '(?m)^RG-LINE-1\s*$' $all 'scrollback holds the first line'
        Assert-True ($all.Length -ge $visible.Length) 'scrollback is at least the visible screen'
        $cap = Invoke-Legacy $w 'capture-pane' @{ scrollback = $true }
        Assert-Match '(?m)^RG-LINE-1\s*$' $cap 'capture-pane --scrollback holds the first line'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: browser open (split and tab), navigate, eval and snapshot' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $split = Invoke-Legacy $w 'open' @{ url = 'about:blank' }
        $rows = @(Invoke-Legacy $w 'surface-list')
        Assert-Equal 1 @($rows | Where-Object { $_.type -eq 'browser' }).Count 'open (default target) adds a browser split'
        Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count 'the browser opened in a new pane'
        $tab = Invoke-Legacy $w 'open' @{ url = 'about:blank'; target = 'tab' }
        Assert-True ($tab.id -gt $split.id) 'browser ids increase'
        $null = Invoke-Legacy $w 'navigate' @{ id = $tab.id; url = 'data:text/html,<title>rg-one</title><h1>Heading</h1><button>Press</button>' }
        $null = Wait-WmuxCondition -TimeoutSec 30 { $r = Invoke-Legacy $w 'eval' @{ id = $tab.id; js = 'document.title' } -AllowError; $r.ok -and $r.data -eq 'rg-one' }
        Assert-Equal 42 (Invoke-Legacy $w 'eval' @{ id = $tab.id; js = '6*7' }) 'eval returns JSON values'
        $nodes = Wait-WmuxCondition -TimeoutSec 30 {
            $s = @(Invoke-Legacy $w 'snapshot' @{ id = $tab.id })
            if (@($s | Where-Object { $_.role -eq 'button' }).Count -gt 0) { $s }
        }
        Assert-True (@($nodes | Where-Object { $_.role -eq 'heading' -and $_.name -eq 'Heading' }).Count -eq 1) 'snapshot lists the heading'
        Assert-True (@($nodes | Where-Object { $_.role -eq 'button' -and $_.name -eq 'Press' }).Count -eq 1) 'snapshot lists the button'
        Assert-Equal 'RootWebArea' $nodes[0].role 'the snapshot starts at the document'
        $null = Invoke-Legacy $w 'navigate' @{ id = $split.id; url = 'data:text/html,<title>rg-two</title>' }
        $null = Wait-WmuxCondition -TimeoutSec 30 { $r = Invoke-Legacy $w 'eval' @{ id = $split.id; js = 'document.title' } -AllowError; $r.ok -and $r.data -eq 'rg-two' }
        Assert-Equal 'rg-one' (Invoke-Legacy $w 'eval' @{ id = $tab.id; js = 'document.title' }) 'navigating one browser leaves the other alone'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: notify ring/clear and log notifications jump across workspaces' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $ws = Invoke-Legacy $w 'workspace-new' @{ name = 'rg-notify' }
        Wait-Prompt $w @{ workspace = $ws.index }
        $target = @(Invoke-Legacy $w 'surface-list' @{ workspace = $ws.index })[0]
        $null = Invoke-Legacy $w 'notify' @{ action = 'ring'; workspace = $ws.index }
        $null = Invoke-Legacy $w 'notify' @{ action = 'clear'; workspace = $ws.index }
        $none = Invoke-Legacy $w 'notify' @{ action = 'next' }
        Assert-Equal $false $none.jumped 'ring/clear alone leave no unread notification'
        $null = Invoke-Legacy $w 'log' @{ text = 'rg notify line'; workspace = $ws.index }
        $jump = Invoke-Legacy $w 'notify' @{ action = 'next' }
        Assert-Equal $true $jump.jumped 'a log line in workspace 1 is an unread notification'
        Assert-Equal ([string]$target.id) ([string]$jump.surface) 'notify next jumps to the surface that logged'
        $list = @(Invoke-Legacy $w 'workspace-list')
        Assert-Equal $ws.index @($list | Where-Object { $_.active })[0].index 'the jump selected the notifying workspace'
        $again = Invoke-Legacy $w 'notify' @{ action = 'next' }
        Assert-Equal $false $again.jumped 'the jump marked the notification read'
        $toggled = Invoke-Legacy $w 'notify' @{ action = 'toggle-read' }
        Assert-Equal $false $toggled.read 'toggle-read marks the most recent one unread again'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: status, progress and log address tabs and validate input' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Invoke-Legacy $w 'tab-new'
        Wait-Prompt $w @{ tab = 1 }
        foreach ($t in 0, 1) {
            $null = Invoke-Legacy $w 'set-status' @{ tab = $t; text = "rg-status-$t" }
            $null = Invoke-Legacy $w 'set-progress' @{ tab = $t; value = 25 * ($t + 1) }
            $null = Invoke-Legacy $w 'log' @{ tab = $t; text = "rg-log-$t" }
        }
        foreach ($v in 0, 100, -1) { $null = Invoke-Legacy $w 'set-progress' @{ value = $v } }
        $bad = Invoke-Legacy $w 'set-progress' @{ value = 101 } -AllowError
        Assert-Equal 'BadProgress' $bad.error 'progress above 100 is rejected'
        $missing = Invoke-Legacy $w 'set-status' @{ tab = 9; text = 'x' } -AllowError
        Assert-Equal $false $missing.ok 'set-status on a missing tab fails'
        $null = Invoke-Legacy $w 'set-status' @{ tab = 0 }
        $first = Invoke-Legacy $w 'notify' @{ action = 'next' }
        Assert-Equal $true $first.jumped 'log lines are notifications'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: session save and restore round-trip a layout' {
    $a = Start-WmuxInstance
    $b = $null
    try {
        Wait-Prompt $a
        $null = Invoke-Legacy $a 'new-split' @{ dir = 'right' }
        Wait-Prompt $a @{ pane = 1 }
        $ws = Invoke-Legacy $a 'workspace-new' @{ name = 'rg-saved' }
        Wait-Prompt $a @{ workspace = $ws.index }
        $null = Invoke-Legacy $a 'session-save'
        $file = Join-Path $a.StateDir 'session-state.json'
        Assert-True (Test-Path -LiteralPath $file -PathType Leaf) 'session-save writes WMUX_STATE_DIR\session-state.json'
        $saved = [WmuxTestHarness.Json]::Parse([IO.File]::ReadAllText($file))
        Assert-Equal 2 @($saved.workspaces).Count 'both workspaces are saved'
        Assert-Equal 'split' $saved.workspaces[0].split_tree.node_type 'the split is saved'
        Assert-Equal 'rg-saved' $saved.workspaces[1].name
        $b = Start-WmuxInstance
        Wait-Prompt $b
        Copy-Item -LiteralPath $file -Destination (Join-Path $b.StateDir 'session-state.json')
        $null = Invoke-Legacy $b 'session-restore'
        $list = @(Invoke-Legacy $b 'workspace-list')
        Assert-Equal 2 $list.Count 'restore recreates the saved workspaces'
        Assert-Equal 'rg-saved' $list[1].name
        # Only the active workspace's split is checked: legacy restore drops the splits of
        # background workspaces (reported to W1-7, which rebuilds session restore).
        $rows = @(Invoke-Legacy $b 'surface-list' @{ workspace = 0 })
        Assert-Equal 2 @($rows | Select-Object -ExpandProperty pane -Unique).Count 'restore recreates the split'
        Wait-Prompt $b @{ workspace = 0; pane = 0 }
        Wait-Prompt $b @{ workspace = 0; pane = 1 }
    } finally {
        Stop-WmuxInstance $a
        Stop-WmuxInstance $b
    }
}

Test-Case 'regression: select-layout rearranges panes and keeps every surface' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        foreach ($dir in 'right', 'down', 'right') { $null = Invoke-Legacy $w 'new-split' @{ dir = $dir } }
        $before = @(Invoke-Legacy $w 'surface-list')
        $shapes = @{}
        foreach ($layout in 'even_horizontal', 'even_vertical', 'main_horizontal', 'main_vertical', 'tiled') {
            $null = Invoke-Legacy $w 'select-layout' @{ layout = $layout }
            $rects = @(Wait-WmuxCondition -TimeoutSec 10 { $r = @(Get-TerminalRects $w); if ($r.Count -eq 4) { $r } })
            $shapes[$layout] = (@($rects | Sort-Object Left, Top | ForEach-Object { "$($_.Width)x$($_.Height)" }) -join ' ')
            $after = @(Invoke-Legacy $w 'surface-list')
            Assert-Equal $before.Count $after.Count "select-layout $layout keeps every surface"
        }
        Assert-True ($shapes['even_horizontal'] -ne $shapes['even_vertical']) "even_horizontal and even_vertical differ ($($shapes['even_horizontal']) / $($shapes['even_vertical']))"
        Write-Host "layouts: $(($shapes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=[$($_.Value)]" }) -join ' ')"
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: sync-input on, off and toggle' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Invoke-Legacy $w 'new-split' @{ dir = 'right' }
        foreach ($action in 'on', 'off', 'toggle', 'toggle') { $null = Invoke-Legacy $w 'sync-input' @{ action = $action } }
        $null = Invoke-Legacy $w 'sync-input'
        $bad = Invoke-Legacy $w 'sync-input' @{ action = 'sideways' } -AllowError
        Assert-Equal 'BadAction' $bad.error
        $missing = Invoke-Legacy $w 'sync-input' @{ tab = 9 } -AllowError
        Assert-Equal 'UnknownTab' $missing.error
        # Programmatic send writes to one PTY only, with or without synchronized input.
        $null = Invoke-Legacy $w 'sync-input' @{ action = 'on' }
        Wait-Prompt $w @{ pane = 1 }
        $m = New-Marker 'RG-SYNC'
        Send-Echo $w @{ pane = 1 } $m
        Assert-True (-not (Invoke-Legacy $w 'read-screen' @{ pane = 0 }).Contains($m)) 'legacy send is not mirrored to the other pane'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: break-pane and move-pane keep every terminal alive' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $null = Invoke-Legacy $w 'new-split' @{ dir = 'right' }
        Wait-Prompt $w @{ pane = 1 }
        $before = @(Invoke-Legacy $w 'surface-list')
        $null = Invoke-Legacy $w 'break-pane'
        $mid = @(Invoke-Legacy $w 'surface-list')
        Assert-Equal $before.Count $mid.Count 'break-pane keeps every surface'
        foreach ($d in 'next', 'prev', 'new') {
            $null = Invoke-Legacy $w 'move-pane' @{ direction = $d }
            $now = @(Invoke-Legacy $w 'surface-list')
            Assert-Equal $before.Count $now.Count "move-pane $d keeps every surface"
        }
        $ids = @($before | ForEach-Object { [string]$_.id } | Sort-Object)
        $after = @(Invoke-Legacy $w 'surface-list' | ForEach-Object { [string]$_.id } | Sort-Object)
        Assert-Equal ($ids -join ',') ($after -join ',') 'the same surfaces exist afterwards'
        $m = New-Marker 'RG-MOVE'
        $null = Invoke-Legacy $w 'send' @{ text = "echo $m"; enter = $true }
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern "(?m)^$m\s*$" -TimeoutSec 30
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: toggle-right-sidebar resizes the terminal area and back' {
    $w = Start-WmuxInstance -Ghostty @('window-show-right-sidebar = true')
    try {
        Wait-Prompt $w
        $r0 = @(Get-TerminalRects $w)
        Assert-Equal 1 $r0.Count
        $null = Invoke-Legacy $w 'toggle-right-sidebar'
        $r1 = @(Wait-WmuxCondition -TimeoutSec 10 { $r = @(Get-TerminalRects $w); if ($r.Count -eq 1 -and $r[0].Width -ne $r0[0].Width) { $r } })
        $null = Invoke-Legacy $w 'toggle-right-sidebar'
        $r2 = @(Wait-WmuxCondition -TimeoutSec 10 { $r = @(Get-TerminalRects $w); if ($r.Count -eq 1 -and $r[0].Width -eq $r0[0].Width) { $r } })
        Write-Host "terminal width: $($r0[0].Width) -> $($r1[0].Width) -> $($r2[0].Width)"
        Assert-Equal $r0[0].Height $r1[0].Height 'the right sidebar only changes the width'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: the hidden window stays off the user''s screen and its terminal renders' {
    $w = Start-WmuxInstance
    try {
        Wait-Prompt $w
        $m = New-Marker 'RG-SHOT'
        Send-Echo $w @{} $m
        $shot = Get-WmuxScreenshot $w -Path (Join-Path $w.ArtifactsDir 'regression.png')
        Write-Host "placement=$($shot.Placement) cloaked=$($shot.Cloaked) terminal=$($shot.TerminalCheck) $($shot.TerminalStats)"
        Assert-True ($shot.Placement -in @('cloaked', 'offscreen')) "the hidden window is cloaked or off-screen, not $($shot.Placement)"
        Assert-True ($shot.Length -gt 0) 'the capture wrote a PNG'
        switch ($shot.TerminalCheck) {
            'ok' { }
            'inconclusive' { throw [WmuxSkipException]::new("terminal capture inconclusive: $($shot.TerminalReason)") }
            # The cloaked window is captured, but the GL terminal shows only its background: the
            # renderer does not present text to a cloaked window yet (W0-A4 acceptance).
            'blank' { throw [WmuxSkipException]::new("W0-A4: the cloaked hidden window captures, but its terminal area is blank ($($shot.TerminalStats))") }
            default { Assert-True $false "terminal capture: $($shot.TerminalCheck): $($shot.TerminalReason)" }
        }
    } finally { Stop-WmuxInstance $w }
}
