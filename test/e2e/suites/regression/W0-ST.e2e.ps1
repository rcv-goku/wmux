# wp: W0-ST
# covers:
# Regression for the terminal teardown hang fixed in W0-ST (ruling D17, CCR W0-ST-1): closing a
# just-created workspace or tab used to hang the UI thread inside core_surface.deinit about once
# in 6-10 fast runs, because src/termio/Exec.zig cancelled the pty read thread with a single
# CancelIoEx that was lost when the thread was not inside ReadFile yet, and the join never
# returned. Each loop creates a terminal and closes it at once over the legacy pipe; a close
# that is not answered within 10 s is a hang. WMUX_W0ST_ITERATIONS sets the loop count (default
# 30 per case; the W0-ST proof ran 300 with -TestTimeoutSec raised), and -Build Release runs
# the same loops on a ReleaseFast build.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:Iterations = 30
if ($env:WMUX_W0ST_ITERATIONS) { $script:Iterations = [int]$env:WMUX_W0ST_ITERATIONS }
$script:NextId = 100

function Invoke-StressCommand {
    # One legacy request with a unique id; returns data, fails the test on ok:false or timeout.
    param(
        [Parameter(Mandatory, Position = 0)]$Instance,
        [Parameter(Mandatory, Position = 1)][string]$Cmd,
        [Parameter(Position = 2)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$What
    )
    $script:NextId++
    $id = $script:NextId
    $request = [ordered]@{ id = $id; cmd = $Cmd }
    if ($Arguments) { $request.args = $Arguments }
    $line = ConvertTo-Json -InputObject $request -Compress -Depth 10
    try {
        $reply = Invoke-WmuxRawLine $Instance $line -TimeoutSec 10 | ConvertFrom-Json
    } catch {
        $rpc = $_.Exception
        while ($rpc -and $rpc -isnot [WmuxRpcError]) { $rpc = $rpc.InnerException }
        if ($rpc -and $rpc.Code -eq 'harness_timeout') {
            # Kill the hung instance at once: the failure snapshot would only skip the capture of
            # a hung window (IsHungAppWindow) and record why, so nothing useful is lost.
            $null = & taskkill.exe /T /F /PID $Instance.Pid 2>&1
            Assert-True $false "$What got no reply within 10 s (UI thread hang)"
        }
        throw
    }
    Assert-Equal $id $reply.id "reply id for $What"
    Assert-True $reply.ok "$What failed: $($reply.error)"
    return $reply.data
}

function Write-StressTimes {
    param([string]$Label, [System.Collections.Generic.List[double]]$Times)
    $sorted = @($Times | Sort-Object)
    $p50 = $sorted[[int][Math]::Floor(($sorted.Count - 1) * 0.5)]
    $max = $sorted[-1]
    Write-Host ("{0}: {1} closes, p50 {2:N0} ms, max {3:N0} ms" -f $Label, $sorted.Count, $p50, $max)
}

Test-Case 'regression: closing a just-created workspace never hangs' {
    $w = Start-WmuxInstance
    try {
        $times = [System.Collections.Generic.List[double]]::new()
        for ($i = 1; $i -le $script:Iterations; $i++) {
            $created = Invoke-StressCommand $w 'workspace-new' @{ name = "w0st-$i" } -What "workspace-new #$i"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-StressCommand $w 'workspace-close' @{ index = $created.index } -What "workspace-close #$i"
            $times.Add($sw.Elapsed.TotalMilliseconds)
        }
        Write-StressTimes 'workspace-close' $times
        $list = @(Invoke-StressCommand $w 'workspace-list' -What 'final workspace-list')
        Assert-Equal 1 $list.Count 'every created workspace was closed again'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'regression: closing a just-created tab never hangs' {
    $w = Start-WmuxInstance
    try {
        $times = [System.Collections.Generic.List[double]]::new()
        $before = @(Invoke-StressCommand $w 'tab-list' -What 'initial tab-list').Count
        for ($i = 1; $i -le $script:Iterations; $i++) {
            $tab = Invoke-StressCommand $w 'tab-new' -What "tab-new #$i"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-StressCommand $w 'tab-close' @{ index = $tab.index } -What "tab-close #$i"
            $times.Add($sw.Elapsed.TotalMilliseconds)
        }
        Write-StressTimes 'tab-close' $times
        $after = @(Invoke-StressCommand $w 'tab-list' -What 'final tab-list').Count
        Assert-Equal $before $after 'every created tab was closed again'
    } finally { Stop-WmuxInstance $w }
}
