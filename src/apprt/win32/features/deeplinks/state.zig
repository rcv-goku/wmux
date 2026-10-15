//! Per-object state of feature `deeplinks` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.deeplinks`).
pub const App = struct {};

/// Per-window state (`Window.ext.deeplinks`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.deeplinks`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.deeplinks`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.deeplinks`).
pub const Tab = struct {};
