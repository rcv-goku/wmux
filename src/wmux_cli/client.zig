//! v2 control-pipe client (ADR-4.5): newline-framed requests with random UUID
//! ids, one reply line per request, id checking, the capability prefix,
//! lazy `auth.login`, retries within one response deadline and large
//! replies. Protocol and framing are pure; bytes move through a
//! `platform.Transport` (a named-pipe handle on Windows, `fake.Server` in
//! tests).
//!
//! - Response timeout: `WMUX_CLI_RESPONSE_TIMEOUT_SEC`, then
//!   `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`, default 15 s; it bounds the whole
//!   call including retries.
//! - Retries: `overloaded` (reconnect, any method) and `rate_limited`
//!   (polling methods), honoring `data.retry_after_ms`; `timeout` only when
//!   `data.retryable` is true. An error reply with `"id": null` (sent before
//!   the server read the request, e.g. an admission `overloaded`) answers the
//!   pending request; any other id mismatch is an error.
//! - `CMUX_SOCKET_CAPABILITY`/`WMUX_SOCKET_CAPABILITY` prefix every line
//!   with `_cmux_capability_v1 <token> `.
//! - Password mode: on `auth_required` the client sends `auth.login
//!   {password}` once (password from `--password`, then
//!   `WMUX_SOCKET_PASSWORD`/`CMUX_SOCKET_PASSWORD`) and repeats the request.

const std = @import("std");
const proto = @import("wmux_proto");
const envelope = proto.envelope;
const env_names = proto.env_names;
const errors = proto.errors;
const Env = env_names.Env;
const Allocator = std.mem.Allocator;
const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;
const Transport = platform_mod.Transport;

pub const default_response_timeout_ms: u32 = 15_000;
pub const default_connect_timeout_ms: u32 = 2_000;
/// Replies larger than this are refused (a `read_text` with scrollback or a
/// 15 MiB paste echo fits comfortably).
pub const default_max_reply_bytes: usize = 256 * 1024 * 1024;
/// Retry delay when the server omits `retry_after_ms`.
pub const default_retry_after_ms: u32 = 100;

/// Seconds from the environment as milliseconds; positive finite numbers
/// only (`1`, `2.5`), capped at one day. Anything else gives the default.
pub fn responseTimeoutMs(env: Env) u32 {
    for ([_][]const u8{ env_names.WMUX_CLI_RESPONSE_TIMEOUT_SEC, env_names.CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC }) |n| {
        if (env.getNonEmpty(n)) |v| if (parseSecondsMs(v)) |ms| return ms;
    }
    return default_response_timeout_ms;
}

/// `"2.5"` → 2500. Null for non-numbers, zero, negatives, NaN and inf.
pub fn parseSecondsMs(text: []const u8) ?u32 {
    const s = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch return null;
    if (!std.math.isFinite(s) or s <= 0) return null;
    const ms = s * 1000.0;
    const cap: f64 = 24 * 60 * 60 * 1000;
    if (ms >= cap) return @intFromFloat(cap);
    return @max(1, @as(u32, @intFromFloat(@round(ms))));
}

/// Capability token from the environment (`WMUX_` twin first). Tokens with
/// whitespace or control characters cannot be framed and are ignored.
pub fn capabilityFromEnv(env: Env) ?[]const u8 {
    const t = env.first(&.{ env_names.WMUX_SOCKET_CAPABILITY, env_names.CMUX_SOCKET_CAPABILITY }) orelse return null;
    for (t) |c| if (c <= ' ' or c == 0x7f) return null;
    return t;
}

/// `--password`, then `WMUX_SOCKET_PASSWORD`, then `CMUX_SOCKET_PASSWORD`.
pub fn passwordFrom(flag: ?[]const u8, env: Env) ?[]const u8 {
    if (flag) |f| return f;
    return env.first(&.{ env_names.WMUX_SOCKET_PASSWORD, env_names.CMUX_SOCKET_PASSWORD });
}

pub const Options = struct {
    path: []const u8,
    capability: ?[]const u8 = null,
    password: ?[]const u8 = null,
    response_timeout_ms: u32 = default_response_timeout_ms,
    connect_timeout_ms: u32 = default_connect_timeout_ms,
    max_reply_bytes: usize = default_max_reply_bytes,
};

