//! Per-object state of feature `files_explorer` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.files_explorer`).
pub const App = struct {};

/// Per-window state (`Window.ext.files_explorer`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.files_explorer`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.files_explorer`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.files_explorer`).
pub const Tab = struct {};
