//! Per-object state of feature `quick_terminal` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.quick_terminal`).
pub const App = struct {};

/// Per-window state (`Window.ext.quick_terminal`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.quick_terminal`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.quick_terminal`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.quick_terminal`).
pub const Tab = struct {};
