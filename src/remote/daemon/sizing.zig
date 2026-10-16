//! Resize coordinator: the PTY size is cols = min(cols_i), rows = min(rows_i)
//! over attachments (smallest screen wins). With no attachments the last
//! effective size is kept (no 80x24 reset). Zero sizes are relayout noise
//! and are ignored.

const std = @import("std");

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub fn eql(a: Size, b: Size) bool {
        return a.cols == b.cols and a.rows == b.rows;
    }
};

/// Effective size for `items` (a slice of Size, or of structs with a
/// `size: Size` field) given the previous effective size `last`.
pub fn effective(last: Size, items: anytype) Size {
    var cols: u16 = std.math.maxInt(u16);
    var rows: u16 = std.math.maxInt(u16);
    var any = false;
    for (items) |item| {
        const s: Size = if (@TypeOf(item) == Size) item else item.size;
        if (s.cols == 0 or s.rows == 0) continue;
        cols = @min(cols, s.cols);
        rows = @min(rows, s.rows);
        any = true;
    }
    return if (any) .{ .cols = cols, .rows = rows } else last;
}

const testing = std.testing;

test "unit: remote-daemon: smallest attached client wins per dimension" {
    const last: Size = .{ .cols = 100, .rows = 40 };
    try testing.expectEqual(last, effective(last, @as([]const Size, &.{})));
    try testing.expectEqual(Size{ .cols = 80, .rows = 24 }, effective(last, &[_]Size{.{ .cols = 80, .rows = 24 }}));
    const two = [_]Size{ .{ .cols = 120, .rows = 20 }, .{ .cols = 90, .rows = 50 } };
    try testing.expectEqual(Size{ .cols = 90, .rows = 20 }, effective(last, &two));
    // Growing back after the smaller one leaves.
    try testing.expectEqual(Size{ .cols = 120, .rows = 20 }, effective(.{ .cols = 90, .rows = 20 }, two[0..1]));
}

test "unit: remote-daemon: zero sizes are ignored and extremes are kept" {
    const last: Size = .{ .cols = 80, .rows = 24 };
    const noisy = [_]Size{ .{ .cols = 0, .rows = 30 }, .{ .cols = 50, .rows = 0 } };
    try testing.expectEqual(last, effective(last, &noisy));
    const big = [_]Size{ .{ .cols = 65535, .rows = 65535 }, .{ .cols = 1, .rows = 65535 } };
    try testing.expectEqual(Size{ .cols = 1, .rows = 65535 }, effective(last, &big));
}
