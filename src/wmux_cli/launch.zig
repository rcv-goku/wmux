//! Launch-if-needed and the launch pipe (ADR-3.1, ADR-4.3 step 4, ADR-4.9,
//! cli-app-launch-if-needed). When no instance is live, launch-capable
//! commands start `INSTALL\wmux.exe` detached (no inherited handles, no
//! arguments, `WMUX_ARGV0` removed from its environment) and wait for the
//! pipe, re-resolving with backoff. The wait is 30 s;
//! `WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS`/`CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS`
//! can shorten it, never lengthen it. The expected control pipe owned by
//! another user or denied by its DACL is a permanent conflict and fails at
//! once. Other socket commands fail fast with the discovery error.
//!
//! `cmux <path>` sends `app.launch {intent:"open", argv, cwd, paths, focus,
//! foreground_grant}` over the launch pipe (`<control>-launch`), which needs
//! no control-socket access. An interactive (focusing) request first calls
//! `AllowSetForegroundWindow(server_pid)` and then sets `foreground_grant`
//! (ADR-3.11, ADR-4.6).

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const pipe_name = proto.pipe_name;
const paths = proto.paths;
const Env = env_names.Env;
const Allocator = std.mem.Allocator;
const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;
const discovery = @import("discovery.zig");
const child_env = @import("child_env.zig");
const client_mod = @import("client.zig");
const command = @import("command.zig");
const focus_default = @import("focus_default.zig");
const output = @import("output.zig");

pub const default_wait_ms: u32 = 30_000;
const first_backoff_ms: u64 = 50;
const max_backoff_ms: u64 = 500;

/// The startup wait: 30 s unless the environment asks for less.
pub fn startupWaitMs(env: Env) u32 {
    for ([_][]const u8{ env_names.WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS, env_names.CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS }) |n| {
        if (env.getNonEmpty(n)) |v| if (client_mod.parseSecondsMs(v)) |ms| return @min(ms, default_wait_ms);
    }
    return default_wait_ms;
}

/// `INSTALL\wmux.exe` for a CLI at `INSTALL\cli\cmux.exe`; null when the CLI
/// does not live in a `cli` directory. A copy elsewhere (for example one
/// renamed to `wmux.exe`) would otherwise start or relay to itself.
pub fn guiExePath(arena: Allocator, cli_exe: []const u8) Allocator.Error!?[]const u8 {
    const style = paths.Style.native;
    const dir = paths.dirname(style, cli_exe) orelse return null;
    const dir_name = paths.basename(style, dir);
    const in_cli = if (style == .windows) std.ascii.eqlIgnoreCase(dir_name, paths.dirs.cli) else std.mem.eql(u8, dir_name, paths.dirs.cli);
    if (!in_cli) return null;
    const install = paths.dirname(style, dir) orelse return null;
    return try paths.join(arena, style, &.{ install, paths.files.gui_exe });
}

/// Starts the GUI detached with a sanitized copy of `env`.
pub fn spawnApp(arena: Allocator, platform: Platform, gui: []const u8, env: ?*const std.process.EnvMap) !void {
    var map = std.process.EnvMap.init(arena);
    if (env) |src| {
        var it = src.iterator();
        while (it.next()) |e| try map.put(e.key_ptr.*, e.value_ptr.*);
    }
    try child_env.sanitize(&map);
    try platform.spawnDetached(arena, &.{gui}, &map);
}

fn isPermanent(err: platform_mod.ConnectError) bool {
    return err == error.ForeignOwner or err == error.AccessDenied;
}

fn startFailure(arena: Allocator, comptime fmt: []const u8, a: anytype) Allocator.Error!discovery.Outcome {
    return .{ .rejected = try std.fmt.allocPrint(arena, fmt, a) };
}