pub const CallOptions = struct {
    /// Polling methods retry `rate_limited` (ADR-3.3 list).
    polling: bool = false,
};

/// A transport-level failure; the command never produced a reply.
pub const Failure = struct {
    kind: Kind,
    /// Human-readable, already names the pipe where relevant.
    message: []const u8,

    pub const Kind = enum {
        connect,
        timeout,
        closed,
        bad_reply,
        mismatched_id,
        /// A raw `ERROR: …` text line (printed verbatim).
        text_error,
        too_large,
        io,
    };
};

pub const Outcome = union(enum) {
    ok: Ok,
    rpc_error: RpcError,
    failure: Failure,

    pub const Ok = struct {
        result: std.json.Value,
        /// The reply line as received.
        raw: []const u8,
    };
    pub const RpcError = struct {
        err: envelope.ReplyError,
        raw: []const u8,
    };
};

/// Methods flagged `polling` server-side (ADR-3.3).
pub const polling_methods = [_][]const u8{
    "system.tree",       "system.identify",        "system.top",     "system.memory",
    "window.list",       "window.current",         "workspace.list", "workspace.current",
    "pane.list",         "pane.surfaces",          "surface.list",   "surface.current",
    "surface.read_text", "surface.read_selection",
};

pub fn isPolling(method: []const u8) bool {
    for (polling_methods) |m| if (std.mem.eql(u8, m, method)) return true;
    return false;
}

