//! Tests for lifecycle.zig (ADR-10.4 state machine).

const std = @import("std");
const testing = std.testing;
const lifecycle = @import("lifecycle.zig");
const Registry = lifecycle.Registry;
const State = lifecycle.State;
const Event = lifecycle.Event;

const surface = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1";
const workspace = "11111111-2222-4333-8444-555555555555";

fn ev(e: Event, now: i64) lifecycle.Input {
    return .{ .event = e, .now_ms = now, .session_id = "sess-1" };
}

fn stateOf(r: *const Registry) State {
    return r.get(surface).?.state;
}

test "unit: agents: lifecycle one prompt cycle goes idle, running, idle" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var start = ev(.session_start, 1000);
    start.workspace_id = workspace;
    start.kind = "claude";
    start.transcript_path = "C:/Users/dev/.claude/projects/p/sess-1.jsonl";
    start.pid = 4100;
    start.pid_start_time = 133_000_000_000_000_000;
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, start));
    const s = r.get(surface).?;
    try testing.expectEqual(State.idle, s.state);
    try testing.expectEqualStrings("sess-1", s.session_id.?);
    try testing.expectEqualStrings(workspace, s.workspace_id.?);
    try testing.expectEqualStrings("claude", s.kind.?);
    try testing.expectEqual(@as(?u32, 4100), s.pid);

    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, ev(.prompt_submit, 2000)));
    try testing.expectEqual(State.running, stateOf(&r));
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(surface, ev(.pre_tool_use, 2100)));
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(surface, ev(.post_tool_use, 2200)));
    try testing.expectEqual(State.running, stateOf(&r));
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, ev(.stop, 3000)));
    try testing.expectEqual(State.idle, stateOf(&r));
}

test "unit: agents: lifecycle duplicate events are no-ops without version bumps" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    _ = try r.apply(surface, ev(.stop, 3));
    const v = r.get(surface).?.version;
    const activity = r.get(surface).?.last_activity_ms;
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(surface, ev(.stop, 4)));
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(surface, ev(.stop, 5)));
    try testing.expectEqual(v, r.get(surface).?.version);
    try testing.expectEqual(activity, r.get(surface).?.last_activity_ms);
}

test "unit: agents: lifecycle versions are strictly monotonic across changes and sessions" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var last: u64 = 0;
    const seq = [_]Event{ .session_start, .prompt_submit, .notification, .pre_tool_use, .stop, .session_end };
    for (seq, 0..) |e, i| {
        try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, ev(e, @intCast(i))));
        const v = r.get(surface).?.version;
        try testing.expect(v > last);
        last = v;
    }
    // A replacement session on the same surface keeps counting upward.
    var next = ev(.session_start, 100);
    next.session_id = "sess-2";
    _ = try r.apply(surface, next);
    try testing.expect(r.get(surface).?.version > last);
    try testing.expectEqualStrings("sess-2", r.get(surface).?.session_id.?);
}

test "unit: agents: lifecycle needs-input sources and resume to running" {
    const sources = [_]Event{ .permission_request, .ask_user_question, .exit_plan_mode, .notification };
    for (sources) |src| {
        var r = Registry.init(testing.allocator);
        defer r.deinit();
        _ = try r.apply(surface, ev(.session_start, 1));
        _ = try r.apply(surface, ev(.prompt_submit, 2));
        _ = try r.apply(surface, ev(src, 3));
        try testing.expectEqual(State.needsInput, stateOf(&r));
        // pre-tool-use clears needs-input when work resumes.
        _ = try r.apply(surface, ev(.pre_tool_use, 4));
        try testing.expectEqual(State.running, stateOf(&r));
    }
}

test "unit: agents: lifecycle stop with background work pending" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    var bg = ev(.pre_tool_use, 3);
    bg.background_pending = true;
    _ = try r.apply(surface, bg);
    try testing.expect(r.get(surface).?.pending_background);
    _ = try r.apply(surface, ev(.stop, 4));
    try testing.expectEqual(State.backgroundWorkPending, stateOf(&r));
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, ev(.background_settled, 5)));
    try testing.expectEqual(State.idle, stateOf(&r));
    try testing.expect(!r.get(surface).?.pending_background);

    // An explicit stop flag overrides what was tracked.
    _ = try r.apply(surface, ev(.prompt_submit, 6));
    var stop = ev(.stop, 7);
    stop.background_pending = true;
    _ = try r.apply(surface, stop);
    try testing.expectEqual(State.backgroundWorkPending, stateOf(&r));
    _ = try r.apply(surface, ev(.prompt_submit, 8));
    var stop2 = ev(.stop, 9);
    stop2.background_pending = false;
    _ = try r.apply(surface, stop2);
    try testing.expectEqual(State.idle, stateOf(&r));
}

