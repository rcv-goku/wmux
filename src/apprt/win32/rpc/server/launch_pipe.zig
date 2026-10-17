//! The launch pipe for single-instance handoff (ARCHITECTURE.md ADR-3.1):
//! `<control pipe>-launch`, always on (even with socketControlMode=off),
//! accepting only `app.launch {intent, argv, cwd, paths, uri}` with
//! intent ∈ open | new_window | activate | uri.
//!
//! - `LaunchPipe.claim` creates the pipe with FILE_FLAG_FIRST_PIPE_INSTANCE:
//!   `.serving` means this process is the instance for its channel,
//!   `.exists` means another server holds the name.
//! - `sendLaunch` is the second process's side: connect, check that the
//!   server runs as the same user, send `app.launch`, read the reply and
//!   return the server pid. The caller (app/single_instance.zig) then calls
//!   AllowSetForegroundWindow(server_pid) itself (G4: no activation here).
//! - `PipeClient` is a small overlapped client with timeouts, used by
//!   `sendLaunch` and the live tests.
//!
//! The request parsing and reply encoding at the top are pure (std +
//! wmux_proto) and unit-tested natively; the Win32 part is only analyzed
//! when referenced, i.e. on Windows.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const envelope = proto.envelope;
const errors = proto.errors;

pub const method = "app.launch";

pub const Intent = enum { open, new_window, activate, uri };

/// One `app.launch` request. Strings live in the parse arena.
pub const LaunchRequest = struct {
    intent: Intent,
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    uri: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    launch: struct { id: std.json.Value, request: LaunchRequest },
    /// The error reply to write (allocated with the `gpa` passed in).
    reply: []u8,
};

/// Parses one launch-pipe line. Anything but a valid `app.launch` yields
/// the error reply: the envelope pre-dispatch errors, `method_not_found
/// "Unknown method"` for any other method, `invalid_params` for bad params.
/// A `_cmux_capability_v1` prefix is ignored (the launch pipe needs none).
pub fn parseLine(arena: Allocator, gpa: Allocator, line: []const u8) Allocator.Error!Parsed {
    const payload = if (envelope.splitCapability(line)) |c| c.payload else |_| line;
    const parsed = try envelope.parseRequest(arena, payload);
    const req = switch (parsed) {
        .rejected => |r| return .{ .reply = try envelope.encodeRejectionAlloc(gpa, r) },
        .request => |r| r,
    };
    if (!std.mem.eql(u8, req.method, method))
        return .{ .reply = try envelope.encodeErrorAlloc(gpa, req.id, .{ .code = .method_not_found, .message = errors.msg.unknown_method }) };
    // std.json would also accept an enum ordinal; cmux names are strings.
    if (req.params.get("intent")) |v| if (v != .string) return .{ .reply = try invalidParams(gpa, req.id, req.params) };
    const launch = std.json.parseFromValueLeaky(LaunchRequest, arena, .{ .object = req.params }, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .reply = try invalidParams(gpa, req.id, req.params) },
    };
    if (launch.intent == .uri and (launch.uri == null or launch.uri.?.len == 0))
        return .{ .reply = try invalidParamsMsg(gpa, req.id, "Missing uri", "uri") };
    return .{ .launch = .{ .id = req.id, .request = launch } };
}

fn invalidParams(gpa: Allocator, id: std.json.Value, params: std.json.ObjectMap) Allocator.Error![]u8 {
    const intent = params.get("intent") orelse return invalidParamsMsg(gpa, id, "Missing intent", "intent");
    const valid_intent = intent == .string and std.meta.stringToEnum(Intent, intent.string) != null;
    if (!valid_intent) return invalidParamsMsg(gpa, id, "Invalid intent", "intent");
    return invalidParamsMsg(gpa, id, errors.Code.invalid_params.defaultMessage(), null);
}

