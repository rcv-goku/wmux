//! Unit tests of decisions.zig.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const decisions = @import("decisions.zig");
const Uuid = proto.uuid.Uuid;
const Value = std.json.Value;
const Decisions = decisions.Decisions;
const Closed = decisions.Closed;
const State = decisions.State;
const Waiter = decisions.Waiter;
const parseWaitTimeoutMs = decisions.parseWaitTimeoutMs;
const wait_timeout_message = decisions.wait_timeout_message;

const testing = std.testing;
const t_id = Uuid.fromRandomBytes(@splat(7));

test "unit: feed: wait_timeout_seconds accepts numbers in 0..120" {
    try testing.expectEqual(@as(u32, 0), try parseWaitTimeoutMs(null));
    try testing.expectEqual(@as(u32, 0), try parseWaitTimeoutMs(.null));
    try testing.expectEqual(@as(u32, 0), try parseWaitTimeoutMs(.{ .integer = 0 }));
    try testing.expectEqual(@as(u32, 120_000), try parseWaitTimeoutMs(.{ .integer = 120 }));
    try testing.expectEqual(@as(u32, 5_500), try parseWaitTimeoutMs(.{ .float = 5.5 }));
    try testing.expectEqual(@as(u32, 2_000), try parseWaitTimeoutMs(.{ .number_string = "2" }));
}

test "unit: feed: wait_timeout_seconds rejects out of range and non-numeric" {
    const bad = [_]Value{ .{ .integer = -1 }, .{ .integer = 121 }, .{ .float = 120.001 }, .{ .float = -0.5 }, .{ .float = std.math.nan(f64) }, .{ .float = std.math.inf(f64) }, .{ .string = "5" }, .{ .bool = true }, .{ .number_string = "1e400" }, .{ .number_string = "nan" }, .{ .number_string = "inf" }, .{ .number_string = "12x" }, .{ .number_string = "-1" }, .{ .integer = std.math.maxInt(i64) }, .{ .integer = std.math.minInt(i64) }, .{ .array = .init(testing.allocator) } };
    for (bad) |v| try testing.expectError(error.InvalidWaitTimeout, parseWaitTimeoutMs(v));
    try testing.expectEqualStrings("feed.push wait_timeout_seconds must be between 0 and 120", wait_timeout_message);
}

test "unit: feed: register parks a waiter with a deadline" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    const r = try d.register(.{ .request_id = "r1", .item_id = t_id, .now_ms = 1000, .timeout_ms = 120_000, .waiter = 9 });
    try testing.expect(r.registered.parked);
    try testing.expectEqual(@as(?i64, 121_000), r.registered.deadline_ms);
    try testing.expectEqual(@as(?i64, 121_000), d.nextDeadline());
    try testing.expectEqual(@as(usize, 1), d.waitingCount());
}

test "unit: feed: wait 0 registers without parking" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    const r = try d.register(.{ .request_id = "r1", .item_id = t_id, .now_ms = 0, .timeout_ms = 0, .waiter = 9 });
    try testing.expect(!r.registered.parked);
    try testing.expectEqual(@as(?i64, null), d.nextDeadline());
    // Still resolvable from the panel; nothing to wake.
    const res = try d.resolve("r1", .{ .permission = .once }, 5);
    try testing.expectEqual(@as(?Waiter, null), res.delivered.waiter);
}

test "unit: feed: resolve wakes the waiter exactly once and is idempotent" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "r1", .item_id = t_id, .now_ms = 0, .timeout_ms = 5000, .waiter = 42 });
    const first = try d.resolve("r1", .{ .permission = .always }, 10);
    try testing.expectEqual(@as(?Waiter, 42), first.delivered.waiter);
    try testing.expect(first.delivered.item_id.eql(t_id));
    const again = try d.resolve("r1", .{ .permission = .always }, 11);
    try testing.expect(again.duplicate.same);
    const other = try d.resolve("r1", .{ .permission = .deny }, 12);
    try testing.expect(!other.duplicate.same);
    try testing.expectEqual(model.PermissionMode.always, other.duplicate.previous.permission);
    // A resolved request never times out afterwards.
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    try d.timeoutDue(1_000_000, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expectEqual(@as(?i64, null), d.nextDeadline());
}

test "unit: feed: resolve copies the resolution (caller buffers may die)" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "q", .item_id = t_id, .now_ms = 0 });
    const sel = try testing.allocator.dupe(u8, "Option 2 \u{2713}");
    const sels = [_][]const u8{sel};
    _ = try d.resolve("q", .{ .question = .{ .selections = &sels } }, 1);
    testing.allocator.free(sel);
    try testing.expectEqualStrings("Option 2 \u{2713}", d.get("q").?.resolution.?.question.selections[0]);
}

