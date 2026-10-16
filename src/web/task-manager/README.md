# `src/web/task-manager`: Task Manager window

PanelKind `task_manager` (ARCHITECTURE ADR-6.11; placement: top-level
`PanelHostWindow`, `singleton: app`), asset directory `task-manager`, entry
`https://task-manager.wmux.example/task-manager/index.html`. Shows resource
usage for wmux windows, workspaces, panes, surfaces, terminal processes, coding
agents and browser webviews. Opened from the Window menu (`Task Manager...`),
the command palette (`Task Manager`, `palette.openTaskManager`) and the tray
menu. Those entry points are native.

Covers: `sidebar-task-manager-window` (page side). Data shapes follow
`sidebar-top-cli` (`system.top`) and `sidebar-memory-cli` (`system.memory`).

| File | Purpose |
|---|---|
| `index.html` | page shell: header, summary cards, state block, the four sections, row menu, kill confirmation |
| `task-manager.js` | entry module: theme sync and app start |
| `app.js` | the application: refresh loop, rendering, sorting, selection, jump, kill |
| `model.js` | pure: reply normalization, agents / program totals / memory groups, sorting, tree flattening, formatting |
| `strings.js` | user-visible strings (`tr()` keys) |
| `task-manager.css` | layout on the `--wmux-*` tokens |

No vendored libraries; all text goes through `textContent`, so the CSP also
enforces Trusted Types.

## Layout

- **Header**: title, a `Refreshing…` indicator while a request is in flight,
  the `Processes` toggle (adds per-process rows to Hierarchy), `Refresh`.
- **Summary cards**: CPU (`totals.cpu_percent`; may exceed 100% across cores),
  Memory (`totals.memory_bytes`), App Footprint and Child RSS (`system.memory`),
  Processes (`totals.process_count`), Updated (local `HH:MM:SS` of the last
  successful refresh). Unknown values show `—`.
- **Coding Agents**: the outermost process of each known agent (Claude Code,
  Codex, OpenCode, Gemini CLI by executable name, or any process native marks
  with `agent`). CPU, memory and process count cover the agent and its
  descendants (unique PIDs). Detail: owning workspace and PID.
- **Program Totals**: unique PIDs grouped by executable name
  (case-insensitive, `.exe` stripped).
- **Child Process RSS**: the `system.memory` command groups with their
  workspace labels (no CPU column).
- **Hierarchy**: window > workspace > tag / pane > surface > process / browser
  webview, as a `treegrid` with a disclosure per row. Detail text uses cmux's
  flags: `hidden`, `selected`, `pinned`, `focused`, `pid-only`, surface type,
  tty, `PID n`, agent, attribution.
- **Columns**: Name, CPU (`%.1f%`), Memory (1024-based, `12.5 MB`, `345 MB`,
  `1.2 GB`), Proc.

## Behavior

- **Refresh**: on start, then every 3 s while the page is visible
  (`document.visibilityState`; WebView2 reports hidden when the window is
  hidden or minimized). Polling stops while hidden and resumes with an immediate
  refresh when shown. `Refresh` and the `panel.task_manager.refresh` event force
  an update. Concurrent refreshes share one request. The next tick is scheduled
  only after the previous one finished, so slow replies never pile up.
- **States**: `Loading resource usage` until the first reply; `No resource
  usage` + `Open a workspace, terminal, or browser surface to see it here.` when
  there is no workspace; `Unable to load resource usage` (with the error
  message, or "This wmux build does not support process diagnostics." for
  `method_not_found` / `not_supported`) when the first load fails. Later
  failures keep the last data and show `Unable to refresh Task Manager data.`,
  except `rate_limited`, which is silent and retried on the next tick.
  `Unable to kill process: <err>` reports kill failures.
- **Sorting**: clicking a column header sorts by it (names ascend first,
  numbers descend first; clicking again flips). Hierarchy sorts siblings at
  every level, like `cmux top --sort`. The other sections use the same key;
  until one is chosen they show the heaviest first (CPU, or memory for Child
  RSS) and Hierarchy keeps native order.
- **Jump to owner** (double-click or Enter): window -> `window.focus`,
  workspace -> `workspace.select`, pane -> `pane.focus`; surface, process,
  webview, tag and agent rows -> `surface.focus` on the owning surface (else
  `workspace.select`). Program and memory group rows have no owner.
- **Row menu** (right-click, Shift+F10, menu key): `View Workspace`, `View
  Terminal`, `Kill Process...`; items without a target are disabled.
