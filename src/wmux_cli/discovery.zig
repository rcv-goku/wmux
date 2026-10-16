//! Control-pipe discovery (ADR-4.5, cli-socket-path-resolution,
//! cli-socket-env-overrides). Resolution order, first live candidate wins:
//!
//! 1. `--socket` (explicit, used verbatim, never probed or rerouted).
//! 2. `WMUX_SOCKET_PATH`, then `CMUX_SOCKET_PATH` (explicit). `CMUX_SOCKET` is
//!    the deprecated alias: used when neither is set, and an error when it is
//!    set non-empty and differs from the effective path (checked before any
//!    connection; `--socket` skips the check).
//! 3. The marker `STATE\run\instance.json` of the CLI's channel.
//! 4. The computed control name of the CLI's channel (the expected default),
//!    then of `stable`.
//! 5. The legacy `\\.\pipe\wmux-ipc-<GHOSTTY_PID>`.
//! 6. Enumerated `\\.\pipe\wmux-*` pipes of the caller's user: same logon
//!    session first, own channel first, then by name; launch pipes and other
//!    users' names are skipped.
//!
//! Implicit candidates are probed with a real connect (`Platform.connect`
//! retries busy pipes and checks the server's owner SID); the winning
//! connection is handed to the client. Picking anything but the expected
//! default prints `cmux: default socket <a> is unavailable; using <b>.`;
//! when nothing is live the CLI prints `No live wmux socket found. Tried:`
//! and one indented line per candidate.

const std = @import("std");
const proto = @import("wmux_proto");
const pipe_name = proto.pipe_name;
const env_names = proto.env_names;
const paths = proto.paths;
const Env = env_names.Env;
const Allocator = std.mem.Allocator;
const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;
const Transport = platform_mod.Transport;
const Brand = @import("brand.zig").Brand;

pub const Source = enum {
    flag,
    env,
    marker,
    default,
    stable_default,
    legacy_pid,
    enumerated,
};

pub const Inputs = struct {
    /// `--socket` value.
    explicit_socket: ?[]const u8 = null,
    env: Env,
    /// The CLI's resolved channel (`channel.resolveFromEnv`).
    channel: []const u8,
    /// Caller's user SID string; null when unknown (no computed names).
    user_sid: ?[]const u8 = null,
    /// Caller's logon session; null when unknown.
    session: ?u32 = null,
    /// `STATE` for the CLI's channel; null when no base variable is set.
    state_dir: ?[]const u8 = null,
    connect_timeout_ms: u32 = 2_000,
};

pub const Explicit = struct {
    path: []const u8,
    source: Source,
};

pub const Candidate = struct {
    path: []const u8,
    source: Source,
};

pub const Tried = struct {
    path: []const u8,
    reason: []const u8,
    err: platform_mod.ConnectError = error.NotFound,
};

pub const Live = struct {
    path: []const u8,
    source: Source,
    transport: Transport,
    /// The expected default, when another candidate won.
    unavailable_default: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    /// `--socket` or an environment path; connect to it directly.
    explicit: Explicit,
    /// A probed, connected implicit candidate.
    live: Live,
    /// Usage-level failure before any connection (message).
    rejected: []const u8,
    /// No implicit candidate was live.
    none: []const Tried,
};

/// `--socket` precedence and the environment rules (steps 1-2). Returns
/// null for implicit discovery; `rejected` for a conflict or a malformed
/// name.
pub fn explicitPath(arena: Allocator, in: Inputs) Allocator.Error!?Outcome {
    if (in.explicit_socket) |s| return try normalized(arena, s, .flag, "--socket");
    const env_path = in.env.getNonEmpty(env_names.WMUX_SOCKET_PATH) orelse in.env.getNonEmpty(env_names.CMUX_SOCKET_PATH);
    const alias = in.env.getNonEmpty(env_names.CMUX_SOCKET);
    if (env_path) |p| {
        if (alias) |a| {
            if (!samePipe(a, p)) {
                return .{ .rejected = try std.fmt.allocPrint(
                    arena,
                    "CMUX_SOCKET ({s}) and CMUX_SOCKET_PATH ({s}) are both set and differ; unset the deprecated CMUX_SOCKET or make them equal",
                    .{ a, p },
                ) };
            }
        }
        return try normalized(arena, p, .env, "CMUX_SOCKET_PATH");
    }
    if (alias) |a| return try normalized(arena, a, .env, "CMUX_SOCKET");
    return null;
}