pub const Client = struct {
    gpa: Allocator,
    platform: Platform,
    opts: Options,
    conn: ?Transport = null,
    buf: std.ArrayList(u8) = .empty,
    authed: bool = false,

    pub fn init(gpa: Allocator, platform: Platform, opts: Options) Client {
        return .{ .gpa = gpa, .platform = platform, .opts = opts };
    }

    /// Reuses a connection discovery already opened.
    pub fn adopt(self: *Client, t: Transport) void {
        if (self.conn) |c| c.close();
        self.conn = t;
        self.buf.clearRetainingCapacity();
    }

    pub fn deinit(self: *Client) void {
        if (self.conn) |c| c.close();
        self.conn = null;
        self.buf.deinit(self.gpa);
    }

    fn disconnect(self: *Client) void {
        if (self.conn) |c| c.close();
        self.conn = null;
        self.buf.clearRetainingCapacity();
        self.authed = false;
    }

    fn ensureConnected(self: *Client, arena: Allocator) Allocator.Error!?Failure {
        if (self.conn != null) return null;
        const t = self.platform.connect(self.gpa, self.opts.path, self.opts.connect_timeout_ms) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .kind = .connect, .message = try connectFailureMessage(arena, self.opts.path, err) };
        };
        self.conn = t;
        self.buf.clearRetainingCapacity();
        return null;
    }

    fn remaining(self: *Client, deadline: i64) u32 {
        const now = self.platform.nowMs();
        if (now >= deadline) return 0;
        return @intCast(@min(deadline - now, std.math.maxInt(u32)));
    }

    /// Sends one request and returns its reply, retrying per ADR-4.5.
    /// Everything in the outcome lives in `arena`.
    pub fn call(self: *Client, arena: Allocator, method: []const u8, params_json: ?[]const u8, call_opts: CallOptions) Allocator.Error!Outcome {
        const deadline = self.platform.nowMs() + self.opts.response_timeout_ms;
        var auth_tried = false;
        while (true) {
            const out = try self.once(arena, method, params_json, deadline);
            const rpc = switch (out) {
                .rpc_error => |e| e,
                else => return out,
            };
            const code = rpc.err.known orelse return out;
            switch (code) {
                .auth_required => {
                    if (auth_tried or self.opts.password == null) return out;
                    auth_tried = true;
                    const logged_in = try self.login(arena, deadline);
                    switch (logged_in) {
                        .ok => continue,
                        else => return logged_in,
                    }
                },
                .overloaded => {
                    if (!try self.backoff(rpc.err, deadline)) return out;
                    self.disconnect();
                },
                .rate_limited => {
                    if (!call_opts.polling) return out;
                    if (!try self.backoff(rpc.err, deadline)) return out;
                },
                .timeout => {
                    if (!dataBool(rpc.err.data, "retryable")) return out;
                    if (self.remaining(deadline) == 0) return out;
                },
                else => return out,
            }
        }
    }

    /// Sleeps `retry_after_ms` when it fits before the deadline.
    fn backoff(self: *Client, err: envelope.ReplyError, deadline: i64) Allocator.Error!bool {
        const wait = dataInt(err.data, "retry_after_ms") orelse default_retry_after_ms;
        const left = self.remaining(deadline);
        if (left == 0 or wait >= left) return false;
        self.platform.sleepMs(wait);
        return true;
    }

    fn login(self: *Client, arena: Allocator, deadline: i64) Allocator.Error!Outcome {
        const params = try std.fmt.allocPrint(arena, "{{\"password\":{f}}}", .{std.json.fmt(self.opts.password.?, .{})});
        const out = try self.once(arena, "auth.login", params, deadline);
        if (out == .ok) self.authed = true;
        return out;
    }

    fn once(self: *Client, arena: Allocator, method: []const u8, params_json: ?[]const u8, deadline: i64) Allocator.Error!Outcome {
        if (try self.ensureConnected(arena)) |f| return .{ .failure = f };
        const conn = self.conn.?;
        const id = envelope.newRequestId();

        var aw: std.Io.Writer.Allocating = .init(arena);
        if (self.opts.capability) |tok| envelope.writeCapabilityPrefix(&aw.writer, tok) catch return error.OutOfMemory;
        envelope.writeRequest(&aw.writer, &id, method, params_json) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;

        conn.write(aw.written(), @max(1, self.remaining(deadline))) catch |err| {
            // A server that refuses the connection at admission (ADR-3.3
            // `overloaded`) may answer and close before the request goes
            // out; what it wrote is still the reply.
            if (err == error.Closed) {
                switch (try self.readLine(arena, method, deadline)) {
                    .line => |l| return self.decode(arena, &id, l),
                    .failure => {},
                }
            }
            self.disconnect();
            return .{ .failure = .{
                .kind = if (err == error.Timeout) .timeout else .closed,
                .message = try std.fmt.allocPrint(arena, "cannot send {s} to {s}: {s}", .{ method, self.opts.path, switch (err) {
                    error.Timeout => "write timed out",
                    error.Closed => "connection closed",
                    error.Unexpected => "write failed",
                } }),
            } };
        };

        const line = switch (try self.readLine(arena, method, deadline)) {
            .line => |l| l,
            .failure => |f| return .{ .failure = f },
        };
        return self.decode(arena, &id, line);
    }

    /// Classifies one reply line received for the request `id`.
    fn decode(self: *Client, arena: Allocator, id: []const u8, line: []const u8) Allocator.Error!Outcome {
        if (envelope.isTextError(line)) return .{ .failure = .{ .kind = .text_error, .message = line } };
        const reply = envelope.parseReply(arena, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidReply => return .{ .failure = .{
                .kind = .bad_reply,
                .message = try std.fmt.allocPrint(arena, "invalid response from {s}: not a v2 JSON reply", .{self.opts.path}),
            } },
        };
        if (!envelope.idMatches(id, reply.id)) {
            // Errors sent before the server read a request (admission
            // `overloaded`, pre-dispatch rejections) carry `"id": null`. A
            // connection serves one request at a time, so such an error
            // answers this request. Anything else is a stray reply: the
            // stream is out of step; start over next time.
            const unattributed_error = !reply.ok and reply.id == .null;
            if (!unattributed_error) {
                self.disconnect();
                return .{ .failure = .{ .kind = .mismatched_id, .message = errors.msg.mismatched_response_id } };
            }
        }
        if (reply.ok) return .{ .ok = .{ .result = reply.result, .raw = line } };
        return .{ .rpc_error = .{ .err = reply.err.?, .raw = line } };
    }

    const LineResult = union(enum) { line: []const u8, failure: Failure };

    /// Next non-blank line without its terminator, copied into `arena`.
    fn readLine(self: *Client, arena: Allocator, method: []const u8, deadline: i64) Allocator.Error!LineResult {
        const conn = self.conn.?;
        var scanned: usize = 0;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buf.items, scanned, '\n')) |nl| {
                const line = try arena.dupe(u8, envelope.trimLineEnd(self.buf.items[0 .. nl + 1]));
                self.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                scanned = 0;
                if (envelope.isBlankLine(line)) continue;
                return .{ .line = line };
            }
            scanned = self.buf.items.len;
            if (self.buf.items.len >= self.opts.max_reply_bytes) {
                self.disconnect();
                return .{ .failure = .{
                    .kind = .too_large,
                    .message = try std.fmt.allocPrint(arena, "response to {s} from {s} exceeds {d} MiB", .{ method, self.opts.path, self.opts.max_reply_bytes / (1024 * 1024) }),
                } };
            }
            const left = self.remaining(deadline);
            if (left == 0) return self.timedOut(arena, method);
            try self.buf.ensureUnusedCapacity(self.gpa, 64 * 1024);
            const spare = self.buf.unusedCapacitySlice();
            const room = @min(spare.len, self.opts.max_reply_bytes - self.buf.items.len);
            const n = conn.read(spare[0..room], left) catch |err| switch (err) {
                error.Timeout => return self.timedOut(arena, method),
                error.Unexpected => {
                    self.disconnect();
                    return .{ .failure = .{ .kind = .io, .message = try std.fmt.allocPrint(arena, "reading the response to {s} from {s} failed", .{ method, self.opts.path }) } };
                },
            };
            if (n == 0) {
                // A final line without a terminator still counts.
                if (!envelope.isBlankLine(self.buf.items)) {
                    const line = try arena.dupe(u8, envelope.trimLineEnd(self.buf.items));
                    self.disconnect();
                    return .{ .line = line };
                }
                self.disconnect();
                return .{ .failure = .{ .kind = .closed, .message = try std.fmt.allocPrint(arena, "connection to {s} closed before a response to {s} arrived", .{ self.opts.path, method }) } };
            }
            self.buf.items.len += n;
        }
    }

    fn timedOut(self: *Client, arena: Allocator, method: []const u8) Allocator.Error!LineResult {
        // A late reply would arrive out of step; drop the connection.
        self.disconnect();
        const secs = @as(f64, @floatFromInt(self.opts.response_timeout_ms)) / 1000.0;
        return .{ .failure = .{
            .kind = .timeout,
            .message = try std.fmt.allocPrint(arena, "timed out after {d}s waiting for a response to {s} from {s} (set WMUX_CLI_RESPONSE_TIMEOUT_SEC to wait longer)", .{ secs, method, self.opts.path }),
        } };
    }
};

