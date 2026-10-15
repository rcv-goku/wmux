//! Per-object state of feature `sleepy_mode` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.sleepy_mode`).
pub const App = struct {};

/// Per-window state (`Window.ext.sleepy_mode`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.sleepy_mode`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.sleepy_mode`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.sleepy_mode`).
pub const Tab = struct {};
