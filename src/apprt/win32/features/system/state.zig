//! Per-object state of feature `system` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.system`).
pub const App = struct {};

/// Per-window state (`Window.ext.system`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.system`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.system`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.system`).
pub const Tab = struct {};
