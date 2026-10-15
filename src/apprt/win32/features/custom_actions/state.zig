//! Per-object state of feature `custom_actions` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.custom_actions`).
pub const App = struct {};

/// Per-window state (`Window.ext.custom_actions`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.custom_actions`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.custom_actions`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.custom_actions`).
pub const Tab = struct {};
