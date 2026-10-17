---
id: W0-ST
title: "Wave 0 stabilization, M0 exit check and wave-0 tag"
wave: 0                      # architecture wave W0 (plan wave 9, WP-09-w0-stabilization)
size: M                      # S < 1 agent-day, M 1-2, L 2-4 (XL must be split)
depends: [W0-A1, W0-A2, W0-A3, W0-A4, W0-B, W0-B2, W0-C, W0-C2, W0-D, W0-K, W0-P1, W0-P2, W0-P3, W0-P4, W0-R, W1-2a, W1-1a-t, W1-6a, W1-8a, PB-web-harness, PB-platform, PB-feed, PB-todo-status, PB-vault, PB-automation, PB-layouts-actions, PB-notif, PB-palette, PB-agents, PB-session, PB-tmux, PB-browser, PB-sidebar, PB-meta, PB-web-markdown, PB-web-diff, PB-web-notif-feed, PB-web-settings, PB-web-taskmgr-todo]
covers: []                   # stabilization: no matrix.csv feature ids
owns:                        # plan files_new + files_touched, then the summary's plan refresh, quarantine and the flake proof
  - docs/arch/coverage/wave-0.md
  - docs/arch/release-notes/wave-0.md
  - test/known-failures.txt
  - docs/arch/plan/WORKPACKAGES.json
  - docs/arch/plan/mapping.md
  - test/e2e/suites/_quarantine/**
  - test/e2e/suites/regression/W0-ST*.e2e.ps1
  - changes/W0-ST.md
  # part 2 (wp/W0-ST-stabilize): harness hang fix and the W0-B2 suites it re-runs (W0-B2 is done;
  # FOLLOWUPS gives the hang fix to "W0-B, or W0-ST part 2 if unowned"), docs reconciliation
  - test/e2e/WmuxTest.psm1
  - test/e2e/suites/_selftest/harness.e2e.ps1
  - test/e2e/suites/regression/w0-regression.e2e.ps1
  - docs/arch/ARCHITECTURE.md
  - docs/arch/wp/W0-B2.md
  # part 2: the unfiltered win32 test build (gate -FullTest) compiles again: two legacy_v2
  # tests built SplitTree(Pane) through init/deinit, which reaches the GTK apprt tests
  - src/apprt/win32/features/session/legacy_v2.zig
touches:                     # frozen core paths approved by ruling D17 (Appendix F.2, 2026-10-16)
  - path: src/termio/Exec.zig
    reason: ruling D17 core CCR, read-thread teardown race (a CancelIoEx issued before ReadFile starts is lost and the join hangs core_surface.deinit)
  - path: src/terminal/search/Thread.zig
    reason: ruling D17 core CCR, the unnamed search Thread test stops and joins its thread when its 100 ms wait times out
appends: []
apis_needed: []
ccr: [W0-ST-1, W0-ST-2]      # ruling D17 approved both core changes directly; the CCR files record them (status done)
deviations: []
---

## Design notes
- Plan entry `WP-09-w0-stabilization` (`docs/arch/plan/WORKPACKAGES.json`): one integrator agent.
  Read ADR-12.7 (flakes, coverage, and the known-flakes paragraph of ruling D17), ADR-14.1/14.2
  (M0), §14.9, §15.9 and Appendix F.2 (AF-2 tag policy, AF-19 automated suites instead of
  dogfooding, AF-23 gate tiers, rulings D16 and D17).
- W0-ST runs in two parts (W0-R brief, ruling D17):
  1. Early part, branch `wp/W0-ST-flakes`, started now (needs only W0-A3 and the D17 approval):
     fix the two known flakes through the core CCRs that D17 approved.
     - `src/termio/Exec.zig`: `threadExit` writes the quit pipe and cancels the read thread with one
       `CancelIoEx`; if the thread has not entered `ReadFile` yet the cancel is lost and
       `exec.read_thread.join()` hangs the UI thread in `core_surface.deinit` (about 1 in 6-10 fast
       workspace-new/close or tab-close runs). Make the Windows teardown race-free; the POSIX path
       stays as it is.
     - `src/terminal/search/Thread.zig`: the unnamed test returns from
       `try ud.reset.timedWait(100 * std.time.ns_per_ms)` on timeout before `thread.stop.notify()`
       and `os_thread.join()`, so the thread keeps running after the test frees its terminal and
       crashes under load. Stop and join on every path. Being unnamed, the test is part of every
       filtered run and `test/known-failures.txt` cannot list it.
     - Prove both: `test/e2e/suites/regression/W0-ST.e2e.ps1` runs rapid workspace and tab
       create/close loops on a Debug and a ReleaseFast build without a hang, and repeated filtered
       unit runs under load stay green.
  2. Final part, branch `wp/W0-ST-stabilize`, after every other W0 item merged: quarantine and fix
     the remaining flakes (ADR-12.7: a test that flakes twice within 7 days moves to
     `test/e2e/suites/_quarantine/`), consolidate `changes/*.md` into
     `docs/arch/release-notes/wave-0.md`, record the `test/e2e/coverage.ps1` report in
     `docs/arch/coverage/wave-0.md`, run `scripts/gate.ps1 -Full` and `-FullTest` on master, verify
     the M0 exit criteria, refresh the statuses in `docs/arch/plan/WORKPACKAGES.json` and
     `docs/arch/plan/mapping.md`, then tag `wave-0`.
- Both parts use this spec. The gate infers the WP id from the worktree directory or the branch, and
  `wp/W0-ST-flakes` alone would resolve to the id `W0-ST-flakes`: name the worktree `W0-ST` or pass
  `-Wp W0-ST` to `gate.ps1` and `check-ownership.ps1`.
- M0 exit criteria (summary and §14.2): identical legacy behavior on the skeleton (W0-B2
  legacy-compat, plus-verbs and w0-regression suites green, AF-19); all manifests, stubs,
  registries, ext structs, hooks and build steps present (`scripts/check-manifest.ps1` 0 errors);
  spike notes S1-S7 merged; every pre-build merged or explicitly folded into its consumer
  (`docs/arch/plan/mapping.md`; W1-1a-t, PB-platform and PB-web-harness come from cfleet round 4);
  test-fast green.
- Tag policy (AF-2): `wave-0` exists only after W0-ST, on the master commit where `gate.ps1 -Full`
  is green; sub-waves are untagged. `check-manifest.ps1` then uses the tag as its alias baseline:
  the existing W0 alias lines may stay, only new ones are reported (ruling D16).
- The summary's own steps add owned paths beyond the plan's file lists: the plan refresh
  (`docs/arch/plan/*`), quarantine (`test/e2e/suites/_quarantine/**`), the flake proof suite and the
  changelog fragment for the hang fix. Quarantining another WP's suite moves its file out of that
  WP's directory: list the source path in this spec on master before moving it.

## Tests
- Early part: `test/e2e/suites/regression/W0-ST.e2e.ps1` (create/close stress, Debug and
  ReleaseFast); `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
  "-Dtest-filter=unit: "` repeated under parallel load; the unfiltered `zig build test` no longer
  crashes in the `terminal.search.Thread` test.
- Final part: `scripts/gate.ps1 -Full` and `-FullTest` on master; legacy, regression, smoke and
  `_selftest` suites on Debug and ReleaseFast.

## Done when
- Early part: the stress suite shows no hang in its create/close loops on Debug and ReleaseFast;
  the `terminal.search.Thread` test joins its thread on every path; `changes/W0-ST.md` names the hang
  fix.
- `scripts/gate.ps1 -Full` and `-FullTest` green on master; legacy, regression, smoke and
  `_selftest` suites green on Debug and ReleaseFast.
- `docs/arch/coverage/wave-0.md` committed; `docs/arch/release-notes/wave-0.md` assembled from
  `changes/*.md`; `docs/arch/plan` statuses refreshed; `git tag wave-0` points at the green master
  commit.
