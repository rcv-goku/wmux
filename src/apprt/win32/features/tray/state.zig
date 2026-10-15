//! Per-object state of feature `tray` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.tray`).
pub const App = struct {};

/// Per-window state (`Window.ext.tray`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.tray`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.tray`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.tray`).
pub const Tab = struct {};
