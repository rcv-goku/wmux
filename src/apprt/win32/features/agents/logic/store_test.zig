//! Tests for store.zig (ADR-10.2 hook session store model).

const std = @import("std");
const testing = std.testing;
const store = @import("store.zig");
const Store = store.Store;

const surf_a = "AAAAAAAA-1111-4111-8111-111111111111";
const surf_b = "BBBBBBBB-2222-4222-8222-222222222222";
const ws_1 = "CCCCCCCC-3333-4333-8333-333333333333";

fn roundTrip(s: *const Store) !Store {
    const json = try s.toOwnedJson(testing.allocator);
    defer testing.allocator.free(json);
    return Store.parse(testing.allocator, json);
}

test "unit: agents: store file names" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("claude-hook-sessions.json", store.fileName(&buf, "claude").?);
    try testing.expectEqualStrings("hermes-agent-hook-sessions.json", store.fileName(&buf, "hermes-agent").?);
    try testing.expectEqualStrings("codex-hook-sessions.json.lock", store.lockFileName(&buf, "codex").?);
    try testing.expect(store.fileName(&buf, "../evil") == null);
    try testing.expect(store.fileName(&buf, "") == null);
    var tiny: [4]u8 = undefined;
    try testing.expect(store.fileName(&tiny, "claude") == null);
    try testing.expectEqual(@as(usize, 20), store.known_suffixes.len);
}

test "unit: agents: store one claude turn yields one record with surface, cwd and argv" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.applyHook(.{
        .session_id = "sess-1",
        .now_ms = 1_760_000_000_000,
        .workspace_id = ws_1,
        .surface_id = surf_a,
        .cwd = "C:\\src\\demo",
        .transcript_path = "C:/Users/dev/.claude/projects/demo/sess-1.jsonl",
        .pid = 4100,
        .pid_start_time = 133_000_000_000_000_000,
        .launch_command = .{ .executable = "claude", .arguments = &.{ "--model", "opus" }, .working_directory = "C:\\src\\demo" },
        .lifecycle = .idle,
        .hook_event_name = "SessionStart",
        .is_restorable = true,
    });
    try s.applyHook(.{ .session_id = "sess-1", .now_ms = 1_760_000_001_000, .lifecycle = .running, .hook_event_name = "UserPromptSubmit", .turn = .begin, .turn_id = "turn-1", .permission_mode = "default" });
    try s.applyHook(.{ .session_id = "sess-1", .now_ms = 1_760_000_002_500, .lifecycle = .idle, .hook_event_name = "Stop", .turn = .settle, .last_subtitle = "Completed in demo", .last_body = "Done.", .had_pending_background_work_at_stop = false });

    try testing.expectEqual(@as(usize, 1), s.count());
    const r = s.activeForSurface(surf_a).?;
    try testing.expectEqualStrings("sess-1", r.session_id);
    try testing.expectEqualStrings("C:\\src\\demo", r.cwd.?);
    try testing.expectEqualStrings("claude", r.launch_command.?.executable.?);
    try testing.expectEqual(@as(usize, 2), r.launch_command.?.arguments.len);
    try testing.expectEqual(store.Lifecycle.idle, r.agent_lifecycle);
    try testing.expectEqual(@as(?bool, true), r.turn_settled);
    try testing.expectEqualStrings("turn-1", r.last_prompt_turn_id.?);
    try testing.expect(r.active_prompt_turn_id == null);
    try testing.expectEqual(@as(?i64, 1_760_000_000_000), r.started_at_ms);
    try testing.expectEqual(@as(?i64, 1_760_000_002_500), r.updated_at_ms);
    try testing.expectEqualStrings("default", r.last_permission_mode.?);
    try testing.expectEqual(r, s.activeForWorkspace(ws_1).?);

    const json = try s.toOwnedJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"activeSessionsBySurface\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"startedAt\": 1760000000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"updatedAt\": 1760000002.5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"agentLifecycle\": \"idle\"") != null);
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));
}

