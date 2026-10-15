//! Per-object state of feature `canvas` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.canvas`).
pub const App = struct {};

/// Per-window state (`Window.ext.canvas`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.canvas`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.canvas`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.canvas`).
pub const Tab = struct {};
