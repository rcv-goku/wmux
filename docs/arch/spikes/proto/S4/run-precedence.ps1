# S4 spike: which "claude" does each launcher run when the shim dir is prepended to PATH?
# Dummies only (ident.exe copies and echo scripts). Prints one row per (scenario, launcher).
param([Parameter(Mandatory)] [string] $Root)
. "$PSScriptRoot\common.ps1"
$B = $script:S4Base
$bash = 'C:\Program Files\Git\bin\bash.exe'
$launchers = [ordered]@{
    'cmd /c'          = @('C:\Windows\System32\cmd.exe', @('/d', '/c', 'claude --probe'))
    'pwsh 7'          = @('C:\Program Files\PowerShell\7\pwsh.exe', @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'claude --probe'))
    'powershell 5.1'  = @('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'claude --probe'))
    'git bash -c'     = @($bash, @('-c', 'claude --probe'))
    'git bash -lc'    = @($bash, @('-l', '-c', 'claude --probe'))
    'CreateProcess'   = @("$Root\bin\spawner.exe", @('create', 'claude', '--probe'))
    '.NET Process'    = @('C:\Program Files\PowerShell\7\pwsh.exe', @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                          '$p=[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName="claude";Arguments="--probe";UseShellExecute=$false;RedirectStandardOutput=$true}); $p.StandardOutput.ReadToEnd()'))
    'where.exe'       = @('C:\Windows\System32\where.exe', @('claude'))
}