fn dataField(data: ?std.json.Value, key: []const u8) ?std.json.Value {
    const d = data orelse return null;
    return switch (d) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn dataInt(data: ?std.json.Value, key: []const u8) ?u32 {
    const v = dataField(data, key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(@min(i, std.math.maxInt(u32))),
        .float => |f| if (!std.math.isFinite(f) or f < 0) null else @intFromFloat(@min(f, 4.0e9)),
        else => null,
    };
}

fn dataBool(data: ?std.json.Value, key: []const u8) bool {
    const v = dataField(data, key) orelse return false;
    return v == .bool and v.bool;
}

/// Connect failure text; explicit and discovered paths are named verbatim.
pub fn connectFailureMessage(arena: Allocator, path: []const u8, err: platform_mod.ConnectError) Allocator.Error![]const u8 {
    return switch (err) {
        error.NotFound => std.fmt.allocPrint(arena, "cannot connect to {s}: no such pipe (is wmux running?)", .{path}),
        error.ForeignOwner => std.fmt.allocPrint(arena, "refusing {s}: the pipe server is not owned by the current user", .{path}),
        else => std.fmt.allocPrint(arena, "cannot connect to {s}: {s}", .{ path, platform_mod.connectErrorText(err) }),
    };
}

// ----- tests -----

const testing = std.testing;
const fake = @import("fake.zig");

const pipe = "\\\\.\\pipe\\wmux-test-0123abcd-s1";

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    server: fake.Server,

    fn init(self: *Harness) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.server = fake.Server.init(a);
        try self.fp.addServer(pipe, &self.server);
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    fn client(self: *Harness, opts: Options) Client {
        var o = opts;
        o.path = pipe;
        return Client.init(self.arena_state.allocator(), self.fp.platform(), o);
    }
};

