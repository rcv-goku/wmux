//! Per-object state of feature `workspace_status` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.workspace_status`).
pub const App = struct {};

/// Per-window state (`Window.ext.workspace_status`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.workspace_status`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.workspace_status`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.workspace_status`).
pub const Tab = struct {};
