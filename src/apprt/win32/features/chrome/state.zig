//! Per-object state of feature `chrome` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.chrome`).
pub const App = struct {};

/// Per-window state (`Window.ext.chrome`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.chrome`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.chrome`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.chrome`).
pub const Tab = struct {};