test "unit: cli-client: ping round trip echoes a fresh uuid id" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const a = h.arena_state.allocator();
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(a, "system.ping", null, .{});
    try testing.expect(out.ok.result.object.get("pong").?.bool);
    const req = h.server.requests.items[0];
    try testing.expect(proto.uuid.Uuid.isUuidText(req.id));
    try testing.expectEqualStrings("{}", req.params_json);
    try testing.expectEqual(@as(?[]const u8, null), req.capability);
    // Two calls reuse one connection with distinct ids.
    _ = try c.call(a, "system.ping", "{\"x\":1}", .{});
    try testing.expectEqual(@as(usize, 1), h.server.connections);
    try testing.expect(!std.mem.eql(u8, req.id, h.server.requests.items[1].id));
    try testing.expectEqualStrings("{\"x\":1}", h.server.requests.items[1].params_json);
}

test "unit: cli-client: capability prefix on every line" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const a = h.arena_state.allocator();
    var c = h.client(.{ .path = "", .capability = "tok_123-abc" });
    defer c.deinit();
    _ = try c.call(a, "system.ping", null, .{});
    _ = try c.call(a, "system.ping", null, .{});
    for (h.server.requests.items) |r| {
        try testing.expectEqualStrings("tok_123-abc", r.capability.?);
        try testing.expect(std.mem.startsWith(u8, r.raw, "_cmux_capability_v1 tok_123-abc {\"id\":"));
    }
}

test "unit: cli-client: capability and password sources" {
    const pairs: []const Env.Pair = &.{ .{ "CMUX_SOCKET_CAPABILITY", "c" }, .{ "WMUX_SOCKET_CAPABILITY", "w" }, .{ "CMUX_SOCKET_PASSWORD", "pc" } };
    const env = Env.fromPairs(&pairs);
    try testing.expectEqualStrings("w", capabilityFromEnv(env).?);
    const bad: []const Env.Pair = &.{.{ "CMUX_SOCKET_CAPABILITY", "has space" }};
    try testing.expectEqual(@as(?[]const u8, null), capabilityFromEnv(Env.fromPairs(&bad)));
    try testing.expectEqual(@as(?[]const u8, null), capabilityFromEnv(Env.empty));
    try testing.expectEqualStrings("flag", passwordFrom("flag", env).?);
    try testing.expectEqualStrings("pc", passwordFrom(null, env).?);
    const both: []const Env.Pair = &.{ .{ "CMUX_SOCKET_PASSWORD", "pc" }, .{ "WMUX_SOCKET_PASSWORD", "pw" } };
    try testing.expectEqualStrings("pw", passwordFrom(null, Env.fromPairs(&both)).?);
}

test "unit: cli-client: response timeout from the environment" {
    try testing.expectEqual(default_response_timeout_ms, responseTimeoutMs(Env.empty));
    const w: []const Env.Pair = &.{ .{ "WMUX_CLI_RESPONSE_TIMEOUT_SEC", "2.5" }, .{ "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", "9" } };
    try testing.expectEqual(@as(u32, 2500), responseTimeoutMs(Env.fromPairs(&w)));
    const c: []const Env.Pair = &.{ .{ "WMUX_CLI_RESPONSE_TIMEOUT_SEC", "nope" }, .{ "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", "60" } };
    try testing.expectEqual(@as(u32, 60_000), responseTimeoutMs(Env.fromPairs(&c)));
    for ([_][]const u8{ "0", "-1", "nan", "inf", "", " ", "1e400" }) |bad| {
        try testing.expectEqual(@as(?u32, null), parseSecondsMs(bad));
    }
    try testing.expectEqual(@as(?u32, 86_400_000), parseSecondsMs("1e9"));
    try testing.expectEqual(@as(?u32, 1), parseSecondsMs("0.0001"));
}

fn wrongIdHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .ok_wrong_id = "{}" };
}

test "unit: cli-client: a reply with another id is an error" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.server.handler = wrongIdHandler;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expectEqual(Failure.Kind.mismatched_id, out.failure.kind);
    try testing.expectEqualStrings("Mismatched v2 response id", out.failure.message);
}

fn badJsonHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .raw = "{\"id\":1,\"ok\":" };
}

