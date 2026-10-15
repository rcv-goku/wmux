//! Per-object state of feature `feed` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.feed`).
pub const App = struct {};

/// Per-window state (`Window.ext.feed`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.feed`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.feed`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.feed`).
pub const Tab = struct {};