test "unit: feed: unknown request id resolves to unknown" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    try testing.expect((try d.resolve("nope", .{ .permission = .once }, 0)) == .unknown);
    try testing.expect((try d.resolve("", .{ .permission = .once }, 0)) == .unknown);
}

test "unit: feed: timeout closes due requests at the deadline boundary" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "a", .item_id = t_id, .now_ms = 0, .timeout_ms = 1000, .waiter = 1 });
    _ = try d.register(.{ .request_id = "b", .item_id = t_id, .now_ms = 0, .timeout_ms = 2000, .waiter = 2 });
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    try d.timeoutDue(999, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try d.timeoutDue(1000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("a", out.items[0].request_id);
    try testing.expectEqual(@as(?Waiter, 1), out.items[0].waiter);
    try testing.expectEqual(model.Status.timed_out, out.items[0].state.itemStatus());
    try testing.expectEqual(@as(?i64, 2000), d.nextDeadline());
    // A late click on the timed-out card reports closed, wakes nothing.
    const late = try d.resolve("a", .{ .permission = .once }, 1500);
    try testing.expectEqual(State.timed_out, late.closed.state);
    // Timing out again does not hand out the waiter a second time.
    out.clearRetainingCapacity();
    try d.timeoutDue(5000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("b", out.items[0].request_id);
}

test "unit: feed: re-push of a waiting request replaces the waiter" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 0, .timeout_ms = 1000, .waiter = 1 });
    const r = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 500, .timeout_ms = 1000, .waiter = 2 });
    try testing.expectEqual(@as(?Waiter, 1), r.registered.replaced);
    try testing.expectEqual(@as(?i64, 1500), r.registered.deadline_ms);
    try testing.expectEqual(@as(usize, 1), d.count());
    const res = try d.resolve("r", .{ .permission = .once }, 600);
    try testing.expectEqual(@as(?Waiter, 2), res.delivered.waiter);
}

test "unit: feed: re-push from the parked waiter itself only extends its deadline" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 0, .timeout_ms = 1000, .waiter = 5 });
    const r = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 400, .timeout_ms = 1000, .waiter = 5 });
    // Answering a "replaced" waiter 5 and later waking it again would reply twice (G5).
    try testing.expectEqual(@as(?Waiter, null), r.registered.replaced);
    try testing.expect(r.registered.parked);
    try testing.expectEqual(@as(?i64, 1400), r.registered.deadline_ms);
    const res = try d.resolve("r", .{ .permission = .once }, 500);
    try testing.expectEqual(@as(?Waiter, 5), res.delivered.waiter);
}

test "unit: feed: non-parking re-push leaves the parked waiter alone" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 0, .timeout_ms = 1000, .waiter = 1 });
    const r = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 10, .timeout_ms = 0, .waiter = 2 });
    try testing.expect(!r.registered.parked);
    try testing.expectEqual(@as(?Waiter, null), r.registered.replaced);
    try testing.expectEqual(@as(?i64, 1000), r.registered.deadline_ms);
    const res = try d.resolve("r", .{ .permission = .once }, 20);
    try testing.expectEqual(@as(?Waiter, 1), res.delivered.waiter);
}

test "unit: feed: re-push after resolution returns the decision at once" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 0, .timeout_ms = 1000, .waiter = 1 });
    _ = try d.resolve("r", .{ .exit_plan = .{ .mode = .manual } }, 1);
    const r = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 2, .timeout_ms = 1000, .waiter = 3 });
    try testing.expectEqual(model.ExitPlanMode.manual, r.already_resolved.exit_plan.mode);
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    try d.timeoutDue(10_000, &out);
    const r2 = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 3 });
    try testing.expect(r2 == .already_resolved);
}

test "unit: feed: dead agent pid expires only its waiting requests" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "a", .item_id = t_id, .pid = 100, .now_ms = 0, .timeout_ms = 1000, .waiter = 1 });
    _ = try d.register(.{ .request_id = "b", .item_id = t_id, .pid = 200, .now_ms = 0, .timeout_ms = 1000, .waiter = 2 });
    _ = try d.register(.{ .request_id = "c", .item_id = t_id, .pid = 100, .now_ms = 0 });
    _ = try d.resolve("c", .{ .permission = .deny }, 1);
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    try d.expirePid(100, 5, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("a", out.items[0].request_id);
    try testing.expectEqual(State.expired, out.items[0].state);
    try testing.expectEqual(State.waiting, d.get("b").?.state);
    try testing.expectEqual(State.resolved, d.get("c").?.state);
}

