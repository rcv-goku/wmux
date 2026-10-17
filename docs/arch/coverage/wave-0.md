# Wave 0 parity coverage

Recorded by W0-ST part 2 on 2026-10-17 (branch `wp/W0-ST-stabilize`, base master `9538cf4`) with
`test/e2e/coverage.ps1` (ADR-12.7, Appendix D.5):

```powershell
pwsh test/e2e/coverage.ps1 -Matrix C:\Users\Rey.ColonValero\claude\research\parity\matrix.csv -Json <file>
```

The matrix is the research copy `research/parity/matrix.csv` (894 rows, SHA-256 prefix `B8121F18366F`),
the last entry of the script's lookup order (`-Matrix`, `$env:WMUX_PARITY_MATRIX`, `docs/arch/matrix.csv`,
`..\research\parity\matrix.csv`, `..\..\research\parity\matrix.csv`, then this path). In-scope ids are the
rows with scope `local-core` or `local-extended` and status `partial` or `missing`: 815 ids, the same set as
`research/parity/design/inscope-ids.json` that the plan assigns.

## Result: 0 of 815 in-scope ids covered (expected at M0)

Wave 0 builds the skeleton, the harness and the legacy safety net; it claims no matrix feature ids
(every W0 spec has `covers: []`). The seven suites carry `# wp:` tags only:

| Suite | wp | covers | manual |
|---|---|---|---|
| `_selftest/harness.e2e.ps1` | W0-B | 0 | 0 |
| `_selftest/isolation.e2e.ps1` | W0-B2 | 0 | 0 |
| `legacy/legacy-compat.e2e.ps1` | W0-B2 | 0 | 0 |
| `legacy/plus-verbs.e2e.ps1` | W0-B2 | 0 | 0 |
| `regression/w0-regression.e2e.ps1` | W0-B2 | 0 | 0 |
| `regression/W0-ST.e2e.ps1` | W0-ST | 0 | 0 |
| `smoke/smoke.e2e.ps1` | W0-B | 0 | 0 |

Stale tags 0, out-of-scope tags 0, invalid tags 0, quarantined ids 0 (`suites/_quarantine/` is empty).

## Per area

| Area | In scope | Covered | Waived | Uncovered | Coverage | Critical uncovered |
|---|---:|---:|---:|---:|---:|---:|
| agents | 94 | 0 | 0 | 94 | 0% | 10 |
| browser | 112 | 0 | 0 | 112 | 0% | 15 |
| cli | 83 | 0 | 0 | 83 | 0% | 11 |
| core | 96 | 0 | 0 | 96 | 0% | 23 |
| extra | 22 | 0 | 0 | 22 | 0% | 0 |
| hosted | 14 | 0 | 0 | 14 | 0% | 0 |
| notifications | 87 | 0 | 0 | 87 | 0% | 13 |
| panels | 74 | 0 | 0 | 74 | 0% | 5 |
| persistence | 77 | 0 | 0 | 77 | 0% | 8 |
| remote | 69 | 0 | 0 | 69 | 0% | 7 |
| sidebar | 87 | 0 | 0 | 87 | 0% | 10 |
| **total** | 815 | 0 | 0 | 815 | 0% | 102 |

## Uncovered critical ids (102)

The W1+ feature WPs add `# covers:` tags for these first (ADR-12.7: a critical id needs a suite or a
`# manual:` waiver backed by a `docs/arch/manual-checks.md` row before its wave ends).

- **agents** (10): `agents-hooks-setup-all`, `agents-hooks-event-entrypoint`, `agents-hook-surface-resolution`, `agents-claude-wrapper`, `agents-claude-hook-events`, `agents-sidebar-agent-status`, `agents-turn-notifications`, `agents-codex-wrapper`, `agents-hook-session-store`, `agents-auto-resume-on-reopen`
- **browser** (15): `browser-surface-type`, `browser-omnibar-core`, `browser-terminal-link-routing`, `browser-cli-targeting-and-conventions`, `browser-cli-open`, `browser-cli-navigation`, `browser-cli-snapshot`, `browser-element-refs`, `browser-cli-eval`, `browser-cli-wait`, `browser-cli-element-actions`, `browser-cli-type-fill`, `browser-cli-keyboard`, `browser-cli-get`, `browser-cli-screenshot`
- **cli** (11): `cli-socket-path-resolution`, `cli-socket-access-modes`, `cli-v2-json-envelope`, `cli-socket-focus-policy`, `cli-handle-refs-and-indexes`, `cli-surface-selection-contract`, `cli-send-command`, `cli-send-key-command`, `cli-read-screen-command`, `cli-terminal-env-identity`, `cli-v2-methods-surface-pane`
- **core** (23): `core-hierarchy-model`, `core-cli-global-options`, `core-socket-v2-core-methods`, `core-window-multiple`, `core-workspace-create`, `core-cli-new-workspace`, `core-cli-workspace-namespace`, `core-workspace-close`, `core-workspace-select-navigate`, `core-workspace-rename`, `core-surface-new`, `core-surface-close`, `core-surface-navigate`, `core-split-create`, `core-cli-new-split-pane`, `core-pane-focus`, `core-dnd-tabs`, `core-left-sidebar-rail`, `core-shortcuts-defaults-app-window`, `core-shortcuts-defaults-workspaces`, `core-shortcuts-defaults-surfaces`, `core-shortcuts-defaults-panes`, `core-shortcuts-cmux-json`
- **notifications** (13): `notifications-cli-notify`, `notifications-socket-v2-api`, `notifications-osc-777`, `notifications-store-model`, `notifications-unread-model`, `notifications-read-on-focus-and-typing`, `notifications-jump-to-latest-unread`, `notifications-open-and-click-to-jump`, `notifications-pane-ring`, `notifications-sidebar-unread-badge`, `notifications-popover`, `notifications-desktop-delivery`, `notifications-focus-suppression`
- **panels** (5): `panels-open-cli`, `panels-file-open-socket`, `panels-terminal-find-bar`, `panels-command-palette-core`, `panels-command-palette-switcher`
- **persistence** (8): `persistence-session-snapshot-autosave`, `persistence-session-restore-on-launch`, `persistence-restored-layout-and-metadata`, `persistence-restore-working-directories`, `persistence-agent-session-resume-on-relaunch`, `persistence-cmuxjson-locations-and-precedence`, `persistence-ghostty-config-loading-and-reload`, `persistence-shell-integration-bootstrap`
- **remote** (7): `remote-ssh-workspace-command`, `remote-auto-reconnect-backoff`, `remote-persistent-pty-sessions`, `remote-splits-and-tabs-in-remote-workspace`, `remote-daemon-bootstrap`, `remote-cli-relay`, `remote-browser-egress`
- **sidebar** (10): `sidebar-left-vertical-workspace-list`, `sidebar-toggle-left`, `sidebar-workspace-row-title-line`, `sidebar-unread-badge`, `sidebar-status-entries`, `sidebar-agent-status-rows`, `sidebar-git-branch-directory`, `sidebar-context-menu`, `sidebar-drag-reorder`, `sidebar-right-sidebar-toggle`
