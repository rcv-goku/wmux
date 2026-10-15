//! Per-object state of feature `a11y` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.a11y`).
pub const App = struct {};

/// Per-window state (`Window.ext.a11y`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.a11y`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.a11y`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.a11y`).
pub const Tab = struct {};
