//! Per-object state of feature `session` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.
//!
//! W1-7a: the app-wide runtime of the session store (autosave, writer
//! thread, pending restore) lives behind `App.core`; the model objects keep
//! the `ext` JSON they were restored with, so feature keys this build does
//! not know round-trip untouched (ADR-9.2), and terminals remember the
//! directory they were spawned in (the cwd fallback when the shell never
//! reported one, ADR-9.6).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// App-wide state (`App.features.session`).
pub const App = struct {
    /// The session runtime (features/session/autosave.zig `Core`), created
    /// by the feature's `init` and destroyed by its `deinit`. Opaque here so
    /// the ext aggregate does not import the session internals.
    core: ?*anyopaque = null,
};

/// Raw `ext` object text an object was restored with (owned; null = none).
/// The writer merges it under the live feature snapshots.
pub const ExtJson = struct {
    ext_json: ?[]u8 = null,

    pub fn set(self: *ExtJson, gpa: Allocator, text: ?[]const u8) Allocator.Error!void {
        const copy: ?[]u8 = if (text) |t| try gpa.dupe(u8, t) else null;
        if (self.ext_json) |old| gpa.free(old);
        self.ext_json = copy;
    }

    pub fn deinit(self: *ExtJson, gpa: Allocator) void {
        if (self.ext_json) |t| gpa.free(t);
        self.ext_json = null;
    }
};

/// Per-window state (`Window.ext.session`).
pub const Window = ExtJson;

/// Per-workspace state (`Workspace.ext.session`).
pub const Workspace = ExtJson;

/// Per-pane state (`Pane.ext.session`).
pub const Pane = ExtJson;

/// Per-surface state (`Tab.ext.session`).
pub const Tab = struct {
    ext_json: ?[]u8 = null,
    /// The working directory the terminal was spawned (or restored) in,
    /// owned; the snapshot's cwd when the shell never reported one.
    spawn_cwd: ?[]u8 = null,
    /// The raw `panel` object of a tab this build restores as a
    /// placeholder (a web panel or an unknown kind), owned, so it is
    /// written back unchanged.
    panel_json: ?[]u8 = null,

    pub fn setExt(self: *Tab, gpa: Allocator, text: ?[]const u8) Allocator.Error!void {
        try replace(gpa, &self.ext_json, text);
    }

    pub fn setSpawnCwd(self: *Tab, gpa: Allocator, text: ?[]const u8) Allocator.Error!void {
        try replace(gpa, &self.spawn_cwd, text);
    }

    pub fn setPanel(self: *Tab, gpa: Allocator, text: ?[]const u8) Allocator.Error!void {
        try replace(gpa, &self.panel_json, text);
    }

    pub fn deinit(self: *Tab, gpa: Allocator) void {
        inline for (.{ &self.ext_json, &self.spawn_cwd, &self.panel_json }) |slot| {
            if (slot.*) |t| gpa.free(t);
            slot.* = null;
        }
    }
};

fn replace(gpa: Allocator, slot: *?[]u8, text: ?[]const u8) Allocator.Error!void {
    const copy: ?[]u8 = if (text) |t| try gpa.dupe(u8, t) else null;
    if (slot.*) |old| gpa.free(old);
    slot.* = copy;
}

test "unit: session: object state keeps owned copies and frees them" {
    const gpa = std.testing.allocator;
    var e: ExtJson = .{};
    try e.set(gpa, "{\"x\":1}");
    try e.set(gpa, "{\"y\":2}");
    try std.testing.expectEqualStrings("{\"y\":2}", e.ext_json.?);
    e.deinit(gpa);
    var t: Tab = .{};
    try t.setSpawnCwd(gpa, "C:\\src");
    try t.setPanel(gpa, "{\"kind\":\"web\"}");
    try t.setExt(gpa, null);
    try std.testing.expect(t.ext_json == null);
    t.deinit(gpa);
    try std.testing.expect(t.spawn_cwd == null and t.panel_json == null);
}
