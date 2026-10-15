//! Per-object state of feature `about` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.about`).
pub const App = struct {};

/// Per-window state (`Window.ext.about`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.about`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.about`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.about`).
pub const Tab = struct {};
