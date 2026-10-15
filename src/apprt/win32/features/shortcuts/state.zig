//! Per-object state of feature `shortcuts` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.shortcuts`).
pub const App = struct {};

/// Per-window state (`Window.ext.shortcuts`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.shortcuts`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.shortcuts`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.shortcuts`).
pub const Tab = struct {};
