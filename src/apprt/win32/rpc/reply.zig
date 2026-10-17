//! Reply lines of the v2 dispatcher and deferred completions
//! (ARCHITECTURE.md ADR-3.2, ADR-3.4, ADR-3.5, ground rule G5).
//!
//! - `ctxLineAlloc` encodes the one reply a handler recorded in its `Ctx`
//!   into the cmux envelope (`{"id","ok":true,"result"}` or
//!   `{"id","ok":false,"error":{code,message,data?}}`), always one line;
//!   encoding failures fall back to the fixed `encode_error` line.
//! - `zigErrorLineAlloc` maps a Zig error that escaped a handler with
//!   `errors.fromZig` (`internal_error` carries `data.error`).
//! - Deferred replies: `Ctx.deferReply()` calls `deferStart`, which records
//!   the request id and marks the request deferred; `complete`,
//!   `completeRaw` and `completeError` may then run on any thread. A
//!   completion for a request that is gone (client left, generation
//!   changed, expired, already completed, or the server stopped) is
//!   dropped by the transport.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const envelope = proto.envelope;
const errors = proto.errors;

const PipeServer = @import("server/PipeServer.zig");
const types = @import("types.zig");

const log = std.log.scoped(.rpc);

const Token = PipeServer.Token;

/// The message of `internal_error` when a handler returned without
/// replying (a G5 violation; logged).
pub const no_reply_message = "Handler did not reply";

/// The reply line for `reply` (no terminator). `.none` (a handler that
/// returned without replying) becomes `internal_error`.
pub fn ctxLineAlloc(gpa: Allocator, id: std.json.Value, reply: types.Reply) Allocator.Error![]u8 {
    return switch (reply) {
        .ok => |json| okRawLineAlloc(gpa, id, json),
        .err => |e| errorLineAlloc(gpa, id, e.code, e.message, e.data),
        .none, .deferred => blk: {
            log.warn("rpc handler returned without replying (G5)", .{});
            break :blk errorLineAlloc(gpa, id, .internal_error, no_reply_message, null);
        },
    };
}

/// `{"id":…,"ok":true,"result":<json>}` with an already encoded result.
pub fn okRawLineAlloc(gpa: Allocator, id: std.json.Value, result_json: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    envelope.writeOkRaw(&aw.writer, id, result_json) catch return error.OutOfMemory;
    const out = aw.written();
    if (!std.unicode.utf8ValidateSlice(out) or std.mem.indexOfAny(u8, out, "\r\n") != null)
        return gpa.dupe(u8, envelope.encode_error_line);
    return aw.toOwnedSlice();
}

/// A failure line; `data_json` is encoded JSON (or null).
pub fn errorLineAlloc(gpa: Allocator, id: std.json.Value, code: errors.Code, message: []const u8, data_json: ?[]const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const data: ?std.json.Value = if (data_json) |text|
        std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return gpa.dupe(u8, envelope.encode_error_line),
        }
    else
        null;
    return envelope.encodeErrorAlloc(gpa, id, .{ .code = code, .message = message, .data = data });
}

/// The reply for a Zig error that escaped a handler (ADR-3.5).
pub fn zigErrorLineAlloc(gpa: Allocator, id: std.json.Value, err: anyerror) Allocator.Error![]u8 {
    const m = errors.fromZig(err);
    if (m.error_name) |name| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        std.json.Stringify.value(.{ .@"error" = name }, .{}, &aw.writer) catch return error.OutOfMemory;
        return errorLineAlloc(gpa, id, m.code, errors.mappedMessage(m), aw.written());
    }
    return errorLineAlloc(gpa, id, m.code, errors.mappedMessage(m), null);
}

// ---------------------------------------------------------------------------
// Deferred completions (any thread)
// ---------------------------------------------------------------------------

const Entry = struct {
    /// The request id, encoded as JSON (owned by `gpa`).
    id_json: []u8,
    /// When it was deferred (stale entries are pruned).
    since_ms: i64,
};

const State = struct {
    gpa: Allocator,
    server: *PipeServer,
    ids: std.AutoHashMapUnmanaged(Token, Entry) = .empty,
};

var mutex: std.Thread.Mutex = .{};
var state: ?State = null;

/// Entries older than this are dropped on the next `deferStart`: their
/// request has long expired (the longest method budget is minutes).
const stale_after_ms: i64 = 30 * 60 * 1000;

/// Binds deferred completions to the control server (rpc/server/mod.zig,
/// at start).
pub fn bind(gpa: Allocator, server: *PipeServer) void {
    mutex.lock();
    defer mutex.unlock();
    std.debug.assert(state == null);
    state = .{ .gpa = gpa, .server = server };
}

/// Drops every pending deferred id; later completions are dropped. Called
/// before the server is freed (the mutex makes in-flight completions
/// finish first).
pub fn unbind() void {
    mutex.lock();
    defer mutex.unlock();
    var s = state orelse return;
    var it = s.ids.valueIterator();
    while (it.next()) |e| s.gpa.free(e.id_json);
    s.ids.deinit(s.gpa);
    state = null;
}

fn tokenOf(d: types.Deferred) Token {
    return .{ .conn_id = d.conn_id, .generation = d.generation, .request_seq = d.request_seq };
}

