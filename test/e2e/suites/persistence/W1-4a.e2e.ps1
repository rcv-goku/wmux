# wp: W1-4a
# covers: persistence-cmuxjson-locations-and-precedence, persistence-ghostty-config-loading-and-reload, persistence-config-reload, persistence-cmuxjson-root-meta-and-packs, persistence-managed-policy-framework
# Settings layer (ARCHITECTURE.md ADR-5.1-5.5, 5.7): live reload of CONFIG\wmux.json and the shared
# cmux.json, JSONC errors that keep the last good revision, the policy layer (WMUX_TEST_POLICY_FILE),
# packs, the generated STATE\run\settings-overrides.ghostty and Ghostty file reloads. Every check
# reads STATE\logs\wmux.log, where the settings layer logs each revision and changed key.
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

$script:Utf8 = [Text.UTF8Encoding]::new($false)

function Get-SettingsLog {
    param([Parameter(Mandatory)]$Instance)
    $path = Join-Path $Instance.StateDir 'logs\wmux.log'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    # The app keeps the log open for writing: read with shared access.
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try { return [IO.StreamReader]::new($fs, $script:Utf8).ReadToEnd() } finally { $fs.Dispose() }
}

function Wait-SettingsLog {
    # Waits until the log matches $Pattern (regex) and returns the match.
    param([Parameter(Mandatory)]$Instance, [Parameter(Mandatory)][string]$Pattern, [double]$TimeoutSec = 10)
    return Wait-WmuxCondition -TimeoutSec $TimeoutSec {
        $m = [regex]::Match((Get-SettingsLog $Instance), $Pattern)
        if ($m.Success) { $m.Value } else { $null }
    }
}

