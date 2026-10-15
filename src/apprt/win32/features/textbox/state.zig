//! Per-object state of feature `textbox` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.textbox`).
pub const App = struct {};

/// Per-window state (`Window.ext.textbox`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.textbox`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.textbox`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.textbox`).
pub const Tab = struct {};
