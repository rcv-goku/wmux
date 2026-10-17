# Plan mapping: branches, work packages and old plan ids

Written by W0-R (`WP-01-reconcile-streams`) on 2026-10-16 from `git log --merges --first-parent master`
at `fb31ab1` and the plan [`WORKPACKAGES.json`](WORKPACKAGES.json); statuses and executors are the
ones recorded there. Ids follow AF-2 (ARCHITECTURE Appendix F.2, 2026-10-16): the plan id
`WP-<NN>-<slug>` is the plan key; the arch id names branches `wp/<arch_id>-<slug>`, commit tags
`[<arch_id>]`, specs `docs/arch/wp/<arch_id>.md` and the ownership tooling. The cfleet pre-builds ran
on branches `wp/cf-*`; their round follows from the integration bases `cfleet/base-r2` and
`cfleet/base-r3` (branches, not work packages). W0-ST refreshes this file with the plan statuses at the
end of W0.

Refreshed by W0-ST part 2 on 2026-10-17 from `git log --merges --first-parent master` at `9538cf4`: every W0 work
package is merged and `done` in the plan; section (b) has no live branch left.

## (a) Merged branches

Dates are commit dates (CDT, UTC-5). A branch merged twice was merged again after review fixes.

| Merge | Date | Branch | arch_id | Plan id | Status | Executor |
|---|---|---|---|---|---|---|
| `9305763` | 2026-10-15 14:29 | `wp/W0-D-S1-toasts` | W0-D (S1) | WP-00-platform-spikes | done | external:wave0-fanout |
| `fdc2d7f` | 2026-10-15 14:40 | `wp/W0-D-S2-hidden-instances` | W0-D (S2) | WP-00-platform-spikes | done | external:wave0-fanout |
| `627a14c` | 2026-10-15 14:58 | `wp/W0-D-S5-webview2-proxies` | W0-D (S5) | WP-00-platform-spikes | done | external:wave0-fanout |
| `12f2a87` | 2026-10-15 15:24 | `wp/W0-D-S3-scrollback-replay` | W0-D (S3) | WP-00-platform-spikes | done | external:wave0-fanout |
| `d9558bd` | 2026-10-15 15:33 | `wp/W0-D-S6-cli-forwarders` | W0-D (S6) | WP-00-platform-spikes | done | external:wave0-fanout |
| `7c79e2c` | 2026-10-15 15:35 | `wp/W0-D-S4-agent-shims` | W0-D (S4) | WP-00-platform-spikes | done | external:wave0-fanout |
| `ae8eef8` | 2026-10-15 15:37 | `wp/W0-D-S7-d2d-sidebar-child` | W0-D (S7) | WP-00-platform-spikes | done | external:wave0-fanout |
| `3203829` | 2026-10-15 15:39 | `wp/W1-6a-web-assets` | W1-6a | WP-00-web-assets | done | external:wave0-fanout |
| `ec904e6` | 2026-10-15 15:41 | `wp/W1-8a-d2d-bindings` | W1-8a | WP-00-d2d-bindings | done | external:wave0-fanout |
| `1452aca` | 2026-10-15 15:46 | `wp/W0-K-skeleton` | W0-K | WP-00-skeleton | done | external:wave0-kickoff |
| `c1b0f5b` | 2026-10-15 16:10 | `wp/W0-B-harness` | W0-B | WP-00-e2e-harness | done | external:wave0-fanout |
| `da8aa66` | 2026-10-15 16:16 | `wp/W0-C-tooling` | W0-C | WP-00-dev-tooling | done | external:wave0-fanout |
| `87b7a22` | 2026-10-15 17:33 | `wp/cf-p4` | W0-P4 | WP-01-proto-events | done | external:cfleet-fanout-r1 |
| `f78c74f` | 2026-10-15 17:45 | `wp/cf-meta` | PB-meta | WP-01-pb-meta | done | external:cfleet-fanout-r1 |
| `b7b87d8` | 2026-10-15 18:02 | `wp/cf-notif` | PB-notif | WP-01-pb-notif | done | external:cfleet-fanout-r1 |
| `682bba9` | 2026-10-15 18:10 | `wp/cf-session` | PB-session | WP-01-pb-session | done | external:cfleet-fanout-r1 |
| `ca1ad89` | 2026-10-15 18:14 | `wp/cf-tmux` | PB-tmux | WP-01-pb-tmux | done | external:cfleet-fanout-r1 |
| `427747c` | 2026-10-15 18:20 | `wp/W0-A1-app-extraction` | W0-A1 | WP-00-app-extraction | done | external:wave0-core-lane |
| `2f2815e` | 2026-10-15 18:36 | `wp/cf-p1` | W0-P1 | WP-01-proto-core | done | external:cfleet-fanout-r1 |
| `4c5a8a9` | 2026-10-15 18:40 | `wp/cf-browser` | PB-browser | WP-01-pb-browser | done | external:cfleet-fanout-r1 |
| `bf96399` | 2026-10-15 18:45 | `wp/cf-agents` | PB-agents | WP-01-pb-agents | done | external:cfleet-fanout-r1 |
| `807f2b7` | 2026-10-15 18:50 | `wp/cf-p2` | W0-P2 | WP-01-proto-settings | done | external:cfleet-fanout-r1 |
| `c988472` | 2026-10-15 20:18 | `wp/cf-p3` | W0-P3 | WP-01-proto-actions-keys | done | external:cfleet-fanout-r1 |
| `00619c5` | 2026-10-15 21:08 | `wp/cf-palette` | PB-palette | WP-02-pb-palette | done | external:cfleet-fanout-r2 |
| `790bfad` | 2026-10-15 21:17 | `wp/cf-todostat` | PB-todo-status | WP-03-pb-todo-status | done | external:cfleet-fanout-r2 |
| `2a95ddf` | 2026-10-15 21:23 | `wp/cf-sidebar` | PB-sidebar | WP-02-pb-sidebar | done | external:cfleet-fanout-r2 |
| `e2c13e7` | 2026-10-15 21:31 | `wp/cf-vault` | PB-vault | WP-03-pb-vault | done | external:cfleet-fanout-r2 |
| `cafd119` | 2026-10-15 21:37 | `wp/cf-hookresearch` | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r2 |
| `0417d37` | 2026-10-15 21:43 | `wp/cf-cli` | W1-2a | WP-02-cli-core | done | external:cfleet-fanout-r2 |
| `38e9cf5` | 2026-10-15 21:49 | `wp/cf-automation` | PB-automation | WP-03-pb-automation | done | external:cfleet-fanout-r2 |
| `f2b5f7e` | 2026-10-15 21:54 | `wp/cf-layouts` | PB-layouts-actions | WP-03-pb-layouts-actions | done | external:cfleet-fanout-r2 |
| `55174cd` | 2026-10-15 22:01 | `wp/cf-feed` | PB-feed | WP-03-pb-feed | done | external:cfleet-fanout-r2 |
| `8db6812` | 2026-10-15 22:09 | `wp/cf-markdown` | PB-web-markdown | WP-04-pb-web-markdown | done | external:cfleet-fanout-r2 |
| `5faa1f3` | 2026-10-16 11:15 | `wp/cf-cli-browser` (1st merge) | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `8033204` | 2026-10-16 11:23 | `wp/cf-settings` (1st merge) | PB-web-settings | WP-04-pb-web-settings | done | external:cfleet-fanout-r3 |
| `ade373a` | 2026-10-16 11:30 | `wp/cf-cli-ws` (1st merge) | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `1bca577` | 2026-10-16 11:37 | `wp/cf-notiffeed` (1st merge) | PB-web-notif-feed | WP-04-pb-web-notif-feed | done | external:cfleet-fanout-r3 |
| `a588ad2` | 2026-10-16 11:43 | `wp/cf-cli-notify` (1st merge) | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `bea93a9` | 2026-10-16 13:27 | `wp/cf-cli-browser` (2nd merge) | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `e91c38a` | 2026-10-16 13:36 | `wp/cf-notiffeed` (2nd merge) | PB-web-notif-feed | WP-04-pb-web-notif-feed | done | external:cfleet-fanout-r3 |
| `be2a80d` | 2026-10-16 13:42 | `wp/cf-diff` | PB-web-diff | WP-04-pb-web-diff | done | external:cfleet-fanout-r3 |
| `28b3967` | 2026-10-16 13:46 | `wp/cf-settings` (2nd merge) | PB-web-settings | WP-04-pb-web-settings | done | external:cfleet-fanout-r3 |
| `8cb1f1e` | 2026-10-16 13:50 | `wp/cf-cli-notify` (2nd merge) | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `06d2091` | 2026-10-16 14:03 | `wp/cf-tasktodo` | PB-web-taskmgr-todo | WP-04-pb-web-taskmgr-todo | done | external:cfleet-fanout-r3 |
| `191938e` | 2026-10-16 14:06 | `wp/cf-cli-ws` (2nd merge) | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `6b1d6cd` | 2026-10-16 14:14 | `wp/W0-A2-window-model` | W0-A2 | WP-02-window-model | done | external:wave0-core-lane |
| `a837f2f` | 2026-10-16 14:31 | `wp/cf-cli-ps` | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `d08f63b` | 2026-10-16 14:36 | `wp/cf-remote` | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `dd3fc4c` | 2026-10-16 14:41 | `wp/cf-cli-misc` | none (ahead of plan) | none | merged, no WP | external:cfleet-fanout-r3 |
| `fb31ab1` | 2026-10-16 17:57 | `wp/W0-A3-skeleton` | W0-A3 | WP-03-registries-prewiring | done | external:wave0-core-lane |
| `1152de0` | 2026-10-16 23:02 | `wp/cf-platform` | PB-platform | WP-02-pb-platform | done | external:cfleet-fanout-r4 |
| `d9eb6c2` | 2026-10-16 23:11 | `wp/W0-R-reconcile` | W0-R | WP-01-reconcile-streams | done | integrator |
| `254a205` | 2026-10-16 23:16 | `wp/cf-webharness` | PB-web-harness | WP-02-pb-web-harness | done | external:cfleet-fanout-r4 |
| `304cf53` | 2026-10-16 23:27 | `wp/cf-rpc` | W1-1a-t | WP-02-rpc-transport | done | external:cfleet-fanout-r4 |
| `0106f4f` | 2026-10-17 00:29 | `wp/W0-ST-flakes` | W0-ST (part 1) | WP-09-w0-stabilization | done | external:wave0-local-lane |
| `319510c` | 2026-10-17 00:55 | `wp/W0-C2-tooling-gates` | W0-C2 | WP-02-tooling-gates | done | external:wave0-local-lane |
| `b47fc46` | 2026-10-17 01:22 | `wp/W0-B2-harness-hardening` | W0-B2 | WP-02-harness-hardening | done | external:wave0-local-lane |
| `9538cf4` | 2026-10-17 03:08 | `wp/W0-A4-spike-foldins` | W0-A4 | WP-04-spike-foldins-isolation | done | external:wave0-local-lane |
| `f47b957` | 2026-10-17 | `wp/W0-ST-stabilize` | W0-ST (part 2) | WP-09-w0-stabilization | done (status set before its merge; the wave-0 tag follows the merge) | integrator |
| `e5982b3` | 2026-10-17 | `wp/W1-IF-kickoff` | W1-IF | WP-10-w1-interface | done | integrator |
| `98836b4` | 2026-10-17 | `wp/W1-IF-grants` | W1-IF (grants) | WP-10-w1-interface | done | integrator |
| `f0ab9e2` | 2026-10-17 | `wp/cf-w1-6b` | W1-6b | WP-11-webview2-bindings | done | external:cfleet-wave1 |
| `8cd1691` | 2026-10-17 | `wp/cf-w1-2c` | W1-2c | WP-11-cli-offline-conformance | done | external:cfleet-wave1 |

