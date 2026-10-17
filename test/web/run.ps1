#requires -Version 7.0
<#
.SYNOPSIS
    Runs the wmux web panel suites (test/web/suites/*.test.html) in a headless
    Chromium-family browser and reports the results.

.DESCRIPTION
    Serves the repository over a loopback-only static HTTP server
    (System.Net.HttpListener on http://127.0.0.1:<free port>/), opens each suite
    page with --headless=new --dump-dom in a fresh temporary profile, reads the
    <pre id="wmux-test-results"> JSON block from the dumped DOM, prints a summary
    and writes test-results/web.json. Needs no Node.

    Exit codes: 0 every suite passed; 1 a suite failed, timed out or produced no
    results block; 2 setup error (no browser, unknown suite, server failure).

.PARAMETER Suite
    Suite names (file name without .test.html), e.g. -Suite bridge,about.
    Default: every suite under test/web/suites.

.PARAMETER Browser
    Path of the browser executable. Default: $env:WMUX_WEB_BROWSER, else
    Microsoft Edge on Windows (Program Files (x86), then Program Files), else the
    first of microsoft-edge, chromium, google-chrome, chrome-headless-shell on PATH.

.PARAMETER TimeoutSec
    Wall-clock limit per suite; the browser process tree is killed after it.

.PARAMETER VirtualTimeBudgetMs
    --virtual-time-budget for each page: virtual milliseconds the browser runs
    the page (timers fast-forward while it is idle) before dumping the DOM.

.PARAMETER OutFile
    Results JSON path. Default: <repo>/test-results/web.json.

.EXAMPLE
    pwsh test/web/run.ps1
.EXAMPLE
    pwsh test/web/run.ps1 -Suite bridge,about -Browser /usr/bin/chromium -TimeoutSec 60
#>
[CmdletBinding()]
param(
    [string[]] $Suite,
    [string] $Browser,
    [ValidateRange(1, 3600)] [int] $TimeoutSec = 120,
    [ValidateRange(1000, 3600000)] [int] $VirtualTimeBudgetMs = 60000,
    [string] $OutFile
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
$SuiteDir = Join-Path $PSScriptRoot 'suites'
$ResultsId = 'wmux-test-results'

class SetupError : System.Exception {
    SetupError([string] $message) : base($message) {}
}

function Find-Browser {
    param([string] $Explicit)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Explicit) { $candidates.Add($Explicit) }
    elseif ($env:WMUX_WEB_BROWSER) { $candidates.Add($env:WMUX_WEB_BROWSER) }
    else {
        if ($IsWindows) {
            foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
                if ($base) { $candidates.Add((Join-Path $base 'Microsoft\Edge\Application\msedge.exe')) }
            }
        }
        else {
            foreach ($name in @('microsoft-edge', 'microsoft-edge-stable', 'chromium', 'chromium-browser',
                    'google-chrome', 'google-chrome-stable', 'chrome-headless-shell')) {
                $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($cmd) { $candidates.Add($cmd.Source) }
            }
        }
    }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.Path]::GetFullPath($path) }
        $cmd = Get-Command $path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $tried = if ($candidates.Count -gt 0) { $candidates -join ', ' } else { 'microsoft-edge, chromium, google-chrome, chrome-headless-shell on PATH' }
    throw [SetupError]::new("No browser found (tried: $tried). Pass -Browser <path> or set WMUX_WEB_BROWSER.")
}

function Get-Suites {
    param([string[]] $Names)
    $all = @(Get-ChildItem -LiteralPath $SuiteDir -Filter '*.test.html' -File | Sort-Object Name |
            ForEach-Object { $_.Name -replace '\.test\.html$', '' })
    if ($all.Count -eq 0) { throw [SetupError]::new("No suites found in $SuiteDir") }
    if (-not $Names -or $Names.Count -eq 0) { return $all }
    $wanted = @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
            ForEach-Object { $_ -replace '\.test\.html$', '' } | Select-Object -Unique)
    $unknown = @($wanted | Where-Object { $all -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw [SetupError]::new("Unknown suite(s): $($unknown -join ', '). Available: $($all -join ', ')")
    }
    if ($wanted.Count -eq 0) { throw [SetupError]::new('-Suite names no suite') }
    return $wanted
}

# --------------------------------------------------------------------------
# Loopback static HTTP server
# --------------------------------------------------------------------------

$MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'
    '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
    '.map' = 'application/json; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'
    '.md' = 'text/markdown; charset=utf-8'; '.diff' = 'text/plain; charset=utf-8'
    '.patch' = 'text/plain; charset=utf-8'; '.xml' = 'application/xml; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
    '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.avif' = 'image/avif'; '.ico' = 'image/x-icon'
    '.bmp' = 'image/bmp'; '.woff' = 'font/woff'; '.woff2' = 'font/woff2'; '.ttf' = 'font/ttf'
    '.otf' = 'font/otf'; '.wasm' = 'application/wasm'; '.pdf' = 'application/pdf'
    '.mp3' = 'audio/mpeg'; '.wav' = 'audio/wav'; '.mp4' = 'video/mp4'; '.webm' = 'video/webm'
}

function Get-MimeType {
    param([string] $Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($MimeTypes.ContainsKey($ext)) { return $MimeTypes[$ext] }
    return 'application/octet-stream'
}

function Get-FreePort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $probe.Start()
        return ([System.Net.IPEndPoint] $probe.LocalEndpoint).Port
    }
    finally { $probe.Stop() }
}

function Start-StaticServer {
    # http://127.0.0.1:<port>/ first. Windows HTTP.sys may refuse that prefix to a
    # non-elevated user (no URL ACL); http://localhost:<port>/ is then tried,
    # which HTTP.sys also binds to loopback only.
    $lastError = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $port = Get-FreePort
        foreach ($hostName in @('127.0.0.1', 'localhost')) {
            $listener = [System.Net.HttpListener]::new()
            $prefix = "http://${hostName}:$port/"
            $listener.Prefixes.Add($prefix)
            try {
                $listener.Start()
                return [pscustomobject]@{
                    Listener    = $listener
                    BaseUrl     = $prefix
                    Port        = $port
                    AllowedHost = @("127.0.0.1:$port", "localhost:$port")
                    Pending     = $null
                    Requests    = 0
                    Errors      = 0
                }
            }
            catch {
                $lastError = $_
                $listener.Close()
            }
        }
    }
    throw [SetupError]::new("Could not start the loopback HTTP server: $($lastError.Exception.Message)")
}

function Stop-StaticServer {
    param($Server)
    if (-not $Server) { return }
    try { $Server.Listener.Stop() } catch { }
    try { $Server.Listener.Close() } catch { }
}

function Resolve-RequestPath {
    # Maps a URL path to a file under the repo root, or $null (404).
    param([string] $UrlPath)
    $decoded = [Uri]::UnescapeDataString($UrlPath)
    if ($decoded.Contains([char] 0) -or $decoded.Contains('\')) { return $null }
    $segments = @($decoded.Split('/') | Where-Object { $_ -ne '' })
    foreach ($segment in $segments) {
        # No traversal, no dot files or dot directories (.git), no drive or stream syntax.
        if ($segment.StartsWith('.') -or $segment.Contains(':')) { return $null }
    }
    if ($segments.Count -eq 0) { return $null }
    $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot ($segments -join [IO.Path]::DirectorySeparatorChar)))
    $rootWithSep = $RepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($rootWithSep, $comparison)) { return $null }
    if (-not [IO.File]::Exists($full)) { return $null }
    return $full
}

function Send-Response {
    param($Context, [int] $Status, [string] $ContentType, [byte[]] $Body, [bool] $HeadOnly)
    $res = $Context.Response
    try {
        $res.StatusCode = $Status
        $res.ContentType = $ContentType
        $res.Headers['Cache-Control'] = 'no-store'
        $res.Headers['X-Content-Type-Options'] = 'nosniff'
        $res.ContentLength64 = $Body.Length
        if (-not $HeadOnly -and $Body.Length -gt 0) { $res.OutputStream.Write($Body, 0, $Body.Length) }
    }
    catch { }
    finally {
        try { $res.Close() } catch { }
    }
}

function Invoke-StaticRequest {
    param($Server, $Context)
    $Server.Requests++
    $req = $Context.Request
    $text = { param($s) [Text.Encoding]::UTF8.GetBytes($s) }
    $remote = $req.RemoteEndPoint
    if ($null -eq $remote -or -not [System.Net.IPAddress]::IsLoopback($remote.Address)) {
        Send-Response $Context 403 'text/plain; charset=utf-8' (& $text 'loopback only') $false
        return
    }
    # DNS-rebinding guard: only our own loopback authority.
    $authority = $req.UserHostName
    if ($Server.AllowedHost -notcontains $authority) {
        Send-Response $Context 421 'text/plain; charset=utf-8' (& $text 'unexpected Host') $false
        return
    }
    $head = $req.HttpMethod -eq 'HEAD'
    if ($req.HttpMethod -ne 'GET' -and -not $head) {
        $Context.Response.Headers['Allow'] = 'GET, HEAD'
        Send-Response $Context 405 'text/plain; charset=utf-8' (& $text 'method not allowed') $false
        return
    }
    $path = Resolve-RequestPath $req.Url.AbsolutePath
    if (-not $path) {
        Send-Response $Context 404 'text/plain; charset=utf-8' (& $text 'not found') $head
        return
    }
    try { $bytes = [IO.File]::ReadAllBytes($path) }
    catch {
        Send-Response $Context 500 'text/plain; charset=utf-8' (& $text 'read failed') $head
        return
    }
    Send-Response $Context 200 (Get-MimeType $path) $bytes $head
}

function Step-StaticServer {
    # Serves the requests that arrive within $WaitMs. Returns after one request
    # or the wait, whichever comes first.
    param($Server, [int] $WaitMs)
    if (-not $Server.Pending) { $Server.Pending = $Server.Listener.GetContextAsync() }
    $done = $false
    try { $done = $Server.Pending.Wait($WaitMs) }
    catch { $Server.Pending = $null; return }
    if (-not $done) { return }
    $task = $Server.Pending
    $Server.Pending = $null
    if (-not $task.IsCompletedSuccessfully) { return }
    try { Invoke-StaticRequest $Server $task.Result }
    catch {
        # One bad request must not abort the run.
        $Server.Errors++
        try { $task.Result.Response.Abort() } catch { }
    }
}

# --------------------------------------------------------------------------
# Browser
# --------------------------------------------------------------------------

function Get-BrowserArguments {
    param([string] $ProfileDir, [int] $BudgetMs, [string] $Url)
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
            "--user-data-dir=$ProfileDir", '--disable-extensions', '--disable-sync',
            '--disable-background-networking', '--disable-component-update', '--no-proxy-server',
            '--mute-audio', '--hide-scrollbars', '--window-size=1280,900',
            "--virtual-time-budget=$BudgetMs")) { $list.Add($a) }
    # Edge on a work-joined Windows host signs every new profile in to the OS
    # account ("implicit sign-in"), so each suite would fetch tokens through the
    # account broker and call Graph, Office and Intune endpoints with the user's
    # identity, and a sign-in that needs interaction could open a broker window
    # outside the browser's process tree. msImplicitSignin turns that off; other
    # browsers ignore unknown feature names.
    $disabledFeatures = [System.Collections.Generic.List[string]]::new()
    $disabledFeatures.Add('msImplicitSignin')
    # Extra flags for unusual hosts, e.g. WMUX_WEB_BROWSER_ARGS=--no-sandbox in a
    # container without user namespaces. Split on whitespace. A repeated
    # --disable-features would replace ours, so its features are merged instead.
    $extra = [System.Collections.Generic.List[string]]::new()
    if ($env:WMUX_WEB_BROWSER_ARGS) {
        foreach ($a in ($env:WMUX_WEB_BROWSER_ARGS -split '\s+')) {
            if (-not $a) { continue }
            if ($a -match '^--disable-features=(.*)$') {
                foreach ($f in ($Matches[1] -split ',')) { if ($f -and -not $disabledFeatures.Contains($f)) { $disabledFeatures.Add($f) } }
            }
            else { $extra.Add($a) }
        }
    }
    $list.Add('--disable-features=' + ($disabledFeatures -join ','))
    foreach ($a in $extra) { $list.Add($a) }
    $list.Add('--dump-dom')
    $list.Add($Url)
    return $list
}

function New-TempProfile {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('wmux-web-' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($dir)
    return $dir
}

function Remove-TempProfile {
    # The browser can hold profile files for a moment after it exits (Windows).
    param([string] $Dir)
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-Path -LiteralPath $Dir)) { return $true }
        try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop; return $true }
        catch { Start-Sleep -Milliseconds 250 }
    }
    return -not (Test-Path -LiteralPath $Dir)
}

function Invoke-BrowserSuite {
    param($Server, [string] $BrowserPath, [string] $Url, [int] $LimitSec, [int] $BudgetMs, [System.Collections.Generic.List[string]] $Profiles)
    $profileDir = New-TempProfile
    $Profiles.Add($profileDir)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($BrowserPath)
    foreach ($a in (Get-BrowserArguments $profileDir $BudgetMs $Url)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void] $proc.Start()
    }
    catch {
        throw [SetupError]::new("Could not start the browser '$BrowserPath': $($_.Exception.Message)")
    }
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    try {
        while (-not $proc.HasExited) {
            if ($clock.Elapsed.TotalSeconds -ge $LimitSec) {
                $timedOut = $true
                try { $proc.Kill($true) } catch { }
                break
            }
            Step-StaticServer $Server 20
        }
        # Keep serving while the output drains (child processes may still fetch).
        while (-not ($stdout.IsCompleted -and $stderr.IsCompleted) -and $clock.Elapsed.TotalSeconds -lt $LimitSec + 10) {
            Step-StaticServer $Server 20
        }
        [void] $proc.WaitForExit(5000)
    }
    finally {
        if (-not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
    }
    $clock.Stop()
    $out = if ($stdout.IsCompletedSuccessfully) { $stdout.Result } else { '' }
    $err = if ($stderr.IsCompletedSuccessfully) { $stderr.Result } else { '' }
    $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    $proc.Dispose()
    if (Remove-TempProfile $profileDir) { [void] $Profiles.Remove($profileDir) }
    return [pscustomobject]@{
        Stdout     = $out
        Stderr     = $err
        ExitCode   = $exitCode
        TimedOut   = $timedOut
        DurationMs = [int] $clock.Elapsed.TotalMilliseconds
    }
}

function Read-ResultsBlock {
    # Returns @{ Results = <object or $null>; Problem = <string or $null> }.
    param([string] $Dom)
    $pattern = '<pre\b[^>]*\bid\s*=\s*"' + [regex]::Escape($ResultsId) + '"[^>]*>(?<body>.*?)</pre>'
    $match = [regex]::Match($Dom, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        $problem = if ([string]::IsNullOrWhiteSpace($Dom)) { 'the browser printed no DOM' } else { "no <pre id=`"$ResultsId`"> block in the dumped DOM" }
        return @{ Results = $null; Problem = $problem }
    }
    $body = [System.Net.WebUtility]::HtmlDecode($match.Groups['body'].Value).Trim()
    if ($body -eq '') {
        return @{ Results = $null; Problem = 'the results block is empty: the suite did not finish within the virtual time budget' }
    }
    try { $results = $body | ConvertFrom-Json -Depth 64 }
    catch { return @{ Results = $null; Problem = "the results block is not valid JSON: $($_.Exception.Message)" } }
    if ($null -eq $results -or $results -isnot [pscustomobject] -or -not ($results.PSObject.Properties.Name -contains 'tests')) {
        return @{ Results = $null; Problem = 'the results block has no "tests" list' }
    }
    return @{ Results = $results; Problem = $null }
}

function Get-Prop {
    param($Object, [string] $Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Get-Tail {
    param([string] $Text, [int] $Lines = 20)
    if (-not $Text) { return '' }
    $all = $Text -split "`r?`n"
    return (($all | Select-Object -Last $Lines) -join "`n")
}

function Write-SuiteReport {
    param($Record)
    $color = if ($Record.status -eq 'passed') { 'Green' } else { 'Red' }
    $label = switch ($Record.status) { 'passed' { 'PASS' } 'timeout' { 'TIME' } 'error' { 'ERR ' } default { 'FAIL' } }
    $counts = if ($null -ne $Record.total) { "$($Record.passed)/$($Record.total) passed" + $(if ($Record.skipped) { ", $($Record.skipped) skipped" } else { '' }) } else { 'no results' }
    $seconds = '{0:N1} s' -f ($Record.durationMs / 1000)
    Write-Host ('  {0}  {1,-16} {2,-22} {3}' -f $label, $Record.name, $counts, $seconds) -ForegroundColor $color
    if ($Record.reason) { Write-Host "        $($Record.reason)" -ForegroundColor Red }
    foreach ($t in @($Record.tests)) {
        if ((Get-Prop $t 'status') -ne 'failed') { continue }
        $err = Get-Prop $t 'error'
        Write-Host "        x $($t.name)" -ForegroundColor Red
        if ($err) { Write-Host "          $(Get-Prop $err 'message' '')" }
        foreach ($e in @(Get-Prop $t 'errors' @())) { Write-Host "          ! $(Get-Prop $e 'kind' 'error'): $(Get-Prop $e 'message' '')" }
    }
    foreach ($e in @($Record.errors)) {
        Write-Host "        ! $(Get-Prop $e 'kind' 'error'): $(Get-Prop $e 'message' '')" -ForegroundColor Red
    }
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

$profiles = [System.Collections.Generic.List[string]]::new()
$server = $null
$exitCode = 0
$started = Get-Date
try {
    $browserPath = Find-Browser $Browser
    $suites = @(Get-Suites $Suite)
    if (-not $OutFile) { $OutFile = Join-Path $RepoRoot 'test-results' 'web.json' }
    $server = Start-StaticServer
    Write-Host "wmux web tests: $($suites.Count) suite(s), browser $browserPath, server $($server.BaseUrl)"
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $suites) {
        $url = $server.BaseUrl + 'test/web/suites/' + [Uri]::EscapeDataString($name) + '.test.html'
        $run = Invoke-BrowserSuite $server $browserPath $url $TimeoutSec $VirtualTimeBudgetMs $profiles
        $parsed = Read-ResultsBlock $run.Stdout
        $results = $parsed.Results
        $record = [ordered]@{
            name = $name; url = $url; status = 'failed'; reason = $null
            durationMs = $run.DurationMs; exitCode = $run.ExitCode
            total = $null; passed = $null; failed = $null; skipped = $null
            userAgent = $null; tests = @(); errors = @(); stderrTail = $null
        }
        if ($results) {
            $record.total = [int] (Get-Prop $results 'total' 0)
            $record.passed = [int] (Get-Prop $results 'passed' 0)
            $record.failed = [int] (Get-Prop $results 'failed' 0)
            $record.skipped = [int] (Get-Prop $results 'skipped' 0)
            $record.userAgent = Get-Prop $results 'userAgent'
            $record.tests = @(Get-Prop $results 'tests' @())
            $record.errors = @(Get-Prop $results 'errors' @())
        }
        if ($run.TimedOut) {
            $record.status = 'timeout'
            $record.reason = "the browser did not finish within $TimeoutSec s (killed)"
        }
        elseif (-not $results) {
            $record.status = 'error'
            $record.reason = $parsed.Problem + $(if ($null -ne $run.ExitCode -and $run.ExitCode -ne 0) { " (browser exit code $($run.ExitCode))" } else { '' })
        }
        elseif ((Get-Prop $results 'status') -eq 'passed' -and $record.failed -eq 0 -and $record.errors.Count -eq 0 -and $record.total -gt 0) {
            $record.status = 'passed'
        }
        else {
            $record.reason = if ($record.total -eq 0) { 'the suite reported no tests' } elseif ($record.failed -eq 0) { 'the suite reported uncaught errors' } else { $null }
        }
        if ($record.status -ne 'passed') {
            $record.stderrTail = Get-Tail $run.Stderr 40
            if ($run.Stderr -match 'No usable sandbox') {
                $record.reason = "$($record.reason); the browser has no usable sandbox here: set WMUX_WEB_BROWSER_ARGS=--no-sandbox"
            }
        }
        $records.Add([pscustomobject] $record)
        Write-SuiteReport $record
    }

    $failedSuites = @($records | Where-Object { $_.status -ne 'passed' })
    $testsTotal = ($records | ForEach-Object { if ($null -ne $_.total) { $_.total } else { 0 } } | Measure-Object -Sum).Sum
    $testsPassed = ($records | ForEach-Object { if ($null -ne $_.passed) { $_.passed } else { 0 } } | Measure-Object -Sum).Sum
    $summary = [ordered]@{
        format = 'wmux-web-run/1'
        status = if ($failedSuites.Count -eq 0) { 'passed' } else { 'failed' }
        startedAt = $started.ToUniversalTime().ToString('o')
        durationMs = [int] ((Get-Date) - $started).TotalMilliseconds
        browser = $browserPath
        virtualTimeBudgetMs = $VirtualTimeBudgetMs
        timeoutSec = $TimeoutSec
        totals = [ordered]@{
            suites = $records.Count; suitesPassed = $records.Count - $failedSuites.Count
            tests = [int] $testsTotal; testsPassed = [int] $testsPassed
        }
        suites = $records
    }
    $outDir = Split-Path -Parent $OutFile
    if ($outDir) { [void] [IO.Directory]::CreateDirectory($outDir) }
    $summary | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM
    $line = "$($summary.totals.suitesPassed)/$($records.Count) suites passed, $testsPassed/$testsTotal tests passed; results: $OutFile"
    if ($failedSuites.Count -eq 0) { Write-Host "OK: $line" -ForegroundColor Green }
    else { Write-Host "FAILED: $line" -ForegroundColor Red; $exitCode = 1 }
}
catch {
    if ($_.Exception -is [SetupError]) {
        Write-Host "run.ps1: $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = 2
    }
    else {
        Write-Host "run.ps1: unexpected error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        $exitCode = 2
    }
}
finally {
    Stop-StaticServer $server
    foreach ($dir in @($profiles)) {
        if (-not (Remove-TempProfile $dir)) { Write-Warning "could not delete the temporary profile $dir" }
    }
}
exit $exitCode
