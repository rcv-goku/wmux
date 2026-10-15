//! Per-object state of feature `vault` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.vault`).
pub const App = struct {};

/// Per-window state (`Window.ext.vault`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.vault`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.vault`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.vault`).
pub const Tab = struct {};