test "unit: agents: store serialization round-trips every field" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.applyHook(.{
        .session_id = "s-ü",
        .now_ms = 1_700_000_000_123,
        .workspace_id = ws_1,
        .surface_id = surf_a,
        .cwd = "/home/dev/日本",
        .title = "Fix \"quotes\"\nand newlines",
        .transcript_path = "/t.jsonl",
        .pid = 7,
        .pid_start_time = 99,
        .launch_command = .{ .executable = "codex", .arguments = &.{ "-c", "model=\"o3\"" }, .working_directory = "/w", .rejection_reason = "none" },
        .permission_mode = "plan",
        .is_restorable = false,
        .lifecycle = .backgroundWorkPending,
        .hook_event_name = "Stop",
        .last_subtitle = "Completed",
        .last_body = "body",
        .runtime_status = "ok",
        .turn = .begin,
        .turn_id = "t9",
        .had_pending_background_work_at_stop = true,
        .last_auto_name_at_ms = 1_700_000_000_000,
        .auto_name_turn_count = 3,
    });
    var t = try roundTrip(&s);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.diagnostics.items.len);
    const r = t.get("s-ü").?;
    try testing.expectEqualStrings(ws_1, r.workspace_id.?);
    try testing.expectEqualStrings("/home/dev/日本", r.cwd.?);
    try testing.expectEqualStrings("Fix \"quotes\"\nand newlines", r.title.?);
    try testing.expectEqual(@as(?i64, 7), r.pid);
    try testing.expectEqual(@as(?i64, 99), r.pid_start_time);
    try testing.expectEqualStrings("model=\"o3\"", r.launch_command.?.arguments[1]);
    try testing.expectEqualStrings("none", r.launch_command.?.rejection_reason.?);
    try testing.expectEqual(@as(?bool, false), r.is_restorable);
    try testing.expectEqual(store.Lifecycle.backgroundWorkPending, r.agent_lifecycle);
    try testing.expectEqual(@as(?bool, false), r.turn_settled);
    try testing.expectEqualStrings("t9", r.active_prompt_turn_id.?);
    try testing.expectEqual(@as(?i64, 1_700_000_000_123), r.started_at_ms);
    try testing.expectEqual(@as(?i64, 1_700_000_000_000), r.last_auto_name_at_ms);
    try testing.expectEqual(@as(?i64, 3), r.auto_name_turn_count);
    try testing.expectEqual(@as(?bool, true), r.had_pending_background_work_at_stop);
    try testing.expectEqualStrings("s-ü", t.activeForSurface(surf_a).?.session_id);

    // Serialization is stable: a second round trip is byte-identical.
    const a = try s.toOwnedJson(testing.allocator);
    defer testing.allocator.free(a);
    const b = try t.toOwnedJson(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "unit: agents: store merge keeps fields that an update leaves null" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.applyHook(.{ .session_id = "x", .now_ms = 10, .cwd = "/a", .transcript_path = "/t", .pid = 5, .pid_start_time = 50 });
    try s.applyHook(.{ .session_id = "x", .now_ms = 5, .lifecycle = .running });
    const r = s.get("x").?;
    try testing.expectEqualStrings("/a", r.cwd.?);
    try testing.expectEqualStrings("/t", r.transcript_path.?);
    try testing.expectEqual(store.Lifecycle.running, r.agent_lifecycle);
    // updatedAt never moves backwards.
    try testing.expectEqual(@as(?i64, 10), r.updated_at_ms);
    // A new pid without a start time does not inherit the old start time.
    try s.applyHook(.{ .session_id = "x", .now_ms = 20, .pid = 6 });
    try testing.expectEqual(@as(?i64, 6), s.get("x").?.pid);
    try testing.expect(s.get("x").?.pid_start_time == null);
    try testing.expectError(error.MissingSessionId, s.applyHook(.{ .session_id = "  ", .now_ms = 1 }));
}

