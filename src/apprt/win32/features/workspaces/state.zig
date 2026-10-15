//! Per-object state of feature `workspaces` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.workspaces`).
pub const App = struct {};

/// Per-window state (`Window.ext.workspaces`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.workspaces`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.workspaces`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.workspaces`).
pub const Tab = struct {};
