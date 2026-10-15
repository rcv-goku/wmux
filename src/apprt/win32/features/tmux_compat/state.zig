//! Per-object state of feature `tmux_compat` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.tmux_compat`).
pub const App = struct {};

/// Per-window state (`Window.ext.tmux_compat`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.tmux_compat`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.tmux_compat`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.tmux_compat`).
pub const Tab = struct {};
