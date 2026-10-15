//! Channel selection: compiled default, WMUX_CHANNEL/WMUX_TAG overrides and
//! sanitizing to [a-z0-9-]{1,40} (ADR-3.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const env_names = @import("env_names.zig");
const Env = env_names.Env;

pub const max_len = 40;
pub const stable = "stable";
pub const debug = "debug";
pub const dev_prefix = "dev-";
pub const test_prefix = "test-";

/// Compiled default: `debug` for Debug builds, else the build override
/// (`-Dwmux-channel=<name>`) or `stable`. The result is not sanitized.
pub fn compiledDefault(optimize: std.builtin.OptimizeMode, build_override: ?[]const u8) []const u8 {
    if (optimize == .Debug) return debug;
    if (build_override) |o| if (o.len > 0) return o;
    return stable;
}

/// Maps `raw` onto `[a-z0-9-]{1,40}`: ASCII letters are lower-cased, every
/// other character (per code point; invalid bytes per byte) becomes `-`, runs
/// of `-` collapse to one, leading/trailing `-` are trimmed and the result is
/// capped at 40. Returns null when nothing is left.
pub fn sanitize(gpa: Allocator, raw: []const u8) Allocator.Error!?[]u8 {
    var buf: [max_len]u8 = undefined;
    const s = sanitizeBuf(&buf, raw) orelse return null;
    return try gpa.dupe(u8, s);
}

/// `sanitize` into a caller buffer of exactly `max_len` bytes.
pub fn sanitizeBuf(buf: *[max_len]u8, raw: []const u8) ?[]const u8 {
    var n: usize = 0;
    var pending_dash = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        var step: usize = 1;
        const mapped: ?u8 = switch (c) {
            'a'...'z', '0'...'9' => c,
            'A'...'Z' => c + 32,
            0x80...0xFF => blk: {
                const len = std.unicode.utf8ByteSequenceLength(c) catch break :blk null;
                if (i + len <= raw.len and std.unicode.utf8ValidateSlice(raw[i .. i + len])) step = len;
                break :blk null;
            },
            else => null,
        };
        i += step;
        if (mapped) |m| {
            if (pending_dash and n > 0) {
                if (n == max_len) break;
                buf[n] = '-';
                n += 1;
            }
            pending_dash = false;
            if (n == max_len) break;
            buf[n] = m;
            n += 1;
        } else pending_dash = true;
    }
    if (n == 0) return null;
    while (n > 0 and buf[n - 1] == '-') n -= 1;
    return buf[0..n];
}

