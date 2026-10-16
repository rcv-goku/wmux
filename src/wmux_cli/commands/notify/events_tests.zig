//! Tests of `cmux events` against a fake pipe that streams frames: option
//! errors, subscription params, frame filtering, limits, snapshot, cursor
//! files, reconnect/resume, timeouts and error frames.

const std = @import("std");
const testing = std.testing;
const kit = @import("testkit.zig");
const fake = kit.fake;
const Harness = kit.Harness;
const events = @import("../events.zig");
const common = @import("common.zig");

const ack = "{\"type\":\"ack\",\"resume\":{\"after_seq\":null,\"oldest_seq\":1,\"latest_seq\":4,\"next_seq\":5,\"gap\":false}}";
const hb = "{\"type\":\"heartbeat\"}";

fn ev(comptime seq: []const u8, comptime name: []const u8) []const u8 {
    return "{\"type\":\"event\",\"seq\":" ++ seq ++ ",\"id\":\"E" ++ seq ++ "\",\"name\":\"" ++ name ++ "\",\"category\":\"workspace\"}";
}

/// Frames per connection (index = connection number - 1).
const Script = struct {
    batches: []const []const u8,
    /// Close the pipe after the batch (else stay silent).
    close: bool = true,
    /// Answer the first subscription with `auth_required`.
    need_auth: bool = false,
    authed: bool = false,
};

fn streamHandler(server: *fake.Server, req: fake.Request) fake.Action {
    const sc: *Script = @ptrCast(@alignCast(server.user.?));
    if (std.mem.eql(u8, req.method, "auth.login")) {
        sc.authed = true;
        return .{ .ok = "{\"authenticated\":true}" };
    }
    if (!std.mem.eql(u8, req.method, "events.stream")) return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
    if (sc.need_auth and !sc.authed) return .{ .err = "{\"code\":\"auth_required\",\"message\":\"Authentication required\"}" };
    const i = server.connections - 1;
    const batch = if (i < sc.batches.len) sc.batches[i] else "";
    server.outbox.appendSlice(server.a, batch) catch unreachable;
    if (batch.len > 0) server.outbox.append(server.a, '\n') catch unreachable;
    return if (sc.close) .close else .stall;
}

/// Runs with the connection counter reset, so each run starts at batch 0.
fn fresh(h: *Harness, argv: []const []const u8) kit.Result {
    h.server.connections = 0;
    return h.run(argv);
}

fn harness(h: *Harness, sc: *Script) !void {
    try h.init(streamHandler);
    h.server.user = sc;
}

fn lines(comptime parts: []const []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (parts, 0..) |p, i| out = out ++ (if (i > 0) "\n" else "") ++ p;
    return out;
}

test "unit: cli-events: prints frames as NDJSON and stops at --limit" {
    var sc: Script = .{ .batches = &.{comptime lines(&.{ ack, hb, ev("1", "workspace.created"), ev("2", "workspace.selected"), ev("3", "x") })} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "events", "--limit", "2" });
    try kit.expectResult(r, 0, comptime lines(&.{ ack, hb, ev("1", "workspace.created"), ev("2", "workspace.selected") }) ++ "\n", "");
    try testing.expectEqualStrings("events.stream", h.last().method);
    try testing.expectEqualStrings("{\"include_heartbeats\":true}", h.last().params_json);
    try kit.expectGolden(h.alloc(), "events.txt", r.out);
}

test "unit: cli-events: filters, after and hidden frames" {
    var sc: Script = .{ .batches = &.{comptime lines(&.{ ack, hb, ev("42", "workspace.created"), hb, ev("43", "a") })} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "events", "--no-ack", "--no-heartbeats", "--limit=1", "--name", "workspace.created", "--name=feed.item.received", "--category", "notification", "--after-seq", "41" });
    try kit.expectResult(r, 0, comptime ev("42", "workspace.created") ++ "\n", "");
    try testing.expectEqualStrings("{\"after_seq\":41,\"names\":[\"workspace.created\",\"feed.item.received\"],\"categories\":[\"notification\"],\"include_heartbeats\":true}", h.last().params_json);
}

