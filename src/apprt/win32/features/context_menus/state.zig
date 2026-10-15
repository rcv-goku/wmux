//! Per-object state of feature `context_menus` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.context_menus`).
pub const App = struct {};

/// Per-window state (`Window.ext.context_menus`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.context_menus`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.context_menus`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.context_menus`).
pub const Tab = struct {};
