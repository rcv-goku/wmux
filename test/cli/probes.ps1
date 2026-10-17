#!/usr/bin/env pwsh
# wp: W1-2c
# covers: cli-no-socket-help-probes, cli-help-command-topics, cli-version-command, cli-guide-skill-command, agents-guide-skill-cli, cli-docs-command, cli-welcome-command, cli-global-options
<#
.SYNOPSIS
    cmux no-socket help probe contract for cli\cmux.exe (ADR-4.8, W1-2c).

.DESCRIPTION
    Runs every probe of the cmux CLI contract ("No-Socket Help Probes" and
    "No-Socket Negative Help Probes") against the wmux CLI, once with the cmux
    spelling and once with the wmux spelling (WMUX_ARGV0=wmux, expected text
    rebranded), with no instance running and no socket environment:

    * the environment drops every CMUX_*, WMUX_*, GHOSTTY_* variable and the
      coding-agent markers, then points WMUX_SOCKET_PATH/CMUX_SOCKET_PATH at a
      pipe that does not exist and WMUX_CHANNEL at a fresh channel, so a probe
      that tried to connect would fail with "No live wmux socket found";
    * a probe passes when its exit code matches (0 help/version, 2 usage) and
      its text is present ('+') / absent ('-') / matched ('~', regex) in
      stdout (stderr for a non-zero exit code), and stderr never reports a
      connection attempt ("No live wmux socket found" or the probe pipe name;
      except the payload-forwarding probes, which must reach the socket path
      to prove that `--help`/`--version` after `--` are payload).

    Adaptations (recorded in docs/wmux/cli/system/W1-2c.md): "Unix socket"
    reads "named pipe"; the cmux cloud, account, coderouter and feedback
    families are not claimed on wmux (G2, Appendix E D19) and exit 2 with
    "not supported on wmux"; `help remote` must not list `auth`, and
    `surface --help` must not print the cloud `surface ls` usage.

    Exit codes: 0 all probes passed, 1 a probe failed, 2 the CLI was not found.

.PARAMETER Exe
    The CLI to probe. Default: zig-out\bin\cli\cmux.exe of this repository.

.PARAMETER Name
    cmux, wmux or both (default).

.PARAMETER Json
    Optional path of a JSON report (one record per probe run).

.EXAMPLE
    pwsh test/cli/probes.ps1
    pwsh test/cli/probes.ps1 -Exe zig-out\release\bin\cli\cmux.exe -Name wmux
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [ValidateSet('cmux', 'wmux', 'both')][string]$Name = 'both',
    [ValidateRange(1, 600)][int]$TimeoutSec = 20,
    [string]$Json
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
if (-not $Exe) {
    $Exe = Join-Path $RepoRoot (Join-Path 'zig-out' (Join-Path 'bin' (Join-Path 'cli' 'cmux.exe')))
}
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    Write-Host "probes: CLI not found at '$Exe' (build it with zig build, or pass -Exe)"
    exit 2
}
$Exe = (Resolve-Path -LiteralPath $Exe).ProviderPath

