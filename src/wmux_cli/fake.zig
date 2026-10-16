//! In-memory test doubles for `platform.zig` (ADR-12.1): a scripted v2 pipe
//! server and a fake platform with a virtual clock, files, enumerated pipes,
//! stdin and spawn recording. Everything lives in the caller's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform_mod = @import("platform.zig");
const proto = @import("wmux_proto");
const envelope = proto.envelope;

/// One request line as the server received it.
pub const Request = struct {
    raw: []const u8,
    capability: ?[]const u8,
    id: []const u8,
    method: []const u8,
    /// Minified params JSON (`{}` when absent).
    params_json: []const u8,
    params: std.json.Value,
};

/// What the server does with a request.
pub const Action = union(enum) {
    /// `{"id":<id>,"ok":true,"result":<json>}`.
    ok: []const u8,
    /// `{"id":<id>,"ok":false,"error":<json>}`.
    err: []const u8,
    /// A literal reply line (newline appended).
    raw: []const u8,
    /// A success reply whose id is not the request's.
    ok_wrong_id: []const u8,
    /// Close the connection without replying.
    close,
    /// Never reply (reads time out).
    stall,
};

pub const Handler = *const fn (server: *Server, req: Request) Action;

pub const Server = struct {
    a: Allocator,
    handler: Handler = pingHandler,
    /// Free-form test state for handlers.
    user: ?*anyopaque = null,
    inbox: std.ArrayList(u8) = .empty,
    outbox: std.ArrayList(u8) = .empty,
    out_pos: usize = 0,
    /// Max bytes returned per read (exercises partial reads).
    chunk: usize = 1 << 20,
    closed: bool = false,
    stalled: bool = false,
    requests: std.ArrayList(Request) = .empty,
    clock: ?*i64 = null,
    connections: usize = 0,
    /// The next `reject_connections` connections are refused at admission
    /// (ADR-3.3): `reject_line`, when not empty, is queued and the pipe is
    /// closed before any request is read, so the client's write fails.
    reject_connections: usize = 0,
    reject_line: []const u8 = "",

    pub fn init(a: Allocator) Server {
        return .{ .a = a };
    }

    fn reset(self: *Server) Allocator.Error!void {
        self.inbox.clearRetainingCapacity();
        self.outbox.clearRetainingCapacity();
        self.out_pos = 0;
        self.closed = false;
        self.stalled = false;
        self.connections += 1;
        if (self.reject_connections > 0) {
            self.reject_connections -= 1;
            if (self.reject_line.len > 0) {
                try self.outbox.appendSlice(self.a, self.reject_line);
                try self.outbox.append(self.a, '\n');
            }
            self.closed = true;
        }
    }

    pub fn transport(self: *Server) platform_mod.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform_mod.Transport.VTable = .{
        .write = write,
        .read = read,
        .serverPid = serverPid,
        .close = close,
    };

    fn write(ptr: *anyopaque, bytes: []const u8, _: u32) platform_mod.WriteError!void {
        const self: *Server = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.Closed;
        self.inbox.appendSlice(self.a, bytes) catch return error.Unexpected;
        while (std.mem.indexOfScalar(u8, self.inbox.items, '\n')) |nl| {
            const line = self.a.dupe(u8, self.inbox.items[0..nl]) catch return error.Unexpected;
            self.inbox.replaceRangeAssumeCapacity(0, nl + 1, &.{});
            self.handleLine(line) catch return error.Unexpected;
        }
    }

    fn handleLine(self: *Server, line: []const u8) !void {
        const cap = try envelope.splitCapability(line);
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.a, cap.payload, .{}) catch {
            try self.outbox.appendSlice(self.a, "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"parse_error\",\"message\":\"Invalid JSON\"}}\n");
            return;
        };
        const id = if (root.object.get("id")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        const method = if (root.object.get("method")) |v| v.string else "";
        const params = root.object.get("params") orelse std.json.Value{ .object = .init(self.a) };
        const params_json = try std.json.Stringify.valueAlloc(self.a, params, .{});
        const req: Request = .{
            .raw = line,
            .capability = cap.token,
            .id = id,
            .method = method,
            .params_json = params_json,
            .params = params,
        };
        try self.requests.append(self.a, req);
        switch (self.handler(self, req)) {
            .ok => |json| try self.reply(id, true, json),
            .err => |json| try self.reply(id, false, json),
            .ok_wrong_id => |json| try self.reply("00000000-0000-4000-8000-000000000000", true, json),
            .raw => |l| {
                try self.outbox.appendSlice(self.a, l);
                try self.outbox.append(self.a, '\n');
            },
            .close => self.closed = true,
            .stall => self.stalled = true,
        }
    }

    fn reply(self: *Server, id: []const u8, ok: bool, json: []const u8) !void {
        const w = try std.fmt.allocPrint(self.a, "{{\"id\":{f},\"ok\":{},\"{s}\":{s}}}\n", .{
            std.json.fmt(id, .{}), ok, if (ok) "result" else "error", json,
        });
        try self.outbox.appendSlice(self.a, w);
    }

    fn read(ptr: *anyopaque, buf: []u8, timeout_ms: u32) platform_mod.ReadError!usize {
        const self: *Server = @ptrCast(@alignCast(ptr));
        const pending = self.outbox.items.len - self.out_pos;
        if (pending > 0) {
            const n = @min(pending, buf.len, self.chunk);
            @memcpy(buf[0..n], self.outbox.items[self.out_pos..][0..n]);
            self.out_pos += n;
            return n;
        }
        if (self.closed) return 0;
        if (self.clock) |c| c.* += timeout_ms;
        return error.Timeout;
    }

    fn serverPid(_: *anyopaque) ?u32 {
        return 4242;
    }

    fn close(ptr: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }

    /// Requests whose method is `method`.
    pub fn countMethod(self: *const Server, method: []const u8) usize {
        var n: usize = 0;
        for (self.requests.items) |r| {
            if (std.mem.eql(u8, r.method, method)) n += 1;
        }
        return n;
    }
};

