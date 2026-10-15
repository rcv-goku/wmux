//! tmux key names for `send-keys` (ADR-10.8): `Enter`, `C-m`, `KPEnter`,
//! `Tab`, `Space`, `BSpace`, `Escape`, `C-<x>`, `M-<key>`, arrows, paging and
//! function keys, translated to the bytes a terminal application receives
//! (xterm sequences, normal cursor mode). Unknown words are not keys: the
//! caller sends them literally, as tmux does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const named = std.StaticStringMap([]const u8).initComptime(.{
    .{ "enter", "\r" },
    .{ "kpenter", "\r" },
    .{ "tab", "\t" },
    .{ "btab", "\x1b[Z" },
    .{ "space", " " },
    .{ "bspace", "\x7f" },
    .{ "escape", "\x1b" },
    .{ "up", "\x1b[A" },
    .{ "down", "\x1b[B" },
    .{ "right", "\x1b[C" },
    .{ "left", "\x1b[D" },
    .{ "home", "\x1b[1~" },
    .{ "end", "\x1b[4~" },
    .{ "insert", "\x1b[2~" },
    .{ "ic", "\x1b[2~" },
    .{ "delete", "\x1b[3~" },
    .{ "dc", "\x1b[3~" },
    .{ "pageup", "\x1b[5~" },
    .{ "pgup", "\x1b[5~" },
    .{ "ppage", "\x1b[5~" },
    .{ "pagedown", "\x1b[6~" },
    .{ "pgdn", "\x1b[6~" },
    .{ "npage", "\x1b[6~" },
    .{ "f1", "\x1bOP" },
    .{ "f2", "\x1bOQ" },
    .{ "f3", "\x1bOR" },
    .{ "f4", "\x1bOS" },
    .{ "f5", "\x1b[15~" },
    .{ "f6", "\x1b[17~" },
    .{ "f7", "\x1b[18~" },
    .{ "f8", "\x1b[19~" },
    .{ "f9", "\x1b[20~" },
    .{ "f10", "\x1b[21~" },
    .{ "f11", "\x1b[23~" },
    .{ "f12", "\x1b[24~" },
});

/// Longest key name accepted (bounds the lowercase scratch buffer).
const max_name = 16;

/// Returns the bytes for a tmux key name, or null when `word` is not a key.
/// Named keys match case-insensitively; `C-`/`M-` prefixes are uppercase.
pub fn lookup(arena: Allocator, word: []const u8) Allocator.Error!?[]const u8 {
    if (word.len == 0 or word.len > max_name) return null;
    if (word.len > 2 and word[0] == 'M' and word[1] == '-') {
        const rest = word[2..];
        const inner = if (rest.len == 1) rest else (try lookup(arena, rest)) orelse return null;
        return try std.mem.concat(arena, u8, &.{ "\x1b", inner });
    }
    if (word.len > 2 and word[0] == 'C' and word[1] == '-') {
        const rest = word[2..];
        if (rest.len == 1) {
            const b = control(rest[0]) orelse return null;
            return try arena.dupe(u8, &.{b});
        }
        if (std.ascii.eqlIgnoreCase(rest, "space")) return try arena.dupe(u8, &.{0});
        return null;
    }
    if (word.len == 1) return null; // a single character is just text
    var buf: [max_name]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, word);
    return named.get(lower);
}

/// Control byte for `C-<c>`.
fn control(c: u8) ?u8 {
    return switch (c) {
        'a'...'z' => c - 'a' + 1,
        'A'...'Z' => c - 'A' + 1,
        '@', ' ', '2' => 0,
        '[', '3' => 0x1b,
        '\\', '4' => 0x1c,
        ']', '5' => 0x1d,
        '^', '6', '~' => 0x1e,
        '_', '7', '/' => 0x1f,
        '?', '8' => 0x7f,
        else => null,
    };
}

/// `send-keys -H`: one hexadecimal byte per argument (`0d`, `0x1b`).
pub fn parseHexByte(s: []const u8) ?u8 {
    const digits = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s[2..] else s;
    if (digits.len == 0 or digits.len > 2) return null;
    return std.fmt.parseInt(u8, digits, 16) catch null;
}

const testing = std.testing;

test "unit: tmux: keys: special keys from the cmux table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][2][]const u8{
        .{ "Enter", "\r" },  .{ "C-m", "\r" },       .{ "KPEnter", "\r" },   .{ "Tab", "\t" },
        .{ "C-i", "\t" },    .{ "Space", " " },      .{ "BSpace", "\x7f" },  .{ "Escape", "\x1b" },
        .{ "C-[", "\x1b" },  .{ "C-c", "\x03" },     .{ "C-d", "\x04" },     .{ "C-z", "\x1a" },
        .{ "C-l", "\x0c" },  .{ "enter", "\r" },     .{ "M-x", "\x1bx" },    .{ "M-Enter", "\x1b\r" },
        .{ "Up", "\x1b[A" }, .{ "F12", "\x1b[24~" }, .{ "C-Space", "\x00" }, .{ "PgUp", "\x1b[5~" },
    };
    for (cases) |c| {
        const got = (try lookup(a, c[0])) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(c[1], got);
    }
}

test "unit: tmux: keys: words that are not keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "", "x", "C-", "M-", "echo hi", "c-c", "C-é", "Enterprise", "M-notakey", "averyveryverylongword" }) |w| {
        try testing.expect((try lookup(a, w)) == null);
    }
}

test "unit: tmux: keys: hex bytes" {
    try testing.expectEqual(@as(u8, 0x0d), parseHexByte("0d").?);
    try testing.expectEqual(@as(u8, 0x1b), parseHexByte("0x1b").?);
    try testing.expectEqual(@as(u8, 0xff), parseHexByte("FF").?);
    try testing.expect(parseHexByte("") == null);
    try testing.expect(parseHexByte("100") == null);
    try testing.expect(parseHexByte("zz") == null);
}
