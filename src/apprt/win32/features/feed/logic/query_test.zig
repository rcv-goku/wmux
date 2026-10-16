//! Unit tests of query.zig.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const store = @import("store.zig");
const query = @import("query.zig");
const Uuid = proto.uuid.Uuid;
const testing = std.testing;
const gpa = testing.allocator;

const ws_a = "0F0E0D0C-0B0A-4908-8706-050403020100";
const ws_b = "1F0E0D0C-0B0A-4908-8706-050403020100";

fn idN(n: u32) Uuid {
    var b: [16]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], n, .big);
    return Uuid.fromRandomBytes(b);
}

fn add(s: *store.Store, n: u32, json: []const u8) !*model.Item {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const it = try model.fromEvent(gpa, parsed.value, .{ .id = idN(n), .now_ms = @as(i64, n) * 1000 });
    _ = try s.add(it);
    return it;
}

/// 1 perm(claude,s1,ws_a) pending, 2 tool use, 3 plan(claude,s1) resolved,
/// 4 question(cursor,s2,ws_b) pending, 5 stop(claude,s1), 6 perm(codex) expired.
fn fixture(s: *store.Store) !void {
    _ = try add(s, 1, "{\"hook_event_name\":\"PermissionRequest\",\"source\":\"claude\",\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"workspace_id\":\"" ++ ws_a ++ "\"}");
    _ = try add(s, 2, "{\"hook_event_name\":\"PreToolUse\",\"source\":\"claude\",\"session_id\":\"s1\",\"tool_name\":\"Read\"}");
    const plan = try add(s, 3, "{\"hook_event_name\":\"PermissionRequest\",\"source\":\"claude\",\"session_id\":\"s1\",\"tool_name\":\"ExitPlanMode\"}");
    try plan.resolve(.{ .exit_plan = .{ .mode = .auto_accept } }, 3500);
    _ = try add(s, 4, "{\"hook_event_name\":\"PermissionRequest\",\"source\":\"cursor\",\"session_id\":\"s2\",\"tool_name\":\"AskUserQuestion\",\"surface_id\":\"" ++ ws_b ++ "\",\"workspace_id\":\"" ++ ws_b ++ "\",\"tool_input\":{\"questions\":[{\"question\":\"Q\",\"options\":[{\"label\":\"one\"},{\"label\":\"two\"}]}]}}");
    _ = try add(s, 5, "{\"hook_event_name\":\"Stop\",\"source\":\"claude\",\"session_id\":\"s1\"}");
    const cx = try add(s, 6, "{\"hook_event_name\":\"PermissionRequest\",\"source\":\"codex\",\"tool_name\":\"Bash\"}");
    cx.close(.expired, 6500);
}

fn ids(page: query.Page, buf: []u32) []u32 {
    for (page.items, 0..) |it, i| buf[i] = std.mem.readInt(u32, it.id.b[0..4], .big);
    return buf[0..page.items.len];
}

fn parse(a: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
}

test "unit: feed: list returns latest first with default filter" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    const page = try query.select(gpa, s.items(), .{});
    defer page.deinit(gpa);
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 6, 5, 4, 3, 2, 1 }, ids(page, &buf));
    try testing.expect(!page.has_more);
}

test "unit: feed: pending_only keeps pending decisions" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    const page = try query.select(gpa, s.items(), .{ .pending_only = true });
    defer page.deinit(gpa);
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 4, 1 }, ids(page, &buf));
}

test "unit: feed: filters by kind, source, session, workspace and surface" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    var buf: [16]u32 = undefined;
    const C = struct { f: query.Filter, want: []const u32 };
    const cases = [_]C{
        .{ .f = .{ .kinds = &.{ .permission_request, .stop } }, .want = &.{ 6, 5, 1 } },
        .{ .f = .{ .source = "CLAUDE" }, .want = &.{ 5, 3, 2, 1 } },
        .{ .f = .{ .session_id = "s2" }, .want = &.{4} },
        .{ .f = .{ .session_id = "" }, .want = &.{} },
        .{ .f = .{ .workspace_id = try Uuid.parse(ws_a) }, .want = &.{1} },
        .{ .f = .{ .surface_id = try Uuid.parse(ws_b) }, .want = &.{4} },
        .{ .f = .{ .source = "claude", .pending_only = true }, .want = &.{1} },
    };
    for (cases) |c| {
        const page = try query.select(gpa, s.items(), c.f);
        defer page.deinit(gpa);
        try testing.expectEqualSlices(u32, c.want, ids(page, &buf));
    }
}

