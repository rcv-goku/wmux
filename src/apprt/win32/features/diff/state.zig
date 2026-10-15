//! Per-object state of feature `diff` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.diff`).
pub const App = struct {};

/// Per-window state (`Window.ext.diff`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.diff`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.diff`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.diff`).
pub const Tab = struct {};