function Get-LogCount {
    param([Parameter(Mandatory)]$Instance, [Parameter(Mandatory)][string]$Pattern)
    return [regex]::Matches((Get-SettingsLog $Instance), $Pattern).Count
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Use-TestPolicyFile {
    # WMUX_TEST_POLICY_FILE must reach the instance, but Start-WmuxInstance strips WMUX_* from the
    # child environment except its keep list: extend the list for the duration of $Body.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Body)
    $mod = Get-Module WmuxTest
    & $mod { $script:EnvKeepNames = @($script:EnvKeepNames) + 'WMUX_TEST_POLICY_FILE' }
    $env:WMUX_TEST_POLICY_FILE = $Path
    try { & $Body } finally {
        Remove-Item Env:WMUX_TEST_POLICY_FILE -ErrorAction SilentlyContinue
        & $mod { $script:EnvKeepNames = @($script:EnvKeepNames | Where-Object { $_ -ne 'WMUX_TEST_POLICY_FILE' }) }
    }
}

Test-Case 'editing wmux.json reloads rev=2 within 2 s; a JSONC error keeps rev 2; fixing it reloads rev 3' {
    $w = Start-WmuxInstance
    try {
        $null = Wait-SettingsLog $w 'settings watcher started'
        $wmux = Join-Path $w.ConfigDir 'wmux.json'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Write-TextFile $wmux "{`n  // reload test`n  `"automation`": { `"socketControlMode`": `"allowAll`" },`n}`n"
        $null = Wait-SettingsLog $w 'settings reloaded rev=2 source=wmux\.json' -TimeoutSec 5
        $elapsed = $sw.Elapsed.TotalSeconds
        Write-Host "rev 2 logged after $([Math]::Round($elapsed, 2)) s"
        Assert-True ($elapsed -lt 2.0) "rev 2 took $elapsed s (limit 2 s)"
        $null = Wait-SettingsLog $w 'settings key automation\.socketControlMode="allowAll" source=wmux\.json'

        # Missing comma before "x": line 5, column 3.
        Write-TextFile $wmux "{`n  `"automation`": {`n    `"socketControlMode`": `"automation`"`n  }`n  `"x`": 1`n}`n"
        $notice = Wait-SettingsLog $w 'notice settings\.parse_error: [^\r\n]*wmux\.json:5:3: [^\r\n]*'
        Write-Host "notice: $notice"
        $null = Wait-SettingsLog $w 'settings reload failed source=wmux\.json errors=1; keeping rev=2'
        Assert-Equal 0 (Get-LogCount $w 'settings reloaded rev=3')

        Write-TextFile $wmux "{`n  `"automation`": {`n    `"socketControlMode`": `"automation`"`n  }`n}`n"
        $null = Wait-SettingsLog $w 'settings reloaded rev=3 source=wmux\.json'
        $null = Wait-SettingsLog $w 'notice settings\.parse_error: dismissed'
        $null = Wait-SettingsLog $w 'settings key automation\.socketControlMode="automation" source=wmux\.json'
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'a cmux.json value is overridden by wmux.json, and a policy lock wins over both' {
    $policyDir = Join-Path ([IO.Path]::GetTempPath()) ("wmux-e2e-policy-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $policyFile = Join-Path $policyDir 'policy.json'
    Write-TextFile $policyFile "{}`n"
    try {
        Use-TestPolicyFile $policyFile {
            $w = Start-WmuxInstance
            try {
                $null = Wait-SettingsLog $w 'settings watcher started'
                $cmux = Join-Path $w.XdgDir 'cmux\cmux.json'
                # The harness's wmux.json already sets socketControlMode "automation": the
                # cmux.json value of that key never takes effect, its other key does.
                Write-TextFile $cmux '{ "automation": { "socketControlMode": "readOnly" }, "terminal": { "confirmUnsafePaste": false } }'
                $null = Wait-SettingsLog $w 'settings reloaded rev=2 source=cmux\.json'
                $null = Wait-SettingsLog $w 'settings key terminal\.confirmUnsafePaste=false source=cmux\.json'
                Assert-Equal 0 (Get-LogCount $w 'socketControlMode="readOnly"')

                # The same key in wmux.json wins over cmux.json.
                Write-TextFile (Join-Path $w.ConfigDir 'wmux.json') '{ "automation": { "socketControlMode": "automation" }, "terminal": { "confirmUnsafePaste": true } }'
                $null = Wait-SettingsLog $w 'settings reloaded rev=3 source=wmux\.json'
                $null = Wait-SettingsLog $w 'settings key terminal\.confirmUnsafePaste=true source=wmux\.json'
                Assert-Equal 0 (Get-LogCount $w 'socketControlMode="readOnly"')

                # The policy locks the key and wins over both files.
                Write-TextFile $policyFile '{ "HKLM": { "automation.socketControlMode": "allowAll" } }'
                $null = Wait-SettingsLog $w 'settings reloaded rev=\d+ source=policy'
                $null = Wait-SettingsLog $w 'settings key automation\.socketControlMode="allowAll" source=policy locked'

                # A user-level write of the forced key has no effect.
                Write-TextFile (Join-Path $w.ConfigDir 'wmux.json') '{ "automation": { "socketControlMode": "off" }, "terminal": { "confirmUnsafePaste": true } }'
                $null = Wait-WmuxCondition { (Get-LogCount $w 'settings reloaded rev=\d+ source=wmux\.json') -ge 2 }
                Assert-Equal 0 (Get-LogCount $w 'socketControlMode="off"')
            } finally { Stop-WmuxInstance $w }
        }
    } finally { Remove-Item -LiteralPath $policyDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'terminal.copyOnSelect=true writes settings-overrides.ghostty and reloads Ghostty once' {
    $w = Start-WmuxInstance
    try {
        $null = Wait-SettingsLog $w 'settings watcher started'
        $overrides = Join-Path $w.StateDir 'run\settings-overrides.ghostty'
        $wmux = Join-Path $w.ConfigDir 'wmux.json'
        Write-TextFile $wmux '{ "automation": { "socketControlMode": "automation" }, "terminal": { "copyOnSelect": true } }'
        $null = Wait-SettingsLog $w 'settings reloaded rev=2 source=wmux\.json'
        $null = Wait-SettingsLog $w 'settings key terminal\.copyOnSelect=true source=wmux\.json'
        $null = Wait-WmuxCondition { (Test-Path -LiteralPath $overrides) -and ((Get-Content -LiteralPath $overrides -Raw) -match '(?m)^copy-on-select = true$') }
        $null = Wait-SettingsLog $w 'ghostty config reloaded reason=settings-overrides'

        # Another settings change that leaves the overrides alone: no second Ghostty reload.
        Write-TextFile $wmux '{ "automation": { "socketControlMode": "allowAll" }, "terminal": { "copyOnSelect": true } }'
        $null = Wait-SettingsLog $w 'settings reloaded rev=3 source=wmux\.json'
        Assert-Equal 1 (Get-LogCount $w 'ghostty config reloaded reason=settings-overrides')
        Assert-Match '(?m)^copy-on-select = true$' (Get-Content -LiteralPath $overrides -Raw)
    } finally { Stop-WmuxInstance $w }
}

Test-Case 'packs load before the listing file and a Ghostty config edit reloads Ghostty' {
    $w = Start-WmuxInstance
    try {
        $null = Wait-SettingsLog $w 'settings watcher started'
        Write-TextFile (Join-Path $w.ConfigDir 'packs\team\wmux.pack.json') '{ "automation": { "socketControlMode": "readOnly" }, "terminal": { "confirmUnsafePaste": false } }'
        # The listing file overrides the pack's socketControlMode; the pack supplies the rest.
        Write-TextFile (Join-Path $w.ConfigDir 'wmux.json') '{ "packs": ["packs/team", "https://example.invalid/p"], "automation": { "socketControlMode": "automation" } }'
        $null = Wait-SettingsLog $w 'settings reloaded rev=2 source=wmux\.json'
        $null = Wait-SettingsLog $w 'settings key terminal\.confirmUnsafePaste=false source=wmux\.json'
        $null = Wait-SettingsLog $w 'settings warning [^\r\n]*wmux\.json:\d+:\d+: remote packs \(http/https\) are not supported'
        Assert-Equal 0 (Get-LogCount $w 'socketControlMode="readOnly"')

        # Editing the pack alone reloads too (it is watched).
        Write-TextFile (Join-Path $w.ConfigDir 'packs\team\wmux.pack.json') '{ "terminal": { "confirmUnsafePaste": true } }'
        $null = Wait-SettingsLog $w 'settings reloaded rev=3 source=pack'

        # The Ghostty config file is watched: an edit reloads Ghostty without a command.
        $conf = Join-Path $w.Root 'ghostty.conf'
        [IO.File]::AppendAllText($conf, "font-size = 15`n", $script:Utf8)
        $null = Wait-SettingsLog $w 'ghostty config reloaded reason=file'
    } finally { Stop-WmuxInstance $w }
}
