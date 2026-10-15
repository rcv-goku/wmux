---
id: W0-C
title: Tooling
wave: 0
size: M                      # S < 1 agent-day, M 1-2, L 2-4 (XL must be split)
depends: []
covers: []                   # tooling only: no matrix.csv feature ids
owns:                        # section 14.3; docs/arch/spikes/** belongs to W0-D
  - scripts/**
  - .github/**
  - docs/arch/ARCHITECTURE.md
  - docs/arch/README.md
  - docs/arch/wp/**
  - docs/arch/ccr/**
  - AGENTS.md
  - test/known-failures.txt
touches: []
appends: []
apis_needed: []
ccr: []
deviations: []
---

## Design notes
- ADR-1.7 (ownership classes, CCR process), ADR-12.2/12.5/12.6 (build steps, gates, CI),
  ADR-14.9 (merge protocol), section 15 (conventions), Appendix H (this template).
- `docs/arch/ARCHITECTURE.md` is a byte-exact copy of the lead architect's document;
  later changes arrive only as dated Appendix F entries from the lead architect.
- Scripts are PowerShell 7 without external modules; shared code lives in
  `scripts/lib/WmuxTooling.psm1` (YAML-subset front-matter parser, glob matching, git and
  process helpers, Zig test-log parsing).
- `gate.ps1` skips steps whose prerequisites do not exist yet (W0-A3 build steps, the W0-B
  harness, contract tests) with a notice, so it is usable from day one and tightens itself
  as the skeleton lands.
- `check-ownership.ps1` reads the spec from `master` so a branch cannot grant itself
  ownership; from wave 1 on, frozen files (ADR-1.7) need an explicit `touches` entry.

## Tests
- `pwsh scripts/test-tooling.ps1`: self-tests of the module (YAML subset, globs, known
  failures, Zig log parsing) and of check-ownership / check-manifest on throwaway fixtures.
- Every `.ps1`/`.psm1` parses (`System.Management.Automation.Language.Parser`);
  `scripts/check-manifest.ps1` runs on the current tree; workflow YAML parses.
- No e2e suite: this WP ships no user-visible feature (`covers: []`).

## Done when
`scripts/gate.ps1 -Wp W0-C` green; `scripts/test-tooling.ps1` green; CI workflow valid.
