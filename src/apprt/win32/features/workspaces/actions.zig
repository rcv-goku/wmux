//! Action handlers of feature `workspaces` (ARCHITECTURE.md ADR-8.1). The
//! actions it owns (ADR-1.5):
//! newTab, closeWorkspace, renameWorkspace, editWorkspaceDescription,
//! selectWorkspaceByNumber, nextSidebarTab, prevSidebarTab, moveWorkspaceUp,
//! moveWorkspaceDown.
//! Empty until W1-5 moves the existing behaviors here. The catalog
//! entries already exist (wmux_proto/actions_catalog.zig); input/actions.zig
//! joins this table.

const input = @import("../../input/actions.zig");

pub const handlers = [_]input.ActionHandler{};
