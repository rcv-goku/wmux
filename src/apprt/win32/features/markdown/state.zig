//! Per-object state of feature `markdown` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.markdown`).
pub const App = struct {};

/// Per-window state (`Window.ext.markdown`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.markdown`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.markdown`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.markdown`).
pub const Tab = struct {};