# exit|mode|args|text  (mode: + present, - absent, ~ regex). Args split on spaces.
# Generated from the cmux CLI contract probe lists, then the wmux additions.
$ContractTable = @'
0|+|--help|cmux - control cmux via named pipe
0|+|--help|open <path-or-url>...
0|+|--help|sessions [list] [options]
0|+|--help|session restore [--list] [--session <id>]...
0|+|help|cmux - control cmux via named pipe
0|+|--help|Start & Resume:
0|+|--help|Diagnostics / Advanced:
0|+|help start|Start & Resume:
0|+|help agents|Agents:
0|+|help navigate|Navigate & Arrange:
0|+|help inspect|Inspect:
0|+|help inspect|review list [--repo <path>] [--json]
0|+|help customize|Customize:
0|+|help automation|Automation:
0|+|help browser|Browser:
0|+|help remote|Remote:
0|+|help diagnostics|Diagnostics / Advanced:
0|+|help diagnostics|socket-status [--json]
0|-|help remote|auth <status|login|logout|team>
0|+|--help|socket-status [--json]
0|+|--help|cmux help <start|agents|navigate|inspect|customize|automation|browser|remote|diagnostics>
0|+|help --help|Usage: cmux help [topic]
0|+|help unknown-task-topic|cmux - control cmux via named pipe
0|+|--help|cmux guide | cmux --skill
2|+|cloud --help|not supported on wmux
0|+|guide|# cmux guide
0|+|--skill|# cmux guide
2|+|cloud guide|not supported on wmux
2|+|cloud --skill|not supported on wmux
2|+|vm guide|not supported on wmux
2|+|vm --skill|not supported on wmux
0|+|guide --help|Usage: cmux guide | cmux --skill [--json]
0|+|--skill -h|Usage: cmux guide | cmux --skill [--json]
2|+|cloud guide --help|not supported on wmux
2|+|cloud --skill -h|not supported on wmux
0|+|sessions --help|Usage: cmux sessions list [options]
0|+|ping --help|Usage: cmux ping
0|+|capabilities --help|Usage: cmux capabilities
0|+|events --help|Usage: cmux events [options]
2|+|glaeda --help|not supported on wmux
2|+|auth --help|not supported on wmux
2|+|vm --help|not supported on wmux
2|+|cloud --help|not supported on wmux
2|+|vm new --help|not supported on wmux
2|+|vm ls --help|not supported on wmux
2|+|vm ports --help|not supported on wmux
2|+|vm domains --help|not supported on wmux
2|+|vm run --help|not supported on wmux
2|+|vm run -h|not supported on wmux
2|+|cloud run --help|not supported on wmux
2|+|vm route --help|not supported on wmux
2|+|vm agent --help|not supported on wmux
2|+|vm push --help|not supported on wmux
2|+|vm upload --help|not supported on wmux
2|+|vm pull --help|not supported on wmux
2|+|vm download --help|not supported on wmux
2|+|vm wait --help|not supported on wmux
2|+|vm open --help|not supported on wmux
2|+|vm tree --help|not supported on wmux
2|+|vm workspace --help|not supported on wmux
2|+|vm terminal --help|not supported on wmux
2|+|vm prompt --help|not supported on wmux
2|+|vm base --help|not supported on wmux
0|-|surface --help|Usage: cmux surface ls [<machine>|local] [--refresh] [--json]
0|+|surface --help|cmux surface resume set [flags] -- <argv...>
0|+|surface-resume --help|cmux surface resume show [--json] [flags]
2|+|remotes --help|not supported on wmux
2|+|remote --help|not supported on wmux
2|+|coderouter --help|not supported on wmux
0|+|rpc --help|Usage: cmux rpc <method> [json-params]
0|+|comments --help|Usage: cmux comments <subcommand> [options]
0|+|review --help|Usage: cmux review <subcommand> [options]
0|+|vault --help|Usage: cmux vault <subcommand> [options]
0|+|help --help|Usage: cmux help
0|+|docs --help|Usage: cmux docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies]
0|+|docs|Topics:
0|+|docs settings|Config files:
0|+|docs capture|capture: Screenshot or record a cmux window
0|+|docs dock|dock: Custom right-sidebar terminal controls
0|+|settings --help|Usage: cmux settings [open [target]|path|docs|<target>]
0|+|settings path|Config files:
0|+|settings docs|Config files:
0|+|config --help|Usage: cmux config <doctor|check|validate|path|paths|docs|documentation|reload|get|set|unset|toggle|cycle|preset|sidebar-font-size|surface-tab-bar-font-size>
0|+|config path|Config files:
0|+|config docs|Config files:
0|+|welcome --help|Usage: cmux welcome
0|+|welcome --help|the default shortcuts
0|+|welcome|Shortcuts
0|+|welcome|cmux shortcuts
0|+|shortcuts --help|Usage: cmux shortcuts
0|+|disable-browser --help|Usage: cmux disable-browser [--json]
0|+|enable-browser --help|Usage: cmux enable-browser [--json]
0|+|browser-status --help|Usage: cmux browser-status [--json]
0|+|agent-hibernation --help|Usage: cmux agent-hibernation <on|off> [--json]
0|+|agent-hibernation --help|cmux agent-hibernation <hibernate|wake> <surface> [--workspace <id|ref|index>] [--json]
0|+|restore --help|Usage: cmux restore [--surface <id|ref>] <kind> <checkpoint-id>
0|+|fork --help|Usage: cmux fork [--surface <id|ref>] <kind> <checkpoint-id>
0|+|restore-session --help|Usage: cmux restore-session
0|+|session restore --help|Usage: cmux session restore [--list] [--session <id>]...
0|+|open --help|Usage: cmux open <path-or-url>...
2|+|feedback --help|not supported on wmux
0|+|feed --help|Usage: cmux feed tui [--opentui|--legacy]
0|+|hooks --help|Usage: cmux hooks setup [agent] [--agent <name>] [--yes|-y]
0|+|codex --help|Usage: cmux codex <install-hooks|uninstall-hooks>
0|+|themes --help|Usage: cmux themes
0|+|import --help|Usage: cmux import
0|+|omo --help|Usage: cmux omo [opencode-args...]
0|+|omx --help|Usage: cmux omx [omx-args...]
0|+|omc --help|Usage: cmux omc [omc-args...]
0|+|identify --help|Usage: cmux identify
0|+|list-windows --help|Usage: cmux list-windows
0|+|current-window --help|Usage: cmux current-window
0|+|new-window --help|Usage: cmux new-window
0|+|focus-window --help|Usage: cmux focus-window --window <id|ref|index>
0|+|close-window --help|Usage: cmux close-window --window <id|ref|index> [--force]
0|+|resize-window --help|Usage: cmux resize-window --window <id|ref|index> [--width <points>] [--height <points>]
0|+|move-workspace-to-window --help|Usage: cmux move-workspace-to-window
0|+|move-surface --help|Usage: cmux move-surface
0|+|split-off --help|Usage: cmux split-off
0|+|reorder-surface --help|Usage: cmux reorder-surface
0|+|reorder-workspace --help|Usage: cmux reorder-workspace
0|+|reorder-workspaces --help|Usage: cmux reorder-workspaces
0|+|workspace-action --help|Usage: cmux workspace-action --action <name>
0|+|move-tab-to-new-workspace --help|Usage: cmux move-tab-to-new-workspace
0|+|tab-action --help|Usage: cmux tab-action --action <name>
0|+|rename-tab --help|Usage: cmux rename-tab
0|+|new-workspace --help|Usage: cmux new-workspace
0|+|new-workspace --help|--command <text>
0|+|list-workspaces --help|Usage: cmux list-workspaces
0|+|ssh --help|Usage: cmux ssh <destination>
0|+|ssh --help|--forward-agent
0|+|ssh --help|--transport <ssh|mosh>
0|+|mosh --help|Usage: cmux mosh <destination>
0|+|mosh-tmux --help|Usage: cmux mosh-tmux <destination>
0|+|mosh-tmux --help|--session <name>
0|+|ssh --help|--command <text>
0|+|ssh --help|--no-focus              Open it in the background
0|+|ssh-session-list --help|Usage: cmux ssh-session-list
0|+|ssh-session-attach --help|Usage: cmux ssh-session-attach --session-id <id>
0|+|ssh-session-cleanup --help|Usage: cmux ssh-session-cleanup
0|+|new-split --help|Usage: cmux new-split
0|+|new-split --help|--command <text>
0|+|list-panes --help|Usage: cmux list-panes
0|+|list-pane-surfaces --help|Usage: cmux list-pane-surfaces
0|+|tree --help|Usage: cmux tree
0|+|top --help|Usage: cmux top
0|+|focus-pane --help|Usage: cmux focus-pane
0|+|new-pane --help|Usage: cmux new-pane
0|+|new-pane --help|--command <text>
0|+|new-surface --help|Usage: cmux new-surface
0|+|new-surface --help|--command <text>
0|+|close-surface --help|Usage: cmux close-surface
0|+|drag-surface-to-split --help|Usage: cmux drag-surface-to-split
0|+|refresh-surfaces --help|Usage: cmux refresh-surfaces
0|+|reload-config --help|Usage: cmux reload-config
0|+|surface-health --help|Usage: cmux surface-health
0|+|debug-terminals --help|Usage: cmux debug-terminals
0|+|trigger-flash --help|Usage: cmux trigger-flash
0|+|list-panels --help|Usage: cmux list-panels
0|+|focus-panel --help|Usage: cmux focus-panel
0|+|close-workspace --help|Usage: cmux close-workspace
0|+|select-workspace --help|Usage: cmux select-workspace
0|+|rename-workspace --help|Usage: cmux rename-workspace
0|+|rename-window --help|Usage: cmux rename-workspace
0|+|current-workspace --help|Usage: cmux current-workspace
0|+|capture-pane --help|Usage: cmux capture-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>]
0|+|resize-pane --help|Usage: cmux resize-pane [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [-L|-R|-U|-D] [--amount <n>]
0|+|pipe-pane --help|Usage: cmux pipe-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--command <shell-command> | <shell-command>]
0|+|wait-for --help|Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]
0|+|swap-pane --help|Usage: cmux swap-pane --pane <id|ref|index> --target-pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
0|+|break-pane --help|Usage: cmux break-pane [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
0|+|join-pane --help|Usage: cmux join-pane --target-pane <id|ref|index> [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
0|+|next-window --help|Usage: cmux next-window
0|+|previous-window --help|Usage: cmux previous-window
0|+|last-window --help|Usage: cmux last-window
0|+|last-pane --help|Usage: cmux last-pane
0|+|find-window --help|Usage: cmux find-window
0|+|clear-history --help|Usage: cmux clear-history
0|+|set-hook --help|Usage: cmux set-hook
0|+|popup --help|Usage: cmux popup
0|+|bind-key --help|Usage: cmux bind-key
0|+|unbind-key --help|Usage: cmux unbind-key
0|+|copy-mode --help|Usage: cmux copy-mode
0|+|set-buffer --help|Usage: cmux set-buffer
0|+|paste-buffer --help|Usage: cmux paste-buffer
0|+|list-buffers --help|Usage: cmux list-buffers
0|+|respawn-pane --help|Usage: cmux respawn-pane
0|+|display-message --help|Usage: cmux display-message
0|+|read-screen --help|Usage: cmux read-screen
0|+|record --help|Usage: cmux record [start] [flags]
0|+|shot --help|Usage: cmux shot [flags]
0|+|send --help|Usage: cmux send
0|+|send-key --help|Usage: cmux send-key
0|+|agent message --help|Usage: cmux agent message
0|+|agent inbox --help|Usage: cmux agent inbox
0|+|agent messages --help|Usage: cmux agent messages
0|+|paste --help|Usage: cmux paste
0|+|send-panel --help|Usage: cmux send-panel
0|+|send-key-panel --help|Usage: cmux send-key-panel
0|+|notify --help|Usage: cmux notify
0|+|list-notifications --help|Usage: cmux list-notifications
0|+|dismiss-notification --help|Usage: cmux dismiss-notification
0|+|mark-notification-read --help|Usage: cmux mark-notification-read
0|+|open-notification --help|Usage: cmux open-notification
0|+|jump-to-unread --help|Usage: cmux jump-to-unread
0|+|jump-to-last-prompt --help|Usage: cmux jump-to-last-prompt
0|+|clear-notifications --help|Usage: cmux clear-notifications
0|+|right-sidebar --help|Usage: cmux right-sidebar <command> [flags]
0|+|set-status --help|Usage: cmux set-status
0|+|clear-status --help|Usage: cmux clear-status
0|+|list-status --help|Usage: cmux list-status
0|+|set-progress --help|Usage: cmux set-progress
0|+|clear-progress --help|Usage: cmux clear-progress
0|+|log --help|Usage: cmux log
0|+|clear-log --help|Usage: cmux clear-log
0|+|list-log --help|Usage: cmux list-log
0|+|sidebar-state --help|Usage: cmux sidebar-state
0|+|set-app-focus --help|Usage: cmux set-app-focus
0|+|simulate-app-active --help|Usage: cmux simulate-app-active
0|+|claude-hook --help|Usage: cmux claude-hook
0|+|browser --help|Usage: cmux browser
0|+|help browser|browser react-grab toggle [--surface <id>] [--return-to <terminal-surface>]
0|+|help browser|browser devtools toggle|console [--surface <id>]
0|+|help browser|browser focus-mode enter|exit|toggle [--surface <id>]
0|+|help browser|browser design-mode enable|disable|toggle|status [--surface <id>]
0|+|help browser|browser zoom in|out|reset|<factor> [--surface <id>]
0|+|help browser|browser history clear --force
0|+|help browser|browser console <list|clear>
0|+|help browser|browser errors <list|clear>
0|+|browser --help|screenshot [--out <path>] [--json]
0|+|browser --help|download list [--limit <1...25>] [--json]
0|+|open-browser --help|Legacy alias for 'cmux browser open'
0|+|navigate --help|Legacy alias for 'cmux browser navigate'
0|+|browser-back --help|Legacy alias for 'cmux browser back'
0|+|browser-forward --help|Legacy alias for 'cmux browser forward'
0|+|browser-reload --help|Legacy alias for 'cmux browser reload'
0|+|get-url --help|Legacy alias for 'cmux browser get-url'
0|+|focus-webview --help|Legacy alias for 'cmux browser focus-webview'
0|+|is-webview-focused --help|Legacy alias for 'cmux browser is-webview-focused'
0|+|markdown --help|Usage: cmux markdown open <path>
2|-|vm exec demo -- --help|Usage: cmux vm
'@

$WmuxTable = @'
0|~|version|^cmux \S+
0|~|--version|^cmux \S+
0|~|-v|^cmux \S+
0|+|guide --json|"format": "markdown"
0|+|--skill --json|"content": "# cmux guide
0|+|help bogus|Start & Resume:
0|+|help start agents|Diagnostics / Advanced:
0|+|docs settings --json|"config_files"
0|+|--json list-workspaces --help|Usage: cmux list-workspaces
0|+|list-workspaces --id-format both --help|Usage: cmux list-workspaces
0|+|socket-status|Socket control mode:
2|+|guide extra|Usage: cmux guide | cmux --skill [--json]
2|+|welcome extra|Usage: cmux welcome
2|+|docs bogus|Usage: cmux docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies]
2|+|--id-format bogus list-workspaces|--id-format must be one of: refs, uuids, both
2|+|list-workspaces --id-format|--id-format must be one of: refs, uuids, both
2|+|list-workspaces --socket /x|unknown option '--socket'
2|+|--socket|--socket requires a value
2|+|--frobnicate ping|unknown global option '--frobnicate'
2|+|open --focus=maybe README.md|--focus must be true|false
1|+|send -- --help|cannot connect to \\.\pipe\wmux-probe-
1|-|send -- --help|Usage:
1|+|send -- --version|cannot connect to \\.\pipe\wmux-probe-
'@

function Get-ProbeEnvironment {
    param([Parameter(Mandatory)][string]$Brand)
    $drop = '^(CMUX_|WMUX_|CMUXTERM_|GHOSTTY_|CLAUDECODE$|CLAUDE_CODE|CODEX_|OPENCODE|AI_AGENT$)'
    $map = [ordered]@{}
    foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $k = [string]$e.Key
        if ($k -notmatch $drop) { $map[$k] = [string]$e.Value }
    }
    $id = [guid]::NewGuid().ToString('N')
    $absent = "\\.\pipe\wmux-probe-$id-absent"
    $map['WMUX_CHANNEL'] = "probe-$($id.Substring(0, 8))"
    $map['WMUX_SOCKET_PATH'] = $absent
    $map['CMUX_SOCKET_PATH'] = $absent
    $map['NO_COLOR'] = '1'
    if ($Brand -eq 'wmux') { $map['WMUX_ARGV0'] = 'wmux' }
    return $map
}

