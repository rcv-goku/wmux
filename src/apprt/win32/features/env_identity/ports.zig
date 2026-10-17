//! Per-workspace port blocks (ARCHITECTURE.md ADR-3.9, feature
//! `cli-terminal-env-ports`): a workspace gets the next ordinal when its
//! first terminal spawns and keeps it while the app runs; the block comes
//! from `automation.portBase`/`automation.portRange` (logic/ports.zig).
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
    const gop = st.port_ordinals.getOrPut(app.core_app.alloc, workspace) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = st.ordinals.take();
    return logic.block(
        settings.get(app, "automation.portBase"),
        settings.get(app, "automation.portRange"),
        gop.value_ptr.*,
    );
}

/// Forget a closed workspace's ordinal (ordinals are never handed out
/// twice, so a later workspace still gets a fresh block).
pub fn forget(app: *App, workspace: ids.Uuid) void {
    _ = app.features.env_identity.port_ordinals.remove(workspace);
}