test "unit: cli-events: a reply envelope is unwrapped and --snapshot prints the ack" {
    const wrapped = "{\"id\":\"x\",\"ok\":true,\"result\":{\"type\":\"ack\",\"resume\":{\"next_seq\":9}}}";
    var sc: Script = .{ .batches = &.{comptime lines(&.{ wrapped, ev("9", "a") })} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    try kit.expectResult(fresh(&h, &.{ "cmux", "events", "--snapshot", "--no-ack" }), 0, "{\"type\":\"ack\",\"resume\":{\"next_seq\":9}}\n", "");
    try kit.expectResult(fresh(&h, &.{ "cmux", "events", "--limit", "1", "--no-ack" }), 0, comptime ev("9", "a") ++ "\n", "");
}

test "unit: cli-events: a closed stream exits 1 without --reconnect" {
    var sc: Script = .{ .batches = &.{comptime lines(&.{ ack, ev("1", "a") })} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "events" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(comptime lines(&.{ ack, ev("1", "a") }) ++ "\n", r.out);
    try kit.expectContains(r.err, "cmux: events stream from ");
    try kit.expectContains(r.err, " closed\n");
}

test "unit: cli-events: --reconnect resumes after the last seq and drops replays" {
    var sc: Script = .{ .batches = &.{
        comptime lines(&.{ ack, ev("5", "a"), ev("6", "b") }),
        comptime lines(&.{ ack, ev("6", "b"), ev("7", "c") }),
    } };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const r = h.run(&.{ "cmux", "events", "--reconnect", "--no-ack", "--limit", "3" });
    try kit.expectResult(r, 0, comptime lines(&.{ ev("5", "a"), ev("6", "b"), ev("7", "c") }) ++ "\n", "");
    try testing.expectEqual(@as(usize, 2), h.server.countMethod("events.stream"));
    try testing.expectEqualStrings("{\"after_seq\":6,\"include_heartbeats\":true}", h.last().params_json);
    try testing.expectEqual(@as(u64, 1000), h.fp.slept_ms);
}

test "unit: cli-events: slow_consumer error frames are transient" {
    const slow = "{\"type\":\"error\",\"code\":\"slow_consumer\",\"message\":\"Slow consumer\"}";
    var sc: Script = .{ .batches = &.{ comptime lines(&.{ ack, ev("1", "a"), slow }), comptime lines(&.{ ack, ev("2", "b") }) } };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const once = h.run(&.{ "cmux", "events", "--no-ack" });
    try kit.expectResult(once, 1, comptime ev("1", "a") ++ "\n", "cmux: slow_consumer: Slow consumer\n");
    h.server.connections = 0;
    const again = h.run(&.{ "cmux", "events", "--no-ack", "--reconnect", "--limit", "2" });
    try kit.expectResult(again, 0, comptime lines(&.{ ev("1", "a"), ev("2", "b") }) ++ "\n", "");
    const bad = "{\"type\":\"error\",\"code\":\"invalid_params\",\"message\":\"Unknown category\"}";
    sc.batches = &.{comptime lines(&.{ ack, bad })};
    h.server.connections = 0;
    try kit.expectResult(h.run(&.{ "cmux", "events", "--no-ack", "--reconnect" }), 1, "", "cmux: invalid_params: Unknown category\n");
}

test "unit: cli-events: an error reply to the subscription is reported" {
    var sc: Script = .{ .batches = &.{"{\"id\":null,\"ok\":false,\"error\":{\"code\":\"invalid_params\",\"message\":\"Unknown category: bogus\"}}"} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "events", "--category", "bogus" }), 1, "", "invalid_params: Unknown category: bogus\n");
}