fn invalidParamsMsg(gpa: Allocator, id: std.json.Value, message: []const u8, param: ?[]const u8) Allocator.Error![]u8 {
    const request_state = @import("../logic/request_state.zig");
    if (param) |p| return request_state.errorLineAlloc(gpa, id, .invalid_params, message, .{ .param = p });
    return request_state.errorLineAlloc(gpa, id, .invalid_params, message, null);
}

/// `{"id":…,"ok":true,"result":{"accepted":<bool>,"pid":<server pid>}}`.
pub fn acceptedReplyAlloc(gpa: Allocator, id: std.json.Value, accepted: bool, pid: u32) Allocator.Error![]u8 {
    return envelope.encodeOkAlloc(gpa, id, .{ .accepted = accepted, .pid = pid });
}

/// The request line a second instance sends (no terminator).
pub fn encodeRequestAlloc(gpa: Allocator, id: []const u8, req: LaunchRequest) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    std.json.Stringify.value(.{
        .id = id,
        .method = method,
        .params = req,
    }, .{ .emit_null_optional_fields = false }, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub const LaunchReply = struct { accepted: bool, pid: u32 };

pub const ReplyError = error{ InvalidReply, Rejected, OutOfMemory };

/// Parses the server's reply to `encodeRequestAlloc(id, …)`.
pub fn parseReply(arena: Allocator, id: []const u8, line: []const u8) ReplyError!LaunchReply {
    const reply = envelope.parseReply(arena, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReply,
    };
    if (!envelope.idMatches(id, reply.id)) return error.InvalidReply;
    if (!reply.ok) return error.Rejected;
    if (reply.result != .object) return error.InvalidReply;
    return std.json.parseFromValueLeaky(LaunchReply, arena, reply.result, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidReply,
    };
}

// ---------------------------------------------------------------------------
// Win32 (analyzed only when referenced)
// ---------------------------------------------------------------------------

const PipeServer = @import("PipeServer.zig");
const Connection = PipeServer.Connection;
const w32 = Connection.w32;
const windows = std.os.windows;

/// Overlapped, and a server may only identify (never impersonate) us: the
/// launch client talks to a server before it has checked its owner.
const client_flags: w32.DWORD = w32.FILE_FLAG_OVERLAPPED | 0x00100000 | 0x00010000; // SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION

/// A newline-framed overlapped pipe client with per-call timeouts.
pub const PipeClient = struct {
    gpa: Allocator,
    handle: w32.HANDLE,
    read_event: w32.HANDLE,
    write_event: w32.HANDLE,
    /// Received bytes; `buf[start..]` is not yet returned.
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub const Error = error{ NotFound, Busy, AccessDenied, ConnectFailed, Timeout, Closed, WriteFailed, InvalidName, OutOfMemory, CreateEventFailed };

    /// Connects to `path` (`\\.\pipe\<name>` or bare), waiting up to
    /// `timeout_ms` while every instance is busy.
    pub fn connect(gpa: Allocator, path: []const u8, timeout_ms: u32) Error!PipeClient {
        const full = proto.pipe_name.normalize(gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidName,
        };
        defer gpa.free(full);
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, full) catch return error.OutOfMemory;
        defer gpa.free(path_w);
        var timer = std.time.Timer.start() catch null;
        const handle = while (true) {
            const h = windows.kernel32.CreateFileW(path_w.ptr, w32.GENERIC_READ | w32.GENERIC_WRITE, 0, null, w32.OPEN_EXISTING, client_flags, null);
            if (h != windows.INVALID_HANDLE_VALUE) break h;
            switch (windows.GetLastError()) {
                .PIPE_BUSY => {
                    const spent: u64 = if (timer) |*t| t.read() / std.time.ns_per_ms else timeout_ms;
                    if (spent >= timeout_ms) return error.Busy;
                    _ = w32.WaitNamedPipeW(path_w.ptr, @intCast(@max(1, timeout_ms - spent)));
                },
                .FILE_NOT_FOUND => return error.NotFound,
                .ACCESS_DENIED => return error.AccessDenied,
                else => return error.ConnectFailed,
            }
        };
        errdefer windows.CloseHandle(handle);
        const read_event = try w32.event(true);
        errdefer windows.CloseHandle(read_event);
        const write_event = try w32.event(true);
        return .{ .gpa = gpa, .handle = handle, .read_event = read_event, .write_event = write_event };
    }

    pub fn close(self: *PipeClient) void {
        windows.CloseHandle(self.handle);
        windows.CloseHandle(self.read_event);
        windows.CloseHandle(self.write_event);
        self.buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// The server's process id, or null.
    pub fn serverPid(self: *PipeClient) ?u32 {
        var pid: windows.ULONG = 0;
        if (w32.GetNamedPipeServerProcessId(self.handle, &pid) == 0) return null;
        return pid;
    }

    /// True when the server process runs as the same user as us (the
    /// squatting check of ADR-3.1).
    pub fn serverIsSameUser(self: *PipeClient) bool {
        const pid = self.serverPid() orelse return false;
        const process = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, pid) orelse return false;
        defer windows.CloseHandle(process);
        var theirs: PipeServer.UserSid = .{};
        theirs.ofProcess(process) catch return false;
        var ours: PipeServer.UserSid = .{};
        ours.ofProcess(windows.GetCurrentProcess()) catch return false;
        return w32.EqualSid(theirs.sid(), ours.sid()) != 0;
    }

    /// Writes raw bytes (add the `\n` yourself).
    pub fn writeAll(self: *PipeClient, bytes: []const u8, timeout_ms: u32) Error!void {
        if (!Connection.writeAllTimeout(self.handle, self.write_event, null, bytes, timeout_ms)) return error.WriteFailed;
    }

    pub fn writeLine(self: *PipeClient, line: []const u8, timeout_ms: u32) Error!void {
        try self.writeAll(line, timeout_ms);
        try self.writeAll("\n", timeout_ms);
    }

    /// The next line without its terminator, valid until the next call.
    /// `error.Closed` when the server closed the pipe first.
    pub fn readLine(self: *PipeClient, timeout_ms: u32) Error![]const u8 {
        if (self.start > 0) {
            const rest = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.start..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.start = 0;
        }
        var timer = std.time.Timer.start() catch null;
        var chunk: [16 * 1024]u8 = undefined;
        var ov = std.mem.zeroes(w32.OVERLAPPED);
        ov.hEvent = self.read_event;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
                self.start = nl + 1;
                return envelope.trimLineEnd(self.buf.items[0..nl]);
            }
            const spent: u64 = if (timer) |*t| t.read() / std.time.ns_per_ms else 0;
            if (spent >= timeout_ms) return error.Timeout;
            if (!Connection.startRead(self.handle, &ov, &chunk)) return error.Closed;
            switch (Connection.awaitIo(self.handle, &ov, null, @intCast(timeout_ms - spent))) {
                .done => |n| try self.buf.appendSlice(self.gpa, chunk[0..n]),
                .failed => return error.Closed,
                .timeout, .stopped => return error.Timeout,
            }
        }
    }
};