Direct commits on master between merges (no branch): `c7598b0` (test-fast runs the gfx logic tests,
`[W0-K]`) and `12abd0c`, `59ba772` (smoke-suite fixes, `[W0-A1]`).

### Pre-builds ahead of the plan

These branches have no work package of their own (do not add WPs for them). Each pre-builds features
of the plan WPs listed; those WPs build on the merged code (they cut down to the remaining delta and
must not register the same commands again).

| Branch | Merges | What it built | Pre-builds features of |
|---|---|---|---|
| `wp/cf-remote` | `d08f63b` | `wmux_proto/remote/**` wire types and framing, `src/remote/daemon/**` (`wmuxd-remote serve --stdio [--persistent]`, real PTYs, persistent sessions with a replay ring, `fs.put/get`) | W6-2 (WP-61-remote-daemon); its persistent sessions also serve W6-3c (WP-64-remote-persistent-pty) |
| `wp/cf-hookresearch` | `cafd119` | agent hook research (`research/parity/agents/`: 20 agents) and fixes to the PB-agents payload parsers (`src/wmux_cli/hooks/payload.zig`, `normalize.zig`) | W3-1a (WP-31-agents-platform), W3-3a (WP-32-hook-installers-core), W3-3b (WP-33-hook-installers-extended) |
| `wp/cf-cli-ws` | `ade373a`, `191938e` | CLI families `window`, `workspace`, `workspace_group` | W2-1a (WP-22-windows-multi), W2-1b (WP-21-workspaces-core), W2-1c (WP-23-workspace-env-placement), W4-5b (WP-42-groups-core), W4-5c (WP-42-workspace-context-menus: `workspace-action`), W5a-1b (WP-52-workspace-status-lanes: `workspace status`), W6-1b (WP-62-remote-reconnect: `workspace reconnect\|disconnect`); text conformance W1-2c/W1-2d (ruling D7) |
| `wp/cf-cli-ps` | `a837f2f` | CLI families `pane_surface`, `terminal_io` (with `wait-for`) and system extras (`tree`, `top`, `memory`, `shot`/`screenshot` in `commands/inspect.zig`) | W2-2b (WP-22-pane-surface-cli), W2-2d (WP-23-panes-advanced), W4-5e (WP-43-tab-bar-menus: `tab-action`), W5a-5b (WP-52-dock-ii: dock placement flags), W2-3a (WP-21-terminal-io-core), W2-3b (WP-22-terminal-io-selection), W2-2c (WP-23-system-tree-identify), W5a-6a (WP-51-top-memory), W5b-7b (WP-57-capture-record: `shot`), W3-6a (WP-31-tmux-engine: `wait-for`) |
| `wp/cf-cli-notify` | `a588ad2`, `8cb1f1e` | CLI families `notify` (with `feed`), `sidebar_meta`, `events` | W2-5b (WP-22-notify-cli), W2-5c (WP-23-notifications-navigation), W2-5d (WP-24-notifications-attention: `trigger-flash`), W3-4b (WP-33-agent-turn-notifications: `jump-to-last-prompt`), W2-6a (WP-21-sidebar-status-log), W2-6c (WP-24-sidebar-pr-ports: `pr`), W2-4 (WP-22-events-stream), W5a-2a (WP-51-feed-core: `feed clear`), W5a-2c (WP-53-feed-cards-banners: `feed tui` as a `feed` subcommand, ruling D12) |
| `wp/cf-cli-browser` | `5faa1f3`, `bea93a9` | CLI family `browser` (all subcommands, `disable-browser`, `enable-browser`, `browser-status`) | W2-8b (WP-22-browser-automation-core), W2-8c (WP-23-browser-automation-actions), W2-8d (WP-24-browser-tabs-dialogs), W2-8e (WP-24-browser-cli-complete), W2-8f (WP-24-browser-omnibar-toolbar), W2-8g (WP-23-browser-link-routing), W5a-7a (WP-51-browser-state-network), W5a-7b (WP-52-browser-profiles-history), W5a-7c (WP-53-browser-import-menus), W5b-11a (WP-56-repl-core), W5b-12 (WP-58-browser-design-tools), W7-15 (WP-72-repl-tools) |
| `wp/cf-cli-misc` | `dd3fc4c` | CLI families `config`, `session` (with `surface-resume`), `layout_todo`, `open_files`, `right_sidebar` | W1-4b (WP-12-config-cli), W4-4a (WP-41-settings-window: `settings`, `shortcuts`), W4-4d (WP-43-appearance-themes: `themes`), W1-7b (WP-12-session-scrollback: `restore-session`), W4-7a (WP-41-history-transfer: session import/export), W3-5a (WP-33-agent-resume: the `surface.resume.*` methods; the command stays in `session.zig`, ruling D12), W4-7b (WP-41-saved-layouts: `layout`), W5a-1a (WP-51-todo-checklist: `todo`), W4-1a (WP-41-markdown-viewer: `markdown open`), W4-2a (WP-41-file-preview-open: `open`, `cmux <path>`), W4-3b (WP-42-diff-sources-cli: `diff`), W4-3d (WP-43-diff-review-comments: `comments list`), W1-8d (WP-13-right-sidebar-host: `right-sidebar`) |

