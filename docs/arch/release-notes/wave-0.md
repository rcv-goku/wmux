# wmux wave 0 (M0) release notes

Wave 0 of the wmux -> cmux parity program (ARCHITECTURE section 14, milestone M0): the legacy app
reorganized onto the new skeleton without behavior changes, the spikes S1-S7, the pre-builds, the
e2e harness and the tiered gates. Assembled by W0-ST part 2 on 2026-10-17 from the `changes/*.md`
fragments on master `9538cf4` (W0-A1, W0-A2, W0-A3, W0-A4, W0-B2, W0-C2, W0-ST, W1-1a-t,
PB-platform) and `docs/arch/plan/mapping.md`. The fragments stay in `changes/` for the CHANGELOG
owner; `CHANGELOG.md` and `README.md` are not edited here. The `wave-0` tag goes on the master commit
that merges `wp/W0-ST-stabilize` with `scripts/gate.ps1 -Full` green (AF-2).

## User-visible changes

### Windows, workspaces, tabs and splits

- No more workspace and tab limits: a window used to stop at 16 workspaces and a pane at 64 tabs.
  (W0-A2)
- Closing a tab in a split pane that is not the focused one (its shell exited, or
  `wmux +tab close --pane N`) no longer switches the tab of the pane you are working in or moves
  keyboard focus there. (W0-A2)
- Closing the last tab of the focused split pane no longer leaves wmux pointing at the freed pane
  (which could crash or misbehave on the next tab operation); the first remaining pane becomes the
  focused one. (W0-A2)
- Dragging a divider of a nested split follows the cursor (it jumped, because the drag was measured
  against the whole window), and `resize_split` moves the divider by the requested number of pixels
  of its own split. (W0-A2)
- Dragging a tab inside a split pane's own tab bar reorders the right tabs, and a click on a tab bar
  before its first paint hits the tab under the cursor. (W0-A2)
- A new tab no longer inherits the attention ring or the synchronized-input flag of the tab that
  used to sit at its position. (W0-A2)
- Tab titles longer than 255 bytes are cut at a character boundary instead of falling back to
  "Ghostty". (W0-A2)
- Breaking a tab out of its pane no longer leaks memory, and a failed break puts the tab back.
  (W0-A2)
- Context menu commands act on what was right-clicked even when tabs or workspaces change while the
  menu is open, and do nothing if it is gone, even when a new tab, pane or workspace has taken its
  place in memory. (W0-A2, W0-A3)
- The backend picker ("+" dropdown, "Split ... With...") and the "Set default shell..." picker list
  every installed WSL distribution (they stopped at 10 and 30). (W0-A2)
- Terminal and browser-host windows get `WS_CLIPSIBLINGS`; the top-level window adds it to every
  other direct child on `WM_PARENTNOTIFY` (spike S7). (W0-A4)

### Stability

