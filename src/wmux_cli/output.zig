//! Output and exit codes (ADR-4.7).
//!
//! - `--json` prints the server `result` as pretty JSON; `--id-format` is
//!   applied client-side through `wmux_proto.idformat` (default refs). `rpc`
//!   stays raw unless `--id-format` is given.
//! - Errors print `<code>: <message>` plus optional `Reason:`, `What to do:`
//!   and `Details:` lines (allowlisted keys, printable characters only). On
//!   `method_not_found` the caller adds the version-skew diagnosis.
//! - Exit codes: 0 success, 1 runtime/server error, 2 usage error.
//! - Console: `Utf16Sink` turns UTF-8 output into whole UTF-16 chunks for
//!   `WriteConsoleW` (correct Unicode in conhost); redirected output stays
//!   UTF-8 without BOM.

const std = @import("std");
const proto = @import("wmux_proto");
const idformat = proto.idformat;
const envelope = proto.envelope;
const utf8 = proto.utf8;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const client_mod = @import("client.zig");

pub const exit = proto.errors.exit;

/// Pretty JSON (2-space indent) plus a newline.
pub fn writeJson(w: *Writer, v: std.json.Value) Writer.Error!void {
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

/// `v` rewritten for `mode`.
pub fn formatIds(arena: Allocator, v: std.json.Value, mode: idformat.Mode) Allocator.Error!std.json.Value {
    return idformat.apply(arena, v, mode, .{});
}

/// A result printed by a `--json`-style command: id-formatted, pretty.
pub fn writeResult(arena: Allocator, w: *Writer, v: std.json.Value, mode: idformat.Mode) (Writer.Error || Allocator.Error)!void {
    try writeJson(w, try formatIds(arena, v, mode));
}

/// Max `Details:` entries and bytes per value.
pub const max_detail_entries = 16;
pub const max_detail_value_bytes = 200;

fn validDetailKey(k: []const u8) bool {
    if (k.len == 0 or k.len > 64) return false;
    for (k) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

fn writeSanitized(gpa: Allocator, w: *Writer, s: []const u8, cap: usize) (Writer.Error || Allocator.Error)!void {
    const clean = try utf8.sanitizePrintableAlloc(gpa, s);
    defer gpa.free(clean);
    const t = utf8.truncateUtf8(clean, cap);
    try w.writeAll(t);
    if (t.len < clean.len) try w.writeAll("\u{2026}");
}

fn writeScalar(gpa: Allocator, w: *Writer, v: std.json.Value) (Writer.Error || Allocator.Error)!bool {
    switch (v) {
        .string => |s| try writeSanitized(gpa, w, s, max_detail_value_bytes),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try writeSanitized(gpa, w, s, max_detail_value_bytes),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        else => return false,
    }
    return true;
}

/// `<code>: <message>` and the optional explanation lines.
pub fn writeRpcError(gpa: Allocator, w: *Writer, e: envelope.ReplyError) (Writer.Error || Allocator.Error)!void {
    const code = if (e.code.len > 0) e.code else "error";
    try writeSanitized(gpa, w, code, 64);
    try w.writeAll(": ");
    try writeSanitized(gpa, w, if (e.message.len > 0) e.message else "(no message)", 4096);
    try w.writeByte('\n');
    if (e.reason) |r| {
        try w.writeAll("Reason: ");
        try writeSanitized(gpa, w, r, 1024);
        try w.writeByte('\n');
    }
    if (e.action) |a| {
        try w.writeAll("What to do: ");
        try writeSanitized(gpa, w, a, 1024);
        try w.writeByte('\n');
    }
    if (e.details) |d| switch (d) {
        .string => |s| {
            try w.writeAll("Details: ");
            try writeSanitized(gpa, w, s, 1024);
            try w.writeByte('\n');
        },
        .object => |o| {
            var n: usize = 0;
            var it = o.iterator();
            while (it.next()) |entry| {
                if (n == max_detail_entries) break;
                if (!validDetailKey(entry.key_ptr.*)) continue;
                switch (entry.value_ptr.*) {
                    .object, .array => continue,
                    else => {},
                }
                try w.writeAll(if (n == 0) "Details: " else "; ");
                try w.print("{s}=", .{entry.key_ptr.*});
                _ = try writeScalar(gpa, w, entry.value_ptr.*);
                n += 1;
            }
            if (n > 0) try w.writeByte('\n');
        },
        else => {},
    };
}

/// A client failure: its message on one line.
pub fn writeFailure(gpa: Allocator, w: *Writer, f: client_mod.Failure) (Writer.Error || Allocator.Error)!void {
    try writeSanitized(gpa, w, f.message, 8192);
    try w.writeByte('\n');
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// Version-skew diagnosis after `method_not_found` (ADR-4.7): what this CLI
/// is, what the connected app reports through `system.identify` (or that it
/// could not be asked) and how to fix it.
pub fn writeVersionSkew(gpa: Allocator, w: *Writer, method: []const u8, cli_version: []const u8, identify: ?std.json.Value) (Writer.Error || Allocator.Error)!void {
    try w.writeAll("This CLI: ");
    try w.writeAll(cli_version);
    try w.writeByte('\n');
    try w.writeAll("Connected app: ");
    if (identify) |v| if (v == .object) {
        const o = v.object;
        try writeSanitized(gpa, w, str(o, "app") orelse "wmux", 64);
        try w.writeByte(' ');
        try writeSanitized(gpa, w, str(o, "version") orelse "(version unknown)", 128);
        if (str(o, "build")) |b| {
            try w.writeAll(" (");
            try writeSanitized(gpa, w, b, 128);
            try w.writeByte(')');
        }
        if (str(o, "app_bundle_path")) |p| {
            try w.writeAll(" at ");
            try writeSanitized(gpa, w, p, 1024);
        }
        try w.writeByte('\n');
    } else try w.writeAll("unknown (system.identify returned no object)\n") else try w.writeAll("unknown (system.identify failed)\n");
    try w.writeAll("Fix: the app does not know '");
    try writeSanitized(gpa, w, method, 256);
    try w.writeAll("'. Use the CLI shipped with the running app (INSTALL\\cli\\cmux.exe, also on PATH inside wmux terminals) or update wmux so both match.\n");
}

/// Streams UTF-8 into whole UTF-16 chunks for a console (`WriteConsoleW`).
/// An incomplete UTF-8 sequence at the end of a chunk waits for the next
/// write; invalid bytes become U+FFFD.
pub const Utf16Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, units: []const u16) bool,
    interface: Writer,
    /// Scratch for one conversion (UTF-16 never needs more units than bytes).
    scratch: [1024]u16 = undefined,

    pub fn init(ctx: *anyopaque, emit: *const fn (*anyopaque, []const u16) bool, buffer: []u8) Utf16Sink {
        return .{ .ctx = ctx, .emit = emit, .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = buffer } };
    }

    /// Emits the complete prefix; an incomplete UTF-8 tail (at most 3
    /// bytes) stays buffered until more bytes or `finish` arrive.
    fn flush(w: *Writer) Writer.Error!void {
        const self: *Utf16Sink = @alignCast(@fieldParentPtr("interface", w));
        const buffered = w.buffer[0..w.end];
        const used = try self.convert(buffered, false);
        const tail = buffered.len - used;
        std.mem.copyForwards(u8, w.buffer[0..tail], buffered[used..]);
        w.end = tail;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Utf16Sink = @alignCast(@fieldParentPtr("interface", w));
        // Flush the buffered bytes first, keeping an incomplete tail.
        const buffered = w.buffer[0..w.end];
        const used = try self.convert(buffered, false);
        const tail = buffered.len - used;
        std.mem.copyForwards(u8, w.buffer[0..tail], buffered[used..]);
        w.end = tail;
        // Then take as much of `data` as fits in the buffer.
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            const n = w.buffer.len - w.end;
            const take = @min(n, chunk.len);
            @memcpy(w.buffer[w.end..][0..take], chunk[0..take]);
            w.end += take;
            consumed += take;
            if (take < chunk.len) return consumed;
        }
        const last = data[data.len - 1];
        var s: usize = 0;
        while (s < splat) : (s += 1) {
            const n = w.buffer.len - w.end;
            const take = @min(n, last.len);
            @memcpy(w.buffer[w.end..][0..take], last[0..take]);
            w.end += take;
            consumed += take;
            if (take < last.len) break;
        }
        return consumed;
    }

    /// Converts and emits the complete prefix of `bytes`; returns how many
    /// bytes were consumed. With `final`, everything is consumed.
    fn convert(self: *Utf16Sink, bytes: []const u8, final: bool) Writer.Error!usize {
        var i: usize = 0;
        var n: usize = 0;
        while (i < bytes.len) {
            if (n + 2 > self.scratch.len) {
                if (!self.emit(self.ctx, self.scratch[0..n])) return error.WriteFailed;
                n = 0;
            }
            const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                self.scratch[n] = 0xFFFD;
                n += 1;
                i += 1;
                continue;
            };
            if (i + len > bytes.len) {
                if (!final) break;
                self.scratch[n] = 0xFFFD;
                n += 1;
                i = bytes.len;
                break;
            }
            const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
                self.scratch[n] = 0xFFFD;
                n += 1;
                i += 1;
                continue;
            };
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                self.scratch[n] = @intCast(0xD800 + (v >> 10));
                self.scratch[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
                n += 2;
            } else {
                self.scratch[n] = @intCast(cp);
                n += 1;
            }
            i += len;
        }
        if (n > 0 and !self.emit(self.ctx, self.scratch[0..n])) return error.WriteFailed;
        return i;
    }

    /// Emits everything still buffered, including an incomplete tail.
    pub fn finish(self: *Utf16Sink) Writer.Error!void {
        _ = try self.convert(self.interface.buffer[0..self.interface.end], true);
        self.interface.end = 0;
    }
};