function Who($r) {
    $o = $r.Out + "`n" + $r.Err
    if ($o -match 'S4NPM via=(\S+)') { return "npm\" + $Matches[1] }
    if ($o -match 'S4SAMEDIR via=(\S+)') { return "samedir\" + $Matches[1] }
    if ($o -match 'S4CWD via=(\S+)') { return $Matches[1] }
    if ($o -match 'S4IDENT exe=(.+)') { return ($Matches[1].Trim()).Replace("$Root\", '') }
    $first = ($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / '
    return "NONE (exit $($r.Code)): $first"
}

$scenarios = @(
    @{ Id = 'A'; Desc = 'shims first, npm (cmd+ps1+sh) later';          Path = "$Root\shims\agents;$Root\npm;$B" }
    @{ Id = 'B'; Desc = 'shims first, native claude.exe later';         Path = "$Root\shims\agents;$Root\native;$B" }
    @{ Id = 'C'; Desc = 'CONTROL npm first, shims later';               Path = "$Root\npm;$Root\shims\agents;$B" }
    @{ Id = 'D'; Desc = 'A with PATHEXT=.CMD;.BAT;.PS1;.EXE;.COM';      Path = "$Root\shims\agents;$Root\npm;$B"; Env = @{ PATHEXT = '.CMD;.BAT;.PS1;.EXE;.COM' } }
    @{ Id = 'E'; Desc = 'one dir with claude.exe+.cmd+.ps1+sh';         Path = "$Root\samedir;$B" }
    @{ Id = 'F'; Desc = 'A, cwd contains claude.cmd';                   Path = "$Root\shims\agents;$Root\npm;$B"; Cwd = "$Root\cwdtest" }
    @{ Id = 'G'; Desc = 'A, cwd contains claude.exe (native)';          Path = "$Root\shims\agents;$Root\npm;$B"; Cwd = "$Root\native" }
    @{ Id = 'H'; Desc = 'G + NoDefaultCurrentDirectoryInExePath=1';     Path = "$Root\shims\agents;$Root\npm;$B"; Cwd = "$Root\native"; Env = @{ NoDefaultCurrentDirectoryInExePath = '1' } }
    @{ Id = 'I'; Desc = 'npm only (no exe anywhere)';                   Path = "$Root\npm;$B" }
)

$log = Join-Path $Root 'logs\precedence.txt'
$fgLog = Join-Path $Root 'logs\fg-precedence.txt'
$job = Start-S4FgSampler $fgLog
Start-Sleep -Milliseconds 300
$rows = foreach ($s in $scenarios) {
    foreach ($name in $launchers.Keys) {
        $file, $argList = $launchers[$name]
        $envs = if ($s.Env) { $s.Env } else { @{} }
        $cwd = if ($s.Cwd) { $s.Cwd } else { $Root }
        $r = Invoke-S4 -File $file -ArgList $argList -Path $s.Path -Cwd $cwd -Env $envs
        Add-Content $log ("==== [{0}] {1} :: {2}`n{3}`n--- stderr ---`n{4}`n--- exit {5}" -f $s.Id, $s.Desc, $name, $r.Out, $r.Err, $r.Code)
        $who = if ($name -eq 'where.exe') { (($r.Out -split "`r?`n" | Where-Object { $_ }) | ForEach-Object { $_.Replace("$Root\", '') }) -join ' > ' } else { Who $r }
        [pscustomobject]@{ Scn = $s.Id; Launcher = $name; Ran = $who }
    }
}
# CreateProcess application-directory precedence: spawner.exe sits next to its own claude.exe.
$r = Invoke-S4 -File "$Root\spawnerdir\spawner.exe" -ArgList @('create', 'claude', '--probe') -Path "$Root\shims\agents;$Root\npm;$B" -Cwd $Root
Add-Content $log ("==== [J] spawner next to claude.exe :: CreateProcess`n{0}`n{1}" -f $r.Out, $r.Err)
$rows += [pscustomobject]@{ Scn = 'J'; Launcher = 'CreateProcess (spawner dir has claude.exe)'; Ran = (Who $r) }
# pwsh: full candidate list in resolution order
foreach ($sid in 'A', 'E') {
    $s = $scenarios | Where-Object Id -eq $sid
    $r = Invoke-S4 -File 'C:\Program Files\PowerShell\7\pwsh.exe' -ArgList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '(Get-Command claude -All -ErrorAction SilentlyContinue | ForEach-Object Source) -join " > "') -Path $s.Path -Cwd $Root
    $rows += [pscustomobject]@{ Scn = $sid; Launcher = 'pwsh Get-Command -All'; Ran = $r.Out.Trim().Replace("$Root\", '') }
}
# Git Bash: PATH as seen by bash (non-login vs login)
foreach ($mode in @(@('-c'), @('-l', '-c'))) {
    $r = Invoke-S4 -File $bash -ArgList ($mode + @('echo "$PATH"; type -a claude')) -Path "$Root\shims\agents;$Root\npm;$B" -Cwd $Root
    Add-Content $log ("==== bash {0} PATH`n{1}`n{2}" -f ($mode -join ' '), $r.Out, $r.Err)
    $first = ($r.Out -split "`n")[0]
    $rows += [pscustomobject]@{ Scn = 'A'; Launcher = "bash $($mode -join ' ') PATH head"; Ran = (($first -split ':') | Select-Object -First 6) -join ':' }
    $posixRoot = ('/' + $Root.Replace(':', '').Replace('\', '/')) -replace '^/([A-Za-z])/', { '/' + $_.Groups[1].Value.ToLower() + '/' }
    $rows += [pscustomobject]@{ Scn = 'A'; Launcher = "bash $($mode -join ' ') type -a"; Ran = ((($r.Out -split "`n") | Select-Object -Skip 1 | Where-Object { $_ }) -join ' > ').Replace("$posixRoot/", '') }
}
# Git Bash with a user rc that prepends a directory (simulates ~/.bashrc adding ~/.local/bin)
$rc = Join-Path $Root 'logs\fake-bashrc'
[IO.File]::WriteAllText($rc, "export PATH=`"$(('/' + $Root.Replace(':', '').Replace('\', '/')).Replace('/C/', '/c/'))/native:`$PATH`"`n")
$r = Invoke-S4 -File $bash -ArgList @('--rcfile', $rc, '-i', '-c', 'claude --probe') -Path "$Root\shims\agents;$Root\npm;$B" -Cwd $Root
Add-Content $log ("==== bash --rcfile (prepends native)`n{0}`n{1}" -f $r.Out, $r.Err)
$rows += [pscustomobject]@{ Scn = 'K'; Launcher = 'git bash -i with rc prepending native dir'; Ran = (Who $r) }
$fg = Stop-S4FgSampler $job $fgLog $Root
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
"foreground samples=$($fg.Samples) violations=$($fg.Violations.Count)"
$fg.Violations