fn applyWire(r: *Registry, json: []const u8, now: i64) !lifecycle.Outcome {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return r.apply(surface, lifecycle.Input.fromHookParams(parsed.value.object, now).?);
}

test "unit: agents: lifecycle a stop that reports no background work clears the tracked flag" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"session-start\",\"seq\":1,\"session_id\":\"sess-1\"}", 1);
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"pre-tool-use\",\"seq\":2,\"session_id\":\"sess-1\",\"background_pending\":true}", 2);
    try testing.expect(r.get(surface).?.pending_background);
    // Stop without a verdict keeps what was tracked.
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"stop\",\"seq\":3,\"session_id\":\"sess-1\"}", 3);
    try testing.expectEqual(State.backgroundWorkPending, stateOf(&r));
    // The next turn's Stop finds the background work done.
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"prompt-submit\",\"seq\":4,\"session_id\":\"sess-1\"}", 4);
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"stop\",\"seq\":5,\"session_id\":\"sess-1\",\"background_pending\":false}", 5);
    try testing.expectEqual(State.idle, stateOf(&r));
    try testing.expect(!r.get(surface).?.pending_background);
    // Later turns go idle without a verdict too.
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"prompt-submit\",\"seq\":6,\"session_id\":\"sess-1\"}", 6);
    _ = try applyWire(&r, "{\"agent\":\"claude\",\"event\":\"stop\",\"seq\":7,\"session_id\":\"sess-1\"}", 7);
    try testing.expectEqual(State.idle, stateOf(&r));
}

test "unit: agents: lifecycle stop failure flag and recovery" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    var fail = ev(.stop, 3);
    fail.failure = true;
    _ = try r.apply(surface, fail);
    try testing.expectEqual(State.idle, stateOf(&r));
    try testing.expect(r.get(surface).?.last_stop_failed);
    _ = try r.apply(surface, ev(.prompt_submit, 4));
    try testing.expect(!r.get(surface).?.last_stop_failed);
}

test "unit: agents: lifecycle subagent events never touch the parent" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    const v = r.get(surface).?.version;
    try testing.expectEqual(lifecycle.Outcome.ignored_subagent, try r.apply(surface, ev(.subagent_stop, 3)));
    var nested = ev(.notification, 4);
    nested.is_subagent = true;
    try testing.expectEqual(lifecycle.Outcome.ignored_subagent, try r.apply(surface, nested));
    var nested_stop = ev(.stop, 5);
    nested_stop.is_subagent = true;
    _ = try r.apply(surface, nested_stop);
    try testing.expectEqual(State.running, stateOf(&r));
    try testing.expectEqual(v, r.get(surface).?.version);
}

test "unit: agents: lifecycle foreign session ids do not overwrite the live binding" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    var foreign = ev(.stop, 3);
    foreign.session_id = "nested-exec";
    try testing.expectEqual(lifecycle.Outcome.ignored_foreign_session, try r.apply(surface, foreign));
    try testing.expectEqualStrings("sess-1", r.get(surface).?.session_id.?);
    try testing.expectEqual(State.running, stateOf(&r));
    // A session-start for a new id (e.g. /clear) does replace it.
    var fresh = ev(.session_start, 4);
    fresh.session_id = "sess-3";
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, fresh));
    try testing.expectEqualStrings("sess-3", r.get(surface).?.session_id.?);
    try testing.expectEqual(State.idle, stateOf(&r));
    try testing.expect(r.get(surface).?.transcript_path == null);
}

test "unit: agents: lifecycle session-end retains the record and a resume revives it" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.session_end, 2));
    try testing.expectEqual(State.ended, stateOf(&r));
    try testing.expectEqual(@as(usize, 1), r.count());
    // Late needs-input or stop events do not resurrect an ended session.
    _ = try r.apply(surface, ev(.notification, 3));
    _ = try r.apply(surface, ev(.stop, 4));
    try testing.expectEqual(State.ended, stateOf(&r));
    // `--resume` of the same id: session-start then work.
    _ = try r.apply(surface, ev(.session_start, 5));
    try testing.expectEqual(State.idle, stateOf(&r));
    _ = try r.apply(surface, ev(.prompt_submit, 6));
    try testing.expectEqual(State.running, stateOf(&r));
    // After an end, a different session id is adopted by any event.
    _ = try r.apply(surface, ev(.session_end, 7));
    var other = ev(.prompt_submit, 8);
    other.session_id = "sess-9";
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, other));
    try testing.expectEqualStrings("sess-9", r.get(surface).?.session_id.?);
    try testing.expectEqual(State.running, stateOf(&r));
}

test "unit: agents: lifecycle repeated session-start keeps a live state" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(surface, ev(.session_start, 3)));
    try testing.expectEqual(State.running, stateOf(&r));
}