/// Starts wmux and waits for a live control pipe (implicit discovery only).
pub fn ensureControl(ctx: *command.Ctx, in: discovery.Inputs) !discovery.Outcome {
    const arena = ctx.arena;
    const platform = ctx.platform;
    const self_exe = platform.selfExePath(arena) orelse return startFailure(arena, "cannot start wmux: the CLI's own path is unknown", .{});
    const gui = (try guiExePath(arena, self_exe)) orelse return startFailure(arena, "cannot start wmux: {s} is not inside INSTALL\\cli", .{self_exe});
    spawnApp(arena, platform, gui, ctx.env_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return startFailure(arena, "cannot start {s}", .{gui}),
    };
    const wait = startupWaitMs(ctx.env);
    const deadline = platform.nowMs() + wait;
    // Only the pipe the new instance will claim can be a permanent conflict;
    // other candidates (another user's legacy pipe, other sessions) must not
    // cut the wait short.
    const expected = try discovery.defaultPath(arena, in);
    var backoff = first_backoff_ms;
    while (true) {
        const o = try discovery.resolve(arena, platform, in);
        switch (o) {
            .none => |tried| for (tried) |t| {
                if (!isPermanent(t.err)) continue;
                if (expected) |e| if (discovery.samePipe(t.path, e)) return o;
            },
            else => return o,
        }
        const now = platform.nowMs();
        if (now >= deadline) break;
        platform.sleepMs(@min(backoff, @as(u64, @intCast(deadline - now))));
        backoff = @min(backoff * 2, max_backoff_ms);
    }
    return startFailure(arena, "wmux did not start within {d}s ({s}); its control pipe never appeared", .{ @as(f64, @floatFromInt(wait)) / 1000.0, gui });
}

/// The launch pipe for this user/session/channel: the marker's
/// `launch_pipe` when present, else `<default control>-launch`.
pub fn launchPipePath(arena: Allocator, platform: Platform, in: discovery.Inputs) Allocator.Error!?[]const u8 {
    const hash: ?[8]u8 = if (in.user_sid) |sid| pipe_name.sidHash8(sid) else null;
    if (try discovery.readMarker(arena, platform, in, if (hash) |*h| h else null)) |m| {
        if (m.launch_pipe) |lp| if (pipe_name.normalize(arena, lp)) |p| return p else |_| {};
    }
    const control = (try discovery.defaultPath(arena, in)) orelse return null;
    return pipe_name.launchName(arena, control) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

pub const Intent = enum { open, new_window, activate, uri };

pub const LaunchRequest = struct {
    intent: Intent,
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    uri: ?[]const u8 = null,
    focus: bool = false,
    /// Set by `sendLaunch` once `AllowSetForegroundWindow(server_pid)` ran.
    foreground_grant: bool = false,
};

pub fn paramsJson(arena: Allocator, req: LaunchRequest) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .intent = @tagName(req.intent),
        .argv = req.argv,
        .cwd = req.cwd,
        .paths = req.paths,
        .uri = req.uri,
        .focus = req.focus,
        .foreground_grant = req.foreground_grant,
    }, .{});
}

/// Absolute form of `p` against `cwd` (no file-system access).
pub fn absolutize(arena: Allocator, cwd: ?[]const u8, p: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(p) or isWindowsAbsolute(p)) return p;
    const base = cwd orelse return p;
    return paths.join(arena, paths.Style.native, &.{ base, p });
}

fn isWindowsAbsolute(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return std.mem.startsWith(u8, p, "\\\\");
}

/// Sends one `app.launch`, starting wmux first when its launch pipe is
/// missing. Returns the exit code.
pub fn sendLaunch(ctx: *command.Ctx, req: LaunchRequest) !u8 {
    const arena = ctx.arena;
    const platform = ctx.platform;
    const in = try ctx.discoveryInputs();
    const path = (try launchPipePath(arena, platform, in)) orelse
        return ctx.runtimeError("cannot locate the wmux launch pipe (unknown user SID or logon session)", .{});
    const transport = platform.connect(arena, path, client_mod.default_connect_timeout_ms) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err != error.NotFound) return ctx.runtimeError("{s}", .{try client_mod.connectFailureMessage(arena, path, err)});
        const self_exe = platform.selfExePath(arena) orelse return ctx.runtimeError("cannot start wmux: the CLI's own path is unknown", .{});
        const gui = (try guiExePath(arena, self_exe)) orelse return ctx.runtimeError("cannot start wmux: {s} is not inside INSTALL\\cli", .{self_exe});
        spawnApp(arena, platform, gui, ctx.env_map) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.runtimeError("cannot start {s}", .{gui}),
        };
        const wait = startupWaitMs(ctx.env);
        const deadline = platform.nowMs() + wait;
        var backoff = first_backoff_ms;
        while (true) {
            if (platform.connect(arena, path, client_mod.default_connect_timeout_ms)) |t| break :blk t else |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (isPermanent(e)) return ctx.runtimeError("{s}", .{try client_mod.connectFailureMessage(arena, path, e)});
            }
            const now = platform.nowMs();
            if (now >= deadline) return ctx.runtimeError("wmux did not start within {d}s ({s}); its launch pipe never appeared", .{ @as(f64, @floatFromInt(wait)) / 1000.0, gui });
            platform.sleepMs(@min(backoff, @as(u64, @intCast(deadline - now))));
            backoff = @min(backoff * 2, max_backoff_ms);
        }
    };
    var sent = req;
    sent.foreground_grant = false;
    if (req.focus) if (transport.serverPid()) |pid| {
        platform.allowForeground(pid);
        sent.foreground_grant = true;
    };
    var c = client_mod.Client.init(arena, platform, .{ .path = path, .response_timeout_ms = client_mod.responseTimeoutMs(ctx.env) });
    defer c.deinit();
    c.adopt(transport);
    const out = try c.call(arena, "app.launch", try paramsJson(arena, sent), .{});
    switch (out) {
        .ok => |ok| {
            if (ctx.json()) try output.writeJson(ctx.out, ok.result);
            return output.exit.ok;
        },
        else => return ctx.reportError("app.launch", out),
    }
}