fn textErrorHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .raw = "ERROR: Access denied" };
}

fn closeHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .close;
}

fn stallHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .stall;
}

test "unit: cli-client: bad JSON, text errors, close and timeout map to failures" {
    const cases = [_]struct { fake.Handler, Failure.Kind, []const u8 }{
        .{ badJsonHandler, .bad_reply, "invalid response from \\\\.\\pipe\\wmux-test-0123abcd-s1: not a v2 JSON reply" },
        .{ textErrorHandler, .text_error, "ERROR: Access denied" },
        .{ closeHandler, .closed, "connection to \\\\.\\pipe\\wmux-test-0123abcd-s1 closed before a response to system.ping arrived" },
        .{ stallHandler, .timeout, "timed out after 1.5s waiting for a response to system.ping from \\\\.\\pipe\\wmux-test-0123abcd-s1 (set WMUX_CLI_RESPONSE_TIMEOUT_SEC to wait longer)" },
    };
    for (cases) |cs| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.server.handler = cs[0];
        var c = h.client(.{ .path = "", .response_timeout_ms = 1500 });
        defer c.deinit();
        const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
        try testing.expectEqual(cs[1], out.failure.kind);
        try testing.expectEqualStrings(cs[2], out.failure.message);
    }
}

test "unit: cli-client: connect errors name the pipe" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { ?platform_mod.ConnectError, []const u8 }{
        .{ null, "cannot connect to \\\\.\\pipe\\gone: no such pipe (is wmux running?)" },
        .{ error.Busy, "cannot connect to \\\\.\\pipe\\gone: busy (all pipe instances in use)" },
        .{ error.Timeout, "cannot connect to \\\\.\\pipe\\gone: timed out" },
        .{ error.AccessDenied, "cannot connect to \\\\.\\pipe\\gone: access denied" },
        .{ error.ForeignOwner, "refusing \\\\.\\pipe\\gone: the pipe server is not owned by the current user" },
        .{ error.Unsupported, "cannot connect to \\\\.\\pipe\\gone: named pipes are only available on Windows" },
    };
    for (cases) |cs| {
        var fp = fake.Platform.init(a);
        if (cs[0]) |e| try fp.addFailure("\\\\.\\pipe\\gone", e);
        var c = Client.init(a, fp.platform(), .{ .path = "\\\\.\\pipe\\gone" });
        defer c.deinit();
        const out = try c.call(a, "system.ping", null, .{});
        try testing.expectEqual(Failure.Kind.connect, out.failure.kind);
        try testing.expectEqualStrings(cs[1], out.failure.message);
    }
}

const Counter = struct { n: usize = 0, code: []const u8 = "", data: []const u8 = "{}" };

fn flakyHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const ctr: *Counter = @ptrCast(@alignCast(server.user.?));
    ctr.n += 1;
    if (ctr.n <= 2) {
        return .{ .err = std.fmt.allocPrint(server.a, "{{\"code\":\"{s}\",\"message\":\"m\",\"data\":{s}}}", .{ ctr.code, ctr.data }) catch unreachable };
    }
    return fake.pingHandler(server, req);
}

test "unit: cli-client: overloaded retries on a new connection honoring retry_after_ms" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctr: Counter = .{ .code = "overloaded", .data = "{\"retryable\":true,\"retry_after_ms\":250,\"reason\":\"pool_saturated\"}" };
    h.server.user = &ctr;
    h.server.handler = flakyHandler;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expect(out == .ok);
    try testing.expectEqual(@as(usize, 3), h.server.connections);
    try testing.expectEqual(@as(u64, 500), h.fp.slept_ms);
}

test "unit: cli-client: retries stop at the response deadline" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctr: Counter = .{ .code = "overloaded", .data = "{\"retry_after_ms\":5000}" };
    h.server.user = &ctr;
    h.server.handler = flakyHandler;
    var c = h.client(.{ .path = "", .response_timeout_ms = 3000 });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expectEqualStrings("overloaded", out.rpc_error.err.code);
    try testing.expectEqual(@as(u64, 0), h.fp.slept_ms);
}

const admission_overloaded =
    \\{"id":null,"ok":false,"error":{"code":"overloaded","message":"Server overloaded","data":{"retryable":true,"retry_after_ms":120,"reason":"preauthorization_saturated"}}}
