//! Per-object state of feature `remote` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.remote`).
pub const App = struct {};

/// Per-window state (`Window.ext.remote`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.remote`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.remote`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.remote`).
pub const Tab = struct {};
