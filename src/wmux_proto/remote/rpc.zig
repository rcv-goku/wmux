//! Control messages of the wmuxd-remote protocol (ADR-13).
//!
//! Request:  `{"id":<int|string>,"method":"<name>","params":{...}}`
//! Reply:    `{"id":...,"ok":true,"result":{...}}` or
//!           `{"id":...,"ok":false,"error":{"code":"...","message":"..."}}`
//! Event:    `{"event":"<name>","params":{...}}` (daemon to client, unsolicited)
//!
//! The shapes mirror the v2 envelope (ADR-3.4) so one client codec serves
//! both. Every encoder writes exactly one line including its `\n`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Protocol version spoken by this package. `hello` rejects any other.
pub const protocol_version: u32 = 1;

/// Daemon version reported by `hello` and `wmuxd-remote version`.
pub const daemon_version = "0.1.0";

pub const Method = enum {
    hello,
    ping,
    session_open,
    session_close,
    session_attach,
    session_resize,
    session_detach,
    session_status,
    pty_attach,
    pty_write,
    pty_resize,
    pty_detach,
    pty_close,
    pty_list,
    fs_put,
    fs_get,
    proxy_open,
    proxy_close,
    proxy_write,
    proxy_stream_subscribe,
    relay_accept,

    const names = [_]struct { []const u8, Method }{
        .{ "hello", .hello },
        .{ "ping", .ping },
        .{ "session.open", .session_open },
        .{ "session.close", .session_close },
        .{ "session.attach", .session_attach },
        .{ "session.resize", .session_resize },
        .{ "session.detach", .session_detach },
        .{ "session.status", .session_status },
        .{ "pty.attach", .pty_attach },
        .{ "pty.write", .pty_write },
        .{ "pty.resize", .pty_resize },
        .{ "pty.detach", .pty_detach },
        .{ "pty.close", .pty_close },
        .{ "pty.list", .pty_list },
        .{ "fs.put", .fs_put },
        .{ "fs.get", .fs_get },
        .{ "proxy.open", .proxy_open },
        .{ "proxy.close", .proxy_close },
        .{ "proxy.write", .proxy_write },
        .{ "proxy.stream.subscribe", .proxy_stream_subscribe },
        .{ "relay.accept", .relay_accept },
    };
    const map = std.StaticStringMap(Method).initComptime(names);

    pub fn parse(name: []const u8) ?Method {
        return map.get(name);
    }

    pub fn wireName(m: Method) []const u8 {
        inline for (names) |n| if (n[1] == m) return n[0];
        unreachable;
    }

    /// Methods declared by the protocol but not served by this package.
    pub fn isStub(m: Method) bool {
        return switch (m) {
            .proxy_open, .proxy_close, .proxy_write, .proxy_stream_subscribe, .relay_accept => true,
            else => false,
        };
    }
};

/// Daemon-advertised capabilities (`hello.result.capabilities`). Stub
/// methods are deliberately absent; a persistent daemon adds `cap_persistent`.
pub const capabilities = [_][]const u8{
    "fs.get",
    "fs.put",
    "pty.binary_frames",
    "pty.replay",
    "pty.session",
    "session.resize.smallest_wins",
};

/// Capability a client lists in `hello.params.capabilities` to receive PTY
/// data as binary frames; without it data arrives as `pty.data` events.
pub const cap_binary_frames = "pty.binary_frames";
/// Only advertised by a persistent (`--persistent`) daemon.
pub const cap_persistent = "pty.session.persistent_daemon";

pub const ErrorCode = enum {
    parse_error,
    invalid_request,
    method_not_found,
    invalid_params,
    hello_required,
    version_mismatch,
    not_found,
    not_supported,
    invalid_state,
    too_large,
    busy,
    io_error,
    internal_error,
};

/// Fixed message for the proxy/relay stubs.
pub fn notImplementedMessage(buf: []u8, m: Method) []const u8 {
    return std.fmt.bufPrint(buf, "{s} is not implemented in this package", .{m.wireName()}) catch "not implemented in this package";
}

pub const Id = union(enum) {
    int: i64,
    string: []const u8,

    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .int => |v| try jw.write(v),
            .string => |s| try jw.write(s),
        }
    }
};

/// Max length of a string request id.
pub const max_id_len = 128;

pub const Request = struct {
    id: ?Id,
    method: []const u8,
    /// `.null` when absent; otherwise must be an object.
    params: std.json.Value,
};

pub const RequestError = error{ ParseError, InvalidRequest } || Allocator.Error;

