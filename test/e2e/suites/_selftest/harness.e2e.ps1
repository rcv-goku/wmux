# wp: W0-B
# Harness self-test. Exercises WmuxTest.psm1, coverage.ps1 and run.ps1 without launching wmux:
# pure helpers, a fake named-pipe server standing in for the v2/legacy protocols, child test
# processes for Test-Case semantics (focus check, watchdog, skip) and the runner end to end.
# It claims no matrix feature ids.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:Mod = Get-Module WmuxTest
$script:E2eRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:ModulePath = Join-Path $script:E2eRoot 'WmuxTest.psm1'
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('wmux-e2e-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $script:TempRoot
$script:FakeServer = $null

function InModule {
    # Runs a scriptblock inside the module scope (internal helpers are not exported).
    param([scriptblock]$ScriptBlock)
    & $script:Mod $ScriptBlock @args
}

function Assert-AssertionFails {
    param([Parameter(Mandatory, Position = 0)][scriptblock]$Block, [Parameter(Position = 1)][string]$Expect)
    $e = Assert-Throws $Block
    Assert-True ($e -is [WmuxAssertionError]) "expected a WmuxAssertionError, got $($e.GetType().FullName): $($e.Message)"
    if ($Expect) { Assert-True $e.Message.Contains($Expect) "message should contain '$Expect' but was: $($e.Message)" }
}

function Copy-Map {
    param([System.Collections.IDictionary]$Map)
    $copy = [ordered]@{}
    foreach ($k in $Map.Keys) { $copy[$k] = $Map[$k] }
    return $copy
}

function Write-TempFile {
    param([string]$Name, [string]$Content)
    $path = Join-Path $script:TempRoot $Name
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [IO.File]::WriteAllText($path, $Content, $script:Utf8)
    return $path
}

function Start-ChildPwsh {
    # pwsh child with a clean WMUX_E2E_* environment (the outer runner's values must not leak).
    param([string[]]$Arguments, [hashtable]$Env = @{}, [string]$WorkingDirectory = $script:TempRoot)
    $psi = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass') + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($k in @($psi.Environment.Keys)) { if ($k -like 'WMUX_E2E_*') { $null = $psi.Environment.Remove($k) } }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try { $p.StandardInput.Close() } catch { }
    return $p
}

function Invoke-ChildPwsh {
    param([string[]]$Arguments, [hashtable]$Env = @{}, [int]$TimeoutSec = 110)
    $p = Start-ChildPwsh -Arguments $Arguments -Env $Env
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill($true) } catch { }
        throw "child pwsh did not exit within ${TimeoutSec}s: $($Arguments -join ' ')"
    }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
}