fn normalized(arena: Allocator, raw: []const u8, source: Source, what: []const u8) Allocator.Error!Outcome {
    const path = pipe_name.normalize(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Empty => return .{ .rejected = try std.fmt.allocPrint(arena, "{s} is empty", .{what}) },
        error.InvalidName => return .{ .rejected = try std.fmt.allocPrint(arena, "{s} is not a valid pipe name: {s}", .{ what, raw }) },
        error.TooLong => return .{ .rejected = try std.fmt.allocPrint(arena, "{s} is longer than 256 characters", .{what}) },
    };
    return .{ .explicit = .{ .path = path, .source = source } };
}

/// Pipe names compare case-insensitively, with or without the prefix.
pub fn samePipe(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(pipe_name.bareName(a), pipe_name.bareName(b));
}

/// The fields of `STATE\run\instance.json` the CLI uses (ADR-3.1).
pub const Marker = struct {
    pipe: []const u8 = "",
    launch_pipe: ?[]const u8 = null,
    pid: ?u32 = null,
    channel: ?[]const u8 = null,
    protocol: ?u32 = null,
};

/// Marker files larger than this are ignored.
pub const max_marker_bytes = 64 * 1024;

/// Parses a marker. Returns null for malformed JSON, a missing or
/// non-wmux pipe, a launch pipe, another channel or (when known) another
/// user's sidhash.
pub fn parseMarker(arena: Allocator, bytes: []const u8, channel: []const u8, sidhash8: ?[]const u8) ?Marker {
    if (bytes.len > max_marker_bytes) return null;
    const m = std.json.parseFromSliceLeaky(Marker, arena, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    const parsed = pipe_name.parse(m.pipe) orelse return null;
    if (parsed.launch) return null;
    if (!std.mem.eql(u8, parsed.channel, channel)) return null;
    if (m.channel) |c| if (!std.mem.eql(u8, c, channel)) return null;
    if (sidhash8) |h| if (!std.mem.eql(u8, parsed.sidhash8, h)) return null;
    return m;
}

/// Reads the marker of `in.channel` through `platform`.
pub fn readMarker(arena: Allocator, platform: Platform, in: Inputs, sidhash8: ?[]const u8) Allocator.Error!?Marker {
    const state = in.state_dir orelse return null;
    const file = try paths.runFile(arena, paths.Style.native, state, paths.files.instance_json);
    const bytes = platform.readFile(arena, file, max_marker_bytes) orelse return null;
    return parseMarker(arena, bytes, in.channel, sidhash8);
}

fn rankEnumerated(p: pipe_name.Parsed, channel: []const u8, session: ?u32) u8 {
    var r: u8 = 0;
    if (session == null or p.session != session.?) r += 2;
    if (!std.mem.eql(u8, p.channel, channel)) r += 1;
    return r;
}

const Ranked = struct { path: []const u8, rank: u8 };

fn rankedLess(_: void, a: Ranked, b: Ranked) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// The default (expected) control name for `in.channel`, when the SID and
/// session are known.
pub fn defaultPath(arena: Allocator, in: Inputs) Allocator.Error!?[]const u8 {
    const sid = in.user_sid orelse return null;
    const session = in.session orelse return null;
    const h = pipe_name.sidHash8(sid);
    return pipe_name.controlName(arena, in.channel, &h, session) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// The implicit candidates in probe order, de-duplicated.
pub fn candidates(arena: Allocator, platform: Platform, in: Inputs) Allocator.Error![]const Candidate {
    var list: std.ArrayList(Candidate) = .empty;
    const hash: ?[8]u8 = if (in.user_sid) |sid| pipe_name.sidHash8(sid) else null;
    const hash_slice: ?[]const u8 = if (hash) |*h| h else null;

    if (try readMarker(arena, platform, in, hash_slice)) |m| {
        if (pipe_name.normalize(arena, m.pipe)) |p| {
            try appendUnique(arena, &list, p, .marker);
        } else |_| {}
    }
    if (try defaultPath(arena, in)) |p| try appendUnique(arena, &list, p, .default);
    if (hash != null and in.session != null and !std.mem.eql(u8, in.channel, proto.channel.stable)) {
        if (pipe_name.controlName(arena, proto.channel.stable, hash_slice.?, in.session.?)) |p| {
            try appendUnique(arena, &list, p, .stable_default);
        } else |_| {}
    }
    if (in.env.getNonEmpty(env_names.GHOSTTY_PID)) |pid_text| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, pid_text, " "), 10)) |pid| {
            try appendUnique(arena, &list, try pipe_name.legacyName(arena, pid), .legacy_pid);
        } else |_| {}
    }

    const names = try platform.enumeratePipes(arena);
    var ranked: std.ArrayList(Ranked) = .empty;
    for (names) |raw| {
        if (!pipe_name.isWmuxPipe(raw)) continue;
        const full = pipe_name.normalize(arena, raw) catch continue;
        if (pipe_name.parse(full)) |p| {
            if (p.launch) continue;
            if (hash_slice) |h| if (!std.mem.eql(u8, p.sidhash8, h)) continue;
            try ranked.append(arena, .{ .path = full, .rank = rankEnumerated(p, in.channel, in.session) });
        } else if (pipe_name.parseLegacy(full) != null) {
            try ranked.append(arena, .{ .path = full, .rank = 4 });
        }
    }
    std.mem.sort(Ranked, ranked.items, {}, rankedLess);
    for (ranked.items) |r| try appendUnique(arena, &list, r.path, .enumerated);
    return list.items;
}