/// Parses one control line. Strings are allocated in `arena`. ParseError
/// means malformed JSON (reply `parse_error` with a null id); InvalidRequest
/// means valid JSON with a bad shape (reply `invalid_request`, using
/// `bestEffortId` for the id).
pub fn parseRequest(arena: Allocator, line: []const u8) RequestError!Request {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    if (root != .object) return error.InvalidRequest;
    const obj = root.object;
    const id = try idFrom(obj.get("id"));
    const method = obj.get("method") orelse return error.InvalidRequest;
    if (method != .string or method.string.len == 0) return error.InvalidRequest;
    const params = obj.get("params") orelse std.json.Value.null;
    if (params != .object and params != .null) return error.InvalidRequest;
    return .{ .id = id, .method = method.string, .params = params };
}

fn idFrom(v: ?std.json.Value) error{InvalidRequest}!?Id {
    const val = v orelse return null;
    return switch (val) {
        .null => null,
        .integer => |i| .{ .int = i },
        .string => |s| if (s.len <= max_id_len) .{ .string = s } else error.InvalidRequest,
        else => error.InvalidRequest,
    };
}

/// The id of a request that failed shape validation, if one is usable.
pub fn bestEffortId(arena: Allocator, line: []const u8) ?Id {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (root != .object) return null;
    return idFrom(root.object.get("id")) catch null;
}

/// Decodes `params` into `T` (unknown fields ignored; missing required
/// fields and type mismatches give InvalidParams).
pub fn parseParams(comptime T: type, arena: Allocator, params: std.json.Value) error{ InvalidParams, OutOfMemory }!T {
    const v: std.json.Value = if (params == .null) .{ .object = .init(arena) } else params;
    return std.json.parseFromValueLeaky(T, arena, v, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidParams,
    };
}

/// Like `jw.write`, but a zero-field struct or tuple (`.{}`) becomes `{}`
/// instead of `[]`.
fn writeObject(jw: *std.json.Stringify, v: anytype) Writer.Error!void {
    const T = @TypeOf(v);
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".fields.len == 0) {
        try jw.beginObject();
        try jw.endObject();
    } else try jw.write(v);
}

const stringify_opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

pub fn writeOk(w: *Writer, id: ?Id, result: anytype) Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w, .options = stringify_opts };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("ok");
    try jw.write(true);
    try jw.objectField("result");
    try writeObject(&jw, result);
    try jw.endObject();
    try w.writeByte('\n');
}

pub fn writeError(w: *Writer, id: ?Id, code: ErrorCode, message: []const u8) Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w, .options = stringify_opts };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("ok");
    try jw.write(false);
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(@tagName(code));
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
    try w.writeByte('\n');
}

pub fn writeEvent(w: *Writer, name: []const u8, params: anytype) Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w, .options = stringify_opts };
    try jw.beginObject();
    try jw.objectField("event");
    try jw.write(name);
    try jw.objectField("params");
    try writeObject(&jw, params);
    try jw.endObject();
    try w.writeByte('\n');
}

/// Writes a request line (client side).
pub fn writeRequest(w: *Writer, id: ?Id, method: Method, params: anytype) Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w, .options = stringify_opts };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("method");
    try jw.write(method.wireName());
    try jw.objectField("params");
    try writeObject(&jw, params);
    try jw.endObject();
    try w.writeByte('\n');
}

/// A daemon-to-client line, decoded by the client.
pub const Incoming = union(enum) {
    reply: struct {
        id: ?Id,
        ok: bool,
        /// `.null` on errors.
        result: std.json.Value,
        code: ?[]const u8 = null,
        message: ?[]const u8 = null,
    },
    event: struct {
        name: []const u8,
        params: std.json.Value,
    },
};

pub fn parseIncoming(arena: Allocator, line: []const u8) RequestError!Incoming {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    if (root != .object) return error.InvalidRequest;
    const obj = root.object;
    if (obj.get("event")) |ev| {
        if (ev != .string) return error.InvalidRequest;
        return .{ .event = .{ .name = ev.string, .params = obj.get("params") orelse .null } };
    }
    const ok = obj.get("ok") orelse return error.InvalidRequest;
    if (ok != .bool) return error.InvalidRequest;
    const id = try idFrom(obj.get("id"));
    if (ok.bool) return .{ .reply = .{ .id = id, .ok = true, .result = obj.get("result") orelse .null } };
    const e = obj.get("error") orelse return error.InvalidRequest;
    if (e != .object) return error.InvalidRequest;
    const code = e.object.get("code") orelse return error.InvalidRequest;
    const msg = e.object.get("message") orelse return error.InvalidRequest;
    if (code != .string or msg != .string) return error.InvalidRequest;
    return .{ .reply = .{ .id = id, .ok = false, .result = .null, .code = code.string, .message = msg.string } };
}

const testing = std.testing;

test "unit: remote-protocol: method names round trip and stubs are flagged" {
    inline for (@typeInfo(Method).@"enum".fields) |f| {
        const m: Method = @enumFromInt(f.value);
        try testing.expectEqual(m, Method.parse(m.wireName()).?);
    }
    try testing.expectEqual(Method.proxy_stream_subscribe, Method.parse("proxy.stream.subscribe").?);
    try testing.expect(Method.parse("pty.Attach") == null);
    try testing.expect(Method.parse("") == null);
    try testing.expect(Method.relay_accept.isStub());
    try testing.expect(!Method.pty_attach.isStub());
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("proxy.open is not implemented in this package", notImplementedMessage(&buf, .proxy_open));
    for (capabilities) |c| try testing.expect(!std.mem.startsWith(u8, c, "proxy"));
}

