//! Per-object state of feature `dnd` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.dnd`).
pub const App = struct {};

/// Per-window state (`Window.ext.dnd`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.dnd`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.dnd`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.dnd`).
pub const Tab = struct {};
