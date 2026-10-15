//! Per-object state of feature `image_paste` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.image_paste`).
pub const App = struct {};

/// Per-window state (`Window.ext.image_paste`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.image_paste`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.image_paste`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.image_paste`).
pub const Tab = struct {};
