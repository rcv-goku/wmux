# wp: W0-B2
# Legacy +verb goldens (AF-11, AF-19). Every legacy wmux +verb (and its --help) runs through
# wmux.exe and through the installed CLI cli\wmux.com against an isolated hidden instance; the
# masked stdout, stderr and exit code are compared with test/e2e/fixtures/plus-verbs/goldens.json,
# which was captured with the wmux.exe CLI of master aa1f532 (see the fixture README). Each verb
# is reported by its own Test-Case per invoker. wmux.exe must match the goldens exactly (stdout,
# stderr, exit code). cli\wmux.com rewrites +verbs to cmux commands (W1-2a legacy_plus); until
# W1-2b makes that output byte-identical (AF-11) a divergence is reported as a skip that names
# W1-2b, never as a pass. A build without cli\wmux.com reports "skipped: legacy CLI not present".
# Every CLI process tree is watched by the focus sampler and the visibility guard.
#
# Capture mode (maintainers only): WMUX_E2E_PLUSVERBS_CAPTURE=<reference wmux.exe> runs the same
# sequences with that executable as the CLI and writes goldens.json instead of comparing.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:Mod = Get-Module WmuxTest
$script:GoldenPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\fixtures\plus-verbs\goldens.json'))
$script:CaptureExe = $env:WMUX_E2E_PLUSVERBS_CAPTURE
$script:Results = @{}
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:RawId = 5000

# The legacy wmux +verbs (src/cli, the wmux additions to Ghostty's +actions).
$script:LegacyVerbs = @(
    'browser', 'workspace', 'tab', 'send', 'notify', 'surface', 'split', 'status', 'log',
    'read-screen', 'capture-pane', 'session', 'hooks', 'ssh', 'new-window', 'toggle-quick-terminal'
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-PvLegacy {
    # One legacy JSON command over the instance pipe; returns data, throws on ok:false.
    param($Ctx, [string]$Cmd, [hashtable]$Arguments)
    $script:RawId++
    $req = [ordered]@{ id = $script:RawId; cmd = $Cmd }
    if ($Arguments) { $req.args = $Arguments }
    $reply = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $Ctx.Instance (ConvertTo-Json -InputObject $req -Compress -Depth 10) -TimeoutSec 20))
    if (-not $reply.ok) { throw "legacy $Cmd failed: $($reply.error)" }
    return , $reply.data
}

function Wait-PvPrompt {
    # The generated ghostty.conf runs "cmd.exe /d /k prompt WMUX$G".
    param($Ctx, [hashtable]$Surface = @{})
    $null = Wait-WmuxScreen $Ctx.Instance -Surface $Surface -Pattern '(?m)^WMUX>' -TimeoutSec 30
}

function Wait-PvTitles {
    # Until every terminal of the workspace shows its shell title (a new tab is "Ghostty" until
    # cmd.exe sets its title), so list outputs are deterministic.
    param($Ctx, [int]$Workspace = -1)
    $a = if ($Workspace -ge 0) { @{ workspace = $Workspace } } else { $null }
    $null = Wait-WmuxCondition -TimeoutSec 30 {
        $list = @(Invoke-PvLegacy $Ctx 'surface-list' $a)
        @($list | Where-Object { $_.type -eq 'terminal' -and $_.title -eq 'Ghostty' }).Count -eq 0
    }
}

