//! Per-object state of feature `automation` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.automation`).
pub const App = struct {};

/// Per-window state (`Window.ext.automation`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.automation`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.automation`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.automation`).
pub const Tab = struct {};
