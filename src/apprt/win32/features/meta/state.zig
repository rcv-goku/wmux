//! Per-object state of feature `meta` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.meta`).
pub const App = struct {};

/// Per-window state (`Window.ext.meta`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.meta`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.meta`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.meta`).
pub const Tab = struct {};