## (b) Live branches (round 4 and parallel lanes)

None. The round-4 pre-builds (`wp/cf-rpc` W1-1a-t, `wp/cf-platform` PB-platform, `wp/cf-webharness`
PB-web-harness) and the local lane (`wp/W0-R-reconcile`, `wp/W0-ST-flakes`, `wp/W0-C2-tooling-gates`,
`wp/W0-B2-harness-hardening`, `wp/W0-A4-spike-foldins`) merged between 2026-10-16 23:02 and
2026-10-17 03:08 (table (a)); the local lane ran as workflow `wf_ede9528f-d43` (executor
`external:wave0-local-lane`). W0-ST part 2 merged as `f47b957` (tag `wave-0`); W1-IF merged as `e5982b3`, the base every W1 WP branches from.

Stopped workflows: `wave0-proto-and-prebuilds` and `wave0-prebuilds-2` were stopped on 2026-10-15
and left no branch in this repository. Their items kept their ids: W1-2a, PB-palette, PB-sidebar,
PB-feed, PB-todo-status, PB-vault, PB-automation, PB-layouts-actions and the five PB-web apps were
built by cfleet rounds 2 and 3 (done); W1-1a-t, PB-platform and PB-web-harness by round 4 (done).

## (c) Old plan ids → new plan ids