test "unit: feed: later hook event from the same session retires older requests" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "old", .item_id = t_id, .source = "claude", .session_id = "s1", .now_ms = 0, .timeout_ms = 120_000, .waiter = 1 });
    _ = try d.register(.{ .request_id = "other", .item_id = t_id, .source = "claude", .session_id = "s2", .now_ms = 0 });
    _ = try d.register(.{ .request_id = "cursor", .item_id = t_id, .source = "cursor", .session_id = "s1", .now_ms = 0 });
    _ = try d.register(.{ .request_id = "new", .item_id = t_id, .source = "claude", .session_id = "s1", .now_ms = 50 });
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    try d.retireContext("claude", null, 50, null, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try d.retireContext("claude", "s1", 50, "new", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("old", out.items[0].request_id);
    try testing.expectEqual(@as(?Waiter, 1), out.items[0].waiter);
    try testing.expectEqual(State.waiting, d.get("new").?.state);
    try testing.expectEqual(State.waiting, d.get("other").?.state);
    try testing.expectEqual(State.waiting, d.get("cursor").?.state);
}

test "unit: feed: retireContext spares the request named by keep_request_id" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "old", .item_id = t_id, .source = "claude", .session_id = "s", .now_ms = 0, .timeout_ms = 1000, .waiter = 1 });
    _ = try d.register(.{ .request_id = "self", .item_id = t_id, .source = "claude", .session_id = "s", .now_ms = 10, .timeout_ms = 1000, .waiter = 2 });
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    // Both are older than the event; only "self" is spared.
    try d.retireContext("claude", "s", 50, "self", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("old", out.items[0].request_id);
    try testing.expectEqual(@as(?i64, 50), d.get("old").?.settled_at_ms);
    try testing.expectEqual(State.waiting, d.get("self").?.state);
    // Retiring again reports nothing new (the waiter is handed out once).
    out.clearRetainingCapacity();
    try d.retireContext("claude", "s", 60, "self", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "unit: feed: detached waiter is never woken but request stays answerable" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    _ = try d.register(.{ .request_id = "r", .item_id = t_id, .now_ms = 0, .timeout_ms = 1000, .waiter = 77 });
    try testing.expectEqual(@as(usize, 1), d.detachWaiter(77));
    try testing.expectEqual(@as(usize, 0), d.detachWaiter(77));
    const res = try d.resolve("r", .{ .permission = .once }, 1);
    try testing.expectEqual(@as(?Waiter, null), res.delivered.waiter);
}

test "unit: feed: pruneSettled keeps recent and waiting entries" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    d.retain_settled_ms = 100;
    _ = try d.register(.{ .request_id = "done", .item_id = t_id, .now_ms = 0 });
    _ = try d.register(.{ .request_id = "recent", .item_id = t_id, .now_ms = 0 });
    _ = try d.register(.{ .request_id = "open", .item_id = t_id, .now_ms = 0 });
    _ = try d.resolve("done", .{ .permission = .once }, 0);
    _ = try d.resolve("recent", .{ .permission = .once }, 50);
    d.pruneSettled(100);
    try testing.expect(d.get("done") == null);
    try testing.expect(d.get("recent") != null);
    try testing.expect(d.get("open") != null);
    try testing.expect((try d.resolve("done", .{ .permission = .once }, 101)) == .unknown);
}

test "unit: feed: many pending requests and unicode request ids" {
    var d = Decisions.init(testing.allocator);
    defer d.deinit();
    var buf: [32]u8 = undefined;
    for (0..1000) |i| {
        const rid = try std.fmt.bufPrint(&buf, "req-\u{1F600}-{d}", .{i});
        _ = try d.register(.{ .request_id = rid, .item_id = t_id, .now_ms = @intCast(i), .timeout_ms = 1000, .waiter = i });
    }
    try testing.expectEqual(@as(usize, 1000), d.waitingCount());
    try testing.expectEqual(@as(?i64, 1000), d.nextDeadline());
    var out: std.ArrayList(Closed) = .empty;
    defer out.deinit(testing.allocator);
    try d.timeoutDue(1499, &out);
    try testing.expectEqual(@as(usize, 500), out.items.len);
}

test "unit: feed: register handles allocation failure without leaking" {
    var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var d = Decisions.init(fa.allocator());
        defer d.deinit();
        _ = d.register(.{ .request_id = "r", .item_id = t_id, .source = "claude", .session_id = "s", .now_ms = 0 }) catch continue;
    }
}
