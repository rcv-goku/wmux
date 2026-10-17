# docs/arch: how the wmux → cmux parity program works

This directory is the home of the parity program's architecture and process.
[`ARCHITECTURE.md`](ARCHITECTURE.md) is **authoritative**; this README only explains how to
work with it and with the tooling in `scripts/`. Where the two disagree, ARCHITECTURE.md wins.

| Path | What | Written by |
|---|---|---|
| `ARCHITECTURE.md` | the authoritative architecture (ADR-1 … ADR-14, §15 conventions, appendices) | lead architect only; changes are dated entries in Appendix F |
| `wp/<id>.md` | one spec per work package, from [`wp/_template.md`](wp/_template.md) (Appendix H); from W1 on rendered from the plan by `scripts/new-wp-specs.ps1` | integrator at wave kickoff; the WP may update `ccr:` |
| `plan/WORKPACKAGES.json`, `plan/mapping.md` | the work-package plan (waves, files, acceptance) and the branch / old-id mapping | integrator (W0-R, wave kickoffs) |
| [`manual-checks.md`](manual-checks.md) | the non-blocking manual-check ledger (AF-19): one row per `# manual:` waiver | any WP appends its rows; the N9 stabilization runs them |
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
  get a letter (`W1-1a`, `W1-1b`), W0 lanes have names (`W0-A1`, `W0-C`, `W0-D-S1`), the
  pre-build lanes are `PB-<name>` (`PB-notif`, `PB-web-taskmgr-todo`; AF-2). The plan id
  `WP-<NN>-<slug>` (NN = plan wave) never appears in branches or commit tags. Size
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
  `scripts/gate.ps1 -Wp <id>` green → the integrator runs `scripts/gate.ps1 -Merge -Wp <id>`
  on the rebased head (it may commit `chore(schema)`) and merges `--no-ff`, one merge at a
  time; two ownership-disjoint WPs may be gated together on one base with
  `gate.ps1 -Batch <a>,<b>` (§14.9, AF-23). `gate.ps1 -Full` runs at every wave end (N9) and
  nightly in CI. A red master blocks the queue; the offending merge is reverted, not patched
  in place.
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
| Shared-appendable | `actions_catalog.zig`, `events_catalog.zig`, `platform/win32.zig` sections, `THIRD_PARTY_LICENSES.md`; the test aggregators `fast_tests.zig`, `test_index.zig`, every `**/logic/tests.zig`, `src/wmux_cli/logic/tests.zig` and the `proto.zig` re-exports (AF-15); the ledger `manual-checks.md` | the WP that declares the file in `appends` (frozen aggregators accept a declared append; any WP may re-sort an aggregator or append ledger rows): one sorted entry per line, nothing else changed (`merge=union`) |
| Merge-time artifact | `docs/wmux/schema/wmux.schema.json` (AF-15) | any WP may regenerate it; `merge=ours` keeps master's copy on merge and `gate.ps1 -Merge` regenerates and commits it on the merged tree |
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

### `scripts/gate.ps1`: tiered gates (AF-23)

| Tier | Who, when | Command |
|---|---|---|
| local | the WP agent, before asking for a merge | `pwsh scripts/gate.ps1 -Wp <id>` |
| merge | the integrator, per merge, on the rebased WP head or on the merge commit; budget 12 min | `pwsh scripts/gate.ps1 -Merge -Wp <id>` |
| batch | the integrator, two ownership-disjoint WPs on one base (§14.9) | `pwsh scripts/gate.ps1 -Batch <a>,<b>` |
| full | every wave end (N9) and the nightly CI job | `pwsh scripts/gate.ps1 -Full` |