test "unit: cli-events: password mode logs in on the stream connection" {
    var sc: Script = .{ .batches = &.{comptime lines(&.{ ack, ev("1", "a") })}, .need_auth = true };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    h.setEnv("CMUX_SOCKET_PASSWORD", "pw");
    try kit.expectResult(h.run(&.{ "cmux", "events", "--limit", "1", "--no-ack" }), 0, comptime ev("1", "a") ++ "\n", "");
    try testing.expectEqual(@as(usize, 1), h.server.countMethod("auth.login"));
    try testing.expectEqual(@as(usize, 2), h.server.countMethod("events.stream"));
    // Without a password the error is reported.
    var sc2: Script = .{ .batches = &.{ack}, .need_auth = true };
    var h2: Harness = undefined;
    try harness(&h2, &sc2);
    defer h2.deinit();
    try kit.expectResult(h2.run(&.{ "cmux", "events" }), 1, "", "auth_required: Authentication required\n");
}

var cursor_buf: [64]u8 = undefined;
var cursor_len: usize = 0;
var cursor_path: []const u8 = "";
var cursor_writes: usize = 0;

fn recordWrite(path: []const u8, bytes: []const u8) anyerror!void {
    cursor_path = path;
    @memcpy(cursor_buf[0..bytes.len], bytes);
    cursor_len = bytes.len;
    cursor_writes += 1;
}

