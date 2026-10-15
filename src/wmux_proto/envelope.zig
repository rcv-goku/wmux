//! cmux v2 JSON envelope: requests, replies, error objects, protocol sniffing and
//! the `_cmux_capability_v1` line prefix (ADR-3.4).
//!
//! Lines are handled without their terminator; encoders never emit a raw
//! newline, so the caller appends exactly one `\n` per reply.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const errors = @import("errors.zig");
const Uuid = @import("uuid.zig").Uuid;

/// Capability envelope keyword (cmux wire format).
pub const capability_prefix = "_cmux_capability_v1";

/// Fixed reply when a reply cannot be encoded.
pub const encode_error_line = "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}";

/// Max request id length the CLI generates or accepts.
pub const max_request_id_len = 128;

/// Strips one trailing `\r` (CRLF framing) and, if present, `\n`.
pub fn trimLineEnd(line: []const u8) []const u8 {
    var t = line;
    if (t.len > 0 and t[t.len - 1] == '\n') t = t[0 .. t.len - 1];
    if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
    return t;
}

/// Blank lines (only spaces/tabs/CR) are ignored by the framer.
pub fn isBlankLine(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t' and c != '\r' and c != '\n') return false;
    return true;
}

pub const Capability = struct {
    /// Token when the line carried the envelope, else null.
    token: ?[]const u8,
    /// The rest of the line (what gets sniffed and dispatched).
    payload: []const u8,
};

/// Splits `_cmux_capability_v1 <token> <payload>`. Lines without the prefix
/// pass through with `token == null`. The prefix must be followed by a space
/// and a non-empty token; `token` ends at the next space or end of line.
pub fn splitCapability(line: []const u8) error{MalformedCapability}!Capability {
    if (!std.mem.startsWith(u8, line, capability_prefix)) return .{ .token = null, .payload = line };
    const rest = line[capability_prefix.len..];
    if (rest.len == 0) return error.MalformedCapability;
    // A longer word such as `_cmux_capability_v10` is not the envelope.
    if (rest[0] != ' ') return .{ .token = null, .payload = line };
    const after = rest[1..];
    const end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    if (end == 0) return error.MalformedCapability;
    const token = after[0..end];
    const payload = if (end < after.len) after[end + 1 ..] else after[after.len..];
    return .{ .token = token, .payload = payload };
}

/// Writes the envelope prefix `_cmux_capability_v1 <token> `.
pub fn writeCapabilityPrefix(w: *Writer, token: []const u8) Writer.Error!void {
    try w.writeAll(capability_prefix);
    try w.writeByte(' ');
    try w.writeAll(token);
    try w.writeByte(' ');
}

pub const Protocol = enum { v2, legacy_json, text_v1 };

/// Per-line protocol sniffing: first non-space byte `{` with a top-level
/// `"method"` key → v2, with a `"cmd"` key → legacy wmux JSON. A `{` line
/// with neither key (or unparseable JSON) is v2, so the client gets the v2
/// `parse_error`/`invalid_request` reply. Anything else → cmux text-v1.
pub fn sniff(payload: []const u8) Protocol {
    const t = std.mem.trimLeft(u8, payload, " \t\r\n");
    if (t.len == 0 or t[0] != '{') return .text_v1;
    var fba_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), t);
    var has_cmd = false;
    if ((scanner.next() catch return .v2) != .object_begin) return .v2;
    while (true) {
        const tok = scanner.next() catch break;
        switch (tok) {
            .string => |key| {
                if (std.mem.eql(u8, key, "method")) return .v2;
                if (std.mem.eql(u8, key, "cmd")) has_cmd = true;
            },
            // Escaped or split keys are never "method"/"cmd" in practice.
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {
                skipRestOfString(&scanner) catch break;
            },
            .object_end, .end_of_document => break,
            else => break,
        }
        scanner.skipValue() catch break;
    }
    return if (has_cmd) .legacy_json else .v2;
}

fn skipRestOfString(scanner: *std.json.Scanner) !void {
    while (true) switch (try scanner.next()) {
        .string => return,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
        else => return error.SyntaxError,
    };
}