/// Answers `system.ping` with `{"pong":true}` and everything else with
/// `method_not_found`.
pub fn pingHandler(_: *Server, req: Request) Action {
    if (std.mem.eql(u8, req.method, "system.ping")) return .{ .ok = "{\"pong\":true}" };
    return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
}

pub const Platform = struct {
    a: Allocator,
    servers: std.ArrayList(Entry) = .empty,
    failures: std.ArrayList(Failure) = .empty,
    files: std.ArrayList(File) = .empty,
    enumerated: std.ArrayList([]const u8) = .empty,
    pipe_states: std.ArrayList(PipeStateEntry) = .empty,
    connects: usize = 0,
    connect_log: std.ArrayList([]const u8) = .empty,
    clock: i64 = 1_000_000,
    slept_ms: u64 = 0,
    stdin: ?[]const u8 = null,
    interactive: bool = false,
    stdout_terminal: bool = false,
    light: bool = false,
    sid: ?[]const u8 = null,
    session: ?u32 = null,
    self_exe: ?[]const u8 = null,
    cwd_path: ?[]const u8 = null,
    hklm: PolicyFake = .absent,
    hkcu: PolicyFake = .absent,
    spawned: std.ArrayList(Spawn) = .empty,
    spawn_fails: bool = false,
    run_exit: u8 = 0,
    ran: std.ArrayList(Spawn) = .empty,
    foreground_grants: std.ArrayList(u32) = .empty,
    /// Servers that appear `delay_ms` after the first detached spawn.
    on_spawn: std.ArrayList(Delayed) = .empty,

    pub const Entry = struct { path: []const u8, server: *Server, available_at: i64 = std.math.minInt(i64) };
    pub const Failure = struct { path: []const u8, err: platform_mod.ConnectError };
    pub const File = struct { path: []const u8, bytes: []const u8 };
    pub const PipeStateEntry = struct { path: []const u8, state: platform_mod.PipeState };
    pub const PolicyFake = union(enum) { absent, string: []const u8, malformed };
    pub const Spawn = struct { argv: []const []const u8, had_argv0: bool, wslenv: ?[]const u8 };
    pub const Delayed = struct { path: []const u8, server: *Server, delay_ms: i64 };

    pub fn init(a: Allocator) Platform {
        return .{ .a = a };
    }

    pub fn platform(self: *Platform) platform_mod.Platform {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn addServer(self: *Platform, path: []const u8, server: *Server) !void {
        server.clock = &self.clock;
        try self.servers.append(self.a, .{ .path = path, .server = server });
    }

    pub fn addFailure(self: *Platform, path: []const u8, err: platform_mod.ConnectError) !void {
        try self.failures.append(self.a, .{ .path = path, .err = err });
    }

    pub fn addFile(self: *Platform, path: []const u8, bytes: []const u8) !void {
        try self.files.append(self.a, .{ .path = path, .bytes = bytes });
    }

    pub fn addOnSpawn(self: *Platform, path: []const u8, server: *Server, delay_ms: i64) !void {
        server.clock = &self.clock;
        try self.on_spawn.append(self.a, .{ .path = path, .server = server, .delay_ms = delay_ms });
    }

    fn self_(ptr: *anyopaque) *Platform {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: platform_mod.Platform.VTable = .{
        .connect = connect,
        .pipeState = pipeState,
        .enumeratePipes = enumeratePipes,
        .readFile = readFile,
        .pathExists = pathExists,
        .readStdin = readStdin,
        .userSid = userSid,
        .sessionId = sessionId,
        .selfExePath = selfExePath,
        .cwd = cwd,
        .spawnDetached = spawnDetached,
        .runInherit = runInherit,
        .sleepMs = sleepMs,
        .nowMs = nowMs,
        .isInteractive = isInteractive,
        .stdoutIsTerminal = stdoutIsTerminal,
        .prefersLightTheme = prefersLight,
        .policy = policy,
        .allowForeground = allowForeground,
    };

    fn same(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(proto.pipe_name.bareName(a), proto.pipe_name.bareName(b));
    }

    fn connect(ptr: *anyopaque, _: Allocator, path: []const u8, _: u32) platform_mod.ConnectError!platform_mod.Transport {
        const self = self_(ptr);
        self.connects += 1;
        self.connect_log.append(self.a, path) catch return error.OutOfMemory;
        for (self.failures.items) |f| if (same(f.path, path)) return f.err;
        for (self.servers.items) |e| {
            if (same(e.path, path) and self.clock >= e.available_at) {
                e.server.reset() catch return error.OutOfMemory;
                return e.server.transport();
            }
        }
        return error.NotFound;
    }

    fn pipeState(ptr: *anyopaque, _: Allocator, path: []const u8) platform_mod.PipeState {
        const self = self_(ptr);
        for (self.pipe_states.items) |e| if (same(e.path, path)) return e.state;
        for (self.servers.items) |e| if (same(e.path, path)) return .present;
        return .absent;
    }

    fn enumeratePipes(ptr: *anyopaque, gpa: Allocator) Allocator.Error![][]u8 {
        const self = self_(ptr);
        const out = try gpa.alloc([]u8, self.enumerated.items.len);
        for (self.enumerated.items, 0..) |n, i| out[i] = try gpa.dupe(u8, n);
        return out;
    }

    fn readFile(ptr: *anyopaque, gpa: Allocator, path: []const u8, max: usize) ?[]u8 {
        const self = self_(ptr);
        for (self.files.items) |f| {
            if (std.mem.eql(u8, f.path, path)) {
                if (f.bytes.len > max) return null;
                return gpa.dupe(u8, f.bytes) catch null;
            }
        }
        return null;
    }

    fn pathExists(ptr: *anyopaque, path: []const u8) bool {
        const self = self_(ptr);
        for (self.files.items) |f| if (std.mem.eql(u8, f.path, path)) return true;
        return false;
    }

    fn readStdin(ptr: *anyopaque, gpa: Allocator, max: usize) platform_mod.StdinError![]u8 {
        const self = self_(ptr);
        const s = self.stdin orelse "";
        if (s.len > max) return error.TooLarge;
        return gpa.dupe(u8, s);
    }

    fn userSid(ptr: *anyopaque, gpa: Allocator) ?[]u8 {
        const s = self_(ptr).sid orelse return null;
        return gpa.dupe(u8, s) catch null;
    }

    fn sessionId(ptr: *anyopaque) ?u32 {
        return self_(ptr).session;
    }

    fn selfExePath(ptr: *anyopaque, gpa: Allocator) ?[]u8 {
        const s = self_(ptr).self_exe orelse return null;
        return gpa.dupe(u8, s) catch null;
    }

    fn cwd(ptr: *anyopaque, gpa: Allocator) ?[]u8 {
        const s = self_(ptr).cwd_path orelse return null;
        return gpa.dupe(u8, s) catch null;
    }

    fn record(self: *Platform, argv: []const []const u8, env: *const std.process.EnvMap) !Spawn {
        const copy = try self.a.alloc([]const u8, argv.len);
        for (argv, 0..) |x, i| copy[i] = try self.a.dupe(u8, x);
        return .{
            .argv = copy,
            .had_argv0 = env.get("WMUX_ARGV0") != null,
            .wslenv = if (env.get("WSLENV")) |w| try self.a.dupe(u8, w) else null,
        };
    }

    fn spawnDetached(ptr: *anyopaque, _: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) platform_mod.SpawnError!void {
        const self = self_(ptr);
        if (self.spawn_fails) return error.SpawnFailed;
        const s = self.record(argv, env) catch return error.OutOfMemory;
        self.spawned.append(self.a, s) catch return error.OutOfMemory;
        for (self.on_spawn.items) |d| {
            self.servers.append(self.a, .{ .path = d.path, .server = d.server, .available_at = self.clock + d.delay_ms }) catch return error.OutOfMemory;
        }
        self.on_spawn.clearRetainingCapacity();
    }

    fn runInherit(ptr: *anyopaque, _: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) platform_mod.SpawnError!u8 {
        const self = self_(ptr);
        if (self.spawn_fails) return error.SpawnFailed;
        const s = self.record(argv, env) catch return error.OutOfMemory;
        self.ran.append(self.a, s) catch return error.OutOfMemory;
        return self.run_exit;
    }

    fn sleepMs(ptr: *anyopaque, ms: u64) void {
        const self = self_(ptr);
        self.clock += @intCast(ms);
        self.slept_ms += ms;
    }

    fn nowMs(ptr: *anyopaque) i64 {
        return self_(ptr).clock;
    }

    fn isInteractive(ptr: *anyopaque) bool {
        return self_(ptr).interactive;
    }

    fn stdoutIsTerminal(ptr: *anyopaque) bool {
        return self_(ptr).stdout_terminal;
    }

    fn prefersLight(ptr: *anyopaque) bool {
        return self_(ptr).light;
    }

    fn policy(ptr: *anyopaque, gpa: Allocator, hive: platform_mod.PolicyHive) platform_mod.PolicyValue {
        const self = self_(ptr);
        const v = if (hive == .hklm) self.hklm else self.hkcu;
        return switch (v) {
            .absent => .absent,
            .malformed => .malformed,
            .string => |s| .{ .string = gpa.dupe(u8, s) catch return .absent },
        };
    }

    fn allowForeground(ptr: *anyopaque, pid: u32) void {
        const self = self_(ptr);
        self.foreground_grants.append(self.a, pid) catch {};
    }
};
