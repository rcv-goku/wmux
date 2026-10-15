//! Per-object state of feature `layouts` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.layouts`).
pub const App = struct {};

/// Per-window state (`Window.ext.layouts`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.layouts`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.layouts`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.layouts`).
pub const Tab = struct {};
