# wp: W0-B
# covers:
# Smoke suite (ARCHITECTURE.md Appendix D.5). Until W1-1a lands the v2 server it speaks the
# legacy wmux JSON protocol through Invoke-WmuxRawLine: workspace-list, workspace-new/close,
# tab-new, send and read-screen polling for an echoed marker, plus the CLI path. No matrix ids
# are claimed yet; W1/W2 upgrade the suite to system.ping, system.capabilities, system.tree,
# events.stream and cli\cmux.exe ping and add their "# covers:" ids. The legacy lines keep
# working after W1-1a because the v2 server sniffs legacy JSON on every pipe.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

function Invoke-LegacyCommand {
    # One legacy request {"id","cmd","args"}; returns data, fails the test on ok:false.
    param(
        [Parameter(Mandatory, Position = 0)]$Instance,
        [Parameter(Mandatory, Position = 1)][string]$Cmd,
        [Parameter(Position = 2)][hashtable]$Arguments,
        [int]$Id = 1
    )
    $request = [ordered]@{ id = $Id; cmd = $Cmd }
    if ($Arguments) { $request.args = $Arguments }
    $line = ConvertTo-Json -InputObject $request -Compress -Depth 10
    $reply = Invoke-WmuxRawLine $Instance $line | ConvertFrom-Json
    Assert-Equal $Id $reply.id "reply id for $Cmd"
    Assert-True $reply.ok "legacy '$Cmd' failed: $($reply.error)"
    # No unary comma: callers wrap list replies in @(), which would otherwise nest the list
    # one level deeper ([[...]]) and break Count, indexing and Assert-JsonShape.
    return $reply.data
}

# Golden shape from test/e2e/fixtures (resolved by Assert-JsonShape).
$workspaceShape = 'shapes/legacy-workspace-list.json'

