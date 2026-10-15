# docs/arch: how the wmux → cmux parity program works

This directory is the home of the parity program's architecture and process.
[`ARCHITECTURE.md`](ARCHITECTURE.md) is **authoritative**; this README only explains how to
work with it and with the tooling in `scripts/`. Where the two disagree, ARCHITECTURE.md wins.

| Path | What | Written by |
|---|---|---|
| `ARCHITECTURE.md` | the authoritative architecture (ADR-1 … ADR-14, §15 conventions, appendices) | lead architect only; changes are dated entries in Appendix F |
| `wp/<id>.md` | one spec per work package, from [`wp/_template.md`](wp/_template.md) (Appendix H) | integrator at wave kickoff; the WP may update `ccr:` |
| `ccr/<wp>-<n>.md` | Core Change Requests, from [`ccr/_template.md`](ccr/_template.md) | the requesting WP |
| `spikes/<name>.md` | spike decision notes S1–S7 (§14.7) | W0-D |

## Read first

Every implementation agent reads, in this order (§15.1):

1. [§0](ARCHITECTURE.md#0-summary-glossary-ground-rules): decisions, glossary, ground rules G1–G10 (clean room, name rule, UI-thread ownership, no focus stealing, …).
2. The ADR(s) of its area (ADR-1 modularization … ADR-13 remote).
3. [§15 "Conventions for implementation agents"](ARCHITECTURE.md#15-conventions-for-implementation-agents): where to register things, file ownership, coding rules, tests, commands, commits, definition of done.
4. Its WP spec `wp/<id>.md`, then the `inventory/`, `gaps/` and `verify/` research entries of every feature id in `covers:`.

## Waves (ADR-14)

- Work is cut into waves **W0 … W7**, each ending in a milestone **M0 … M7** (§14.2).
  W0 restructures the code base (single core lane W0-A, plus harness W0-B, tooling W0-C and
  spikes W0-D in parallel); W1 builds the platform foundations; W2 reaches core cmux parity;
  W3–W7 add agents, panels, extended features, remote and polish.
- **Kickoff**: the integrator lands one *wave interface commit* (stub `api.zig` functions
  named in WP specs, new catalog lines, CLI family stubs, folded CCRs) and the WP specs;
  all WPs of the wave branch from it (§14.1).
- **Hot files**: each wave's table in §14 names the single owner of every frozen/hot file
  for that wave.
- **End**: a one-agent stabilization WP (flakes, docs, coverage report, release build,
  dogfood checklist). The wave is tagged **`wave-<N>`** (e.g. `wave-0`) only when
  `scripts/gate.ps1 -Full` is green on master. `scripts/check-manifest.ps1` uses the
  `wave-0` tag as the baseline for "no new W0 aliases" (ADR-1.9).
- Wave N+1 branches only after wave N is tagged (§14.9).

## Work packages

- **Ids**: `W<wave>-<n>` (`W2-5`; the split wave 5 gives `W5a-<n>`, `W5b-<n>`), split packages
  get a letter (`W1-1a`, `W1-1b`), W0 lanes have names (`W0-A1`, `W0-C`, `W0-D-S1`). Size
  S < 1 agent-day, M 1–2, L 2–4; XL is split.
- **Spec** (`wp/<id>.md`, Appendix H): YAML front matter with `id`, `title`, `wave`, `size`,
  `depends`, `covers` (matrix.csv ids), `owns` (globs the WP may create/modify), `touches`
  (frozen/hot files, each with a `reason`, matching the wave's hot-file table), `appends`
  (shared-appendable files), `apis_needed`, `ccr`, `deviations` (Appendix E rows); then
  *Design notes*, *Tests* and *Done when*.
- **Branch and worktree**: `wp/<id>-<slug>` in `..\wmux-wt\<id>`, created by
  `scripts/new-worktree.ps1` (below).
- **Lifecycle** (§14.9): spec merged → worktree from the interface commit → implement inside
  `owns`/`touches`/`appends` → rebase onto master (regenerate nothing) →
  `scripts/gate.ps1 -Wp <id>` green → the integrator runs `scripts/gate.ps1 -Full` on the
  rebased head and merges `--no-ff`, one merge at a time (two only when ownership is
  disjoint and both gates passed on the same base). A red master blocks the queue; the
  offending merge is reverted, not patched in place.
- **Definition of done** (§15.8): cmux behavior for every covered id (or an Appendix E
  deviation), registered only through extension points, unit tests (`unit: <feature>: …`),
  an e2e suite `test/e2e/suites/<area>/<id>*.e2e.ps1` tagging every covered id
  (`# covers:`/`# manual:`), CLI goldens and offline help, docs `docs/wmux/**`, a changelog
  fragment `changes/<id>.md`, both gates green, no focus stealing, no new warnings.
- **Commits** (§15.7): `<type>(<scope>): <summary> [<id>]`, body = what and why,
  `Covers: <ids>`, referenced CCRs, plus the attribution trailer your harness requires.

## File ownership and CCRs (ADR-1.7)

| Class | Examples | Who edits |
|---|---|---|
| Owned | `features/<id>/**`, `specs/<id>.zig`, `commands/<family>.zig`, `src/web/<app>/**`, the WP's e2e suites, docs and changelog fragment | the WP whose spec `owns` them |
| Frozen | `App.zig`, `ui/Window.zig`, `model/**`, registries and manifests, `Config.zig`, `Binding.zig`, `build.zig`, `src/build/**`, core Ghostty files | the WP named in the wave's hot-file table (spec `touches`), or via a CCR |
| Layer | non-frozen files of `app/ platform/ ui/ input/ rpc/ settings/ web/` | the layer's owning WP in that wave |
| Shared-appendable | `actions_catalog.zig`, `events_catalog.zig`, `platform/win32.zig` sections, `THIRD_PARTY_LICENSES.md` | any WP: one sorted entry per line, nothing else changed (`merge=union`) |
| Proto | other `src/wmux_proto/**` | the creating WP; frozen after its wave |

**Need a file outside your spec?** Do not edit it "just a little" (§15.1). Copy
`ccr/_template.md` to `ccr/<id>-<n>.md`, describe *what*, *why* and an *exact diff
sketch*, list it in your spec's `ccr:` field and keep shipping behind a stub. The
integrator folds the CCR into the current wave's owner of that file, schedules it for the
next wave (often in the interface commit), or rejects it, and records the decision in the
CCR's front matter (`status`, `decision`).

## Spikes (§14.7)

Spikes S1–S7 (W0-D) de-risk platform unknowns before the waves that depend on them
(toasts, hidden test instances, scrollback replay, agent shims, WebView2 proxies, CLI
forwarders, the D2D sidebar child). Prototypes live in throwaway branches; only the
decision note `spikes/<name>.md` is merged. Each note states the question, what was tried,
the result, the decision and the fallback; consumers (the WPs listed in §14.7) cite it.

## Tooling

All scripts are PowerShell 7 (`pwsh`), need no extra modules, and share
`scripts/lib/WmuxTooling.psm1`. `Get-Help scripts/<name>.ps1 -Full` shows every option.
Zig is found via `-Zig`, `$env:ZIG`, `zig` on PATH, or `~\zig-x86_64-windows-0.15.2\zig.exe`.

### `scripts/new-worktree.ps1 -Wp <id> [-Slug <slug>]`

Creates `..\wmux-wt\<id>` on branch `wp/<id>-<slug>` from master (re-uses an existing branch
or worktree), keeps the shared Zig cache (Zig's per-user default; overridden only when the
worktree is on another drive), stages an x64 `WebView2Loader.dll` into `zig-out\bin`
(`-WebView2Loader`, `$env:WEBVIEW2LOADER_PATH`, the main checkout's `zig-out\bin` or
`dist\windows`, `%LOCALAPPDATA%\Programs\wmux[\bin]`, the NuGet cache) and runs the first
debug build. The slug defaults to the spec title. `-NoBuild` skips the build, `-WhatIf`
prints the plan.

### `scripts/gate.ps1 -Wp <id>` (local gate) and `-Full` (merge gate)

| Step | What | `-Wp` | `-Full` |
|---|---|---|---|
| `fmt` | `zig fmt --check` on `.zig`/`.zon` files changed vs master | ✓ | ✓ |
| `pslint` | PowerShell parse check of changed `.ps1`/`.psm1`/`.psd1` | ✓ | ✓ |
| `ownership` | `check-ownership.ps1 -Wp <id>` | ✓ | ✓ (WP id from `-Wp` or the branch) |
| `manifest` | `check-manifest.ps1` | ✓ | ✓ |
| `build` | debug build | ✓ | ✓ |
| `release` | ReleaseFast build into `zig-out\release` | | ✓ |
| `test-fast`, `test-cli` | `zig build test-fast` / `test-cli` once W0-A3 defines them | ✓ | ✓ |
| `unit` | `zig build test` with `-Dtest-filter` | `unit: <feature>` for owned/changed features; `unit: ` + legacy filters when shared code changed | `unit: `, `sidebar`, `wsl`, `win-pwd`, `ipc:` |
| `e2e` | `test/e2e/run.ps1` once W0-B ships it | suite `smoke` + the areas of `<id>*.e2e.ps1` | all suites (`-Parallel 4`) |
| `contract` | settings-schema golden, `test/cli/probes.ps1`, `test/contract/*.ps1` (each when present) | | ✓ |
| `fulltest` | unfiltered `zig build test` vs `test/known-failures.txt` | with `-FullTest` | with `-FullTest` |

- Steps whose prerequisites do not exist yet are **SKIP** with a notice; WARN does not fail;
  the exit code is 1 when any step FAILs. All unit filters run in **one** compile (Zig ORs
  repeated `-Dtest-filter`s; `-SplitFilters` runs them one by one).
- Useful options: `-Only fmt,ownership`, `-Skip e2e`, `-FailFast`, `-DryRun` (plan only),
  `-Quiet` (log tails on failure only), `-UnitFilter 'unit: x'`, `-AllowMissingSpec`.
- Logs and `summary.json` go to `.zig-cache\wmux-gate\<timestamp>-<mode>-<id>\`.
- `e2e` tests the debug `zig-out\bin\wmux.exe` of the `build` step (`run.ps1 -Exe`), or lets
  `run.ps1` build it (`-Build Debug`) when that step is skipped. Child scripts get `ZIG` set
  to the gate's zig.
- Contract scripts (`test/cli/probes.ps1`, `test/contract/*.ps1`) run with the repo root as
  working directory and no arguments, find binaries under `zig-out\bin` themselves and
  exit non-zero on failure.

### `scripts/check-ownership.ps1 -Wp <id>`

Fails when a committed or uncommitted change touches a path not matched by the spec's
`owns`, `touches` or `appends` globs (`**` spans directories, `*`/`?` stay inside a path
segment, `{a,b}` alternates; case-insensitive). The spec is read **from master** so a branch
cannot grant itself ownership (the worktree copy is used, with a warning, only while the
spec is not on master). Always allowed: the WP's own spec and its CCRs
`ccr/<id>-<n>.md`. From wave 1 on, frozen files need an explicit `touches` entry even if an
`owns` glob covers them. Untracked files outside the spec and shared-appendable files that
lose lines are warnings. Exit 0 ok, 1 violations, 2 missing/invalid spec.

Spec YAML is parsed by a small built-in subset parser: block maps and lists, `[a, b]`,
`{}`, quoted strings and `#` comments. Quote values that start with `*`, `{`, `!` or `&`.

### `scripts/check-manifest.ps1`

Static checks of ADR-1.3/1.4/12.1: every `features/<id>/mod.zig` is listed in
`features/manifest.zig` and has a field in every `*Ext` struct of `features/ext.zig`;
`pub const id` equals the directory name; `state.zig` exists; every `logic/*.zig` (features
and layers) is referenced from its `logic/tests.zig`, which `mod.zig` and `fast_tests.zig`
reach; unsorted entries, missing pre-seeded modules (§1.5) and new aliases in
`App.zig`/`ui/Window.zig` after the `wave-0` tag are warnings. Before W0-A3 it reports
"skeleton not present yet" and passes.

### `test/known-failures.txt`

The allowlist for the unfiltered `zig build test` (ADR-12.2): one fully qualified Zig test
name per line (`<path.with.dots>.test.<test name>`, e.g.
`cli.ssh-cache.DiskCache.test.disk cache default path`), a trailing `*` for a prefix, and a
`# reason` after ` #`. Any failure not listed fails `gate.ps1 -FullTest`; entries that no
longer fail are reported for pruning.

### CI (`.github/workflows/windows-ci.yml`, ADR-12.6)

Job *Build & test* builds, runs `test-fast`/`test-cli` when the build defines them, and the
unit + legacy filters; job *Tooling* parses every script and runs `check-manifest.ps1` and
`scripts/test-tooling.ps1`. `test.yml` keeps running the full suite on master.
