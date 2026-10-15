# wmux end-to-end harness

PowerShell 7 harness for wmux (ARCHITECTURE.md ADR-12.3 to 12.7 and Appendix D). No external
modules and no Pester.

| File | Purpose |
|---|---|
| `WmuxTest.psm1` | helper module; exports exactly the Appendix D.3 functions |
| `run.ps1` | runner: discovery, parallel files, retry, JSON + JUnit, artifacts |
| `coverage.ps1` | parity coverage of the `# covers:` / `# manual:` tags against `matrix.csv` |
| `suites/<area>/<wp-id>.e2e.ps1` | test files (`smoke`, `_selftest`, `_quarantine`, matrix areas) |
| `fixtures/` | golden JSON shapes and other static inputs |

## Writing a suite

```powershell
# wp: W2-1
# covers: core-workspace-create, core-cli-new-workspace
# manual: core-workspace-create-plus-button "pointer click; covered by the UI dogfood checklist"
Import-Module (Join-Path $PSScriptRoot '..\..\WmuxTest.psm1') -Force

Test-Case 'workspace.create returns handles and keeps focus' {
    $w = Start-WmuxInstance
    try {
        $ws = Invoke-WmuxRpc $w 'workspace.create' @{ title = 'e2e'; focus = $false }
        Assert-Match '^workspace:\d+$' $ws.workspace_ref
        Wait-WmuxEvent $w -Name 'workspace.created' -Where { $_.workspace_id -eq $ws.workspace_id } | Out-Null
    } finally { Stop-WmuxInstance $w }
}
```

Rules: one isolated instance per test, stop it in `finally`, drive only public surfaces
(v2 RPC, CLI, events, `wmux.debug.*`), never sleep (use `Wait-WmuxCondition`, `Wait-WmuxEvent`,
`Wait-WmuxScreen`). Inside `Test-Case`, non-terminating errors fail the test and body output is
discarded (use `Write-Host`). `throw [WmuxSkipException]::new('reason')` reports a skip.

`Assert-JsonShape <value> <shape>` takes JSON text, a `.json` path (also looked up under
`fixtures/`) or a hashtable. Extra keys are allowed unless the object has `"<strict>": true`;
`"key?"` marks an optional key; `["<each>", shape]` matches arrays of any length. Tokens:
`<any> <string> <nonempty> <number> <int> <bool> <null> <object> <array> <uuid> <ref>
<ref:kind> <timestamp> <re:regex>`. Literal UUIDs, `<uuid>-<seq>` event ids, ISO-8601
timestamps and `kind:N` refs in a golden shape match any value of the same form.

## Running

```powershell
pwsh test/e2e/run.ps1 -Suite smoke                 # one area (globs and comma lists work)
pwsh test/e2e/run.ps1 -Suite core -Filter workspace -Parallel 2 -Build Debug
pwsh test/e2e/run.ps1 -Suite _selftest             # harness self-test, never launches wmux
pwsh test/e2e/run.ps1 -List                        # what would run
pwsh test/e2e/coverage.ps1 [-Area cli] [-Json test-results/coverage.json]
```

Outputs go to `test-results/` (gitignored): `e2e.json`, `e2e.junit.xml`, `logs/` (per attempt),
`raw/` (Test-Case JSONL) and `artifacts/` (failure screenshots, `events.jsonl`, logs, toast sink,
dialogs). A failed file is retried once and reported `flaky` when the retry passes. Every
Test-Case has a 120 s watchdog (`-TestTimeoutSec`); a file whose process outlives its budget is
killed and reported `timeout`. Exit codes: 0 pass, 1 failures, 2 usage / nothing matched,
3 build or environment failure. `-Build Release` builds into `zig-out\release`.

## Isolation and safety

`Start-WmuxInstance` creates `%RUNNER_TEMP%` or `%TEMP%\wmux-e2e\<id>\` (state, config, xdg,
logs, artifacts, work), writes `config\wmux.json` (socket mode automation plus `-Settings`,
dotted keys expanded) and `ghostty.conf` (`command = cmd.exe /d /k prompt WMUX$G` or `-Shell`,
then `-Ghostty` lines), and launches `wmux.exe --config-default-files=false
--config-file=<root>\ghostty.conf` with `WMUX_TEST_MODE`, `WMUX_TEST_HIDDEN`, a `test-<id>`
channel and the D.2.4 variables. Inherited `CMUX_*`, `WMUX_*` (except `WMUX_WEB_DIR`,
`WMUX_WEB_DEVTOOLS`), `GHOSTTY_*`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, agent markers and API
credentials are removed. `LOCALAPPDATA` points into the root, so the legacy app never touches
the user's session files; it is seeded with a fresh `ghostty\update_check_at`, so the app also
skips its startup update check and the tray balloon that can follow. Each instance runs in a
kill-on-close job object, so nothing outlives the test process.

A focus sampler checks the foreground window every 100 ms; if a test instance ever owns it, the
running Test-Case fails with `focus stolen by test instance`. Start-WmuxInstance refuses to
launch a `wmux.exe` that lacks `WMUX_TEST_HIDDEN` support (the test is skipped instead); pass
`-Visible` only for local debugging.

## Transitional behavior (until W1-1a, W1-2 and W0-A1 land)

* Protocol detection: when `\\.\pipe\wmux-ipc-<pid>` appears and answers a `workspace-list`
  request, the instance is `Protocol = 'legacy'`; otherwise the v2 pipe from
  `state\run\instance.json` or the D.2.6 name `wmux-<channel>-<sidhash8>-s<session>` is used with
  readiness `wmux.debug.ready`. A v2 pipe wins when both exist.
* The legacy pipe has a single instance and the app writes each reply to whichever connection
  is open when its UI thread gets to it, so the reply to a request that timed out (typically a
  readiness probe sent before the message loop runs) arrives on a later connection. The harness
  remembers the ids of unanswered requests per instance and skips such late replies; give raw
  JSON lines unique ids.
* v2-only helpers throw `[WmuxRpcError]` code `harness_legacy_protocol` on a legacy instance; the
  smoke suite therefore speaks legacy JSON through `Invoke-WmuxRawLine`.
* `Invoke-WmuxCli` relays a small allowlist of legacy `+verbs` through `wmux.exe` (with
  `GHOSTTY_PID` aimed at the test instance) until `cli\cmux.exe` exists.
* Until W0-A1 adds `WMUX_TEST_HIDDEN`, every test that starts an instance is skipped.

Harness error codes (never produced by the server): `harness_legacy_protocol`,
`harness_timeout`, `harness_eof`, `harness_transport`, `harness_bad_reply`,
`harness_id_mismatch`, `harness_stream_closed`, `harness_cli_missing`, `harness_cli_timeout`,
`harness_instance_stopped`. Environment knobs are listed at the top of `WmuxTest.psm1`.
