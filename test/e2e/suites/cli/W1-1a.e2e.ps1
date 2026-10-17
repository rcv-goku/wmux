# wp: W1-1a
# covers: cli-v2-json-envelope, cli-handle-refs-and-indexes, cli-v2-capabilities-and-naming, cli-socket-admission-deadlines, cli-socket-path-resolution
# budget-sec: 1500
# The v2 control plane (ARCHITECTURE.md ADR-3): the instance marker and the computed control pipe
# name, system.ping/system.capabilities, the cmux v2 envelope and its pre-dispatch errors, handle
# routing (UUID, ref, display index; fail closed), admission (64 live, 64 pending, then
# overloaded pool_saturated) and the polling rate limit, the legacy JSON adapter on wmux-ipc-<pid>
# (the whole W0-B2 legacy-compat suite rerun over that pipe; the gate runs it over the control
# pipe), the wmux.debug.* core hooks, single instance (a second launch forwards app.launch) and
# CLI discovery through STATE\run\instance.json.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:Mod = Get-Module WmuxTest
$script:Utf8 = [Text.UTF8Encoding]::new($false)

if (-not ('W1aFakePipe' -as [type])) {
    # A one-connection v2 stand-in server: answers every line with {pong:true}, echoing the id.
    Add-Type -TypeDefinition @'
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
public static class W1aFakePipe {
    public static Task<int> ServePings(string bareName, int connectTimeoutMs) {
        var srv = new NamedPipeServerStream(bareName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        return Task.Run(async () => {
            int served = 0;
            using (srv) {
                using (var cts = new CancellationTokenSource(connectTimeoutMs)) {
                    try { await srv.WaitForConnectionAsync(cts.Token); } catch (System.OperationCanceledException) { return 0; }
                }
                var utf8 = new UTF8Encoding(false);
                var r = new StreamReader(srv, utf8, false, 4096, true);
                var w = new StreamWriter(srv, utf8, 4096, true);
                w.AutoFlush = true;
                w.NewLine = "\n";
                string line;
                while ((line = await r.ReadLineAsync()) != null) {
                    var m = Regex.Match(line, "\"id\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|-?\\d+)");
                    var id = m.Success ? m.Groups[1].Value : "null";
                    try { w.WriteLine("{\"id\":" + id + ",\"ok\":true,\"result\":{\"pong\":true}}"); } catch (IOException) { break; }
                    served++;
                }
            }
            return served;
        });
    }
}
'@
}

function ConvertTo-BarePipe([string]$Path) {
    return ($Path -replace '^\\\\\.\\pipe\\', '')
}

function Open-RawPipe {
    # A raw client of a named pipe (newline-framed UTF-8), for pipelining and admission tests.
    param([Parameter(Mandatory)][string]$Path, [int]$ConnectMs = 10000)
    $s = [System.IO.Pipes.NamedPipeClientStream]::new('.', (ConvertTo-BarePipe $Path), [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    $s.Connect($ConnectMs)
    $reader = [IO.StreamReader]::new($s, $script:Utf8, $false, 4096, $true)
    $writer = [IO.StreamWriter]::new($s, $script:Utf8, 4096, $true)
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"
    return [pscustomobject]@{ Stream = $s; Reader = $reader; Writer = $writer; Pending = $null }
}

function Read-RawLine {
    # The next line, or $null after -TimeoutMs (the pending read is kept for the next call).
    param([Parameter(Mandatory)]$Client, [int]$TimeoutMs = 10000)
    if ($null -eq $Client.Pending) { $Client.Pending = $Client.Reader.ReadLineAsync() }
    if (-not $Client.Pending.Wait($TimeoutMs)) { return $null }
    $line = $Client.Pending.Result
    $Client.Pending = $null
    return $line
}

function Close-RawPipe($Client) {
    try { $Client.Writer.Dispose() } catch { }
    try { $Client.Reader.Dispose() } catch { }
    try { $Client.Stream.Dispose() } catch { }
}

function Get-Marker($Instance) {
    return [IO.File]::ReadAllText((Join-Path $Instance.StateDir 'run\instance.json')) | ConvertFrom-Json
}

function Get-Workspaces($Instance) {
    $layout = Invoke-WmuxRpc $Instance 'wmux.debug.layout'
    return @($layout.windows[0].workspaces)
}

Test-Case 'marker: STATE\run\instance.json names the computed control pipe; system.ping answers' {
    $w = Start-WmuxInstance
    try {
        $m = Get-Marker $w
        Assert-Equal 2 ([int]$m.protocol) 'marker protocol'
        Assert-Match '^\\\\\.\\pipe\\wmux-test-[0-9a-f]{8}-[0-9a-f]{8}-s\d+$' $m.pipe 'marker pipe = \\.\pipe\wmux-test-<id>-<sidhash8>-s<n>'
        Assert-Equal "\\.\pipe\$(& $script:Mod { param($c) Get-WmuxPipeName -Channel $c } $w.Channel)" $m.pipe 'the marker names the computed (D.2.6) control pipe'
        Assert-Equal ($m.pipe + '-launch') $m.launch_pipe 'launch pipe = control pipe + -launch'
        Assert-Equal $w.Pid ([int]$m.pid) 'marker pid'
        Assert-Equal $w.Channel $m.channel 'marker channel'
        Assert-Match '^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$' $m.boot_id 'boot_id is an uppercase UUID'
        # ConvertFrom-Json turns dates into DateTime: check the raw text.
        $raw = [IO.File]::ReadAllText((Join-Path $w.StateDir 'run\instance.json'))
        Assert-Match '"started_at": "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"' $raw 'started_at is RFC 3339 UTC'
        Assert-True ($m.exe -like '*wmux.exe') 'marker exe'
        Assert-Equal 'v2' $w.Protocol 'the harness speaks v2 to the instance'
        $pong = Invoke-WmuxRpc $w 'system.ping'
        Assert-Equal $true $pong.pong 'system.ping -> {pong:true}'
        Assert-True (@([WmuxTestHarness.Native]::ListPipes('wmux-ipc-')) -contains "wmux-ipc-$($w.Pid)") 'the legacy pipe wmux-ipc-<pid> is served too'
        $legacy = [WmuxTestHarness.PipeIO]::RoundTrip("wmux-ipc-$($w.Pid)", '{"id":41,"cmd":"workspace-list"}', 15000, $w.OutstandingIds) | ConvertFrom-Json
        Assert-Equal 41 $legacy.id 'the legacy pipe answers legacy JSON'
        Assert-Equal $true $legacy.ok
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'capabilities: sorted methods, wmux.debug.* listed in test mode, hidden bridges never' {
    $w = Start-WmuxInstance
    try {
        $c = Invoke-WmuxRpc $w 'system.capabilities'
        Assert-Equal 'cmux-socket' $c.protocol
        Assert-Equal 2 ([int]$c.version)
        Assert-Equal (Get-Marker $w).pipe $c.socket_path 'socket_path is the control pipe'
        Assert-Equal 'automation' $c.access_mode
        Assert-Equal 'windows' $c.capabilities.wmux.platform
        Assert-Equal $w.Channel $c.capabilities.wmux.channel
        $methods = @($c.methods)
        $sorted = [string[]]$methods.Clone()
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        Assert-Equal ($sorted -join ',') ($methods -join ',') 'methods are sorted (ordinal)'
        foreach ($name in 'system.ping', 'system.capabilities', 'wmux.debug.ready', 'wmux.debug.app.quit', 'wmux.debug.focus_state', 'wmux.debug.layout', 'wmux.debug.menu.list', 'wmux.debug.menu.invoke', 'wmux.debug.dialogs.list', 'wmux.debug.clipboard.get') {
            Assert-True ($methods -ccontains $name) "capabilities list $name"
        }
        Assert-True (-not ($methods -ccontains 'surface.read_text')) 'the hidden surface.read_text bridge is not listed'
        Assert-True (-not ($methods -ccontains 'app.launch')) 'app.launch is served on the launch pipe only'
        foreach ($m in $methods) { Assert-Match '^[a-z_]+(\.[a-z_]+)+$' $m "method name $m is <domain>.<verb>" }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'envelope: ids are echoed, pre-dispatch errors use cmux codes, pipelined replies stay in order' {
    $w = Start-WmuxInstance
    try {
        Assert-Equal '{"id":"1","ok":true,"result":{"pong":true}}' (Invoke-WmuxRawLine $w '{"id":"1","method":"system.ping","params":{}}') 'string id echoed byte for byte'
        $r = Invoke-WmuxRawLine $w '{"id":7,"method":" system.ping ","params":[1]}' | ConvertFrom-Json
        Assert-Equal 7 $r.id 'numeric id echoed as a number (method trimmed, non-object params = {})'
        Assert-Equal $true $r.result.pong
        $cases = @(
            @{ Line = '{"id":1,,}'; Code = 'parse_error'; Message = 'Invalid JSON'; Id = $null },
            @{ Line = '{"id":2,"params":{}}'; Code = 'invalid_request'; Message = 'Missing method'; Id = 2 },
            @{ Line = '{"id":3,"method":""}'; Code = 'invalid_request'; Message = 'Missing method'; Id = 3 },
            @{ Line = '{"id":"u","method":"nope.nope"}'; Code = 'method_not_found'; Message = 'Unknown method'; Id = 'u' },
            @{ Line = '{"id":4,"method":"wmux.debug.focus_state","params":{"workspaceId":"workspace:1"}}'; Code = 'invalid_params'; Message = "Unsupported parameter 'workspaceId'; use 'workspace_id'"; Id = 4 },
            @{ Line = '{"id":5,"method":"system.ping","params":{"surfaceID":"surface:1"}}'; Code = 'invalid_params'; Message = "Unsupported parameter 'surfaceID'; use 'surface_id'"; Id = 5 },
            @{ Line = '{"id":6,"method":"system.ping","params":{"caller":7}}'; Code = 'invalid_params'; Message = 'Invalid caller: expected an object'; Id = 6 }
        )
        foreach ($c in $cases) {
            $line = Invoke-WmuxRawLine $w $c.Line
            Assert-True ($line -notmatch "[`r`n]") 'one reply line'
            $e = $line | ConvertFrom-Json
            Assert-Equal $false $e.ok "ok:false for $($c.Line)"
            Assert-Equal $c.Code $e.error.code "code for $($c.Line)"
            Assert-Equal $c.Message $e.error.message "message for $($c.Line)"
            Assert-Equal $c.Id $e.id "id for $($c.Line)"
        }
        $client = Open-RawPipe $w.Pipe
        try {
            $client.Writer.Write('{"id":"a","method":"system.ping"}' + "`n" + '{"id":"b","method":"wmux.debug.focus_state"}' + "`n" + '{"id":"c","method":"system.capabilities"}' + "`n")
            $ids = foreach ($i in 1..3) { (Read-RawLine $client 15000 | ConvertFrom-Json).id }
            Assert-Equal 'a,b,c' ($ids -join ',') 'pipelined requests on one connection are answered in order'
        } finally { Close-RawPipe $client }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'handles: UUIDs, refs and display indexes route; unknown or mistyped selectors fail closed' {
    $w = Start-WmuxInstance
    try {
        $null = Invoke-WmuxRawLine $w '{"id":11,"cmd":"workspace-new","args":{"name":"w1a-two"}}'
        $wss = Get-Workspaces $w
        Assert-Equal 2 $wss.Count 'two workspaces'
        $second = $wss[1]
        Assert-Match '^workspace:\d+$' $second.workspace_ref
        foreach ($sel in @($second.workspace_id, $second.workspace_id.ToLowerInvariant(), $second.workspace_ref, 1)) {
            $r = Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; workspace_id = $sel }
            Assert-Equal $second.workspace_id $r.target.workspace_id "workspace_id=$sel routes to the second (display) workspace"
        }
        $first = Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; workspace_id = 0; window_id = 0 }
        Assert-Equal $wss[0].workspace_id $first.target.workspace_id 'index 0 in window 0'
        $tab = Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'tab'; surface_id = 'surface:1' }
        Assert-Equal 'surface:1' $tab.target.surface_ref 'surface ref routes'
        $e = Assert-Throws -Code 'not_found' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; workspace_id = 'workspace:999' } }
        Assert-Equal 'Workspace not found' $e.Message
        Assert-Equal 'workspace_id' $e.Data.selector
        $e = Assert-Throws -Code 'not_found' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'tab'; surface_id = '00000000-0000-4000-8000-000000000000' } }
        Assert-Equal 'Surface not found for the given surface_id' $e.Message
        $null = Assert-Throws -Code 'not_found' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; workspace_id = 'pane:1' } }
        $null = Assert-Throws -Code 'invalid_params' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; workspace_id = '  ' } }
        $null = Assert-Throws -Code 'not_found' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; workspace_id = 5 } }
        $e = Assert-Throws -Code 'invalid_params' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row'; tabId = 'tab:1' } }
        Assert-Equal "Unsupported parameter 'tabId'; use 'tab_id'" $e.Message
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'admission: 64 connections served, 64 wait, the rest overloaded pool_saturated; a waiter is served in turn' {
    $w = Start-WmuxInstance
    $live = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new()
    try {
        foreach ($i in 1..64) {
            $c = Open-RawPipe $w.Pipe
            $live.Add($c)
            $c.Writer.WriteLine("{`"id`":$i,`"method`":`"system.ping`"}")
            $reply = Read-RawLine $c 15000 | ConvertFrom-Json
            Assert-Equal $true $reply.result.pong "live connection $i is served"
        }
        foreach ($i in 1..64) {
            $c = Open-RawPipe $w.Pipe
            $pending.Add($c)
            $c.Writer.WriteLine("{`"id`":$(1000 + $i),`"method`":`"system.ping`"}")
        }
        Assert-Equal $null (Read-RawLine $pending[0] 750) 'the 65th connection waits for a slot (pending)'
        $over = foreach ($i in 1..6) {
            $c = Open-RawPipe $w.Pipe
            try { Read-RawLine $c 15000 } finally { Close-RawPipe $c }
        }
        foreach ($line in $over) {
            $e = $line | ConvertFrom-Json
            Assert-Equal 'overloaded' $e.error.code 'connections past 64 live + 64 pending are answered overloaded'
            Assert-Equal 'pool_saturated' $e.error.data.reason
            Assert-Equal $true $e.error.data.retryable
            Assert-True ([int]$e.error.data.retry_after_ms -gt 0) 'retry_after_ms'
        }
        # FIFO: the oldest waiter gets the freed slot.
        Close-RawPipe $live[0]
        $live.RemoveAt(0)
        $served = Read-RawLine $pending[0] 15000 | ConvertFrom-Json
        Assert-Equal 1001 $served.id 'the first pending connection is served once a live one leaves'
        Assert-Equal $null (Read-RawLine $pending[1] 500) 'the second one still waits'
    } finally {
        foreach ($c in $live) { Close-RawPipe $c }
        foreach ($c in $pending) { Close-RawPipe $c }
        Stop-WmuxInstance $w
    }
}

