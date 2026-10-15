//! Per-object state of feature `groups` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.groups`).
pub const App = struct {};

/// Per-window state (`Window.ext.groups`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.groups`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.groups`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.groups`).
pub const Tab = struct {};
