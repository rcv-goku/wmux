//! Per-object state of feature `find` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.find`).
pub const App = struct {};

/// Per-window state (`Window.ext.find`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.find`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.find`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.find`).
pub const Tab = struct {};
