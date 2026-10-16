//! Unit tests of store.zig.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const store = @import("store.zig");
const Uuid = proto.uuid.Uuid;
const testing = std.testing;
const gpa = testing.allocator;

fn idN(n: u32) Uuid {
    var b: [16]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], n, .big);
    return Uuid.fromRandomBytes(b);
}

fn mk(n: u32, json: []const u8) !*model.Item {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    return model.fromEvent(gpa, parsed.value, .{ .id = idN(n), .now_ms = @as(i64, n) * 1000 });
}

fn mkPerm(n: u32) !*model.Item {
    return mk(n, "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"request_id\":\"r\"}");
}

test "unit: feed: store evicts the oldest items beyond capacity" {
    var s = store.Store.init(gpa, 3);
    defer s.deinit();
    for (1..6) |n| _ = try s.add(try mkPerm(@intCast(n)));
    try testing.expectEqual(@as(usize, 3), s.len());
    try testing.expect(s.get(idN(1)) == null);
    try testing.expect(s.get(idN(2)) == null);
    try testing.expect(s.items()[0].id.eql(idN(3)));
    try testing.expect(s.items()[2].id.eql(idN(5)));
}

test "unit: feed: store capacity zero is clamped to one" {
    var s = store.Store.init(gpa, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), try s.add(try mkPerm(1)));
    try testing.expectEqual(@as(usize, 1), try s.add(try mkPerm(2)));
    try testing.expectEqual(@as(usize, 1), s.len());
}

test "unit: feed: adding an existing id replaces it in place" {
    var s = store.Store.init(gpa, 10);
    defer s.deinit();
    _ = try s.add(try mkPerm(1));
    _ = try s.add(try mkPerm(2));
    const updated = try s.get(idN(1)).?.clone(gpa);
    try updated.resolve(.{ .permission = .once }, 99);
    _ = try s.add(updated);
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expect(s.items()[0] == updated);
    try testing.expectEqual(model.Status.resolved, s.get(idN(1)).?.status);
}

test "unit: feed: re-adding the stored item itself after an in-place update is a no-op" {
    var s = store.Store.init(gpa, 10);
    defer s.deinit();
    _ = try s.add(try mkPerm(1));
    _ = try s.add(try mkPerm(2));
    const it = s.get(idN(1)).?;
    try it.resolve(.{ .permission = .once }, 5);
    try testing.expectEqual(@as(usize, 0), try s.add(it));
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expect(s.get(idN(1)).? == it);
    try testing.expect(s.items()[0] == it);
    try testing.expectEqual(model.Status.resolved, s.items()[0].status);
}

test "unit: feed: findByRequestId returns the newest match" {
    var s = store.Store.init(gpa, 10);
    defer s.deinit();
    _ = try s.add(try mkPerm(1));
    _ = try s.add(try mkPerm(2));
    _ = try s.add(try mk(3, "{\"hook_event_name\":\"Stop\"}"));
    try testing.expect(s.findByRequestId("r").?.id.eql(idN(2)));
    try testing.expect(s.findByRequestId("missing") == null);
    s.clear();
    try testing.expectEqual(@as(usize, 0), s.len());
    try testing.expect(s.findByRequestId("r") == null);
}