Test-Case 'legacy: workspace-list reports exactly one active initial workspace' {
    $w = Start-WmuxInstance
    try {
        $list = @(Invoke-LegacyCommand $w 'workspace-list')
        Assert-JsonShape $list $workspaceShape
        Assert-True ($list.Count -ge 1) 'at least one workspace exists at startup'
        Assert-Equal 0 $list[0].index
        Assert-Equal 1 @($list | Where-Object { $_.active }).Count 'exactly one active workspace'
        Assert-True ($list[0].tab_count -ge 1) 'the initial workspace has a tab'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy: workspace-new adds a background workspace and workspace-close removes it' {
    $w = Start-WmuxInstance
    try {
        $before = @(Invoke-LegacyCommand $w 'workspace-list')
        $activeBefore = @($before | Where-Object { $_.active })[0].index
        $created = Invoke-LegacyCommand $w 'workspace-new' @{ name = 'e2e-smoke' } -Id 2
        Assert-Equal $before.Count $created.index 'the new workspace is appended'
        $after = @(Invoke-LegacyCommand $w 'workspace-list' -Id 3)
        Assert-JsonShape $after $workspaceShape
        Assert-Equal ($before.Count + 1) $after.Count
        Assert-Equal 'e2e-smoke' $after[$created.index].name
        Assert-Equal $activeBefore @($after | Where-Object { $_.active })[0].index 'creating a workspace does not change the active one'
        $null = Invoke-LegacyCommand $w 'workspace-close' @{ index = $created.index } -Id 4
        $final = @(Invoke-LegacyCommand $w 'workspace-list' -Id 5)
        Assert-Equal $before.Count $final.Count 'workspace-close removed it again'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy: tab-new, send and read-screen round-trip an echoed marker' {
    $w = Start-WmuxInstance
    try {
        $tabsBefore = @(Invoke-LegacyCommand $w 'tab-list')
        $tab = Invoke-LegacyCommand $w 'tab-new' -Id 2
        $tabsAfter = @(Invoke-LegacyCommand $w 'tab-list' -Id 3)
        Assert-Equal ($tabsBefore.Count + 1) $tabsAfter.Count 'tab-new adds one tab'
        $surface = @{ tab = $tab.index }
        # The generated ghostty.conf runs "cmd.exe /d /k prompt WMUX$G": wait for that prompt.
        $null = Wait-WmuxScreen $w -Surface $surface -Pattern '(?m)^WMUX>' -TimeoutSec 30
        $marker = 'WMUX-E2E-' + [guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
        $null = Invoke-LegacyCommand $w 'send' @{ text = "echo $marker"; enter = $true; tab = $tab.index } -Id 4
        $screen = Wait-WmuxScreen $w -Surface $surface -Pattern "(?m)^$marker\s*$" -TimeoutSec 30
        Assert-Match "WMUX>echo $marker" $screen 'the typed command is echoed after the prompt'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy: an unknown command is answered with an error and the pipe keeps serving' {
    $w = Start-WmuxInstance
    try {
        $reply = Invoke-WmuxRawLine $w '{"id":7,"cmd":"frobnicate"}' | ConvertFrom-Json
        Assert-Equal 7 $reply.id
        Assert-Equal $false $reply.ok
        Assert-Equal 'unknown command' $reply.error
        $list = @(Invoke-LegacyCommand $w 'workspace-list' -Id 8)
        Assert-True ($list.Count -ge 1) 'the next request on a new connection still works'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'harness: the whole instance tree is watched and stays hidden' {
    # Spike S2 (W0-B2): the focus sampler and the visibility guard cover wmux, conhost and the
    # shell, not just the wmux pid; hidden windows are cloaked (S2, W0-A4) or off-screen (W0-A1).
    $w = Start-WmuxInstance
    try {
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^WMUX>' -TimeoutSec 30
        $null = Wait-WmuxCondition -TimeoutSec 10 {
            [WmuxTestHarness.FocusSampler]::RefreshTrees()
            $names = @([WmuxTestHarness.FocusSampler]::TreeOf($w.Pid) | ForEach-Object { $_.Name.ToLowerInvariant() })
            ($names -contains 'conhost.exe') -and ($names -contains 'cmd.exe')
        }
        $placement = Wait-WmuxCondition -TimeoutSec 10 { $p = [WmuxTestHarness.FocusSampler]::PlacementOf($w.Pid); if ($p -ne 'none') { $p } }
        Write-Host "hidden mode: $placement"
        Assert-Match '^(cloaked|offscreen|cloaked-offscreen)(\+(cloaked|offscreen|cloaked-offscreen))*$' $placement 'every visible window of the instance is cloaked or off-screen'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'cli: the CLI reaches the test instance and nothing else' {
    $w = Start-WmuxInstance
    try {
        if ($w.Protocol -eq 'v2' -and (Test-Path -LiteralPath $w.CliExe -PathType Leaf)) {
            # W1-2 and later: the Appendix D.5 smoke contract is "cli\cmux.exe ping". It needs
            # the v2 server (W1-1a); the W0-K skeleton cli\cmux.exe only implements --version.
            $r = Invoke-WmuxCli $w @('ping')
            Assert-Equal 0 $r.ExitCode "cmux ping failed: $($r.Stderr)"
        } else {
            # Legacy instance (before W1-1a): the legacy +workspace verb of wmux.exe, aimed with
            # GHOSTTY_PID (Invoke-WmuxCli relays legacy +verbs of a legacy instance to wmux.exe).
            $r = Invoke-WmuxCli $w @('+workspace', 'list')
            Assert-Equal 0 $r.ExitCode "wmux +workspace list failed: $($r.Stderr)"
            $list = @($r.Stdout | ConvertFrom-Json)
            Assert-JsonShape $list $workspaceShape
            Assert-True ($list.Count -ge 1) 'the CLI listed the workspaces of the test instance'
        }
    } finally { Stop-WmuxInstance $w }
}