test "unit: agents: store superseded sessions on the same surface are cleaned up" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.applyHook(.{ .session_id = "old", .now_ms = 1, .surface_id = surf_a, .workspace_id = ws_1 });
    try s.applyHook(.{ .session_id = "other", .now_ms = 2, .surface_id = surf_b, .workspace_id = ws_1 });
    try s.applyHook(.{ .session_id = "new", .now_ms = 3, .surface_id = surf_a, .workspace_id = ws_1 });
    try testing.expect(s.get("old") == null);
    try testing.expect(s.get("other") != null);
    try testing.expectEqualStrings("new", s.activeForSurface(surf_a).?.session_id);
    try testing.expectEqualStrings("other", s.activeForSurface(surf_b).?.session_id);
    try testing.expectEqualStrings("new", s.activeForWorkspace(ws_1).?.session_id);

    // A session moving to another surface leaves no stale surface mapping.
    try s.applyHook(.{ .session_id = "new", .now_ms = 4, .surface_id = surf_b });
    try testing.expect(s.activeForSurface(surf_a) == null);
    try testing.expectEqualStrings("new", s.activeForSurface(surf_b).?.session_id);
    try testing.expect(s.get("other") == null);

    // activate=false records without touching the active maps.
    try s.applyHook(.{ .session_id = "quiet", .now_ms = 5, .surface_id = surf_a, .activate = false });
    try testing.expect(s.activeForSurface(surf_a) == null);
}

test "unit: agents: store corrupt entries are dropped individually" {
    const doc =
        \\{"version":1,
        \\ "sessions":{
        \\   "good":{"sessionId":"good","surfaceId":"S1","cwd":"/ok","agentLifecycle":"running","updatedAt":1700000000},
        \\   "notobj":[1,2],
        \\   "badid":{"sessionId":42},
        \\   "wrongtypes":{"cwd":7,"pid":"x","isRestorable":"yes","agentLifecycle":"sleeping","launchCommand":"claude","startedAt":"yesterday"},
        \\   "mismatch":{"sessionId":"other","workspaceId":null},
        \\   "":{"sessionId":""}
        \\ },
        \\ "activeSessionsBySurface":{"S1":"good","S2":"missing","S3":5},
        \\ "activeSessionsByWorkspace":[]
        \\}
    ;
    var s = try Store.parse(testing.allocator, doc);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expect(s.get("good") != null);
    try testing.expect(s.get("notobj") == null);
    try testing.expect(s.get("badid") == null);
    const w = s.get("wrongtypes").?;
    try testing.expect(w.cwd == null and w.pid == null and w.is_restorable == null and w.launch_command == null and w.started_at_ms == null);
    try testing.expectEqual(store.Lifecycle.unknown, w.agent_lifecycle);
    try testing.expectEqualStrings("mismatch", s.get("mismatch").?.session_id);
    try testing.expectEqualStrings("good", s.activeForSurface("S1").?.session_id);
    try testing.expect(s.activeForSurface("S2") == null);
    try testing.expect(s.diagnostics.items.len >= 10);
    try testing.expectEqual(@as(?i64, 1_700_000_000_000), s.get("good").?.updated_at_ms);
}

test "unit: agents: store whole-file garbage yields an empty store with a diagnostic" {
    const cases = [_][]const u8{ "not json", "[]", "\"x\"", "{\"sessions\":", "\xff\xfe" };
    for (cases) |c| {
        var s = try Store.parse(testing.allocator, c);
        defer s.deinit();
        try testing.expectEqual(@as(usize, 0), s.count());
        try testing.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    }
    var e = try Store.parse(testing.allocator, " \n");
    defer e.deinit();
    try testing.expectEqual(@as(usize, 0), e.diagnostics.items.len);
    var bad_sessions = try Store.parse(testing.allocator, "{\"version\":\"one\",\"sessions\":5}");
    defer bad_sessions.deinit();
    try testing.expectEqual(@as(usize, 2), bad_sessions.diagnostics.items.len);
}

test "unit: agents: store preserves unknown keys and newer versions" {
    const doc =
        \\{"version":3,"futureTop":{"a":[1,true,null]},
        \\ "sessions":{"k":{"sessionId":"k","futureField":"v","nested":{"x":1.5}}}}
    ;
    var s = try Store.parse(testing.allocator, doc);
    defer s.deinit();
    try testing.expectEqual(@as(i64, 3), s.version);
    var t = try roundTrip(&s);
    defer t.deinit();
    try testing.expectEqual(@as(i64, 3), t.version);
    try testing.expect(t.extra.get("futureTop") != null);
    const r = t.get("k").?;
    try testing.expectEqualStrings("v", r.extra.get("futureField").?.string);
    try testing.expectEqual(@as(f64, 1.5), r.extra.get("nested").?.object.get("x").?.float);
}