/// A validated v2 request. Strings point into the parse arena.
pub const Request = struct {
    /// Echoed id: string or number; `.null` when absent or of another type.
    id: std.json.Value,
    /// Whitespace-trimmed, non-empty.
    method: []const u8,
    /// `{}` when absent or not an object.
    params: std.json.ObjectMap,
    /// Optional top-level `automation_origin` object, passed through.
    automation_origin: ?std.json.Value = null,
};

pub const Rejection = struct {
    id: std.json.Value,
    code: errors.Code,
    message: []const u8,
};

pub const Parsed = union(enum) {
    request: Request,
    rejected: Rejection,
};

/// Pre-dispatch checks in cmux order: invalid UTF-8 → `invalid_utf8`; bad
/// JSON → `parse_error "Invalid JSON"`; not an object → `invalid_request
/// "Expected JSON object"`; missing/empty/non-string method →
/// `invalid_request "Missing method"`. Unknown methods are the router's job
/// (`errors.msg.unknown_method`). `payload` must already be stripped of the
/// capability prefix. Values are allocated in `arena`.
pub fn parseRequest(arena: Allocator, payload: []const u8) Allocator.Error!Parsed {
    if (!std.unicode.utf8ValidateSlice(payload))
        return reject(.null, .invalid_utf8, errors.msg.invalid_utf8);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return reject(.null, .parse_error, errors.msg.invalid_json),
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return reject(.null, .invalid_request, errors.msg.expected_object),
    };
    const id = normalizeId(obj.get("id"));
    const method_raw = switch (obj.get("method") orelse .null) {
        .string => |s| s,
        else => return reject(id, .invalid_request, errors.msg.missing_method),
    };
    const method = std.mem.trim(u8, method_raw, " \t\r\n");
    if (method.len == 0) return reject(id, .invalid_request, errors.msg.missing_method);
    const params = switch (obj.get("params") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.init(arena),
    };
    const origin: ?std.json.Value = if (obj.get("automation_origin")) |v| switch (v) {
        .object => v,
        else => null,
    } else null;
    return .{ .request = .{ .id = id, .method = method, .params = params, .automation_origin = origin } };
}

fn reject(id: std.json.Value, code: errors.Code, message: []const u8) Parsed {
    return .{ .rejected = .{ .id = id, .code = code, .message = message } };
}

/// Keeps string and number ids; anything else (absent, null, bool, array,
/// object) echoes as `null`.
pub fn normalizeId(v: ?std.json.Value) std.json.Value {
    const id = v orelse return .null;
    return switch (id) {
        .string, .integer, .float, .number_string => id,
        else => .null,
    };
}

/// The `error` object of a failure reply.
pub const ErrorObject = struct {
    code: errors.Code,
    message: []const u8,
    data: ?std.json.Value = null,
    reason: ?[]const u8 = null,
    action: ?[]const u8 = null,
    details: ?std.json.Value = null,
};

/// `{"id":…,"ok":true,"result":<result>}`; `result` is any value
/// `std.json.Stringify` accepts. No trailing newline.
pub fn writeOk(w: *Writer, id: std.json.Value, result: anytype) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("result");
    try s.write(result);
    try s.endObject();
}

/// Like `writeOk` with `result_json` already encoded. Raw CR/LF bytes (only
/// legal as insignificant whitespace in valid JSON) are written as spaces so
/// the reply stays one line.
pub fn writeOkRaw(w: *Writer, id: std.json.Value, result_json: []const u8) Writer.Error!void {
    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"ok\":true,\"result\":");
    var start: usize = 0;
    for (result_json, 0..) |c, i| {
        if (c == '\n' or c == '\r') {
            try w.writeAll(result_json[start..i]);
            try w.writeByte(' ');
            start = i + 1;
        }
    }
    try w.writeAll(result_json[start..]);
    try w.writeByte('}');
}

/// `{"id":…,"ok":false,"error":{code,message,data?,reason?,action?,details?}}`.
pub fn writeError(w: *Writer, id: std.json.Value, e: ErrorObject) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("ok");
    try s.write(false);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(e.code.text());
    try s.objectField("message");
    try s.write(e.message);
    if (e.data) |v| {
        try s.objectField("data");
        try s.write(v);
    }
    if (e.reason) |v| {
        try s.objectField("reason");
        try s.write(v);
    }
    if (e.action) |v| {
        try s.objectField("action");
        try s.write(v);
    }
    if (e.details) |v| {
        try s.objectField("details");
        try s.write(v);
    }
    try s.endObject();
    try s.endObject();
}