function ConvertTo-PvMasked {
    # Volatile parts of a CLI output: instance paths, the pipe pid, 64-bit surface ids, the
    # Windows build in cmd's banner and CDP node refs.
    param([AllowNull()][string]$Text, $Ctx)
    if ($null -eq $Text) { return '' }
    $t = $Text.Replace("`r`n", "`n")
    if ($Ctx -and $Ctx.Instance) {
        $root = $Ctx.Instance.Root
        foreach ($form in @($root.Replace('\', '\\'), $root, $root.Replace('\', '/'))) {
            $t = [regex]::Replace($t, [regex]::Escape($form), '<ROOT>', 'IgnoreCase')
        }
    }
    $t = $t -replace 'wmux-ipc-\d+', 'wmux-ipc-<PID>'
    $t = $t -replace '\b\d{7,}\b', '<ID>'
    $t = $t -replace '\[Version [0-9.]+\]', '[Version <V>]'
    $t = $t -replace '"ref":\d+', '"ref":<REF>'
    return $t
}

function Get-PvCliEnvironment {
    param($Ctx)
    return (& $script:Mod { param($i) Get-WmuxCliEnvironment -Instance $i } $Ctx.Instance)
}

function Invoke-PvProcess {
    # Runs one CLI process with the instance's CLI environment (GHOSTTY_PID and
    # WMUX_SOCKET_PATH aimed at the test instance). Its process tree is watched by the focus
    # sampler and the visibility guard (and killed on a violation) while it runs.
    param($Ctx, [string]$Exe, [string[]]$Argv, [int]$TimeoutSec = 30)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Argv) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $psi.WorkingDirectory = $Ctx.Instance.WorkDir
    $envMap = Get-PvCliEnvironment $Ctx
    $psi.Environment.Clear()
    foreach ($k in $envMap.Keys) { $psi.Environment[$k] = $envMap[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    [WmuxTestHarness.FocusSampler]::WatchTree($p.Id, $true, $true)
    try {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        try { $p.StandardInput.Close() } catch { }
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = -999; Stdout = ''; Stderr = "timed out after ${TimeoutSec}s" }
        }
        $p.WaitForExit()
        $null = $out.Wait(5000)
        $null = $err.Wait(5000)
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
    } finally {
        [WmuxTestHarness.FocusSampler]::Unwatch($p.Id)
        $p.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Sequences. Each group runs on a fresh instance, steps in order; Before/After settle the
# instance through the legacy pipe so every output is deterministic. Argv may be a scriptblock
# (param $Ctx) for values found at run time (browser refs).
# ---------------------------------------------------------------------------

$script:Groups = @(
    [ordered]@{
        Name  = 'help'
        Steps = @(foreach ($v in $script:LegacyVerbs) { @{ Name = "$v --help"; Argv = @("+$v", '--help') } })
    },
    [ordered]@{
        Name  = 'core'
        Setup = { param($c) Wait-PvPrompt $c; Wait-PvTitles $c }
        Steps = @(
            @{ Name = 'workspace list'; Argv = @('+workspace', 'list') },
            @{ Name = 'workspace new'; Argv = @('+workspace', 'new', '--name', 'pv-two'); After = { param($c) Wait-PvPrompt $c @{ workspace = 1 }; Wait-PvTitles $c 1 } },
            @{ Name = 'workspace list (two)'; Argv = @('+workspace', 'list') },
            @{ Name = 'workspace select'; Argv = @('+workspace', 'select', '1') },
            @{ Name = 'workspace select back'; Argv = @('+workspace', 'select', '0') },
            @{ Name = 'workspace select unknown'; Argv = @('+workspace', 'select', '99') },
            @{ Name = 'workspace (no subcommand)'; Argv = @('+workspace') },
            @{ Name = 'tab list'; Argv = @('+tab', 'list') },
            @{ Name = 'tab new'; Argv = @('+tab', 'new'); After = { param($c) Wait-PvPrompt $c @{ tab = 1 }; Wait-PvTitles $c } },
            @{ Name = 'tab list (two)'; Argv = @('+tab', 'list') },
            @{ Name = 'tab select'; Argv = @('+tab', 'select', '0') },
            @{ Name = 'tab (unknown subcommand)'; Argv = @('+tab', 'frob') },
            @{ Name = 'send'; Argv = @('+send', 'echo PV-MARK-1', '--enter'); After = { param($c) $null = Wait-WmuxScreen $c.Instance -Surface @{ tab = 0 } -Pattern '(?m)^PV-MARK-1\s*\n(\s*\n)*WMUX>\s*$' -TimeoutSec 30 } },
            @{ Name = 'read-screen'; Argv = @('+read-screen', '--lines', '3') },
            @{ Name = 'capture-pane'; Argv = @('+capture-pane') },
            @{ Name = 'capture-pane --file'; Argv = { param($c) @('+capture-pane', '--file', (Join-Path $c.Instance.WorkDir 'pv-capture.txt')) } },
            @{ Name = 'split'; Argv = @('+split', 'right'); After = { param($c) Wait-PvTitles $c } },
            @{ Name = 'surface list'; Argv = @('+surface', 'list') },
            @{ Name = 'surface focus'; Argv = @('+surface', 'focus', '--pane', '0', '--tab', '0') },
            @{ Name = 'status set'; Argv = @('+status', 'set', 'pv-busy') },
            @{ Name = 'status progress'; Argv = @('+status', 'progress', '40') },
            @{ Name = 'status progress clear'; Argv = @('+status', 'progress', 'clear') },
            @{ Name = 'status progress out of range'; Argv = @('+status', 'progress', '400') },
            @{ Name = 'log'; Argv = @('+log', 'hello from plus-verbs') },
            @{ Name = 'notify ring'; Argv = @('+notify', 'ring', '--workspace', '1') },
            @{ Name = 'notify clear'; Argv = @('+notify', 'clear', '--workspace', '1') },
            @{ Name = 'notify next'; Argv = @('+notify', 'next') },
            @{ Name = 'notify toggle-read'; Argv = @('+notify', 'toggle-read') },
            @{ Name = 'notify mark-oldest-next'; Argv = @('+notify', 'mark-oldest-next') },
            @{ Name = 'session capture'; Argv = @('+session', 'capture', '--kind', 'pv-agent', '--id', 'pv-session-1') },
            @{ Name = 'session show'; Argv = @('+session', 'show') },
            @{ Name = 'session resume (no recipe)'; Argv = @('+session', 'resume') },
            @{ Name = 'tab close'; Argv = @('+tab', 'close', '1', '--pane', '1') },
            @{ Name = 'workspace close'; Argv = @('+workspace', 'close', '1') },
            @{ Name = 'workspace list (final)'; Argv = @('+workspace', 'list') },
            @{ Name = 'new-window'; Argv = @('+new-window') },
            @{ Name = 'toggle-quick-terminal'; Argv = @('+toggle-quick-terminal') }
        )
    },
    [ordered]@{
        Name  = 'browser'
        Setup = { param($c) Wait-PvPrompt $c; Wait-PvTitles $c }
        Steps = @(
            @{ Name = 'browser open'; Argv = @('+browser', 'open', 'about:blank', '--tab') },
            @{ Name = 'browser navigate'; Argv = @('+browser', 'navigate', 'data:text/html,<title>pv</title><button id=b onclick="document.title=''clicked''">Go</button><input id=i aria-label=field>')
                After = { param($c)
                    $null = Wait-WmuxCondition -TimeoutSec 30 {
                        $script:RawId++
                        $r = [WmuxTestHarness.Json]::Parse((Invoke-WmuxRawLine $c.Instance ('{"id":' + $script:RawId + ',"cmd":"eval","args":{"js":"document.title"}}') -TimeoutSec 20))
                        $r.ok -and $r.data -eq 'pv'
                    }
                    $snap = Wait-WmuxCondition -TimeoutSec 30 {
                        $s = @(Invoke-PvLegacy $c 'snapshot')
                        if (@($s | Where-Object { $_.role -eq 'button' }).Count -gt 0 -and @($s | Where-Object { $_.role -eq 'textbox' }).Count -gt 0) { $s }
                    }
                    $c.Vars.Button = [string](@($snap | Where-Object { $_.role -eq 'button' })[0].ref)
                    $c.Vars.Field = [string](@($snap | Where-Object { $_.role -eq 'textbox' })[0].ref)
                }
            },
            @{ Name = 'browser eval'; Argv = @('+browser', 'eval', 'document.title') },
            @{ Name = 'browser list'; Argv = @('+browser', 'list') },
            @{ Name = 'browser snapshot'; Argv = @('+browser', 'snapshot') },
            @{ Name = 'browser click'; Argv = { param($c) @('+browser', 'click', $c.Vars.Button) } },
            @{ Name = 'browser fill'; Argv = { param($c) @('+browser', 'fill', $c.Vars.Field, 'pv-text') } },
            @{ Name = 'browser eval (after input)'; Argv = @('+browser', 'eval', 'document.title + "|" + document.getElementById("i").value') },
            @{ Name = 'browser (unknown subcommand)'; Argv = @('+browser', 'frob') }
        )
    },
    [ordered]@{
        Name  = 'session'
        Setup = { param($c) Wait-PvPrompt $c; Wait-PvTitles $c }
        Steps = @(
            @{ Name = 'session save'; Argv = @('+session', 'save') },
            @{ Name = 'session restore'; Argv = @('+session', 'restore'); After = { param($c) Wait-PvTitles $c } },
            @{ Name = 'session workspace list'; Argv = @('+workspace', 'list') }
        )
    }
)

function Invoke-PvGroup {
    # Runs one group with the given CLI executable; returns name -> result. -Tolerant (any CLI
    # but wmux.exe): a settle step that fails (because the CLI did not do what the legacy verb
    # did) is recorded and the remaining settle steps of the group are skipped, so every verb
    # still runs and gets a result.
    param([System.Collections.IDictionary]$Group, [string]$Exe, [switch]$Tolerant)
    $results = [ordered]@{}
    $w = Start-WmuxInstance
    try {
        $ctx = [pscustomobject]@{ Instance = $w; Vars = @{}; SettleError = $null }
        $settle = {
            param($Block, $R)
            if (-not $Block -or $ctx.SettleError) { return }
            if (-not $Tolerant) { & $Block $ctx $R; return }
            try { & $Block $ctx $R } catch { $ctx.SettleError = (Get-PvErrorText $_); & $script:Mod { $script:State.FailMark = $false } }
        }
        & $settle $Group.Setup $null
        foreach ($step in $Group.Steps) {
            & $settle $step.Before $null
            $argv = if ($step.Argv -is [scriptblock]) { @(& $step.Argv $ctx) } else { @($step.Argv) }
            $r = Invoke-PvProcess -Ctx $ctx -Exe $Exe -Argv $argv
            $results[$step.Name] = [ordered]@{
                argv      = @($argv | ForEach-Object { ConvertTo-PvMasked $_ $ctx })
                exit_code = $r.ExitCode
                stdout    = ConvertTo-PvMasked $r.Stdout $ctx
                stderr    = ConvertTo-PvMasked $r.Stderr $ctx
            }
            if ($Tolerant) { $results[$step.Name].settle = $ctx.SettleError }
            & $settle $step.After $r
        }
    } finally { Stop-WmuxInstance $w }
    return $results
}

function Get-PvErrorText {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e.InnerException -and ($e -is [System.Management.Automation.MethodInvocationException] -or $e.GetType() -eq [System.Management.Automation.RuntimeException])) { $e = $e.InnerException }
    return ($e.Message -split "`n")[0]
}

function Format-PvDiff {
    param([string]$Expected, [string]$Actual)
    $e = @($Expected -split "`n")
    $a = @($Actual -split "`n")
    $n = [Math]::Max($e.Count, $a.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $e.Count) { $e[$i] } else { '<missing>' }
        $y = if ($i -lt $a.Count) { $a[$i] } else { '<missing>' }
        if ($x -cne $y) { return "line $($i + 1): expected $(ConvertTo-Json $x -Compress), got $(ConvertTo-Json $y -Compress)" }
    }
    return 'outputs differ only in line endings'
}

# ---------------------------------------------------------------------------
# Capture mode
# ---------------------------------------------------------------------------

if ($script:CaptureExe) {
    Test-Case 'plus-verbs: capture goldens with the reference wmux.exe' {
        $exe = (Resolve-Path -LiteralPath $script:CaptureExe).ProviderPath
        $doc = [ordered]@{
            '//'     = 'Legacy +verb goldens for test/e2e/suites/legacy/plus-verbs.e2e.ps1; captured with WMUX_E2E_PLUSVERBS_CAPTURE (see README.md). Masks: <ROOT> <PID> <ID> <V> <REF>.'
            source   = $env:WMUX_E2E_PLUSVERBS_SOURCE
            captured = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
            groups   = [ordered]@{}
        }
        foreach ($g in $script:Groups) { $doc.groups[$g.Name] = Invoke-PvGroup -Group $g -Exe $exe }
        $json = (ConvertTo-Json -InputObject $doc -Depth 10).Replace("`r`n", "`n") + "`n"
        [IO.File]::WriteAllText($script:GoldenPath, $json, $script:Utf8)
        Write-Host "wrote $script:GoldenPath"
    }
    return
}

# ---------------------------------------------------------------------------
# Compare mode
# ---------------------------------------------------------------------------

$script:Goldens = (Get-Content -LiteralPath $script:GoldenPath -Raw | ConvertFrom-Json -AsHashtable)
$script:WmuxExe = $null
try { $script:WmuxExe = & $script:Mod { Resolve-WmuxExe } } catch { }
$script:Invokers = [ordered]@{
    'wmux.exe'      = $script:WmuxExe
    'cli\wmux.com'  = $(if ($script:WmuxExe) { Join-Path (Split-Path -Parent $script:WmuxExe) 'cli\wmux.com' })
}

foreach ($invoker in $script:Invokers.Keys) {
    $script:Results[$invoker] = @{}
    foreach ($g in $script:Groups) {
        $script:CurrentInvoker = $invoker
        $script:CurrentGroup = $g
        Test-Case "plus-verbs [$invoker] run the $($g.Name) sequence" {
            $exe = $script:Invokers[$script:CurrentInvoker]
            if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                throw [WmuxSkipException]::new("skipped: legacy CLI not present ($exe)")
            }
            if ($script:CurrentInvoker -eq 'wmux.exe') {
                $script:Results[$script:CurrentInvoker][$script:CurrentGroup.Name] = Invoke-PvGroup -Group $script:CurrentGroup -Exe $exe
                return
            }
            try {
                $script:Results[$script:CurrentInvoker][$script:CurrentGroup.Name] = Invoke-PvGroup -Group $script:CurrentGroup -Exe $exe -Tolerant
            } catch {
                throw [WmuxSkipException]::new("W1-2b: the $($script:CurrentGroup.Name) sequence did not complete through $($script:CurrentInvoker): $(Get-PvErrorText $_)")
            }
        }
    }
}

