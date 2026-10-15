//! Per-object state of feature `session` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.session`).
pub const App = struct {};

/// Per-window state (`Window.ext.session`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.session`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.session`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.session`).
pub const Tab = struct {};