const testing = std.testing;

fn parseValue(a: Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, s, .{});
}

test "unit: cli-output: id-format refs uuids both" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try parseValue(a, "{\"workspaces\":[{\"id\":\"9B69\",\"ref\":\"workspace:1\",\"title\":\"api\"}],\"window_id\":\"AA\",\"window_ref\":\"window:1\"}");
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeResult(a, &aw.writer, v, .refs);
    try testing.expectEqualStrings(
        \\{
        \\  "workspaces": [
        \\    {
        \\      "ref": "workspace:1",
        \\      "title": "api"
        \\    }
        \\  ],
        \\  "window_ref": "window:1"
        \\}
        \\
    , aw.written());
    aw.clearRetainingCapacity();
    try writeResult(a, &aw.writer, v, .uuids);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"ref\"") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"id\": \"9B69\"") != null);
    aw.clearRetainingCapacity();
    try writeResult(a, &aw.writer, v, .both);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"ref\"") != null and std.mem.indexOf(u8, aw.written(), "\"id\"") != null);
}

test "unit: cli-output: rpc error lines with reason, action and details" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const details = try parseValue(a, "{\"selector\":\"workspace_id\",\"count\":3,\"bad key\":1,\"nested\":{\"x\":1},\"ok\":true,\"esc\":\"a\\u001b[31mb\\nc\"}");
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeRpcError(a, &aw.writer, .{
        .code = "not_found",
        .known = .not_found,
        .message = "Workspace not found",
        .reason = "the workspace was closed",
        .action = "run cmux list-workspaces",
        .details = details,
    });
    try testing.expectEqualStrings(
        \\not_found: Workspace not found
        \\Reason: the workspace was closed
        \\What to do: run cmux list-workspaces
        \\Details: selector=workspace_id; count=3; ok=true; esc=a[31mb c
        \\
    , aw.written());
}

