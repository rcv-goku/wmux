//! Per-workspace port blocks (ARCHITECTURE.md ADR-3.9, feature
//! `cli-terminal-env-ports`): a workspace gets the next ordinal when its
//! first terminal spawns, and its block (from `automation.portBase`/
//! `automation.portRange`, logic/ports.zig) is snapshotted then and kept
//! while the app runs, so all terminals of a workspace share it even when
//! the settings change later (cmux snapshots it once per session).
//! UI thread only.

const std = @import("std");

const App = @import("../../App.zig");
const settings = @import("../../settings/api.zig");
const ids = @import("../../model/ids.zig");
const logic = @import("logic/ports.zig");

pub const Block = logic.Block;

/// The port block of workspace `workspace` (null for a nil id, on
/// allocation failure, or when no block fits).
pub fn blockFor(app: *App, workspace: ids.Uuid) ?Block {
    if (workspace.isNil()) return null;
    const st = &app.features.env_identity;
    const gop = st.port_blocks.getOrPut(app.core_app.alloc, workspace) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = logic.block(
        settings.get(app, "automation.portBase"),
        settings.get(app, "automation.portRange"),
        st.ordinals.take(),
    );
    return gop.value_ptr.*;
}

/// Forget a closed workspace's block (ordinals are never handed out
/// twice, so a later workspace still gets a fresh block).
pub fn forget(app: *App, workspace: ids.Uuid) void {
    _ = app.features.env_identity.port_blocks.remove(workspace);
}
