//! Per-object state of feature `copy_mode` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.copy_mode`).
pub const App = struct {};

/// Per-window state (`Window.ext.copy_mode`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.copy_mode`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.copy_mode`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.copy_mode`).
pub const Tab = struct {};
