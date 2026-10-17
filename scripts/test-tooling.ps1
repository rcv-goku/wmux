#Requires -Version 7.0
<#
.SYNOPSIS
    Self-tests of the parity-program tooling (scripts/lib/WmuxTooling.psm1 and the check scripts).

.DESCRIPTION
    Runs without Zig and without network in a few seconds (CI job "Tooling"):
      - module: YAML-subset front matter, globs, WP ids, known-failures file, Zig test-log parsing;
      - check-ownership.ps1 against a throwaway git repository (owned, touches, appends,
        frozen, self-granted ownership, untracked files, missing spec);
      - check-manifest.ps1 against throwaway skeleton trees (consistent, broken, no skeleton);
      - gate.ps1 -DryRun and new-worktree.ps1 -WhatIf against this checkout (nothing is executed
        or created).
    Fixtures live under $env:TEMP and are deleted afterwards.

.EXAMPLE
    pwsh scripts/test-tooling.ps1

.NOTES
    Exit codes: 0 = all checks passed, 1 = at least one failed.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib/WmuxTooling.psm1') -Force

$script:passed = 0
$script:failed = 0
$pwsh = Get-WmuxPwshExe
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Test-That([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        $script:passed++
        Write-Host "  ok    $Name"
    } else {
        $script:failed++
        Write-Host "  FAIL  $Name $(if ($Detail) { "-- $Detail" })"
    }
}

function Test-Throws([string]$Name, [scriptblock]$Block, [string]$Pattern = '') {
    $msg = $null
    try { & $Block | Out-Null } catch { $msg = $_.Exception.Message }
    Test-That $Name (($null -ne $msg) -and (-not $Pattern -or $msg -match $Pattern)) "message: $msg"
}

function Write-Fixture([string]$Root, [string]$Rel, [string[]]$Lines) {
    $path = Join-Path $Root $Rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), $utf8)
}

