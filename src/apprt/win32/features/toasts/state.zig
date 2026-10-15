//! Per-object state of feature `toasts` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.toasts`).
pub const App = struct {};

/// Per-window state (`Window.ext.toasts`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.toasts`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.toasts`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.toasts`).
pub const Tab = struct {};