test "unit: agents: lifecycle events without a session cannot create one" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var anon: lifecycle.Input = .{ .event = .stop, .now_ms = 1 };
    try testing.expectEqual(lifecycle.Outcome.ignored_no_session, try r.apply(surface, anon));
    try testing.expect(r.get(surface) == null);
    // Hooks installed mid-session: the first event with an id binds.
    anon.session_id = "late";
    anon.event = .pre_tool_use;
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, anon));
    try testing.expectEqual(State.running, stateOf(&r));
    // A session-start without an id still creates an (unbound) entry.
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply("other-surface", .{ .event = .session_start, .now_ms = 2 }));
    try testing.expectEqual(State.idle, r.get("other-surface").?.state);
}

test "unit: agents: lifecycle exit watcher ends only the current process" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    var start = ev(.session_start, 1);
    start.pid = 100;
    start.pid_start_time = 5555;
    _ = try r.apply(surface, start);
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    // Resumed under a new pid.
    var resumed = ev(.prompt_submit, 3);
    resumed.pid = 200;
    resumed.pid_start_time = 7777;
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(surface, resumed));
    try testing.expectEqual(lifecycle.Outcome.ignored_stale_process, r.onProcessExit(surface, 100, 5555, 4));
    try testing.expectEqual(State.running, stateOf(&r));
    // Same pid reused by an unrelated process (different creation time).
    try testing.expectEqual(lifecycle.Outcome.ignored_stale_process, r.onProcessExit(surface, 200, 9999, 5));
    try testing.expectEqual(lifecycle.Outcome.changed, r.onProcessExit(surface, 200, 7777, 6));
    try testing.expectEqual(State.ended, stateOf(&r));
    try testing.expectEqual(lifecycle.Outcome.unchanged, r.onProcessExit(surface, 200, null, 7));
    try testing.expectEqual(lifecycle.Outcome.ignored_no_session, r.onProcessExit("nope", 1, null, 8));
}

test "unit: agents: lifecycle transcript backstop clears stuck running only" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 1));
    try testing.expectEqual(lifecycle.Outcome.unchanged, r.onTranscriptTurnComplete(surface, "sess-1", 2));
    _ = try r.apply(surface, ev(.prompt_submit, 3));
    try testing.expectEqual(lifecycle.Outcome.ignored_foreign_session, r.onTranscriptTurnComplete(surface, "other", 4));
    try testing.expectEqual(lifecycle.Outcome.changed, r.onTranscriptTurnComplete(surface, "sess-1", 5));
    try testing.expectEqual(State.idle, stateOf(&r));
    _ = try r.apply(surface, ev(.prompt_submit, 6));
    _ = try r.apply(surface, ev(.notification, 7));
    try testing.expectEqual(lifecycle.Outcome.unchanged, r.onTranscriptTurnComplete(surface, "sess-1", 8));
    try testing.expectEqual(State.needsInput, stateOf(&r));
}

test "unit: agents: lifecycle informational events and activity tracking" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply(surface, ev(.session_start, 10));
    _ = try r.apply(surface, ev(.prompt_submit, 20));
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(surface, ev(.informational, 30)));
    try testing.expectEqual(@as(i64, 20), r.get(surface).?.last_activity_ms);
    _ = try r.apply(surface, ev(.pre_tool_use, 40));
    try testing.expectEqual(@as(i64, 40), r.get(surface).?.last_activity_ms);
    // Clock skew: activity never moves backwards.
    _ = try r.apply(surface, ev(.stop, 5));
    try testing.expectEqual(@as(i64, 40), r.get(surface).?.last_activity_ms);
}

test "unit: agents: lifecycle remove and multiple surfaces" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    _ = try r.apply("s-a", ev(.session_start, 1));
    var b = ev(.prompt_submit, 2);
    b.session_id = "sess-b";
    _ = try r.apply("s-b", b);
    try testing.expectEqual(@as(usize, 2), r.count());
    try testing.expectEqual(State.idle, r.get("s-a").?.state);
    try testing.expectEqual(State.running, r.get("s-b").?.state);
    try testing.expect(r.remove("s-a"));
    try testing.expect(!r.remove("s-a"));
    try testing.expect(r.get("s-a") == null);
}

