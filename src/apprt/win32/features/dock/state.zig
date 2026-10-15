//! Per-object state of feature `dock` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.dock`).
pub const App = struct {};

/// Per-window state (`Window.ext.dock`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.dock`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.dock`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.dock`).
pub const Tab = struct {};