test "unit: feed: limit and before cursor page older activity" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    var buf: [16]u32 = undefined;
    const p1 = try query.select(gpa, s.items(), .{ .limit = 2 });
    defer p1.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 6, 5 }, ids(p1, &buf));
    try testing.expect(p1.has_more);
    const p2 = try query.select(gpa, s.items(), .{ .limit = 2, .before = p1.items[1].id });
    defer p2.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 4, 3 }, ids(p2, &buf));
    try testing.expect(p2.has_more);
    const p3 = try query.select(gpa, s.items(), .{ .limit = 2, .before = p2.items[1].id });
    defer p3.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, ids(p3, &buf));
    try testing.expect(!p3.has_more);
    const p4 = try query.select(gpa, s.items(), .{ .before = idN(1) });
    defer p4.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), p4.items.len);
    const unknown = try query.select(gpa, s.items(), .{ .before = idN(999) });
    defer unknown.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), unknown.items.len);
}

test "unit: feed: select on an empty store" {
    const page = try query.select(gpa, &.{}, .{ .pending_only = true });
    defer page.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), page.items.len);
    try testing.expect(!page.has_more);
    const act = try query.actionable(gpa, &.{});
    defer act.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), act.pending.len + act.resolved.len);
    const w = try query.workstreams(gpa, &.{});
    defer gpa.free(w);
    try testing.expectEqual(@as(usize, 0), w.len);
    try testing.expectEqualStrings("No pending decisions", query.empty_actionable.title);
    try testing.expectEqualStrings("Agent decisions and todo-list updates will appear here.", query.empty_activity.body);
}

test "unit: feed: parseListParams reads cmux and wmux keys" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: query.ParamDiag = .{};
    const none = try query.parseListParams(a, null, &diag);
    try testing.expect(!none.pending_only);
    try testing.expectEqual(query.default_limit, none.limit);
    const f = try query.parseListParams(a, try parse(a,
        \\{"pending_only":true,"kind":["question","exitPlan"],"source":"claude","session_id":"s",
        \\ "workspace_id":"
    ++ ws_a ++
        \\","before":null,"limit":5,"extra":1}
    ), &diag);
    try testing.expect(f.pending_only);
    try testing.expectEqualSlices(model.Kind, &.{ .question, .exit_plan }, f.kinds);
    try testing.expectEqualStrings("claude", f.source.?);
    try testing.expectEqualStrings("s", f.session_id.?);
    try testing.expect(f.workspace_id.?.eql(try Uuid.parse(ws_a)));
    try testing.expect(f.before == null);
    try testing.expectEqual(@as(usize, 5), f.limit);
    const single = try query.parseListParams(a, try parse(a, "{\"kind\":\"stop\"}"), &diag);
    try testing.expectEqualSlices(model.Kind, &.{.stop}, single.kinds);
}

test "unit: feed: parseListParams rejects malformed params with a message" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const C = struct { json: []const u8, msg: []const u8 };
    const cases = [_]C{
        .{ .json = "[1]", .msg = "params must be an object" },
        .{ .json = "{\"pending_only\":\"yes\"}", .msg = "pending_only must be a boolean" },
        .{ .json = "{\"pending_only\":1}", .msg = "pending_only must be a boolean" },
        .{ .json = "{\"kind\":\"Permission\"}", .msg = "unknown feed item kind" },
        .{ .json = "{\"kind\":[\"stop\",3]}", .msg = "kind must be a string or an array of strings" },
        .{ .json = "{\"kind\":{}}", .msg = "kind must be a string or an array of strings" },
        .{ .json = "{\"source\":1}", .msg = "source must be a string" },
        .{ .json = "{\"workspace_id\":\"workspace:1\"}", .msg = "workspace_id must be a UUID" },
        .{ .json = "{\"before\":7}", .msg = "before must be a UUID" },
        .{ .json = "{\"limit\":0}", .msg = "limit must be between 1 and 2000" },
        .{ .json = "{\"limit\":2001}", .msg = "limit must be between 1 and 2000" },
        .{ .json = "{\"limit\":1.5}", .msg = "limit must be between 1 and 2000" },
    };
    for (cases) |c| {
        var diag: query.ParamDiag = .{};
        try testing.expectError(error.InvalidParams, query.parseListParams(a, try parse(a, c.json), &diag));
        try testing.expectEqualStrings(c.msg, diag.message);
    }
}

