# ui/ (layer)

Top-level window chrome (ARCHITECTURE.md ADR-1.1, ADR-1.8). Populated by
W0-A2; W0-A3 added the contribution registry and the window hook
dispatch.

- `Window.zig`: the top-level HWND, the window's model part (workspace
  list, selected workspace), chrome state, init/teardown and the
  WndProc dispatch. The functions W0-A2 moved out are re-exported as W0
  aliases; new code calls the owning module directly.
- `chrome.zig`: chrome geometry, pane layout and dividers (through
  `model/layout.zig`), invalidation, paint dispatch, theme, fullscreen.
- `tabbar/`: tab bar painting and input over one shared geometry
  (`tabbar/logic/geometry.zig`), and the tab menu items (`menu.zig`).
- `sidebar/`, `right_sidebar/`: the legacy GDI sidebar and right strip,
  the workspace row menu items, and the `attach`/`detach` facades
  (`mod.zig`) that W1-8 fills.
- `menus.zig`: `MenuBuilder` (ADR-1.6). Menus are built per `MenuSite`
  from `MenuItem`s contributed by their owners (tab bar, sidebar,
  `settings/menu.zig`, `backend_picker.zig`, the terminal `Surface.zig`,
  and features through `contrib.zig`); command id = 1 + row index;
  targets are captured by UUID before the modal loop and re-resolved
  through the handle registry after it.
- `contrib.zig` (frozen): the UI registry (ADR-1.4). It aggregates what
  features declare in mod.zig: menu items, palette providers
  (`palette/provider.zig`), sidebar row contributors
  (`sidebar/contrib.zig`), right-sidebar modes (`right_sidebar/mode.zig`),
  web panel kinds (`web/PanelKind.zig`), window hooks (dispatched by
  `Window.zig`) and app hooks (dispatched by App.msgWndProc and the
  broadcast window).
- `backend_picker.zig`: the "+ ▾" / "Split ... With..." backend picker.
- `overlays/`: attention rings, pane buttons, flash overlay, scrollbar.
- `rename.zig`, `placement.zig`, `placement_state.zig`: inline rename and
  window placement.

Dependency rule (ADR-1.2): features use the public types of this layer;
the layer never imports feature internals except through registries.