/// Called on a connection thread for each valid `app.launch`. `req` and
/// its strings are only valid during the call: copy what you post to the
/// UI thread. Return false to answer `accepted:false` (e.g. shutting down).
pub const OnLaunch = *const fn (ctx: ?*anyopaque, req: *const LaunchRequest, client_pid: u32) bool;

/// The always-on launch pipe server.
pub const LaunchPipe = struct {
    gpa: Allocator,
    server: *PipeServer,
    on_launch: OnLaunch,
    ctx: ?*anyopaque,
    pid: u32,

    pub const Claim = union(enum) {
        /// We are the instance for this channel; `deinit` when quitting.
        serving: *LaunchPipe,
        /// Another server holds the name: hand off with `sendLaunch`.
        exists,
    };

    pub const Options = struct {
        /// Timeouts and limits; the launch pipe only ever answers inline.
        limits: PipeServer.admission.Limits = .{},
        allow_all: bool = false,
    };

    /// Tries to become the launch-pipe server for `name` (the control
    /// name + `-launch`, see wmux_proto.pipe_name.launchName).
    pub fn claim(gpa: Allocator, name: []const u8, on_launch: OnLaunch, ctx: ?*anyopaque, options: Options) PipeServer.StartError!Claim {
        const self = try gpa.create(LaunchPipe);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .server = undefined, .on_launch = on_launch, .ctx = ctx, .pid = windows.GetCurrentProcessId() };
        self.server = PipeServer.start(gpa, .{
            .name = name,
            .first_instance = true,
            .allow_all = options.allow_all,
            .limits = options.limits,
        }, .{ .ctx = self, .dispatch = dispatch }) catch |err| switch (err) {
            error.PipeNameInUse => {
                gpa.destroy(self);
                return .exists;
            },
            else => |e| return e,
        };
        return .{ .serving = self };
    }

    /// Stops the server (joining its threads) and frees.
    pub fn deinit(self: *LaunchPipe) void {
        self.server.deinit();
        self.gpa.destroy(self);
    }

    fn dispatch(ctx: ?*anyopaque, conn: *Connection, req: *PipeServer.Request) void {
        const self: *LaunchPipe = @ptrCast(@alignCast(ctx.?));
        // `conn.server`, not `self.server`: a client may arrive before
        // `claim` has stored the server pointer.
        const server = conn.server;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const parsed = parseLine(arena_state.allocator(), self.gpa, req.line) catch return;
        const reply = switch (parsed) {
            .reply => |r| r,
            .launch => |l| blk: {
                const accepted = self.on_launch(self.ctx, &l.request, conn.clientPid());
                break :blk acceptedReplyAlloc(self.gpa, l.id, accepted, self.pid) catch return;
            },
        };
        defer self.gpa.free(reply);
        _ = server.complete(req.token, reply);
    }
};

