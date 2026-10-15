//! Per-object state of feature `hints` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.hints`).
pub const App = struct {};

/// Per-window state (`Window.ext.hints`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.hints`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.hints`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.hints`).
pub const Tab = struct {};
