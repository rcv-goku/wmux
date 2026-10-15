//! Per-object state of feature `history` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.history`).
pub const App = struct {};

/// Per-window state (`Window.ext.history`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.history`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.history`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.history`).
pub const Tab = struct {};