test "unit: cli-output: rpc error minimal and hostile fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeRpcError(a, &aw.writer, .{ .code = "", .known = null, .message = "" });
    try testing.expectEqualStrings("error: (no message)\n", aw.written());
    aw.clearRetainingCapacity();
    const long = try a.alloc(u8, 5000);
    @memset(long, 'x');
    try writeRpcError(a, &aw.writer, .{ .code = "internal_error", .known = .internal_error, .message = "bad\x07\u{202e}msg", .details = .{ .string = long } });
    const out = aw.written();
    try testing.expect(std.mem.startsWith(u8, out, "internal_error: badmsg\nDetails: x"));
    try testing.expect(std.mem.endsWith(u8, out, "\u{2026}\n"));
}

test "unit: cli-output: version skew diagnosis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ident = try parseValue(a, "{\"app\":\"wmux\",\"version\":\"0.9.0\",\"build\":\"123\",\"app_bundle_path\":\"C:\\\\wmux\"}");
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeVersionSkew(a, &aw.writer, "surface.read_selection", "cmux 1.0.0", ident);
    try testing.expectEqualStrings(
        \\This CLI: cmux 1.0.0
        \\Connected app: wmux 0.9.0 (123) at C:\wmux
        \\Fix: the app does not know 'surface.read_selection'. Use the CLI shipped with the running app (INSTALL\cli\cmux.exe, also on PATH inside wmux terminals) or update wmux so both match.
        \\
    , aw.written());
    aw.clearRetainingCapacity();
    try writeVersionSkew(a, &aw.writer, "x", "cmux 1", null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "Connected app: unknown (system.identify failed)\n") != null);
}

