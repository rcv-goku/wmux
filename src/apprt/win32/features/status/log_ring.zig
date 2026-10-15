//! Status / progress / log ring (pure; the sidebar metadata model): the
//! per-tab ring of recent `log` lines shown by the sidebars.
//!
//! Moved out of `ipc.zig` in W0-A1 (ARCHITECTURE.md ADR-1.8); W0-A3 moves
//! the per-tab storage into the `status` feature's ext state.

const std = @import("std");
const testing = std.testing;

/// A small fixed-capacity ring of recent log lines for one tab. Pushed by
/// the `log` IPC verb and rendered by the sidebar (Stage 2). Kept here, in
/// the pure protocol layer, so the wrap/newest-first/truncation rules are
/// unit-testable without a live Window. Each line is stored in an inline
/// fixed buffer (no per-push allocation, matching the tab-title/name
/// buffers on Workspace); over-long lines are byte-truncated.
pub const max_log_line_bytes: usize = 160;
pub const log_ring_capacity: usize = 8;

pub const LogRing = struct {
    /// Inline storage for each line + its used length.
    lines: [log_ring_capacity][max_log_line_bytes]u8 = undefined,
    lens: [log_ring_capacity]u16 = @splat(0),
    /// Index where the next push lands (mod capacity).
    head: usize = 0,
    /// Number of live lines (<= capacity).
    len: usize = 0,

    /// Append a line, truncating to max_log_line_bytes and dropping the
    /// oldest once full. Invalid UTF-8 is not the ring's concern (the
    /// renderer is lossy); the byte truncation may split a codepoint, so
    /// callers that care should pre-truncate on a boundary.
    pub fn push(self: *LogRing, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, max_log_line_bytes));
        @memcpy(self.lines[self.head][0..n], text[0..n]);
        self.lens[self.head] = n;
        self.head = (self.head + 1) % log_ring_capacity;
        if (self.len < log_ring_capacity) self.len += 1;
    }

    /// The display_idx-th newest line (0 = newest), or null past the end.
    pub fn at(self: *const LogRing, display_idx: usize) ?[]const u8 {
        if (display_idx >= self.len) return null;
        // head points one past the newest; walk backward.
        const slot = (self.head + log_ring_capacity - 1 - display_idx) % log_ring_capacity;
        return self.lines[slot][0..self.lens[slot]];
    }

    /// The newest line, or null when empty (the sidebar's "latest" text).
    pub fn latest(self: *const LogRing) ?[]const u8 {
        return self.at(0);
    }

    pub fn clear(self: *LogRing) void {
        self.head = 0;
        self.len = 0;
    }
};

test "ipc: LogRing newest-first, wraps, and truncates" {
    var ring: LogRing = .{};
    try testing.expect(ring.latest() == null);
    try testing.expect(ring.at(0) == null);

    ring.push("first");
    ring.push("second");
    try testing.expectEqualStrings("second", ring.latest().?);
    try testing.expectEqualStrings("second", ring.at(0).?);
    try testing.expectEqualStrings("first", ring.at(1).?);
    try testing.expect(ring.at(2) == null);

    // Fill past capacity; the oldest drops, newest-first order holds.
    for (0..log_ring_capacity) |i| {
        var buf: [8]u8 = undefined;
        ring.push(std.fmt.bufPrint(&buf, "L{d}", .{i}) catch unreachable);
    }
    try testing.expectEqual(log_ring_capacity, ring.len);
    var ebuf: [8]u8 = undefined;
    const newest = std.fmt.bufPrint(&ebuf, "L{d}", .{log_ring_capacity - 1}) catch unreachable;
    try testing.expectEqualStrings(newest, ring.latest().?);

    // Over-long line is byte-truncated to the cap.
    const big = [_]u8{'x'} ** (max_log_line_bytes + 50);
    ring.push(&big);
    try testing.expectEqual(@as(usize, max_log_line_bytes), ring.latest().?.len);

    ring.clear();
    try testing.expectEqual(@as(usize, 0), ring.len);
    try testing.expect(ring.latest() == null);
}