- Fixed: closing a terminal tab or workspace right after creating it could hang wmux (the UI thread
  waited forever for the terminal's pty read thread). The Windows read thread now checks for the
  quit signal before every read, and teardown repeats the cancel until the thread has exited
  (`src/termio/Exec.zig`, CCR W0-ST-1). (W0-ST)
- The legacy `select-layout` pipe command answers `NoWindow` when no window exists instead of
  leaving the client waiting forever. (W0-A1)
- `wmux +browser` no longer double-frees when several wmux instances are running. (W0-A1)
- Pipe requests still queued when wmux exits are freed. (W0-A1)

### Session restore

- Session restore brings back every saved workspace and tab (it dropped workspaces past 16 and tabs
  past 64). (W0-A2) Known issue: a multi-workspace legacy restore can still lose the restored
  background workspaces (see Known issues).

### Configuration and keybindings

- A `wmux:<action-id>` keybinding action is accepted in the Ghostty configuration
  (`keybind = ctrl+b=wmux:newSurface`, an argument after a second colon). It has no effect yet: the
  actions get their handlers in wave 1. (W0-A3)

### Logging

- Every log line also goes to `STATE\logs\wmux.log` (`WMUX_STATE_DIR\logs`, else
  `%LOCALAPPDATA%\wmux\logs`) with a UTC timestamp; the file rotates to `wmux.log.1` at 8 MiB.
  `WMUX_LOG=debug|info|warn|error|off` sets the level (default `info`); stderr output is unchanged.
  (W0-A4)

### Automation and test mode (ADR-12.3, AF-16)

- `WMUX_TEST_MODE=1`: no global hotkey, no tray icon or balloons, no update check, no sounds, an
  in-process clipboard, message boxes auto-answered with their default button; window placement is
  neither restored nor saved and closing a window saves no session unless
  `WMUX_TEST_SESSION_RESTORE=1`. The explicit `session-save` command still writes
  `session-state.json` (pending decision (b) below). (W0-A1, W0-A4)
- `WMUX_TEST_HIDDEN=1`: every top-level window is DWM-cloaked at the primary work-area origin with a
  1600x1000 client size clamped to the work area, never activated, not in the taskbar or Alt-Tab, and
  does not save or restore its placement; the UI thread's `WH_CBT` hook also refuses every
  `SetFocus` whose top-level window is not already active (spike S2 "gate" policy). (W0-A1, W0-A4)
- Sinks: `WMUX_TEST_TOAST_SINK` (desktop notifications test mode does not show), and in test mode
  `open_url`, `open_config` and the update balloon's link append to `WMUX_TEST_EXTERNAL_SINK`
  instead of starting anything; the bell, `MessageBeep` and `PlaySound` append to
  `WMUX_TEST_SOUND_SINK`; file dialogs answer from `WMUX_TEST_FILE_DIALOG` (a path, or cancel when
  unset). (W0-A1, W0-A4)
- `WMUX_STATE_DIR=<dir>` moves `window-state`, `session-state.json`, `scrollback\` and the WebView2
  user data under `<dir>`; `WMUX_CONFIG_DIR` is reserved for the wmux config directory;
  `WMUX_DISABLE_SESSION_RESTORE` / `CMUX_DISABLE_SESSION_RESTORE` skip the restore. Without them
  nothing moves. (W0-A1)

## Internal notes

### Skeleton and core (no user-visible change)

- W0-K skeleton; W0-A1 App/ipc extraction (`app/*` plumbing, per-feature legacy command tables);
  W0-A2 Window extraction and the model; W0-A3 object ids, the event bus, the RPC, action and UI
  registries and the start-up hooks, so later waves add features without touching the core. The
  legacy `wmux +...` commands and their replies are unchanged.
- W0-A4: `app/dialogs.zig` is the only entry for `MessageBoxW`, `IFileDialog`, `ShellExecuteW`,
  `MessageBeep` and `PlaySoundW`, except `settings/legacy_config_files.zig` (the sidebar gear and
  the settings menu still open the config file and folder directly, also in test mode, until W1-4);
  `app/modal.zig` keeps only the modal-depth counter; the `update_check_at` file goes through
  `app/paths.zig`; the ADR-2.3 group and pin fields match the spec and the new
  `model/logic/display_order.zig` computes the workspace display order W1-1a uses for indexes
  (pinned first; each group expands at its anchor, pinned members first); S1 confirmed (`wmux.exe`
  imports neither `runtimeobject` nor `combase`).
- W0-P1..P4 protocol packages (core, settings, actions/keys, events) in `wmux_proto`.
- W0-ST part 2: the unfiltered win32 `zig build test` compiles again. Since W0-A3 wired
  `features/session/legacy_v2.zig` into `test_index.zig`, two of its tests built `SplitTree(Pane)`
  through init/deinit, which reaches the renderer's `apprt.gtk` switch prong and with it the GTK
  apprt's tests ("no module named 'adw'"); they now build the tree by hand.
- W0-ST part 1: the `terminal.search.Thread` unit test always stops and joins its thread, so
  filtered `zig build test` runs no longer crash under load (`src/terminal/search/Thread.zig`,
  CCR W0-ST-2).

### Pre-builds (merged, consumed by later waves)

- W1-1a-t: v2 RPC named-pipe transport (thread-per-connection `PipeServer` with cmux admission
  limits, polling rate limit, 1 MiB line framing, per-request deadlines, generation-checked deferred
  replies, clean shutdown) and the single-instance launch pipe, ready for the W1-1a dispatcher.
- PB-platform: `platform/job.zig` (typed job objects, `PROC_THREAD_ATTRIBUTE_JOB_LIST`, presets for
  tabs, instances and wrappers per spike S4), `platform/dpapi.zig` (current-user DPAPI),
  `platform/shell.zig` (known folders, open/explore, reveal, default-app lookup) and
  `platform/tests.zig` for W1-3, the RPC auth/password store and the open/explorer features.
- Without fragments (see `docs/arch/plan/mapping.md` for the merges): W1-2a CLI core and the CLI
  families built ahead of plan (`window`, `workspace`, `pane_surface`, `terminal_io`, `notify`,
  `browser`, `config`, `session`, `layout_todo`, `open_files`, `right_sidebar`), W1-6a web assets,
  W1-8a D2D/DWrite/WIC bindings, PB-notif, PB-agents, PB-session, PB-tmux, PB-browser, PB-meta,
  PB-palette, PB-sidebar, PB-feed, PB-todo-status, PB-vault, PB-automation, PB-layouts-actions,
  PB-web-harness, the five PB-web apps (markdown, diff, notifications/feed, settings, task
  manager/todo), cf-remote (W6 daemon core) and cf-hookresearch.

### Spikes

- W0-D S1-S7 decision notes are merged under `docs/arch/spikes/` (toasts, hidden instances,
  scrollback replay, agent shims, WebView2 proxies, CLI forwarders, D2D sidebar child); their
  decisions are Appendix F amendments AF-4..AF-10.

### Test infrastructure

- W0-B harness and runner; W0-B2 completion per spike S2: the focus sampler watches the whole
  process tree of a test instance on a per-monitor-v2 DPI-aware thread; a visibility guard fails a
  visible, uncloaked, on-monitor window ("visible test window") and reports `hidden_mode`;
  `Get-WmuxScreenshot` is DWMWA_CLOAKED-aware (placement plus a terminal "not blank" check that is
  inconclusive unless the window is cloaked on a monitor); `Stop-WmuxInstance` kills orphaned tree
  members, waits until none is listed and deletes the instance root in the background when files
  stay locked; `run.ps1` sweeps roots of dead runs and honours a `# budget-sec:` header.
- New suites replacing the W0 dogfood gate (AF-19): `legacy/legacy-compat` (all 37 legacy JSON
  commands, reply shapes pinned in `test/e2e/fixtures/legacy/`), `legacy/plus-verbs` (every legacy
  `+verb` through `wmux.exe` and `cli\wmux.com` against goldens captured from `aa1f532`),
  `regression/w0-regression` (scripted legacy checklist), `regression/W0-ST` (create/close
  stress) and `_selftest/isolation`.
- W0-ST part 2: the failure snapshot of `Stop-WmuxInstance` no longer waits on a hung wmux UI
  thread (`IsHungAppWindow` check, the reason in `artifacts\failure-snapshot.txt`, other captures
  bounded to 5 s, `Save-WmuxWindowCapture -TimeoutMs`), with a self-test on a hung fixture window.

### Tooling and CI

- W0-C dev tooling and `docs/arch`; W0-C2: `scripts/gate.ps1` tiers (`-Merge` with a 12 min
  budget, `summary.json`, the settings schema regenerated and committed, ReleaseFast in the
  background; `-Batch`; `-Full` with the unfiltered `zig build test`; a `web` step), the spec
  generator `scripts/new-wp-specs.ps1`, `merge=union` / `merge=ours` attributes for merge-time
  artifacts, sorted-aggregator and manual-waiver checks in `check-manifest.ps1`, new
  `check-ownership.ps1` rules, a nightly `gate.ps1 -Full` CI job and a Node job for
  `test/web-node/**/*.test.mjs`.

## Pending owner decisions

Listed for the program owner (the lead architect, AF-19); W0-ST does not decide them.

(a) **D6 premise.** Ruling D6 chose hyphenated `workspace.action` / `tab.action` names on the premise
that the CLI already sends hyphens. It does not: `workspace-action` sends cmux's underscore wire
spelling (`set_description`, `mark_read`, pinned by the "unit: cli-workspace: workspace-action
actions" test); only `tab-action` sends hyphens. Commit `5b4789e` (W0-R) clarified Appendix B.4: the
hyphenated names of D6 stay and the handlers accept both spellings, as cmux does (its v2 parsing maps
`-` to `_`). Decide: confirm that ADR clarification, or change the CLI in W2-1/W4-5.

(b) **Explicit session-save in test mode.** W0-A4 gated only the session save on `WM_CLOSE`; the
explicit legacy `session-save` command still writes `session-state.json` in test mode, and the W0-B2
suites assert that it does (`legacy-compat.e2e.ps1:219-220`, `w0-regression.e2e.ps1:247-249`). The
W0-A4 acceptance text ("a legacy session-save plus WM_CLOSE leaves STATE without window-state and
session-state.json") reads the other way. Decide whether the explicit command writes in test mode,
then amend the suites or the acceptance text.

(c) **check-ownership implicit rules.** W0-C2 made two rules implicit for every WP: a sort-only edit
to a `merge=union` aggregator (`fast_tests.zig`, `test_index.zig`, `**/logic/tests.zig`,
`proto.zig`) and appending rows to `docs/arch/manual-checks.md`. They are documented in
`docs/arch/README.md` and the script header but not in the plan or a spec. Acknowledge them as a gloss
on AF-15/AF-19 (or reject them).

(d) **Sink formats, `WMUX_TEST_FILE_DIALOG` and `WMUX_LOG` (for ADR-12.3 / Appendix G).** W0-A4
chose: `WMUX_TEST_FILE_DIALOG` = a path or `cancel` (unset = cancel); external sink line
`{kind, verb, target, timestamp_ms}`; sound sink line `{kind, source, type, sound, timestamp_ms}`;
`WMUX_LOG` levels `off`/`error`/`warn`/`info`/`debug` (default `info`); the explicit session-save
command is not gated in test mode (see (b)). Record them in ADR-12.3 / Appendix G or change them.

(e) **RPC transport values chosen by the W1-1a-t worker** (record in Appendix E or change in
W1-1a/W1-1b): `overloaded` replies carry `retry_after_ms` 250 (pool, pre-authorization or accept
buffer saturated), 1000 (pending wait expired) and 2000 (server stopping); an oversized line is
answered `{"id":null,"ok":false,"error":{"code":"invalid_request","message":"Request too large","data":{"max_bytes":1048576}}}`;
on shutdown a queued request gets `overloaded` with reason `server_stopping` and a running or
deferred one gets `cancelled` ("Server stopping", `reason: server_stopping`, `retryable: false`);
`rate_limited` replies carry `retry_after_ms`; the pre-authorization timeout stage is the worker's
choice too.

## Known issues and follow-ups

- Multi-workspace legacy restore (W1-7): W0-ST re-tried restoring both workspaces of a saved
  session in `w0-regression` after the teardown fix; workspace 1 disappeared within seconds
  (read-screen answered `UnknownWorkspace` after `workspace-list` had shown it, 2 of 2 Debug runs).
  The suite keeps restoring workspace 0 only; legacy restore also drops the splits of background
  workspaces.
- `legacy/plus-verbs`: 60 skips per run name W1-2b (`cli\wmux.com` does not reproduce the legacy
  output yet, AF-11); expected at M0.
- The cloaked GL capture check of `w0-regression` is inconclusive tonight: the workstation was
  locked (`LogonUI.exe` running) for every run, so cloaked GL captures came out one colour
  (0x282C34, 100 %) and the test skipped. Ledger row `w0-cloaked-gl-capture` (manual-checks.md).
- The CI jobs 'Web panels (Node, jsdom)' and nightly 'full-gate' have not run on GitHub Actions yet
  (ledger rows `w0-ci-web-node-job`, `w0-ci-nightly-full-gate`).
- The remaining items are in `research/parity/FOLLOWUPS.md` under their owning WPs.

## M0 exit check

Checked by W0-ST part 2 on 2026-10-17 on `wp/W0-ST-stabilize` (head `eb4526a`, master `9538cf4` plus
the W0-ST part 2 commits; the zig sources differ from master only in two legacy_v2.zig tests).
Criteria from the ARCHITECTURE milestone table (M0 row), section 14.2 and the W0-ST spec. The
workstation was locked during the whole run (`LogonUI.exe` present), so capture-based checks are
inconclusive, not failures.

- [x] **Identical legacy behavior on the skeleton** (AF-19 suites instead of dogfooding).
  `pwsh test/e2e/run.ps1 -Suite smoke,legacy,regression,_selftest -Parallel 4`, Debug and
  ReleaseFast, twice each: every run 7 files, 199 tests, 138 passed, 0 failed, 61 skipped, 0 flaky
  (Debug 235 s / 187 s, ReleaseFast 189 s / 204 s). Per file: `legacy/legacy-compat` 9/9 passed;
  `legacy/plus-verbs` 78 passed, 60 skipped, all 60 naming W1-2b (`cli\wmux.com` does not reproduce
  the legacy output yet, AF-11: expected); `regression/w0-regression` 12 passed, 1 skipped (the
  cloaked GL capture: one colour 0x282C34, inconclusive because the session was locked; ledger row
  `w0-cloaked-gl-capture`); `regression/W0-ST` 2/2; `smoke` 6/6; `_selftest/harness` 25/25;
  `_selftest/isolation` 6/6. Teardown stress `W0-ST.e2e.ps1` with `WMUX_W0ST_ITERATIONS=300`:
  Debug 300 workspace closes (p50 55 ms, max 603 ms) and 300 tab closes (p50 82 ms, max 679 ms),
  ReleaseFast 300 + 300 (p50 38 / 88 ms, max 96 / 714 ms), no hang. `pwsh test/web/run.ps1`:
  10/10 suites, 87/87 tests.
- [x] **All manifests, stubs, registries, ext structs, hooks and build steps present.**
  `pwsh scripts/check-manifest.ps1`: 0 errors, 0 warnings (70 module directories / 70 manifest
  entries, 76 logic directories / 72 logic files with 1 exemption, 79 shared-appendable aggregators
  with 0 ordering issues, 9 ledger rows, 136 W0 alias lines allowed until the tag, ruling D16).
  Build steps: `zig build` (debug), ReleaseFast, `test-fast`, `test-cli`, `settings-schema` and the
  unfiltered `zig build test` all run in `gate.ps1 -Full`.
- [x] **Spike notes S1-S7 merged.** `docs/arch/spikes/S1-toasts.md`, `S2-hidden-instances.md`,
  `S3-scrollback-replay.md`, `S4-agent-shims.md`, `S5-webview2-proxies.md`,
  `S6-cli-forwarders.md`, `S7-d2d-sidebar-child.md` (W0-D merges `9305763`..`ae8eef8`); decisions in
  Appendix F (AF-4..AF-10). S2 is implemented on the app side (W0-A4) and in the harness (W0-B2).
- [x] **Every pre-build merged or folded.** `docs/arch/plan/WORKPACKAGES.json`: all 40 W0 work
  packages (plan waves 0-4 and 9) are `done`, including the 20 PB-* pre-builds and W1-1a-t, W1-2a,
  W1-6a, W1-8a; none was folded. Merge commits in `docs/arch/plan/mapping.md` (W1-1a-t `304cf53`,
  PB-platform `1152de0`, PB-web-harness `254a205` from cfleet round 4).
- [x] **test-fast green.** `zig build test-fast -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`:
  1243/1243 passed.
- [x] **Gate.** `pwsh scripts/gate.ps1 -Full -FullTest -Base 18381f4`: GATE PASSED, 13/13 steps,
  0 warnings, 13 min 02 s (fmt, pslint, ownership, manifest, build 0:48, release 2:48, test-fast
  0:05, test-cli 0:14 (526/526), unit 1:10 (`unit: `, sidebar, wsl, win-pwd, `ipc:`: 1219/1219),
  e2e all suites 2:38 (199 tests, 138 passed, 61 skipped), web 0:27 (87/87), contract 0:01,
  fulltest 4:44 (unfiltered: 4047/4102 passed, 55 skipped, 0 failed; the 9 DiskCache entries of
  `test/known-failures.txt` did not fail)). `-Base 18381f4` is the branch's first commit, the W0-ST
  spec amendment: `check-ownership` reads the spec from the base, and against plain master it reports
  the six part 2 paths that amendment adds. Merge `18381f4` (or cherry-pick it) to master first,
  then the whole branch passes against master. The first `-Full` run (against the same base) failed
  only in fulltest: the unfiltered test binary no longer compiled (fixed in `eb4526a`, see Internal
  notes).
- [ ] **Tag `wave-0`.** After the merge of `wp/W0-ST-stabilize`, on the master commit where
  `gate.ps1 -Full` is green (AF-2); not created by this branch.

Result: M0 exit criteria met on the branch; the cloaked GL capture and the two GitHub Actions jobs
stay open as non-blocking manual checks (`docs/arch/manual-checks.md`).
