//! Per-object state of feature `remote_tmux` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.remote_tmux`).
pub const App = struct {};

/// Per-window state (`Window.ext.remote_tmux`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.remote_tmux`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.remote_tmux`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.remote_tmux`).
pub const Tab = struct {};