/// True when `s` already matches `[a-z0-9-]{1,40}`.
pub fn isValid(s: []const u8) bool {
    if (s.len == 0 or s.len > max_len) return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Resolution order (ADR-3.1): `WMUX_CHANNEL` overrides all; else
/// `WMUX_TAG=<tag>` → `dev-<tag>`; else the compiled default. Each candidate
/// is sanitized; one that sanitizes to nothing is skipped. Falls back to
/// `stable` if even the default is unusable. Caller owns the result.
pub fn resolve(gpa: Allocator, compiled_default: []const u8, wmux_channel: ?[]const u8, wmux_tag: ?[]const u8) Allocator.Error![]u8 {
    if (wmux_channel) |c| if (try sanitize(gpa, c)) |s| return s;
    if (wmux_tag) |t| {
        var buf: [max_len]u8 = undefined;
        if (sanitizeBuf(&buf, t)) |tag| {
            const joined = try std.mem.concat(gpa, u8, &.{ dev_prefix, tag });
            defer gpa.free(joined);
            if (try sanitize(gpa, joined)) |s| return s;
        }
    }
    if (try sanitize(gpa, compiled_default)) |s| return s;
    return gpa.dupe(u8, stable);
}

/// `resolve` reading `WMUX_CHANNEL`/`WMUX_TAG` from `env`.
pub fn resolveFromEnv(gpa: Allocator, compiled_default: []const u8, env: Env) Allocator.Error![]u8 {
    return resolve(gpa, compiled_default, env.getNonEmpty(env_names.WMUX_CHANNEL), env.getNonEmpty(env_names.WMUX_TAG));
}

/// `test-<8 lowercase hex>` from 4 random bytes (test instances).
pub fn testChannel(random_bytes: [4]u8) [test_prefix.len + 8]u8 {
    var out: [test_prefix.len + 8]u8 = undefined;
    @memcpy(out[0..test_prefix.len], test_prefix);
    out[test_prefix.len..].* = std.fmt.bytesToHex(random_bytes, .lower);
    return out;
}

pub fn isTestChannel(channel: []const u8) bool {
    return std.mem.startsWith(u8, channel, test_prefix);
}

/// Channels whose capability secret is regenerated per launch (ADR-3.8).
pub fn isEphemeral(channel: []const u8) bool {
    return std.mem.eql(u8, channel, debug) or isTestChannel(channel);
}

/// AUMID / bundle id: `wmux.app` for stable, else `wmux.app.<channel>`.
pub fn bundleIdAlloc(gpa: Allocator, channel: []const u8) Allocator.Error![]u8 {
    if (std.mem.eql(u8, channel, stable)) return gpa.dupe(u8, "wmux.app");
    return std.mem.concat(gpa, u8, &.{ "wmux.app.", channel });
}

const testing = std.testing;

fn expectSanitized(raw: []const u8, want: ?[]const u8) !void {
    const got = try sanitize(testing.allocator, raw);
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| {
        try testing.expectEqualStrings(w, got.?);
        try testing.expect(isValid(got.?));
    } else try testing.expectEqual(@as(?[]u8, null), got);
}

test "unit: proto: channel sanitize" {
    try expectSanitized("stable", "stable");
    try expectSanitized("Nightly", "nightly");
    try expectSanitized("dev-My Branch_1", "dev-my-branch-1");
    try expectSanitized("--a--b--", "a-b");
    try expectSanitized("feature/x.y", "feature-x-y");
    try expectSanitized("J\u{f6}rg", "j-rg");
    try expectSanitized("\u{1F600}x\u{1F600}\u{1F600}y", "x-y");
    try expectSanitized("a\xffb", "a-b");
    try expectSanitized("a\xe2\x82", "a");
    try expectSanitized("", null);
    try expectSanitized("---", null);
    try expectSanitized("\u{1F600}", null);
    try expectSanitized("  ", null);
}

test "unit: proto: channel sanitize caps at 40" {
    try expectSanitized("a" ** 41, "a" ** 40);
    try expectSanitized("a" ** 39 ++ "-b", "a" ** 39);
    try expectSanitized("a" ** 39 ++ "--bc", "a" ** 39);
    try expectSanitized("a" ** 38 ++ "_bc", "a" ** 38 ++ "-b");
    var huge: [10_000]u8 = undefined;
    @memset(&huge, 'Z');
    try expectSanitized(&huge, "z" ** 40);
}

test "unit: proto: channel isValid" {
    try testing.expect(isValid("stable"));
    try testing.expect(isValid("test-0a1b2c3d"));
    try testing.expect(!isValid(""));
    try testing.expect(!isValid("Stable"));
    try testing.expect(!isValid("a_b"));
    try testing.expect(!isValid("a" ** 41));
}

test "unit: proto: channel compiled default" {
    try testing.expectEqualStrings("debug", compiledDefault(.Debug, "nightly"));
    try testing.expectEqualStrings("stable", compiledDefault(.ReleaseFast, null));
    try testing.expectEqualStrings("stable", compiledDefault(.ReleaseSafe, ""));
    try testing.expectEqualStrings("nightly", compiledDefault(.ReleaseFast, "nightly"));
}

test "unit: proto: channel resolve precedence" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8, ?[]const u8, []const u8 }{
        .{ "stable", null, null, "stable" },
        .{ "stable", null, "My Tag", "dev-my-tag" },
        .{ "stable", "Nightly", "tag", "nightly" },
        .{ "stable", "!!!", "tag", "dev-tag" },
        .{ "stable", "!!!", "???", "stable" },
        .{ "debug", null, null, "debug" },
        .{ "", null, null, "stable" },
        .{ "stable", null, "t" ** 50, "dev-" ++ "t" ** 36 },
    };
    for (cases) |c| {
        const got = try resolve(gpa, c[0], c[1], c[2]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[3], got);
        try testing.expect(isValid(got));
    }
}

test "unit: proto: channel resolve from env" {
    const gpa = testing.allocator;
    const pairs: []const Env.Pair = &.{ .{ "WMUX_CHANNEL", "" }, .{ "WMUX_TAG", "pr-12" } };
    const got = try resolveFromEnv(gpa, "stable", Env.fromPairs(&pairs));
    defer gpa.free(got);
    try testing.expectEqualStrings("dev-pr-12", got);
    const none = try resolveFromEnv(gpa, "nightly", Env.empty);
    defer gpa.free(none);
    try testing.expectEqualStrings("nightly", none);
}

test "unit: proto: channel test channels and bundle ids" {
    const t = testChannel(.{ 0x0a, 0x1b, 0x2c, 0xff });
    try testing.expectEqualStrings("test-0a1b2cff", &t);
    try testing.expect(isTestChannel(&t));
    try testing.expect(isValid(&t));
    try testing.expect(isEphemeral("debug"));
    try testing.expect(isEphemeral(&t));
    try testing.expect(!isEphemeral("stable"));
    const gpa = testing.allocator;
    const a = try bundleIdAlloc(gpa, "stable");
    defer gpa.free(a);
    try testing.expectEqualStrings("wmux.app", a);
    const b = try bundleIdAlloc(gpa, "nightly");
    defer gpa.free(b);
    try testing.expectEqualStrings("wmux.app.nightly", b);
}