fn appendUnique(arena: Allocator, list: *std.ArrayList(Candidate), path: []const u8, source: Source) Allocator.Error!void {
    for (list.items) |c| if (samePipe(c.path, path)) return;
    try list.append(arena, .{ .path = path, .source = source });
}

/// Full resolution. `live.transport` is owned by the caller.
pub fn resolve(arena: Allocator, platform: Platform, in: Inputs) Allocator.Error!Outcome {
    if (try explicitPath(arena, in)) |o| return o;
    const cands = try candidates(arena, platform, in);
    const default = try defaultPath(arena, in);
    var tried: std.ArrayList(Tried) = .empty;
    for (cands) |c| {
        if (platform.connect(arena, c.path, in.connect_timeout_ms)) |t| {
            var live: Live = .{ .path = c.path, .source = c.source, .transport = t };
            if (default) |d| if (!samePipe(d, c.path)) {
                live.unavailable_default = d;
            };
            return .{ .live = live };
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try tried.append(arena, .{ .path = c.path, .reason = platform_mod.connectErrorText(err), .err = err });
        }
    }
    return .{ .none = tried.items };
}

/// `cmux: default socket <a> is unavailable; using <b>.`
pub fn writeFallbackNotice(w: *std.Io.Writer, brand: Brand, default: []const u8, used: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}: default socket {s} is unavailable; using {s}.\n", .{ brand.name(), default, used });
}

/// `No live wmux socket found. Tried:` plus one indented line per candidate.
pub fn writeNoneFound(w: *std.Io.Writer, tried: []const Tried) std.Io.Writer.Error!void {
    try w.writeAll("No live wmux socket found. Tried:\n");
    if (tried.len == 0) {
        try w.writeAll("  (no candidates: the user SID, logon session and STATE directory are unknown, and no wmux pipe is listed)\n");
        return;
    }
    for (tried) |t| try w.print("  {s} ({s})\n", .{ t.path, t.reason });
}

