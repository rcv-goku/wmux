//! Per-object state of feature `agent_chat` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

/// App-wide state (`App.features.agent_chat`).
pub const App = struct {};

/// Per-window state (`Window.ext.agent_chat`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.agent_chat`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.agent_chat`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.agent_chat`).
pub const Tab = struct {};