fn failWrite(_: []const u8, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

fn noDelete(_: []const u8) anyerror!void {}

test "unit: cli-events: cursor file seeds the start and records every event" {
    var sc: Script = .{ .batches = &.{comptime lines(&.{ ack, ev("11", "a"), ev("12", "b") })} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const saved = common.files;
    defer common.files = saved;
    common.files = .{ .delete = noDelete, .write = recordWrite };
    cursor_writes = 0;
    try h.fp.addFile("events.seq", "10\n");
    try kit.expectResult(fresh(&h, &.{ "cmux", "events", "--cursor-file", "events.seq", "--limit", "2", "--no-ack" }), 0, comptime lines(&.{ ev("11", "a"), ev("12", "b") }) ++ "\n", "");
    try testing.expectEqualStrings("{\"after_seq\":10,\"include_heartbeats\":true}", h.last().params_json);
    try testing.expectEqual(@as(usize, 2), cursor_writes);
    try testing.expectEqualStrings("events.seq", cursor_path);
    try testing.expectEqualStrings("12\n", cursor_buf[0..cursor_len]);
    // An explicit --after wins; a missing file starts from the live tail.
    _ = fresh(&h, &.{ "cmux", "events", "--cursor-file", "events.seq", "--after", "3", "--limit", "1" });
    try testing.expectEqualStrings("{\"after_seq\":3,\"include_heartbeats\":true}", h.last().params_json);
    _ = fresh(&h, &.{ "cmux", "events", "--cursor-file", "missing.seq", "--limit", "1" });
    try testing.expectEqualStrings("{\"include_heartbeats\":true}", h.last().params_json);
    try h.fp.addFile("bad.seq", "-4");
    const n = h.requestCount();
    try kit.expectResult(fresh(&h, &.{ "cmux", "events", "--cursor-file", "bad.seq" }), 1, "", "cmux: Malformed events cursor file bad.seq: expected a non-negative sequence number\n");
    try testing.expectEqual(n, h.requestCount());
    common.files = .{ .delete = noDelete, .write = failWrite };
    const failed = fresh(&h, &.{ "cmux", "events", "--cursor-file", "events.seq", "--no-ack" });
    try kit.expectResult(failed, 1, comptime ev("11", "a") ++ "\n", "cmux: cannot write events cursor file events.seq: AccessDenied\n");
}

test "unit: cli-events: cursor parsing" {
    try testing.expectEqual(@as(?u64, null), try events.parseCursor(null));
    try testing.expectEqual(@as(?u64, null), try events.parseCursor(" \r\n"));
    try testing.expectEqual(@as(?u64, 0), try events.parseCursor("0"));
    try testing.expectEqual(@as(?u64, 18446744073709551615), try events.parseCursor("18446744073709551615\n"));
    for ([_][]const u8{ "-1", "1.5", "abc", "18446744073709551616", "1 2", "\u{1F600}" }) |bad| {
        try testing.expectError(error.Malformed, events.parseCursor(bad));
    }
}

test "unit: cli-events: --timeout fails on the monotonic clock" {
    var sc: Script = .{ .batches = &.{ack}, .close = false };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const before = h.fp.clock;
    try kit.expectResult(fresh(&h, &.{ "cmux", "events", "--timeout", "2.5", "--limit", "1" }), 1, ack ++ "\n", "cmux: " ++ events.timeout_message ++ "\n");
    try testing.expectEqual(@as(i64, 2500), h.fp.clock - before);
    // Silence beyond four heartbeats is a dead stream.
    const idle = fresh(&h, &.{ "cmux", "events", "--no-ack" });
    try testing.expectEqual(@as(u8, 1), idle.code);
    try kit.expectContains(idle.err, "for 60s\n");
    // The timeout also bounds reconnect attempts.
    sc.close = true;
    h.server.connections = 0;
    const r = fresh(&h, &.{ "cmux", "events", "--reconnect", "--no-ack", "--timeout", "3" });
    try kit.expectResult(r, 1, "", "cmux: " ++ events.timeout_message ++ "\n");
}

test "unit: cli-events: event frames need a numeric seq" {
    var sc: Script = .{ .batches = &.{comptime lines(&.{ ack, "{\"type\":\"event\",\"name\":\"a\",\"seq\":\"7\"}" })} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    try kit.expectResult(h.run(&.{ "cmux", "events", "--no-ack" }), 1, "", "cmux: " ++ events.missing_seq_message ++ "\n");
    sc.batches = &.{comptime lines(&.{ ack, "not json" })};
    h.server.connections = 0;
    const r = h.run(&.{ "cmux", "events", "--no-ack" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try kit.expectContains(r.err, "not JSON");
    // Unknown frame types and unicode payloads pass through.
    const odd = "{\"type\":\"notice\",\"text\":\"h\u{e9}llo \u{1F600}\"}";
    sc.batches = &.{comptime lines(&.{ ack, odd, ev("1", "a") })};
    h.server.connections = 0;
    try kit.expectResult(h.run(&.{ "cmux", "events", "--no-ack", "--limit", "1" }), 0, odd ++ "\n" ++ comptime ev("1", "a") ++ "\n", "");
}

test "unit: cli-events: option errors" {
    var sc: Script = .{ .batches = &.{} };
    var h: Harness = undefined;
    try harness(&h, &sc);
    defer h.deinit();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"--bogus"}, "Unknown events option: --bogus" },
        .{ &.{"stray"}, "Unknown events option: stray" },
        .{ &.{"--reconnect=yes"}, "Unknown events option: --reconnect=yes" },
        .{ &.{"--limit"}, "--limit requires a value" },
        .{ &.{ "--limit", "0" }, "--limit must be greater than 0" },
        .{ &.{ "--limit", "-2" }, "--limit must be greater than 0" },
        .{ &.{ "--after", "-1" }, "--after must be a non-negative integer" },
        .{ &.{"--after-seq=x"}, "--after must be a non-negative integer" },
        .{ &.{ "--timeout", "0" }, "--timeout must be a positive number of seconds" },
        .{ &.{ "--timeout", "soon" }, "--timeout must be a positive number of seconds" },
        .{ &.{"--cursor-file="}, "--cursor-file requires a value" },
    };
    for (cases) |c| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{ "cmux", "events" }, c[0] });
        const want = try std.fmt.allocPrint(h.alloc(), "cmux: {s}\n", .{c[1]});
        try kit.expectResult(h.run(argv), 2, "", want);
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
    const help = h.run(&.{ "cmux", "events", "--help" });
    try testing.expectEqual(@as(u8, 0), help.code);
    try kit.expectGolden(h.alloc(), "events-help.txt", help.out);
}