// ----- tests -----

const testing = std.testing;
const fake = @import("fake.zig");

const test_sid = "S-1-5-21-1-2-3-1001";

fn hashOf(s: []const u8) [8]u8 {
    return pipe_name.sidHash8(s);
}

fn ctrl(arena: Allocator, channel: []const u8, session: u32) []const u8 {
    const h = hashOf(test_sid);
    return pipe_name.controlName(arena, channel, &h, session) catch unreachable;
}

test "unit: cli-discovery: --socket wins and is used verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    const pairs: []const Env.Pair = &.{ .{ "CMUX_SOCKET_PATH", "b" }, .{ "CMUX_SOCKET", "c" } };
    const o = try resolve(a, fp.platform(), .{ .explicit_socket = "my-pipe", .env = Env.fromPairs(&pairs), .channel = "stable" });
    try testing.expectEqualStrings("\\\\.\\pipe\\my-pipe", o.explicit.path);
    try testing.expectEqual(Source.flag, o.explicit.source);
    try testing.expectEqual(@as(usize, 0), fp.connects);
}

test "unit: cli-discovery: env path precedence and CMUX_SOCKET alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const both: []const Env.Pair = &.{ .{ "WMUX_SOCKET_PATH", "\\\\.\\pipe\\w" }, .{ "CMUX_SOCKET_PATH", "\\\\.\\pipe\\c" } };
    try testing.expectEqualStrings("\\\\.\\pipe\\w", (try explicitPath(a, .{ .env = Env.fromPairs(&both), .channel = "stable" })).?.explicit.path);
    const alias_only: []const Env.Pair = &.{.{ "CMUX_SOCKET", "//./pipe/old" }};
    try testing.expectEqualStrings("\\\\.\\pipe\\old", (try explicitPath(a, .{ .env = Env.fromPairs(&alias_only), .channel = "stable" })).?.explicit.path);
    // Equal values (any case or prefix spelling) are not a conflict.
    const same: []const Env.Pair = &.{ .{ "CMUX_SOCKET_PATH", "\\\\.\\pipe\\WMUX-x" }, .{ "CMUX_SOCKET", "wmux-x" } };
    try testing.expectEqual(Source.env, (try explicitPath(a, .{ .env = Env.fromPairs(&same), .channel = "stable" })).?.explicit.source);
    // Empty CMUX_SOCKET (what terminals export) never conflicts.
    const empty_alias: []const Env.Pair = &.{ .{ "CMUX_SOCKET_PATH", "p" }, .{ "CMUX_SOCKET", "" } };
    try testing.expectEqualStrings("\\\\.\\pipe\\p", (try explicitPath(a, .{ .env = Env.fromPairs(&empty_alias), .channel = "stable" })).?.explicit.path);
    try testing.expectEqual(@as(?Outcome, null), try explicitPath(a, .{ .env = Env.empty, .channel = "stable" }));
}

test "unit: cli-discovery: CMUX_SOCKET mismatch fails before connecting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    const pairs: []const Env.Pair = &.{ .{ "CMUX_SOCKET_PATH", "/b" }, .{ "CMUX_SOCKET", "/a" } };
    const o = try resolve(a, fp.platform(), .{ .env = Env.fromPairs(&pairs), .channel = "stable", .user_sid = test_sid, .session = 1 });
    try testing.expect(std.mem.indexOf(u8, o.rejected, "CMUX_SOCKET (/a) and CMUX_SOCKET_PATH (/b)") != null);
    try testing.expectEqual(@as(usize, 0), fp.connects);
    // --socket overrides both variables and skips the check.
    const o2 = try resolve(a, fp.platform(), .{ .explicit_socket = "y", .env = Env.fromPairs(&pairs), .channel = "stable" });
    try testing.expectEqualStrings("\\\\.\\pipe\\y", o2.explicit.path);
}

