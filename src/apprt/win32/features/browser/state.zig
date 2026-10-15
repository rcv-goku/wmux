//! Per-object state of feature `browser` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.browser`).
pub const App = struct {};

/// Per-window state (`Window.ext.browser`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.browser`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.browser`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.browser`).
pub const Tab = struct {};