pub const SendError = PipeClient.Error || ReplyError || error{ForeignServer};

/// Hands `req` to the running instance on `launch_path` and returns its
/// reply (with the server pid for AllowSetForegroundWindow). Fails with
/// `error.ForeignServer` when the server does not run as the same user.
pub fn sendLaunch(gpa: Allocator, launch_path: []const u8, req: LaunchRequest, timeout_ms: u32) SendError!LaunchReply {
    var client = try PipeClient.connect(gpa, launch_path, timeout_ms);
    defer client.close();
    if (!client.serverIsSameUser()) return error.ForeignServer;
    const id = envelope.newRequestId();
    const line = try encodeRequestAlloc(gpa, &id, req);
    defer gpa.free(line);
    try client.writeLine(line, timeout_ms);
    const reply_line = try client.readLine(timeout_ms);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return parseReply(arena_state.allocator(), &id, reply_line);
}

// ---------------------------------------------------------------------------
// Tests (pure part; run natively)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectReply(line: []const u8, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseLine(arena_state.allocator(), testing.allocator, line);
    const reply = p.reply;
    defer testing.allocator.free(reply);
    if (std.mem.indexOf(u8, reply, needle) == null) {
        std.log.err("reply {s} lacks {s}", .{ reply, needle });
        return error.TestUnexpectedResult;
    }
}

test "unit: rpc: launch pipe parses app.launch with all fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const line = "{\"id\":\"L1\",\"method\":\" app.launch \",\"params\":{\"intent\":\"open\",\"argv\":[\"wmux.exe\",\"C:\\\\x\"],\"cwd\":\"C:\\\\Users\\\\\xc3\xa9\",\"paths\":[\"C:\\\\x\"],\"extra\":1}}";
    const p = try parseLine(arena_state.allocator(), testing.allocator, line);
    const r = p.launch.request;
    try testing.expectEqualStrings("L1", p.launch.id.string);
    try testing.expectEqual(Intent.open, r.intent);
    try testing.expectEqual(@as(usize, 2), r.argv.len);
    try testing.expectEqualStrings("C:\\x", r.argv[1]);
    try testing.expectEqualStrings("C:\\Users\\\xc3\xa9", r.cwd.?);
    try testing.expectEqual(@as(usize, 1), r.paths.len);
    try testing.expect(r.uri == null);
}