test "unit: remote-protocol: request parsing accepts ids and rejects bad shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseRequest(a, "{\"id\":7,\"method\":\"ping\"}");
    try testing.expectEqual(@as(i64, 7), r.id.?.int);
    try testing.expectEqualStrings("ping", r.method);
    try testing.expect(r.params == .null);
    const s = try parseRequest(a, "{\"id\":\"a-☃\",\"method\":\"pty.list\",\"params\":{}}");
    try testing.expectEqualStrings("a-☃", s.id.?.string);
    try testing.expect((try parseRequest(a, "{\"method\":\"ping\"}")).id == null);
    try testing.expectError(error.ParseError, parseRequest(a, "{\"id\":1,"));
    try testing.expectError(error.ParseError, parseRequest(a, ""));
    try testing.expectError(error.InvalidRequest, parseRequest(a, "[1]"));
    try testing.expectError(error.InvalidRequest, parseRequest(a, "{\"id\":1}"));
    try testing.expectError(error.InvalidRequest, parseRequest(a, "{\"id\":1,\"method\":\"\"}"));
    try testing.expectError(error.InvalidRequest, parseRequest(a, "{\"id\":1.5,\"method\":\"ping\"}"));
    try testing.expectError(error.InvalidRequest, parseRequest(a, "{\"id\":1,\"method\":\"ping\",\"params\":[]}"));
    const long = "{\"id\":\"" ++ "x" ** 129 ++ "\",\"method\":\"ping\"}";
    try testing.expectError(error.InvalidRequest, parseRequest(a, long));
    try testing.expectEqual(@as(i64, 3), bestEffortId(a, "{\"id\":3,\"method\":5}").?.int);
    try testing.expect(bestEffortId(a, "nope") == null);
}

test "unit: remote-protocol: replies and events encode as single lines and parse back" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeOk(&aw.writer, .{ .int = 1 }, .{ .pong = true, .note = "line\nbreak" });
    try writeError(&aw.writer, .{ .string = "x" }, .not_found, "session not found");
    try writeEvent(&aw.writer, "pty.exit", .{ .session_id = "s1", .exit_code = @as(?i64, null) });
    try writeRequest(&aw.writer, null, .pty_list, .{});
    const out = aw.written();
    var it = std.mem.splitScalar(u8, out[0 .. out.len - 1], '\n');

    const ok = (try parseIncoming(a, it.next().?)).reply;
    try testing.expect(ok.ok);
    try testing.expectEqual(@as(i64, 1), ok.id.?.int);
    try testing.expectEqualStrings("line\nbreak", ok.result.object.get("note").?.string);

    const err = (try parseIncoming(a, it.next().?)).reply;
    try testing.expect(!err.ok);
    try testing.expectEqualStrings("not_found", err.code.?);
    try testing.expectEqualStrings("session not found", err.message.?);

    const ev = (try parseIncoming(a, it.next().?)).event;
    try testing.expectEqualStrings("pty.exit", ev.name);
    try testing.expect(ev.params.object.get("exit_code") == null);

    const req = try parseRequest(a, it.next().?);
    try testing.expectEqualStrings("pty.list", req.method);
    try testing.expect(req.id == null);
    try testing.expect(it.next() == null);

    try testing.expectError(error.InvalidRequest, parseIncoming(a, "{\"ok\":false}"));
    try testing.expectError(error.InvalidRequest, parseIncoming(a, "{\"id\":1}"));
}

test "unit: remote-protocol: parseParams maps missing and mistyped fields to InvalidParams" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const P = struct { session_id: []const u8, cols: u32 = 80 };
    const r = try parseRequest(a, "{\"id\":1,\"method\":\"x\",\"params\":{\"session_id\":\"s\",\"extra\":[1]}}");
    const p = try parseParams(P, a, r.params);
    try testing.expectEqualStrings("s", p.session_id);
    try testing.expectEqual(@as(u32, 80), p.cols);
    try testing.expectError(error.InvalidParams, parseParams(P, a, .null));
    const bad = try parseRequest(a, "{\"id\":1,\"method\":\"x\",\"params\":{\"session_id\":\"s\",\"cols\":-1}}");
    try testing.expectError(error.InvalidParams, parseParams(P, a, bad.params));
    const huge = try parseRequest(a, "{\"id\":1,\"method\":\"x\",\"params\":{\"session_id\":\"s\",\"cols\":99999999999}}");
    try testing.expectError(error.InvalidParams, parseParams(P, a, huge.params));
}
