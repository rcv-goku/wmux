//! Per-object state of feature `todo` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.todo`).
pub const App = struct {};

/// Per-window state (`Window.ext.todo`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.todo`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.todo`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.todo`).
pub const Tab = struct {};