/// `cmux <path>...`: open existing paths through the launch pipe.
pub fn openPaths(ctx: *command.Ctx, raw: []const []const u8) !u8 {
    const cwd = ctx.platform.cwd(ctx.arena);
    var abs: std.ArrayList([]const u8) = .empty;
    for (raw) |p| try abs.append(ctx.arena, try absolutize(ctx.arena, cwd, p));
    const focus = focus_default.defaultFocus(ctx.platform.isInteractive(), ctx.env, ctx.env_names);
    return sendLaunch(ctx, .{ .intent = .open, .argv = raw, .cwd = cwd, .paths = abs.items, .focus = focus });
}

// ----- tests -----

const testing = std.testing;
const fake = @import("fake.zig");

test "unit: cli-launch: startup wait can only shorten" {
    try testing.expectEqual(default_wait_ms, startupWaitMs(Env.empty));
    const short: []const Env.Pair = &.{.{ "CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS", "5" }};
    try testing.expectEqual(@as(u32, 5000), startupWaitMs(Env.fromPairs(&short)));
    const long: []const Env.Pair = &.{.{ "WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS", "600" }};
    try testing.expectEqual(default_wait_ms, startupWaitMs(Env.fromPairs(&long)));
    const junk: []const Env.Pair = &.{ .{ "WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS", "-3" }, .{ "CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS", "0.5" } };
    try testing.expectEqual(@as(u32, 500), startupWaitMs(Env.fromPairs(&junk)));
}

test "unit: cli-launch: gui path sits next to the cli directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const style = paths.Style.native;
    const cli = try paths.join(a, style, &.{ "C:", "Programs", "wmux", "cli", "cmux.exe" });
    const want = try paths.join(a, style, &.{ "C:", "Programs", "wmux", "wmux.exe" });
    try testing.expectEqualStrings(want, (try guiExePath(a, cli)).?);
    const com = try paths.join(a, style, &.{ "C:", "Programs", "wmux", "cli", "wmux.com" });
    try testing.expectEqualStrings(want, (try guiExePath(a, com)).?);
}

test "unit: cli-launch: a CLI outside a cli directory has no gui to start" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const style = paths.Style.native;
    // A copy renamed to wmux.exe would otherwise relay to itself forever.
    for ([_][]const []const u8{
        &.{ "C:", "tools", "wmux.exe" },
        &.{ "C:", "tools", "cmux.exe" },
        &.{ "C:", "shims", "agents", "claude.exe" },
        &.{ "C:", "clients", "cmux.exe" },
    }) |parts| {
        try testing.expectEqual(@as(?[]const u8, null), try guiExePath(a, try paths.join(a, style, parts)));
    }
    try testing.expectEqual(@as(?[]const u8, null), try guiExePath(a, "cmux.exe"));
    try testing.expectEqual(@as(?[]const u8, null), try guiExePath(a, ""));
}

