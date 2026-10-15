---
id: W2-5
title: Notifications core
wave: 2
size: L                      # S < 1 agent-day, M 1-2, L 2-4 (XL must be split)
depends: [W1-1, W1-4, W1-8]
covers:                      # matrix.csv ids; each needs an e2e `# covers:` tag or a `# manual:` waiver
  - notifications-store-model
  - notifications-unread-model
owns:                        # globs this WP may create/modify
  - src/apprt/win32/features/notifications/**
  - src/wmux_proto/settings/specs/notifications.zig
  - src/wmux_cli/commands/notify.zig
  - test/e2e/suites/notifications/W2-5*.e2e.ps1
  - docs/wmux/features/notifications.md
  - changes/W2-5.md
touches:                     # hot/frozen files, each with the reason (must match the wave's hot-file table)
  - path: src/apprt/surface.zig
    reason: heap notification payload in the surface message
appends:                     # shared-appendable files
  - src/wmux_proto/events_catalog.zig
apis_needed: []              # other features' api.zig functions (stubbed by the wave interface commit)
ccr: []                      # docs/arch/ccr/<wp>-<n>.md
deviations: []               # Appendix E rows requested
---

## Design notes
Links to ADR sections; decisions specific to this WP; acceptance lines taken from inventory/<area>.json.

## Tests
Unit test names (`unit: notifications: …`), e2e suite paths, manual waivers with reasons.

## Done when
`scripts/gate.ps1 -Wp W2-5` green; `coverage.ps1` shows every listed id covered or waived; docs and changelog fragment written.