foreach ($invoker in $script:Invokers.Keys) {
    foreach ($g in $script:Groups) {
        foreach ($step in $g.Steps) {
            $script:Check = @{ Invoker = $invoker; Group = $g.Name; Step = $step.Name }
            Test-Case "plus-verbs [$invoker] $($g.Name): $($step.Name)" {
                $c = $script:Check
                $exe = $script:Invokers[$c.Invoker]
                if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                    throw [WmuxSkipException]::new("skipped: legacy CLI not present ($exe)")
                }
                $golden = $script:Goldens.groups[$c.Group][$c.Step]
                Assert-True ($null -ne $golden) "no golden for $($c.Group): $($c.Step) in fixtures/plus-verbs/goldens.json"
                $groupResults = $script:Results[$c.Invoker][$c.Group]
                if ($null -eq $groupResults) {
                    if ($c.Invoker -ne 'wmux.exe') { throw [WmuxSkipException]::new("W1-2b: the $($c.Group) sequence did not complete through $($c.Invoker)") }
                    Throw "the $($c.Group) sequence did not complete through $($c.Invoker) (see its run Test-Case)"
                }
                $actual = $groupResults[$c.Step]
                $problems = [System.Collections.Generic.List[string]]::new()
                if ([int]$golden.exit_code -ne [int]$actual.exit_code) { $problems.Add("exit code $($actual.exit_code), golden $($golden.exit_code)") }
                if ($golden.stdout -cne $actual.stdout) { $problems.Add("stdout differs: $(Format-PvDiff $golden.stdout $actual.stdout)") }
                if ($c.Invoker -eq 'wmux.exe' -and $golden.stderr -cne $actual.stderr) { $problems.Add("stderr differs: $(Format-PvDiff $golden.stderr $actual.stderr)") }
                if ($problems.Count -eq 0) { return }
                $text = "$($c.Invoker) $($actual.argv -join ' '): $($problems -join '; ')"
                if ($actual.settle) { $text += " (instance state diverged earlier: $($actual.settle))" }
                if ($c.Invoker -ne 'wmux.exe') {
                    throw [WmuxSkipException]::new("W1-2b: cli\wmux.com does not reproduce the legacy output yet (AF-11): $text")
                }
                Assert-True $false $text
            }
        }
    }
}
