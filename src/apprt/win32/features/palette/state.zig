//! Per-object state of feature `palette` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.palette`).
pub const App = struct {};

/// Per-window state (`Window.ext.palette`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.palette`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.palette`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.palette`).
pub const Tab = struct {};
