//! Per-object state of feature `status` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

const log_ring = @import("log_ring.zig");

/// Maximum bytes of a tab's status text (legacy `set-status`). Inline, so
/// set-status never allocates; longer text is byte truncated (legacy
/// behavior until W2-6 replaces it with the status entries of
/// `wmux.sidebar.status.*`).
pub const max_status_bytes: usize = 96;

/// App-wide state (`App.features.status`).
pub const App = struct {};

/// Per-window state (`Window.ext.status`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.status`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.status`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.status`): the legacy per-tab sidebar
/// metadata, moved out of model/Tab.zig in W0-A3.
pub const Tab = struct {
    /// Orchestration status text (`set-status`), byte truncated.
    status_text: [max_status_bytes]u8 = undefined,
    status_text_len: u16 = 0,
    /// Progress percent (`set-progress`), 0..100, or null for none.
    progress: ?u8 = null,
    /// Recent `log` lines.
    log: log_ring.LogRing = .{},

    pub fn statusText(self: *const Tab) []const u8 {
        return self.status_text[0..self.status_text_len];
    }

    /// Store the status text, byte truncated to `max_status_bytes` (empty
    /// clears it).
    pub fn setStatusText(self: *Tab, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, max_status_bytes));
        @memcpy(self.status_text[0..n], text[0..n]);
        self.status_text_len = n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "unit: status: tab status text is byte truncated" {
    var t: Tab = .{};
    try testing.expectEqualStrings("", t.statusText());
    t.setStatusText("running tests");
    try testing.expectEqualStrings("running tests", t.statusText());
    var long: [max_status_bytes + 10]u8 = undefined;
    @memset(&long, 'x');
    t.setStatusText(&long);
    try testing.expectEqual(max_status_bytes, t.statusText().len);
    t.setStatusText("");
    try testing.expectEqualStrings("", t.statusText());
}

test "unit: status: tab progress and log start empty" {
    var t: Tab = .{};
    try testing.expectEqual(@as(?u8, null), t.progress);
    try testing.expect(t.log.latest() == null);
    t.log.push("line one");
    t.log.push("line two");
    try testing.expectEqualStrings("line two", t.log.latest().?);
    try testing.expectEqualStrings("line one", t.log.at(1).?);
}
