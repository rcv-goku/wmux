//! CLI command family `events` (Appendix C).
//! events [--after --after-seq --cursor-file --name --category --reconnect
//! --limit --no-ack --no-heartbeat]. Owner: W2-4.
//!
//! `events.stream` takes over the connection (ADR-3.10): after the request
//! line the server writes newline-delimited frames (`ack`, `event`,
//! `heartbeat`; a v2 reply envelope is unwrapped, an error envelope or an
//! `error` frame ends the stream). Frames are printed as compact JSON and
//! flushed per line. `--cursor-file` persists the last event `seq` after
//! every event; `--reconnect` resumes from it after transient failures
//! (closed pipe, `slow_consumer`, silence longer than four heartbeats),
//! waiting up to 1 s between attempts. `--timeout` is measured on the
//! monotonic clock across reconnects.

const std = @import("std");
const proto = @import("wmux_proto");
const envelope = proto.envelope;
const Allocator = std.mem.Allocator;
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const client_mod = @import("../client.zig");
const common = @import("notify/common.zig");
const Params = common.Params;

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "events", .group = .automation, .usage = common.usageOf(@embedFile("../help/events.txt")), .help = @embedFile("../help/events.txt"), .run = run },
};

/// No frame for this long means the connection is dead (heartbeats every
/// 15 s).
pub const idle_timeout_ms: u32 = 60_000;
/// Longest wait between reconnect attempts.
pub const reconnect_delay_ms: u64 = 1_000;
/// Longest frame line accepted (the server caps frames at 16 KiB).
pub const max_frame_bytes: usize = 1 << 20;

pub const timeout_message = "Timed out waiting for a matching event";
pub const missing_seq_message = "Event frame is missing a numeric seq";

pub const Options = struct {
    after: ?u64 = null,
    cursor_file: ?[]const u8 = null,
    names: []const []const u8 = &.{},
    categories: []const []const u8 = &.{},
    reconnect: bool = false,
    limit: ?u64 = null,
    timeout_ms: ?u64 = null,
    snapshot: bool = false,
    no_ack: bool = false,
    no_heartbeat: bool = false,
};

const opts_table = [_]common.Opt{
    .{ .name = "--after" },
    .{ .name = "--after-seq", .canonical = "--after" },
    .{ .name = "--cursor-file" },
    .{ .name = "--name" },
    .{ .name = "--category" },
    .{ .name = "--reconnect", .kind = .flag },
    .{ .name = "--limit" },
    .{ .name = "--timeout" },
    .{ .name = "--snapshot", .kind = .flag },
    .{ .name = "--no-ack", .kind = .flag },
    .{ .name = "--no-heartbeat", .kind = .flag },
    .{ .name = "--no-heartbeats", .kind = .flag, .canonical = "--no-heartbeat" },
};

pub const ParseResult = union(enum) { ok: Options, usage: []const u8 };

fn parseSeq(s: []const u8) ?u64 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

/// Parses the `events` arguments; `usage` carries cmux's message.
pub fn parseOptions(arena: Allocator, argv: []const []const u8) Allocator.Error!ParseResult {
    const s = switch (try common.scan(arena, argv, &opts_table, .{})) {
        .ok => |x| x,
        .problem => |p| return .{ .usage = switch (p) {
            .unexpected => |toks| try std.fmt.allocPrint(arena, "Unknown events option: {s}", .{toks[0]}),
            .missing_value, .empty_value => |n| try std.fmt.allocPrint(arena, "{s} requires a value", .{n}),
        } },
    };
    if (s.positionals.len > 0) return .{ .usage = try std.fmt.allocPrint(arena, "Unknown events option: {s}", .{s.positionals[0]}) };
    var o: Options = .{
        .cursor_file = s.get("--cursor-file"),
        .names = try s.all(arena, "--name"),
        .categories = try s.all(arena, "--category"),
        .reconnect = s.has("--reconnect"),
        .snapshot = s.has("--snapshot"),
        .no_ack = s.has("--no-ack"),
        .no_heartbeat = s.has("--no-heartbeat"),
    };
    if (s.get("--after")) |v| o.after = parseSeq(v) orelse return .{ .usage = "--after must be a non-negative integer" };
    if (s.get("--limit")) |v| {
        const n = parseSeq(v) orelse 0;
        if (n == 0) return .{ .usage = "--limit must be greater than 0" };
        o.limit = n;
    }
    if (s.get("--timeout")) |v| {
        const secs = std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t")) catch -1;
        if (!std.math.isFinite(secs) or secs <= 0 or secs > 1e9) return .{ .usage = "--timeout must be a positive number of seconds" };
        o.timeout_ms = @max(1, @as(u64, @intFromFloat(secs * 1000.0)));
    }
    return .{ .ok = o };
}