test "unit: cli-launch: params json and absolute paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const js = try paramsJson(a, .{ .intent = .open, .argv = &.{"x.md"}, .cwd = "C:\\w", .paths = &.{"C:\\w\\x.md"} });
    try testing.expectEqualStrings("{\"intent\":\"open\",\"argv\":[\"x.md\"],\"cwd\":\"C:\\\\w\",\"paths\":[\"C:\\\\w\\\\x.md\"],\"uri\":null,\"focus\":false,\"foreground_grant\":false}", js);
    try testing.expectEqualStrings("D:\\a", try absolutize(a, "C:\\w", "D:\\a"));
    try testing.expectEqualStrings("\\\\srv\\share", try absolutize(a, "C:\\w", "\\\\srv\\share"));
    try testing.expectEqualStrings("rel", try absolutize(a, null, "rel"));
}

/// A Ctx over a fake platform (shared with main.zig tests).
pub const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    env_map: std.process.EnvMap,
    ctx: command.Ctx,

    pub fn init(self: *TestCtx, pairs: *const []const Env.Pair) void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.fp.sid = "S-1-5-21-9";
        self.fp.session = 1;
        self.out = .init(a);
        self.err = .init(a);
        self.env_map = std.process.EnvMap.init(a);
        self.ctx = .{
            .gpa = a,
            .arena = a,
            .brand = .cmux,
            .parsed = .{},
            .command = "",
            .env = Env.fromPairs(pairs),
            .env_map = &self.env_map,
            .platform = self.fp.platform(),
            .out = &self.out.writer,
            .err = &self.err.writer,
            .channel = "stable",
            .version_summary = "cmux 0.0.0-test",
        };
    }

    pub fn deinit(self: *TestCtx) void {
        self.ctx.deinit();
        self.arena_state.deinit();
    }

    pub fn controlPath(self: *TestCtx) []const u8 {
        const h = pipe_name.sidHash8(self.fp.sid.?);
        return pipe_name.controlName(self.arena_state.allocator(), "stable", &h, self.fp.session.?) catch unreachable;
    }
};

fn selfExe(a: Allocator) []const u8 {
    return paths.join(a, paths.Style.native, &.{ "C:", "wmux", "cli", "cmux.exe" }) catch unreachable;
}

test "unit: cli-launch: ensureControl starts the app and waits for its pipe" {
    const pairs: []const Env.Pair = &.{};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    const a = t.arena_state.allocator();
    t.fp.self_exe = selfExe(a);
    try t.env_map.put("WMUX_ARGV0", "wmux");
    try t.env_map.put("WSLENV", "WMUX_ARGV0:FOO/u");
    var server = fake.Server.init(a);
    try t.fp.addOnSpawn(t.controlPath(), &server, 1200);
    const in = try t.ctx.discoveryInputs();
    const o = try ensureControl(&t.ctx, in);
    try testing.expect(o == .live);
    o.live.transport.close();
    try testing.expectEqual(@as(usize, 1), t.fp.spawned.items.len);
    const s = t.fp.spawned.items[0];
    try testing.expectEqualStrings(try paths.join(a, paths.Style.native, &.{ "C:", "wmux", "wmux.exe" }), s.argv[0]);
    try testing.expectEqual(@as(usize, 1), s.argv.len);
    try testing.expect(!s.had_argv0);
    try testing.expectEqualStrings("FOO/u", s.wslenv.?);
    try testing.expect(t.fp.slept_ms >= 1200 and t.fp.slept_ms < 2000);
}

test "unit: cli-launch: ensureControl gives up at the shortened deadline" {
    const pairs: []const Env.Pair = &.{.{ "CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS", "2" }};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    t.fp.self_exe = selfExe(t.arena_state.allocator());
    const in = try t.ctx.discoveryInputs();
    const o = try ensureControl(&t.ctx, in);
    try testing.expect(std.mem.startsWith(u8, o.rejected, "wmux did not start within 2s"));
    try testing.expectEqual(@as(u64, 2000), t.fp.slept_ms);
}

test "unit: cli-launch: a foreign-owned pipe is a permanent conflict" {
    const pairs: []const Env.Pair = &.{};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    t.fp.self_exe = selfExe(t.arena_state.allocator());
    try t.fp.addFailure(t.controlPath(), error.ForeignOwner);
    const in = try t.ctx.discoveryInputs();
    const o = try ensureControl(&t.ctx, in);
    try testing.expect(o == .none);
    try testing.expectEqual(@as(u64, 0), t.fp.slept_ms);
}