/// Heap reply line for a success. Falls back to `encode_error_line` when the
/// encoded line is not valid single-line UTF-8 (possible through custom
/// `jsonStringify` methods). Note that std.json.Stringify encodes a
/// non-UTF-8 `[]const u8` as an array of numbers, which stays valid JSON.
/// Only allocation failure is an error.
pub fn encodeOkAlloc(gpa: Allocator, id: std.json.Value, result: anytype) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeOk(&aw.writer, id, result) catch return error.OutOfMemory;
    return finishLine(gpa, &aw);
}

/// Heap reply line for a failure, with the same fallback as `encodeOkAlloc`;
/// also falls back when `message`, `reason` or `action` is not valid UTF-8
/// (std.json.Stringify would otherwise encode them as byte arrays).
pub fn encodeErrorAlloc(gpa: Allocator, id: std.json.Value, e: ErrorObject) Allocator.Error![]u8 {
    for ([_]?[]const u8{ e.message, e.reason, e.action }) |str| {
        if (str) |t| if (!std.unicode.utf8ValidateSlice(t)) return gpa.dupe(u8, encode_error_line);
    }
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeError(&aw.writer, id, e) catch return error.OutOfMemory;
    return finishLine(gpa, &aw);
}

/// Heap reply line for a `parseRequest` rejection.
pub fn encodeRejectionAlloc(gpa: Allocator, r: Rejection) Allocator.Error![]u8 {
    return encodeErrorAlloc(gpa, r.id, .{ .code = r.code, .message = r.message });
}

fn finishLine(gpa: Allocator, aw: *Writer.Allocating) Allocator.Error![]u8 {
    const out = aw.written();
    if (!std.unicode.utf8ValidateSlice(out) or std.mem.indexOfAny(u8, out, "\r\n") != null)
        return gpa.dupe(u8, encode_error_line);
    return aw.toOwnedSlice();
}

// ----- client side -----

/// A fresh request id (uppercase UUID text, always valid per `isValidRequestId`).
pub fn newRequestId() [Uuid.text_len]u8 {
    return Uuid.v4().toText();
}

/// Client request id rule: 1..128 bytes of valid UTF-8 without control (Cc)
/// or format (Cf) characters.
pub fn isValidRequestId(s: []const u8) bool {
    if (s.len == 0 or s.len > max_request_id_len) return false;
    const view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isControl(cp) or isFormat(cp)) return false;
    }
    return true;
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F);
}

/// Unicode general category Cf (format characters).
fn isFormat(cp: u21) bool {
    return switch (cp) {
        0x00AD, 0x061C, 0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2, 0x180E, 0xFEFF => true,
        0x0600...0x0605, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F => true,
        0xFFF9...0xFFFB, 0x110BD, 0x110CD, 0x13430...0x1343F, 0x1BCA0...0x1BCA3 => true,
        0x1D173...0x1D17A, 0xE0001, 0xE0020...0xE007F => true,
        else => false,
    };
}

