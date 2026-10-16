//! Environment hygiene for processes the CLI spawns (ADR-4.1, spike S6 §5.1):
//! `WMUX_ARGV0` only brands the CLI invocation it was set for, so it and its
//! `WSLENV` entry are removed before any child (the GUI, a relayed
//! `wmux.exe +action`) inherits them; otherwise a child CLI started by that
//! child would take the wrong name.

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;

/// `WSLENV` without the `WMUX_ARGV0` entry (any flags). Empty segments are
/// dropped. Returns null when nothing is left. Caller owns the result.
pub fn wslenvWithout(gpa: std.mem.Allocator, wslenv: []const u8, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, wslenv, ':');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, seg, '/') orelse seg.len;
        if (env_names.eqlEnvName(seg[0..slash], name)) continue;
        if (out.items.len > 0) try out.append(gpa, ':');
        try out.appendSlice(gpa, seg);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// Removes `WMUX_ARGV0` and its `WSLENV` entry from `map` in place.
pub fn sanitize(map: *std.process.EnvMap) std.mem.Allocator.Error!void {
    map.remove(env_names.WMUX_ARGV0);
    const wslenv = map.get(env_names.WSLENV) orelse return;
    const gpa = map.hash_map.allocator;
    const cleaned = try wslenvWithout(gpa, wslenv, env_names.WMUX_ARGV0);
    if (cleaned) |c| {
        defer gpa.free(c);
        if (!std.mem.eql(u8, c, wslenv)) try map.put(env_names.WSLENV, c);
    } else map.remove(env_names.WSLENV);
}

const testing = std.testing;

test "unit: cli: child env drops WMUX_ARGV0 and its WSLENV entry" {
    var map = std.process.EnvMap.init(testing.allocator);
    defer map.deinit();
    try map.put("WMUX_ARGV0", "wmux");
    try map.put("WSLENV", "CMUX_SURFACE_ID/u:WMUX_ARGV0:TERM_PROGRAM/u");
    try map.put("PATH", "C:\\x");
    try sanitize(&map);
    try testing.expectEqual(@as(?[]const u8, null), map.get("WMUX_ARGV0"));
    try testing.expectEqualStrings("CMUX_SURFACE_ID/u:TERM_PROGRAM/u", map.get("WSLENV").?);
    try testing.expectEqualStrings("C:\\x", map.get("PATH").?);
}

test "unit: cli: child env removes WSLENV when only WMUX_ARGV0 was listed" {
    var map = std.process.EnvMap.init(testing.allocator);
    defer map.deinit();
    try map.put("WSLENV", "WMUX_ARGV0/u");
    try sanitize(&map);
    try testing.expectEqual(@as(?[]const u8, null), map.get("WSLENV"));
    // Nothing to do is fine too.
    try sanitize(&map);
    try testing.expectEqual(@as(u32, 0), map.count());
}

test "unit: cli: child env WSLENV filter edge cases" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "", null },
        .{ ":::", null },
        .{ "WMUX_ARGV0", null },
        .{ "A:WMUX_ARGV0/up:B", "A:B" },
        .{ "WMUX_ARGV0X:A", "WMUX_ARGV0X:A" },
        .{ "A::B:", "A:B" },
        .{ "\u{e9}/u:WMUX_ARGV0", "\u{e9}/u" },
    };
    for (cases) |c| {
        const got = try wslenvWithout(gpa, c[0], "WMUX_ARGV0");
        defer if (got) |g| gpa.free(g);
        if (c[1]) |want| try testing.expectEqualStrings(want, got.?) else try testing.expectEqual(@as(?[]u8, null), got);
    }
}
