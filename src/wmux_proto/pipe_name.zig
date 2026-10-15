//! Pipe names: control `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`, launch and
//! legacy pipes (ADR-3.1). Pure string logic; the caller supplies the user SID
//! string and session id (Win32 lookups live in the app and CLI). Named pipes
//! exist only on Windows (`supported`), but every function here is portable.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const channel_mod = @import("channel.zig");

/// True on hosts with Windows named pipes.
pub const supported = builtin.os.tag == .windows;

/// Namespace prefix of every local pipe path.
pub const pipe_prefix = "\\\\.\\pipe\\";
/// Prefix of every wmux pipe name (enumeration filter).
pub const name_prefix = "wmux-";
pub const launch_suffix = "-launch";
pub const alt_infix = "-alt-";
pub const legacy_prefix = "wmux-ipc-";
/// Windows caps the full pipe path at 256 characters.
pub const max_path_len = 256;

pub const Error = error{ InvalidChannel, InvalidSidHash, TooLong, OutOfMemory };

/// Lowercase hex of the first 4 bytes of SHA-256(UTF-8 user SID string).
pub fn sidHash8(sid_utf8: []const u8) [8]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sid_utf8, &digest, .{});
    return std.fmt.bytesToHex(digest[0..4].*, .lower);
}

fn isHash8(s: []const u8) bool {
    if (s.len != 8) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`. `channel` must already be
/// sanitized (`channel.isValid`).
pub fn controlName(gpa: Allocator, channel: []const u8, sidhash8: []const u8, session: u32) Error![]u8 {
    if (!channel_mod.isValid(channel)) return error.InvalidChannel;
    if (!isHash8(sidhash8)) return error.InvalidSidHash;
    return std.fmt.allocPrint(gpa, pipe_prefix ++ name_prefix ++ "{s}-{s}-s{d}", .{ channel, sidhash8, session });
}

/// Launch pipe: control name + `-launch`.
pub fn launchName(gpa: Allocator, control: []const u8) Error![]u8 {
    if (control.len + launch_suffix.len > max_path_len) return error.TooLong;
    return std.mem.concat(gpa, u8, &.{ control, launch_suffix });
}

/// Squatting fallback: control name + `-alt-<8hex>`.
pub fn altName(gpa: Allocator, control: []const u8, random_bytes: [4]u8) Error![]u8 {
    if (control.len + alt_infix.len + 8 > max_path_len) return error.TooLong;
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.mem.concat(gpa, u8, &.{ control, alt_infix, &hex });
}

/// Legacy pipe `\\.\pipe\wmux-ipc-<pid>` (one release).
pub fn legacyName(gpa: Allocator, pid: u32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, pipe_prefix ++ legacy_prefix ++ "{d}", .{pid});
}

/// Bare name part of a pipe path (prefix matched case-insensitively, either
/// slash direction); `s` itself when it has no prefix.
pub fn bareName(s: []const u8) []const u8 {
    if (s.len < pipe_prefix.len) return s;
    for (s[0..pipe_prefix.len], pipe_prefix) |a, b| {
        const ok = if (b == '\\') (a == '\\' or a == '/') else std.ascii.toLower(a) == b;
        if (!ok) return s;
    }
    return s[pipe_prefix.len..];
}

/// Explicit `--socket`/env values: accepts `\\.\pipe\name` (any case, `/`
/// or `\`) or a bare `name`, returns the canonical full path. Explicit paths
/// are otherwise used verbatim (never rerouted).
pub fn normalize(gpa: Allocator, s: []const u8) error{ Empty, InvalidName, TooLong, OutOfMemory }![]u8 {
    const name = bareName(s);
    if (name.len == 0) return error.Empty;
    if (std.mem.indexOfScalar(u8, name, '\\') != null or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidName;
    if (pipe_prefix.len + name.len > max_path_len) return error.TooLong;
    return std.mem.concat(gpa, u8, &.{ pipe_prefix, name });
}

pub const Parsed = struct {
    channel: []const u8,
    sidhash8: []const u8,
    session: u32,
    /// `-alt-<8hex>` suffix, without the infix.
    alt: ?[]const u8 = null,
    launch: bool = false,
};

/// Parses a control/launch/alt name (full path or bare):
/// `wmux-<channel>-<8hex>-s<session>[-alt-<8hex>][-launch]`.
pub fn parse(s: []const u8) ?Parsed {
    var name = bareName(s);
    if (!std.mem.startsWith(u8, name, name_prefix)) return null;
    name = name[name_prefix.len..];
    var out: Parsed = .{ .channel = undefined, .sidhash8 = undefined, .session = 0 };
    if (std.mem.endsWith(u8, name, launch_suffix)) {
        out.launch = true;
        name = name[0 .. name.len - launch_suffix.len];
    }
    if (name.len > alt_infix.len + 8 and std.mem.eql(u8, name[name.len - 8 - alt_infix.len ..][0..alt_infix.len], alt_infix)) {
        const hex = name[name.len - 8 ..];
        if (isHash8(hex)) {
            out.alt = hex;
            name = name[0 .. name.len - 8 - alt_infix.len];
        }
    }
    // ...-<8hex>-s<digits>
    const dash_s = std.mem.lastIndexOf(u8, name, "-s") orelse return null;
    const digits = name[dash_s + 2 ..];
    if (digits.len == 0 or digits.len > 10) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    out.session = std.fmt.parseInt(u32, digits, 10) catch return null;
    const head = name[0..dash_s];
    if (head.len < 10 or head[head.len - 9] != '-') return null;
    out.sidhash8 = head[head.len - 8 ..];
    if (!isHash8(out.sidhash8)) return null;
    out.channel = head[0 .. head.len - 9];
    if (!channel_mod.isValid(out.channel)) return null;
    return out;
}

/// PID of a legacy `wmux-ipc-<pid>` pipe name (full path or bare).
pub fn parseLegacy(s: []const u8) ?u32 {
    const name = bareName(s);
    if (!std.mem.startsWith(u8, name, legacy_prefix)) return null;
    const digits = name[legacy_prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// Enumeration filter for `\\.\pipe\wmux-*` (case-insensitive, as the pipe
/// namespace is).
pub fn isWmuxPipe(s: []const u8) bool {
    const name = bareName(s);
    return name.len > name_prefix.len and std.ascii.startsWithIgnoreCase(name, name_prefix);
}

const testing = std.testing;

test "unit: proto: pipe_name sidhash8 is sha256 prefix" {
    // SHA-256("abc") = ba7816bf...
    try testing.expectEqualStrings("ba7816bf", &sidHash8("abc"));
    // SHA-256("") = e3b0c442...
    try testing.expectEqualStrings("e3b0c442", &sidHash8(""));
    const h = sidHash8("S-1-5-21-3623811015-3361044348-30300820-1013");
    try testing.expect(isHash8(&h));
}

test "unit: proto: pipe_name control launch alt legacy" {
    const gpa = testing.allocator;
    const c = try controlName(gpa, "stable", "3f9c1a0b", 1);
    defer gpa.free(c);
    try testing.expectEqualStrings("\\\\.\\pipe\\wmux-stable-3f9c1a0b-s1", c);
    const l = try launchName(gpa, c);
    defer gpa.free(l);
    try testing.expectEqualStrings("\\\\.\\pipe\\wmux-stable-3f9c1a0b-s1-launch", l);
    const a = try altName(gpa, c, .{ 0xde, 0xad, 0xbe, 0xef });
    defer gpa.free(a);
    try testing.expectEqualStrings("\\\\.\\pipe\\wmux-stable-3f9c1a0b-s1-alt-deadbeef", a);
    const g = try legacyName(gpa, 4242);
    defer gpa.free(g);
    try testing.expectEqualStrings("\\\\.\\pipe\\wmux-ipc-4242", g);
    try testing.expectEqual(@as(?u32, 4242), parseLegacy(g));
}

test "unit: proto: pipe_name control rejects bad inputs" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidChannel, controlName(gpa, "Stable", "3f9c1a0b", 1));
    try testing.expectError(error.InvalidChannel, controlName(gpa, "", "3f9c1a0b", 1));
    try testing.expectError(error.InvalidChannel, controlName(gpa, "a\\b", "3f9c1a0b", 1));
    try testing.expectError(error.InvalidSidHash, controlName(gpa, "stable", "3F9C1A0B", 1));
    try testing.expectError(error.InvalidSidHash, controlName(gpa, "stable", "3f9c1a0", 1));
    const long = "\\\\.\\pipe\\" ++ "x" ** 248;
    try testing.expectError(error.TooLong, launchName(gpa, long));
    try testing.expectError(error.TooLong, altName(gpa, long, .{ 0, 0, 0, 0 }));
}

test "unit: proto: pipe_name parse round trip" {
    const gpa = testing.allocator;
    const channels = [_][]const u8{ "stable", "debug", "dev-my-s1-branch", "test-0a1b2c3d", "a" ** 40 };
    for (channels) |ch| {
        for ([_]u32{ 0, 1, 4294967295 }) |session| {
            const c = try controlName(gpa, ch, "0123abcd", session);
            defer gpa.free(c);
            const p = parse(c).?;
            try testing.expectEqualStrings(ch, p.channel);
            try testing.expectEqualStrings("0123abcd", p.sidhash8);
            try testing.expectEqual(session, p.session);
            try testing.expect(!p.launch and p.alt == null);

            const a = try altName(gpa, c, .{ 1, 2, 3, 4 });
            defer gpa.free(a);
            const l = try launchName(gpa, a);
            defer gpa.free(l);
            const pl = parse(l).?;
            try testing.expect(pl.launch);
            try testing.expectEqualStrings("01020304", pl.alt.?);
            try testing.expectEqualStrings(ch, pl.channel);
            try testing.expectEqual(session, pl.session);
        }
    }
}

test "unit: proto: pipe_name parse rejects malformed" {
    const bad = [_][]const u8{
        "",
        "wmux-",
        "wmux-stable",
        "wmux-stable-3f9c1a0b",
        "wmux-stable-3f9c1a0b-s",
        "wmux-stable-3f9c1a0b-sx",
        "wmux-stable-3f9c1a0b-s4294967296",
        "wmux-stable-3F9C1A0B-s1",
        "wmux-stable3f9c1a0b-s1",
        "wmux--3f9c1a0b-s1",
        "wmux-Stable-3f9c1a0b-s1",
        "wmux-ipc-1234",
        "cmux-stable-3f9c1a0b-s1",
        "\\\\.\\pipe\\wmux-st\u{e4}ble-3f9c1a0b-s1",
    };
    for (bad) |s| try testing.expectEqual(@as(?Parsed, null), parse(s));
    // A malformed alt suffix does not parse as anything.
    try testing.expectEqual(@as(?Parsed, null), parse("wmux-stable-3f9c1a0b-s1-alt-XYZ"));
}

test "unit: proto: pipe_name normalize explicit paths" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "wmux-stable-3f9c1a0b-s1", "\\\\.\\pipe\\wmux-stable-3f9c1a0b-s1" },
        .{ "\\\\.\\pipe\\x", "\\\\.\\pipe\\x" },
        .{ "//./PIPE/x", "\\\\.\\pipe\\x" },
        .{ "\\\\.\\Pipe\\caf\u{e9}", "\\\\.\\pipe\\caf\u{e9}" },
        .{ "my pipe", "\\\\.\\pipe\\my pipe" },
    };
    for (cases) |c| {
        const got = try normalize(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    try testing.expectError(error.Empty, normalize(gpa, ""));
    try testing.expectError(error.Empty, normalize(gpa, "\\\\.\\pipe\\"));
    try testing.expectError(error.InvalidName, normalize(gpa, "a\\b"));
    try testing.expectError(error.InvalidName, normalize(gpa, "\\\\.\\pipe\\a\\b"));
    try testing.expectError(error.InvalidName, normalize(gpa, "a\x00b"));
    try testing.expectError(error.TooLong, normalize(gpa, "x" ** 248));
    const ok = try normalize(gpa, "x" ** 247);
    gpa.free(ok);
}

test "unit: proto: pipe_name legacy and enumeration filters" {
    try testing.expectEqual(@as(?u32, 7), parseLegacy("wmux-ipc-7"));
    try testing.expectEqual(@as(?u32, null), parseLegacy("wmux-ipc-"));
    try testing.expectEqual(@as(?u32, null), parseLegacy("wmux-ipc-7a"));
    try testing.expectEqual(@as(?u32, null), parseLegacy("wmux-ipc-99999999999"));
    try testing.expect(isWmuxPipe("\\\\.\\pipe\\wmux-stable-3f9c1a0b-s1"));
    try testing.expect(isWmuxPipe("WMUX-ipc-1"));
    try testing.expect(!isWmuxPipe("wmux-"));
    try testing.expect(!isWmuxPipe("cmux-x"));
    try testing.expectEqualStrings("abc", bareName("\\\\.\\pipe\\abc"));
    try testing.expectEqualStrings("\\\\.\\pip", bareName("\\\\.\\pip"));
}