/// Writes a v2 request line `{"id":"…","method":"…","params":…}`.
/// `params_json` must be an encoded JSON object (or null for `{}`).
pub fn writeRequest(w: *Writer, id: []const u8, method: []const u8, params_json: ?[]const u8) Writer.Error!void {
    try w.writeAll("{\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, w);
    try w.writeAll(",\"method\":");
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    try w.writeAll(",\"params\":");
    const p = params_json orelse "{}";
    var start: usize = 0;
    for (p, 0..) |c, i| {
        if (c == '\n' or c == '\r') {
            try w.writeAll(p[start..i]);
            try w.writeByte(' ');
            start = i + 1;
        }
    }
    try w.writeAll(p[start..]);
    try w.writeByte('}');
}

/// The `error` object of a reply as received (unknown codes preserved).
pub const ReplyError = struct {
    code: []const u8,
    /// `code` when it is one of `errors.Code`.
    known: ?errors.Code,
    message: []const u8,
    data: ?std.json.Value = null,
    reason: ?[]const u8 = null,
    action: ?[]const u8 = null,
    details: ?std.json.Value = null,
};

pub const Reply = struct {
    id: std.json.Value,
    ok: bool,
    /// `.null` when absent.
    result: std.json.Value,
    err: ?ReplyError,
};

pub const ReplyParseError = error{ InvalidReply, OutOfMemory };

/// Parses a reply line. Text replies (`ERROR: …`) are not JSON: check
/// `isTextError` first and surface those verbatim.
pub fn parseReply(arena: Allocator, line: []const u8) ReplyParseError!Reply {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimLineEnd(line), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReply,
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidReply,
    };
    const ok = switch (obj.get("ok") orelse return error.InvalidReply) {
        .bool => |b| b,
        else => return error.InvalidReply,
    };
    var reply: Reply = .{
        .id = obj.get("id") orelse .null,
        .ok = ok,
        .result = obj.get("result") orelse .null,
        .err = null,
    };
    if (!ok) {
        const eobj = switch (obj.get("error") orelse return error.InvalidReply) {
            .object => |o| o,
            // Legacy wmux replies carry a bare string error.
            .string => |s| {
                reply.err = .{ .code = "", .known = null, .message = s };
                return reply;
            },
            else => return error.InvalidReply,
        };
        const code = optString(eobj, "code") orelse "";
        reply.err = .{
            .code = code,
            .known = errors.Code.parse(code),
            .message = optString(eobj, "message") orelse "",
            .data = eobj.get("data"),
            .reason = optString(eobj, "reason"),
            .action = optString(eobj, "action"),
            .details = eobj.get("details"),
        };
    }
    return reply;
}

fn optString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// True when the reply echoes the string id we sent.
pub fn idMatches(expected: []const u8, got: std.json.Value) bool {
    return switch (got) {
        .string => |s| std.mem.eql(u8, s, expected),
        else => false,
    };
}

/// Raw `ERROR:` text reply (e.g. access denied before the JSON stage).
pub fn isTextError(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "ERROR:");
}

const testing = std.testing;

fn expectRejected(payload: []const u8, code: errors.Code, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseRequest(arena_state.allocator(), payload);
    try testing.expect(p == .rejected);
    try testing.expectEqual(code, p.rejected.code);
    try testing.expectEqualStrings(message, p.rejected.message);
}

test "unit: proto: envelope parses a v2 request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseRequest(arena_state.allocator(),
        \\{"id":"3f2a","method":"  workspace.create\t","params":{"title":"api","focus":false},"automation_origin":{"rule":"x"}}
    );
    const r = p.request;
    try testing.expectEqualStrings("3f2a", r.id.string);
    try testing.expectEqualStrings("workspace.create", r.method);
    try testing.expectEqualStrings("api", r.params.get("title").?.string);
    try testing.expect(r.automation_origin != null);
}

test "unit: proto: envelope id forms and params defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(@as(i64, 7), (try parseRequest(a, "{\"id\":7,\"method\":\"m\"}")).request.id.integer);
    try testing.expect((try parseRequest(a, "{\"method\":\"m\"}")).request.id == .null);
    try testing.expect((try parseRequest(a, "{\"id\":true,\"method\":\"m\"}")).request.id == .null);
    try testing.expect((try parseRequest(a, "{\"id\":{},\"method\":\"m\"}")).request.id == .null);
    try testing.expect((try parseRequest(a, "{\"id\":1.5,\"method\":\"m\"}")).request.id == .float);
    const big = (try parseRequest(a, "{\"id\":123456789012345678901234567890,\"method\":\"m\"}")).request.id;
    try testing.expect(big == .number_string or big == .float);
    try testing.expectEqual(@as(usize, 0), (try parseRequest(a, "{\"method\":\"m\",\"params\":[1]}")).request.params.count());
    try testing.expectEqual(@as(usize, 0), (try parseRequest(a, "{\"method\":\"m\",\"params\":null}")).request.params.count());
    try testing.expect((try parseRequest(a, "{\"method\":\"m\",\"automation_origin\":3}")).request.automation_origin == null);
}

