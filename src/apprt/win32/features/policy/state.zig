//! Per-object state of feature `policy` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.policy`).
pub const App = struct {};

/// Per-window state (`Window.ext.policy`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.policy`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.policy`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.policy`).
pub const Tab = struct {};
