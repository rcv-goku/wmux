//! Per-object state of feature `resume` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.@"resume"`).
pub const App = struct {};

/// Per-window state (`Window.ext.@"resume"`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.@"resume"`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.@"resume"`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.@"resume"`).
pub const Tab = struct {};
