//! Per-object state of feature `agents` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.agents`).
pub const App = struct {};

/// Per-window state (`Window.ext.agents`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.agents`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.agents`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.agents`).
pub const Tab = struct {};
