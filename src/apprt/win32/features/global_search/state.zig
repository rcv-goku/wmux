//! Per-object state of feature `global_search` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.global_search`).
pub const App = struct {};

/// Per-window state (`Window.ext.global_search`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.global_search`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.global_search`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.global_search`).
pub const Tab = struct {};