Every `derived_from` value of the plan (138 old ids, `WP-00-*` .. `WP-19-*`, also cited by the PB task
texts) with the new plan ids that took over its scope (arch ids in parentheses). The integrator items
`W<N>-IF` and `W<N>-ST` of waves 1-7 derive from no old id.

| Old plan id | New plan ids |
|---|---|
| WP-00-modularize-app | WP-00-app-extraction (W0-A1), WP-04-spike-foldins-isolation (W0-A4) |
| WP-01-model-window-split | WP-02-window-model (W0-A2) |
| WP-02-cli-frontend-core | WP-02-cli-core (W1-2a), WP-11-cli-relay-staging (W1-2b), WP-11-cli-offline-conformance (W1-2c), WP-23-workspace-env-placement (W2-1c) |
| WP-02-core-prewiring | WP-03-registries-prewiring (W0-A3) |
| WP-02-dev-tooling | WP-00-dev-tooling (W0-C), WP-01-reconcile-streams (W0-R), WP-02-tooling-gates (W0-C2), WP-09-w0-stabilization (W0-ST) |
| WP-02-e2e-harness | WP-00-e2e-harness (W0-B), WP-02-harness-hardening (W0-B2) |
| WP-02-feature-skeleton | WP-00-skeleton (W0-K), WP-01-proto-core (W0-P1), WP-03-registries-prewiring (W0-A3), WP-04-spike-foldins-isolation (W0-A4) |
| WP-02-platform-spikes | WP-00-platform-spikes (W0-D) |
| WP-03-env-identity-jobs | WP-02-pb-platform (PB-platform), WP-11-env-identity-jobs (W1-3), WP-23-system-tree-identify (W2-2c) |
| WP-03-notification-store | WP-01-pb-notif (PB-notif), WP-21-notifications-store-api (W2-5a) |
| WP-03-rpc-server | WP-02-rpc-transport (W1-1a-t), WP-11-rpc-dispatch (W1-1a), WP-12-cli-online-conformance (W1-2d), WP-34-legacy-pipe-retirement (W3-1c) |
| WP-03-session-v3 | WP-01-pb-session (PB-session), WP-11-session-core (W1-7a), WP-12-session-scrollback (W1-7b) |
| WP-03-settings-store | WP-01-proto-settings (W0-P2), WP-11-settings-layer (W1-4a), WP-12-config-cli (W1-4b) |
| WP-04-keys-router | WP-01-proto-actions-keys (W0-P3), WP-12-key-router (W1-5a) |
| WP-04-panes-surfaces-core | WP-21-panes-surfaces-core (W2-2a), WP-22-pane-surface-cli (W2-2b), WP-23-system-tree-identify (W2-2c) |
| WP-04-rpc-auth-caller | WP-13-rpc-auth-caller (W1-1b) |
| WP-04-sidebar-d2d | WP-00-d2d-bindings (W1-8a), WP-02-pb-sidebar (PB-sidebar), WP-12-sidebar-d2d (W1-8b), WP-13-sidebar-focus-dpi (W1-8c) |
| WP-04-terminal-io | WP-21-terminal-io-core (W2-3a), WP-22-terminal-io-selection (W2-3b) |
| WP-04-web-panels | WP-00-web-assets (W1-6a), WP-02-pb-web-harness (PB-web-harness), WP-11-webview2-bindings (W1-6b), WP-12-web-host-bridge (W1-6c) |
| WP-04-windows-core | WP-22-windows-multi (W2-1a) |
| WP-04-workspaces-core | WP-21-workspaces-core (W2-1b), WP-23-workspace-env-placement (W2-1c), WP-41-workspace-style (W4-5a) |
| WP-05-agent-hooks-core | WP-01-pb-agents (PB-agents), WP-31-agents-platform (W3-1a) |
| WP-05-browser-surface | WP-21-browser-surface (W2-8a) |
| WP-05-events-stream | WP-01-proto-events (W0-P4), WP-22-events-stream (W2-4) |
| WP-05-keys-customization | WP-13-shortcut-customization (W1-5b) |
| WP-05-notifications-api-cli | WP-21-notifications-store-api (W2-5a), WP-22-notify-cli (W2-5b) |
| WP-05-right-sidebar-host | WP-13-right-sidebar-host (W1-8d) |
| WP-05-sidebar-status-log | WP-21-sidebar-status-log (W2-6a) |
| WP-05-system-tree-identify | WP-12-cli-online-conformance (W1-2d), WP-23-system-tree-identify (W2-2c) |
| WP-06-agent-status-rows | WP-32-agent-status-rows (W3-4a) |
| WP-06-agent-wrappers | WP-32-agent-wrappers (W3-2) |
| WP-06-browser-automation-core | WP-22-browser-automation-core (W2-8b), WP-24-browser-cli-complete (W2-8e) |
| WP-06-command-palette | WP-02-pb-palette (PB-palette), WP-21-command-palette (W2-7a) |
| WP-06-config-cli | WP-11-settings-layer (W1-4a), WP-12-config-cli (W1-4b) |
| WP-06-find-focus-history | WP-23-find-focus-history (W2-7b) |
| WP-06-notifications-attention | WP-24-notifications-attention (W2-5d) |
| WP-06-notifications-navigation | WP-01-pb-notif (PB-notif), WP-23-notifications-navigation (W2-5c) |
| WP-07-agent-resume | WP-33-agent-resume (W3-5a), WP-34-agent-restore-fork (W3-5b) |
| WP-07-agent-turn-notifications | WP-33-agent-turn-notifications (W3-4b) |
| WP-07-browser-automation-actions | WP-01-pb-browser (PB-browser), WP-23-browser-automation-actions (W2-8c), WP-24-browser-cli-complete (W2-8e) |
| WP-07-browser-link-routing | WP-23-browser-link-routing (W2-8g) |
| WP-07-browser-omnibar-toolbar | WP-24-browser-omnibar-toolbar (W2-8f) |
| WP-07-notifications-osc-delivery | WP-24-notifications-osc-delivery (W2-5e) |
| WP-07-panes-advanced | WP-21-panes-surfaces-core (W2-2a), WP-23-panes-advanced (W2-2d) |
| WP-07-sidebar-git-pr-ports | WP-01-pb-meta (PB-meta), WP-23-shell-reports-git (W2-6b), WP-24-sidebar-pr-ports (W2-6c) |
| WP-08-agent-session-ux | WP-32-draft-guard-agent-events (W3-1b) |
| WP-08-browser-automation-tabs-dialogs | WP-24-browser-tabs-dialogs (W2-8d), WP-24-browser-cli-complete (W2-8e) |
| WP-08-cli-app-integration | WP-02-cli-core (W1-2a), WP-11-cli-relay-staging (W1-2b), WP-12-cli-online-conformance (W1-2d), WP-23-shell-reports-git (W2-6b) |
| WP-08-hook-installers-core | WP-32-hook-installers-core (W3-3a) |
| WP-08-markdown-viewer | WP-04-pb-web-markdown (PB-web-markdown), WP-41-markdown-viewer (W4-1a) |
| WP-08-tmux-compat | WP-01-pb-tmux (PB-tmux), WP-31-tmux-engine (W3-6a), WP-32-tmux-command-set (W3-6b) |
| WP-08-toasts-delivery | WP-31-toasts-protocol (W3-7a) |
| WP-08-workspace-style | WP-41-workspace-style (W4-5a) |
| WP-09-agent-restore-fork | WP-32-agent-crash-recovery (W3-5c), WP-34-agent-restore-fork (W3-5b) |
| WP-09-agent-teams | WP-33-agent-teams (W3-6c), WP-34-codex-teams (W3-6d) |
| WP-09-dnd-tabs-workspaces | WP-41-dnd-tabs-workspaces (W4-6a) |
| WP-09-file-preview | WP-41-file-preview-open (W4-2a) |
| WP-09-groups-core | WP-42-groups-core (W4-5b) |
| WP-09-history-session-ii | WP-12-session-scrollback (W1-7b), WP-41-history-transfer (W4-7a) |
| WP-09-notifications-policy-mute | WP-31-notification-policy-hooks (W3-8a), WP-33-notifications-mute-persistence (W3-8b) |
| WP-09-workspace-context-menus | WP-42-workspace-context-menus (W4-5c) |
| WP-10-diff-viewer | WP-04-pb-web-diff (PB-web-diff), WP-41-diff-viewer-core (W4-3a), WP-42-diff-sources-cli (W4-3b) |
| WP-10-file-editor | WP-42-file-editor (W4-2b) |
| WP-10-groups-ui | WP-43-groups-ui (W4-5d) |
| WP-10-hook-installers-extended | WP-33-hook-installers-extended (W3-3b) |
| WP-10-layouts | WP-03-pb-layouts-actions (PB-layouts-actions), WP-41-saved-layouts (W4-7b) |
| WP-10-notifications-popover | WP-04-pb-web-notif-feed (PB-web-notif-feed), WP-31-notifications-popover (W3-8c) |
| WP-10-settings-window | WP-04-pb-web-settings (PB-web-settings), WP-41-settings-window (W4-4a) |
| WP-10-tab-bar-menus | WP-43-tab-bar-menus (W4-5e) |
| WP-11-appearance-themes | WP-43-appearance-themes (W4-4d) |
| WP-11-browser-lifecycle | WP-11-webview2-bindings (W1-6b), WP-21-browser-surface (W2-8a), WP-52-browser-lifecycle (W5a-7d) |
| WP-11-custom-actions | WP-03-pb-layouts-actions (PB-layouts-actions), WP-41-saved-layouts (W4-7b), WP-42-custom-actions (W4-7c) |
| WP-11-dnd-merge-file-drops | WP-43-dnd-merge-file-drops (W4-6b) |
| WP-11-feed-core | WP-03-pb-feed (PB-feed), WP-51-feed-core (W5a-2a) |
| WP-11-files-explorer | WP-42-files-find-in-dir (W4-8) |
| WP-11-sounds-command-tray | WP-32-sounds-command-tray (W3-7b) |
| WP-11-textbox-image-paste | WP-56-textbox (W5b-5a), WP-57-image-paste-comments-delivery (W5b-5b) |
| WP-12-agent-messages | WP-56-agent-messages (W5b-1a) |
| WP-12-copy-mode-terminal-input | WP-56-copy-mode-input (W5b-4) |
| WP-12-dock-core | WP-51-dock-core (W5a-5a) |
| WP-12-feed-panel | WP-03-pb-feed (PB-feed), WP-04-pb-web-notif-feed (PB-web-notif-feed), WP-52-feed-panel (W5a-2b), WP-53-feed-cards-banners (W5a-2c) |
| WP-12-settings-shortcuts-themes | WP-04-pb-web-settings (PB-web-settings), WP-42-settings-shortcuts-terminal (W4-4b), WP-43-appearance-themes (W4-4d) |
| WP-12-task-manager | WP-04-pb-web-taskmgr-todo (PB-web-taskmgr-todo), WP-51-top-memory (W5a-6a), WP-52-task-manager-window (W5a-6b) |
| WP-12-todo-checklist | WP-03-pb-todo-status (PB-todo-status), WP-04-pb-web-taskmgr-todo (PB-web-taskmgr-todo), WP-51-todo-checklist (W5a-1a) |
| WP-12-vault-sessions | WP-03-pb-vault (PB-vault), WP-51-vault-index (W5a-3a), WP-52-vault-search (W5a-3b) |
| WP-13-browser-profiles-history | WP-52-browser-profiles-history (W5a-7b) |
| WP-13-browser-state-network | WP-51-browser-state-network (W5a-7a) |
| WP-13-diff-viewer-ii | WP-04-pb-web-diff (PB-web-diff), WP-42-diff-sources-cli (W4-3b), WP-43-diff-viewer-ii (W4-3c) |
| WP-13-dock-scopes-cli | WP-52-dock-ii (W5a-5b) |
| WP-13-markdown-viewer-ii | WP-04-pb-web-markdown (PB-web-markdown), WP-42-markdown-viewer-ii (W4-1b) |
| WP-13-remote-daemon | WP-61-remote-daemon (W6-2) |
| WP-13-ssh-workspaces | WP-61-ssh-workspaces (W6-1a) |
| WP-13-workspace-status-lanes | WP-03-pb-todo-status (PB-todo-status), WP-52-workspace-status-lanes (W5a-1b) |
| WP-14-browser-repl-core | WP-56-repl-core (W5b-11a), WP-57-repl-sessions (W5b-11b), WP-58-repl-snapshot (W5b-11c) |
| WP-14-diff-comments | WP-04-pb-web-diff (PB-web-diff), WP-43-diff-review-comments (W4-3d), WP-57-image-paste-comments-delivery (W5b-5b) |
| WP-14-feed-banners-inbox | WP-04-pb-web-notif-feed (PB-web-notif-feed), WP-53-feed-cards-banners (W5a-2c), WP-57-agent-inbox-overlay (W5b-1b) |
| WP-14-global-search | WP-57-global-search (W5b-6b) |
| WP-14-remote-bootstrap-carrier | WP-62-remote-bootstrap (W6-3a), WP-63-remote-carrier (W6-3b) |
| WP-14-remote-reconnect | WP-62-remote-reconnect (W6-1b) |
| WP-14-ssh-tmux-mirror | WP-62-ssh-tmux-mapping (W6-6a), WP-63-ssh-tmux-mirror (W6-6b) |
| WP-14-vault-checkpoints | WP-03-pb-vault (PB-vault), WP-53-vault-checkpoints (W5a-3c) |
| WP-15-auto-naming | WP-56-auto-naming (W5b-2) |
| WP-15-automation-rules | WP-03-pb-automation (PB-automation), WP-51-automation-rules (W5a-8) |
| WP-15-browser-import-menus | WP-53-browser-import-menus (W5a-7c) |
| WP-15-browser-repl-page-api | WP-57-repl-sessions (W5b-11b), WP-58-repl-page-api (W5b-11d), WP-71-repl-policy (W7-14) |
| WP-15-custom-sidebars-runtime | WP-51-custom-sidebars-runtime (W5a-4a), WP-52-custom-sidebars-dialects (W5a-4b) |
| WP-15-remote-browser-egress | WP-11-webview2-bindings (W1-6b), WP-64-remote-browser-egress (W6-5a), WP-65-remote-registry-policy (W6-5b) |
| WP-15-remote-persistent-pty | WP-64-remote-persistent-pty (W6-3c), WP-65-remote-session-cli (W6-3d) |
| WP-15-ssh-tmux-sync | WP-64-ssh-tmux-sync (W6-6c) |
| WP-16-browser-design-tools | WP-58-browser-design-tools (W5b-12) |
| WP-16-browser-repl-tools | WP-22-terminal-io-selection (W2-3b), WP-58-repl-snapshot (W5b-11c), WP-72-repl-tools (W7-15) |
| WP-16-browser-security-prompts | WP-11-webview2-bindings (W1-6b), WP-53-browser-security-prompts (W5a-7e) |
| WP-16-custom-sidebars-tooling | WP-52-custom-sidebars-dialects (W5a-4b), WP-53-custom-sidebar-hosting (W5a-4c) |
| WP-16-hibernation-resources | WP-56-hibernation (W5b-3a), WP-57-terminal-resources (W5b-3b), WP-58-render-throttling (W5b-3c) |
| WP-16-remote-file-transfer | WP-63-predictive-echo (W6-8), WP-64-remote-files (W6-7a) |
| WP-16-remote-relay-agents | WP-64-remote-relay (W6-4a), WP-65-remote-agents (W6-4b) |
| WP-16-ssh-tmux-extended | WP-65-ssh-tmux-extended (W6-6d) |
| WP-17-agent-usage-detection | WP-57-agent-usage-detection (W5b-9) |
| WP-17-capture-record | WP-57-capture-record (W5b-7b) |
| WP-17-deeplinks-shell-entry | WP-33-deeplinks-shell-entry (W3-7c), WP-62-ssh-links-mosh (W6-7b) |
| WP-17-protocol-completeness | WP-58-protocol-completeness (W5b-8a), WP-58-read-plane-tabbars (W5b-8b) |
| WP-17-remote-misc | WP-62-ssh-links-mosh (W6-7b), WP-65-remote-registry-policy (W6-5b), WP-65-ssh-tmux-extended (W6-6d), WP-65-session-move (W6-7c) |
| WP-17-right-sidebar-tool-panes | WP-57-file-drag-vault-xref (W5b-10b), WP-58-right-sidebar-tool-panes (W5b-10a) |
| WP-17-updater | WP-56-updater (W5b-7a) |
| WP-18-agent-chat | WP-71-agent-chat-core (W7-9a), WP-72-agent-chat-panel (W7-9b) |
| WP-18-canvas-layout | WP-71-canvas-mode (W7-3a), WP-72-canvas-manipulation (W7-3b), WP-72-canvas-layout-conformance (W7-3c) |
| WP-18-chrome-titlebar-menu | WP-71-titlebar-app-settings (W7-10a), WP-73-main-menu (W7-10b) |
| WP-18-diagnostics-sudo | WP-71-diagnostics-sudo (W7-7) |
| WP-18-keep-awake-sleepy | WP-56-keep-awake-hints (W5b-6a), WP-71-sleepy-mode (W7-4) |
| WP-18-local-tmux | WP-72-local-tmux (W7-8a), WP-73-local-zellij (W7-8b) |
| WP-18-policy-distribution | WP-71-policy-admx (W7-5), WP-72-install-cli-distribution (W7-6) |
| WP-19-accessibility | WP-72-accessibility (W7-2) |
| WP-19-canvas-navigation | WP-73-canvas-navigation (W7-3d) |
| WP-19-computer-use | WP-73-computer-use (W7-13) |
| WP-19-localization | WP-71-localization (W7-1) |
| WP-19-sidebar-provider-views | WP-73-sidebar-provider-views (W7-12) |
| WP-19-updater-relaunch | WP-73-updater-relaunch (W7-11) |
| WP-19-window-hints | WP-56-keep-awake-hints (W5b-6a) |
