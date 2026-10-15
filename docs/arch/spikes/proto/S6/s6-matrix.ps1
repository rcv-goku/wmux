# wmux spike S6: forwarder test matrix (cmd, pwsh 7, Windows PowerShell 5.1, Git Bash, WSL).
# Installs wmuxspikefwd* files into %LOCALAPPDATA%\Microsoft\WindowsApps, runs the
# groups, writes zig-out\spike-s6\results\<group>.json and always cleans up.
param([string[]]$Groups = @('all'))
. (Join-Path $PSScriptRoot 's6-common.ps1')
. (Join-Path $PSScriptRoot 's6-native.ps1')
$ErrorActionPreference = 'Stop'
function Want([string]$g) { ($Groups -contains 'all') -or ($Groups -contains $g) }

$WA = $S6.WA
$Shells = @('cmd', 'pwsh', 'winps', 'bash')
$Variants = [ordered]@{ direct = $null; fwd = 'wmuxspikefwd'; com = 'wmuxspikefwdc'; cmd = 'wmuxspikefwdcmd'; hl = 'wmuxspikefwdhl' }
$BareNames = @('wmuxspikefwd', 'wmuxspikefwdc', 'wmuxspikefwdcmd', 'wmuxspikefwdhl', 'wmuxspikefwdsh')

function Install-SpikeWindowsApps {
    Copy-Item $S6.Fwd (Join-Path $WA 'wmuxspikefwd.exe') -Force
    Copy-Item $S6.Fwd (Join-Path $WA 'wmuxspikefwdc.com') -Force
    [IO.File]::WriteAllText((Join-Path $WA 'wmuxspikefwdcmd.cmd'), "@`"$($S6.Target)`" %*`r`n", [Text.Encoding]::ASCII)
    $rc = [S6Native]::TryHardLink((Join-Path $WA 'wmuxspikefwdhl.exe'), $S6.Target)
    if ($rc) { throw "CreateHardLinkW failed: $rc" }
    [IO.File]::WriteAllText((Join-Path $WA 'wmuxspikefwdsh'), "#!/bin/sh`nexec `"`$(dirname `"`$0`")/wmuxspikefwd.exe`" `"`$@`"`n", [Text.UTF8Encoding]::new($false))
}

# Name used to invoke a variant from a shell.
function Get-Invoker([string]$shell, [string]$variant) {
    switch ($variant) {
        'direct' { if ($shell -eq 'bash') { return ConvertTo-MsysPath $S6.Target } else { return $S6.Target } }
        'com' { if ($shell -eq 'bash') { return 'wmuxspikefwdc.com' } else { return 'wmuxspikefwdc' } }
        'cmd' { if ($shell -eq 'bash') { return 'wmuxspikefwdcmd.cmd' } else { return 'wmuxspikefwdcmd' } }
        default { return $Variants[$variant] }
    }
}

# Build a one-command script for a shell: <invoker> <args...>; prints @@RC.
function New-CallScript([string]$shell, [string]$invoker, [string[]]$argv, [string]$suffix = '') {
    switch ($shell) {
        'cmd' {
            $head = if ($invoker -match '[\\ ]') { '"' + $invoker + '"' } else { $invoker }
            $tail = ($argv | ForEach-Object { ConvertTo-MsvcrtArg $_ }) -join ' '
            return ($head + ' ' + (ConvertTo-CmdEscaped $tail) + $suffix)
        }
        { $_ -in 'pwsh', 'winps' } {
            $list = ($argv | ForEach-Object { ConvertTo-PsSingle $_ }) -join ', '
            return "`$a = @($list)`r`ntry { & $(ConvertTo-PsSingle $invoker) @a$suffix; `"@@RC `$LASTEXITCODE`" } catch { `"@@NOTFOUND `$(`$_.FullyQualifiedErrorId)`" }`r`n"
        }
        'bash' {
            $list = ($argv | ForEach-Object { ConvertTo-BashSingle $_ }) -join ' '
            return "a=( $list )`n$(ConvertTo-BashSingle $invoker) `"`${a[@]}`"$suffix`necho `"@@RC `$?`"`n"
        }
    }
}

function Get-Rc($r, [string]$shell) {
    if ($shell -eq 'cmd') { return $r.ExitCode }
    $m = Get-Marker $r.Out 'RC'
    if ($null -ne $m) { return [int64]$m }
    $nf = Get-Marker $r.Out 'NOTFOUND'
    if ($null -ne $nf) { return "notfound:$nf" }
    return "none(exit=$($r.ExitCode))"
}

