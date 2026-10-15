//! Per-object state of feature `panes_surfaces` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.panes_surfaces`).
pub const App = struct {};

/// Per-window state (`Window.ext.panes_surfaces`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.panes_surfaces`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.panes_surfaces`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.panes_surfaces`).
pub const Tab = struct {};