test "unit: agents: store prune by age and entry cap" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const day = std.time.ms_per_day;
    const now: i64 = 100 * day;
    try s.applyHook(.{ .session_id = "ancient", .now_ms = now - 40 * day, .surface_id = "S0" });
    for (0..5) |i| {
        var buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "r{d}", .{i});
        var sbuf: [16]u8 = undefined;
        const surf = try std.fmt.bufPrint(&sbuf, "S{d}", .{i + 1});
        try s.applyHook(.{ .session_id = id, .now_ms = now - @as(i64, @intCast(5 - i)) * 1000, .surface_id = surf });
    }
    try testing.expectEqual(@as(usize, 6), s.count());
    try testing.expectEqual(@as(usize, 1), s.prune(.{ .now_ms = now, .max_entries = null }));
    try testing.expect(s.get("ancient") == null);
    try testing.expect(s.activeForSurface("S0") == null);
    try testing.expectEqual(@as(usize, 2), s.prune(.{ .now_ms = now, .max_entries = 3 }));
    try testing.expect(s.get("r0") == null and s.get("r1") == null);
    try testing.expect(s.get("r4") != null);
    try testing.expectEqual(@as(usize, 3), s.active_by_surface.count());
    try testing.expectEqual(@as(usize, 0), s.prune(.{ .now_ms = now, .max_age_ms = null, .max_entries = null }));
    try testing.expectEqual(@as(usize, 3), s.prune(.{ .now_ms = now, .max_entries = 0 }));
    try testing.expectEqual(@as(usize, 0), s.active_by_surface.count());
}

test "unit: agents: store remove and removeSurface repair the active maps" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.applyHook(.{ .session_id = "a", .now_ms = 1, .surface_id = surf_a, .workspace_id = ws_1 });
    try s.applyHook(.{ .session_id = "b", .now_ms = 2, .surface_id = surf_b });
    try testing.expectEqual(@as(usize, 1), s.removeSurface(surf_a));
    try testing.expect(s.activeForWorkspace(ws_1) == null);
    try testing.expectEqual(@as(usize, 0), s.removeSurface(surf_a));
    try testing.expect(s.remove("b"));
    try testing.expect(!s.remove("b"));
    try testing.expectEqual(@as(usize, 0), s.active_by_surface.count());
}

test "unit: agents: store caps huge strings and arguments" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const huge_id = "ä" ** 200;
    var args: [300][]const u8 = undefined;
    for (&args) |*a| a.* = "--flag";
    try s.applyHook(.{ .session_id = huge_id, .now_ms = 1, .last_body = "x" ** 10_000, .launch_command = .{ .executable = "e", .arguments = &args } });
    try testing.expectEqual(@as(usize, 1), s.count());
    const r = s.sessions.values()[0];
    try testing.expect(r.session_id.len <= store.max_id_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(r.session_id));
    try testing.expectEqual(store.max_text_bytes, r.last_body.?.len);
    try testing.expectEqual(store.max_arguments, r.launch_command.?.arguments.len);
    var t = try roundTrip(&s);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.count());
}

test "unit: agents: store timestamp decoding" {
    try testing.expectEqual(@as(?i64, 1_700_000_000_000), store.decodeTimestampMs(.{ .integer = 1_700_000_000 }));
    try testing.expectEqual(@as(?i64, 1_700_000_000_500), store.decodeTimestampMs(.{ .float = 1_700_000_000.5 }));
    try testing.expectEqual(@as(?i64, 1_700_000_000_000), store.decodeTimestampMs(.{ .integer = 1_700_000_000_000 }));
    try testing.expect(store.decodeTimestampMs(.{ .integer = -1 }) == null);
    try testing.expect(store.decodeTimestampMs(.{ .string = "2026-01-01" }) == null);
    try testing.expect(store.decodeTimestampMs(.{ .float = std.math.inf(f64) }) == null);
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), store.decodeTimestampMs(.{ .float = 1e300 }));
}

test "unit: agents: store lifecycle parse is forward compatible" {
    try testing.expectEqual(store.Lifecycle.needsInput, store.Lifecycle.parse("needsInput"));
    try testing.expectEqual(store.Lifecycle.unknown, store.Lifecycle.parse("ended"));
    try testing.expectEqual(store.Lifecycle.unknown, store.Lifecycle.parse(""));
}