$sampler = $null
$stopFile = Join-Path $S6.Run 'fgsampler.stop'
$fgLog = Join-Path $S6.Results 'foreground.log'
Remove-Item -ErrorAction SilentlyContinue $stopFile
$summary = [ordered]@{ started = (Get-Date).ToString('o'); groups = [ordered]@{} }
try {
    $psi = [Diagnostics.ProcessStartInfo]::new($S6.Pwsh, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 's6-fgsampler.ps1')`" -Log `"$fgLog`" -StopFile `"$stopFile`"")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $sampler = [Diagnostics.Process]::Start($psi)

    Install-SpikeTarget
    $before = @(Get-SpikeWindowsAppsFiles).Count
    if ($before -ne 0) { throw "WindowsApps already has $before wmuxspikefwd* files; run s6-cleanup.ps1 first" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Install-SpikeWindowsApps
    $summary.install_ms = $sw.Elapsed.TotalMilliseconds
    $summary.installed = @(Get-SpikeWindowsAppsFiles | ForEach-Object { [ordered]@{ name = $_.Name; length = $_.Length; attributes = "$($_.Attributes)"; id = [S6Native]::FileId($_.FullName) } })
    $summary.target_id = [S6Native]::FileId($S6.Target)

    # ---------------------------------------------------------------- resolution
    if (Want 'resolution') {
        $res = [ordered]@{}
        $r = Invoke-InShell cmd ('where ' + ($BareNames -join ' '))
        $res.cmd_where = [ordered]@{ exit = $r.ExitCode; out = @($r.Out.Trim() -split "`r?`n"); err = $r.Err.Trim() }
        $all = $BareNames + @('wmuxspikefwdc.com', 'wmuxspikefwdcmd.cmd')
        $psList = ($all | ForEach-Object { ConvertTo-PsSingle $_ }) -join ','
        $gc = @'
foreach ($n in @(__LIST__)) {
  $c = @(Get-Command $n -All -ErrorAction SilentlyContinue)
  if ($c.Count -eq 0) { "@@GC $n NOTFOUND" } else { foreach ($x in $c) { "@@GC $n $($x.CommandType) $($x.Source)" } }
}
'@.Replace('__LIST__', $psList)
        foreach ($sh in 'pwsh', 'winps') { $r = Invoke-InShell $sh $gc; $res["${sh}_get_command"] = Get-Markers $r.Out }
        $b = 'for n in ' + ($all -join ' ') + '; do p=$(type -P "$n" 2>/dev/null); echo "@@TYPE $n ${p:-NOTFOUND}"; done'
        $r = Invoke-InShell bash $b
        $res.bash_type_P = Get-Markers $r.Out
        $res.bash_err = $r.Err.Trim()
        $summary.groups.resolution = Save-Result 'resolution' $res
    }

    # ------------------------------------------------- bare-name invocation probe
    if (Want 'barename') {
        $res = [ordered]@{}
        foreach ($sh in $Shells) {
            foreach ($n in $BareNames) {
                # Never invoke an extensionless name from cmd/PowerShell: if they resolved
                # it as a document they would ShellExecute it (an "Open with" dialog would
                # take the foreground). Resolution of it is reported by the 'resolution' group.
                if ($n -eq 'wmuxspikefwdsh' -and $sh -ne 'bash') { $res["$sh/$n"] = 'skipped (extensionless; see resolution)'; continue }
                $r = Invoke-InShell $sh (New-CallScript $sh $n @('argv', 'probe1', 'two words'))
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                $res["$sh/$n"] = [ordered]@{
                    rc = Get-Rc $r $sh; ok = ($null -ne $j -and $j.argv.Count -ge 4 -and (JArg $j 3) -eq 'two words')
                    argv0 = (JArg $j 0); exe = $j.exe; stdin = $j.stdin; stdout = $j.stdout
                    err = ($r.Err.Trim() -split "`r?`n" | Select-Object -First 2) -join ' | '
                }
            }
        }
        $summary.groups.barename = Save-Result 'barename' $res
    }

    # ------------------------------------------------------------ argv fidelity
    $Vectors = [ordered]@{
        basic   = @('a', 'b c', '', 'x"y', 'C:\dir\', 'tr\\ail\\', 'a\\"b', '"', '\', '--', '--help', '+verb', '-x=1', "tab`there")
        unicode = @("h$([char]0xE9)llo", "$([char]0x65E5)$([char]0x672C)$([char]0x8A9E)", [char]::ConvertFromUtf32(0x1F642), "$([char]0xDC)n$([char]0xEF)c$([char]0xF6)d$([char]0xE9) spaced")
        special = @('a&b', 'a|b', 'a^b', '100%', '%PATH%', '!bang!', '<lt>', '(paren)', 'semi;colon', 'back`tick', '$dollar', "it's", '*glob*', '~tilde', '/slash-opt', 'C:/fwd/slash')
    }
    if (Want 'argv') {
        $res = [ordered]@{}
        foreach ($sh in $Shells) {
            foreach ($vn in $Vectors.Keys) {
                $vec = $Vectors[$vn]
                $baseline = $null
                foreach ($v in $Variants.Keys) {
                    $inv = Get-Invoker $sh $v
                    $r = Invoke-InShell $sh (New-CallScript $sh $inv (@('argv') + $vec))
                    $js = @(Get-JsonLines $r.Out)
                    $got = if ($js.Count -gt 0) { @($js[0].argv | Select-Object -Skip 2) } else { $null }
                    if ($v -eq 'direct') { $baseline = $got }
                    $exact = ($null -ne $got) -and ((ConvertTo-Json -Compress -InputObject @($got)) -eq (ConvertTo-Json -Compress -InputObject @($vec)))
                    $same = ($null -ne $got) -and ((ConvertTo-Json -Compress -InputObject @($got)) -eq (ConvertTo-Json -Compress -InputObject @($baseline)))
                    $entry = [ordered]@{ rc = Get-Rc $r $sh; json_lines = $js.Count; equals_intended = $exact; equals_direct = $same }
                    if (-not $same -or -not $exact) { $entry.received = $got }
                    if ($js.Count -gt 0) { $entry.argv0 = $js[0].argv[0] }
                    $e = $r.Err.Trim(); if ($e) { $entry.err = ($e -split "`r?`n" | Select-Object -First 3) -join ' | ' }
                    $res["$sh/$vn/$v"] = $entry
                }
            }
        }
        $res.intended = $Vectors
        $summary.groups.argv = Save-Result 'argv' $res
    }

    # ------------------------------------------------------- long command lines
    if (Want 'long') {
        $res = [ordered]@{}
        # 1) Through the Process API (CreateProcessW limit 32767 incl. NUL).
        foreach ($len in 32000, 32760, 32766, 32767) {
            foreach ($v in 'fwd', 'direct') {
                $file = if ($v -eq 'fwd') { Join-Path $WA 'wmuxspikefwd.exe' } else { $S6.Target }
                $prefixLen = $file.Length + 3 + 5   # quotes + space + "argv "
                $pad = 'x' * [math]::Max(1, $len - $prefixLen)
                try {
                    $r = Invoke-Proc -File $file -Arguments "argv $pad"
                    $j = Get-JsonLines $r.Out | Select-Object -First 1
                    $res["api/$len/$v"] = [ordered]@{ rc = $r.ExitCode; cmdline_len = $j.cmdline.Length; pad_ok = ((JArg $j 2) -eq $pad); err = $r.Err.Trim() }
                } catch { $res["api/$len/$v"] = [ordered]@{ error = $_.Exception.Message } }
            }
        }
        # 2) Through shells: ~29k chars (pwsh/bash), ~8.1k limit in cmd.
        $chunk = 'y' * 99
        foreach ($sh in 'pwsh', 'bash', 'cmd') {
            $count = if ($sh -eq 'cmd') { 78 } else { 290 }
            $argvL = @('argv') + @(1..$count | ForEach-Object { $chunk })
            foreach ($v in 'direct', 'fwd') {
                $r = Invoke-InShell $sh (New-CallScript $sh (Get-Invoker $sh $v) $argvL)
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                $res["shell/$sh/$v"] = [ordered]@{ rc = Get-Rc $r $sh; argc = $j.argv.Count; cmdline_len = $j.cmdline.Length; err = ($r.Err.Trim() -split "`r?`n" | Select-Object -First 2) -join ' | ' }
            }
        }
        $summary.groups.long = Save-Result 'long' $res
    }

    # ------------------------------------------------------- stdin/stdout bytes
    if (Want 'stdio') {
        $res = [ordered]@{}
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $buf = [byte[]]::new(4MB); $rng.GetBytes($buf)
        $inBytes = Join-Bytes ([byte[]](0..255)) $buf
        $inFile = Join-Path $S6.Run 'input.bin'
        [IO.File]::WriteAllBytes($inFile, $inBytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        $inHash = ([BitConverter]::ToString($sha.ComputeHash($inBytes)) -replace '-', '').ToLower()
        $N = 3000000
        $emit = [byte[]]::new($N); for ($i = 0; $i -lt $N; $i++) { $emit[$i] = [byte](($i * 7 + 3) -band 0xFF) }
        $emitHash = ([BitConverter]::ToString($sha.ComputeHash($emit)) -replace '-', '').ToLower()
        $res.expected = [ordered]@{ input_len = $inBytes.Length; input_sha = $inHash; emit_len = $N; emit_sha = $emitHash }
        function HashFile($p) { if (Test-Path $p) { (Get-FileHash -Algorithm SHA256 $p).Hash.ToLower() + " len=" + (Get-Item $p).Length } else { 'missing' } }
        foreach ($v in 'direct', 'fwd', 'cmd', 'hl') {
            # cmd
            $inv = Get-Invoker 'cmd' $v; $q = if ($inv -match '[\\ ]') { "`"$inv`"" } else { $inv }
            $d = "`"$($S6.Target)`""
            $out = Join-Path $S6.Run "out-cmd-$v.bin"
            $res["cmd/$v/stdin_file"] = (Invoke-InShell cmd "$q sha < `"$inFile`"").Out.Trim()
            $null = Invoke-InShell cmd "$q emit $N > `"$out`""; $res["cmd/$v/stdout_file"] = HashFile $out
            $res["cmd/$v/pipe_in"] = (Invoke-InShell cmd "$d emit $N | $q sha").Out.Trim()
            $res["cmd/$v/pipe_out"] = (Invoke-InShell cmd "$q emit $N | $d sha").Out.Trim()
            # pwsh 7.6 (native byte pipes)
            $inv = Get-Invoker 'pwsh' $v; $out = Join-Path $S6.Run "out-pwsh-$v.bin"
            $s = @'
& '__D__' emit __N__ | & '__V__' sha
& '__V__' emit __N__ | & '__D__' sha
& '__V__' emit __N__ > '__OUT__'
'@.Replace('__D__', $S6.Target).Replace('__V__', $inv).Replace('__N__', "$N").Replace('__OUT__', $out)
            $r = Invoke-InShell pwsh $s
            $lines = @($r.Out.Trim() -split "`r?`n")
            $res["pwsh/$v/pipe_in"] = $lines[0]; $res["pwsh/$v/pipe_out"] = $lines[1]; $res["pwsh/$v/stdout_file"] = HashFile $out
            # Windows PowerShell 5.1 (text pipeline; compare with direct)
            $inv = Get-Invoker 'winps' $v
            $r = Invoke-InShell winps ("'h" + [char]0xE9 + "llo pipe' | & '" + $inv + "' cat")
            $res["winps/$v/text_pipe"] = $r.Out.Trim()
            # Git Bash
            $inv = Get-Invoker 'bash' $v; $out = Join-Path $S6.Run "out-bash-$v.bin"
            $mi = ConvertTo-MsysPath $inFile; $mo = ConvertTo-MsysPath $out; $md = ConvertTo-MsysPath $S6.Target
            $s = @'
'__V__' sha < '__IN__'
cat '__IN__' | '__V__' sha
'__V__' emit __N__ | sha256sum
'__V__' emit __N__ > '__OUT__'
'__D__' emit __N__ | '__V__' sha
'@.Replace('__V__', $inv).Replace('__IN__', $mi).Replace('__N__', "$N").Replace('__OUT__', $mo).Replace('__D__', $md)
            $r = Invoke-InShell bash $s
            $lines = @($r.Out.Trim() -split "`n")
            $res["bash/$v/stdin_file"] = $lines[0]; $res["bash/$v/pipe_cat"] = $lines[1]; $res["bash/$v/pipe_out_sha256sum"] = $lines[2]
            $res["bash/$v/pipe_in"] = $lines[3]; $res["bash/$v/stdout_file"] = HashFile $out
            # Process API: stdin bytes in, stdout bytes out
            if ($v -in 'direct', 'fwd', 'hl') {
                $file = switch ($v) { 'direct' { $S6.Target } 'fwd' { Join-Path $WA 'wmuxspikefwd.exe' } 'hl' { Join-Path $WA 'wmuxspikefwdhl.exe' } }
                $r = Invoke-Proc -File $file -Arguments 'cat' -Stdin $inBytes
                $res["api/$v/cat_roundtrip"] = (([BitConverter]::ToString($sha.ComputeHash($r.OutBytes)) -replace '-', '').ToLower() -eq $inHash)
                $r = Invoke-Proc -File $file -Arguments 'stderr'
                $res["api/$v/stderr_split"] = [ordered]@{ out = $r.Out.Trim(); err = $r.Err.Trim(); rc = $r.ExitCode }
            }
        }
        Get-ChildItem $S6.Run -Filter 'out-*.bin' | Remove-Item
        $summary.groups.stdio = Save-Result 'stdio' $res
    }

    # --------------------------------------------------------------- exit codes
    if (Want 'exit') {
        $res = [ordered]@{}
        $codes = @('0', '1', '2', '42', '255', '256', '9009', '-1', '0xC000013A', '0x7FFFFFFF')
        foreach ($v in 'direct', 'fwd', 'com', 'cmd', 'hl') {
            foreach ($c in $codes) {
                $r = Invoke-InShell cmd (New-CallScript 'cmd' (Get-Invoker 'cmd' $v) @('exit', $c))
                $res["cmd/$v/$c"] = $r.ExitCode
            }
            foreach ($sh in 'pwsh', 'winps') {
                $inv = Get-Invoker $sh $v
                $s = "foreach (`$c in @('" + ($codes -join "','") + "')) { & '$inv' exit `$c; `"@@RC `$c `$LASTEXITCODE`" }"
                $r = Invoke-InShell $sh $s
                foreach ($m in Get-Markers $r.Out) { if ($m -match '^@@RC (\S+) (\S+)$') { $res["$sh/$v/$($Matches[1])"] = [int64]$Matches[2] } }
            }
            $inv = Get-Invoker 'bash' $v
            $s = "for c in $($codes -join ' '); do '$inv' exit `$c; echo `"@@RC `$c `$?`"; done"
            $r = Invoke-InShell bash $s
            foreach ($m in Get-Markers $r.Out) { if ($m -match '^@@RC (\S+) (\S+)$') { $res["bash/$v/$($Matches[1])"] = [int64]$Matches[2] } }
            # Process API (no shell): full 32-bit value
            if ($v -in 'direct', 'fwd', 'hl') {
                $file = switch ($v) { 'direct' { $S6.Target } 'fwd' { Join-Path $WA 'wmuxspikefwd.exe' } 'hl' { Join-Path $WA 'wmuxspikefwdhl.exe' } }
                foreach ($c in $codes) { $res["api/$v/$c"] = (Invoke-Proc -File $file -Arguments "exit $c").ExitCode }
            }
        }
        $summary.groups.exit = Save-Result 'exit' $res
    }

    # ------------------------------------- new logon environment (fresh session)
    if (Want 'fresh') {
        $res = [ordered]@{}
        $fresh = [S6Native]::FreshEnvironment()
        $res.fresh_path_has_windowsapps = (($fresh['Path'] -split ';') | Where-Object { $_.TrimEnd('\') -ieq $WA.TrimEnd('\') }).Count -gt 0
        $res.fresh_path_index_of_windowsapps = [array]::IndexOf(@($fresh['Path'] -split ';' | ForEach-Object { $_.TrimEnd('\').ToLower() }), $WA.TrimEnd('\').ToLower())
        $res.fresh_path_entries = @($fresh['Path'] -split ';').Count
        foreach ($sh in $Shells) {
            $r = Invoke-InShell $sh (New-CallScript $sh 'wmuxspikefwd' @('argv', 'fresh session')) -Env $fresh
            $j = Get-JsonLines $r.Out | Select-Object -First 1
            $res["$sh"] = [ordered]@{ rc = Get-Rc $r $sh; ok = ((JArg $j 2) -eq 'fresh session'); exe = $j.exe; err = $r.Err.Trim() }
        }
        $summary.groups.fresh = Save-Result 'fresh' $res
    }

    # ------------------------- already-running shell sees install and uninstall
    if (Want 'running') {
        $res = [ordered]@{}
        $late = Join-Path $WA 'wmuxspikefwdlate.exe'
        try {
            $r = Invoke-InShell cmd "where wmuxspikefwdlate >nul 2>&1 & copy /b `"$($S6.Fwd)`" `"$late`" >nul & wmuxspikefwdlate argv late & del `"$late`" & wmuxspikefwdlate argv after-delete"
            $res.cmd = [ordered]@{ json = @(Get-JsonLines $r.Out | ForEach-Object { $_.argv[2] }); exit = $r.ExitCode; err = $r.Err.Trim() }
            $s = @'
$c = Get-Command wmuxspikefwdlate -ErrorAction SilentlyContinue; "@@BEFORE $([bool]$c)"
Copy-Item '__FWD__' '__LATE__'
& wmuxspikefwdlate argv late; "@@RC1 $LASTEXITCODE"
Remove-Item '__LATE__'
try { & wmuxspikefwdlate argv after; "@@RC2 $LASTEXITCODE" } catch { "@@RC2 notfound $($_.FullyQualifiedErrorId)" }
'@.Replace('__FWD__', $S6.Fwd).Replace('__LATE__', $late)
            foreach ($sh in 'pwsh', 'winps') { $r = Invoke-InShell $sh $s; $res[$sh] = [ordered]@{ markers = Get-Markers $r.Out; json = @(Get-JsonLines $r.Out | ForEach-Object { $_.argv[2] }) } }
            $s = @'
p=$(type -P wmuxspikefwdlate); echo "@@BEFORE ${p:-none}"
cp '__FWD__' '__LATE__'
wmuxspikefwdlate argv late; echo "@@RC1 $?"
rm '__LATE__'
wmuxspikefwdlate argv after; echo "@@RC2 $?"
hash -r; wmuxspikefwdlate argv after-hash-r; echo "@@RC3 $?"
'@.Replace('__FWD__', (ConvertTo-MsysPath $S6.Fwd)).Replace('__LATE__', (ConvertTo-MsysPath $late))
            $r = Invoke-InShell bash $s
            $res.bash = [ordered]@{ markers = Get-Markers $r.Out; json = @(Get-JsonLines $r.Out | ForEach-Object { $_.argv[2] }); err = $r.Err.Trim() }
        } finally { Remove-Item -ErrorAction SilentlyContinue $late }
        $summary.groups.running = Save-Result 'running' $res
    }

    # ------------------------------------- same-name precedence within the dir
    if (Want 'precedence') {
        $res = [ordered]@{}
        $p = Join-Path $WA 'wmuxspikefwdp'
        try {
            function Which-Ran($r) {
                if ($r.Out -match '@@SH extensionless') { return 'extensionless-sh' }
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                if (-not $j) { return "none: $(($r.Err.Trim() -split "`r?`n")[0])" }
                if ($j.argv[-1] -eq 'FROMCMD') { return '.cmd' }
                if ($j.exe -like "$WA*") { return '.exe' } else { return '.com' }
            }
            # Phase A, all shells: .com (forwarder), .exe (target copy), .cmd (shim). No
            # extensionless file exists here, so cmd/PowerShell can never pick a document.
            Copy-Item $S6.Fwd "$p.com"
            Copy-Item $S6.Target "$p.exe"
            [IO.File]::WriteAllText("$p.cmd", "@`"$($S6.Target)`" %* FROMCMD`r`n", [Text.Encoding]::ASCII)
            foreach ($step in 'com+exe+cmd', 'exe+cmd', 'cmd') {
                if ($step -eq 'exe+cmd') { Remove-Item "$p.com" }
                if ($step -eq 'cmd') { Remove-Item "$p.exe" }
                foreach ($sh in $Shells) { $res["$step/$sh"] = Which-Ran (Invoke-InShell $sh (New-CallScript $sh 'wmuxspikefwdp' @('argv'))) }
            }
            Remove-Item "$p.cmd"
            # Phase B, Git Bash only: extensionless LF script next to .exe / .com.
            [IO.File]::WriteAllText($p, "#!/bin/sh`necho '@@SH extensionless'`n", [Text.UTF8Encoding]::new($false))
            Copy-Item $S6.Target "$p.exe"
            $res['sh+exe/bash'] = Which-Ran (Invoke-InShell bash (New-CallScript bash 'wmuxspikefwdp' @('argv')))
            # Resolution only (never executed from cmd/PowerShell): which file would win?
            $res['sh+exe/cmd_where'] = @((Invoke-InShell cmd 'where wmuxspikefwdp').Out.Trim() -split "`r?`n")
            foreach ($sh in 'pwsh', 'winps') {
                $r = Invoke-InShell $sh '$c = @(Get-Command wmuxspikefwdp -All); foreach ($x in $c) { "@@GC $($x.Source)" }; "@@FIRST $((Get-Command wmuxspikefwdp).Source)"'
                $res["sh+exe/${sh}_get_command"] = Get-Markers $r.Out
            }
            Remove-Item "$p.exe"; Copy-Item $S6.Fwd "$p.com"
            $res['sh+com/bash'] = Which-Ran (Invoke-InShell bash (New-CallScript bash 'wmuxspikefwdp' @('argv')))
            Remove-Item $p
            $res['com-only/bash'] = Which-Ran (Invoke-InShell bash (New-CallScript bash 'wmuxspikefwdp' @('argv')))
        } finally { Remove-Item -ErrorAction SilentlyContinue "$p.com", "$p.exe", "$p.cmd", $p }
        $summary.groups.precedence = Save-Result 'precedence' $res
    }

    # ----------------------------- non-ASCII install path: .cmd vs exe forwarder
    if (Want 'unicode') {
        $res = [ordered]@{}
        $u8 = Join-Path $WA 'wmuxspikefwdu8.cmd'; $oem = Join-Path $WA 'wmuxspikefwdoem.cmd'
        try {
            [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
            $line = "@`"$($S6.TargetU)`" %*`r`n"
            [IO.File]::WriteAllText($u8, $line, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($oem, $line, [Text.Encoding]::GetEncoding(437))
            foreach ($cp in 437, 65001) {
                foreach ($n in 'wmuxspikefwdu8', 'wmuxspikefwdoem') {
                    $r = Invoke-InShell cmd "chcp $cp >nul & $n argv ok"
                    $j = Get-JsonLines $r.Out | Select-Object -First 1
                    $res["cmd/chcp$cp/$n"] = [ordered]@{ ok = ((JArg $j 2) -eq 'ok'); exit = $r.ExitCode; err = $r.Err.Trim() }
                }
            }
            foreach ($n in 'wmuxspikefwdu8', 'wmuxspikefwdoem') {
                $r = Invoke-InShell pwsh (New-CallScript 'pwsh' $n @('argv', 'ok'))
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                $res["pwsh/$n"] = [ordered]@{ ok = ((JArg $j 2) -eq 'ok'); rc = Get-Rc $r 'pwsh'; err = $r.Err.Trim() }
            }
            # exe forwarder with a non-ASCII InstallDir (registry is UTF-16)
            Set-ItemProperty -Path $S6.RegKey -Name InstallDir -Value $S6.InstallU
            foreach ($cp in 437, 65001) {
                $r = Invoke-InShell cmd "chcp $cp >nul & wmuxspikefwd argv ok"
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                $res["cmd/chcp$cp/wmuxspikefwd(exe)"] = [ordered]@{ ok = ((JArg $j 2) -eq 'ok'); exit = $r.ExitCode; exe = $j.exe; err = $r.Err.Trim() }
            }
            foreach ($sh in 'pwsh', 'bash') {
                $r = Invoke-InShell $sh (New-CallScript $sh 'wmuxspikefwd' @('argv', 'ok'))
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                $res["$sh/wmuxspikefwd(exe)"] = [ordered]@{ ok = ((JArg $j 2) -eq 'ok'); rc = Get-Rc $r $sh; exe = $j.exe }
            }
        } finally {
            Set-ItemProperty -Path $S6.RegKey -Name InstallDir -Value $S6.Install
            Remove-Item -ErrorAction SilentlyContinue $u8, $oem
        }
        $summary.groups.unicode = Save-Result 'unicode' $res
    }

    # ------------------------------------------------- App Paths (negative test)
    if (Want 'apppaths') {
        $res = [ordered]@{}
        $key = Join-Path $S6.AppPathsKey 'wmuxspikefwdap.exe'
        try {
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name '(default)' -Value $S6.Target
            foreach ($sh in $Shells) {
                $r = Invoke-InShell $sh (New-CallScript $sh 'wmuxspikefwdap' @('argv', 'x'))
                $res["$sh"] = [ordered]@{ rc = Get-Rc $r $sh; json = @(Get-JsonLines $r.Out).Count; err = ($r.Err.Trim() -split "`r?`n" | Select-Object -First 1) }
            }
            $s = @'
try { $p = Start-Process -FilePath wmuxspikefwdap -ArgumentList 'exit','7' -NoNewWindow -Wait -PassThru -ErrorAction Stop; "@@NONEWWINDOW exit=$($p.ExitCode)" } catch { "@@NONEWWINDOW error: $($_.Exception.Message)" }
Add-Type -Namespace S6 -Name Sh -MemberDefinition @"
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct SEI { public int cbSize; public uint fMask; public IntPtr hwnd; public string lpVerb, lpFile, lpParameters, lpDirectory; public int nShow; public IntPtr hInstApp, lpIDList; public string lpClass; public IntPtr hkeyClass; public uint dwHotKey; public IntPtr hIcon, hProcess; }
[DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool ShellExecuteExW(ref SEI i);
[DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
[DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint c);
"@
$i = New-Object S6.Sh+SEI
$i.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($i)
$i.fMask = 0x40 -bor 0x8000 -bor 0x400   # NOCLOSEPROCESS | NO_CONSOLE (reuse our hidden console) | FLAG_NO_UI
$i.lpVerb = 'open'; $i.lpFile = 'wmuxspikefwdap.exe'; $i.lpParameters = 'exit 7'; $i.nShow = 0
if ([S6.Sh]::ShellExecuteExW([ref]$i)) { [void][S6.Sh]::WaitForSingleObject($i.hProcess, 15000); $c = 0; [void][S6.Sh]::GetExitCodeProcess($i.hProcess, [ref]$c); "@@SHELLEXECUTE exit=$c" } else { "@@SHELLEXECUTE error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
'@
            $r = Invoke-InShell pwsh $s
            $res.pwsh_start_process_nonewwindow = Get-Marker $r.Out 'NONEWWINDOW'
            $res.shellexecuteex_hidden = Get-Marker $r.Out 'SHELLEXECUTE'
        } finally { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        $summary.groups.apppaths = Save-Result 'apppaths' $res
    }

    # ---------------------------------------------------- Mark of the Web (MOTW)
    if (Want 'motw') {
        $res = [ordered]@{}
        $dir = Join-Path $S6.Run 'motw'; New-Item -ItemType Directory -Force $dir | Out-Null
        $src = Join-Path $dir 'tagged.exe'
        $wam = Join-Path $WA 'wmuxspikefwdmotw.exe'
        try {
            Copy-Item $S6.Fwd $src -Force
            Set-Content -LiteralPath $src -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://example.invalid/wmux.zip"
            Copy-Item $src (Join-Path $dir 'copy-item.exe') -Force
            [IO.File]::Copy($src, (Join-Path $dir 'file-copy.exe'), $true)
            [IO.File]::WriteAllBytes((Join-Path $dir 'bytes.exe'), [IO.File]::ReadAllBytes($src))
            foreach ($f in 'tagged.exe', 'copy-item.exe', 'file-copy.exe', 'bytes.exe') {
                $res["stream/$f"] = [bool](Get-Item -LiteralPath (Join-Path $dir $f) -Stream Zone.Identifier -ErrorAction SilentlyContinue)
            }
            Copy-Item $src $wam -Force   # carries the stream into WindowsApps
            $res['stream/WindowsApps copy'] = [bool](Get-Item -LiteralPath $wam -Stream Zone.Identifier -ErrorAction SilentlyContinue)
            foreach ($sh in $Shells) {
                $r = Invoke-InShell $sh (New-CallScript $sh 'wmuxspikefwdmotw' @('argv', 'motw'))
                $j = Get-JsonLines $r.Out | Select-Object -First 1
                $res["run/$sh"] = [ordered]@{ ok = ((JArg $j 2) -eq 'motw'); rc = Get-Rc $r $sh; ms = $r.Ms; err = $r.Err.Trim() }
            }
        } finally { Remove-Item -ErrorAction SilentlyContinue $wam; Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dir }
        $summary.groups.motw = Save-Result 'motw' $res
    }

    # ------------------------------- hard links, update semantics, file locks
    if (Want 'links') {
        $res = [ordered]@{}
        $dir = Join-Path $S6.Run 'hl\cli'; New-Item -ItemType Directory -Force $dir | Out-Null
        $t = Join-Path $dir 't.exe'
        $link = Join-Path $WA 'wmuxspikefwdhlu.exe'
        $v2 = Join-Path $S6.Run 'hl\v2.exe'
        $v3 = Join-Path $S6.Run 'hl\v3.exe'
        try {
            Copy-Item $S6.Target $t -Force
            [IO.File]::WriteAllBytes($v2, (Join-Bytes ([IO.File]::ReadAllBytes($S6.Target)) ([Text.Encoding]::ASCII.GetBytes('v2-overlay'))))
            [IO.File]::WriteAllBytes($v3, (Join-Bytes ([IO.File]::ReadAllBytes($S6.Target)) ([Text.Encoding]::ASCII.GetBytes('v3-overlay'))))
            $res.create = [S6Native]::TryHardLink($link, $t)
            $h = { param($p) (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.Substring(0, 12) }
            $res.initial = [ordered]@{ t = [S6Native]::FileId($t); link = [S6Native]::FileId($link) }
            $r = Invoke-Proc -File $link -Arguments 'argv'
            $res.link_reports_exe = (Get-JsonLines $r.Out | Select-Object -First 1).exe
            # A) in-place overwrite (CopyFile onto the existing name)
            [IO.File]::Copy($v2, $t, $true)
            $res.after_copy_overwrite = [ordered]@{ t = [S6Native]::FileId($t); link = [S6Native]::FileId($link); same_content = ((& $h $t) -eq (& $h $link)) }
            # B) replace by rename (write temp + MoveFileEx REPLACE_EXISTING), as installers/updaters do
            Copy-Item $v3 "$t.tmp" -Force
            Move-Item -LiteralPath "$t.tmp" -Destination $t -Force
            $res.after_rename_replace = [ordered]@{ t = [S6Native]::FileId($t); link = [S6Native]::FileId($link); same_content = ((& $h $t) -eq (& $h $link)); link_is_v2 = ((& $h $link) -eq (& $h $v2)) }
            # C) file locks while the CLI runs through the link
            Remove-Item $link -Force; [void][S6Native]::TryHardLink($link, $t)
            $psi = [Diagnostics.ProcessStartInfo]::new($link, 'sleep 5'); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            $p = [Diagnostics.Process]::Start($psi); [void]$p.StandardOutput.ReadLine()
            $lock = [ordered]@{}
            try { [IO.File]::Copy($v2, $t, $true); $lock.overwrite = 'ok' } catch { $lock.overwrite = $_.Exception.InnerException.Message ?? $_.Exception.Message }
            try { Remove-Item -LiteralPath $t -Force -ErrorAction Stop; $lock.delete = 'ok' } catch { $lock.delete = $_.Exception.Message }
            try { Rename-Item -LiteralPath $t -NewName 't.old.exe' -ErrorAction Stop; $lock.rename = 'ok'; Rename-Item -LiteralPath (Join-Path $dir 't.old.exe') -NewName 't.exe' } catch { $lock.rename = $_.Exception.Message }
            $p.Kill(); $p.WaitForExit()
            $res.locks_while_running_via_link = $lock
            # D) same for the forwarder file itself in WindowsApps (install-cli upgrade path)
            $fw = Join-Path $WA 'wmuxspikefwd.exe'
            $psi = [Diagnostics.ProcessStartInfo]::new($fw, 'sleep 5'); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            $p = [Diagnostics.Process]::Start($psi); [void]$p.StandardOutput.ReadLine()
            $lock = [ordered]@{}
            try { [IO.File]::Copy($S6.Fwd, $fw, $true); $lock.overwrite = 'ok' } catch { $lock.overwrite = $_.Exception.Message }
            try { Rename-Item -LiteralPath $fw -NewName 'wmuxspikefwd.exe.old' -ErrorAction Stop; $lock.rename = 'ok' } catch { $lock.rename = $_.Exception.Message }
            if ($lock.rename -eq 'ok') {
                try { Copy-Item $S6.Fwd $fw -Force; $lock.copy_new_after_rename = 'ok' } catch { $lock.copy_new_after_rename = $_.Exception.Message }
                try { Remove-Item -LiteralPath "$fw.old" -Force -ErrorAction Stop; $lock.delete_old_while_running = 'ok' } catch { $lock.delete_old_while_running = $_.Exception.Message }
            }
            $p.Kill(); $p.WaitForExit()
            Start-Sleep -Milliseconds 300
            if (Test-Path "$fw.old") { Remove-Item -LiteralPath "$fw.old" -Force; $lock.delete_old_after_exit = 'ok' }
            $res.locks_forwarder_in_windowsapps = $lock
            # E) symbolic links (Developer Mode off -> privilege error expected)
            $sym = Join-Path $S6.Run 'sym.exe'
            $res.symlink_unprivileged_flag = [S6Native]::TrySymlink($sym, $S6.Target, 2)
            $res.symlink_plain = [S6Native]::TrySymlink($sym, $S6.Target, 0)
            Remove-Item -ErrorAction SilentlyContinue $sym
            # F) volumes available for a cross-volume hard link test
            $res.fixed_volumes = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID })
        } finally {
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -like "$dir*" -or $_.Path -eq $link) } | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            Remove-Item -ErrorAction SilentlyContinue $link
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $S6.Run 'hl')
        }
        $summary.groups.links = Save-Result 'links' $res
    }

    # ---------------------------------------------- job object / process tree
    if (Want 'job') {
        $res = [ordered]@{}
        function Start-Fwd([string]$argsLine, [hashtable]$envAdd) {
            $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $WA 'wmuxspikefwd.exe'), $argsLine)
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            if ($envAdd) { foreach ($k in $envAdd.Keys) { $psi.Environment[$k] = $envAdd[$k] } }
            return [Diagnostics.Process]::Start($psi)
        }
        foreach ($mode in 'default', 'nojob') {
            $envAdd = if ($mode -eq 'nojob') { @{ WMUXSPIKEFWD_MODE = 'nojob' } } else { $null }
            $p = Start-Fwd 'sleep 20' $envAdd
            $line = $p.StandardOutput.ReadLine(); $tpid = [int]($line -replace '^PID=', '')
            $p.Kill()   # forwarder only (not the tree)
            $p.WaitForExit(); Start-Sleep -Milliseconds 500
            $alive = [bool](Get-Process -Id $tpid -ErrorAction SilentlyContinue)
            $res["kill_forwarder/$mode"] = [ordered]@{ target_pid = $tpid; target_alive_after = $alive }
            if ($alive) { Stop-Process -Id $tpid -Force }
        }
        $p = Start-Fwd 'spawn-grandchild 20' $null
        $line = $p.StandardOutput.ReadLine(); $p.WaitForExit()
        $gpid = [int]($line -replace '^GPID=', '')
        Start-Sleep -Milliseconds 500
        $alive = [bool](Get-Process -Id $gpid -ErrorAction SilentlyContinue)
        $res.grandchild_survives_forwarder_exit = [ordered]@{ forwarder_exit = $p.ExitCode; grandchild_alive = $alive }
        if ($alive) { Stop-Process -Id $gpid -Force }
        $summary.groups.job = Save-Result 'job' $res
    }

    # Launch overhead and first-launch (AV/EDR) cost: see s6-timing.ps1 (one hidden console,
    # interleaved rounds; this harness's per-launch conhost would dominate the numbers).

    # ------------------------------------------------------------ WSL interop
    if (Want 'wsl') {
        $res = [ordered]@{}
        $running = ((& wsl.exe -l --running 2>&1) -join "`n") -replace "`0", ''
        $res.running = $running.Trim()
        if ($running -match 'Ubuntu') {
            $f = Join-Path $S6.Run 'wsl.sh'
            # This distro has [interop] appendWindowsPath=false, so the Windows PATH is not
            # visible; append WindowsApps as appendWindowsPath=true (the default) would.
            $res.wsl_conf = ((& wsl.exe -d Ubuntu-24.04 -e sh -c 'grep -i appendWindowsPath /etc/wsl.conf' 2>&1) -join ' ') -replace "`0", ''
            $script = @'
case "$1" in append) export PATH="$PATH:__WAPATH__";; esac
echo "@@MODE ${1:-default}"
p=$(command -v wmuxspikefwd.exe); echo "@@CMDV_EXE ${p:-none}"
p=$(command -v wmuxspikefwd); echo "@@CMDV_NOEXT ${p:-none}"
p=$(command -v wmuxspikefwdsh); echo "@@CMDV_SH ${p:-none}"
wmuxspikefwd.exe argv 'a b' '' 'x"y'; echo "@@RC_EXE $?"
wmuxspikefwdsh argv 'via sh'; echo "@@RC_SH $?"
printf 'hello\n' | wmuxspikefwd.exe sha; echo "@@RC_PIPE $?"
wmuxspikefwd.exe exit 300; echo "@@RC_300 $?"
'@
            $waWsl = '/mnt/c/' + ($S6.WA.Substring(3) -replace '\\', '/')
            [IO.File]::WriteAllText($f, $script.Replace("`r`n", "`n").Replace('__WAPATH__', $waWsl), [Text.UTF8Encoding]::new($false))
            $wslPath = '/mnt/c/' + ($f.Substring(3) -replace '\\', '/')
            foreach ($mode in 'default', 'append') {
                $r = Invoke-Proc -File 'wsl.exe' -Arguments "-d Ubuntu-24.04 -e sh $wslPath $mode" -TimeoutMs 60000
                $res["$mode/markers"] = Get-Markers $r.Out
                $res["$mode/json"] = @(Get-JsonLines $r.Out | ForEach-Object { [ordered]@{ argv = $_.argv; exe = $_.exe } })
                $res["$mode/other"] = @($r.Out -split "`n" | Where-Object { $_ -and $_ -notmatch '^@@' -and $_ -notmatch '^\{"cmdline"' })
                $res["$mode/err"] = $r.Err.Trim()
            }
        }
        $summary.groups.wsl = Save-Result 'wsl' $res
    }

    # ---------------------- programmatic spawn without a shell (agents, runtimes)
    if (Want 'spawn') {
        $res = [ordered]@{}
        foreach ($n in 'wmuxspikefwd', 'wmuxspikefwdc', 'wmuxspikefwdcmd', 'wmuxspikefwdhl', 'wmuxspikefwdc.com', 'wmuxspikefwdcmd.cmd') {
            $res["CreateProcessW(NULL, '$n exit 7')"] = [S6Native]::SpawnNoShell("$n exit 7")
            try {
                $psi = [Diagnostics.ProcessStartInfo]::new($n, 'exit 7'); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit(); $res[".NET Process.Start('$n')"] = "exit $($p.ExitCode)"
            } catch { $res[".NET Process.Start('$n')"] = "error: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
        }
        $summary.groups.spawn = Save-Result 'spawn' $res
    }

    # ------------------------------------------------------ forwarder error paths
    if (Want 'errors') {
        $res = [ordered]@{}
        try {
            Set-ItemProperty -Path $S6.RegKey -Name InstallDir -Value (Join-Path $S6.Scratch 'no-such-dir')
            $r = Invoke-Proc -File (Join-Path $WA 'wmuxspikefwd.exe') -Arguments 'argv'
            $res.target_missing = [ordered]@{ rc = $r.ExitCode; err = $r.Err.Trim() }
            Remove-ItemProperty -Path $S6.RegKey -Name InstallDir
            $r = Invoke-Proc -File (Join-Path $WA 'wmuxspikefwd.exe') -Arguments 'argv'
            $res.registry_missing = [ordered]@{ rc = $r.ExitCode; err = $r.Err.Trim() }
        } finally { New-ItemProperty -Path $S6.RegKey -Name InstallDir -Value $S6.Install -PropertyType String -Force | Out-Null }
        $summary.groups.errors = Save-Result 'errors' $res
    }

    # still there? (AV quarantine would delete files)
    $summary.present_at_end = @(Get-SpikeWindowsAppsFiles | ForEach-Object Name)
}
finally {
    & (Join-Path $PSScriptRoot 's6-cleanup.ps1') | ForEach-Object { $summary.cleanup += @("$_") }
    if ($sampler) { New-Item -ItemType File -Force $stopFile | Out-Null; [void]$sampler.WaitForExit(5000) }
    $summary.finished = (Get-Date).ToString('o')
    Save-Result 'summary' $summary | Out-Null
    $summary | ConvertTo-Json -Depth 5
}