test "unit: rpc: launch pipe accepts every intent and a capability prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (.{ "open", "new_window", "activate" }) |name| {
        const p = try parseLine(arena, testing.allocator, "{\"method\":\"app.launch\",\"params\":{\"intent\":\"" ++ name ++ "\"}}");
        try testing.expectEqualStrings(name, @tagName(p.launch.request.intent));
        try testing.expect(p.launch.id == .null);
    }
    const u = try parseLine(arena, testing.allocator, "_cmux_capability_v1 tok {\"id\":5,\"method\":\"app.launch\",\"params\":{\"intent\":\"uri\",\"uri\":\"wmux://notification/open?id=1\"}}");
    try testing.expectEqual(Intent.uri, u.launch.request.intent);
    try testing.expectEqual(@as(i64, 5), u.launch.id.integer);
}

test "unit: rpc: launch pipe rejects other methods and malformed lines" {
    try expectReply("{\"id\":1,\"method\":\"system.ping\"}", "\"code\":\"method_not_found\",\"message\":\"Unknown method\"");
    try expectReply("{\"id\":1,\"method\":\"\"}", "\"message\":\"Missing method\"");
    try expectReply("ping", "\"code\":\"parse_error\"");
    try expectReply("", "\"code\":\"parse_error\"");
    try expectReply("[1,2]", "\"message\":\"Expected JSON object\"");
    try expectReply("{\"method\":\"app.launch\",\"params\":{\"intent\":\"\xff\"}}", "\"code\":\"invalid_utf8\"");
}

test "unit: rpc: launch pipe validates params" {
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\",\"params\":{}}", "\"message\":\"Missing intent\"");
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\"}", "\"message\":\"Missing intent\"");
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\",\"params\":{\"intent\":\"explode\"}}", "\"message\":\"Invalid intent\"");
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\",\"params\":{\"intent\":3}}", "\"message\":\"Invalid intent\"");
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\",\"params\":{\"intent\":\"open\",\"argv\":\"x\"}}", "\"code\":\"invalid_params\"");
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\",\"params\":{\"intent\":\"uri\"}}", "\"message\":\"Missing uri\"");
    try expectReply("{\"id\":\"a\",\"method\":\"app.launch\",\"params\":{\"intent\":\"uri\",\"uri\":\"\"}}", "\"data\":{\"param\":\"uri\"}");
}

test "unit: rpc: launch request round-trips through encode, parse and reply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = try encodeRequestAlloc(testing.allocator, "ID-1", .{ .intent = .new_window, .argv = &.{ "a", "b\nc" }, .cwd = "C:\\" });
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"uri\"") == null);
    const p = try parseLine(arena, testing.allocator, line);
    try testing.expectEqual(Intent.new_window, p.launch.request.intent);
    try testing.expectEqualStrings("b\nc", p.launch.request.argv[1]);

    const reply = try acceptedReplyAlloc(testing.allocator, p.launch.id, true, 4242);
    defer testing.allocator.free(reply);
    const r = try parseReply(arena, "ID-1", reply);
    try testing.expect(r.accepted);
    try testing.expectEqual(@as(u32, 4242), r.pid);
    try testing.expectError(error.InvalidReply, parseReply(arena, "other", reply));
    try testing.expectError(error.Rejected, parseReply(arena, "ID-1", "{\"id\":\"ID-1\",\"ok\":false,\"error\":{\"code\":\"busy\",\"message\":\"Busy\"}}"));
    try testing.expectError(error.InvalidReply, parseReply(arena, "ID-1", "garbage"));
    try testing.expectError(error.InvalidReply, parseReply(arena, "ID-1", "{\"id\":\"ID-1\",\"ok\":true,\"result\":7}"));
}