test "unit: proto: envelope pre-dispatch errors use cmux strings" {
    try expectRejected("{\"method\":\"m\",\"x\":\"\xff\"}", .invalid_utf8, "Invalid UTF-8");
    try expectRejected("{nope", .parse_error, "Invalid JSON");
    try expectRejected("", .parse_error, "Invalid JSON");
    try expectRejected("{\"method\":\"m\"} trailing", .parse_error, "Invalid JSON");
    try expectRejected("[1,2]", .invalid_request, "Expected JSON object");
    try expectRejected("\"str\"", .invalid_request, "Expected JSON object");
    try expectRejected("{}", .invalid_request, "Missing method");
    try expectRejected("{\"method\":\"   \"}", .invalid_request, "Missing method");
    try expectRejected("{\"method\":5}", .invalid_request, "Missing method");
    try expectRejected("{\"method\":null}", .invalid_request, "Missing method");
}

test "unit: proto: envelope rejection keeps id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseRequest(arena_state.allocator(), "{\"id\":9}");
    try testing.expectEqual(@as(i64, 9), p.rejected.id.integer);
    const line = try encodeRejectionAlloc(testing.allocator, p.rejected);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"id\":9,\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"Missing method\"}}", line);
}

test "unit: proto: envelope encodes ok replies" {
    const gpa = testing.allocator;
    const a = try encodeOkAlloc(gpa, .{ .string = "1" }, .{ .pong = true });
    defer gpa.free(a);
    try testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"pong\":true}}", a);
    const b = try encodeOkAlloc(gpa, .{ .integer = 7 }, .{ .text = "line1\nline2" });
    defer gpa.free(b);
    try testing.expectEqualStrings("{\"id\":7,\"ok\":true,\"result\":{\"text\":\"line1\\nline2\"}}", b);
    const c = try encodeOkAlloc(gpa, .null, struct {}{});
    defer gpa.free(c);
    try testing.expectEqualStrings("{\"id\":null,\"ok\":true,\"result\":{}}", c);
}

test "unit: proto: envelope raw result stays one line" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeOkRaw(&aw.writer, .{ .integer = 3 }, "{\n  \"a\": 1\r\n}");
    try testing.expectEqualStrings("{\"id\":3,\"ok\":true,\"result\":{   \"a\": 1  }}", aw.written());
}

test "unit: proto: envelope encodes error objects" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var data = std.json.ObjectMap.init(arena_state.allocator());
    try data.put("selector", .{ .string = "workspace_id" });
    const line = try encodeErrorAlloc(gpa, .{ .integer = 7 }, .{ .code = .not_found, .message = "Workspace not found", .data = .{ .object = data } });
    defer gpa.free(line);
    try testing.expectEqualStrings("{\"id\":7,\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"Workspace not found\",\"data\":{\"selector\":\"workspace_id\"}}}", line);
    const full = try encodeErrorAlloc(gpa, .null, .{ .code = .forbidden, .message = "m", .reason = "r", .action = "do\nit", .details = .{ .integer = 1 } });
    defer gpa.free(full);
    try testing.expectEqualStrings("{\"id\":null,\"ok\":false,\"error\":{\"code\":\"forbidden\",\"message\":\"m\",\"reason\":\"r\",\"action\":\"do\\nit\",\"details\":1}}", full);
}

const RawBytes = struct {
    bytes: []const u8,
    pub fn jsonStringify(self: RawBytes, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.bytes);
        jws.endWriteRaw();
    }
};

test "unit: proto: envelope encode_error fallback on invalid utf8" {
    const gpa = testing.allocator;
    const line = try encodeOkAlloc(gpa, .null, RawBytes{ .bytes = "\"bad\xff\"" });
    defer gpa.free(line);
    try testing.expectEqualStrings(encode_error_line, line);
    const nl = try encodeOkAlloc(gpa, .null, RawBytes{ .bytes = "[1,\n2]" });
    defer gpa.free(nl);
    try testing.expectEqualStrings(encode_error_line, nl);
    const arr = try encodeOkAlloc(gpa, .null, .{ .text = @as([]const u8, "b\xff") });
    defer gpa.free(arr);
    try testing.expectEqualStrings("{\"id\":null,\"ok\":true,\"result\":{\"text\":[98,255]}}", arr);
    const e = try encodeErrorAlloc(gpa, .null, .{ .code = .internal_error, .message = "\xc3" });
    defer gpa.free(e);
    try testing.expectEqualStrings(encode_error_line, e);
}