- **Kill**: `Kill Process...` or Delete opens `Kill process?` with `Ask <name>
  (PID <n>) to terminate gracefully. wmux will force-kill it if it is still
  running after a short grace period.` For several PIDs: `Ask N processes (PIDs
  a, b) to terminate gracefully. wmux will force-kill them …`. Buttons: Kill and
  Cancel; Cancel has focus and Escape cancels. Targets: a process row -> its
  PID; a tag -> its PID; a surface / pane / workspace -> the top-level processes
  under it; an agent -> its outermost PID; a program -> all its PIDs. Windows and
  webviews are never killed from here. After the call the page refreshes.
- **Keyboard**: Up/Down/Home/End move within a section, Left/Right collapse,
  expand or go to the parent / first child, Enter jumps, Delete kills.
  Focus stays on the same row across refreshes.

## Native contract

The allowlist needs `system.top`, `system.memory`, `window.focus`,
`workspace.select`, `pane.focus` and `surface.focus` (cmux names,
Appendix B.1). The focus methods must also bring the owning main window to the
front, because the Task Manager is a separate top-level window.

| Method | Params (page -> native) | Notes |
|---|---|---|
| `system.top` | `{all_windows: true, include_processes: true}` | always with processes, so Coding Agents and Program Totals work while the toggle only hides rows. Reply: `{windows: [...], totals: {cpu_percent, memory_bytes, process_count}}` (below) |
| `system.memory` | `{all_windows: true}` | optional; failures only blank App Footprint / Child RSS. Reply below |
| `window.focus` | `{window_id}` | |
| `workspace.select` | `{workspace_id, window_id?}` | |
| `pane.focus` | `{pane_id, workspace_id?, window_id?}` | |
| `surface.focus` | `{surface_id, workspace_id?, window_id?}` | |
| `panel.task_manager.kill` | `{pids: [n, ...]}` -> `{killed?: [n], failed?: [{pid, message}]}` | wmux-only (cmux names none): graceful terminate (WM_CLOSE / CTRL_BREAK, then TerminateProcess / TerminateJobObject after the grace period). **Native must only kill PIDs that its latest sample attributes to a wmux surface, tag or agent**: the page is not trusted with arbitrary PIDs |

Events: `panel.task_manager.refresh` (any payload) forces a refresh, e.g. when
the palette command re-focuses an open window. `theme` is handled by
`_shared/`.

### `system.top` reply shape (accepted fields)

Every node may carry `cpu_percent`, `memory_bytes`, `process_count`.
Children arrays and the node kind they hold: `workspaces` (workspace),
`tags` (tag), `panes` (pane), `surfaces` (surface), `webviews` (webview),
`processes` (process), `children` (process children). A node may also set
`kind` explicitly.

| Kind | Fields used |
|---|---|
| window | `id` or `window_id`, `ref`, `title`, `hidden` |
| workspace | `id` or `workspace_id`, `ref`, `title`, `selected`, `pinned` |
| tag | `key`, `value`, `pid`, `pid_only` |
| pane | `id` or `pane_id`, `ref`, `focused` |
| surface | `id` or `surface_id`, `ref`, `type` or `surface_type` (`terminal` / `browser`), `title`, `selected`, `tty` |
| webview | `pid` (WebView2 browser / renderer process), `title` |
| process | `pid`, `name` (or `command`), `attribution`, `agent` (agent id such as `claude`, or a display name) |

Process `cpu_percent` / `memory_bytes` are the process's **own** values (the
page sums subtrees for agents). Missing `process_count` on a process means 1
plus its descendants. Missing `totals` are summed from the windows. Invalid
numbers read as 0, and PIDs must be positive integers.

### `system.memory` reply shape (accepted fields)

`{app: {memory_bytes}, child: {memory_bytes, process_count}, groups:
[{command, memory_bytes, process_count, workspaces: ["label" | {title}]}]}`.
Aliases: `app_memory_bytes` / `app_footprint_bytes`, `child_rss_bytes` /
`children.memory_bytes` (else the sum of the groups), group `name`,
`rss_bytes`, `count`, `labels`.

### Session state (`panel.state_changed`)

`{v: 1, show_processes, sort: {key: "name" | "cpu" | "mem" | "proc" | null,
dir: "asc" | "desc"}, collapsed: [row key, ...] (newest 200)}`; restored from
`panel.init.state`. `panel.init.params.processes` (bool) overrides the toggle.

## CSP

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; require-trusted-types-for 'script'; trusted-types 'none'
```

## Tests

`test/web-node/task-manager/` (node:test + jsdom; the page harness and mock
host come from `test/web-node/todo/harness.mjs`, the `system.top` fixture
from `fixture.mjs`):

```sh
npm install --prefix /tmp/wmux-web-test-deps --ignore-scripts jsdom@26
WMUX_WEB_TEST_DEPS=/tmp/wmux-web-test-deps node --test 'test/web-node/task-manager/*.test.mjs'
```
