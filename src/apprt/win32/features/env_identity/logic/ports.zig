//! Per-workspace port block math (ARCHITECTURE.md ADR-3.9, feature
//! `cli-terminal-env-ports`): every workspace gets an ordinal when its
//! first terminal spawns (0, 1, 2, ... in order, never reused while the app
//! runs), and its terminals export `CMUX_PORT` (first port of the block),
//! `CMUX_PORT_END` (last port, inclusive) and `CMUX_PORT_RANGE` (ports per
//! block) from the cmux settings `automation.portBase` (9100) and
//! `automation.portRange` (10). Pure: std only.

const std = @import("std");

/// The defaults of `automation.portBase` and `automation.portRange`.
pub const default_base: i64 = 9100;
pub const default_range: i64 = 10;

/// The highest TCP port.
pub const max_port: u32 = 65535;

pub const Block = struct {
    /// First port (`CMUX_PORT`).
    start: u32,
    /// Last port, inclusive (`CMUX_PORT_END` = start + range - 1).
    end: u32,
    /// Ports in the block (`CMUX_PORT_RANGE`).
    range: u32,
};

/// The block of the workspace with `ordinal` for the settings `base` and
/// `range`. Values outside the valid ranges are clamped (base to
/// 1..65535, range to at least 1); when the ordinals run past the last
/// port, they wrap around to the first block that fits, so every block
/// stays inside 1..65535. Null only when not even one block fits above
/// `base`.
pub fn block(base: i64, range: i64, ordinal: u32) ?Block {
    const b: u32 = @intCast(std.math.clamp(base, 1, max_port));
    const r: u32 = @intCast(std.math.clamp(range, 1, max_port));
    const span = max_port - b + 1;
    const blocks = span / r;
    if (blocks == 0) return null;
    const start = b + (ordinal % blocks) * r;
    return .{ .start = start, .end = start + r - 1, .range = r };
}

/// Hands out workspace ordinals in creation order (the app keeps one).
pub const Ordinals = struct {
    next: u32 = 0,

    /// The next ordinal; wraps at the u32 limit (`block` wraps anyway).
    pub fn take(self: *Ordinals) u32 {
        const o = self.next;
        self.next +%= 1;
        return o;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: env_identity: port block math uses base + ordinal * range" {
    try testing.expectEqual(Block{ .start = 9100, .end = 9109, .range = 10 }, block(default_base, default_range, 0).?);
    try testing.expectEqual(Block{ .start = 9110, .end = 9119, .range = 10 }, block(default_base, default_range, 1).?);
    try testing.expectEqual(Block{ .start = 9200, .end = 9209, .range = 10 }, block(default_base, default_range, 10).?);
    try testing.expectEqual(Block{ .start = 32100 + 2 * 42, .end = 32100 + 3 * 42 - 1, .range = 42 }, block(32100, 42, 2).?);
    // A one-port block.
    try testing.expectEqual(Block{ .start = 9105, .end = 9105, .range = 1 }, block(9100, 1, 5).?);
}

test "unit: env_identity: port block math clamps and wraps inside 1..65535" {
    // Out-of-range settings are clamped.
    try testing.expectEqual(Block{ .start = 1, .end = 1, .range = 1 }, block(0, 0, 0).?);
    try testing.expectEqual(Block{ .start = 1, .end = 10, .range = 10 }, block(-5, 10, 0).?);
    // 9100..65535 holds 5643 blocks of 10: ordinal 5643 wraps to the first.
    const blocks: u32 = (max_port - 9100 + 1) / 10;
    try testing.expectEqual(@as(u32, 5643), blocks);
    try testing.expectEqual(@as(u32, 9100 + (blocks - 1) * 10), block(9100, 10, blocks - 1).?.start);
    try testing.expectEqual(@as(u32, 9100), block(9100, 10, blocks).?.start);
    var o: u32 = 0;
    while (o < 3 * blocks) : (o += 997) {
        const blk = block(9100, 10, o).?;
        try testing.expect(blk.start >= 9100 and blk.end <= max_port);
    }
    try testing.expect(block(9100, 10, std.math.maxInt(u32)).?.end <= max_port);
    // No block fits.
    try testing.expectEqual(@as(?Block, null), block(65535, 2, 0));
    try testing.expectEqual(Block{ .start = 65535, .end = 65535, .range = 1 }, block(70000, 1, 3).?);
}

test "unit: env_identity: port ordinals count up in creation order" {
    var ords: Ordinals = .{};
    try testing.expectEqual(@as(u32, 0), ords.take());
    try testing.expectEqual(@as(u32, 1), ords.take());
    ords.next = std.math.maxInt(u32);
    try testing.expectEqual(std.math.maxInt(u32), ords.take());
    try testing.expectEqual(@as(u32, 0), ords.take());
}
