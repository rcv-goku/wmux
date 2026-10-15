//! Per-object state of feature `events` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.events`).
pub const App = struct {};

/// Per-window state (`Window.ext.events`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.events`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.events`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.events`).
pub const Tab = struct {};
