//! Object identity in the model (ARCHITECTURE.md ADR-2): the wmux_proto
//! identity types under the names the model uses, the "not registered"
//! handle, and the identity a terminal is spawned with.
//!
//! Every window, workspace, workspace group, pane and tab (cmux surface)
//! has a `handle` (UUID + per-kind ref) minted in the process-wide
//! `App.handles` registry when the object is created (model/registry.zig)
//! and retired when it is destroyed.

const proto = @import("wmux_proto");

pub const Uuid = proto.uuid.Uuid;
pub const Kind = proto.handles.Kind;
pub const Ref = proto.handles.Ref;
pub const Handle = proto.handles.Handle;
pub const HandleText = proto.handles.HandleText;

/// The handle of an object that is not registered (yet): nil UUID, ref 0
/// (refs start at 1). The fake model graphs of the unit tests keep it.
pub const no_handle: Handle = .{ .uuid = Uuid.nil, .ref = 0 };

/// Whether `h` names a registered object.
pub fn isRegistered(h: Handle) bool {
    return h.ref != 0;
}

/// The identity a terminal surface is spawned with: fixed before its tab
/// (and, for a split, its pane) is linked into the model, because the
/// child process environment needs it at spawn (`CMUX_WORKSPACE_ID`,
/// `CMUX_SURFACE_ID`, `CMUX_PANE_ID`, `CMUX_TERMINAL_LIFECYCLE_ID`,
/// ADR-3.9). The tab and pane adopt these UUIDs when they are minted.
pub const SpawnIdentity = struct {
    window: Uuid = Uuid.nil,
    workspace: Uuid = Uuid.nil,
    /// The pane the terminal opens in (informational, ADR-3.9).
    pane: Uuid = Uuid.nil,
    /// The tab (cmux surface).
    surface: Uuid = Uuid.nil,
    /// `Tab.lifecycle_id`: new for every spawn of the tab's terminal.
    lifecycle: Uuid = Uuid.nil,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "unit: model: ids no_handle is unregistered and minted handles are" {
    try testing.expect(!isRegistered(no_handle));
    try testing.expect(no_handle.uuid.isNil());
    try testing.expect(isRegistered(.{ .uuid = Uuid.v4(), .ref = 1 }));
    const spawn: SpawnIdentity = .{};
    try testing.expect(spawn.surface.isNil() and spawn.lifecycle.isNil());
}