test "unit: feed: JSONL line round-trips every field" {
    const it = try mk(7,
        \\{"hook_event_name":"PermissionRequest","source":"claude","tool_name":"AskUserQuestion",
        \\ "session_id":"s\u00e9","request_id":"req","pid":12,"cwd":"C:\\w","workspace_id":"0F0E0D0C-0B0A-4908-8706-050403020100",
        \\ "tool_input":{"questions":[{"question":"Pick \ud83d\ude00","header":"H","multiSelect":true,
        \\   "options":[{"label":"A","description":"d"},{"label":"B"}]}]}}
    );
    defer it.destroy();
    const sels = [_][]const u8{ "A", "B" };
    try it.resolve(.{ .question = .{ .selections = &sels } }, 8000);
    const line = try store.encodeLine(gpa, it);
    defer gpa.free(line);
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expect(std.mem.startsWith(u8, line, "{\"v\":1,"));
    const back = try store.decodeLine(gpa, line);
    defer back.destroy();
    try testing.expect(back.id.eql(it.id));
    try testing.expectEqual(model.Kind.question, back.kind);
    try testing.expectEqual(model.Status.resolved, back.status);
    try testing.expectEqualStrings("claude", back.source);
    try testing.expectEqualStrings("s\u{e9}", back.session_id.?);
    try testing.expectEqualStrings("req", back.request_id.?);
    try testing.expectEqual(@as(?u32, 12), back.pid);
    try testing.expectEqualStrings("C:\\w", back.cwd.?);
    try testing.expect(back.workspace_id.?.eql(it.workspace_id.?));
    try testing.expect(back.surface_id == null);
    try testing.expectEqualStrings("Pick \u{1F600}", back.questions[0].question);
    try testing.expect(back.questions[0].multi_select);
    try testing.expectEqualStrings("d", back.questions[0].options[0].description);
    try testing.expectEqualStrings("B", back.resolution.?.question.selections[1]);
    try testing.expectEqual(@as(?i64, 8000), back.resolved_at_ms);
    try testing.expectEqual(it.created_at_ms, back.created_at_ms);
    try testing.expectEqualStrings(it.tool_input_json.?, back.tool_input_json.?);
    // Re-encoding is byte-identical.
    const line2 = try store.encodeLine(gpa, back);
    defer gpa.free(line2);
    try testing.expectEqualStrings(line, line2);
}

test "unit: feed: JSONL keeps permission modes, plan, todos and resolutions" {
    const perm = try mk(1, "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"permission_suggestions\":[{}]}");
    defer perm.destroy();
    try perm.resolve(.{ .permission = .all }, 5);
    const plan = try mk(2, "{\"hook_event_name\":\"PermissionRequest\",\"source\":\"claude\",\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"P\",\"allowedPrompts\":[\"x\"]}}");
    defer plan.destroy();
    try plan.resolve(.{ .exit_plan = .{ .mode = .deny, .feedback = "redo \"step\"\n2" } }, 6);
    const todos = try mk(3, "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[{\"content\":\"t\",\"status\":\"in_progress\"}]}}");
    defer todos.destroy();
    const stop = try mk(4, "{\"hook_event_name\":\"Stop\"}");
    defer stop.destroy();
    try stop.resolve(.{ .reply = "go on" }, 7);
    const result = try mk(5, "{\"hook_event_name\":\"PostToolUse\",\"is_error\":true}");
    defer result.destroy();

    for ([_]*model.Item{ perm, plan, todos, stop, result }) |it| {
        const line = try store.encodeLine(gpa, it);
        defer gpa.free(line);
        const back = try store.decodeLine(gpa, line);
        defer back.destroy();
        try testing.expectEqual(it.kind, back.kind);
        try testing.expectEqual(it.status, back.status);
        try testing.expectEqual(it.permission_modes, back.permission_modes);
        try testing.expectEqual(it.exit_plan_modes, back.exit_plan_modes);
        try testing.expectEqual(it.tool_error, back.tool_error);
        try testing.expectEqual(it.todos.len, back.todos.len);
        if (it.resolution) |r| try testing.expect(r.eql(back.resolution.?)) else try testing.expect(back.resolution == null);
    }
}

test "unit: feed: decodeLine rejects malformed records" {
    const bad = [_][]const u8{
        "",
        "   ",
        "not json",
        "{\"id\":\"x\"",
        "[]",
        "{\"v\":1,\"id\":\"nope\",\"kind\":\"stop\",\"status\":\"info\",\"created_at_ms\":1}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"bogus\",\"status\":\"info\",\"created_at_ms\":1}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"stop\",\"status\":\"meh\",\"created_at_ms\":1}",
        "{\"v\":2,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"stop\",\"status\":\"info\",\"created_at_ms\":1}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"stop\",\"status\":\"info\"}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"stop\",\"status\":\"info\",\"created_at_ms\":true}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"stop\",\"status\":\"info\",\"created_at_ms\":1,\"resolution\":{\"kind\":\"permission\",\"mode\":\"once\"}}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"permissionRequest\",\"status\":\"resolved\",\"created_at_ms\":1,\"resolution\":{\"kind\":\"permission\",\"mode\":\"sometimes\"}}",
        "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"permissionRequest\",\"status\":\"resolved\",\"created_at_ms\":1,\"resolution\":{\"kind\":\"vibes\"}}",
    };
    for (bad) |line| try testing.expectError(error.InvalidRecord, store.decodeLine(gpa, line));
}