test "unit: cli-launch: unrelated refused pipes do not cut the startup wait short" {
    const pairs: []const Env.Pair = &.{};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    const a = t.arena_state.allocator();
    t.fp.self_exe = selfExe(a);
    // Another user's legacy pipe (machine-global namespace) denies access,
    // and an instance in another logon session fails the owner check.
    try t.fp.enumerated.append(a, "wmux-ipc-4711");
    try t.fp.addFailure("\\\\.\\pipe\\wmux-ipc-4711", error.AccessDenied);
    const own = pipe_name.sidHash8(t.fp.sid.?);
    const other_session = try pipe_name.controlName(a, "nightly", &own, 2);
    try t.fp.enumerated.append(a, pipe_name.bareName(other_session));
    try t.fp.addFailure(other_session, error.ForeignOwner);
    var server = fake.Server.init(a);
    try t.fp.addOnSpawn(t.controlPath(), &server, 700);
    const in = try t.ctx.discoveryInputs();
    const o = try ensureControl(&t.ctx, in);
    try testing.expect(o == .live);
    o.live.transport.close();
    try testing.expect(t.fp.slept_ms >= 700);
}

test "unit: cli-launch: spawn failure and unknown install are reported" {
    const pairs: []const Env.Pair = &.{};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    const in = try t.ctx.discoveryInputs();
    try testing.expect(std.mem.indexOf(u8, (try ensureControl(&t.ctx, in)).rejected, "own path is unknown") != null);
    t.fp.self_exe = "cmux.exe";
    try testing.expect(std.mem.indexOf(u8, (try ensureControl(&t.ctx, in)).rejected, "is not inside INSTALL\\cli") != null);
    t.fp.self_exe = selfExe(t.arena_state.allocator());
    t.fp.spawn_fails = true;
    try testing.expect(std.mem.startsWith(u8, (try ensureControl(&t.ctx, in)).rejected, "cannot start "));
}

fn launchHandler(_: *fake.Server, req: fake.Request) fake.Action {
    if (std.mem.eql(u8, req.method, "app.launch")) return .{ .ok = "{\"accepted\":true}" };
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

test "unit: cli-launch: open paths over the launch pipe, starting wmux first" {
    const pairs: []const Env.Pair = &.{};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    const a = t.arena_state.allocator();
    t.fp.self_exe = selfExe(a);
    t.fp.cwd_path = "C:\\work";
    t.fp.interactive = true;
    var server = fake.Server.init(a);
    server.handler = launchHandler;
    const launch_path = try pipe_name.launchName(a, t.controlPath());
    try t.fp.addOnSpawn(launch_path, &server, 300);
    const code = try openPaths(&t.ctx, &.{"README.md"});
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 1), t.fp.spawned.items.len);
    const req = server.requests.items[0];
    try testing.expectEqualStrings("app.launch", req.method);
    try testing.expectEqualStrings("open", req.params.object.get("intent").?.string);
    try testing.expect(req.params.object.get("focus").?.bool);
    // AllowSetForegroundWindow ran, so the request carries the grant.
    try testing.expect(req.params.object.get("foreground_grant").?.bool);
    try testing.expectEqual(@as(usize, 1), t.fp.foreground_grants.items.len);
    // No capability prefix on the launch pipe.
    try testing.expectEqual(@as(?[]const u8, null), req.capability);
}

test "unit: cli-launch: an agent caller opens in the background" {
    const pairs: []const Env.Pair = &.{.{ "CLAUDECODE", "1" }};
    var t: TestCtx = undefined;
    t.init(&pairs);
    defer t.deinit();
    const a = t.arena_state.allocator();
    t.fp.interactive = true;
    var server = fake.Server.init(a);
    server.handler = launchHandler;
    try t.fp.addServer(try pipe_name.launchName(a, t.controlPath()), &server);
    try testing.expectEqual(@as(u8, 0), try openPaths(&t.ctx, &.{"C:\\x"}));
    try testing.expect(!server.requests.items[0].params.object.get("focus").?.bool);
    try testing.expect(!server.requests.items[0].params.object.get("foreground_grant").?.bool);
    try testing.expectEqual(@as(usize, 0), t.fp.foreground_grants.items.len);
    try testing.expectEqual(@as(usize, 0), t.fp.spawned.items.len);
}
