//! Per-object state of feature `comments` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.comments`).
pub const App = struct {};

/// Per-window state (`Window.ext.comments`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.comments`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.comments`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.comments`).
pub const Tab = struct {};
