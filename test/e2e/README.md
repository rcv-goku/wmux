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
pwsh test/e2e/run.ps1 -Suite legacy,regression -Parallel 4          # the W0 legacy gate (AF-19)
pwsh test/e2e/run.ps1 -Suite legacy,regression -Parallel 4 -Exe zig-out\release\bin\wmux.exe
pwsh test/e2e/run.ps1 -Suite core -Filter workspace -Parallel 2 -Build Debug
pwsh test/e2e/run.ps1 -Suite _selftest             # harness self-test (isolation.e2e.ps1 launches wmux)
pwsh test/e2e/run.ps1 -List                        # what would run
pwsh test/e2e/coverage.ps1 [-Area cli] [-Json test-results/coverage.json]
```

Outputs go to `test-results/` (gitignored): `e2e.json`, `e2e.junit.xml`, `logs/` (per attempt),
`raw/` (Test-Case JSONL) and `artifacts/` (failure screenshots, `events.jsonl`, logs, toast sink,
dialogs). A failed file is retried once and reported `flaky` when the retry passes. Every
Test-Case has a 120 s watchdog (`-TestTimeoutSec`); a file whose process outlives its budget is
killed and reported `timeout`. Exit codes: 0 pass, 1 failures, 2 usage / nothing matched,
3 build or environment failure. `-Build Release` builds into `zig-out\release`. A custom
`-ResultsDir` must be new, empty or a previous run's output (marker `.wmux-e2e-results`).
A `# budget-sec: <n>` header line raises a file's budget above `-TestTimeoutSec` times its
number of `Test-Case` lines (for loops of generated Test-Cases or nested runs).

At start the runner sweeps stale instance roots under `%RUNNER_TEMP%`/`%TEMP%\wmux-e2e`: a root
whose `owner.json` names a harness process that no longer runs (same pid and start time), or a
root without `owner.json` older than 24 h. Roots of live runs, including concurrent runs from
other worktrees, are never touched.

## Suites

| Suite | WP | What it checks |
|---|---|---|
| `smoke/smoke.e2e.ps1` | W0-B | Appendix D.5 smoke over the legacy protocol, plus the watched instance tree and its hidden mode |
| `legacy/legacy-compat.e2e.ps1` | W0-B2 | all 37 legacy JSON commands (ADR-3.7); every reply matches a strict shape in `fixtures/legacy/<command>.json`; the fixtures must equal the `Command` enum of `rpc/compat/legacy_json.zig` and every pinned case must run |
| `legacy/plus-verbs.e2e.ps1` | W0-B2 | every legacy `+verb` (and `--help`) through `wmux.exe` and through `cli\wmux.com`, masked output compared with `fixtures/plus-verbs/goldens.json` (captured from `aa1f532`, see its README); `cli\wmux.com` divergences are skips naming W1-2b (AF-11), "skipped: legacy CLI not present" without `cli\wmux.com` |
| `regression/w0-regression.e2e.ps1` | W0-B2 | the scripted W0 checklist (AF-19): splits, tabs, workspaces, send/read-screen, browser open/eval/snapshot, notify, status/progress/log, session save/restore, layouts, sync-input, break/move pane, right sidebar, hidden-window capture |
| `_selftest/harness.e2e.ps1` | W0-B | module, runner and coverage without launching wmux |
| `_selftest/isolation.e2e.ps1` | W0-B2 | visibility guard and tree focus sampler on fixtures, orphan and root cleanup, stale-root sweep, and a nested `-Suite smoke,legacy -Parallel 4` leaving `%LOCALAPPDATA%\ghostty` and `%LOCALAPPDATA%\wmux` byte-identical (inconclusive when a non-test `wmux.exe` ran; CI is authoritative) |

Known flake until W0-ST lands the `src/termio/Exec.zig` teardown fix (ruling D17, ADR-12.7):
closing a just-created tab or workspace can hang the UI thread once in a while. Suites close a
tab or workspace only after its prompt appeared, never sleep, and rely on the runner's single
retry (the file is then reported `flaky`).

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

The focus sampler (Appendix D.2 step 7, spike S2) runs on a background thread that is made
per-monitor-v2 DPI aware first. It watches the whole process tree of every instance: the wmux
pid plus every descendant (conhost, the shells, msedgewebview2), found through Toolhelp parent
links every 250 ms; exited pids stay members and creation times are compared, so a recycled pid
never counts. Every 100 ms it reads `GetWindowThreadProcessId(GetForegroundWindow())`; a window
of a watched tree in the foreground fails the running Test-Case with
`focus stolen by test instance`. Every 200 ms the visibility guard enumerates the top-level
windows of the trees and fails the Test-Case with `visible test window` for a window that is
visible, not minimized, not cloaked (only a successful `DWMWA_CLOAKED` query of 0 counts) and
on a monitor. Cloaked windows (the S2 placement, W0-A4) and windows on no monitor (the
(-32000,-32000) placement of W0-A1) are both accepted; the placement seen is recorded per
instance (`hidden_mode` in the result records: `cloaked`, `offscreen`, `cloaked-offscreen`, or
combinations). A violating tree is killed at once. Processes started by a suite itself (for
example the CLI runs of `plus-verbs`) can be watched the same way with
`[WmuxTestHarness.FocusSampler]::WatchTree(<pid>, $true, $true)`. Start-WmuxInstance refuses to
launch a `wmux.exe` that lacks `WMUX_TEST_HIDDEN` support (the test is skipped instead); pass
`-Visible` only for local debugging (focus is then still sampled, the guard is off).

`Get-WmuxScreenshot` captures with `PrintWindow(PW_RENDERFULLCONTENT)` on a DPI-aware thread
(10 s limit when the UI thread hangs) and returns the PNG's `FileInfo` with `Placement`,
`Cloaked` and `TerminalCheck`: `ok` when the `WmuxTerminal` area shows 3+ colours and no colour
above 99.9 %, `blank` otherwise, and `inconclusive` whenever the window is not cloaked on a
monitor (GL output reaches `PrintWindow` only there; never compare exact colours).

`Stop-WmuxInstance` kills the tree, then terminates every recorded member that still runs
(msedgewebview2 outlives its host by 30-60 s), waits up to 15 s until none is listed any more,
and deletes the root: one synchronous attempt, then a hidden background deleter that retries
for 90 s while WebView2 keeps files locked. Cleanup never fails a test; leftovers are listed in
the result record (`survivors`, `root_deletion`).

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
* A `wmux.exe` without `WMUX_TEST_HIDDEN` (older than W0-A1) is never started; its tests are skipped.

Harness error codes (never produced by the server): `harness_legacy_protocol`,
`harness_timeout`, `harness_eof`, `harness_transport`, `harness_bad_reply`,
`harness_id_mismatch`, `harness_stream_closed`, `harness_cli_missing`, `harness_cli_timeout`,
`harness_instance_stopped`. Environment knobs are listed at the top of `WmuxTest.psm1`.