Test-Case 'admission: a burst of polling calls on one connection is rate_limited with retry_after_ms' {
    $w = Start-WmuxInstance
    try {
        $c = Open-RawPipe $w.Pipe
        try {
            $limited = $null
            foreach ($i in 1..20) {
                $c.Writer.WriteLine("{`"id`":$i,`"method`":`"surface.read_text`",`"params`":{}}")
                $r = Read-RawLine $c 15000 | ConvertFrom-Json
                if (-not $r.ok -and $r.error.code -eq 'rate_limited') { $limited = $r; break }
            }
            Assert-True ($null -ne $limited) 'a tight loop of polling requests gets rate_limited'
            Assert-True ([int]$limited.error.data.retry_after_ms -gt 0) 'rate_limited carries retry_after_ms'
            $c.Writer.WriteLine('{"id":"np","method":"system.ping"}')
            Assert-Equal $true (Read-RawLine $c 15000 | ConvertFrom-Json).result.pong 'non-polling methods are not limited'
        } finally { Close-RawPipe $c }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'legacy: the W0-B2 legacy-compat suite passes over the legacy pipe wmux-ipc-<pid>' {
    # The unchanged suite runs in a child pwsh from a scratch copy of its tree whose WmuxTest.psm1
    # is a shim: the real harness, with Invoke-WmuxRawLine sending every raw line to the
    # instance's legacy pipe instead of the control pipe (where the gate runs the suite).
    $e2e = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $repo = [IO.Path]::GetFullPath((Join-Path $e2e '..\..'))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("wmux-w1a-legacy-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $tree = Join-Path $tmp 'test\e2e'
    try {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $tree 'suites\legacy'), (Join-Path $tree 'fixtures'), (Join-Path $tmp 'src\apprt\win32\rpc\compat')
        Copy-Item -LiteralPath (Join-Path $e2e 'suites\legacy\legacy-compat.e2e.ps1') -Destination (Join-Path $tree 'suites\legacy\legacy-compat.e2e.ps1')
        Copy-Item -LiteralPath (Join-Path $e2e 'fixtures\legacy') -Destination (Join-Path $tree 'fixtures') -Recurse
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $e2e 'fixtures') -File) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $tree 'fixtures') }
        Copy-Item -LiteralPath (Join-Path $repo 'src\apprt\win32\rpc\compat\legacy_json.zig') -Destination (Join-Path $tmp 'src\apprt\win32\rpc\compat\legacy_json.zig')
        $routed = Join-Path $tmp 'routed.txt'
        $real = (Join-Path $e2e 'WmuxTest.psm1').Replace("'", "''")
        $shim = @"
`$inner = Import-Module '$real' -Force -PassThru
function Invoke-WmuxRawLine {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]`$Instance, [Parameter(Mandatory, Position = 1)][string]`$Line, [double]`$TimeoutSec = 15)
    `$pipe = '\\.\pipe\wmux-ipc-' + `$Instance.Pid
    [IO.File]::AppendAllText('$($routed.Replace("'", "''"))', "`$pipe``n")
    & `$inner { param(`$i, `$l, `$t, `$p) Invoke-WmuxPipeLine -Instance `$i -Line `$l -TimeoutSec `$t -Method 'raw line' -Pipe `$p } `$Instance `$Line `$TimeoutSec `$pipe
}
Export-ModuleMember -Function (@((Get-Command -Module `$inner.Name).Name | Where-Object { `$_ -ne 'Invoke-WmuxRawLine' }) + 'Invoke-WmuxRawLine')
"@
        [IO.File]::WriteAllText((Join-Path $tree 'WmuxTest.psm1'), $shim, $script:Utf8)
        $results = Join-Path $tmp 'results.jsonl'
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $tree 'suites\legacy\legacy-compat.e2e.ps1'))) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment['WMUX_E2E_RESULTS'] = $results
        $psi.Environment['WMUX_E2E_ARTIFACTS'] = Join-Path $tmp 'artifacts'
        $psi.Environment['WMUX_E2E_FILE'] = 'legacy/legacy-compat.e2e.ps1 (wmux-ipc-<pid>)'
        $null = $psi.Environment.Remove('WMUX_E2E_FILTER')
        if (-not $psi.Environment.ContainsKey('WMUX_E2E_EXE')) {
            $exe = & $script:Mod { Resolve-WmuxExe }
            $psi.Environment['WMUX_E2E_EXE'] = $exe
        }
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(1200000)) { try { $p.Kill($true) } catch { }; throw 'legacy-compat over wmux-ipc-<pid> did not finish within 20 min' }
        $p.WaitForExit()
        $null = $out.Wait(5000)
        Write-Host $out.Result
        $records = @(Get-Content -LiteralPath $results -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($records.Count -ge 9) "legacy-compat reported its Test-Cases ($($records.Count)): $($err.Result)"
        $lines = @(Get-Content -LiteralPath $routed -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\\\\\.\\pipe\\wmux-ipc-\d+$' })
        Assert-True ($lines.Count -ge 30) "the suite's raw lines went to wmux-ipc-<pid> ($($lines.Count) routed)"
        $bad = @($records | Where-Object { $_.status -ne 'passed' })
        Assert-Equal 0 $bad.Count ("every legacy-compat Test-Case passes over the legacy pipe: " + (($bad | ForEach-Object { "$($_.name): $($_.status) $($_.message)" }) -join ' | '))
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'debug: menu.list returns the workspace_row items; menu.invoke Rename opens the rename edit' {
    $w = Start-WmuxInstance
    try {
        $menu = Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'workspace_row' }
        $titles = @($menu.items | ForEach-Object { $_.title })
        foreach ($t in 'Rename Workspace', 'Edit Description', 'Close Workspace', 'New Workspace') {
            Assert-True ($titles -ccontains $t) "workspace_row menu lists '$t' (got $($titles -join ', '))"
        }
        Assert-True (@($menu.items | Where-Object { $_.separator_before }).Count -ge 1) 'group separators are reported'
        # Startup focus changes are over once the shell prompt shows.
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^WMUX>' -TimeoutSec 30
        $before = Invoke-WmuxRpc $w 'wmux.debug.focus_state'
        Assert-Equal $false $before.edit 'no rename edit at start'
        $r = Invoke-WmuxRpc $w 'wmux.debug.menu.invoke' @{ site = 'workspace_row'; title = 'Rename' }
        Assert-Equal 'Rename Workspace' $r.title
        $st = Wait-WmuxCondition -TimeoutSec 10 { $s = Invoke-WmuxRpc $w 'wmux.debug.focus_state'; if ($s.edit) { $s } }
        Assert-Equal 'workspace' $st.edit_target 'the workspace rename edit is open'
        $null = Invoke-WmuxRpc $w 'wmux.debug.key' @{ key = 'escape' }
        $null = Wait-WmuxCondition -TimeoutSec 10 { -not (Invoke-WmuxRpc $w 'wmux.debug.focus_state').edit }
        $null = Assert-Throws -Code 'not_found' { Invoke-WmuxRpc $w 'wmux.debug.menu.invoke' @{ site = 'workspace_row'; title = 'No Such Item' } }
        $null = Assert-Throws -Code 'invalid_params' { Invoke-WmuxRpc $w 'wmux.debug.menu.list' @{ site = 'nowhere' } }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'debug: ready, focus_state, layout, clipboard, type, key, timers, dialogs and the sinks' {
    $w = Start-WmuxInstance
    try {
        $ready = Invoke-WmuxRpc $w 'wmux.debug.ready'
        Assert-Equal $true $ready.ready
        $fs = Invoke-WmuxRpc $w 'wmux.debug.focus_state'
        Assert-Match '^window:\d+$' $fs.window_ref
        Assert-Equal 0 ([int]$fs.workspace_index)
        Assert-Equal 'terminal' $fs.surface_type
        $layout = Invoke-WmuxRpc $w 'wmux.debug.layout'
        Assert-Equal $fs.surface_id $layout.windows[0].workspaces[0].panes[0].surfaces[0].surface_id 'layout and focus_state agree'
        $null = Invoke-WmuxRpc $w 'wmux.debug.clipboard.set' @{ text = 'w1a clip ✓' }
        Assert-Equal 'w1a clip ✓' (Invoke-WmuxRpc $w 'wmux.debug.clipboard.get').text 'the fake clipboard round-trips'
        $null = Wait-WmuxScreen $w -Surface @{} -Pattern '(?m)^WMUX>' -TimeoutSec 30
        $t = Invoke-WmuxRpc $w 'wmux.debug.type' @{ text = 'echo W1A-TYPED' }
        Assert-Equal 'terminal' $t.target
        $null = Invoke-WmuxRpc $w 'wmux.debug.key' @{ key = 'enter' }
        $null = Wait-WmuxScreen $w -Surface $fs.surface_id -Pattern '(?m)^W1A-TYPED\s*$' -TimeoutSec 30
        Assert-True (@((Invoke-WmuxRpc $w 'wmux.debug.timers').timers).Count -ge 1) 'app.timers are listed'
        Assert-Equal 0 @((Invoke-WmuxRpc $w 'wmux.debug.dialogs.list').dialogs).Count 'no message box was shown'
        $q = Invoke-WmuxRpc $w 'wmux.debug.dialogs.answer' @{ answer = 'yes' }
        Assert-Equal 6 ([int]$q.answer)
        $null = Invoke-WmuxRpc $w 'wmux.debug.external_open.list'
        $null = Invoke-WmuxRpc $w 'wmux.debug.sounds.list'
        $null = Assert-Throws -Code 'invalid_params' { Invoke-WmuxRpc $w 'wmux.debug.key' @{ key = 'hyper+q' } }
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'single instance: a second launch with a folder path forwards app.launch open and exits 0' {
    $w = Start-WmuxInstance
    try {
        $folder = Join-Path $w.Root 'launch-target'
        $null = New-Item -ItemType Directory -Force -Path $folder
        $env2 = & $script:Mod { param($i) Get-WmuxCliEnvironment -Instance $i } $w
        $psi = [Diagnostics.ProcessStartInfo]::new($w.Exe)
        foreach ($a in @('--config-default-files=false', "--config-file=$(Join-Path $w.Root 'ghostty.conf')", $folder)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment.Clear()
        foreach ($k in $env2.Keys) { $psi.Environment[$k] = $env2[$k] }
        $p = [Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync()
        $null = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { try { $p.Kill($true) } catch { }; throw 'the second wmux.exe did not exit within 60 s' }
        $p.WaitForExit()
        Assert-Equal 0 $p.ExitCode "the second launch exits 0 after the handoff: $($err.Result)"
        $layout = Wait-WmuxCondition -TimeoutSec 20 { $l = Invoke-WmuxRpc $w 'wmux.debug.layout'; if ([int]$l.launch_count -ge 1) { $l } }
        Assert-Equal 'open' @($layout.launches)[-1].intent 'app.launch {intent:"open"} reached the instance'
        $null = Wait-WmuxCondition -TimeoutSec 20 {
            @((Invoke-WmuxRpc $w 'wmux.debug.layout').windows[0].workspaces | Where-Object { $_.cwd -and ([IO.Path]::GetFullPath($_.cwd) -eq [IO.Path]::GetFullPath($folder)) }).Count -eq 1
        }
        Assert-True (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) 'the second process is gone'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'cli: cli\cmux.exe with no socket environment finds the instance through instance.json' {
    $w = Start-WmuxInstance
    try {
        if (-not (Test-Path -LiteralPath $w.CliExe -PathType Leaf)) { throw [WmuxSkipException]::new("cli\cmux.exe not built at $($w.CliExe)") }
        $noSocket = @{ WMUX_SOCKET_PATH = $null; CMUX_SOCKET_PATH = $null; CMUX_SOCKET = $null; GHOSTTY_PID = $null }
        $r = Invoke-WmuxCli $w @('ping') -Env $noSocket
        Assert-Equal 0 $r.ExitCode "cmux ping through the marker: $($r.Stderr)"
        Assert-True ($r.Stderr -notmatch 'unavailable') "the marker's pipe is the expected default (no fallback note): $($r.Stderr)"
        # The marker is consulted before the computed default: point it at an -alt- name served by
        # a stand-in pipe of this test; the CLI must pick it over the live default and say so.
        $marker = Join-Path $w.StateDir 'run\instance.json'
        $saved = [IO.File]::ReadAllText($marker)
        $alt = (Get-Marker $w).pipe + '-alt-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $served = [W1aFakePipe]::ServePings((ConvertTo-BarePipe $alt), 30000)
        try {
            $m = $saved | ConvertFrom-Json
            $m.pipe = $alt
            $m.launch_pipe = $null
            [IO.File]::WriteAllText($marker, ($m | ConvertTo-Json -Depth 8), $script:Utf8)
            $r = Invoke-WmuxCli $w @('ping') -Env $noSocket
            Assert-Equal 0 $r.ExitCode "cmux ping through the rewritten marker: $($r.Stderr)"
            Assert-True ($served.Wait(15000)) 'the stand-in pipe named by the marker was used'
            Assert-True ($served.Result -ge 1) "the stand-in pipe answered the ping ($($served.Result) line(s))"
            Assert-True ($r.Stderr.Contains("is unavailable; using $alt.")) "the CLI took the marker's pipe over the default: $($r.Stderr)"
        } finally { [IO.File]::WriteAllText($marker, $saved, $script:Utf8) }
    } finally { Stop-WmuxInstance $w }
}