;

test "unit: cli-client: an admission rejection sent before the request is read is retried" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The server answers `overloaded` with a null id and closes before the
    // request goes out, so the client's write fails on a closed pipe.
    h.server.reject_connections = 1;
    h.server.reject_line = admission_overloaded;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expect(out.ok.result.object.get("pong").?.bool);
    try testing.expectEqual(@as(usize, 2), h.server.connections);
    try testing.expectEqual(@as(u64, 120), h.fp.slept_ms);
    // Only the second connection delivered a request.
    try testing.expectEqual(@as(usize, 1), h.server.requests.items.len);
}

test "unit: cli-client: an admission rejection that never clears ends at the deadline" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.server.reject_connections = std.math.maxInt(usize);
    h.server.reject_line = admission_overloaded;
    var c = h.client(.{ .path = "", .response_timeout_ms = 1000 });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expectEqualStrings("overloaded", out.rpc_error.err.code);
    try testing.expectEqualStrings("preauthorization_saturated", out.rpc_error.err.data.?.object.get("reason").?.string);
    try testing.expect(h.fp.slept_ms < 1000);
    try testing.expectEqual(@as(usize, 0), h.server.requests.items.len);
}

test "unit: cli-client: a pipe closed before the request with nothing to read is a send failure" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.server.reject_connections = 1;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expectEqual(Failure.Kind.closed, out.failure.kind);
    try testing.expectEqualStrings("cannot send system.ping to \\\\.\\pipe\\wmux-test-0123abcd-s1: connection closed", out.failure.message);
}

fn nullIdErrorHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .raw = "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"parse_error\",\"message\":\"Invalid JSON\"}}" };
}

fn absentIdErrorHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .raw = "{\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"Expected JSON object\"}}" };
}

fn nullIdOkHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .raw = "{\"id\":null,\"ok\":true,\"result\":{\"pong\":true}}" };
}

fn otherIdErrorHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .raw = "{\"id\":\"00000000-0000-4000-8000-000000000000\",\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"m\"}}" };
}

test "unit: cli-client: only an error without an id may answer the pending request" {
    const cases = [_]struct { fake.Handler, ?[]const u8 }{
        .{ nullIdErrorHandler, "parse_error" },
        .{ absentIdErrorHandler, "invalid_request" },
        .{ nullIdOkHandler, null },
        .{ otherIdErrorHandler, null },
    };
    for (cases) |cs| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.server.handler = cs[0];
        var c = h.client(.{ .path = "" });
        defer c.deinit();
        const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
        if (cs[1]) |code| {
            try testing.expectEqualStrings(code, out.rpc_error.err.code);
            // The connection stays usable after an unattributed error.
            try testing.expect(c.conn != null);
        } else {
            try testing.expectEqual(Failure.Kind.mismatched_id, out.failure.kind);
            try testing.expect(c.conn == null);
        }
    }
}

test "unit: cli-client: rate_limited retries only polling methods" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctr: Counter = .{ .code = "rate_limited", .data = "{\"retry_after_ms\":100}" };
    h.server.user = &ctr;
    h.server.handler = flakyHandler;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const a = h.arena_state.allocator();
    const first = try c.call(a, "workspace.create", null, .{});
    try testing.expectEqualStrings("rate_limited", first.rpc_error.err.code);
    ctr.n = 0;
    const polled = try c.call(a, "system.ping", null, .{ .polling = isPolling("workspace.list") });
    try testing.expect(polled == .ok);
    try testing.expectEqual(@as(usize, 1), h.server.connections);
    try testing.expect(isPolling("surface.read_text"));
    try testing.expect(!isPolling("system.ping"));
}

test "unit: cli-client: timeout retries only when retryable" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctr: Counter = .{ .code = "timeout", .data = "{\"stage\":\"main_actor\",\"deadline_ms\":10000,\"retryable\":false}" };
    h.server.user = &ctr;
    h.server.handler = flakyHandler;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const a = h.arena_state.allocator();
    try testing.expectEqualStrings("timeout", (try c.call(a, "system.ping", null, .{})).rpc_error.err.code);
    ctr = .{ .code = "timeout", .data = "{\"retryable\":true}" };
    try testing.expect((try c.call(a, "system.ping", null, .{})) == .ok);
}