| Step | What | `-Wp` | `-Merge` / `-Batch` | `-Full` |
|---|---|---|---|---|
| `batch` | both WP branches sit on the current base and inside HEAD; their changed paths are disjoint outside appends | | batch only | |
| `fmt` | `zig fmt --check` on `.zig`/`.zon` files changed vs master | ✓ | ✓ | ✓ |
| `pslint` | PowerShell parse check of changed `.ps1`/`.psm1`/`.psd1` | ✓ | ✓ | ✓ |
| `ownership` | `check-ownership.ps1 -Wp <id>` (per WP branch with `-Head` in a batch) | ✓ | ✓ | ✓ (WP id from `-Wp` or the branch) |
| `manifest` | `check-manifest.ps1` | ✓ | ✓ | ✓ |
| `schema` | `zig build settings-schema` on the merged tree; commits `chore(schema): regenerate the settings schema [<id>]` when it changed | | ✓ | |
| `build` | debug build | ✓ | ✓ | ✓ |
| `release` | ReleaseFast build into `zig-out\release` | | ✓ (in the background, beside the other steps) | ✓ |
| `test-fast`, `test-cli` | `zig build test-fast` / `test-cli` | ✓ | ✓ | ✓ |
| `unit` | `zig build test` with `-Dtest-filter` | `unit: <feature>` for owned/changed features; `unit: ` + legacy filters when shared code changed | the same area filters, always plus the legacy filters `sidebar`, `wsl`, `win-pwd`, `ipc:` | `unit: ` + legacy filters |
| `e2e` | one `test/e2e/run.ps1 -Suite a,b,... -Parallel 4` run | `smoke` + the areas of the WP's suites | `smoke`, `legacy`, `regression` + the areas of the WP's suites, of suites whose `# covers:` tags name the spec's ids, of changed suites and of changed feature ids with a suite area | all suites |
| `web` | `pwsh test/web/run.ps1` (headless web panels) | when `src/web/**` or `test/web/**` changed | same | always |
| `contract` | `test/cli/probes.ps1`, `test/contract/*.ps1` (each when present); `-Full` also checks the settings-schema golden | | ✓ | ✓ |
| `fulltest` | unfiltered `zig build test` vs `test/known-failures.txt` | with `-FullTest` | with `-FullTest` | ✓ (`-NoFullTest` drops it) |

- Steps whose prerequisites do not exist yet are **SKIP** with a notice (an e2e area without
  suites, `test/web/run.ps1`, contract scripts); WARN does not fail; the exit code is 1 when
  any step FAILs. All unit filters run in **one** compile (Zig ORs repeated
  `-Dtest-filter`s; `-SplitFilters` runs them one by one).
- `-Merge` on a merge commit of master itself diffs against the first parent (post-merge
  gate). The `schema` step defines the `ours` merge driver (`git config merge.ours.driver
  true`, shared by every worktree) that `.gitattributes` names; `-NoSchemaCommit` only
  reports. The budget (`-BudgetSec`, default 720 s for `-Merge`) is a warning, not a failure.
- `-Batch <a>,<b>` expects HEAD to be a batch branch holding both WP branches:
  `git switch -c batch/<a>+<b> master; git merge --no-ff wp/<a>-...; git merge --no-ff wp/<b>-...`.
  The branches are found as the single local `wp/<id>[-*]` branch of each id (`-BatchRef`
  overrides).
- Useful options: `-Only fmt,ownership`, `-Skip e2e`, `-FailFast`, `-DryRun` (prints the tier
  plan), `-Quiet` (log tails on failure only), `-UnitFilter 'unit: x'`, `-AllowMissingSpec`.