function Invoke-Probe {
    param([string[]]$Arguments, [System.Collections.IDictionary]$Environment)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.WorkingDirectory = $RepoRoot
    $psi.Environment.Clear()
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = $Environment[$k] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Close()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = -1; Stdout = ''; Stderr = "timed out after ${TimeoutSec}s" }
        }
        $proc.WaitForExit()
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $outTask.Result; Stderr = $errTask.Result }
    } finally {
        $proc.Dispose()
    }
}

function ConvertTo-Probe {
    param([string]$Line)
    $parts = $Line.Split('|', 4)
    if ($parts.Count -ne 4) { throw "bad probe line: $Line" }
    return [pscustomobject]@{
        Exit = [int]$parts[0]
        Mode = $parts[1]
        Args = @($parts[2].Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
        Text = $parts[3]
    }
}

function Test-Probe {
    # Returns $null on success, else the failure reason.
    param($Probe, [string]$Brand, $Result)
    $text = if ($Brand -eq 'wmux') { $Probe.Text.Replace('cmux', 'wmux') } else { $Probe.Text }
    if ($Result.ExitCode -ne $Probe.Exit) { return "exit $($Result.ExitCode), expected $($Probe.Exit)" }
    $connects = $Result.Stderr.Contains('No live wmux socket found') -or $Result.Stderr.Contains('\\.\pipe\wmux-probe-')
    if ($connects -and $Probe.Exit -ne 1) { return 'tried to connect to a socket' }
    $stream = if ($Probe.Exit -eq 0) { $Result.Stdout } else { $Result.Stderr }
    switch ($Probe.Mode) {
        '+' { if (-not $stream.Contains($text)) { return "missing '$text'" } }
        '-' { if ($Result.Stdout.Contains($text) -or $Result.Stderr.Contains($text)) { return "unexpected '$text'" } }
        '~' { if ($stream -notmatch $text) { return "no match for /$text/" } }
        default { return "bad mode '$($Probe.Mode)'" }
    }
    return $null
}

$probes = @(
    foreach ($line in (($ContractTable + "`n" + $WmuxTable) -split "`r?`n")) {
        if ($line.Trim().Length -gt 0) { ConvertTo-Probe $line }
    }
)
$brands = if ($Name -eq 'both') { @('cmux', 'wmux') } else { @($Name) }
$records = [System.Collections.Generic.List[object]]::new()
$failed = 0
foreach ($brand in $brands) {
    $envMap = Get-ProbeEnvironment -Brand $brand
    foreach ($p in $probes) {
        $r = Invoke-Probe -Arguments $p.Args -Environment $envMap
        $why = Test-Probe -Probe $p -Brand $brand -Result $r
        $records.Add([ordered]@{
                brand  = $brand
                args   = $p.Args
                exit   = $r.ExitCode
                expect = $p.Exit
                mode   = $p.Mode
                text   = $p.Text
                ok     = ($null -eq $why)
                reason = $why
            })
        if ($null -ne $why) {
            $failed++
            Write-Host ("FAIL {0} {1}: {2}" -f $brand, ($p.Args -join ' '), $why)
            $tail = (($r.Stdout + $r.Stderr) -split "`r?`n" | Select-Object -First 4) -join ' / '
            Write-Host "     output: $tail"
        }
    }
}
if ($Json) {
    $records | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Json -Encoding utf8NoBOM
}
$total = $records.Count
Write-Host ("probes: {0} run, {1} passed, {2} failed ({3}; {4})" -f $total, ($total - $failed), $failed, ($brands -join '+'), $Exe)
if ($failed -gt 0) { exit 1 }
exit 0
