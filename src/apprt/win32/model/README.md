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
- `logic/`: pure helpers (`arith.zig`, `titles.zig`) and `fake.zig`,
  which builds window/workspace/pane/tab graphs without HWNDs for the
  `unit: model:` tests.

Dependency rule (ADR-1.2): may import `platform/`, `features/ext.zig` and
`wmux_proto`; never `rpc/` or feature internals. ADR-2.3 fields are the
exception: `Workspace.window` points at `ui/Window.zig` and `TabContent`
at the terminal `Surface.zig` and `web/BrowserPane.zig`.
