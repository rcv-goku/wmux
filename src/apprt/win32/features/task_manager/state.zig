//! Per-object state of feature `task_manager` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.task_manager`).
pub const App = struct {};

/// Per-window state (`Window.ext.task_manager`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.task_manager`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.task_manager`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.task_manager`).
pub const Tab = struct {};