/// Start sequence stored in a cursor file: null when the file is missing or
/// blank; error when it holds anything but a non-negative integer.
pub fn parseCursor(bytes: ?[]const u8) error{Malformed}!?u64 {
    const b = bytes orelse return null;
    const t = std.mem.trim(u8, b, " \t\r\n");
    if (t.len == 0) return null;
    return parseSeq(t) orelse error.Malformed;
}

/// The `events.stream` params.
pub fn streamParams(arena: Allocator, o: Options, after: ?u64) ![]const u8 {
    var p = Params.init(arena);
    if (after) |a| try p.int("after_seq", @intCast(@min(a, std.math.maxInt(i64))));
    if (o.names.len > 0) try p.strings("names", o.names);
    if (o.categories.len > 0) try p.strings("categories", o.categories);
    // Heartbeats always flow: they keep the idle timeout honest;
    // --no-heartbeat only hides them.
    try p.boolean("include_heartbeats", true);
    return p.json();
}

/// Error codes after which a `--reconnect` stream resumes.
pub fn isTransientCode(code: []const u8) bool {
    for ([_][]const u8{ "slow_consumer", "overloaded", "rate_limited", "timeout", "unavailable", "busy", "cancelled" }) |c| {
        if (std.mem.eql(u8, c, code)) return true;
    }
    return false;
}

