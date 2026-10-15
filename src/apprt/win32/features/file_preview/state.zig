//! Per-object state of feature `file_preview` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.file_preview`).
pub const App = struct {};

/// Per-window state (`Window.ext.file_preview`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.file_preview`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.file_preview`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.file_preview`).
pub const Tab = struct {};