test "unit: feed: decodeLine tolerates unknown fields, CRLF and minimal records" {
    const it = try store.decodeLine(gpa, "{\"v\":1,\"id\":\"00000000-0000-4000-8000-000000000001\",\"kind\":\"permissionRequest\",\"status\":\"pending\",\"created_at_ms\":5,\"future\":{\"x\":[1]},\"surface_id\":\"bad\"}\r\n");
    defer it.destroy();
    try testing.expectEqual(@as(i64, 5), it.updated_at_ms);
    try testing.expect(it.surface_id == null);
    try testing.expect(it.permission_modes.has(.once) and it.permission_modes.has(.deny));
    try testing.expect(!it.permission_modes.has(.bypass));
}

fn appendLine(buf: *std.ArrayList(u8), it: *const model.Item) !void {
    const line = try store.encodeLine(gpa, it);
    defer gpa.free(line);
    try buf.appendSlice(gpa, line);
}

test "unit: feed: load collapses mutation rows to the latest state" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    const a = try mkPerm(1);
    defer a.destroy();
    const b = try mk(2, "{\"hook_event_name\":\"Stop\"}");
    defer b.destroy();
    try appendLine(&file, a);
    try appendLine(&file, b);
    try file.appendSlice(gpa, "garbage line\n\n");
    try a.resolve(.{ .permission = .deny }, 3000);
    try appendLine(&file, a);
    // Torn tail write (crash mid-append).
    try file.appendSlice(gpa, "{\"v\":1,\"id\":\"0000");

    var s = store.Store.init(gpa, 2000);
    defer s.deinit();
    const stats = try s.load(file.items);
    try testing.expectEqual(@as(usize, 3), stats.lines);
    try testing.expectEqual(@as(usize, 2), stats.skipped);
    try testing.expectEqual(@as(usize, 2), stats.distinct);
    try testing.expectEqual(@as(usize, 0), stats.evicted);
    try testing.expectEqual(@as(usize, 2), s.len());
    // Order by creation, not by the mutation row.
    try testing.expect(s.items()[0].id.eql(idN(1)));
    try testing.expectEqual(model.Status.resolved, s.items()[0].status);
    try testing.expectEqualStrings("denied", s.items()[0].resolution.?.badge());
}

test "unit: feed: load keeps only the newest capacity items" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    for (1..11) |n| {
        const it = try mkPerm(@intCast(n));
        defer it.destroy();
        try appendLine(&file, it);
    }
    var s = store.Store.init(gpa, 4);
    defer s.deinit();
    const stats = try s.load(file.items);
    try testing.expectEqual(@as(usize, 6), stats.evicted);
    try testing.expectEqual(@as(usize, 4), s.len());
    try testing.expect(s.items()[0].id.eql(idN(7)));
    try testing.expect(s.items()[3].id.eql(idN(10)));
}

test "unit: feed: load of empty and all-garbage files" {
    var s = store.Store.init(gpa, 10);
    defer s.deinit();
    const e = try s.load("");
    try testing.expectEqual(@as(usize, 0), e.lines + e.skipped);
    const g = try s.load("\x00\xff\xfe\n{]\n\n\r\n");
    try testing.expectEqual(@as(usize, 2), g.skipped);
    try testing.expectEqual(@as(usize, 0), s.len());
}

test "unit: feed: compaction keeps one line per item, newest first kept" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    var items: [5]*model.Item = undefined;
    for (&items, 1..) |*p, n| p.* = try mkPerm(@intCast(n));
    defer for (items) |it| it.destroy();
    for (items) |it| try appendLine(&file, it);
    try items[0].resolve(.{ .permission = .once }, 9000);
    try appendLine(&file, items[0]);
    try items[4].resolve(.{ .permission = .deny }, 9001);
    try appendLine(&file, items[4]);
    try file.appendSlice(gpa, "junk\n");

    const unbounded = std.math.maxInt(u64);
    const out = try store.compactJsonl(gpa, file.items, 3, unbounded);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    const stats = try s.load(out);
    try testing.expectEqual(@as(usize, 0), stats.skipped);
    try testing.expect(s.items()[0].id.eql(idN(3)));
    try testing.expectEqual(model.Status.resolved, s.items()[2].status);
    // Compacting again is a fixed point.
    const again = try store.compactJsonl(gpa, out, 3, unbounded);
    defer gpa.free(again);
    try testing.expectEqualStrings(out, again);
    const none = try store.compactJsonl(gpa, file.items, 0, unbounded);
    defer gpa.free(none);
    try testing.expectEqualStrings("", none);
}