test "unit: feed: actionable partitions pending and resolved decisions" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    const act = try query.actionable(gpa, s.items());
    defer act.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), act.pending.len);
    try testing.expect(act.pending[0].id.eql(idN(4)));
    try testing.expectEqual(@as(usize, 2), act.resolved.len);
    try testing.expect(act.resolved[0].id.eql(idN(6)));
    try testing.expectEqualStrings("auto", act.resolved[1].resolution.?.badge());
}

test "unit: feed: workstreams group by source and session" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    const w = try query.workstreams(gpa, s.items());
    defer gpa.free(w);
    try testing.expectEqual(@as(usize, 3), w.len);
    // codex (expired at 6500) is the most recently active.
    try testing.expectEqualStrings("codex", w[0].source);
    try testing.expect(w[0].session_id == null);
    try testing.expectEqualStrings("claude", w[1].source);
    try testing.expectEqualStrings("s1", w[1].session_id.?);
    try testing.expectEqual(@as(usize, 4), w[1].item_count);
    try testing.expectEqual(@as(usize, 1), w[1].pending_count);
    try testing.expect(w[1].latest.id.eql(idN(5)));
    try testing.expect(w[1].workspace_id.?.eql(try Uuid.parse(ws_a)));
    try testing.expectEqualStrings("cursor", w[2].source);
    try testing.expect(w[2].surface_id != null);
}

test "unit: feed: list JSON carries kind, status, options and resolution" {
    var s = store.Store.init(gpa, 100);
    defer s.deinit();
    try fixture(&s);
    const page = try query.select(gpa, s.items(), .{});
    defer page.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try query.writeListJson(&aw.writer, page);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("has_more").?.bool);
    const items = root.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 6), items.len);

    const q = items[2].object; // id 4, question
    try testing.expectEqualStrings("question", q.get("kind").?.string);
    try testing.expectEqualStrings("pending", q.get("status").?.string);
    try testing.expectEqualStrings("cursor", q.get("source").?.string);
    try testing.expectEqual(@as(f64, 4.0), q.get("created_at").?.float);
    try testing.expectEqual(@as(usize, 2), q.get("options").?.array.items.len);
    try testing.expectEqualStrings("one", q.get("questions").?.array.items[0].object.get("options").?.array.items[0].object.get("label").?.string);

    const plan = items[3].object; // id 3, resolved plan
    try testing.expectEqualStrings("exitPlan", plan.get("kind").?.string);
    try testing.expectEqualStrings("resolved", plan.get("status").?.string);
    try testing.expectEqual(@as(usize, 0), plan.get("options").?.array.items.len);
    const res = plan.get("resolution").?.object;
    try testing.expectEqualStrings("autoAccept", res.get("mode").?.string);
    try testing.expectEqualStrings("auto", res.get("badge").?.string);

    const perm = items[5].object; // id 1, pending claude permission
    try testing.expectEqualStrings("permissionRequest", perm.get("kind").?.string);
    const opts = perm.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 3), opts.len);
    try testing.expectEqualStrings("once", opts[0].string);
    try testing.expectEqualStrings("bypass", opts[1].string);
    try testing.expectEqualStrings("deny", opts[2].string);
    try testing.expectEqualStrings(ws_a, perm.get("workspace_id").?.string);

    const tool = items[4].object; // id 2, activity: no options key
    try testing.expect(tool.get("options") == null);
    try testing.expectEqualStrings("toolUse", tool.get("kind").?.string);
    try testing.expectEqualStrings("expired", items[0].object.get("status").?.string);
}

test "unit: feed: list JSON encodes todo summary, negative and sub-second times" {
    var s = store.Store.init(gpa, 10);
    defer s.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[{\"content\":\"\\u0000x\",\"status\":\"completed\"}]}}", .{});
    defer parsed.deinit();
    const it = try model.fromEvent(gpa, parsed.value, .{ .id = idN(1), .now_ms = 1_760_000_000_123 });
    _ = try s.add(it);
    const it2 = try model.fromEvent(gpa, parsed.value, .{ .id = idN(2), .now_ms = -1500 });
    _ = try s.add(it2);
    const page = try query.select(gpa, s.items(), .{});
    defer page.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try query.writeListJson(&aw.writer, page);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"created_at\":1760000000.123") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"created_at\":-1.500") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"todo_summary\":\"1 done\"") != null);
    const back = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer back.deinit();
    try testing.expectEqualStrings("\x00x", back.value.object.get("items").?.array.items[0].object.get("todos").?.array.items[0].object.get("content").?.string);
}