const Collect = struct {
    units: std.ArrayList(u16) = .empty,
    a: Allocator,
    fn emit(ctx: *anyopaque, u: []const u16) bool {
        const self: *Collect = @ptrCast(@alignCast(ctx));
        self.units.appendSlice(self.a, u) catch return false;
        return true;
    }
};

test "unit: cli-output: console sink converts split UTF-8 to UTF-16" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var col: Collect = .{ .a = a };
    var buf: [5]u8 = undefined;
    var sink = Utf16Sink.init(&col, Collect.emit, &buf);
    const text = "h\u{e9}llo \u{65e5}\u{672c} \u{1F600}!";
    // Byte-at-a-time writes split every multi-byte sequence.
    for (text) |c| try sink.interface.writeByte(c);
    try sink.interface.flush();
    try sink.finish();
    const want = try std.unicode.utf8ToUtf16LeAlloc(a, text);
    try testing.expectEqualSlices(u16, want, col.units.items);
}

test "unit: cli-output: console sink replaces invalid bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var col: Collect = .{ .a = a };
    var buf: [64]u8 = undefined;
    var sink = Utf16Sink.init(&col, Collect.emit, &buf);
    try sink.interface.writeAll("a\xffb\xe2\x82");
    try sink.interface.flush();
    try sink.finish();
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD }, col.units.items);
}

test "unit: cli-output: console sink handles output larger than its buffers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var col: Collect = .{ .a = a };
    var buf: [256]u8 = undefined;
    var sink = Utf16Sink.init(&col, Collect.emit, &buf);
    var big: std.ArrayList(u8) = .empty;
    for (0..20_000) |i| try big.appendSlice(a, if (i % 3 == 0) "\u{e9}" else if (i % 3 == 1) "\u{1F600}" else "z");
    try sink.interface.writeAll(big.items);
    try sink.interface.flush();
    try sink.finish();
    try testing.expectEqualSlices(u16, try std.unicode.utf8ToUtf16LeAlloc(a, big.items), col.units.items);
}