function Invoke-ChildTestFile {
    # Runs a generated test file in its own pwsh and returns its Test-Case result records.
    param([string]$Name, [string]$Content, [hashtable]$Env = @{})
    $file = Write-TempFile "$Name.e2e.ps1" $Content.Replace('__MODULE__', $script:ModulePath)
    $results = Join-Path $script:TempRoot "$Name.results.jsonl"
    $environment = @{
        WMUX_E2E_RESULTS   = $results
        WMUX_E2E_ARTIFACTS = Join-Path $script:TempRoot "$Name.artifacts"
        WMUX_E2E_FILE      = "selftest/$Name.e2e.ps1"
    }
    foreach ($k in $Env.Keys) { $environment[$k] = $Env[$k] }
    $r = Invoke-ChildPwsh -Arguments @('-File', $file) -Env $environment
    $records = @()
    if (Test-Path -LiteralPath $results) {
        $records = @(Get-Content -LiteralPath $results | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    [pscustomobject]@{ ExitCode = $r.ExitCode; Stdout = $r.Stdout; Stderr = $r.Stderr; Results = $records }
}

$script:FakeServerScript = @'
param([string]$PipeName, [switch]$LegacyOwnPid)
# Fake wmux control pipe for the harness self-test: one connection at a time, one request per
# connection, canned replies for v2 methods, legacy JSON and text-v1. -LegacyOwnPid listens on
# wmux-ipc-<own pid> like the legacy app does.
$ErrorActionPreference = 'Stop'
if ($LegacyOwnPid) { $PipeName = "wmux-ipc-$PID" }
$utf8 = [Text.UTF8Encoding]::new($false)
$reads = 0
function Send-Json($writer, $value) { $writer.WriteLine((ConvertTo-Json -InputObject $value -Compress -Depth 20)) }
while ($true) {
    $server = [System.IO.Pipes.NamedPipeServerStream]::new($PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::None)
    $stop = $false
    try {
        $server.WaitForConnection()
        $reader = [IO.StreamReader]::new($server, $utf8, $false, 4096, $true)
        $writer = [IO.StreamWriter]::new($server, $utf8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.NewLine = "`n"
        $line = $reader.ReadLine()
        if ($null -eq $line) {
            # connection closed without a request
        } elseif ($line -eq 'quit') {
            $writer.WriteLine('bye')
            $stop = $true
        } elseif ($line -eq 'ping') {
            $writer.WriteLine('PONG')
        } else {
            $req = ConvertFrom-Json -InputObject $line
            if ($null -ne $req.cmd) {
                if ($req.cmd -eq 'stale-pair') {
                    # A late reply to an earlier request, then the reply to this one, in one write.
                    $writer.Write((ConvertTo-Json -InputObject ([ordered]@{ id = $req.args.stale; ok = $true; data = 'late' }) -Compress) + "`n" +
                        (ConvertTo-Json -InputObject ([ordered]@{ id = $req.id; ok = $true; data = 'fresh' }) -Compress) + "`n")
                } else {
                    Send-Json $writer ([ordered]@{ id = $req.id; ok = $true; data = @([ordered]@{ index = 0; name = 'legacy'; active = $true; tab_count = 1 }) })
                }
            } else {
                $id = $req.id
                switch ($req.method) {
                    'stale.pair' {
                        $writer.Write((ConvertTo-Json -InputObject ([ordered]@{ id = $req.params.stale; ok = $true; result = 'late' }) -Compress) + "`n" +
                            (ConvertTo-Json -InputObject ([ordered]@{ id = $id; ok = $true; result = 'fresh' }) -Compress) + "`n")
                    }
                    'system.ping' { Send-Json $writer ([ordered]@{ id = $id; ok = $true; result = [ordered]@{ pong = $true; echo = $req.params } }) }
                    'wmux.debug.ready' { Send-Json $writer ([ordered]@{ id = $id; ok = $true; result = [ordered]@{ ready = $true } }) }
                    'boom' { Send-Json $writer ([ordered]@{ id = $id; ok = $false; error = [ordered]@{ code = 'not_found'; message = 'Workspace not found'; data = [ordered]@{ selector = 'workspace_id' } } }) }
                    'wrong.id' { Send-Json $writer ([ordered]@{ id = 'someone-else'; ok = $true; result = 1 }) }
                    'list.one' { Send-Json $writer ([ordered]@{ id = $id; ok = $true; result = @(7) }) }
                    'surface.read_text' {
                        $reads++
                        $text = if ($reads -ge 3) { "WMUX>echo hi`nhi`nWMUX>" } else { 'WMUX>' }
                        Send-Json $writer ([ordered]@{ id = $id; ok = $true; result = [ordered]@{ text = $text; surface_id = $req.params.surface_id } })
                    }
                    'wmux.debug.dialogs.list' { Send-Json $writer ([ordered]@{ id = $id; ok = $true; result = [ordered]@{ dialogs = @([ordered]@{ title = 'Confirm'; answer = 'ok' }) } }) }
                    'wmux.debug.window.screenshot' { Send-Json $writer ([ordered]@{ id = $id; ok = $true; result = [ordered]@{ png_base64 = 'iVBORw0KGgo=' } }) }
                    'events.stream' {
                        $names = if ($req.params.names) { @($req.params.names) } else { @() }
                        $cats = if ($req.params.categories) { @($req.params.categories) } else { @() }
                        $boot = 'EED6A3D5-CDF0-4823-A383-CE4C9EC42335'
                        Send-Json $writer ([ordered]@{
                                type = 'ack'; protocol = 'cmux-events'; version = 1; boot_id = $boot
                                subscription_id = '460F280C-12C7-428C-A982-EA9D8AA60F45'; heartbeat_interval_seconds = 15; replay_count = 2
                                resume = [ordered]@{ after_seq = $req.params.after_seq; requested_after_seq = $req.params.after_seq; oldest_seq = 1; latest_seq = 2; next_seq = 3; gap = $false }
                                filters = [ordered]@{ names = $names; categories = $cats }
                            })
                        foreach ($n in 1, 2) {
                            $ws = if ($n -eq 1) { '384E46CB-5986-49BE-9696-4BC07AF97C4D' } else { 'C0CD13DB-0141-4529-B8E8-D5DF0A696C28' }
                            Send-Json $writer ([ordered]@{
                                    type = 'event'; protocol = 'cmux-events'; version = 1; boot_id = $boot; seq = $n; id = "$boot-$n"
                                    name = 'workspace.created'; category = 'workspace'; source = 'workspace.lifecycle'
                                    occurred_at = '2026-10-15T09:41:27.250Z'; workspace_id = $ws; surface_id = $null; pane_id = $null; window_id = $null
                                    payload = [ordered]@{ index = $n }
                                })
                            if ($n -eq 1) { Send-Json $writer ([ordered]@{ type = 'heartbeat'; protocol = 'cmux-events'; version = 1; boot_id = $boot; latest_seq = 1 }) }
                        }
                    }
                    default { Send-Json $writer ([ordered]@{ id = $id; ok = $false; error = [ordered]@{ code = 'method_not_found'; message = 'Unknown method' } }) }
                }
            }
        }
        try { $server.WaitForPipeDrain() } catch { }
    } catch {
    } finally {
        $server.Dispose()
    }
    if ($stop) { break }
}
'@

$script:SlowLegacyServerScript = @'
param([int]$StartupDelayMs = 3000, [int]$PerRequestMs = 250, [int]$LifetimeSec = 120)
# Model of the legacy server on master (ipc.zig + App.zig): \\.\pipe\wmux-ipc-<pid> has one
# instance and exists before the UI thread pumps messages; the pipe thread queues each request
# for the UI thread, which answers on whatever connection is open at that moment and drops the
# reply when none is.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class SlowLegacyServer
{
    static readonly object Gate = new object();
    static NamedPipeServerStream Current;
    static readonly BlockingCollection<string> Queue = new BlockingCollection<string>();

    public static void Start(string name, int startupDelayMs, int perRequestMs)
    {
        var ui = new Thread(() => {
            Thread.Sleep(startupDelayMs);
            foreach (string id in Queue.GetConsumingEnumerable())
            {
                Thread.Sleep(perRequestMs);
                byte[] b = Encoding.UTF8.GetBytes("{\"id\":" + id + ",\"ok\":true,\"data\":[{\"index\":0,\"name\":\"w\",\"active\":true,\"tab_count\":1}]}\n");
                lock (Gate)
                {
                    if (Current == null) continue;
                    try { Current.Write(b, 0, b.Length); Current.Flush(); } catch { }
                }
            }
        });
        ui.IsBackground = true;
        ui.Start();
        var pipe = new Thread(() => Serve(name));
        pipe.IsBackground = true;
        pipe.Start();
    }

    static void Serve(string name)
    {
        while (true)
        {
            var s = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            s.WaitForConnection();
            lock (Gate) { Current = s; }
            var acc = new MemoryStream();
            var buf = new byte[4096];
            try
            {
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0)
                {
                    for (int i = 0; i < n; i++)
                    {
                        if (buf[i] != 10) { acc.WriteByte(buf[i]); continue; }
                        Match m = Regex.Match(Encoding.UTF8.GetString(acc.ToArray()), "\"id\"\\s*:\\s*(\\d+)");
                        acc.SetLength(0);
                        Queue.Add(m.Success ? m.Groups[1].Value : "0");
                    }
                }
            }
            catch { }
            lock (Gate) { Current = null; }
            try { s.Disconnect(); } catch { }
            s.Dispose();
        }
    }
}
"@
[SlowLegacyServer]::Start("wmux-ipc-$PID", $StartupDelayMs, $PerRequestMs)
Start-Sleep -Seconds $LifetimeSec
'@

function Start-FakeServerProcess {
    # A fake pipe server in its own pwsh, inside a kill-on-close job so it never outlives us.
    param([string]$PipeName, [switch]$LegacyOwnPid)
    $scriptPath = Join-Path $script:TempRoot 'fake-server.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { $null = Write-TempFile 'fake-server.ps1' $script:FakeServerScript }
    $arguments = @('-File', $scriptPath)
    if ($LegacyOwnPid) { $arguments += '-LegacyOwnPid' } else { $arguments += @('-PipeName', $PipeName) }
    $p = Start-ChildPwsh -Arguments $arguments
    $job = [WmuxTestHarness.JobObject]::Create()
    $null = [WmuxTestHarness.JobObject]::Assign($job, $p.Handle)
    if ($LegacyOwnPid) { $PipeName = "wmux-ipc-$($p.Id)" }
    $null = Wait-WmuxCondition -TimeoutSec 90 -IntervalMs 50 { [WmuxTestHarness.Native]::PipeExists($PipeName) -or $p.HasExited }
    if ($p.HasExited) { throw "fake server exited early: $($p.StandardError.ReadToEnd())" }
    return [pscustomobject]@{ Process = $p; Job = $job; Pipe = "\\.\pipe\$PipeName" }
}

function Stop-FakeServerProcess {
    param($Server)
    if ($null -eq $Server) { return }
    try { $null = [WmuxTestHarness.PipeIO]::RoundTrip($Server.Pipe, 'quit', 3000) } catch { }
    if (-not $Server.Process.WaitForExit(5000)) { try { $Server.Process.Kill($true) } catch { } }
    [WmuxTestHarness.JobObject]::Close($Server.Job)
}

function Get-FakeServer {
    # The shared fake server of this file (started on first use, stopped at the end).
    if ($script:FakeServer) { return $script:FakeServer }
    $script:FakeServer = Start-FakeServerProcess -PipeName ('wmux-e2e-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    return $script:FakeServer
}

function New-FakeInstance {
    param([string]$Protocol = 'v2', [string]$Pipe)
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $root = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'wmux-e2e') "selftest-$id"
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'artifacts')
    $inst = [WmuxInstance]::new()
    $inst.Id = $id
    $inst.Channel = "test-$id"
    $inst.Protocol = $Protocol
    $inst.Pipe = $Pipe
    $inst.Root = $root
    $inst.ArtifactsDir = Join-Path $root 'artifacts'
    $inst.WorkDir = $root
    $inst.LocalAppData = Join-Path $root 'localappdata'
    $inst.ToastSink = Join-Path $root 'toasts.jsonl'
    $inst.StateDir = Join-Path $root 'state'
    $inst.ConfigDir = Join-Path $root 'config'
    $inst.CliExe = Join-Path $root 'cli\cmux.exe'
    $inst.Exe = Join-Path $root 'wmux.exe'
    $inst.JobHandle = [IntPtr]::Zero
    return $inst
}

# ---------------------------------------------------------------------------

Test-Case 'module exports exactly the Appendix D.3 functions and parameters' {
    $expected = [ordered]@{
        'Start-WmuxInstance'    = @('Build', 'Exe', 'Settings', 'Ghostty', 'Shell', 'Restore', 'Visible', 'KeepArtifacts', 'TimeoutSec')
        'Stop-WmuxInstance'     = @('Instance', 'TimeoutSec')
        'Invoke-WmuxRpc'        = @('Instance', 'Method', 'Params', 'TimeoutSec', 'Raw')
        'Invoke-WmuxRawLine'    = @('Instance', 'Line', 'TimeoutSec')
        'Invoke-WmuxCli'        = @('Instance', 'Arguments', 'Stdin', 'Env', 'AsWmux')
        'Open-WmuxEventStream'  = @('Instance', 'Category', 'Name', 'AfterSeq')
        'Read-WmuxEvents'       = @('Stream', 'TimeoutSec')
        'Close-WmuxEventStream' = @('Stream')
        'Wait-WmuxEvent'        = @('Instance', 'Name', 'Category', 'Where', 'TimeoutSec')
        'Wait-WmuxCondition'    = @('TimeoutSec', 'IntervalMs', 'Condition')
        'Wait-WmuxScreen'       = @('Instance', 'Surface', 'Pattern', 'TimeoutSec')
        'Get-WmuxScreenshot'    = @('Instance', 'Path', 'Window')
        'Get-WmuxToasts'        = @('Instance')
        'Get-WmuxDialogs'       = @('Instance')
        'Assert-Equal'          = @('Expected', 'Actual', 'Message')
        'Assert-NotEqual'       = @('Expected', 'Actual', 'Message')
        'Assert-Match'          = @('Pattern', 'Actual', 'Message')
        'Assert-True'           = @('Condition', 'Message')
        'Assert-Throws'         = @('Code', 'ScriptBlock', 'Message')
        'Assert-JsonShape'      = @('Actual', 'Shape', 'Message')
        'Test-Case'             = @('Name', 'Body')
    }
    $exported = @((Get-Command -Module WmuxTest).Name | Sort-Object)
    Assert-Equal (@($expected.Keys | Sort-Object) -join ',') ($exported -join ',') 'exported function set'
    Assert-Equal 0 $script:Mod.ExportedAliases.Count 'no aliases exported'
    Assert-Equal 0 $script:Mod.ExportedVariables.Count 'no variables exported'
    $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    foreach ($name in $expected.Keys) {
        $actual = @((Get-Command $name).Parameters.Keys | Where-Object { $common -notcontains $_ } | Sort-Object)
        Assert-Equal (@($expected[$name] | Sort-Object) -join ',') ($actual -join ',') "parameters of $name"
    }
    $wait = Get-Command Wait-WmuxEvent
    Assert-Equal 'ByName,ByCategory' (@($wait.ParameterSets.Name) -join ',') 'Wait-WmuxEvent takes -Name or -Category'
    Assert-Equal 'WmuxInstance' (Get-Command Start-WmuxInstance).OutputType[0].Name
    foreach ($field in 'Pid', 'Channel', 'Root', 'StateDir', 'ConfigDir', 'Pipe', 'LaunchPipe', 'Exe', 'CliExe', 'ToastSink', 'ArtifactsDir', 'Failed') {
        Assert-True ($null -ne [WmuxInstance].GetField($field)) "[WmuxInstance] has field $field"
    }
}

Test-Case 'Assert-JsonShape wildcards UUIDs, refs and timestamps and reports paths' {
    $golden = '{"workspace_id":"384E46CB-5986-49BE-9696-4BC07AF97C4D","workspace_ref":"workspace:4","index":3,' +
    '"created_at":"2026-10-15T09:41:27.250Z","event_id":"EED6A3D5-CDF0-4823-A383-CE4C9EC42335-57","title":"api","tags":["a","b"]}'
    $good = [ordered]@{
        workspace_id = [guid]::NewGuid().ToString().ToUpperInvariant(); workspace_ref = 'workspace:17'; index = 3
        created_at = '2026-10-15T08:00:00Z'; event_id = ([guid]::NewGuid().ToString() + '-9'); title = 'api'; tags = @('a', 'b'); extra = 1
    }
    Assert-JsonShape $good $golden
    Assert-JsonShape ([pscustomobject]$good) $golden

    $bad = Copy-Map $good; $bad.workspace_ref = 'surface:3'
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.workspace_ref: expected a workspace:N ref'
    $bad = Copy-Map $good; $bad.workspace_id = 'abc'
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.workspace_id: expected a UUID'
    $bad = Copy-Map $good; $bad.index = 4
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.index: expected 3, got 4'
    $bad = Copy-Map $good; $bad.index = '3'
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.index: expected 3, got "3"'
    $bad = Copy-Map $good; $bad.Remove('title')
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.title: missing'
    $bad = Copy-Map $good; $bad.tags = @('a')
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.tags: expected 2 elements, got 1'
    $bad = Copy-Map $good; $bad.created_at = 'yesterday'
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.created_at: expected an ISO-8601 timestamp'
    $bad = Copy-Map $good; $bad.event_id = 'evt-1'
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.event_id: expected a <uuid>-<seq> id'
    $bad = Copy-Map $good; $bad.title = 'API'
    Assert-AssertionFails { Assert-JsonShape $bad $golden } '$.title: expected "api", got "API"'
    # Several mismatches are reported together.
    $e = Assert-Throws { Assert-JsonShape @{ index = 'x'; tags = 5 } $golden }
    Assert-Match '\d+ mismatch\(es\)' $e.Message
    Assert-True ($e.Message.Contains('$.tags: expected an array of 2')) $e.Message
}

Test-Case 'Assert-JsonShape tokens, optional and strict keys, <each> arrays and inputs' {
    Assert-JsonShape @{ a = 5; b = 'x'; c = $true; d = $null; e = @(1); f = @{ g = 1 }; h = 1.5 } `
        '{"a":"<int>","b":"<string>","c":"<bool>","d":"<null>","e":"<array>","f":"<object>","h":"<number>"}'
    Assert-AssertionFails { Assert-JsonShape @{ a = 1.5 } '{"a":"<int>"}' } '$.a: expected <int>, got 1.5'
    Assert-AssertionFails { Assert-JsonShape @{ a = '' } '{"a":"<nonempty>"}' } '$.a: expected <nonempty>'
    Assert-JsonShape @{ a = 'surface:9'; b = 'pane:2' } '{"a":"<ref:surface>","b":"<ref>"}'
    Assert-AssertionFails { Assert-JsonShape @{ a = 'pane:9' } '{"a":"<ref:surface>"}' } '$.a: expected <ref:surface>'
    Assert-JsonShape @{ t = 1760500000123 } '{"t":"<timestamp>"}'
    Assert-JsonShape 'WMUX>echo hi' '<re:^WMUX>echo>'
    Assert-AssertionFails { Assert-JsonShape 'nope' '<re:^WMUX>' } 'expected <re:^WMUX>'
    Assert-AssertionFails { Assert-JsonShape 'WMUX>echo hi' '<re:^WMUX>echo' } 'expected "<re:^WMUX>echo"'
    Assert-JsonShape @{ x = 1 } '{"a?":"<int>","x":1}'
    Assert-AssertionFails { Assert-JsonShape @{ a = 'x' } '{"a?":"<int>"}' } '$.a: expected <int>'
    Assert-JsonShape @{ a = 1 } '{"<strict>":true,"a":1}'
    Assert-AssertionFails { Assert-JsonShape @{ a = 1; b = 2 } '{"<strict>":true,"a":1}' } '$.b: unexpected key'
    Assert-AssertionFails { Assert-JsonShape '{"ID":1}' '{"id":1}' } "key case differs (got 'ID')"
    $uuid = [guid]::NewGuid().ToString()
    Assert-JsonShape @(@{ id = $uuid }, @{ id = $uuid }) '["<each>", {"id":"<uuid>"}]'
    Assert-JsonShape @() '["<each>", {"id":"<uuid>"}]'
    Assert-AssertionFails { Assert-JsonShape @(@{ id = $uuid }, @{ id = 'x' }) '["<each>", {"id":"<uuid>"}]' } '$[1].id: expected <uuid>, got "x"'
    # Actual JSON text is parsed; a hashtable shape works; u64 ids compare exactly.
    Assert-JsonShape '{"a":5}' @{ a = '<int>' }
    Assert-JsonShape '{"id":17293822569102704640}' '{"id":17293822569102704640}'
    Assert-AssertionFails { Assert-JsonShape '{"id":17293822569102704640}' '{"id":17293822569102704641}' } '$.id: expected 17293822569102704641'
    # Golden shape loaded from a .json file by absolute path or from test/e2e/fixtures.
    $file = Write-TempFile 'shape.json' '{"workspace_ref":"workspace:1","ok":true}'
    Assert-JsonShape @{ workspace_ref = 'workspace:99'; ok = $true } $file
    Assert-JsonShape @(@{ index = 0; name = 'main'; active = $true; tab_count = 1 }) 'shapes/legacy-workspace-list.json'
    Assert-AssertionFails { Assert-JsonShape @(@{ index = 0; name = 'main'; active = 'yes'; tab_count = 1 }) 'shapes/legacy-workspace-list.json' } '$[0].active: expected <bool>'
    # The failing line of the test file is part of the message.
    $e = Assert-Throws { Assert-JsonShape @{ a = 1 } '{"a":2}' }
    Assert-Match '\(at harness\.e2e\.ps1:\d+\)' $e.Message
}

Test-Case 'Assert-Equal, Assert-NotEqual, Assert-Match and Assert-True are strict and informative' {
    Assert-Equal 'abc' 'abc'
    Assert-AssertionFails { Assert-Equal 'abc' 'ABC' } 'expected "abc", got "ABC" (first difference at index 0)'
    Assert-Equal 3 ([long]3)
    Assert-Equal 3 3.0
    Assert-Equal ([uint64]'17293822569102704640') ([WmuxTestHarness.Json]::Parse('17293822569102704640'))
    Assert-AssertionFails { Assert-Equal 0 '0' } 'expected 0, got "0"'
    Assert-AssertionFails { Assert-Equal $true 1 } 'expected true, got 1'
    Assert-Equal $null $null
    Assert-AssertionFails { Assert-Equal $null '' } 'expected null, got ""'
    Assert-Equal @(1, 2) @(1, 2)
    Assert-AssertionFails { Assert-Equal @(1, 2) @(2, 1) } 'expected [1,2], got [2,1]'
    Assert-Equal @{ a = 1; b = @(1, 2) } ([pscustomobject]@{ b = @(1, 2); a = 1 })
    Assert-AssertionFails { Assert-Equal @{ a = 1 } @{ a = 2 } } 'Assert-Equal'
    Assert-NotEqual 1 2
    Assert-AssertionFails { Assert-NotEqual 'a' 'a' } 'Assert-NotEqual: both values are "a"'
    Assert-Match '^workspace:\d+$' 'workspace:12'
    Assert-AssertionFails { Assert-Match 'x' $null } 'does not match null'
    Assert-AssertionFails { Assert-Match '^A' 'abc' } '/^A/ does not match "abc"'
    Assert-True $true
    Assert-True 'x'
    Assert-AssertionFails { Assert-True $false } 'condition is false'
    Assert-AssertionFails { Assert-True @() } 'Assert-True'
    $e = Assert-Throws { Assert-Equal 1 2 'workspace count' }
    Assert-True $e.Message.StartsWith('workspace count -- Assert-Equal: expected 1, got 2') $e.Message
    Assert-Match '\(at harness\.e2e\.ps1:\d+\)' $e.Message
}

Test-Case 'Assert-Throws matches WmuxRpcError codes and exposes Code, Message and Data' {
    $err = Assert-Throws -Code 'not_found' {
        throw [WmuxRpcError]::new('not_found', 'Workspace not found', [pscustomobject]@{ selector = 'workspace_id' }, 'workspace.select', 'id-1', $null, $null, $null)
    }
    Assert-Equal 'not_found' $err.Code
    Assert-Equal 'Workspace not found' $err.Message
    Assert-Equal 'workspace_id' $err.Data.selector
    Assert-Equal 'workspace.select' $err.Method
    Assert-AssertionFails { Assert-Throws -Code 'invalid_params' { throw [WmuxRpcError]::new('not_found', 'x') } } "expected code 'invalid_params', got 'not_found'"
    Assert-AssertionFails { Assert-Throws -Code 'x' { 1 } } 'nothing was thrown'
    Assert-AssertionFails { Assert-Throws -Code 'x' { throw 'boom' } } 'got RuntimeException: boom'
    $any = Assert-Throws { throw [InvalidOperationException]::new('plain') }
    Assert-Equal 'plain' $any.Message
    $caught = $null
    try { throw [WmuxRpcError]::new('busy', 'b') } catch [WmuxRpcError] { $caught = $_.Exception.Code }
    Assert-Equal 'busy' $caught 'catch [WmuxRpcError] resolves in test scripts'
}

Test-Case 'pipe names follow the D.2.6 algorithm on fixed inputs' {
    # Oracle values computed independently with: printf '%s' <sid> | sha256sum | cut -c1-8
    Assert-Equal 'a8c06b30' (InModule { Get-WmuxSidHash8 -Sid 'S-1-5-21-1111111111-2222222222-3333333333-1001' })
    Assert-Equal '72c8a69c' (InModule { Get-WmuxSidHash8 -Sid 'S-1-5-21-3623811015-3361044348-30300820-1013' })
    Assert-Equal '593347bd' (InModule { Get-WmuxSidHash8 -Sid 'S-1-5-18' })
    Assert-Equal 'wmux-test-0a1b2c3d-a8c06b30-s1' (InModule { Get-WmuxPipeName -Channel 'test-0a1b2c3d' -SidHash8 'a8c06b30' -Session 1 })
    Assert-Equal 'wmux-test-0a1b2c3d-a8c06b30-s1-launch' (InModule { Get-WmuxPipeName -Channel 'test-0a1b2c3d' -SidHash8 'a8c06b30' -Session 1 -Launch })
    Assert-Equal 'wmux-stable-593347bd-s2' (InModule { Get-WmuxPipeName -Channel 'stable' -SidHash8 '593347bd' -Session 2 })
    Assert-Equal 'dev-feature-x' (InModule { ConvertTo-WmuxChannel 'Dev-Feature_X' })
    Assert-Equal 'test-0a1b2c3d' (InModule { ConvertTo-WmuxChannel 'test-0a1b2c3d' })
    Assert-Equal 40 (InModule { ConvertTo-WmuxChannel ('a' * 50) }).Length
    Assert-Match '^[0-9a-f]{8}$' (InModule { Get-WmuxSidHash8 })
    Assert-Equal ([System.Diagnostics.Process]::GetCurrentProcess().SessionId) (InModule { Get-WmuxSessionId })
    $live = InModule { Get-WmuxPipeName -Channel 'test-12345678' }
    Assert-Match '^wmux-test-12345678-[0-9a-f]{8}-s\d+$' $live
    Assert-Equal '\\.\pipe\wmux-x' (InModule { ConvertTo-WmuxFullPipePath 'wmux-x' })
    Assert-Equal '\\.\pipe\wmux-x' (InModule { ConvertTo-WmuxFullPipePath '\\.\pipe\wmux-x' })
}

Test-Case 'v2 envelope encoding and decoding' {
    $line = InModule { New-WmuxRpcRequestLine -Method 'workspace.create' -Params ([ordered]@{ title = 'api'; focus = $false }) -Id 'abc' }
    Assert-Equal '{"id":"abc","method":"workspace.create","params":{"title":"api","focus":false}}' $line
    Assert-Equal '{"id":7,"method":"system.ping","params":{}}' (InModule { New-WmuxRpcRequestLine -Method 'system.ping' -Params $null -Id 7 })
    $null = Assert-Throws { InModule { New-WmuxRpcRequestLine -Method 'x' -Params 'nope' -Id 1 } }

    $ok = '{"id":"abc","ok":true,"result":{"workspace_id":"384E46CB-5986-49BE-9696-4BC07AF97C4D","index":3}}'
    $r = InModule { param($l) ConvertFrom-WmuxRpcReply -Line $l -RequestId 'abc' -Method 'workspace.create' } $ok
    Assert-Equal 3 $r.index
    $arr = InModule { ConvertFrom-WmuxRpcReply -Line '{"id":1,"ok":true,"result":[{"a":1}]}' -RequestId 1 -Method 'm' }
    Assert-True ($arr -is [array]) 'a one-element array result stays an array'
    Assert-Equal 1 $arr.Count
    $e = Assert-Throws -Code 'not_found' {
        InModule { ConvertFrom-WmuxRpcReply -Line '{"id":"abc","ok":false,"error":{"code":"not_found","message":"Workspace not found","data":{"selector":"workspace_id"}}}' -RequestId 'abc' -Method 'workspace.select' }
    }
    Assert-Equal 'Workspace not found' $e.Message
    Assert-Equal 'workspace_id' $e.Data.selector
    Assert-Equal 'not_found' $e.ErrorObject.code
    $null = Assert-Throws -Code 'harness_id_mismatch' { InModule { ConvertFrom-WmuxRpcReply -Line '{"id":"zzz","ok":true,"result":1}' -RequestId 'abc' -Method 'm' } }
    $null = Assert-Throws -Code 'parse_error' { InModule { ConvertFrom-WmuxRpcReply -Line '{"id":null,"ok":false,"error":{"code":"parse_error","message":"Invalid JSON"}}' -RequestId 'abc' -Method 'm' } }
    $null = Assert-Throws -Code 'harness_legacy_protocol' { InModule { ConvertFrom-WmuxRpcReply -Line '{"id":0,"ok":false,"error":"request must be an object"}' -RequestId 'abc' -Method 'm' } }
    $null = Assert-Throws -Code 'harness_legacy_protocol' { InModule { ConvertFrom-WmuxRpcReply -Line '{"id":1,"ok":true,"data":[]}' -RequestId 'abc' -Method 'm' } }
    $legacyRaw = InModule { ConvertFrom-WmuxRpcReply -Line '{"id":0,"ok":false,"error":"unknown command"}' -RequestId 'abc' -Method 'm' -Raw }
    Assert-Equal 'unknown command' $legacyRaw.error '-Raw returns a legacy envelope instead of throwing'
    $null = Assert-Throws -Code 'harness_bad_reply' { InModule { ConvertFrom-WmuxRpcReply -Line 'PONG' -RequestId 'abc' -Method 'm' } }
    $raw = InModule { ConvertFrom-WmuxRpcReply -Line '{"id":"abc","ok":false,"error":{"code":"busy","message":"b"}}' -RequestId 'abc' -Method 'm' -Raw }
    Assert-Equal $false $raw.ok
    Assert-Equal 'busy' $raw.error.code
    $legacy = InModule { ConvertFrom-WmuxLegacyReply '{"id":1,"ok":true,"data":[{"index":0}]}' }
    Assert-Equal 0 $legacy.data[0].index
}

Test-Case 'JSON conversion keeps strings, u64 ids and single-element arrays' {
    $v = [WmuxTestHarness.Json]::Parse('{"t":"2026-10-15T09:41:27.250Z","big":17293822569102704640,"one":[1],"n":null,"f":1.5,"nested":{"k":"v"},"neg":-3}')
    Assert-True ($v.t -is [string]) 'ISO dates stay strings'
    Assert-Equal '2026-10-15T09:41:27.250Z' $v.t
    Assert-True ($v.big -is [uint64]) 'ids beyond Int64 become UInt64'
    Assert-Equal ([uint64]'17293822569102704640') $v.big
    Assert-True ($v.one -is [array]) 'single-element arrays survive'
    Assert-Equal 1 $v.one.Count
    Assert-Equal $null $v.n
    Assert-Equal 1.5 $v.f
    Assert-Equal 'v' $v.nested.k
    Assert-True ($v.neg -is [long])
    Assert-Equal '{"t":"2026-10-15T09:41:27.250Z","big":17293822569102704640,"one":[1],"n":null,"f":1.5,"nested":{"k":"v"},"neg":-3}' (ConvertTo-Json -InputObject $v -Compress -Depth 10)
}

Test-Case 'settings document, ghostty.conf and child environment follow D.2 (no launch)' {
    $doc = InModule { ConvertTo-WmuxSettingsDocument -Settings @{ 'sidebar.showPorts' = $false; 'automation.portBase' = 9200; notifications = @{ sound = 'none' } } }
    $json = ConvertTo-Json -InputObject $doc -Depth 10 | ConvertFrom-Json
    Assert-Equal 'automation' $json.automation.socketControlMode
    Assert-Equal 9200 $json.automation.portBase
    Assert-Equal $false $json.sidebar.showPorts
    Assert-Equal 'none' $json.notifications.sound
    Assert-Equal '{"automation":{"socketControlMode":"automation"}}' (ConvertTo-Json -InputObject (InModule { ConvertTo-WmuxSettingsDocument -Settings $null }) -Compress)
    $null = Assert-Throws { InModule { ConvertTo-WmuxSettingsDocument -Settings ([ordered]@{ 'a' = 1; 'a.b' = 2 }) } }
    $null = Assert-Throws { InModule { ConvertTo-WmuxSettingsDocument -Settings ([ordered]@{ 'a.b' = 2; 'a' = 1 }) } }

    $conf = InModule { New-WmuxGhosttyConfText -Shell $null -Ghostty @('font-size = 11', "a = 1`nb = 2") -Id 'abcd1234' }
    Assert-Match '(?m)^command = cmd\.exe /d /k prompt WMUX\$G$' $conf
    Assert-Match '(?m)^font-size = 11$' $conf
    Assert-Match '(?m)^a = 1$' $conf
    Assert-Match '(?m)^b = 2$' $conf
    Assert-True ($conf.IndexOf('command =') -lt $conf.IndexOf('font-size')) 'test lines come after the command line so they win'
    Assert-Match '(?m)^command = pwsh\.exe -NoLogo -NoProfile$' (InModule { New-WmuxGhosttyConfText -Shell 'pwsh.exe -NoLogo -NoProfile' -Id 'x' })
    $null = Assert-Throws { InModule { New-WmuxGhosttyConfText -Shell "cmd.exe`nfoo = 1" -Id 'x' } }

    $base = @{
        PATH = 'C:\Windows'; USERPROFILE = 'C:\Users\u'; LOCALAPPDATA = 'C:\Users\u\AppData\Local'
        CMUX_SOCKET_PATH = '\\.\pipe\user'; CMUX_WORKSPACE_ID = 'X'; CMUX_SOCKET = 'old'; WMUX_SOCKET_PASSWORD = 'pw'
        WMUX_SOCKET_PATH = '\\.\pipe\user'; WMUX_WORKSPACE_ID = 'Y'; GHOSTTY_RESOURCES_DIR = 'C:\x'; GHOSTTY_PID = '42'
        WMUX_WEB_DIR = 'C:\web'; WMUX_CHANNEL = 'stable'; WMUX_STATE_DIR = 'C:\real'; CLAUDECODE = '1'; ANTHROPIC_API_KEY = 'sk'
        CLAUDE_CODE_ENTRYPOINT = 'cli'; GH_TOKEN = 't'
    }
    $root = 'C:\tmp\wmux-e2e\0a1b2c3d'
    $envMap = InModule { param($b, $r) New-WmuxChildEnvironment -BaseEnvironment $b -Root $r -Id '0a1b2c3d' } $base $root
    foreach ($kept in 'PATH', 'USERPROFILE', 'WMUX_WEB_DIR') { Assert-True $envMap.ContainsKey($kept) "$kept is inherited" }
    foreach ($gone in 'CMUX_SOCKET_PATH', 'CMUX_WORKSPACE_ID', 'CMUX_SOCKET', 'WMUX_SOCKET_PASSWORD', 'WMUX_SOCKET_PATH', 'WMUX_WORKSPACE_ID',
        'GHOSTTY_RESOURCES_DIR', 'GHOSTTY_PID', 'CLAUDECODE', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_ENTRYPOINT', 'GH_TOKEN', 'WMUX_TEST_SESSION_RESTORE') {
        Assert-True (-not $envMap.ContainsKey($gone)) "$gone is removed"
    }
    $want = [ordered]@{
        WMUX_TEST_MODE = '1'; WMUX_TEST_HIDDEN = '1'; WMUX_CHANNEL = 'test-0a1b2c3d'; WMUX_STATE_DIR = "$root\state"
        WMUX_CONFIG_DIR = "$root\config"; XDG_CONFIG_HOME = "$root\xdg"; WMUX_SOCKET_MODE = 'automation'
        WMUX_DISABLE_SESSION_RESTORE = '1'; WMUX_TEST_TOAST_SINK = "$root\toasts.jsonl"; LOCALAPPDATA = "$root\localappdata"
    }
    foreach ($k in $want.Keys) { Assert-Equal $want[$k] $envMap[$k] $k }
    $visible = InModule { param($b, $r) New-WmuxChildEnvironment -BaseEnvironment $b -Root $r -Id '0a1b2c3d' -Visible -Restore -KeepLocalAppData } $base $root
    Assert-True (-not $visible.ContainsKey('WMUX_TEST_HIDDEN')) '-Visible omits WMUX_TEST_HIDDEN'
    Assert-Equal '1' $visible['WMUX_TEST_SESSION_RESTORE'] '-Restore enables test session restore'
    Assert-True (-not $visible.ContainsKey('WMUX_DISABLE_SESSION_RESTORE')) '-Restore drops WMUX_DISABLE_SESSION_RESTORE'
    Assert-Equal 'C:\Users\u\AppData\Local' $visible['LOCALAPPDATA'] '-KeepLocalAppData keeps LOCALAPPDATA'
    $tempBase = InModule { Get-WmuxTempBase }
    Assert-True (Test-Path -LiteralPath $tempBase -PathType Container) "instance roots live under an existing directory: $tempBase"
    Assert-True (-not $tempBase.Contains('~')) "8.3 short names are expanded: $tempBase"
}

Test-Case 'hidden-support detection and the start-up guards never open a window' {
    $ascii = Write-TempFile 'bin-ascii.bin' ("xx`0WMUX_TEST_HIDDEN`0yy")
    $utf16 = Join-Path $script:TempRoot 'bin-utf16.bin'
    [IO.File]::WriteAllBytes($utf16, [byte[]](@(0, 1, 2) + [Text.Encoding]::Unicode.GetBytes('WMUX_TEST_HIDDEN') + @(9, 9)))
    $none = Write-TempFile 'bin-none.bin' 'WMUX_TEST_HIDDE N'
    $edge = Join-Path $script:TempRoot 'bin-edge.bin'
    $fs = [IO.File]::Create($edge)
    try {
        # The scanner reads 4 MiB + 32 bytes first; put the literal across that boundary.
        $pad = (4 -shl 20) + 32 - 5
        $fs.Write([byte[]]::new($pad), 0, $pad)
        $needle = [Text.Encoding]::ASCII.GetBytes('WMUX_TEST_HIDDEN')
        $fs.Write($needle, 0, $needle.Length)
    } finally { $fs.Dispose() }
    Assert-True ([WmuxTestHarness.Native]::FileContains($ascii, 'WMUX_TEST_HIDDEN')) 'ASCII literal found'
    Assert-True ([WmuxTestHarness.Native]::FileContains($utf16, 'WMUX_TEST_HIDDEN')) 'UTF-16LE literal found'
    Assert-True (-not [WmuxTestHarness.Native]::FileContains($none, 'WMUX_TEST_HIDDEN')) 'near miss rejected'
    Assert-True ([WmuxTestHarness.Native]::FileContains($edge, 'WMUX_TEST_HIDDEN')) 'literal across the 4 MiB read boundary found'

    # Assert-Throws lets skips through on purpose (a skip always wins), so catch it directly.
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $skip = $null
    try { $null = Start-WmuxInstance -Exe $cmd } catch { $skip = $_.Exception }
    Assert-True ($skip -is [WmuxSkipException]) "a binary without WMUX_TEST_HIDDEN is skipped, got $(if ($skip) { $skip.GetType().Name } else { 'nothing' })"
    Assert-Match 'pending W0-A1' $skip.Message
    $e = Assert-Throws { Start-WmuxInstance -Exe (Join-Path $script:TempRoot 'missing\wmux.exe') }
    Assert-True ($e -is [WmuxAssertionError]) 'a missing binary fails the test'
    Assert-Match 'wmux\.exe not found' $e.Message
}

Test-Case 'Wait-WmuxCondition polls, returns the value and times out with context' {
    $script:polls = 0
    $value = Wait-WmuxCondition -TimeoutSec 10 -IntervalMs 10 { $script:polls++; if ($script:polls -ge 3) { "ready-$($script:polls)" } }
    Assert-True ($value -is [string]) 'a scalar value is returned unwrapped'
    Assert-Equal 'ready-3' $value
    $list = Wait-WmuxCondition -TimeoutSec 5 { , @(42) }
    Assert-True ($list -is [array]) 'array values are returned intact'
    $e = Assert-Throws { Wait-WmuxCondition -TimeoutSec 0.3 -IntervalMs 50 { throw 'not yet' } }
    Assert-True ($e -is [WmuxAssertionError]) 'timeout is an assertion failure'
    Assert-Match 'timed out after 0\.3s' $e.Message
    Assert-Match 'last error: not yet' $e.Message
    $e = Assert-Throws { Wait-WmuxCondition -TimeoutSec 0.2 -IntervalMs 50 { 0 } }
    Assert-Match 'last value: 0' $e.Message
}

Test-Case 'transport helpers against a fake v2 server: rpc, raw lines, errors' {
    $srv = Get-FakeServer
    $w = New-FakeInstance -Pipe $srv.Pipe
    try {
        $r = Invoke-WmuxRpc $w 'system.ping' @{ hello = 'world' }
        Assert-True ($r -isnot [array]) 'an object result is not wrapped in an array'
        Assert-Equal $true $r.pong
        Assert-Equal 'world' $r.echo.hello
        $envelope = Invoke-WmuxRpc $w 'boom' -Raw
        Assert-Equal $false $envelope.ok
        Assert-Equal 'not_found' $envelope.error.code
        $e = Assert-Throws -Code 'not_found' { Invoke-WmuxRpc $w 'boom' }
        Assert-Equal 'Workspace not found' $e.Message
        Assert-Equal 'workspace_id' $e.Data.selector
        Assert-Equal 'boom' $e.Method
        $null = Assert-Throws -Code 'harness_id_mismatch' { Invoke-WmuxRpc $w 'wrong.id' }
        $null = Assert-Throws -Code 'method_not_found' { Invoke-WmuxRpc $w 'no.such.method' }
        $one = Invoke-WmuxRpc $w 'list.one'
        Assert-True ($one -is [array]) 'a one-element array result stays an array'
        Assert-Equal 7 $one[0]
        Assert-Equal 'PONG' (Invoke-WmuxRawLine $w 'ping')
        $legacy = Invoke-WmuxRawLine $w '{"id":5,"cmd":"workspace-list"}' | ConvertFrom-Json
        Assert-Equal $true $legacy.ok
        Assert-Equal 'legacy' $legacy.data[0].name
        $null = Assert-Throws { Invoke-WmuxRawLine $w "two`nlines" }
        $dialogs = @(Get-WmuxDialogs $w)
        Assert-Equal 1 $dialogs.Count
        Assert-Equal 'Confirm' $dialogs[0].title
        $png = Get-WmuxScreenshot $w -Path (Join-Path $script:TempRoot 'shot\fake.png')
        $bytes = [IO.File]::ReadAllBytes($png.FullName)
        Assert-Equal '89-50-4E-47' ([BitConverter]::ToString($bytes, 0, 4)) 'PNG signature written from png_base64'
        $missing = New-FakeInstance -Pipe ('\\.\pipe\wmux-e2e-selftest-missing-' + [guid]::NewGuid().ToString('N'))
        try {
            $null = Assert-Throws -Code 'harness_timeout' { Invoke-WmuxRawLine $missing '{}' -TimeoutSec 0.3 }
        } finally { Stop-WmuxInstance $missing }
    } finally {
        Stop-WmuxInstance $w
    }
    Assert-True (-not (Test-Path -LiteralPath $w.Root)) 'Stop-WmuxInstance deleted the instance root'
    Assert-True $w.Stopped
    $null = Assert-Throws -Code 'harness_instance_stopped' { Invoke-WmuxRpc $w 'system.ping' }
}

Test-Case 'late replies to timed-out requests are skipped; other replies are returned as is' {
    $srv = Get-FakeServer
    $w = New-FakeInstance -Pipe $srv.Pipe
    try {
        # As if request 41 had timed out: its reply now arrives ahead of the reply to 42.
        $null = $w.OutstandingIds.Add('n:41')
        $r = Invoke-WmuxRawLine $w '{"id":42,"cmd":"stale-pair","args":{"stale":41}}' | ConvertFrom-Json
        Assert-Equal 42 $r.id 'the late reply to 41 was skipped'
        Assert-Equal 'fresh' $r.data
        Assert-Equal 0 $w.OutstandingIds.Count 'both requests are settled'
        # A reply with an id the harness is not waiting for is returned unchanged.
        $r = Invoke-WmuxRawLine $w '{"id":44,"cmd":"stale-pair","args":{"stale":43}}' | ConvertFrom-Json
        Assert-Equal 43 $r.id
        $w.OutstandingIds.Clear()
        # v2 string ids and the module's own legacy commands.
        $null = $w.OutstandingIds.Add('s:timed-out-request')
        Assert-Equal 'fresh' (Invoke-WmuxRpc $w 'stale.pair' @{ stale = 'timed-out-request' })
        Assert-Equal 0 $w.OutstandingIds.Count
        $legacyData = InModule { param($i) Invoke-WmuxLegacyCommand -Instance $i -Cmd 'workspace-list' } $w
        Assert-Equal 'legacy' @($legacyData)[0].name
        # Lines without an id (text-v1) are not matched.
        Assert-Equal 'PONG' (Invoke-WmuxRawLine $w 'ping')
    } finally {
        Stop-WmuxInstance $w
    }
}

Test-Case 'event helpers against a fake v2 server: stream, read, wait' {
    $srv = Get-FakeServer
    $w = New-FakeInstance -Pipe $srv.Pipe
    try {
        $s = Open-WmuxEventStream $w -Name 'workspace.created' -AfterSeq 0
        Assert-Equal 'ack' $s.Ack.type
        Assert-Equal 0 $s.Ack.resume.requested_after_seq 'after_seq is sent'
        Assert-Equal 'workspace.created' @($s.Ack.filters.names)[0] 'name filter is sent'
        # The fake server closes after its canned frames; wait for that so the read is deterministic.
        $null = Wait-WmuxCondition -TimeoutSec 10 -IntervalMs 20 { $s.EndOfStream }
        $events = @(Read-WmuxEvents $s -TimeoutSec 5)
        Assert-Equal 2 $events.Count 'heartbeats are not returned as events'
        Assert-Equal 'C0CD13DB-0141-4529-B8E8-D5DF0A696C28' $events[1].workspace_id
        Assert-JsonShape $events[0] '{"type":"event","seq":"<int>","id":"EED6A3D5-CDF0-4823-A383-CE4C9EC42335-1","name":"workspace.created","workspace_id":"<uuid>","occurred_at":"<timestamp>"}'
        $null = Assert-Throws -Code 'harness_stream_closed' { Read-WmuxEvents $s -TimeoutSec 1 }
        Close-WmuxEventStream $s
        $logLines = @(Get-Content -LiteralPath $s.LogPath)
        Assert-Equal 4 $logLines.Count 'the stream log keeps every frame (ack, events, heartbeat)'

        $wanted = 'C0CD13DB-0141-4529-B8E8-D5DF0A696C28'
        $frame = Wait-WmuxEvent $w -Name 'workspace.created' -Where { $_.workspace_id -eq $wanted } -TimeoutSec 10
        Assert-Equal 2 $frame.seq
        $frame = Wait-WmuxEvent $w -Category 'workspace' -TimeoutSec 10
        Assert-Equal 1 $frame.seq
        $e = Assert-Throws { Wait-WmuxEvent $w -Name 'workspace.created' -Where { $_.workspace_id -eq 'nope' } -TimeoutSec 3 }
        Assert-True ($e -is [WmuxAssertionError])
        Assert-Match 'Wait-WmuxEvent: the events stream ended before a matching event' $e.Message
        Assert-Match 'Non-matching events: workspace\.created' $e.Message

        $text = Wait-WmuxScreen $w -Surface 'surface:1' -Pattern '(?m)^hi$' -TimeoutSec 15
        Assert-Match 'WMUX>echo hi' $text
        $e = Assert-Throws { Wait-WmuxScreen $w -Surface 'surface:1' -Pattern 'never-there' -TimeoutSec 0.5 }
        Assert-Match 'Last screen lines' $e.Message
    } finally {
        Stop-WmuxInstance $w
    }
}

Test-Case 'v2-only helpers refuse a legacy instance; Get-WmuxToasts parses the sink' {
    $w = New-FakeInstance -Protocol 'legacy' -Pipe '\\.\pipe\wmux-e2e-selftest-legacy-none'
    try {
        $null = Assert-Throws -Code 'harness_legacy_protocol' { Invoke-WmuxRpc $w 'system.ping' }
        $null = Assert-Throws -Code 'harness_legacy_protocol' { Open-WmuxEventStream $w }
        $null = Assert-Throws -Code 'harness_legacy_protocol' { Wait-WmuxEvent $w -Name 'x' -TimeoutSec 1 }
        $null = Assert-Throws -Code 'harness_legacy_protocol' { Get-WmuxDialogs $w }
        $null = Assert-Throws -Code 'harness_cli_missing' { Invoke-WmuxCli $w @('frobnicate') }
        Assert-Equal 0 @(Get-WmuxToasts $w).Count 'no sink file, no toasts'
        [IO.File]::WriteAllText($w.ToastSink, "{`"title`":`"Build done`",`"body`":`"ok`"}`n`n{`"title`":`"Second`"}`n{`"partial`":", $script:Utf8)
        $toasts = @(Get-WmuxToasts $w)
        Assert-Equal 2 $toasts.Count 'a torn last line is ignored'
        Assert-Equal 'Build done' $toasts[0].title
        Assert-Equal 'Second' $toasts[1].title
    } finally {
        Stop-WmuxInstance $w
    }
}

Test-Case 'Invoke-WmuxCli isolates the environment and captures stdin, stdout and exit codes' {
    $w = New-FakeInstance -Pipe '\\.\pipe\wmux-e2e-selftest-cli'
    $w.Pid = 4242
    $w.CliExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $saved = $env:CMUX_WORKSPACE_ID
    $env:CMUX_WORKSPACE_ID = 'LEAKED-FROM-OUTER-TERMINAL'
    try {
        $r = Invoke-WmuxCli $w @('/d', '/c', 'echo [%WMUX_SOCKET_PATH%][%CMUX_SOCKET_PATH%][%GHOSTTY_PID%][%WMUX_CHANNEL%][%FOO%][%CMUX_WORKSPACE_ID%][%WMUX_TEST_MODE%]') -Env @{ FOO = 'bar' }
        Assert-Equal 0 $r.ExitCode $r.Stderr
        Assert-Equal "[\\.\pipe\wmux-e2e-selftest-cli][\\.\pipe\wmux-e2e-selftest-cli][4242][$($w.Channel)][bar][%CMUX_WORKSPACE_ID%][1]" $r.Stdout.Trim()
        $sorted = Invoke-WmuxCli $w @('/d', '/c', 'sort') -Stdin "b`r`na`r`n"
        Assert-Equal "a`r`nb`r`n" $sorted.Stdout
        Assert-Equal 3 (Invoke-WmuxCli $w @('/d', '/c', 'exit 3')).ExitCode
        $null = Assert-Throws -Code 'harness_cli_missing' { Invoke-WmuxCli $w @('ping') -AsWmux }
        $cliEnv = InModule { param($i) Get-WmuxCliEnvironment -Instance $i } $w
        Assert-Equal (Join-Path $w.Root 'localappdata') $cliEnv['LOCALAPPDATA'] 'the CLI sees the redirected LOCALAPPDATA'
        $w.LocalAppData = [NullString]::Value
        $cliEnv = InModule { param($i) Get-WmuxCliEnvironment -Instance $i } $w
        Assert-Equal $env:LOCALAPPDATA $cliEnv['LOCALAPPDATA'] 'WMUX_E2E_KEEP_LOCALAPPDATA instances keep it for the CLI too'
    } finally {
        $env:CMUX_WORKSPACE_ID = $saved
        Stop-WmuxInstance $w
    }
}

Test-Case 'kill-on-close job object terminates an assigned process' {
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\PING.EXE'))
    foreach ($a in '-n', '60', '127.0.0.1') { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $job = [WmuxTestHarness.JobObject]::Create()
        Assert-NotEqual ([IntPtr]::Zero) $job 'job created'
        Assert-True ([WmuxTestHarness.JobObject]::Assign($job, $p.Handle)) 'process assigned'
        Assert-True (-not $p.HasExited) 'still running before the job closes'
        [WmuxTestHarness.JobObject]::Close($job)
        Assert-True ($p.WaitForExit(10000)) 'closing the job killed the process'
    } finally {
        if (-not $p.HasExited) { $p.Kill($true) }
        $p.Dispose()
    }
}

# The remaining tests orchestrate nested pwsh processes (up to six each). On a loaded machine
# that can take minutes, so they get a larger per-test budget than the default 120 s.
if ([int]($env:WMUX_E2E_TEST_TIMEOUT_SEC ?? '0') -lt 300) { $env:WMUX_E2E_TEST_TIMEOUT_SEC = '300' }

Test-Case 'protocol detection: legacy pipe, computed v2 pipe, marker file, early exit, timeout' {
    function New-DetectInstance {
        $inst = New-FakeInstance -Protocol '' -Pipe $null
        $inst.LogDir = Join-Path $inst.Root 'logs'
        $null = New-Item -ItemType Directory -Force -Path $inst.LogDir, (Join-Path $inst.StateDir 'run')
        return $inst
    }
    function Wait-Ready($Instance, [double]$TimeoutSec = 60) {
        InModule { param($i, $t) Wait-WmuxInstanceReady -Instance $i -TimeoutSec $t } $Instance $TimeoutSec
    }

    # Legacy app (current master): \\.\pipe\wmux-ipc-<pid> answering workspace-list.
    $a = New-DetectInstance
    $legacy = Start-FakeServerProcess -LegacyOwnPid
    $a.Pid = $legacy.Process.Id
    $a.Process = $legacy.Process
    try {
        Wait-Ready $a
        Assert-Equal 'legacy' $a.Protocol
        Assert-Equal "\\.\pipe\wmux-ipc-$($a.Pid)" $a.Pipe
        Assert-Equal $a.Pipe $a.LegacyPipe
        Assert-Equal $null $a.LaunchPipe 'no launch pipe before W1-1a'
        Assert-Equal $true (Invoke-WmuxRawLine $a '{"id":3,"cmd":"tab-list"}' | ConvertFrom-Json).ok
        $null = Assert-Throws -Code 'harness_legacy_protocol' { Invoke-WmuxRpc $a 'system.ping' }
    } finally { Stop-FakeServerProcess $legacy; Stop-WmuxInstance $a }

    # v2 server found through the D.2.6 name of the instance channel, ready via wmux.debug.ready.
    $b = New-DetectInstance
    $name = InModule { param($c) Get-WmuxPipeName -Channel $c } $b.Channel
    $v2 = Start-FakeServerProcess -PipeName $name
    $b.Pid = $v2.Process.Id
    $b.Process = $v2.Process
    try {
        Wait-Ready $b
        Assert-Equal 'v2' $b.Protocol
        Assert-Equal "\\.\pipe\$name" $b.Pipe
        Assert-Equal "\\.\pipe\$name-launch" $b.LaunchPipe
        Assert-Equal $true (Invoke-WmuxRpc $b 'system.ping').pong
    } finally { Stop-FakeServerProcess $v2; Stop-WmuxInstance $b }

    # v2 server announced by state\run\instance.json (the marker wins over the computed name).
    $c = New-DetectInstance
    $markerPipe = 'wmux-e2e-selftest-marker-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $mk = Start-FakeServerProcess -PipeName $markerPipe
    $c.Pid = $mk.Process.Id
    $c.Process = $mk.Process
    $marker = [ordered]@{ pipe = "\\.\pipe\$markerPipe"; launch_pipe = "\\.\pipe\$markerPipe-launch"; pid = $c.Pid; protocol = 2; channel = $c.Channel }
    [IO.File]::WriteAllText((Join-Path $c.StateDir 'run\instance.json'), (ConvertTo-Json -InputObject $marker), $script:Utf8)
    try {
        Wait-Ready $c
        Assert-Equal 'v2' $c.Protocol
        Assert-Equal "\\.\pipe\$markerPipe" $c.Pipe
        Assert-Equal "\\.\pipe\$markerPipe-launch" $c.LaunchPipe
    } finally { Stop-FakeServerProcess $mk; Stop-WmuxInstance $c }

    # The process dies before any pipe shows up.
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\cmd.exe'))
    foreach ($arg in '/d', '/c', 'exit 7') { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $dead = [System.Diagnostics.Process]::Start($psi)
    $null = $dead.WaitForExit(10000)
    $d = New-DetectInstance
    $d.Pid = $dead.Id
    $d.Process = $dead
    try {
        $e = Assert-Throws { Wait-Ready $d 10 }
        Assert-Match 'exited during startup with code 7' $e.Message
    } finally { Stop-WmuxInstance $d }

    # Alive but never ready: bounded wait with a diagnostic.
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\PING.EXE'))
    foreach ($arg in '-n', '30', '127.0.0.1') { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $idle = [System.Diagnostics.Process]::Start($psi)
    $f = New-DetectInstance
    $f.Pid = $idle.Id
    $f.Process = $idle
    try {
        $e = Assert-Throws { Wait-Ready $f 1 }
        Assert-Match 'not ready after 1s' $e.Message
        Assert-Match ([regex]::Escape("wmux-ipc-$($idle.Id)")) $e.Message
    } finally { Stop-WmuxInstance $f }
    Assert-True $idle.HasExited 'Stop-WmuxInstance killed the idle process'
}

Test-Case 'legacy readiness and later requests stay in step when the app answers late' {
    # The legacy app answers queued requests only once its message loop runs, on whatever
    # connection is open then. Readiness probes that time out must not shift later replies.
    $scriptPath = Write-TempFile 'slow-legacy-server.ps1' $script:SlowLegacyServerScript
    $p = Start-ChildPwsh -Arguments @('-File', $scriptPath, '-StartupDelayMs', '3000', '-PerRequestMs', '300', '-LifetimeSec', '240')
    $job = [WmuxTestHarness.JobObject]::Create()
    $null = [WmuxTestHarness.JobObject]::Assign($job, $p.Handle)
    $inst = New-FakeInstance -Protocol '' -Pipe $null
    $inst.LogDir = Join-Path $inst.Root 'logs'
    $null = New-Item -ItemType Directory -Force -Path $inst.LogDir, (Join-Path $inst.StateDir 'run')
    $inst.Pid = $p.Id
    $inst.Process = $p
    try {
        InModule { param($i) Wait-WmuxInstanceReady -Instance $i -TimeoutSec 120 } $inst
        Assert-Equal 'legacy' $inst.Protocol
        foreach ($n in 1..6) {
            $reply = Invoke-WmuxRawLine $inst ('{"id":' + $n + ',"cmd":"workspace-list"}') -TimeoutSec 30 | ConvertFrom-Json
            Assert-Equal $n $reply.id "request $n is answered by its own reply"
        }
        $data = InModule { param($i) Invoke-WmuxLegacyCommand -Instance $i -Cmd 'workspace-list' -TimeoutSec 30 } $inst
        Assert-Equal 'w' @($data)[0].name
    } finally {
        [WmuxTestHarness.JobObject]::Close($job)
        Stop-WmuxInstance $inst
    }
}

Test-Case 'Test-Case isolates failures and reports skip, watchdog timeout and focus theft' {
    $content = @'
Import-Module '__MODULE__' -Force
Test-Case 'fails first' { Assert-Equal 1 2 'deliberate' }
Test-Case 'runs after a failure' { Assert-True $true }
Test-Case 'skips' { throw [WmuxSkipException]::new('not applicable here') }
Test-Case 'plain error' { Get-Item -LiteralPath 'Z:\definitely\missing\path' }
Test-Case 'overruns the watchdog' { Start-Sleep -Milliseconds 2500 }
Test-Case 'simulated focus theft' {
    $fg = [WmuxTestHarness.Native]::ForegroundProcessId()
    if ($fg -le 0) { throw [WmuxSkipException]::new('no foreground window (locked workstation)') }
    [WmuxTestHarness.FocusSampler]::Watch($fg)
    try { $null = [WmuxTestHarness.FocusSampler]::SampleOnce() } finally { [WmuxTestHarness.FocusSampler]::Unwatch($fg) }
}
Test-Case 'watchdog spares removed processes' {
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\PING.EXE'))
    foreach ($a in '-n', '30', '127.0.0.1') { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $spared = [System.Diagnostics.Process]::Start($psi)
    $killed = [System.Diagnostics.Process]::Start($psi)
    try {
        [WmuxTestHarness.Watchdog]::Add($spared)
        [WmuxTestHarness.Watchdog]::Add($killed)
        [WmuxTestHarness.Watchdog]::Remove($spared.Id)
        Start-Sleep -Milliseconds 2500
        Write-Host "WATCHDOG spared=$(-not $spared.HasExited) killed=$($killed.HasExited)"
    } finally {
        foreach ($x in $spared, $killed) { try { if (-not $x.HasExited) { $x.Kill() } } catch { } }
    }
}
'@
    $r = Invoke-ChildTestFile -Name 'testcase-semantics' -Content $content -Env @{ WMUX_E2E_TEST_TIMEOUT_SEC = '1'; WMUX_E2E_ATTEMPT = '2' }
    Assert-Equal 0 $r.ExitCode "child stderr: $($r.Stderr)"
    $byName = @{}
    foreach ($rec in $r.Results) { $byName[$rec.name] = $rec }
    Assert-Equal 7 $r.Results.Count "seven results recorded; stdout: $($r.Stdout)"
    Assert-Equal 'timeout' $byName['watchdog spares removed processes'].kind
    Assert-Match 'WATCHDOG spared=True killed=True' $r.Stdout 'the watchdog kills registered processes and spares removed ones'
    Assert-Equal 'failed' $byName['fails first'].status
    Assert-Equal 'assertion' $byName['fails first'].kind
    Assert-Match 'deliberate -- Assert-Equal: expected 1, got 2' $byName['fails first'].message
    Assert-Equal 'passed' $byName['runs after a failure'].status
    Assert-Equal 'skipped' $byName['skips'].status
    Assert-Equal 'not applicable here' $byName['skips'].message
    Assert-Equal 'failed' $byName['plain error'].status
    Assert-Equal 'error' $byName['plain error'].kind
    Assert-Equal 'failed' $byName['overruns the watchdog'].status
    Assert-Equal 'timeout' $byName['overruns the watchdog'].kind
    Assert-Match 'exceeded the 1s per-test timeout' $byName['overruns the watchdog'].message
    $focus = $byName['simulated focus theft']
    if ($focus.status -ne 'skipped') {
        Assert-Equal 'failed' $focus.status
        Assert-Equal 'focus' $focus.kind
        Assert-Match '^focus stolen by test instance' $focus.message
    }
    Assert-Equal 'selftest/testcase-semantics.e2e.ps1' $byName['runs after a failure'].file
    Assert-Equal 2 $byName['runs after a failure'].attempt
    Assert-True ($byName['runs after a failure'].duration_ms -ge 0)
}

Test-Case 'coverage.ps1 joins header tags with the matrix' {
    $dir = Join-Path $script:TempRoot 'coverage'
    $suites = Join-Path $dir 'suites'
    $null = Write-TempFile 'coverage\suites\core\W2-1.e2e.ps1' "# wp: W2-1`n# covers: core-a, core-b`n# covers: core-c`n# manual: core-d `"pointer-only; dogfood checklist`"`nImport-Module nothing`n# covers: core-e`n"
    $null = Write-TempFile 'coverage\suites\cli\W1-2.e2e.ps1' "#Requires -Version 7.0`n# wp: W1-2`n#covers: cli-x core-a, ghost-id`n# Covers: core-done-id`n"
    $null = Write-TempFile 'coverage\suites\_quarantine\flaky.e2e.ps1' "# covers: cli-y`n"
    $null = Write-TempFile 'coverage\suites\smoke\smoke.e2e.ps1' "# wp: W0-B`n# covers:`n"
    $matrix = Write-TempFile 'coverage\matrix.csv' (@(
            '"area","id","name","status","analyst","scope","imp","effort"'
            '"core","core-a","A","partial","partial","local-core","critical","L"'
            '"core","core-b","B","missing","missing","local-core","high","M"'
            '"core","core-c","C","missing","missing","local-extended","low","S"'
            '"core","core-d","D","missing","missing","local-core","critical","M"'
            '"core","core-e","E","partial","partial","local-core","critical","M"'
            '"core","core-done-id","Done","done","done","local-core","high","S"'
            '"cli","cli-x","X","missing","missing","local-core","medium","S"'
            '"cli","cli-y","Y","missing","missing","local-core","critical","S"'
            '"cli","cli-z","Z","missing","missing","local-core","low","S"'
            '"cli","cli-cloud","Cloud","missing","missing","cloud-or-account","low","S"'
        ) -join "`n")
    $coverage = Join-Path $script:E2eRoot 'coverage.ps1'
    $report = & $coverage -SuitesRoot $suites -Matrix $matrix -PassThru -Quiet
    Assert-Equal 8 $report.totals.in_scope
    Assert-Equal 5 $report.totals.covered 'core-a, core-b, core-c, cli-x and the quarantined cli-y'
    Assert-Equal 1 $report.totals.waived
    Assert-Equal 2 $report.totals.uncovered 'core-e (tag below the header does not count) and cli-z'
    Assert-Equal 'core-e' (@($report.uncovered_critical.id) -join ',')
    Assert-Equal 'ghost-id' (@($report.stale_tags.id) -join ',')
    Assert-Equal 'core-done-id' (@($report.out_of_scope_tags.id) -join ',')
    Assert-Equal 'cli-y' (@($report.quarantined_ids) -join ',')
    $core = @($report.areas | Where-Object area -EQ 'core')[0]
    Assert-Equal 5 $core.in_scope
    Assert-Equal 3 $core.covered
    Assert-Equal 1 $core.waived
    Assert-Equal 1 $core.uncovered
    Assert-Equal 1 $core.critical_uncovered
    $cli = @($report.areas | Where-Object area -EQ 'cli')[0]
    Assert-Equal 3 $cli.in_scope
    Assert-Equal 2 $cli.covered
    $coreA = @($report.covered | Where-Object id -EQ 'core-a')[0]
    Assert-Equal 2 @($coreA.files).Count 'core-a is covered by two files'
    $waived = @($report.waived | Where-Object id -EQ 'core-d')[0]
    Assert-Equal 'pointer-only; dogfood checklist' @($waived.reasons)[0]

    $tags = @(& $coverage -SuitesRoot $suites -TagsOnly -PassThru -Quiet)
    Assert-Equal 4 $tags.Count
    $w21 = @($tags | Where-Object RelativePath -EQ 'core/W2-1.e2e.ps1')[0]
    Assert-Equal 'W2-1' $w21.Wp
    Assert-Equal 'core-a,core-b,core-c' (@($w21.Covers) -join ',')
    $w12 = @($tags | Where-Object RelativePath -EQ 'cli/W1-2.e2e.ps1')[0]
    Assert-Equal 'W1-2' $w12.Wp 'a #Requires line does not end the header'
    Assert-Equal 'cli-x,core-a,ghost-id,core-done-id' (@($w12.Covers) -join ',')

    $ids = Write-TempFile 'coverage\ids.json' '["core-a","core-e","cli-z","panels-q"]'
    $byIds = & $coverage -SuitesRoot $suites -InScopeIds $ids -Matrix (Join-Path $dir 'no-such-matrix.csv') -PassThru -Quiet
    Assert-Equal 4 $byIds.totals.in_scope
    Assert-Equal 1 $byIds.totals.covered
    Assert-True ((@($byIds.areas.area) -join ',') -eq 'cli,core,panels') "areas from id prefixes: $(@($byIds.areas.area) -join ',')"

    $json = Join-Path $dir 'out\coverage.json'
    $null = & $coverage -SuitesRoot $suites -Matrix $matrix -Json $json -Quiet
    Assert-Equal 'wmux-e2e-coverage/1' (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json).schema
    $global:LASTEXITCODE = 0
    $null = & $coverage -SuitesRoot $suites -Matrix $matrix -Quiet -FailOnStale
    Assert-Equal 1 $global:LASTEXITCODE '-FailOnStale exits 1 on stale tags'
    $global:LASTEXITCODE = 0
    $null = & $coverage -SuitesRoot $suites -Matrix (Join-Path $dir 'no-such-matrix.csv') -Quiet 6>$null
    Assert-Equal 2 $global:LASTEXITCODE 'a missing explicit matrix exits 2'
    $global:LASTEXITCODE = 0
}

$script:RunnerSuite = Join-Path $script:TempRoot 'runner\suites'
function New-RunnerSuite {
    if (Test-Path -LiteralPath $script:RunnerSuite) { return }
    $import = "Import-Module '$($script:ModulePath)' -Force"
    $null = Write-TempFile 'runner\suites\a\pass.e2e.ps1' "# wp: T-1`n# covers: core-a`n$import`nTest-Case 'passes' { Assert-Equal 1 1 }`nTest-Case 'skips' { throw [WmuxSkipException]::new('not today') }`n"
    $null = Write-TempFile 'runner\suites\a\fail.e2e.ps1' "$import`nTest-Case 'fails' { Assert-Equal 1 2 'one is not two' }`nTest-Case 'still runs after a failure' { Assert-True `$true }`n"
    $null = Write-TempFile 'runner\suites\b\flaky.e2e.ps1' "$import`nTest-Case 'flaky' { Assert-Equal '2' `$env:WMUX_E2E_ATTEMPT 'passes on retry only' }`n"
    $null = Write-TempFile 'runner\suites\c\hang.e2e.ps1' "$import`nTest-Case 'hangs' { Start-Sleep -Seconds 300 }`n"
    $null = Write-TempFile 'runner\suites\_quarantine\q.e2e.ps1' "$import`nTest-Case 'quarantined' { Assert-True `$true }`n"
}

Test-Case 'run.ps1 retries, marks flaky files, skips quarantine and writes JSON + JUnit' {
    New-RunnerSuite
    $results = Join-Path $script:TempRoot 'runner\results1'
    $run = Join-Path $script:E2eRoot 'run.ps1'
    $r = Invoke-ChildPwsh -Arguments @('-File', $run, '-SuitesRoot', $script:RunnerSuite, '-ResultsDir', $results, '-Suite', 'a,b', '-Parallel', '3', '-TestTimeoutSec', '60')
    Assert-Equal 1 $r.ExitCode "a failing file makes the run fail. stdout:`n$($r.Stdout)`nstderr:`n$($r.Stderr)"
    $report = Get-Content -LiteralPath (Join-Path $results 'e2e.json') -Raw | ConvertFrom-Json
    Assert-Equal 'wmux-e2e-results/1' $report.schema
    Assert-Equal 3 $report.summary.files 'quarantine and c/ are not selected'
    Assert-Equal 1 $report.summary.flaky_files
    Assert-Equal 1 $report.summary.failed_files
    Assert-Equal 1 $report.summary.passed_files
    $tests = @{}
    foreach ($t in $report.tests) { $tests[$t.name] = $t }
    Assert-Equal 'passed' $tests['passes'].status
    Assert-Equal 'skipped' $tests['skips'].status
    Assert-Equal 'not today' $tests['skips'].message
    Assert-Equal 'failed' $tests['fails'].status
    Assert-Match 'one is not two' $tests['fails'].message
    Assert-Equal 'passed' $tests['still runs after a failure'].status
    Assert-Equal 'passed' $tests['flaky'].status
    Assert-Equal $true $tests['flaky'].flaky
    Assert-Equal 2 $tests['flaky'].attempt
    $failFile = @($report.files | Where-Object path -EQ 'a/fail.e2e.ps1')[0]
    Assert-Equal 2 @($failFile.attempts).Count 'a failed file is retried once'
    Assert-Equal 'failed' $failFile.status
    $passFile = @($report.files | Where-Object path -EQ 'a/pass.e2e.ps1')[0]
    Assert-Equal 'T-1' $passFile.wp
    Assert-Equal 'core-a' (@($passFile.covers) -join ',')
    Assert-True (Test-Path -LiteralPath (Join-Path $results 'logs\a__pass.attempt1.out.log')) 'per-attempt logs are kept'
    [xml]$junit = Get-Content -LiteralPath (Join-Path $results 'e2e.junit.xml') -Raw
    Assert-Equal '5' $junit.testsuites.tests
    Assert-Equal '1' $junit.testsuites.failures
    Assert-Equal '1' $junit.testsuites.skipped
    Assert-Equal 3 @($junit.testsuites.testsuite).Count
    $flakyCase = @($junit.SelectNodes('//testcase[@name="flaky"]'))[0]
    Assert-Equal 'true' $flakyCase.properties.property.value
}

Test-Case 'run.ps1 kills a hung file at its time budget and reports a timeout' {
    New-RunnerSuite
    $results = Join-Path $script:TempRoot 'runner\results2'
    $run = Join-Path $script:E2eRoot 'run.ps1'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-ChildPwsh -Arguments @('-File', $run, '-SuitesRoot', $script:RunnerSuite, '-ResultsDir', $results, '-Suite', 'c', '-NoRetry', '-TestTimeoutSec', '3')
    $clock.Stop()
    Assert-Equal 1 $r.ExitCode "stdout:`n$($r.Stdout)"
    Assert-True ($clock.Elapsed.TotalSeconds -lt 90) "the hung file was killed (took $($clock.Elapsed.TotalSeconds)s)"
    $report = Get-Content -LiteralPath (Join-Path $results 'e2e.json') -Raw | ConvertFrom-Json
    $file = @($report.files)[0]
    Assert-Equal 'timeout' $file.status
    Assert-Equal 1 @($file.attempts).Count '-NoRetry runs once'
    Assert-Equal '(file)' @($report.tests)[0].name
    Assert-Equal 'timeout' @($report.tests)[0].kind
    [xml]$junit = Get-Content -LiteralPath (Join-Path $results 'e2e.junit.xml') -Raw
    Assert-Equal '1' $junit.testsuites.errors
}

Test-Case 'run.ps1 lists quarantine on request and exits 2 when nothing matches' {
    New-RunnerSuite
    $run = Join-Path $script:E2eRoot 'run.ps1'
    $list = Invoke-ChildPwsh -Arguments @('-File', $run, '-SuitesRoot', $script:RunnerSuite, '-Quarantine', '-Suite', '_quarantine', '-List')
    Assert-Equal 0 $list.ExitCode $list.Stderr
    Assert-Match '_quarantine/q\.e2e\.ps1' $list.Stdout
    Assert-True (-not $list.Stdout.Contains('a/pass')) '-Suite still applies with -Quarantine'
    # Without -Quarantine the same selection matches nothing: excluded by default, exit code 2.
    $none = Invoke-ChildPwsh -Arguments @('-File', $run, '-SuitesRoot', $script:RunnerSuite, '-Suite', '_quarantine', '-ResultsDir', (Join-Path $script:TempRoot 'runner\results3'))
    Assert-Equal 2 $none.ExitCode "quarantine is skipped by default and an empty selection is a usage error. stdout: $($none.Stdout)"
    Assert-Match 'no test file matched' $none.Stdout
}

# ---------------------------------------------------------------------------
# Cleanup of the fake server and temporary files.
# ---------------------------------------------------------------------------

Stop-FakeServerProcess $script:FakeServer
Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