/// A non-negative integer field of `v`.
fn seqField(v: std.json.Value, key: []const u8) ?u64 {
    return switch (common.field(v, key) orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

const Outcome = union(enum) {
    /// `--limit` or `--snapshot` reached.
    done,
    /// Already reported; exit 1.
    fatal,
    /// Resumable failure (message lives in the frame arena).
    transient: []const u8,
    /// Keep reading.
    more,
};

const Read = union(enum) { line: []const u8, closed, idle, deadline, io, too_large };

const Stream = struct {
    ctx: *Ctx,
    o: Options,
    c: *client_mod.Client,
    /// Per-frame scratch, reset before every frame (streams run for days).
    scratch: std.heap.ArenaAllocator,
    buf: std.ArrayList(u8) = .empty,
    start: ?u64,
    last_seq: ?u64 = null,
    events: u64 = 0,
    deadline: ?i64,
    /// `auth.login` was sent on the current connection.
    auth_tried: bool = false,

    fn deinit(self: *Stream) void {
        self.buf.deinit(std.heap.page_allocator);
        self.scratch.deinit();
    }

    fn a(self: *Stream) Allocator {
        return self.scratch.allocator();
    }

    fn path(self: *const Stream) []const u8 {
        return self.c.opts.path;
    }

    /// Milliseconds left before `--timeout` (null without one).
    fn remaining(self: *const Stream) ?u64 {
        const d = self.deadline orelse return null;
        const now = self.ctx.platform.nowMs();
        return if (now >= d) 0 else @intCast(d - now);
    }

    fn dropConnection(self: *Stream) void {
        if (self.c.conn) |t| t.close();
        self.c.conn = null;
        self.buf.clearRetainingCapacity();
        // Authentication belongs to a connection (as in `Client`): the next
        // connection answers `auth_required` again and logs in again.
        self.auth_tried = false;
    }

    fn readLine(self: *Stream) !Read {
        const conn = self.c.conn.?;
        var scanned: usize = 0;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buf.items, scanned, '\n')) |nl| {
                const line = try self.a().dupe(u8, envelope.trimLineEnd(self.buf.items[0 .. nl + 1]));
                self.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                scanned = 0;
                if (envelope.isBlankLine(line)) continue;
                return .{ .line = line };
            }
            scanned = self.buf.items.len;
            if (self.buf.items.len > max_frame_bytes) return .too_large;
            var wait: u32 = idle_timeout_ms;
            // A wait cut short by --timeout ends at the deadline even when
            // the OS wakes up a clock tick early and a few milliseconds
            // still seem to be left.
            var until_deadline = false;
            if (self.remaining()) |r| {
                if (r == 0) return .deadline;
                if (r <= wait) {
                    wait = @intCast(r);
                    until_deadline = true;
                }
            }
            try self.buf.ensureUnusedCapacity(std.heap.page_allocator, 64 * 1024);
            const spare = self.buf.unusedCapacitySlice();
            const n = conn.read(spare, wait) catch |err| switch (err) {
                error.Timeout => return if (until_deadline or self.remaining() == @as(?u64, 0)) .deadline else .idle,
                error.Unexpected => return .io,
            };
            if (n == 0) return .closed;
            self.buf.items.len += n;
        }
    }

    fn send(self: *Stream, method: []const u8, params: []const u8) !bool {
        var aw: std.Io.Writer.Allocating = .init(self.a());
        if (self.c.opts.capability) |tok| try envelope.writeCapabilityPrefix(&aw.writer, tok);
        const id = envelope.newRequestId();
        try envelope.writeRequest(&aw.writer, &id, method, params);
        try aw.writer.writeByte('\n');
        self.c.conn.?.write(aw.written(), 5_000) catch return false;
        return true;
    }

    fn sendStream(self: *Stream) !bool {
        return self.send("events.stream", try streamParams(self.a(), self.o, self.last_seq orelse self.start));
    }

    fn transient(self: *Stream, comptime fmt: []const u8, args: anytype) !Outcome {
        return .{ .transient = try std.fmt.allocPrint(self.a(), fmt, args) };
    }

    fn fatal(self: *Stream, comptime fmt: []const u8, args: anytype) Outcome {
        _ = self.ctx.runtimeError(fmt, args);
        return .fatal;
    }

    /// One connection: connect if needed, subscribe, then frames until the
    /// stream ends.
    fn session(self: *Stream) !Outcome {
        _ = self.scratch.reset(.retain_capacity);
        if (self.c.conn == null) {
            self.c.conn = self.ctx.platform.connect(self.c.gpa, self.path(), self.c.opts.connect_timeout_ms) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .transient = try client_mod.connectFailureMessage(self.a(), self.path(), err) };
            };
            self.buf.clearRetainingCapacity();
        }
        if (!try self.sendStream()) return self.transient("cannot send events.stream to {s}", .{self.path()});
        while (true) {
            _ = self.scratch.reset(.retain_capacity);
            const line = switch (try self.readLine()) {
                .line => |l| l,
                .closed => return self.transient("events stream from {s} closed", .{self.path()}),
                .idle => return self.transient("no events frames from {s} for {d}s", .{ self.path(), idle_timeout_ms / 1000 }),
                .io => return self.transient("reading events from {s} failed", .{self.path()}),
                .deadline => return self.fatal("{s}", .{timeout_message}),
                .too_large => return self.fatal("events frame from {s} exceeds {d} MiB", .{ self.path(), max_frame_bytes >> 20 }),
            };
            const out = try self.handle(line);
            if (out != .more) return out;
        }
    }

    fn print(self: *Stream, frame: std.json.Value, raw: ?[]const u8) !void {
        const out = self.ctx.out;
        if (raw) |r| try out.writeAll(r) else try std.json.Stringify.value(frame, .{}, out);
        try out.writeByte('\n');
        try out.flush();
    }

    fn handle(self: *Stream, line: []const u8) !Outcome {
        const v = std.json.parseFromSliceLeaky(std.json.Value, self.a(), line, .{}) catch
            return self.fatal("invalid events frame from {s}: not JSON", .{self.path()});
        if (v != .object) return self.fatal("invalid events frame from {s}: not a JSON object", .{self.path()});
        var frame = v;
        var raw: ?[]const u8 = line;
        if (v.object.get("ok")) |okv| {
            if (okv == .bool and !okv.bool) return self.replyError(line);
            // The subscription reply: its result is the first frame.
            frame = v.object.get("result") orelse .{ .object = std.json.ObjectMap.init(self.a()) };
            if (frame != .object) return self.fatal("invalid events frame from {s}: not a JSON object", .{self.path()});
            raw = null;
        }
        const ty = common.strField(frame, "type") orelse
            (if (raw == null) "ack" else if (frame.object.get("seq") != null) "event" else "");
        if (std.mem.eql(u8, ty, "ack")) {
            self.onAck(frame);
            if (!self.o.no_ack or self.o.snapshot) try self.print(frame, raw);
            return if (self.o.snapshot) .done else .more;
        }
        if (std.mem.eql(u8, ty, "heartbeat")) {
            if (!self.o.no_heartbeat) try self.print(frame, raw);
            return .more;
        }
        if (std.mem.eql(u8, ty, "event")) return self.onEvent(frame, raw);
        if (std.mem.eql(u8, ty, "error")) {
            const code = common.strField(frame, "code") orelse "error";
            const msg = common.strField(frame, "message") orelse code;
            if (isTransientCode(code)) return self.transient("{s}: {s}", .{ code, msg });
            return self.fatal("{s}: {s}", .{ code, msg });
        }
        // Unknown frame kinds pass through (forward compatible).
        try self.print(frame, raw);
        return .more;
    }

    /// `seq` is process-local. After a reconnect, an ack whose next sequence
    /// number does not pass the last printed one comes from a restarted app:
    /// resume from that app's position (its effective `after_seq`, else its
    /// latest seq) so its events are not dropped as replays of the old ones.
    fn onAck(self: *Stream, ack: std.json.Value) void {
        const last = self.last_seq orelse return;
        const res = common.field(ack, "resume") orelse return;
        const next = seqField(res, "next_seq") orelse ((seqField(res, "latest_seq") orelse return) +| 1);
        if (next > last) return;
        const after = seqField(res, "after_seq");
        self.last_seq = if (after != null and after.? < next) after.? else next -| 1;
    }

    fn onEvent(self: *Stream, frame: std.json.Value, raw: ?[]const u8) !Outcome {
        const seq: u64 = switch (frame.object.get("seq") orelse .null) {
            .integer => |i| if (i >= 0) @intCast(i) else return self.fatal("{s}", .{missing_seq_message}),
            .float => |f| if (f >= 0 and f < 1.8e19 and @floor(f) == f) @intFromFloat(f) else return self.fatal("{s}", .{missing_seq_message}),
            else => return self.fatal("{s}", .{missing_seq_message}),
        };
        // A replay after a reconnect may repeat what was already printed.
        if (self.last_seq) |l| if (seq <= l) return .more;
        try self.print(frame, raw);
        self.last_seq = seq;
        if (self.o.cursor_file) |cf| {
            const text = try std.fmt.allocPrint(self.a(), "{d}\n", .{seq});
            common.files.write(cf, text) catch |err|
                return self.fatal("cannot write events cursor file {s}: {s}", .{ cf, @errorName(err) });
        }
        self.events += 1;
        if (self.o.limit) |l| if (self.events >= l) return .done;
        return .more;
    }

    /// An error reply to the subscription (or to `auth.login`).
    fn replyError(self: *Stream, line: []const u8) !Outcome {
        const rep = envelope.parseReply(self.a(), line) catch
            return self.fatal("invalid events frame from {s}: not a v2 reply", .{self.path()});
        const e = rep.err orelse return self.fatal("invalid events frame from {s}: not a v2 reply", .{self.path()});
        if (e.known == .auth_required and self.c.opts.password != null and !self.auth_tried) {
            self.auth_tried = true;
            return self.login();
        }
        if (isTransientCode(e.code)) return self.transient("{s}: {s}", .{ e.code, e.message });
        _ = try self.ctx.reportError("events.stream", .{ .rpc_error = .{ .err = e, .raw = line } });
        return .fatal;
    }

    /// Password mode: `auth.login` on this connection, then subscribe again.
    fn login(self: *Stream) !Outcome {
        const params = try std.fmt.allocPrint(self.a(), "{{\"password\":{f}}}", .{std.json.fmt(self.c.opts.password.?, .{})});
        if (!try self.send("auth.login", params)) return self.transient("cannot send auth.login to {s}", .{self.path()});
        const line = switch (try self.readLine()) {
            .line => |l| l,
            .deadline => return self.fatal("{s}", .{timeout_message}),
            else => return self.transient("connection to {s} closed during auth.login", .{self.path()}),
        };
        const rep = envelope.parseReply(self.a(), line) catch
            return self.fatal("invalid response from {s}: not a v2 JSON reply", .{self.path()});
        if (!rep.ok) {
            _ = try self.ctx.reportError("auth.login", .{ .rpc_error = .{ .err = rep.err.?, .raw = line } });
            return .fatal;
        }
        if (!try self.sendStream()) return self.transient("cannot send events.stream to {s}", .{self.path()});
        return .more;
    }
};

