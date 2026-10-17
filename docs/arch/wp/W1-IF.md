---
id: W1-IF
title: "W1 kickoff interface commit: specs, facades and stubs for same-sub-wave calls"
wave: 1                      # architecture wave W1 (plan wave 10, WP-10-w1-interface)
size: S                      # S < 1 agent-day, M 1-2, L 2-4 (XL must be split)
depends: [W0-ST]
covers: []                   # interface commit: no matrix.csv feature ids
owns:                        # plan files_new + non-frozen files_touched (hand-written: the generator skips in_progress WPs)
  - docs/arch/wp/W1-*.md
  - src/apprt/win32/input/router.zig
  - src/apprt/win32/features/chrome/dpi_hooks.zig
  - src/apprt/win32/features/chrome/rpc.zig
  - src/wmux_cli/commands/wmux/*.zig
  - src/apprt/win32/ui/sidebar/api.zig
  - src/apprt/win32/ui/right_sidebar/api.zig
  - src/apprt/win32/ui/tabbar/hints.zig
  - src/apprt/win32/ui/strings.zig
  - src/wmux_cli/logic/tests.zig
  - src/apprt/win32/ui/notice.zig
  - src/apprt/win32/features/chrome/mod.zig
  - src/wmux_cli/commands/wmux_ns.zig
  - src/apprt/win32/ui/tabbar/paint.zig
  - src/wmux_cli/main.zig
  - src/apprt/win32/ui/sidebar/mod.zig
  - src/apprt/win32/ui/right_sidebar/mod.zig
  - src/apprt/win32/settings/api.zig
  - src/apprt/win32/features/env_identity/api.zig
  - src/apprt/win32/rpc/server/mod.zig
  - src/apprt/win32/web/env.zig
  - src/apprt/win32/features/session/api.zig
  # the owner decisions of 2026-10-17 and the plan fixes (integrator)
  - docs/arch/ARCHITECTURE.md
  - docs/arch/plan/WORKPACKAGES.json
  - docs/arch/release-notes/wave-0.md
  - docs/arch/wp/W0-A4.md
touches:                     # frozen paths of the plan entry, with its reasons
  - path: src/apprt/win32/model/TabContent.zig
    reason: "ruling D5: TabContent.setBounds(Rect) (moves hwnd()) and snapshot(*std.json.Stringify) (writes {kind}) for every variant"
  - path: src/apprt/win32/ui/Window.zig
    reason: WM_CLOSE calls features/session/api.zig onWindowClose (the unchanged gated legacy save moves there) so W1-7a removes the per-window overwrite in its own file
appends:                     # shared-appendable files: one sorted entry per line
  - src/apprt/win32/test_index.zig
apis_needed: []              # this commit creates the facades the W1 specs list
ccr: []                      # docs/arch/ccr/<wp>-<n>.md
deviations: []               # Appendix E rows requested (D34 is an owner decision recorded here, not a request)
---

<!-- Hand-written by the integrator: scripts/new-wp-specs.ps1 renders only planned WPs and W1-IF is in_progress while it runs. Source: docs/arch/plan/WORKPACKAGES.json (WP-10-w1-interface). -->

## Design notes
- Plan entry `WP-10-w1-interface` (`docs/arch/plan/WORKPACKAGES.json`), executor integrator, est.
  size S. Integrator-only commit series every W1 WP branches from (ADR-14.1.4, AF-1). No behavior
  change: the legacy suites stay green.
- Commits: (1) `docs(arch)` the owner decisions of 2026-10-17 (Appendix F.2 entry, ADR-12.3,
  Appendix B.4, E D34, G.2, the W0-A4 acceptance wording, the release notes); (2) `docs(plan)` the
  stale W0-C2 paths, the W1 executors, W1-IF in progress and the kickoff file lists; (3) `docs(wp)`
  the rendered W1 specs with their carried follow-ups; (4) `feat` the kickoff interface code; (5)
  `feat(model)` `TabContent.setBounds`/`snapshot` (ruling D5).
- Kickoff interface code (AF-1): sub-files and pre-declared tables where two W1 WPs of one plan
  wave would otherwise edit the same file, and a facade with its final signature and a stub body in
  the owning WP's file for every call a W1 WP makes into another WP of the same sub-wave (plus the
  forward calls of an earlier sub-wave that the caller could not otherwise compile). The specs of
  both the owner and the caller list each facade in their "Kickoff interface (W1-IF)" section; the
  callers' `apis_needed` name them.
- The research copies `research/parity/design/ARCHITECTURE.md` and `WORKPACKAGES.json` are kept
  byte-identical to the repository copies.

## Tests
- `zig build`, `test-fast` and `test-cli` green; unit tests for the new stubs (`unit: ui: notice`,
  `unit: settings: get returns spec defaults`, `unit: model: snapshot writes the kind`).
- e2e smoke, legacy and regression suites green (behavior identical).

## Done when
- `pwsh scripts/new-wp-specs.ps1 -Plan docs/arch/plan/WORKPACKAGES.json -Wave 10,11,12,13,19`
  exited 0 without `-AllowExisting` after the plan fix, and every rendered W1 spec parses
  (`scripts/check-ownership.ps1 -SpecPath`); `-Check` stays clean after the kickoff code.
- `pwsh scripts/gate.ps1 -Merge -Wp W1-IF` green; both architecture copies and both plan copies in
  step.
