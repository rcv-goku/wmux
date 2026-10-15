# S4 spike: builds the dummy PATH layout under a temp root (no real agents involved).
#   shims\agents\claude.exe   hardlink of ident.exe  (stands in for the wmux wrapper shim)
#   shims\wrap\claude.exe     hardlink of wrapper.exe (the ADR-10.6 wrapper prototype)
#   native\claude.exe         copy of ident.exe      (stands in for %USERPROFILE%\.local\bin\claude.exe)
#   npm\claude.cmd|.ps1|claude (sh) + npm\node.exe (ident copy) + node_modules\...\cli.js
#   samedir\claude.exe|.cmd|.ps1|claude   (within-directory precedence)
#   cwdtest\claude.cmd        (current-directory precedence)
#   spawnerdir\spawner.exe + claude.exe (application-directory precedence of CreateProcess)
#   teams\tmux.exe            hardlink of ident.exe  (stands in for the tmux compat shim)
#   tmuxlater\tmux.cmd, tmuxlater\tmux (sh)
param([Parameter(Mandatory)] [string] $Root)
$ErrorActionPreference = 'Stop'
$bin = Join-Path $Root 'bin'
$dirs = 'shims\agents', 'shims\wrap', 'native', 'npm\node_modules\@anthropic-ai\claude-code', 'samedir', 'cwdtest',
        'spawnerdir', 'teams', 'tmuxlater', 'proj dir with spaces', 'logs'
foreach ($d in $dirs) { New-Item -ItemType Directory -Force (Join-Path $Root $d) | Out-Null }

function Link($target, $link) {
    if (Test-Path $link) { Remove-Item $link -Force }
    New-Item -ItemType HardLink -Path $link -Target $target | Out-Null
}
Link "$bin\ident.exe"   "$Root\shims\agents\claude.exe"
Link "$bin\wrapper.exe" "$Root\shims\wrap\claude.exe"
Link "$bin\ident.exe"   "$Root\teams\tmux.exe"
Copy-Item "$bin\ident.exe"   "$Root\native\claude.exe" -Force
Copy-Item "$bin\ident.exe"   "$Root\npm\node.exe" -Force
Copy-Item "$bin\ident.exe"   "$Root\samedir\claude.exe" -Force
Copy-Item "$bin\spawner.exe" "$Root\spawnerdir\spawner.exe" -Force
Copy-Item "$bin\ident.exe"   "$Root\spawnerdir\claude.exe" -Force
Set-Content -NoNewline -Path "$Root\npm\node_modules\@anthropic-ai\claude-code\cli.js" -Value "// dummy cli.js (never executed)`n"

$crlf = "`r`n"
# npm cmd-shim lookalike (same control flow as npm's generated .cmd: SETLOCAL, node.exe next to
# the shim or on PATH, endLocal & goto trick, title, "%dp0%\<script>" %*).
$cmd = @(
    '@ECHO off', 'GOTO start', ':find_dp0', 'SET dp0=%~dp0', 'EXIT /b', ':start', 'SETLOCAL', 'CALL :find_dp0',
    'ECHO S4NPM via=claude.cmd', '',
    'IF EXIST "%dp0%\node.exe" (', '  SET "_prog=%dp0%\node.exe"', ') ELSE (', '  SET "_prog=node"',
    '  SET PATHEXT=%PATHEXT:;.JS;=;%', ')', '',
    'endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@anthropic-ai\claude-code\cli.js" %*'
) -join $crlf
Set-Content -NoNewline -Path "$Root\npm\claude.cmd" -Value ($cmd + $crlf)

$ps1 = @(
    '#!/usr/bin/env pwsh', '$basedir=Split-Path $MyInvocation.MyCommand.Definition -Parent',
    'Write-Output "S4NPM via=claude.ps1"', '$exe=""',
    'if ($PSVersionTable.PSVersion -lt "6.0" -or $IsWindows) { $exe=".exe" }', '$ret=0',
    'if (Test-Path "$basedir/node$exe") {',
    '  & "$basedir/node$exe" "$basedir/node_modules/@anthropic-ai/claude-code/cli.js" $args',
    '  $ret=$LASTEXITCODE', '} else {',
    '  & "node$exe" "$basedir/node_modules/@anthropic-ai/claude-code/cli.js" $args', '  $ret=$LASTEXITCODE', '}',
    'exit $ret'
) -join $crlf
Set-Content -NoNewline -Path "$Root\npm\claude.ps1" -Value ($ps1 + $crlf)

$sh = @(
    '#!/bin/sh', 'basedir=$(dirname "$(echo "$0" | sed -e ''s,\\,/,g'')")', 'echo "S4NPM via=claude(sh)"',
    'if [ -x "$basedir/node" ]; then', '  exec "$basedir/node" "$basedir/node_modules/@anthropic-ai/claude-code/cli.js" "$@"',
    'else', '  exec node "$basedir/node_modules/@anthropic-ai/claude-code/cli.js" "$@"', 'fi'
) -join "`n"
[IO.File]::WriteAllText("$Root\npm\claude", $sh + "`n")

# same-directory collision set
Set-Content -NoNewline -Path "$Root\samedir\claude.cmd" -Value ("@echo S4SAMEDIR via=claude.cmd" + $crlf)
Set-Content -NoNewline -Path "$Root\samedir\claude.ps1" -Value ('Write-Output "S4SAMEDIR via=claude.ps1"' + $crlf)
[IO.File]::WriteAllText("$Root\samedir\claude", "#!/bin/sh`necho `"S4SAMEDIR via=claude(sh)`"`n")
# current-directory decoy
Set-Content -NoNewline -Path "$Root\cwdtest\claude.cmd" -Value ("@echo S4CWD via=cwdtest\claude.cmd" + $crlf)
# later tmux variants
Set-Content -NoNewline -Path "$Root\tmuxlater\tmux.cmd" -Value ("@echo S4TMUX via=tmux.cmd %*" + $crlf)
[IO.File]::WriteAllText("$Root\tmuxlater\tmux", "#!/bin/sh`necho `"S4TMUX via=tmux(sh) `$*`"`n")
Get-ChildItem -Recurse $Root -File | Where-Object { $_.FullName -notmatch '\\(zcache|bin)\\' } |
    ForEach-Object { $_.FullName.Substring($Root.Length + 1) }