function Invoke-Script([string]$Script, [string[]]$Arguments, [switch]$Child) {
    # In-process by default (all streams captured); -Child runs a separate pwsh, which is
    # needed where output goes straight to the host (ShouldProcess "What if" lines).
    $path = Join-Path $PSScriptRoot $Script
    if ($Child) {
        $out = & $pwsh -NoProfile -NonInteractive -File $path @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    }
    # Array splatting binds '-Name' strings positionally for scripts; build a hashtable.
    $named = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $name = $Arguments[$i].TrimStart('-')
        if ($i + 1 -lt $Arguments.Count -and -not $Arguments[$i + 1].StartsWith('-')) { $named[$name] = $Arguments[$i + 1]; $i++ }
        else { $named[$name] = $true }
    }
    $global:LASTEXITCODE = 0
    try {
        $out = & $path @named *>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    } catch {
        return [pscustomobject]@{ Code = 99; Output = "unhandled: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    }
}

function Invoke-FixtureGit([string]$Repo, [string[]]$Arguments) {
    $all = @('-C', $Repo, '-c', 'user.name=tooling-test', '-c', 'user.email=tooling-test@example.invalid', '-c', 'core.autocrlf=false') + $Arguments
    $out = & git @all 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wmux-tooling-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

try {
    # ------------------------------------------------------------ module
    Write-Host 'module: WP ids'
    foreach ($id in 'W2-5', 'W1-1a', 'W0-D-S1', 'W0-C', 'W12-3', 'W5a-3', 'PB-notif', 'PB-web-taskmgr-todo', 'W1-1a-t') { Test-That "valid id $id" (Test-WmuxWpId $id) }
    foreach ($id in 'w2-5', 'W2', 'W2-', 'X1-2', 'W2-5 ', 'W2_5', 'W5ab-1', 'W5a', 'PB', 'PB-', 'pb-notif', 'PB_notif', 'PBX-1') { Test-That "invalid id '$id'" (-not (Test-WmuxWpId $id)) }

    Write-Host 'module: file classes and aggregators (AF-15)'
    Test-That 'frozen: fast_tests.zig' (Test-WmuxFrozenPath 'src/apprt/win32/fast_tests.zig')
    Test-That 'frozen: src/terminal (plan note 6)' (Test-WmuxFrozenPath 'src/terminal/PageList.zig')
    Test-That 'not frozen: a feature file' (-not (Test-WmuxFrozenPath 'src/apprt/win32/features/todo/logic/model.zig'))
    Test-That 'aggregator: feature logic/tests.zig' (Test-WmuxAggregatorPath 'src/apprt/win32/features/todo/logic/tests.zig')
    Test-That 'aggregator: proto.zig and wmux_cli logic/tests.zig' ((Test-WmuxAggregatorPath 'src/wmux_proto/proto.zig') -and (Test-WmuxAggregatorPath 'src/wmux_cli/logic/tests.zig'))
    Test-That 'aggregator: not a logic file' (-not (Test-WmuxAggregatorPath 'src/apprt/win32/features/todo/logic/model.zig'))
    Test-That 'schema path' ((Get-WmuxSchemaPath) -eq 'docs/wmux/schema/wmux.schema.json')
    $okLines = @('//! index', 'const std = @import("std");', 'test {', '    _ = @import("a.zig");', '    // a note inside the run', '    _ = @import("b.zig");', '}',
        'pub const zeta = @import("zeta.zig");', 'pub const alpha = struct {', '    pub const a = @import("x/a.zig");', '};')
    Test-That 'aggregator: sorted runs pass (helpers and comments ignored)' ((Get-WmuxAggregatorIssues -Lines $okLines).Count -eq 0)
    $bad = Get-WmuxAggregatorIssues -Lines @('test {', '    _ = @import("b.zig");', '    _ = @import("a.zig");', '    _ = @import("a.zig");', '    _ = @import("c.zig"); _ = @import("d.zig");', '}')
    Test-That 'aggregator: unsorted entry' (@($bad | Where-Object { $_.Line -eq 3 -and $_.Message -match 'not sorted' }).Count -eq 1) ($bad | Out-String)
    Test-That 'aggregator: duplicate entry' (@($bad | Where-Object { $_.Line -eq 4 -and $_.Message -match 'duplicate' }).Count -eq 1) ($bad | Out-String)
    Test-That 'aggregator: two imports on one line' (@($bad | Where-Object { $_.Line -eq 5 -and $_.Message -match 'one entry per line' }).Count -eq 1) ($bad | Out-String)
    Test-That 'glob overlap: dir glob vs file' (Test-WmuxGlobOverlap 'src/web/todo/**' 'src/web/todo/app.js')
    Test-That 'glob overlap: disjoint suites' (-not (Test-WmuxGlobOverlap 'test/e2e/suites/p/W1-4a.e2e.ps1' 'test/e2e/suites/p/W1-4b*.e2e.ps1'))
    $ledgerFile = Join-Path $fixtureRoot 'manual-checks.md'
    Write-Fixture $fixtureRoot 'manual-checks.md' @('# ledger', '', '| id | check |', '|---|---|', '| `core-ime-composition` | IME |', '| toasts-real-click | click |')
    $led = Read-WmuxManualLedger -Path $ledgerFile
    Test-That 'ledger: rows read, header skipped' (($led.Count -eq 2) -and $led.Contains('core-ime-composition') -and -not $led.Contains('id'))

    Write-Host 'module: YAML front matter'
    $template = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../docs/arch/wp/_template.md'))
    $d = Read-WmuxFrontMatter -Text $template -Source '_template.md'
    Test-That 'template id' ($d['id'] -eq 'W2-5')
    Test-That 'template size strips the comment' ($d['size'] -eq 'L')
    Test-That 'template depends flow list' ((@($d['depends']) -join ',') -eq 'W1-1,W1-4,W1-8')
    Test-That 'template covers block list' (@($d['covers']).Count -eq 2)
    Test-That 'template owns keeps globs' (@($d['owns'])[3] -eq 'test/e2e/suites/notifications/W2-5*.e2e.ps1')
    Test-That 'template touches list of maps' ((@($d['touches'])[0]['path'] -eq 'src/apprt/surface.zig') -and (@($d['touches'])[0]['reason'] -like 'heap notification*'))
    Test-That 'template empty flow lists' ((@($d['ccr']).Count -eq 0) -and ($d['apis_needed'] -is [System.Collections.IList]))
    $ccr = Read-WmuxFrontMatter -Text ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../docs/arch/ccr/_template.md'))) -Source 'ccr/_template.md'
    Test-That 'CCR template parses' (($ccr['status'] -eq 'proposed') -and ($ccr['decision']['outcome'] -eq '') -and (@($ccr['files'])[0]['class'] -eq 'frozen'))
    $own = Read-WmuxFrontMatter -Text ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../docs/arch/wp/W0-C.md'))) -Source 'wp/W0-C.md'
    Test-That 'W0-C spec parses' (($own['id'] -eq 'W0-C') -and (@($own['owns']) -contains 'scripts/**'))

    $y = ConvertFrom-WmuxYaml -Lines @(
        'a: "quoted # not a comment"  # comment',
        "b: 'it''s'",
        'c: plain value: with colon',
        'd:',
        '- x',
        '- y',
        'e:',
        '  f: 1',
        '  g: [p, "q, r"]',
        'h: {}',
        'i: ~',
        'j: the WP''s file  # trailing comment',
        'k:',
        '  - path: one',
        '    reason: first',
        '  - two')
    Test-That 'yaml double-quoted with #' ($y['a'] -eq 'quoted # not a comment')
    Test-That 'yaml single-quoted escape' ($y['b'] -eq "it's")
    Test-That 'yaml colon inside value' ($y['c'] -eq 'plain value: with colon')
    Test-That 'yaml sequence at key indent' ((@($y['d']) -join ',') -eq 'x,y')
    Test-That 'yaml nested map' (($y['e']['f'] -eq '1') -and ((@($y['e']['g']) -join '|') -eq 'p|q, r'))
    Test-That 'yaml empty map and null' (($y['h'] -is [System.Collections.IDictionary]) -and ($null -eq $y['i']))
    Test-That 'yaml apostrophe in plain scalar' ($y['j'] -eq "the WP's file")
    Test-That 'yaml mixed list' ((@($y['k'])[0]['reason'] -eq 'first') -and (@($y['k'])[1] -eq 'two'))
    Test-Throws 'yaml rejects tabs' { ConvertFrom-WmuxYaml -Lines @("a:", "`t- x") } 'tab'
    Test-Throws 'yaml rejects duplicate keys' { ConvertFrom-WmuxYaml -Lines @('a: 1', 'a: 2') } 'duplicate'
    Test-Throws 'yaml rejects bad indentation' { ConvertFrom-WmuxYaml -Lines @('a: 1', '   b: 2') } 'indentation'
    Test-Throws 'yaml rejects block scalars' { ConvertFrom-WmuxYaml -Lines @('a: |') } 'unsupported'
    Test-Throws 'front matter required' { Read-WmuxFrontMatter -Text "# title`n" } 'front matter'
    Test-Throws 'front matter must close' { Read-WmuxFrontMatter -Text "---`na: 1`n" } 'unterminated'

    Write-Host 'module: globs'
    $globCases = @(
        @('src/apprt/win32/features/notifications/logic/store.zig', 'src/apprt/win32/features/notifications/**', $true),
        @('src/apprt/win32/features/notifications_x/mod.zig', 'src/apprt/win32/features/notifications/**', $false),
        @('test/e2e/suites/notifications/W2-5-core.e2e.ps1', 'test/e2e/suites/notifications/W2-5*.e2e.ps1', $true),
        @('test/e2e/suites/notifications/sub/W2-5.e2e.ps1', 'test/e2e/suites/notifications/W2-5*.e2e.ps1', $false),
        @('docs/arch/ccr/W2-5-1.md', 'docs/arch/{wp,ccr}/**', $true),
        @('docs/arch/spikes/S1.md', 'docs/arch/{wp,ccr}/**', $false),
        @('src/foo.zig', 'src/**/foo.zig', $true),
        @('src/a/b/foo.zig', 'src/**/foo.zig', $true),
        @('SRC/A/foo.zig', 'src/**/foo.zig', $true),
        @('scripts/lib/x.psm1', 'scripts/', $true),
        @('.github/workflows/windows-ci.yml', '.github/**', $true),
        @('AGENTS.md', './AGENTS.md', $true),
        @('xAGENTS.md', 'AGENTS.md', $false),
        @('src/a.zig', 'src/?.zig', $true),
        @('src/ab.zig', 'src/?.zig', $false)
    )
    foreach ($c in $globCases) { Test-That "glob '$($c[1])' vs '$($c[0])' = $($c[2])" ((Test-WmuxGlobMatch -Path $c[0] -Glob $c[1]) -eq $c[2]) }

    Write-Host 'module: known failures and zig test logs'
    $kf = Join-Path $fixtureRoot 'known-failures.txt'
    Write-Fixture $fixtureRoot 'known-failures.txt' @(
        '# comment',
        '',
        'cli.ssh-cache.DiskCache.test.disk cache default path  # reason one',
        'sub.Thing.test.*  # whole file')
    $entries = Read-WmuxKnownFailures -Path $kf
    Test-That 'known failures: two entries' ($entries.Count -eq 2)
    Test-That 'known failures: reason parsed' ($entries[0].Reason -eq 'reason one')
    Test-That 'known failures: exact match' ($null -ne (Find-WmuxKnownFailure -Name 'cli.ssh-cache.DiskCache.test.disk cache default path' -Entries $entries))
    Test-That 'known failures: exact is not prefix' ($null -eq (Find-WmuxKnownFailure -Name 'cli.ssh-cache.DiskCache.test.disk cache default path 2' -Entries $entries))
    Test-That 'known failures: prefix match' ($null -ne (Find-WmuxKnownFailure -Name 'sub.Thing.test.anything' -Entries $entries))
    Test-That 'known failures: case-sensitive' ($null -eq (Find-WmuxKnownFailure -Name 'SUB.Thing.test.anything' -Entries $entries))
    Test-That 'known failures: missing file' ((Read-WmuxKnownFailures -Path (Join-Path $fixtureRoot 'nope.txt')).Count -eq 0)
    $sample = @(
        'test',
        '+- run test 4/7 passed, 2 failed, 1 skipped',
        "error: 'main.test.unit: beta: fails' failed: expected 1, found 2",
        'C:\zig\lib\std\testing.zig:110:17: 0x7ff7fd1b1143 in expectEqualInner__anon_473 (test_zcu.obj)',
        "error: 'sub.Thing.test.disk cache default path' failed: C:\x\Thing.zig:2:34: 0x7ff in test.disk (test_zcu.obj)",
        "error: 'a.test.leaky' leaked: 1 allocation",
        "error: while executing test 'sub.Thing.test.skipped one', the following test command failed:",
        "error: while executing test 'b.test.crashy', the following command exited with code 3 (expected exited with code 0):",
        'Build Summary: 1/3 steps succeeded; 1 failed; 4/7 tests passed; 1 skipped; 2 failed')
    $p = ConvertFrom-WmuxZigTestLog -Lines $sample
    Test-That 'zig log: failures found' ((@($p.Failures.Keys) -join '|') -eq 'main.test.unit: beta: fails|sub.Thing.test.disk cache default path|a.test.leaky|b.test.crashy')
    Test-That 'zig log: kinds' (($p.Failures['a.test.leaky'] -eq 'leaked') -and ($p.Failures['b.test.crashy'] -eq 'crashed'))
    Test-That 'zig log: generic failure line ignored' (-not $p.Failures.Contains('sub.Thing.test.skipped one'))
    Test-That 'zig log: no compile errors' ($p.CompileErrors.Count -eq 0)
    Test-That 'zig log: summary counts' (($p.TestsPassed -eq 4) -and ($p.TestsTotal -eq 7))
    $c = ConvertFrom-WmuxZigTestLog -Lines @('src\apprt\win32\App.zig:12:5: error: expected type ''u8''', 'Build Summary: 0/3 steps succeeded; 1 failed')
    Test-That 'zig log: compile error detected' ($c.CompileErrors.Count -eq 1)

    # ------------------------------------------------------------ check-ownership
    Write-Host 'check-ownership: fixture repository'
    $repo = Join-Path $fixtureRoot 'own'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    Invoke-FixtureGit $repo @('init', '-q', '-b', 'master')
    Write-Fixture $repo 'docs/arch/wp/W9-1.md' @(
        '---', 'id: W9-1', 'title: Fixture', 'wave: 1', 'size: S', 'depends: []', 'covers: []',
        'owns:', '  - src/apprt/win32/features/foo/**', '  - src/apprt/win32/model/**', '  - changes/W9-1.md',
        'touches:', '  - path: src/apprt/win32/App.zig', '    reason: one-line facade',
        'appends:', '  - src/wmux_proto/events_catalog.zig',
        'apis_needed: []', 'ccr: []', 'deviations: []', '---', '', '## Design notes')
    Write-Fixture $repo 'src/apprt/win32/App.zig' @('const std = @import("std");')
    Write-Fixture $repo 'src/apprt/win32/model/Workspace.zig' @('pub const Workspace = struct {};')
    Write-Fixture $repo 'src/wmux_proto/events_catalog.zig' @('"a",', '"c",')
    Write-Fixture $repo 'src/other.zig' @('// other')
    Invoke-FixtureGit $repo @('add', '-A')
    Invoke-FixtureGit $repo @('commit', '-q', '-m', 'base')

    # a) everything inside the spec, plus a CCR and an untracked stray file
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-1-ok')
    Write-Fixture $repo 'src/apprt/win32/features/foo/mod.zig' @('pub const id = "foo";')
    Write-Fixture $repo 'src/apprt/win32/App.zig' @('const std = @import("std");', '// facade')
    Write-Fixture $repo 'src/wmux_proto/events_catalog.zig' @('"a",', '"b",', '"c",')
    Write-Fixture $repo 'docs/arch/ccr/W9-1-1.md' @('---', 'id: W9-1-1', '---')
    Invoke-FixtureGit $repo @('add', '-A')
    Invoke-FixtureGit $repo @('commit', '-q', '-m', 'ok')
    Write-Fixture $repo 'stray.txt' @('untracked')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: owned/touches/appends/CCR pass' ($r.Code -eq 0) $r.Output
    Test-That 'ownership: touches reason printed' ($r.Output -match 'touches src/apprt/win32/App.zig \(one-line facade\)')
    Test-That 'ownership: untracked stray file only warns' ($r.Output -match 'stray\.txt \[untracked\]' -and $r.Output -match '0 violation\(s\), 1 warning\(s\)') $r.Output
    Remove-Item -LiteralPath (Join-Path $repo 'stray.txt')

    # b) a file outside the spec; the branch also tries to grant itself ownership
    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-1-bad')
    Write-Fixture $repo 'src/other.zig' @('// changed')
    $specText = [System.IO.File]::ReadAllText((Join-Path $repo 'docs/arch/wp/W9-1.md')).Replace("  - changes/W9-1.md`n", "  - changes/W9-1.md`n  - src/other.zig`n")
    [System.IO.File]::WriteAllText((Join-Path $repo 'docs/arch/wp/W9-1.md'), $specText, $utf8)
    Invoke-FixtureGit $repo @('commit', '-q', '-am', 'bad')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: outside path fails' ($r.Code -eq 1) $r.Output
    Test-That 'ownership: base spec is authoritative' ($r.Output -match 'M src/other\.zig \[committed\] is outside')
    Test-That 'ownership: -SpecPath overrides' ((Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo, '-SpecPath', (Join-Path $repo 'docs/arch/wp/W9-1.md'))).Code -eq 0)

    # c) frozen file covered only by an owns glob (wave >= 1)
    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-1-frozen')
    Write-Fixture $repo 'src/apprt/win32/model/Workspace.zig' @('pub const Workspace = struct { x: u8 = 0 };')
    Invoke-FixtureGit $repo @('commit', '-q', '-am', 'frozen')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: frozen file needs touches' (($r.Code -eq 1) -and ($r.Output -match 'frozen file')) $r.Output
    $lettered = Join-Path $fixtureRoot 'W9-1-wave5a.md'
    [System.IO.File]::WriteAllText($lettered, [System.IO.File]::ReadAllText((Join-Path $repo 'docs/arch/wp/W9-1.md')).Replace('wave: 1', 'wave: 5a'), $utf8)
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo, '-SpecPath', $lettered)
    Test-That 'ownership: wave 5a applies the frozen rules' (($r.Code -eq 1) -and ($r.Output -match 'frozen file')) $r.Output

    # d) shared-appendable file loses a line; uncommitted change counts
    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-1-append')
    Write-Fixture $repo 'src/wmux_proto/events_catalog.zig' @('"c",')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: append deletion warns' (($r.Code -eq 0) -and ($r.Output -match 'loses 1 line')) $r.Output
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo, '-CommittedOnly')
    Test-That 'ownership: -CommittedOnly ignores the working tree' (($r.Code -eq 0) -and ($r.Output -match '0 changed path')) $r.Output
    Invoke-FixtureGit $repo @('checkout', '-q', '--', '.')

    # e) missing spec, bad id
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-2', '-RepoRoot', $repo)
    Test-That 'ownership: missing spec exits 2' ($r.Code -eq 2) $r.Output
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'nope', '-RepoRoot', $repo)
    Test-That 'ownership: invalid id exits 2' ($r.Code -eq 2) $r.Output

    # f) AF-15 merge-time artifact and aggregators; PB ids; -Head
    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Write-Fixture $repo 'docs/wmux/schema/wmux.schema.json' @('{', '  "type": "object"', '}')
    Write-Fixture $repo 'docs/arch/manual-checks.md' @('| id | check |', '|---|---|', '| a-one | one |')
    Write-Fixture $repo 'src/apprt/win32/fast_tests.zig' @('test {', '    _ = @import("features/a/logic/tests.zig");', '    _ = @import("features/c/logic/tests.zig");', '}')
    Write-Fixture $repo 'src/apprt/win32/features/bar/logic/tests.zig' @('test {', '    _ = @import("a.zig");', '    _ = @import("b.zig");', '}')
    Write-Fixture $repo 'docs/arch/wp/W9-2.md' @(
        '---', 'id: W9-2', 'title: Appender', 'wave: 1', 'size: S', 'depends: []', 'covers: []',
        'owns:', '  - src/apprt/win32/features/b/**',
        'touches: []',
        'appends:', '  - src/apprt/win32/fast_tests.zig',
        'apis_needed: []', 'ccr: []', 'deviations: []', '---')
    Write-Fixture $repo 'docs/arch/wp/PB-notif.md' @(
        '---', 'id: PB-notif', 'title: Pre-build', 'wave: 0', 'size: M', 'depends: []', 'covers: []',
        'owns:', '  - src/apprt/win32/features/notifications/logic/**', 'touches: []', 'appends: []',
        'apis_needed: []', 'ccr: []', 'deviations: []', '---')
    Invoke-FixtureGit $repo @('add', '-A')
    Invoke-FixtureGit $repo @('commit', '-q', '-m', 'aggregators')

    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-1-schema')
    Write-Fixture $repo 'docs/wmux/schema/wmux.schema.json' @('{', '  "type": "object",', '  "properties": {}', '}')
    Invoke-FixtureGit $repo @('commit', '-q', '-am', 'schema')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: a branch changing the settings schema passes for any WP (AF-15)' (($r.Code -eq 0) -and ($r.Output -match 'merge-time artifact')) $r.Output
    Write-Fixture $repo 'docs/arch/manual-checks.md' @('| id | check |', '|---|---|', '| a-one | one |', '| b-two | two |')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: any WP may append a ledger row (AF-19)' (($r.Code -eq 0) -and ($r.Output -match '0 violation\(s\), 0 warning\(s\)')) $r.Output
    Write-Fixture $repo 'docs/arch/manual-checks.md' @('| id | check |', '|---|---|')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: dropping a ledger row warns' (($r.Code -eq 0) -and ($r.Output -match 'manual-checks\.md is shared-appendable but loses 1 line')) $r.Output
    Invoke-FixtureGit $repo @('checkout', '-q', '--', '.')

    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-2-append')
    Write-Fixture $repo 'src/apprt/win32/fast_tests.zig' @('test {', '    _ = @import("features/a/logic/tests.zig");', '    _ = @import("features/b/logic/tests.zig");', '    _ = @import("features/c/logic/tests.zig");', '}')
    Write-Fixture $repo 'src/apprt/win32/features/b/logic/tests.zig' @('test {}')
    Invoke-FixtureGit $repo @('add', '-A')
    Invoke-FixtureGit $repo @('commit', '-q', '-m', 'append')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-2', '-RepoRoot', $repo)
    Test-That 'ownership: a declared append to a frozen aggregator passes' ($r.Code -eq 0) $r.Output
    Write-Fixture $repo 'src/apprt/win32/fast_tests.zig' @('test {', '    _ = @import("features/b/logic/tests.zig");', '}')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-2', '-RepoRoot', $repo)
    Test-That 'ownership: removing lines from a frozen appended file fails' (($r.Code -eq 1) -and ($r.Output -match 'It is frozen')) $r.Output
    Invoke-FixtureGit $repo @('checkout', '-q', '--', '.')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo, '-Head', 'wp/W9-1-schema')
    Test-That 'ownership: -Head checks another branch (committed only)' (($r.Code -eq 0) -and ($r.Output -match 'at wp/W9-1-schema') -and ($r.Output -match '1 changed path')) $r.Output

    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/W9-1-sort')
    Write-Fixture $repo 'src/apprt/win32/features/bar/logic/tests.zig' @('test {', '    _ = @import("b.zig");', '    _ = @import("a.zig");', '}')
    Invoke-FixtureGit $repo @('commit', '-q', '-am', 'reorder')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: a sort-only edit of any aggregator passes' (($r.Code -eq 0) -and ($r.Output -match 're-sorted')) $r.Output
    Write-Fixture $repo 'src/apprt/win32/features/bar/logic/tests.zig' @('test {', '    _ = @import("b.zig");', '    _ = @import("c.zig");', '}')
    $r = Invoke-Script 'check-ownership.ps1' @('-Wp', 'W9-1', '-RepoRoot', $repo)
    Test-That 'ownership: changing an aggregator beyond a re-sort is not implicit' ($r.Code -eq 1) $r.Output
    Invoke-FixtureGit $repo @('checkout', '-q', '--', '.')

    Invoke-FixtureGit $repo @('checkout', '-q', 'master')
    Invoke-FixtureGit $repo @('checkout', '-q', '-b', 'wp/PB-notif-store')
    Write-Fixture $repo 'src/apprt/win32/features/notifications/logic/store.zig' @('// store')
    Invoke-FixtureGit $repo @('add', '-A')
    Invoke-FixtureGit $repo @('commit', '-q', '-m', 'pb')
    $r = Invoke-Script 'check-ownership.ps1' @('-RepoRoot', $repo)
    Test-That 'ownership: PB-notif inferred from wp/PB-notif-store and accepted' (($r.Code -eq 0) -and ($r.Output -match 'PB-notif vs')) $r.Output

    # g) the repository's .gitattributes merge drivers (AF-15): union keeps both appends,
    #    ours keeps the target branch's schema (once merge.ours.driver is defined).
    Write-Host 'merge drivers: .gitattributes of this checkout'
    $md = Join-Path $fixtureRoot 'drivers'
    New-Item -ItemType Directory -Force -Path $md | Out-Null
    Invoke-FixtureGit $md @('init', '-q', '-b', 'master')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../.gitattributes') -Destination (Join-Path $md '.gitattributes')
    Test-That 'merge drivers: Set-WmuxMergeDrivers defines "ours" once' ((Set-WmuxMergeDrivers -RepoRoot $md) -and -not (Set-WmuxMergeDrivers -RepoRoot $md))
    Write-Fixture $md 'src/apprt/win32/features/x/logic/tests.zig' @('test {', '    _ = @import("a.zig");', '    _ = @import("m.zig");', '}')
    Write-Fixture $md 'src/wmux_proto/proto.zig' @('pub const a = @import("a.zig");', 'pub const m = @import("m.zig");')
    Write-Fixture $md 'docs/wmux/schema/wmux.schema.json' @('{', '  "base": true', '}')
    Invoke-FixtureGit $md @('add', '-A')
    Invoke-FixtureGit $md @('commit', '-q', '-m', 'base')
    Invoke-FixtureGit $md @('checkout', '-q', '-b', 'one')
    Write-Fixture $md 'src/apprt/win32/features/x/logic/tests.zig' @('test {', '    _ = @import("a.zig");', '    _ = @import("b.zig");', '    _ = @import("m.zig");', '}')
    Write-Fixture $md 'src/wmux_proto/proto.zig' @('pub const a = @import("a.zig");', 'pub const b = @import("b.zig");', 'pub const m = @import("m.zig");')
    Write-Fixture $md 'docs/wmux/schema/wmux.schema.json' @('{', '  "one": true', '}')
    Invoke-FixtureGit $md @('commit', '-q', '-am', 'one')
    Invoke-FixtureGit $md @('checkout', '-q', 'master')
    Invoke-FixtureGit $md @('checkout', '-q', '-b', 'two')
    Write-Fixture $md 'src/apprt/win32/features/x/logic/tests.zig' @('test {', '    _ = @import("a.zig");', '    _ = @import("c.zig");', '    _ = @import("m.zig");', '}')
    Write-Fixture $md 'src/wmux_proto/proto.zig' @('pub const a = @import("a.zig");', 'pub const c = @import("c.zig");', 'pub const m = @import("m.zig");')
    Write-Fixture $md 'docs/wmux/schema/wmux.schema.json' @('{', '  "two": true', '}')
    Invoke-FixtureGit $md @('commit', '-q', '-am', 'two')
    Invoke-FixtureGit $md @('checkout', '-q', 'one')
    $mergeOk = $true
    try { Invoke-FixtureGit $md @('merge', '-q', '--no-ff', '-m', 'merge two', 'two') } catch { $mergeOk = $false }
    $tests = [System.IO.File]::ReadAllText((Join-Path $md 'src/apprt/win32/features/x/logic/tests.zig'))
    $schema = [System.IO.File]::ReadAllText((Join-Path $md 'docs/wmux/schema/wmux.schema.json'))
    Test-That 'merge drivers: the merge has no conflict' $mergeOk
    Test-That 'merge drivers: union keeps both logic/tests.zig appends' (($tests -match 'b\.zig') -and ($tests -match 'c\.zig') -and ($tests -notmatch '<<<<<<<')) $tests
    Test-That 'merge drivers: union keeps both proto.zig re-exports' ([System.IO.File]::ReadAllText((Join-Path $md 'src/wmux_proto/proto.zig')) -match '(?s)b\.zig.*c\.zig')
    Test-That 'merge drivers: ours keeps the target schema (regenerated by gate -Merge)' (($schema -match '"one"') -and ($schema -notmatch '"two"')) $schema

    # ------------------------------------------------------------ check-manifest
    Write-Host 'check-manifest: fixture trees'
    $sk = Join-Path $fixtureRoot 'skeleton'
    Write-Fixture $sk 'src/apprt/win32/App.zig' @('const std = @import("std");', 'pub const legacyThing = @import("ui/x.zig").legacyThing;')
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $sk)
    Test-That 'manifest: no skeleton passes cleanly' (($r.Code -eq 0) -and ($r.Output -match 'skeleton not present yet')) $r.Output
    Test-That 'manifest: non-git tree skips alias baseline' ($r.Output -match 'alias baseline check skipped')

    foreach ($id in 'alpha', 'beta') {
        Write-Fixture $sk "src/apprt/win32/features/$id/mod.zig" @("pub const id = `"$id`";", 'test { _ = @import("logic/tests.zig"); }')
        Write-Fixture $sk "src/apprt/win32/features/$id/state.zig" @('pub const App = struct {};')
        Write-Fixture $sk "src/apprt/win32/features/$id/logic/tests.zig" @('test { _ = @import("calc.zig"); }')
        Write-Fixture $sk "src/apprt/win32/features/$id/logic/calc.zig" @('test "unit: x: y" {}')
    }
    Write-Fixture $sk 'src/apprt/win32/model/logic/tests.zig' @('test { _ = @import("layout.zig"); }')
    Write-Fixture $sk 'src/apprt/win32/model/logic/layout.zig' @('// layout')
    # Exempt (ruling D1): full-suite-only fake model graphs, never referenced from logic/tests.zig.
    Write-Fixture $sk 'src/apprt/win32/model/logic/fake.zig' @('// fake model graphs (full suite only)')
    Write-Fixture $sk 'src/apprt/win32/features/manifest.zig' @('pub const modules = .{', '    @import("alpha/mod.zig"),', '    @import("beta/mod.zig"),', '};')
    $ext = @()
    foreach ($s in 'App', 'Window', 'Workspace', 'Pane', 'Tab') {
        $ext += "pub const ${s}Ext = struct {"
        $ext += "    alpha: @import(`"alpha/state.zig`").$s = .{},"
        $ext += "    beta: @import(`"beta/state.zig`").$s = .{},"
        $ext += '};'
    }
    Write-Fixture $sk 'src/apprt/win32/features/ext.zig' $ext
    Write-Fixture $sk 'src/apprt/win32/fast_tests.zig' @(
        'test {',
        '    _ = @import("features/alpha/logic/tests.zig");',
        '    _ = @import("features/beta/logic/tests.zig");',
        '    _ = @import("model/logic/tests.zig");',
        '}')
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $sk)
    Test-That 'manifest: consistent skeleton passes' (($r.Code -eq 0) -and ($r.Output -match '0 error\(s\), 0 warning\(s\)')) $r.Output
    Test-That 'manifest: model/logic/fake.zig is exempt from the tests.zig rule' (($r.Output -notmatch 'fake\.zig is not referenced') -and ($r.Output -match '1 exempt from the tests\.zig rule')) $r.Output

    # break it in several ways
    Write-Fixture $sk 'src/apprt/win32/features/gamma/mod.zig' @('pub const id = "gamma";')
    Write-Fixture $sk 'src/apprt/win32/features/alpha/logic/orphan.zig' @('// not referenced')
    Write-Fixture $sk 'src/apprt/win32/features/alpha/logic/fake.zig' @('// only model/logic/fake.zig is exempt')
    Write-Fixture $sk 'src/apprt/win32/features/beta/mod.zig' @('pub const id = "betta";', '// _ = @import("logic/tests.zig"); commented out')
    Write-Fixture $sk 'src/apprt/win32/model/logic/tests.zig' @('// _ = @import("layout.zig");')
    Write-Fixture $sk 'src/apprt/win32/fast_tests.zig' @('test {', '    _ = @import("features/alpha/logic/tests.zig");', '}')
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $sk)
    Test-That 'manifest: broken skeleton fails' ($r.Code -eq 1) $r.Output
    Test-That 'manifest: unlisted module' ($r.Output -match 'features/gamma/mod\.zig is not listed')
    Test-That 'manifest: missing ext field' ($r.Output -match "AppExt has no field 'gamma'")
    Test-That 'manifest: missing state.zig' ($r.Output -match 'features/gamma/state\.zig is missing')
    Test-That 'manifest: id mismatch' ($r.Output -match 'declares id "betta"')
    Test-That 'manifest: mod.zig must reference logic/tests.zig' ($r.Output -match 'features/beta/mod\.zig does not reference logic/tests\.zig')
    Test-That 'manifest: unreferenced logic file' ($r.Output -match 'features/alpha/logic/orphan\.zig is not referenced')
    Test-That 'manifest: a fake.zig outside model/logic is not exempt' ($r.Output -match 'features/alpha/logic/fake\.zig is not referenced')
    Test-That 'manifest: commented import does not count' ($r.Output -match 'model/logic/layout\.zig is not referenced')
    Test-That 'manifest: fast_tests reachability' ($r.Output -match 'features/beta/logic/tests\.zig is not reachable')
    $r2 = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $sk, '-WarningsAsErrors')
    Test-That 'manifest: -WarningsAsErrors still fails' ($r2.Code -eq 1)

    # W0 aliases: both forms are counted during W0 and warned about when new after the wave-0 tag.
    $al = Join-Path $fixtureRoot 'alias'
    New-Item -ItemType Directory -Force -Path $al | Out-Null
    Invoke-FixtureGit $al @('init', '-q', '-b', 'master')
    $appLines = @('const std = @import("std");', 'const ring = @import("features/notifications/legacy_ring.zig");',
        'pub const moved = @import("app/tasks.zig").moved;', 'pub const notifAt = ring.notifAt;',
        'pub const must_draw_from_app_thread = false;', 'pub const NAME = std.unicode.utf8ToUtf16LeStringLiteral("x");')
    Write-Fixture $al 'src/apprt/win32/App.zig' $appLines
    Invoke-FixtureGit $al @('add', '-A')
    Invoke-FixtureGit $al @('commit', '-q', '-m', 'w0')
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $al)
    Test-That 'manifest: both W0 alias forms are counted' (($r.Code -eq 0) -and ($r.Output -match '2 alias line\(s\)')) $r.Output
    Invoke-FixtureGit $al @('tag', 'wave-0')
    Write-Fixture $al 'src/apprt/win32/App.zig' ($appLines + @('pub const clearNotifs = ring.clearNotifs;', 'pub const later = @import("app/timers.zig").later;'))
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $al)
    Test-That 'manifest: new aliases after wave-0 warn (both forms)' (($r.Code -eq 0) -and ($r.Output -match 'new alias after Wave 0 \(pub const clearNotifs = ring\.clearNotifs;\)') -and ($r.Output -match 'new alias after Wave 0 \(pub const later = ') -and ($r.Output -match '0 error\(s\), 2 warning\(s\)')) $r.Output

    # Shared-appendable aggregators and the manual-check ledger.
    $ag = Join-Path $fixtureRoot 'aggregators'
    Write-Fixture $ag 'src/apprt/win32/App.zig' @('const std = @import("std");')
    Write-Fixture $ag 'src/apprt/win32/model/logic/tests.zig' @('test {', '    _ = @import("b.zig");', '    _ = @import("a.zig");', '}')
    Write-Fixture $ag 'src/apprt/win32/model/logic/a.zig' @('// a')
    Write-Fixture $ag 'src/apprt/win32/model/logic/b.zig' @('// b')
    Write-Fixture $ag 'src/wmux_proto/proto.zig' @('pub const b = @import("b.zig");', 'pub const a = @import("a.zig");')
    Write-Fixture $ag 'test/e2e/suites/core/W2-1.e2e.ps1' @('# wp: W2-1', '# covers: core-a', '# manual: core-ime-composition "IME needs a human"', 'Import-Module nothing')
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $ag)
    Test-That 'manifest: unsorted logic/tests.zig is an error' (($r.Code -eq 1) -and ($r.Output -match 'model/logic/tests\.zig:3: not sorted')) $r.Output
    Test-That 'manifest: unsorted proto.zig re-exports are an error' ($r.Output -match 'proto\.zig:2: not sorted') $r.Output
    Test-That 'manifest: manual waiver without a ledger row warns' ($r.Output -match "'# manual: core-ime-composition' has no row in docs/arch/manual-checks\.md") $r.Output
    Write-Fixture $ag 'src/apprt/win32/model/logic/tests.zig' @('test {', '    _ = @import("a.zig");', '    _ = @import("b.zig");', '}')
    Write-Fixture $ag 'src/wmux_proto/proto.zig' @('pub const a = @import("a.zig");', 'pub const b = @import("b.zig");')
    Write-Fixture $ag 'docs/arch/manual-checks.md' @('| id | check |', '|---|---|', '| core-ime-composition | IME |')
    $r = Invoke-Script 'check-manifest.ps1' @('-RepoRoot', $ag)
    Test-That 'manifest: sorted aggregators and a ledger row pass cleanly' (($r.Code -eq 0) -and ($r.Output -match '0 error\(s\), 0 warning\(s\)')) $r.Output

    # ------------------------------------------------------------ new-wp-specs
    Write-Host 'new-wp-specs.ps1: fixture plans'
    $pr = Join-Path $fixtureRoot 'plan-tree'
    Write-Fixture $pr 'src/apprt/win32/features/todo/mod.zig' @('pub const id = "todo";')
    Write-Fixture $pr 'src/apprt/win32/fast_tests.zig' @('test {}')
    Write-Fixture $pr 'src/apprt/win32/App.zig' @('// app')
    function New-PlanWp([string]$Id, [string]$Arch, [int]$Wave, [string[]]$New = @(), [string[]]$Touched = @(), [object[]]$Touches = @(), [string[]]$Appends = @(), [string[]]$Depends = @()) {
        return [ordered]@{
            id = $Id; title = "Fixture $Arch"; wave = $Wave; arch_id = $Arch; arch_wave = 'W3'; status = 'planned'; executor = 'plan'
            est_size = 'M'; units = 3; summary = "Fixture work package $Arch."; features = @("feat-$Arch"); depends_on = $Depends; merge_after = @()
            files_new = $New; files_touched = $Touched; touches = $Touches; appends = $Appends
            acceptance = @("unit: $($Arch): works", 'e2e: it shows'); derived_from = @()
        }
    }
    function Write-Plan([string]$Name, [object[]]$Wps) {
        $path = Join-Path $fixtureRoot $Name
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject ([ordered]@{ waves = @(); work_packages = $Wps; notes = @() }) -Depth 8), $utf8)
        return $path
    }
    function Invoke-Specs([string]$PlanPath, [string]$Out, [string[]]$Extra = @()) {
        return (Invoke-Script 'new-wp-specs.ps1' (@('-Plan', $PlanPath, '-Wave', '31', '-OutDir', $Out, '-RepoRoot', $pr) + $Extra))
    }
    $good = @(
        (New-PlanWp 'WP-30-if' 'W3-IF' 30),
        (New-PlanWp 'WP-31-a' 'W3-1a' 31 -New @('src/apprt/win32/features/todo/logic/model.zig', 'test/e2e/suites/todo/W3-1a.e2e.ps1') -Touched @('src/apprt/win32/features/todo/mod.zig', 'src/apprt/win32/App.zig') `
                -Touches @([ordered]@{ path = 'src/apprt/win32/App.zig'; reason = 'one-line hook: wire the store' }) -Appends @('src/apprt/win32/fast_tests.zig') -Depends @('WP-30-if')),
        (New-PlanWp 'WP-31-b' 'PB-todo' 31 -New @('src/web/todo/**') -Appends @('src/apprt/win32/fast_tests.zig'))
    )
    $out = Join-Path $fixtureRoot 'specs-good'
    $r = Invoke-Specs (Write-Plan 'plan-good.json' $good) $out
    Test-That 'specs: a clean wave renders one spec per WP and exits 0' (($r.Code -eq 0) -and (Test-Path (Join-Path $out 'W3-1a.md')) -and (Test-Path (Join-Path $out 'PB-todo.md')) -and -not (Test-Path (Join-Path $out 'W3-IF.md'))) $r.Output
    if (Test-Path (Join-Path $out 'W3-1a.md')) {
        $sp = Get-WmuxWpSpec -RepoRoot $repo -Wp 'W3-1a' -SpecPath (Join-Path $out 'W3-1a.md')
        Test-That 'specs: owns = files_new + non-frozen files_touched' ((@($sp.Owns | ForEach-Object Path) -join '|') -eq 'src/apprt/win32/features/todo/logic/model.zig|test/e2e/suites/todo/W3-1a.e2e.ps1|src/apprt/win32/features/todo/mod.zig') ($sp.Owns | Out-String)
        Test-That 'specs: touches keep their reasons' (($sp.Touches.Count -eq 1) -and ($sp.Touches[0].Reason -eq 'one-line hook: wire the store'))
        Test-That 'specs: appends, wave, depends and covers' ((@($sp.Appends | ForEach-Object Path) -join '|') -eq 'src/apprt/win32/fast_tests.zig' -and $sp.Data['wave'] -eq '3' -and (@($sp.Data['depends']) -join ',') -eq 'W3-IF' -and (@($sp.Data['covers']) -join ',') -eq 'feat-W3-1a')
    }
    $r = Invoke-Specs (Join-Path $fixtureRoot 'plan-good.json') $out
    Test-That 'specs: an existing spec needs -Force' (($r.Code -eq 1) -and ($r.Output -match 'pass -Force')) $r.Output
    $r = Invoke-Specs (Join-Path $fixtureRoot 'plan-good.json') $out @('-Force')
    Test-That 'specs: -Force overwrites' ($r.Code -eq 0) $r.Output

    $cases = @(
        @('placeholder path', @((New-PlanWp 'WP-31-a' 'W3-1a' 31 -New @('src/apprt/win32/features/<id>/logic/x.zig'))), 'placeholder path in files_new'),
        @('existing files_new', @((New-PlanWp 'WP-31-a' 'W3-1a' 31 -New @('src/apprt/win32/features/todo/mod.zig'))), 'already exists in the tree'),
        @('frozen path without touches', @((New-PlanWp 'WP-31-a' 'W3-1a' 31 -Touched @('src/apprt/win32/App.zig'))), 'frozen path without a touches entry'),
        @('same-wave overlap', @((New-PlanWp 'WP-31-a' 'W3-1a' 31 -New @('src/web/todo/**')), (New-PlanWp 'WP-31-b' 'W3-1b' 31 -New @('src/web/todo/app.js'))), 'both touch .* outside appends'),
        @('append vs edit in one wave', @((New-PlanWp 'WP-31-a' 'W3-1a' 31 -Appends @('src/apprt/win32/fast_tests.zig')), (New-PlanWp 'WP-31-b' 'W3-1b' 31 -Touched @('src/apprt/win32/fast_tests.zig') -Touches @([ordered]@{ path = 'src/apprt/win32/fast_tests.zig'; reason = 'rewrite' }))), 'outside appends'),
        @('touches without reason', @((New-PlanWp 'WP-31-a' 'W3-1a' 31 -Touched @('src/apprt/win32/App.zig') -Touches @([ordered]@{ path = 'src/apprt/win32/App.zig'; reason = '' }))), 'has no reason')
    )
    $k = 0
    foreach ($c in $cases) {
        $k++
        $o = Join-Path $fixtureRoot "specs-bad-$k"
        $r = Invoke-Specs (Write-Plan "plan-bad-$k.json" $c[1]) $o
        Test-That "specs: fails on $($c[0])" (($r.Code -eq 1) -and ($r.Output -match $c[2]) -and -not (Test-Path (Join-Path $o '*.md'))) $r.Output
    }
    $r = Invoke-Specs (Join-Path $fixtureRoot 'plan-bad-2.json') (Join-Path $fixtureRoot 'specs-drift') @('-AllowExisting')
    Test-That 'specs: -AllowExisting turns plan drift into a warning' (($r.Code -eq 0) -and ($r.Output -match 'WARN: .*already exists') -and (Select-String -LiteralPath (Join-Path $fixtureRoot 'specs-drift/W3-1a.md') -Pattern 'Plan drift' -Quiet)) $r.Output
    $r = Invoke-Specs (Join-Path $fixtureRoot 'plan-good.json') (Join-Path $fixtureRoot 'specs-check') @('-Check')
    Test-That 'specs: -Check validates and writes nothing' (($r.Code -eq 0) -and -not (Test-Path (Join-Path $fixtureRoot 'specs-check'))) $r.Output
    $r = Invoke-Script 'new-wp-specs.ps1' @('-Plan', (Join-Path $fixtureRoot 'plan-good.json'))
    Test-That 'specs: no -Wave/-Wp is a usage error' ($r.Code -eq 2) $r.Output

    # ------------------------------------------------------------ gate / new-worktree (no execution)
    Write-Host 'gate.ps1 and new-worktree.ps1: plans only'
    $r = Invoke-Script 'gate.ps1' @('-Full', '-DryRun', '-FullTest')
    Test-That 'gate: -Full -DryRun plans every step' (($r.Code -eq 0) -and ($r.Output -match 'DRY RUN') -and ($r.Output -match 'fulltest')) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Wp', 'W0-C', '-DryRun', '-Only', 'fmt,ownership')
    Test-That 'gate: -Only filters steps' (($r.Code -eq 0) -and ($r.Output -match 'not selected')) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Wp', 'W0-C', '-DryRun', '-Skip', 'bogus')
    Test-That 'gate: unknown step is a usage error' ($r.Code -eq 2) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Merge', '-Wp', 'W0-C2', '-DryRun')
    Test-That 'gate: -Merge -DryRun prints the merge tier plan' (($r.Code -eq 0) -and ($r.Output -match 'tier plan: merge -> fmt, pslint, ownership, manifest, schema, build, release, test-fast, test-cli, unit, e2e, web, contract \(budget 12:00\)') -and ($r.Output -match "'sidebar', 'wsl', 'win-pwd', 'ipc:'") -and ($r.Output -match 'background')) $r.Output
    Test-That 'gate: -Merge plans smoke + legacy + regression (missing suites skipped)' ($r.Output -match 'e2e .*smoke' -and $r.Output -match '(?s)e2e .*(legacy|-Suite [^ ]*legacy)') $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Full', '-DryRun')
    Test-That 'gate: -Full includes the unfiltered suite by default' (($r.Code -eq 0) -and ($r.Output -match 'tier plan: full -> .*fulltest')) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Full', '-DryRun', '-NoFullTest')
    Test-That 'gate: -NoFullTest drops it' (($r.Code -eq 0) -and ($r.Output -notmatch 'tier plan: full -> .*fulltest')) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Batch', 'W0-C2,W0-B2', '-BatchRef', 'HEAD,HEAD', '-DryRun')
    Test-That 'gate: -Batch -DryRun plans the batch tier' (($r.Code -eq 0) -and ($r.Output -match 'tier plan: batch \(merge tier\) -> batch, fmt') -and ($r.Output -match '-Wp W0-B2 -Head HEAD')) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Batch', 'W0-C2', '-DryRun')
    Test-That 'gate: -Batch needs two ids' ($r.Code -eq 2) $r.Output
    $r = Invoke-Script 'gate.ps1' @('-Merge', '-Full', '-Wp', 'W0-C2', '-DryRun')
    Test-That 'gate: -Merge and -Full are exclusive' ($r.Code -eq 2) $r.Output
    $wtRoot = Join-Path $fixtureRoot 'wt'
    $r = Invoke-Script 'new-worktree.ps1' @('-Wp', 'W9-99', '-Root', $wtRoot, '-NoBuild', '-WhatIf') -Child
    Test-That 'new-worktree: -WhatIf plans and creates nothing' (($r.Code -eq 0) -and ($r.Output -match 'What if') -and -not (Test-Path (Join-Path $wtRoot 'W9-99'))) $r.Output
    $r = Invoke-Script 'new-worktree.ps1' @('-Wp', 'bad id', '-Root', $wtRoot, '-WhatIf')
    Test-That 'new-worktree: invalid id exits 2' ($r.Code -eq 2) $r.Output
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "test-tooling: $script:passed passed, $script:failed failed"
exit ([int]($script:failed -gt 0))
