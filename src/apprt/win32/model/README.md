# model/ (layer, frozen after W0)

Window-independent object model (ARCHITECTURE.md ADR-1.1, ADR-1.8,
ADR-2, ADR-3.10). Populated by W0-A2; W0-A3 added identity, groups, the
event bus and moved the legacy per-tab state into feature ext state.

- `Workspace.zig`: a sidebar row. Heap object in its window's
  `workspaces` list (no cap); owns its split tree of panes, the focused
  and zoomed pane, its name (`Title`), description, cwd, env, its group
  and the legacy sidebar metadata. `locate`/`locateSurface` find a tab
  across a window's workspaces.
- `Group.zig`: a workspace group (W4-5 creates them) in the window's
  `groups` list; members point at it through `Workspace.group`.
- `Pane.zig`: a split-tree leaf with its own tab bar; owns
  `tabs: std.ArrayList(*Tab)` (no cap) and the selected index.
- `Tab.zig`: one tab (cmux "surface"): reference-counted, holds its
  `Title`, its `TabContent`, its cwd and `lifecycle_id`.
- `TabContent.zig`: terminal surface, WebView2 browser, web panel
  (W1-6) or `placeholder` (no live content: the fake graphs' tabs, later
  hibernated tabs).
- `Title.zig`: user rename (`custom`) over the automatic title (`auto`),
  heap UTF-8/WTF-8.
- `layout.zig`: `computeLayout` lays out a split tree once into a
  `LayoutResult` (node rects, leaf rects, dividers).
- `ids.zig`, `registry.zig`, `logic/handle_registry.zig`: identity
  (ADR-2). Every window, workspace, group, pane and tab has a `handle`
  (uppercase UUIDv4 + per-kind ref, `workspace:7`) minted in `App.handles`
  when it is created and retired when it is destroyed; refs are never
  reused, and the registry's reservation hook lets the session persist
  them crash-safely. `registry.zig` resolves UUIDs, refs, legacy core
  surface ids and contextual indexes (ADR-2.4). A terminal's identity is
  fixed before it spawns (`ids.SpawnIdentity`, carried by
  `Surface.spawn_identity`) because its tab and pane join the model only
  afterwards.
- `events.zig`: the event bus (ADR-3.10). `emit` runs every feature's
  `onEvent` after the mutation. Lifecycle events come only from
  `ops/*`, through `ops/lifecycle_events.zig`.
- `ops/*.zig`: the mutators. Core tab operations take explicit targets
  (`surface.insert`, the one way a tab enters a pane; `remove`,
  `moveInPane`, `selectInPane`, `closeTabAt`); the "focused pane" entry
  points only resolve their pane and delegate. `ops/window.zig` also owns
  the model part of creating and freeing a window; `ops/group.zig` the
  group operations.
- `logic/`: std-only helpers (`arith.zig`, `titles.zig`,
  `handle_registry.zig`, indexed by `tests.zig`, which test-fast runs)
  and `fake.zig`, which builds window/workspace/pane/tab graphs without
  HWNDs for the `unit: model:` tests (not std-only, so ui/Window.zig's
  test block collects it for the full suite).

Per-object feature state lives in `ext` (features/ext.zig): the legacy
per-tab status text, progress and log are `Tab.ext.status`, the
bell/exited dot and attention `Tab.ext.notifications`, synchronized
input `Tab.ext.sync_input`. Destroy paths call `features/ext.zig
deinitAll` for the states that declare `deinit`.

Dependency rule (ADR-1.2): may import `platform/`, `features/ext.zig` and
`wmux_proto`; not `ui/`, `rpc/`, `web/` or feature internals. The
exceptions at the end of W0:

- the ADR-2.3 fields: `Workspace.window` and `Group.window` point at
  `ui/Window.zig`, the split tree is `src/datastruct/split_tree.zig`, and
  `TabContent` holds the terminal `Surface.zig`, a `web/BrowserPane.zig`
  or a `web/WebPanel.zig`;
- `ops/*.zig` still take the `*Window` they act on and drive its chrome
  (layout, focus, invalidation, overlays) through `ui/Window.zig`;
  `ops/surface.zig` also shows the window through `app/foreground.zig`,
  and it and `ops/pane.zig` create browser tabs (`web/BrowserPane.zig`);
- `events.zig` reaches the features through `features/lifecycle.zig`
  (the sanctioned consumer list of ADR-1.4) and names
  `Event.automation_origin` with the automation feature's pure loop-guard
  type.

Pane index: `Workspace.paneAt` (the legacy IPC `pane` index and the v2
session file) counts panes in split-tree node order; handle resolution
(`registry.paneAtDepthFirst`, ADR-2.4) counts them depth-first, left
before right, like `layout.zig`'s leaves.
