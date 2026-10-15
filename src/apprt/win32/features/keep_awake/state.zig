//! Per-object state of feature `keep_awake` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.keep_awake`).
pub const App = struct {};

/// Per-window state (`Window.ext.keep_awake`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.keep_awake`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.keep_awake`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.keep_awake`).
pub const Tab = struct {};