const AuthState = struct { authed: bool = false, password: []const u8 };

fn authHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const st: *AuthState = @ptrCast(@alignCast(server.user.?));
    if (std.mem.eql(u8, req.method, "auth.login")) {
        const pw = req.params.object.get("password").?.string;
        if (std.mem.eql(u8, pw, st.password)) {
            st.authed = true;
            return .{ .ok = "{\"authenticated\":true}" };
        }
        return .{ .err = "{\"code\":\"auth_failed\",\"message\":\"Invalid password\"}" };
    }
    if (!st.authed) return .{ .err = "{\"code\":\"auth_required\",\"message\":\"Authentication required\"}" };
    return fake.pingHandler(server, req);
}

test "unit: cli-client: password mode logs in lazily once" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var st: AuthState = .{ .password = "p\u{e4}ss \"w\"" };
    h.server.user = &st;
    h.server.handler = authHandler;
    var c = h.client(.{ .path = "", .password = "p\u{e4}ss \"w\"" });
    defer c.deinit();
    const a = h.arena_state.allocator();
    try testing.expect((try c.call(a, "system.ping", null, .{})) == .ok);
    try testing.expectEqual(@as(usize, 1), h.server.countMethod("auth.login"));
    try testing.expect((try c.call(a, "system.ping", null, .{})) == .ok);
    try testing.expectEqual(@as(usize, 1), h.server.countMethod("auth.login"));
}

test "unit: cli-client: wrong or missing password surfaces the auth error" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var st: AuthState = .{ .password = "right" };
    h.server.user = &st;
    h.server.handler = authHandler;
    const a = h.arena_state.allocator();
    var wrong = h.client(.{ .path = "", .password = "wrong" });
    defer wrong.deinit();
    try testing.expectEqualStrings("auth_failed", (try wrong.call(a, "system.ping", null, .{})).rpc_error.err.code);
    var none = h.client(.{ .path = "" });
    defer none.deinit();
    try testing.expectEqualStrings("auth_required", (try none.call(a, "system.ping", null, .{})).rpc_error.err.code);
}

fn bigHandler(server: *fake.Server, _: fake.Request) fake.Action {
    const n: *usize = @ptrCast(@alignCast(server.user.?));
    const body = server.a.alloc(u8, n.*) catch unreachable;
    for (body, 0..) |*b, i| b.* = "abc\u{e9}"[i % 4];
    // Keep the payload valid UTF-8: a lone continuation byte can be cut.
    for (body, 0..) |*b, i| if (b.* >= 0x80) {
        b.* = if (i % 2 == 0) 'x' else 'y';
    };
    return .{ .ok = std.fmt.allocPrint(server.a, "{{\"text\":\"{s}\"}}", .{body}) catch unreachable };
}

test "unit: cli-client: large replies arrive in many partial reads" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var size: usize = 5 * 1024 * 1024 + 3;
    h.server.user = &size;
    h.server.handler = bigHandler;
    h.server.chunk = 7777;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "surface.read_text", null, .{});
    try testing.expectEqual(size, out.ok.result.object.get("text").?.string.len);
}

test "unit: cli-client: replies over the cap are refused" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var size: usize = 3 * 1024 * 1024;
    h.server.user = &size;
    h.server.handler = bigHandler;
    var c = h.client(.{ .path = "", .max_reply_bytes = 2 * 1024 * 1024 });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "surface.read_text", null, .{});
    try testing.expectEqual(Failure.Kind.too_large, out.failure.kind);
}

fn echoCrlfHandler(server: *fake.Server, req: fake.Request) fake.Action {
    return .{ .raw = std.fmt.allocPrint(server.a, "   \r\n\r\n{{\"id\":\"{s}\",\"ok\":true,\"result\":{{\"pong\":true}}}}\r", .{req.id}) catch unreachable };
}

test "unit: cli-client: blank lines are skipped and CRLF is accepted" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.server.handler = echoCrlfHandler;
    var c = h.client(.{ .path = "" });
    defer c.deinit();
    const out = try c.call(h.arena_state.allocator(), "system.ping", null, .{});
    try testing.expect(out.ok.result.object.get("pong").?.bool);
}