test "unit: feed: compaction honors the byte budget so it cannot re-trigger" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    var line_len: usize = 0;
    var body: [3000]u8 = undefined;
    @memset(&body, 'm');
    for (1..7) |n| {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(gpa);
        try json.appendSlice(gpa, "{\"hook_event_name\":\"Notification\",\"message\":\"");
        try json.appendSlice(gpa, &body);
        try json.appendSlice(gpa, "\"}");
        const it = try mk(@intCast(n), json.items);
        defer it.destroy();
        const line = try store.encodeLine(gpa, it);
        defer gpa.free(line);
        line_len = line.len;
        try file.appendSlice(gpa, line);
    }
    // Room for three lines (plus slack below a fourth): the newest three stay.
    const budget: u64 = line_len * 3 + line_len / 2;
    const out = try store.compactJsonl(gpa, file.items, 100, budget);
    defer gpa.free(out);
    try testing.expect(out.len <= budget);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    _ = try s.load(out);
    try testing.expect(s.items()[0].id.eql(idN(4)));
    try testing.expect(s.items()[2].id.eql(idN(6)));
    // Exactly three lines' worth also keeps three.
    const exact = try store.compactJsonl(gpa, file.items, 100, line_len * 3);
    defer gpa.free(exact);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, exact, "\n"));
    // A budget below one line keeps nothing.
    const tiny = try store.compactJsonl(gpa, file.items, 100, line_len - 1);
    defer gpa.free(tiny);
    try testing.expectEqualStrings("", tiny);
    // With the retention budget, a size-triggered compaction ends below the trigger.
    const r: store.Retention = .{ .max_file_bytes = file.items.len - 1 };
    try testing.expect(store.needsCompaction(6, file.items.len, r));
    const compacted = try store.compactJsonl(gpa, file.items, r.file_items, r.compactBytes());
    defer gpa.free(compacted);
    try testing.expect(compacted.len > 0);
    try testing.expect(!store.needsCompaction(std.mem.count(u8, compacted, "\n"), compacted.len, r));
}

test "unit: feed: compaction policy thresholds" {
    const r: store.Retention = .{ .file_items = 10, .slack_lines = 5, .max_file_bytes = 1000 };
    try testing.expect(!store.needsCompaction(15, 1000, r));
    try testing.expect(store.needsCompaction(16, 0, r));
    try testing.expect(store.needsCompaction(0, 1001, r));
    const d: store.Retention = .{};
    try testing.expectEqual(@as(usize, 2000), d.memory);
    try testing.expectEqualStrings("workstream.jsonl", store.file_name);
}

test "unit: feed: store ring holds 2000 items under a larger stream" {
    var s = store.Store.init(gpa, 2000);
    defer s.deinit();
    var evicted: usize = 0;
    for (0..2500) |n| evicted += try s.add(try mk(@intCast(n), "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\"}"));
    try testing.expectEqual(@as(usize, 500), evicted);
    try testing.expectEqual(@as(usize, 2000), s.len());
    try testing.expect(s.items()[0].id.eql(idN(500)));
    try testing.expect(s.get(idN(499)) == null);
    try testing.expect(s.get(idN(2499)) != null);
}

test "unit: feed: load survives allocation failure without leaks" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    for (1..4) |n| {
        const it = try mkPerm(@intCast(n));
        defer it.destroy();
        try appendLine(&file, it);
        try appendLine(&file, it);
    }
    var i: usize = 0;
    while (true) : (i += 1) {
        var fa = testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        var s = store.Store.init(fa.allocator(), 2);
        defer s.deinit();
        _ = s.load(file.items) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        try testing.expectEqual(@as(usize, 2), s.len());
        break;
    }
}