test "unit: proto: envelope reply round trip with unicode" {
    const gpa = testing.allocator;
    const line = try encodeOkAlloc(gpa, .{ .string = "id-\u{1F600}" }, .{ .title = "J\u{f6}rg \u{4e2d}" });
    defer gpa.free(line);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const r = try parseReply(arena_state.allocator(), line);
    try testing.expect(r.ok);
    try testing.expect(idMatches("id-\u{1F600}", r.id));
    try testing.expectEqualStrings("J\u{f6}rg \u{4e2d}", r.result.object.get("title").?.string);
}

test "unit: proto: envelope parses error replies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseReply(a, "{\"id\":\"x\",\"ok\":false,\"error\":{\"code\":\"rate_limited\",\"message\":\"slow\",\"data\":{\"retry_after_ms\":100},\"reason\":\"why\"}}\r\n");
    try testing.expect(!r.ok);
    try testing.expectEqual(@as(?errors.Code, .rate_limited), r.err.?.known);
    try testing.expectEqualStrings("why", r.err.?.reason.?);
    try testing.expectEqual(@as(i64, 100), r.err.?.data.?.object.get("retry_after_ms").?.integer);
    const unknown = try parseReply(a, "{\"ok\":false,\"error\":{\"code\":\"brand_new\",\"message\":\"m\"}}");
    try testing.expectEqual(@as(?errors.Code, null), unknown.err.?.known);
    try testing.expectEqualStrings("brand_new", unknown.err.?.code);
    const legacy = try parseReply(a, "{\"id\":1,\"ok\":false,\"error\":\"UnknownWorkspace\"}");
    try testing.expectEqualStrings("UnknownWorkspace", legacy.err.?.message);
    try testing.expectEqualStrings(encode_error_line, encode_error_line);
    const fallback = try parseReply(a, encode_error_line);
    try testing.expectEqual(@as(?errors.Code, .encode_error), fallback.err.?.known);
}

test "unit: proto: envelope reply parse failures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.InvalidReply, parseReply(a, ""));
    try testing.expectError(error.InvalidReply, parseReply(a, "ERROR: access denied"));
    try testing.expectError(error.InvalidReply, parseReply(a, "[]"));
    try testing.expectError(error.InvalidReply, parseReply(a, "{\"id\":1}"));
    try testing.expectError(error.InvalidReply, parseReply(a, "{\"ok\":\"yes\"}"));
    try testing.expectError(error.InvalidReply, parseReply(a, "{\"ok\":false}"));
    try testing.expect(isTextError("ERROR: access denied"));
    try testing.expect(!isTextError("{\"ok\":true}"));
}

test "unit: proto: envelope id matching" {
    try testing.expect(idMatches("abc", .{ .string = "abc" }));
    try testing.expect(!idMatches("abc", .{ .string = "abd" }));
    try testing.expect(!idMatches("1", .{ .integer = 1 }));
    try testing.expect(!idMatches("abc", .null));
    try testing.expectEqualStrings("Mismatched v2 response id", errors.msg.mismatched_response_id);
}

test "unit: proto: envelope request id validation" {
    const id = newRequestId();
    try testing.expect(isValidRequestId(&id));
    try testing.expect(isValidRequestId("a"));
    try testing.expect(isValidRequestId("J\u{f6}rg-\u{1F600}"));
    try testing.expect(isValidRequestId("x" ** 128));
    try testing.expect(!isValidRequestId("x" ** 129));
    try testing.expect(!isValidRequestId(""));
    try testing.expect(!isValidRequestId("a\nb"));
    try testing.expect(!isValidRequestId("a\x7f"));
    try testing.expect(!isValidRequestId("a\u{85}"));
    try testing.expect(!isValidRequestId("a\u{200B}b"));
    try testing.expect(!isValidRequestId("\u{FEFF}a"));
    try testing.expect(!isValidRequestId("a\u{202E}"));
    try testing.expect(!isValidRequestId("a\u{E0041}"));
    try testing.expect(!isValidRequestId("\xff"));
}