test "unit: agents: lifecycle caps huge and unicode ids" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    const huge = "ü" ** 300;
    var in = ev(.session_start, 1);
    in.session_id = huge;
    in.transcript_path = "C:/Users/Jöhn/日本語/t.jsonl";
    _ = try r.apply(huge, in);
    const s = r.get(lifecycle.truncateUtf8(huge, lifecycle.max_id_bytes)).?;
    try testing.expect(s.session_id.?.len <= lifecycle.max_id_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(s.session_id.?));
    try testing.expectEqualStrings("C:/Users/Jöhn/日本語/t.jsonl", s.transcript_path.?);
    // The uncapped ids still reach the same entry and the same session.
    try testing.expectEqual(lifecycle.Outcome.changed, try r.apply(huge, .{ .event = .prompt_submit, .now_ms = 2, .session_id = huge }));
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectEqual(State.running, r.get(huge).?.state);
    try testing.expectEqual(lifecycle.Outcome.unchanged, try r.apply(huge, .{ .event = .pre_tool_use, .now_ms = 3, .session_id = huge }));
    // Found (no pid recorded, so stale) rather than ignored_no_session.
    try testing.expectEqual(lifecycle.Outcome.ignored_stale_process, r.onProcessExit(huge, 1, null, 4));
    try testing.expect(r.remove(huge));
    try testing.expectEqual(@as(usize, 0), r.count());
}

fn applySequence(gpa: std.mem.Allocator) !void {
    var r = Registry.init(gpa);
    defer r.deinit();
    var start = ev(.session_start, 1);
    start.workspace_id = workspace;
    start.kind = "codex";
    start.transcript_path = "/t/sess-1.jsonl";
    _ = try r.apply(surface, start);
    _ = try r.apply(surface, ev(.prompt_submit, 2));
    var next = ev(.session_start, 3);
    next.session_id = "sess-2";
    _ = try r.apply(surface, next);
    _ = try r.apply("other-surface", ev(.prompt_submit, 4));
}

test "unit: agents: lifecycle apply leaks nothing when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, applySequence, .{});
}

test "unit: agents: lifecycle wire event mapping" {
    try testing.expectEqual(Event.session_start, Event.fromWire("active", null).?);
    try testing.expectEqual(Event.stop, Event.fromWire("idle", null).?);
    try testing.expectEqual(Event.notification, Event.fromWire("notify", null).?);
    try testing.expectEqual(Event.permission_request, Event.fromWire("feed", null).?);
    try testing.expectEqual(Event.post_tool_use, Event.fromWire("push-notification", null).?);
    try testing.expectEqual(Event.ask_user_question, Event.fromWire("pre-tool-use", "question").?);
    try testing.expectEqual(Event.exit_plan_mode, Event.fromWire("pre-tool-use", "plan").?);
    try testing.expectEqual(Event.pre_tool_use, Event.fromWire("pre-tool-use", null).?);
    try testing.expectEqual(Event.notification, Event.fromWire("notification", "plan").?);
    try testing.expectEqual(Event.informational, Event.fromWire("pre-compact", null).?);
    try testing.expectEqual(Event.subagent_stop, Event.fromWire("subagent-stop", null).?);
    try testing.expect(Event.fromWire("", null) == null);
    try testing.expect(Event.fromWire("SessionStart", null) == null);
}

test "unit: agents: lifecycle input from wmux.agent.hook params" {
    const json =
        \\{"agent":"claude","event":"stop","seq":3,"session_id":"sess-1","surface_id":"S","workspace_id":"W",
        \\ "cwd":"C:/w","pid":4242,"transcript_path":"C:/t.jsonl","failure":true,"background_pending":true}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const in = lifecycle.Input.fromHookParams(parsed.value.object, 99).?;
    try testing.expectEqual(Event.stop, in.event);
    try testing.expectEqualStrings("sess-1", in.session_id.?);
    try testing.expectEqualStrings("W", in.workspace_id.?);
    try testing.expectEqualStrings("claude", in.kind.?);
    try testing.expectEqual(@as(?u32, 4242), in.pid);
    try testing.expect(in.failure);
    try testing.expectEqual(@as(?bool, true), in.background_pending);
    try testing.expectEqual(@as(i64, 99), in.now_ms);

    const bad = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"event":"bogus","pid":-1}
    , .{});
    defer bad.deinit();
    try testing.expect(lifecycle.Input.fromHookParams(bad.value.object, 0) == null);

    const odd = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"event":"pre-tool-use","input_kind":"question","pid":99999999999,"session_id":7,"is_subagent":"yes"}
    , .{});
    defer odd.deinit();
    const o = lifecycle.Input.fromHookParams(odd.value.object, 0).?;
    try testing.expectEqual(Event.ask_user_question, o.event);
    try testing.expect(o.pid == null);
    try testing.expect(o.session_id == null);
    try testing.expect(!o.is_subagent);
}

test "unit: agents: lifecycle store values and hook topics" {
    try testing.expectEqualStrings("needsInput", State.needsInput.storeValue());
    try testing.expectEqualStrings("backgroundWorkPending", State.backgroundWorkPending.storeValue());
    try testing.expectEqualStrings("idle", State.ended.storeValue());
    try testing.expectEqualStrings("unknown", State.unknown.storeValue());
    const t = try lifecycle.hookTopic(testing.allocator, "UserPromptSubmit");
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("agent.hook.UserPromptSubmit", t);
}
