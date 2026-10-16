# model/ (layer)

Window-independent object model (ARCHITECTURE.md ADR-1.1, ADR-1.8,
ADR-2.3). Populated by W0-A2; W0-A3 adds handles, the registry, groups,
the event bus and moves the legacy per-tab state into feature ext state.

- `Workspace.zig`: a sidebar row. Heap object in its window's
  `workspaces` list (no cap); owns its split tree of panes, the focused
  and zoomed pane, its name (`Title`), description, cwd, env, and the
  legacy sidebar metadata. `locate`/`locateSurface` find a tab across a
  window's workspaces.
- `Pane.zig`: a split-tree leaf with its own tab bar; owns
  `tabs: std.ArrayList(*Tab)` (no cap) and the selected index.
- `Tab.zig`: one tab (cmux "surface"): reference-counted, holds its
  `Title`, its `TabContent`, its cwd and the legacy per-tab state.
- `TabContent.zig`: terminal surface, WebView2 browser, or `placeholder`
  (the HWND-less content of the fake graphs).
- `Title.zig`: user rename (`custom`) over the automatic title (`auto`),
  heap UTF-8/WTF-8.
- `layout.zig`: `computeLayout` lays out a split tree once into a
  `LayoutResult` (node rects, leaf rects, dividers); pane layout, divider
  paint/hit-test/drag, keyboard resize, attention rings and pane buttons
  all use it.
- `ops/*.zig`: the mutators. Core tab operations take explicit targets
  (`surface.insert`, the one way a tab enters a pane; `remove`,
  `moveInPane`, `selectInPane`, `closeTabAt`); the "focused pane"
  entry points only resolve their pane and delegate.
- `logic/`: std-only helpers (`arith.zig`, `titles.zig`, indexed by
  `tests.zig`, the test-fast entry of CCR W0-A2-1) and `fake.zig`, which
  builds window/workspace/pane/tab graphs without HWNDs for the
  `unit: model:` tests (not std-only, so ui/Window.zig's test block
  collects it for the full suite).

Dependency rule (ADR-1.2): may import `platform/`, `features/ext.zig` and
`wmux_proto`; not `ui/`, `rpc/`, `web/` or feature internals. The
exceptions at the end of W0-A2:

- the ADR-2.3 fields: `Workspace.window` points at `ui/Window.zig`, the
  split tree is `src/datastruct/split_tree.zig`, and `TabContent` holds
  the terminal `Surface.zig` or a `web/BrowserPane.zig`;
- `ops/*.zig` still take the `*Window` they act on and drive its chrome
  (layout, focus, invalidation, overlays) through `ui/Window.zig`;
  `ops/surface.zig` also shows the window through `app/foreground.zig`,
  and it and `ops/pane.zig` create browser tabs (`web/BrowserPane.zig`);
- `Tab.zig` keeps the legacy per-tab log ring of
  `features/status/log_ring.zig` until W0-A3 moves the legacy per-tab
  state into feature ext state.

Pane index: `Workspace.paneAt` (the legacy IPC `pane` index and the v2
session file) counts panes in split-tree node order, which is not the
depth-first order of `layout.zig`'s leaves (see `paneAt`).
