//! Per-object state of feature `terminal_io` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.terminal_io`).
pub const App = struct {};

/// Per-window state (`Window.ext.terminal_io`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.terminal_io`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.terminal_io`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.terminal_io`).
pub const Tab = struct {};