/// `Ctx.deferReply`: remember the id of request `d` and mark it deferred
/// (a later timeout then says `retryable:false`). No-op without a bound
/// server (in-process and test contexts).
pub fn deferStart(d: types.Deferred, id: std.json.Value) void {
    mutex.lock();
    defer mutex.unlock();
    const s = &(state orelse return);
    const id_json = std.json.Stringify.valueAlloc(s.gpa, id, .{}) catch return;
    const now = std.time.milliTimestamp();
    pruneLocked(s, now);
    const gop = s.ids.getOrPut(s.gpa, tokenOf(d)) catch {
        s.gpa.free(id_json);
        return;
    };
    if (gop.found_existing) s.gpa.free(gop.value_ptr.id_json);
    gop.value_ptr.* = .{ .id_json = id_json, .since_ms = now };
    _ = s.server.markDeferred(tokenOf(d));
}

fn pruneLocked(s: *State, now: i64) void {
    if (s.ids.count() < 256) return;
    var stale: std.ArrayList(Token) = .empty;
    defer stale.deinit(s.gpa);
    var it = s.ids.iterator();
    while (it.next()) |e| {
        if (now - e.value_ptr.since_ms > stale_after_ms) stale.append(s.gpa, e.key_ptr.*) catch return;
    }
    for (stale.items) |t| {
        if (s.ids.fetchRemove(t)) |kv| s.gpa.free(kv.value.id_json);
    }
}

/// Encodes the reply line of deferred request `d` with `build(gpa, id)`
/// and hands it to the transport. Dropped when `d` is unknown.
fn completeWith(d: types.Deferred, ctx: anytype, comptime build: fn (@TypeOf(ctx), Allocator, std.json.Value) Allocator.Error![]u8) void {
    mutex.lock();
    defer mutex.unlock();
    const s = &(state orelse return);
    const kv = s.ids.fetchRemove(tokenOf(d)) orelse return;
    defer s.gpa.free(kv.value.id_json);
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const id = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), kv.value.id_json, .{}) catch .null;
    const line = build(ctx, s.gpa, id) catch return;
    defer s.gpa.free(line);
    _ = s.server.complete(tokenOf(d), line);
}

/// Completes deferred request `d` with `result` (any JSON-encodable value).
pub fn complete(d: types.Deferred, result: anytype) void {
    const Build = struct {
        fn build(r: @TypeOf(result), gpa: Allocator, id: std.json.Value) Allocator.Error![]u8 {
            return envelope.encodeOkAlloc(gpa, id, r);
        }
    };
    completeWith(d, result, Build.build);
}

/// Completes deferred request `d` with an already encoded result.
pub fn completeRaw(d: types.Deferred, result_json: []const u8) void {
    const Build = struct {
        fn build(json: []const u8, gpa: Allocator, id: std.json.Value) Allocator.Error![]u8 {
            return okRawLineAlloc(gpa, id, json);
        }
    };
    completeWith(d, result_json, Build.build);
}

pub const Failure = struct { code: errors.Code, message: []const u8, data_json: ?[]const u8 = null };

/// Completes deferred request `d` with an error.
pub fn completeError(d: types.Deferred, failure: Failure) void {
    const Build = struct {
        fn build(f: Failure, gpa: Allocator, id: std.json.Value) Allocator.Error![]u8 {
            return errorLineAlloc(gpa, id, f.code, f.message, f.data_json);
        }
    };
    completeWith(d, failure, Build.build);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: reply lines encode ok, raw ok and errors as one envelope line" {
    const gpa = testing.allocator;
    const ok = try ctxLineAlloc(gpa, .{ .string = "1" }, .{ .ok = "{\"pong\":true}" });
    defer gpa.free(ok);
    try testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"pong\":true}}", ok);

    const multi = try okRawLineAlloc(gpa, .{ .integer = 2 }, "{\n\"a\": 1\r\n}");
    defer gpa.free(multi);
    try testing.expect(std.mem.indexOfAny(u8, multi, "\r\n") == null);

    const err = try ctxLineAlloc(gpa, .{ .integer = 7 }, .{ .err = .{ .code = .not_found, .message = "Workspace not found", .data = "{\"selector\":\"workspace_id\"}" } });
    defer gpa.free(err);
    try testing.expectEqualStrings("{\"id\":7,\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"Workspace not found\",\"data\":{\"selector\":\"workspace_id\"}}}", err);

    const none = try ctxLineAlloc(gpa, .null, .none);
    defer gpa.free(none);
    try testing.expect(std.mem.indexOf(u8, none, "\"internal_error\"") != null);

    const bad = try errorLineAlloc(gpa, .null, .busy, "Busy", "{not json");
    defer gpa.free(bad);
    try testing.expectEqualStrings(envelope.encode_error_line, bad);
}

test "unit: rpc: escaped zig errors map through errors.fromZig" {
    const gpa = testing.allocator;
    const a = try zigErrorLineAlloc(gpa, .null, error.WorkspaceNotFound);
    defer gpa.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "\"code\":\"not_found\"") != null);
    const b = try zigErrorLineAlloc(gpa, .null, error.Exploded);
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "\"code\":\"internal_error\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"data\":{\"error\":\"Exploded\"}") != null);
    const c = try zigErrorLineAlloc(gpa, .{ .integer = 3 }, error.MissingTitle);
    defer gpa.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "\"code\":\"invalid_params\"") != null);
}

test "unit: rpc: deferred completion without a bound server is dropped" {
    // No server bound: nothing is recorded and completions are no-ops.
    deferStart(.{ .conn_id = 1, .generation = 1, .request_seq = 1 }, .{ .integer = 5 });
    complete(.{ .conn_id = 1, .generation = 1, .request_seq = 1 }, .{ .done = true });
    completeError(.{ .conn_id = 1, .generation = 1, .request_seq = 1 }, .{ .code = .busy, .message = "Busy" });
}
