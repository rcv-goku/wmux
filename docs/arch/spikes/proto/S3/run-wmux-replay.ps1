# S3 spike reference harness (not shipped): launch a hidden, isolated wmux
# built with the S3 spike patch (s3-spike.patch), replay a saved scrollback
# file and verify over the legacy pipe (read-screen scrollback:true) that
# the replayed lines survive ConPTY's first frame and that the prompt
# follows them.
#
# Isolation: LOCALAPPDATA/APPDATA/XDG_CONFIG_HOME point into a sandbox dir
# (no user config, session or window-state is read or written; the update
# check is suppressed by a future update_check_at). The instance is created
# off-screen, WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW, SW_SHOWNOACTIVATE
# (WMUX_TEST_HIDDEN=1); a 100 ms foreground sampler aborts the run if the
# instance ever becomes foreground. The process tree is killed at the end.
#
# Modes: off (no replay), none (text only = control), crlf (ADR-9.5 as
# written), crlf_home (ADR + ESC[H), fallback (env file + shell-side
# cat/Get-Content/type).
param(
    [Parameter(Mandatory)][ValidateSet('cmd', 'pwsh', 'pwsh-noprofile', 'wsl')][string]$Shell,
    [Parameter(Mandatory)][ValidateSet('off', 'none', 'crlf', 'crlf_home', 'fallback')][string]$Mode,
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\..\..\..\zig-out\bin\wmux.exe'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\..\..\..\zig-out\s3\runs'),
    [int]$Lines = 100,
    [int]$Pad = 0,
    [int]$ResizeAfterMs = -1,
    [int]$ResizeWidth = 800,
    [int]$ResizeHeight = 900,
    [int]$TimeoutSec = 90,
    [int]$StableMs = 2000,
    [string]$Tag = ''
)
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
if (-not $Tag) { $Tag = "$Shell-$Mode" + $(if ($ResizeAfterMs -ge 0) { "-resize$ResizeAfterMs" } else { '' }) }
if (-not ('S3Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'S3Native.cs') }

# ---------------------------------------------------------------- sandbox
$sb = Join-Path $OutDir "sandbox-$Tag"
if (Test-Path $sb) { Remove-Item -Recurse -Force $sb }
foreach ($d in 'Local\ghostty', 'Roaming', 'xdg\ghostty') { New-Item -ItemType Directory -Force (Join-Path $sb $d) | Out-Null }
$future = [DateTimeOffset]::UtcNow.AddYears(10).ToUnixTimeSeconds()
Set-Content -NoNewline -Path (Join-Path $sb 'Local\ghostty\update_check_at') -Value "$future"
$cfg = @('confirm-close-surface = false')
if ($Mode -eq 'fallback' -and $Shell -like 'pwsh*') { $cfg += 'shell-integration = none' }
Set-Content -Path (Join-Path $sb 'xdg\ghostty\config') -Value $cfg

# ---------------------------------------------------------- history files
$E = [char]27; $BEL = [char]7
function New-History([bool]$Hostile) {
    $sbuf = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -le $Lines; $i++) {
        $line = 'S3-LINE-{0:000} the quick brown fox jumps over the lazy dog' -f $i
        if ($Pad -gt 0) { $line += ' ' + ('p' * $Pad) }
        if ($i -eq 33) { $line += " h${E}[3mé${E}[23mllo wörld ─ 日本語 ✓" }
        if ($i -eq 77) { $line += ' ' + ('x' * 150) + ' END77' }
        if ($i % 10 -eq 0) { $line = "${E}[1;38;2;80;200;120m$line${E}[0m" }
        if ($i -eq 45) { $line = "${E}[44m$line" }   # background left open on purpose
        if ($i -eq 46) { $line = "${E}[0m$line" }
        if ($Hostile -and $i -eq 50) {
            $line += "${E}]0;S3-HACKED-TITLE${BEL}${E}[6n${E}[c${E}]52;c;aGVsbG8=${BEL}${E}[?1049h${E}[2J${E}[3J"
        }
        [void]$sbuf.Append($line).Append("`r`n")
    }
    [void]$sbuf.Append("${E}[33mC:\old\prompt>${E}[0m `r`n")
    return $sbuf.ToString()
}
$histTerm = Join-Path $sb 'history.vt'
$histSaved = Join-Path $sb 'history-saved.vt'
[IO.File]::WriteAllText($histTerm, (New-History $true), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($histSaved, (New-History $false), [Text.UTF8Encoding]::new($false))

# Fallback shell-side scripts (what shell integration would contain).
$fbPs1 = Join-Path $sb 'fb.ps1'
Set-Content -Path $fbPs1 -Encoding utf8 -Value @'
if ($env:WMUX_RESTORE_SCROLLBACK_FILE -and (Test-Path -LiteralPath $env:WMUX_RESTORE_SCROLLBACK_FILE)) {
    [Console]::Out.Write([IO.File]::ReadAllText($env:WMUX_RESTORE_SCROLLBACK_FILE))
    [Console]::Out.Write("`r`n")
    Remove-Item Env:WMUX_RESTORE_SCROLLBACK_FILE
}
'@
$fbRc = Join-Path $sb 'fb.bashrc'
[IO.File]::WriteAllText($fbRc, (@'
[ -f ~/.bashrc ] && . ~/.bashrc
if [ -n "$WMUX_RESTORE_SCROLLBACK_FILE" ] && [ -r "$WMUX_RESTORE_SCROLLBACK_FILE" ]; then
  cat "$WMUX_RESTORE_SCROLLBACK_FILE"; printf '\r\n'; unset WMUX_RESTORE_SCROLLBACK_FILE
fi
'@ -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
function To-WslPath([string]$p) { '/mnt/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }

$command = switch ($Shell) {
    'cmd' { if ($Mode -eq 'fallback') { "cmd.exe /k type $histSaved" } else { 'cmd.exe' } }
    'pwsh' { if ($Mode -eq 'fallback') { "pwsh.exe -NoLogo -NoExit -File $fbPs1" } else { 'pwsh.exe -NoLogo' } }
    'pwsh-noprofile' { if ($Mode -eq 'fallback') { "pwsh.exe -NoLogo -NoProfile -NoExit -File $fbPs1" } else { 'pwsh.exe -NoLogo -NoProfile' } }
    'wsl' { if ($Mode -eq 'fallback') { "wsl.exe -d Ubuntu-24.04 -- bash --rcfile $(To-WslPath $fbRc) -i" } else { 'wsl.exe -d Ubuntu-24.04' } }
}

# ----------------------------------------------------------------- launch
$psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $true
$psi.ArgumentList.Add("--command=$command")
$psi.Environment['WMUX_TEST_HIDDEN'] = '1'
$psi.Environment['LOCALAPPDATA'] = (Join-Path $sb 'Local')
$psi.Environment['APPDATA'] = (Join-Path $sb 'Roaming')
$psi.Environment['XDG_CONFIG_HOME'] = (Join-Path $sb 'xdg')
switch ($Mode) {
    'off' { }
    'fallback' {
        $psi.Environment['WMUX_RESTORE_SCROLLBACK_FILE'] = $histSaved
        $psi.Environment['WSLENV'] = 'WMUX_RESTORE_SCROLLBACK_FILE/p'
    }
    default {
        $psi.Environment['WMUX_SPIKE_RESTORE_FILE'] = $histTerm
        $psi.Environment['WMUX_SPIKE_RESTORE_MODE'] = $Mode
    }
}
$errLog = Join-Path $OutDir "wmux-stderr-$Tag.txt"
$fsErr = [IO.File]::Create($errLog)
$fsOut = [IO.File]::Create((Join-Path $OutDir "wmux-stdout-$Tag.txt"))
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = [System.Diagnostics.Process]::Start($psi)
$t1 = $p.StandardError.BaseStream.CopyToAsync($fsErr)
$t2 = $p.StandardOutput.BaseStream.CopyToAsync($fsOut)
$fg = [S3Native+FgSampler]::new()
$fg.Start($p.Id)
$pipe = "wmux-ipc-$($p.Id)"

$result = [ordered]@{ tag = $Tag; shell = $Shell; mode = $Mode; command = $command; pid = $p.Id }
function Read-Screen([bool]$Scrollback) {
    $req = '{"id":1,"cmd":"read-screen","args":{"scrollback":' + $(if ($Scrollback) { 'true' } else { 'false' }) + '}}'
    $raw = [S3Native]::PipeRequest($pipe, $req, 5000)
    $obj = $raw | ConvertFrom-Json
    if (-not $obj.ok) { return $null }
    return [string]$obj.data
}
function Find-Prompt([string[]]$ls) {
    $last = -1
    for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i] -match '^S3-LINE-\d{3}') { $last = $i } }
    for ($i = $last + 1; $i -lt $ls.Count; $i++) {
        $t = $ls[$i].Trim()
        if ($t -and $t -notmatch '^S3-LINE' -and $t -notmatch '^C:\\old\\prompt>' -and $t -notmatch '^x+ END77$') { return $i }
    }
    return -1
}

try {
    $resized = $false
    if ($ResizeAfterMs -eq 0) {
        # Resize as soon as the top-level window exists (lands right after
        # the replay, before ConPTY's first frame).
        $result.resize = [S3Native]::ResizeAsap($p.Id, 'WmuxWindow', $ResizeWidth, $ResizeHeight, 20000)
        $resized = $true
    }
    $firstDumpMs = $null; $promptMs = $null; $lastDump = $null; $stableSince = $null
    while ($sw.ElapsedMilliseconds -lt $TimeoutSec * 1000) {
        if ($fg.Violated) { throw "FOREGROUND VIOLATION: $($fg.Detail)" }
        if ($p.HasExited) { throw "wmux exited early with code $($p.ExitCode)" }
        if (-not $resized -and $ResizeAfterMs -ge 0 -and $sw.ElapsedMilliseconds -ge $ResizeAfterMs) {
            $h = [S3Native]::TopWindowsOf($p.Id, 'WmuxWindow')
            if ($h.Count -gt 0) {
                $before = [S3Native]::Rect($h[0])
                $ok = [S3Native]::SetSize($h[0], $ResizeWidth, $ResizeHeight)
                $result.resize = "at $($sw.ElapsedMilliseconds) ms: $before -> $([S3Native]::Rect($h[0])) ok=$ok"
                $resized = $true
            }
        }
        $d = $null
        try { $d = Read-Screen $true } catch { }
        if ($d) {
            if ($null -eq $firstDumpMs) { $firstDumpMs = $sw.ElapsedMilliseconds }
            $ls = $d -split "`n"
            if ((Find-Prompt $ls) -ge 0) {
                if ($null -eq $promptMs) { $promptMs = $sw.ElapsedMilliseconds }
                if ($d -ne $lastDump) { $stableSince = $sw.ElapsedMilliseconds; $lastDump = $d }
                elseif ($sw.ElapsedMilliseconds - $stableSince -ge $StableMs -and ($ResizeAfterMs -lt 0 -or $resized)) { break }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    $result.first_dump_ms = $firstDumpMs
    $result.prompt_ms = $promptMs
    $full = Read-Screen $true
    $vis = Read-Screen $false
    [IO.File]::WriteAllText((Join-Path $OutDir "screen-scrollback-$Tag.txt"), $full)
    [IO.File]::WriteAllText((Join-Path $OutDir "screen-visible-$Tag.txt"), $vis)

    # ------------------------------------------------------------ analyze
    $ls = $full -split "`n"
    $idx = @{}
    $dups = @()
    for ($i = 0; $i -lt $ls.Count; $i++) {
        if ($ls[$i] -match '^S3-LINE-(\d+)') {
            $n = [int]$Matches[1]
            if ($idx.ContainsKey($n)) { $dups += $n } else { $idx[$n] = $i }
        }
    }
    $missing = @(1..$Lines | Where-Object { -not $idx.ContainsKey($_) })
    $ordered = $true
    for ($n = 2; $n -le $Lines; $n++) { if ($idx.ContainsKey($n) -and $idx.ContainsKey($n - 1) -and $idx[$n] -le $idx[$n - 1]) { $ordered = $false } }
    $pi = Find-Prompt $ls
    $lastIdx = if ($idx.Count) { ($idx.Values | Measure-Object -Maximum).Maximum } else { -1 }
    $oldPrompt = [Array]::FindIndex($ls, [Predicate[string]] { param($x) $x -match '^C:\\old\\prompt>' })
    $result.present = $idx.Count
    $result.missing = if ($missing.Count -gt 8) { "$($missing[0])..$($missing[-1]) ($($missing.Count))" } else { ($missing -join ',') }
    $result.duplicates = ($dups -join ',')
    $result.ordered = $ordered
    $result.prompt_line = if ($pi -ge 0) { $ls[$pi].Trim() } else { $null }
    $result.blank_lines_between_history_and_prompt = if ($pi -ge 0 -and $lastIdx -ge 0) {
        $after = if ($oldPrompt -gt $lastIdx) { $oldPrompt } else { $lastIdx }
        if ($pi - 1 -lt $after + 1) { 0 } else { @($ls[($after + 1)..($pi - 1)] | Where-Object { -not $_.Trim() }).Count }
    } else { $null }
    $result.prompt_after_history = ($pi -gt $lastIdx -and $lastIdx -ge 0)
    $result.unicode_line_ok = [bool]($ls | Where-Object { $_ -match '^S3-LINE-033 .* héllo wörld ─ 日本語 ✓' })
    $result.long_line_ok = [bool](($full -replace "`r?`n", '') -match 'S3-LINE-077 the quick brown fox jumps over the lazy dog x{150} END77')
    $result.hostile_leak = [bool]($full -match '\[\d+;\d+R|\[\?[\d;]*c|S3-HACKED')
    $visLines = @($vis -split "`n")
    $firstVis = ($visLines | Where-Object { $_.Trim() } | Select-Object -First 1)
    $result.visible_first_line = if ($firstVis) { $firstVis.Trim() } else { $null }
    $result.visible_top_is_prompt = ($visLines.Count -gt 0 -and $visLines[0].Trim() -and $visLines[0].Trim() -eq $result.prompt_line)
    $result.total_dump_lines = $ls.Count
    $result.fg_samples = $fg.Samples
    $result.fg_violation = $fg.Violated
}
finally {
    try { $p.Kill($true) } catch { }
    $p.WaitForExit(10000) | Out-Null
    $fg.Stop()
    try { $t1.Wait(3000) | Out-Null; $t2.Wait(3000) | Out-Null } catch { }
    $fsErr.Dispose(); $fsOut.Dispose()
    $result.elapsed_ms = $sw.ElapsedMilliseconds
    $s3log = Select-String -Path $errLog -Pattern 'S3 replay:|S3:' -SimpleMatch:$false | Select-Object -First 3 | ForEach-Object { $_.Line.Trim() }
    $result.s3_log = ($s3log -join ' | ')
}
$result | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $OutDir "result-$Tag.json")
[pscustomobject]$result