test "unit: cli-discovery: malformed explicit names are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o = (try explicitPath(a, .{ .explicit_socket = "a\\b", .env = Env.empty, .channel = "stable" })).?;
    try testing.expectEqualStrings("--socket is not a valid pipe name: a\\b", o.rejected);
    const long = "x" ** 300;
    const o2 = (try explicitPath(a, .{ .explicit_socket = long, .env = Env.empty, .channel = "stable" })).?;
    try testing.expectEqualStrings("--socket is longer than 256 characters", o2.rejected);
    const o3 = (try explicitPath(a, .{ .explicit_socket = "\\\\.\\pipe\\", .env = Env.empty, .channel = "stable" })).?;
    try testing.expectEqualStrings("--socket is empty", o3.rejected);
}

test "unit: cli-discovery: default control name is used with no notice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    var server = fake.Server.init(a);
    try fp.addServer(ctrl(a, "nightly", 1), &server);
    const o = try resolve(a, fp.platform(), .{ .env = Env.empty, .channel = "nightly", .user_sid = test_sid, .session = 1 });
    try testing.expectEqual(Source.default, o.live.source);
    try testing.expectEqual(@as(?[]const u8, null), o.live.unavailable_default);
    o.live.transport.close();
}

test "unit: cli-discovery: falls back to stable with the cmux notice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    var server = fake.Server.init(a);
    try fp.addServer(ctrl(a, "stable", 1), &server);
    const o = try resolve(a, fp.platform(), .{ .env = Env.empty, .channel = "debug", .user_sid = test_sid, .session = 1 });
    try testing.expectEqual(Source.stable_default, o.live.source);
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeFallbackNotice(&aw.writer, .wmux, o.live.unavailable_default.?, o.live.path);
    const h = hashOf(test_sid);
    const want = try std.fmt.allocPrint(a, "wmux: default socket \\\\.\\pipe\\wmux-debug-{s}-s1 is unavailable; using \\\\.\\pipe\\wmux-stable-{s}-s1.\n", .{ &h, &h });
    try testing.expectEqualStrings(want, aw.written());
}

test "unit: cli-discovery: marker comes first and is validated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    const h = hashOf(test_sid);
    const alt = try std.fmt.allocPrint(a, "\\\\.\\pipe\\wmux-stable-{s}-s1-alt-0badf00d", .{&h});
    const marker = try std.fmt.allocPrint(a, "{{\"pipe\":{f},\"pid\":4,\"protocol\":2,\"channel\":\"stable\",\"extra\":[1]}}", .{std.json.fmt(alt, .{})});
    try fp.addFile(try paths.runFile(a, paths.Style.native, "C:\\state", "instance.json"), marker);
    var server = fake.Server.init(a);
    try fp.addServer(alt, &server);
    const in: Inputs = .{ .env = Env.empty, .channel = "stable", .user_sid = test_sid, .session = 1, .state_dir = "C:\\state" };
    const cands = try candidates(a, fp.platform(), in);
    try testing.expectEqual(Source.marker, cands[0].source);
    try testing.expectEqualStrings(alt, cands[0].path);
    const o = try resolve(a, fp.platform(), in);
    try testing.expectEqual(Source.marker, o.live.source);
    // The squatting alt name is not the default, so the notice names both.
    try testing.expect(o.live.unavailable_default != null);
}

test "unit: cli-discovery: marker rejects other channels, users, launch pipes and junk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const h = hashOf(test_sid);
    const good = try std.fmt.allocPrint(a, "{{\"pipe\":\"\\\\\\\\.\\\\pipe\\\\wmux-stable-{s}-s1\"}}", .{&h});
    try testing.expect(parseMarker(a, good, "stable", &h) != null);
    try testing.expect(parseMarker(a, good, "nightly", &h) == null);
    try testing.expect(parseMarker(a, good, "stable", "00000000") == null);
    const launch = try std.fmt.allocPrint(a, "{{\"pipe\":\"wmux-stable-{s}-s1-launch\"}}", .{&h});
    try testing.expect(parseMarker(a, launch, "stable", &h) == null);
    const chan = try std.fmt.allocPrint(a, "{{\"pipe\":\"wmux-stable-{s}-s1\",\"channel\":\"nightly\"}}", .{&h});
    try testing.expect(parseMarker(a, chan, "stable", &h) == null);
    for ([_][]const u8{ "", "{", "[]", "{\"pipe\":5}", "{\"pipe\":\"cmux.sock\"}", "\xff\xfe" }) |junk| {
        try testing.expect(parseMarker(a, junk, "stable", &h) == null);
    }
    const huge = try a.alloc(u8, max_marker_bytes + 1);
    @memset(huge, ' ');
    try testing.expect(parseMarker(a, huge, "stable", &h) == null);
}