test "unit: proto: envelope writes requests" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeRequest(&aw.writer, "1", "system.ping", null);
    try aw.writer.writeByte('|');
    try writeRequest(&aw.writer, "q\"t", "surface.send_text", "{\n\"text\":\"a\\nb\"}");
    try testing.expectEqualStrings("{\"id\":\"1\",\"method\":\"system.ping\",\"params\":{}}|{\"id\":\"q\\\"t\",\"method\":\"surface.send_text\",\"params\":{ \"text\":\"a\\nb\"}}", aw.written());
}

test "unit: proto: envelope capability prefix" {
    const a = try splitCapability("_cmux_capability_v1 tok123 {\"method\":\"system.ping\"}");
    try testing.expectEqualStrings("tok123", a.token.?);
    try testing.expectEqualStrings("{\"method\":\"system.ping\"}", a.payload);
    const b = try splitCapability("ping");
    try testing.expectEqual(@as(?[]const u8, null), b.token);
    try testing.expectEqualStrings("ping", b.payload);
    const c = try splitCapability("_cmux_capability_v1 tok");
    try testing.expectEqualStrings("tok", c.token.?);
    try testing.expectEqualStrings("", c.payload);
    const d = try splitCapability("_cmux_capability_v1 tok auth  pw");
    try testing.expectEqualStrings("auth  pw", d.payload);
    const e = try splitCapability("_cmux_capability_v10 x");
    try testing.expectEqual(@as(?[]const u8, null), e.token);
    try testing.expectError(error.MalformedCapability, splitCapability("_cmux_capability_v1"));
    try testing.expectError(error.MalformedCapability, splitCapability("_cmux_capability_v1 "));
    try testing.expectError(error.MalformedCapability, splitCapability("_cmux_capability_v1  ping"));

    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeCapabilityPrefix(&aw.writer, "T0K-_");
    try aw.writer.writeAll("ping");
    const rt = try splitCapability(aw.written());
    try testing.expectEqualStrings("T0K-_", rt.token.?);
    try testing.expectEqualStrings("ping", rt.payload);
}

test "unit: proto: envelope protocol sniffing" {
    try testing.expectEqual(Protocol.v2, sniff("{\"id\":1,\"method\":\"system.ping\"}"));
    try testing.expectEqual(Protocol.v2, sniff("  {\"params\":{\"cmd\":1},\"method\":\"x\"}"));
    try testing.expectEqual(Protocol.legacy_json, sniff("{\"id\":1,\"cmd\":\"workspace-list\",\"args\":{\"method\":2}}"));
    try testing.expectEqual(Protocol.v2, sniff("{\"cmd\":\"x\",\"method\":\"y\"}"));
    try testing.expectEqual(Protocol.v2, sniff("{\"id\":1}"));
    try testing.expectEqual(Protocol.v2, sniff("{garbage"));
    try testing.expectEqual(Protocol.v2, sniff("{}"));
    try testing.expectEqual(Protocol.legacy_json, sniff("{\"long\\u0041key\":1,\"cmd\":\"x\"}"));
    try testing.expectEqual(Protocol.text_v1, sniff("ping"));
    try testing.expectEqual(Protocol.text_v1, sniff("set_status k {v}"));
    try testing.expectEqual(Protocol.text_v1, sniff(""));
    try testing.expectEqual(Protocol.text_v1, sniff("[1]"));
    try testing.expectEqual(Protocol.text_v1, sniff("\u{1F600}"));
}

test "unit: proto: envelope sniff huge line" {
    const gpa = testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll("{\"params\":{\"text\":\"");
    for (0..100_000) |_| try aw.writer.writeAll("abcdefghij");
    try aw.writer.writeAll("\"},\"method\":\"surface.send_text\"}");
    try testing.expectEqual(Protocol.v2, sniff(aw.written()));
}

test "unit: proto: envelope line helpers" {
    try testing.expectEqualStrings("abc", trimLineEnd("abc\r\n"));
    try testing.expectEqualStrings("abc", trimLineEnd("abc\n"));
    try testing.expectEqualStrings("abc\n", trimLineEnd("abc\n\n"));
    try testing.expectEqualStrings("", trimLineEnd(""));
    try testing.expect(isBlankLine(""));
    try testing.expect(isBlankLine(" \t\r"));
    try testing.expect(!isBlankLine(" x"));
}
