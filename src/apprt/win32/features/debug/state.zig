//! Per-object state of feature `debug` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.debug`).
pub const App = struct {};

/// Per-window state (`Window.ext.debug`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.debug`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.debug`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.debug`).
pub const Tab = struct {};