test "unit: cli-discovery: enumeration skips launch pipes and other users and ranks the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    const h = hashOf(test_sid);
    const other = hashOf("S-1-5-21-other");
    const names = [_][]const u8{
        try std.fmt.allocPrint(a, "wmux-zeta-{s}-s1", .{&h}),
        try std.fmt.allocPrint(a, "wmux-dev-x-{s}-s2", .{&h}),
        try std.fmt.allocPrint(a, "wmux-dev-x-{s}-s1-launch", .{&h}),
        try std.fmt.allocPrint(a, "wmux-dev-x-{s}-s1", .{&other}),
        try std.fmt.allocPrint(a, "wmux-dev-x-{s}-s1", .{&h}),
        "wmux-ipc-77",
        "chrome.sync",
        "WMUX-garbage",
    };
    for (names) |n| try fp.enumerated.append(a, n);
    const cands = try candidates(a, fp.platform(), .{ .env = Env.empty, .channel = "dev-x", .user_sid = test_sid, .session = 1 });
    // default (dev-x s1), stable s1, then enumerated: zeta s1 (rank 1), dev-x s2 (rank 2), legacy.
    var enumerated: std.ArrayList([]const u8) = .empty;
    for (cands) |c| if (c.source == .enumerated) try enumerated.append(a, pipe_name.bareName(c.path));
    try testing.expectEqual(@as(usize, 3), enumerated.items.len);
    try testing.expectEqualStrings(names[0], enumerated.items[0]);
    try testing.expectEqualStrings(names[1], enumerated.items[1]);
    try testing.expectEqualStrings("wmux-ipc-77", enumerated.items[2]);
    try testing.expectEqual(Source.default, cands[0].source);
    try testing.expectEqual(Source.stable_default, cands[1].source);
}

test "unit: cli-discovery: nothing live lists every candidate tried" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    try fp.addFailure("\\\\.\\pipe\\wmux-ipc-42", error.ForeignOwner);
    const pairs: []const Env.Pair = &.{.{ "GHOSTTY_PID", "42" }};
    const o = try resolve(a, fp.platform(), .{ .env = Env.fromPairs(&pairs), .channel = "stable", .user_sid = test_sid, .session = 3 });
    try testing.expectEqual(@as(usize, 2), o.none.len);
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeNoneFound(&aw.writer, o.none);
    const want = try std.fmt.allocPrint(a,
        \\No live wmux socket found. Tried:
        \\  {s} (not found)
        \\  \\.\pipe\wmux-ipc-42 (server not owned by the current user)
        \\
    , .{ctrl(a, "stable", 3)});
    try testing.expectEqualStrings(want, aw.written());
}

test "unit: cli-discovery: no SID and no pipes still reports clearly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fp = fake.Platform.init(a);
    const pairs: []const Env.Pair = &.{.{ "GHOSTTY_PID", "not-a-pid" }};
    const o = try resolve(a, fp.platform(), .{ .env = Env.fromPairs(&pairs), .channel = "stable" });
    try testing.expectEqual(@as(usize, 0), o.none.len);
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeNoneFound(&aw.writer, o.none);
    try testing.expect(std.mem.startsWith(u8, aw.written(), "No live wmux socket found. Tried:\n  (no candidates"));
}