fn run(ctx: *Ctx) !u8 {
    const o = switch (try parseOptions(ctx.arena, ctx.args())) {
        .ok => |x| x,
        .usage => |m| return ctx.usageError("{s}", .{m}),
    };
    var start = o.after;
    if (start == null) if (o.cursor_file) |cf| {
        start = parseCursor(ctx.platform.readFile(ctx.arena, cf, 1 << 20)) catch
            return ctx.runtimeError("Malformed events cursor file {s}: expected a non-negative sequence number", .{cf});
    };
    const deadline: ?i64 = if (o.timeout_ms) |t| ctx.platform.nowMs() + @as(i64, @intCast(@min(t, std.math.maxInt(i32)))) else null;
    const c = (try ctx.connect()) orelse return output.exit.runtime;
    var st: Stream = .{
        .ctx = ctx,
        .o = o,
        .c = c,
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .start = start,
        .deadline = deadline,
    };
    defer st.deinit();
    while (true) {
        switch (try st.session()) {
            .done => return output.exit.ok,
            .fatal => return output.exit.runtime,
            .more => unreachable,
            .transient => |msg| {
                st.dropConnection();
                if (!o.reconnect) return ctx.runtimeError("{s}", .{msg});
                var wait = reconnect_delay_ms;
                if (st.remaining()) |r| wait = @min(wait, r);
                if (wait > 0) ctx.platform.sleepMs(wait);
                if (st.remaining() == @as(?u64, 0)) return ctx.runtimeError("{s}", .{timeout_message});
            },
        }
    }
}

test {
    _ = @import("notify/events_tests.zig");
}