- Logs and `summary.json` go to `.zig-cache\wmux-gate\<timestamp>-<mode>-<id>\`;
  `summary.json` holds the tier, every step's result and duration (`durations`, wall time of
  the background release build), the total `seconds`, `budget_seconds` and `within_budget`.
- `e2e` tests the debug `zig-out\bin\wmux.exe` of the `build` step (`run.ps1 -Exe`), or lets
  `run.ps1` build it (`-Build Debug`) when that step is skipped. Child scripts get `ZIG` set
  to the gate's zig.
- Contract scripts (`test/cli/probes.ps1`, `test/contract/*.ps1`) run with the repo root as
  working directory and no arguments, find binaries under `zig-out\bin` themselves and
  exit non-zero on failure.
- Cross-compiling by hand (`zig test` / `zig build-exe` with `-M` module flags): `-target`
  must come before the first `-M`, or zig builds those modules for the host. The gate and CI
  only use `zig build` with `-Dtarget`.

### `scripts/new-wp-specs.ps1`: WP specs from the plan

`pwsh scripts/new-wp-specs.ps1 -Plan docs/arch/plan/WORKPACKAGES.json -Wave 10,11,12,13,19`
renders `docs/arch/wp/<arch_id>.md` for every planned WP of those plan waves (`-Wp <ids>`
selects by id; `-OutDir <dir>` previews into another directory; `-Force` overwrites;
`-Check` validates only). A spec gets `owns` = `files_new` + the non-frozen
`files_touched`, `touches` with the plan's reasons, `appends`, `covers` = features,
`depends` as arch ids, the architecture wave (`W1` → `1`), and Design notes / Tests /
Done when from the summary and acceptance lines; every spec is read back through the
tooling's YAML parser. Validation runs first and nothing is written when it fails:

- a placeholder (`<...>`, `TBD`, `TODO`, `FIXME`, `XXX`, `...`) in a path or reason, an
  empty title, a touches entry without a reason, an arch_id that is not a WP id;
- a `files_new` path (or glob) that already exists in the tree (`-AllowExisting` turns this
  plan drift into a warning and notes it in the spec);
- a frozen path (ADR-1.7 plus plan note 6) without a `touches` entry (a frozen
  shared-appendable file listed in `appends` is a declared append);
- two WPs of one plan wave touching the same path (glob-aware) outside `appends`;
- an existing spec without `-Force`.

A touched path that neither exists nor is created by an earlier WP is a warning.

### `scripts/check-ownership.ps1 -Wp <id>`

Fails when a committed or uncommitted change touches a path not matched by the spec's
`owns`, `touches` or `appends` globs (`**` spans directories, `*`/`?` stay inside a path
segment, `{a,b}` alternates; case-insensitive). The spec is read **from master** so a branch
cannot grant itself ownership (the worktree copy is used, with a warning, only while the
spec is not on master). Always allowed: the WP's own spec and its CCRs
`ccr/<id>-<n>.md`, the settings schema (merge-time artifact, AF-15), new rows in
`manual-checks.md` (AF-19) and a sort-only edit of a test aggregator (the same lines in
another order). From wave 1 on, frozen files need an explicit `touches` entry even if an
`owns` glob covers them; a frozen shared-appendable file (`fast_tests.zig`) also passes
through an `appends` entry, but then must not lose lines. Untracked files outside the spec
and appendable files that lose lines are warnings. `-Head <ref>` checks the committed
changes of another branch. Exit 0 ok, 1 violations, 2 missing/invalid spec.

Spec YAML is parsed by a small built-in subset parser: block maps and lists, `[a, b]`,
`{}`, quoted strings and `#` comments. Quote values that start with `*`, `{`, `!` or `&`.

### `scripts/check-manifest.ps1`

Static checks of ADR-1.3/1.4/12.1 and AF-15/AF-19: every `features/<id>/mod.zig` is listed
in `features/manifest.zig` and has a field in every `*Ext` struct of `features/ext.zig`;
`pub const id` equals the directory name; `state.zig` exists; every `logic/*.zig` (features
and layers) is referenced from its `logic/tests.zig`, which `mod.zig` and `fast_tests.zig`
reach; every shared-appendable aggregator (`fast_tests.zig`, `test_index.zig`,
`**/logic/tests.zig`, `src/wmux_cli/logic/tests.zig`, `proto.zig`) has one import per entry
line and sorted runs of entries (`_ = @import(...)`, `pub const x = @import(...)`) without
duplicates. Warnings: unsorted registry entries, missing pre-seeded modules (§1.5), new
aliases in `App.zig`/`ui/Window.zig` after the `wave-0` tag, and a `# manual: <id>` waiver
of an e2e suite without a row in `manual-checks.md`.

### Shared-appendable files and merge drivers (AF-15)

`.gitattributes` gives the registries, the test aggregators and the `proto.zig` re-exports
`merge=union` (two branches that each add a line both keep it) and the settings schema
`merge=ours`. A union merge of two appends at the same spot can leave entries out of order;
check-manifest then fails and anyone re-sorts the file (sort-only edits are allowed to every
WP). `merge=ours` needs `git config merge.ours.driver true` in the shared `.git/config`
(the gate's `schema` step sets it); without it git falls back to a normal text merge.

### `manual-checks.md`: the manual-check ledger (AF-19)

Checks only a person can do (IME, DPI over RDP, a real toast click, OLE drags, passkeys,
UAC, snap layouts, NVDA, relay security sign-off) never block a gate. The e2e suite that
would cover such a feature carries `# manual: <id> "<reason>"` and the WP appends one ledger
row per id; check-manifest warns about a waiver without a row, and the N9 stabilization runs
the open rows.

### `test/known-failures.txt`

The allowlist for the unfiltered `zig build test` (ADR-12.2): one fully qualified Zig test
name per line (`<path.with.dots>.test.<test name>`, e.g.
`cli.ssh-cache.DiskCache.test.disk cache default path`), a trailing `*` for a prefix, and a
`# reason` after ` #`. Any failure not listed fails `gate.ps1 -Full` (and `-FullTest`);
entries that no longer fail are reported for pruning.

### CI (`.github/workflows/windows-ci.yml`, ADR-12.6)

Job *Build & test* builds, runs `test-fast`/`test-cli` when the build defines them, and the
unit + legacy filters; job *Tooling* parses every script and runs `check-manifest.ps1` and
`scripts/test-tooling.ps1`; job *Web (Node)* runs every `test/web-node/**/*.test.mjs`
(`node --test` with jsdom in `WMUX_WEB_TEST_DEPS`); job *Nightly full gate* runs
`scripts/gate.ps1 -Full` on a schedule (and on manual dispatch) and uploads the gate logs and
`summary.json`. `test.yml` keeps running the full suite on master.
