//! Per-object state of feature `find_in_dir` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.find_in_dir`).
pub const App = struct {};

/// Per-window state (`Window.ext.find_in_dir`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.find_in_dir`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.find_in_dir`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.find_in_dir`).
pub const Tab = struct {};
