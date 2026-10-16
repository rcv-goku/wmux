//! Unit tests of model.zig.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const Uuid = proto.uuid.Uuid;
const testing = std.testing;
const gpa = testing.allocator;

const t_id = Uuid.fromRandomBytes(@splat(1));
const ws_text = "0F0E0D0C-0B0A-4908-8706-050403020100";

/// Parses `json` and builds an item from it.
fn itemFrom(json: []const u8, o: model.FromEventOptions) !*model.Item {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    return model.fromEvent(gpa, parsed.value, o);
}

fn opts() model.FromEventOptions {
    return .{ .id = t_id, .now_ms = 1_000 };
}

test "unit: feed: wire names round-trip for kinds and statuses" {
    inline for (std.meta.fields(model.Kind)) |f| {
        const k: model.Kind = @enumFromInt(f.value);
        try testing.expectEqual(k, model.Kind.parse(k.wire()).?);
    }
    inline for (std.meta.fields(model.Status)) |f| {
        const s: model.Status = @enumFromInt(f.value);
        try testing.expectEqual(s, model.Status.parse(s.wire()).?);
    }
    try testing.expectEqualStrings("permissionRequest", model.Kind.permission_request.wire());
    try testing.expectEqualStrings("exitPlan", model.Kind.exit_plan.wire());
    try testing.expectEqualStrings("question", model.Kind.question.wire());
    try testing.expect(model.Kind.parse("PermissionRequest") == null);
    try testing.expect(model.Kind.parse("") == null);
    try testing.expect(model.Status.parse("timed_out") == null);
}

test "unit: feed: permission and exit plan modes parse cmux names" {
    try testing.expectEqual(model.PermissionMode.all, model.PermissionMode.parse("all").?);
    try testing.expect(model.PermissionMode.parse("allow") == null);
    try testing.expect(model.PermissionMode.parse("Once") == null);
    try testing.expectEqualStrings("all tools", model.PermissionMode.all.badge());
    try testing.expectEqualStrings("denied", model.PermissionMode.deny.badge());
    try testing.expectEqual(model.ExitPlanMode.bypass_permissions, model.ExitPlanMode.parse("bypassPermissions").?);
    try testing.expectEqual(model.ExitPlanMode.auto_accept, model.ExitPlanMode.parse("autoAccept").?);
    try testing.expect(model.ExitPlanMode.parse("auto") == null);
    try testing.expectEqualStrings("auto", model.ExitPlanMode.auto_accept.badge());
    try testing.expectEqualStrings("feed.permission.reply requires mode \u{2208} once|always|all|bypass|deny", model.PermissionMode.invalid_message);
}

test "unit: feed: decision mode wire names round-trip" {
    inline for (std.meta.fields(model.PermissionMode)) |f| {
        const m: model.PermissionMode = @enumFromInt(f.value);
        try testing.expectEqual(m, model.PermissionMode.parse(m.wire()).?);
    }
    inline for (std.meta.fields(model.ExitPlanMode)) |f| {
        const m: model.ExitPlanMode = @enumFromInt(f.value);
        try testing.expectEqual(m, model.ExitPlanMode.parse(m.wire()).?);
    }
}

test "unit: feed: classify maps hook events and tools to kinds" {
    const C = struct { ev: []const u8, tool: ?[]const u8, kind: model.Kind };
    const cases = [_]C{
        .{ .ev = "PermissionRequest", .tool = "Bash", .kind = .permission_request },
        .{ .ev = "PermissionRequest", .tool = "ExitPlanMode", .kind = .exit_plan },
        .{ .ev = "PermissionRequest", .tool = "AskUserQuestion", .kind = .question },
        .{ .ev = "PermissionRequest", .tool = null, .kind = .permission_request },
        .{ .ev = "beforeShellExecution", .tool = null, .kind = .permission_request },
        .{ .ev = "pre_approval_request", .tool = null, .kind = .permission_request },
        .{ .ev = "PreToolUse", .tool = "TodoWrite", .kind = .todos },
        .{ .ev = "PreToolUse", .tool = "Edit", .kind = .tool_use },
        .{ .ev = "preToolUse", .tool = "x", .kind = .tool_use },
        .{ .ev = "PostToolUse", .tool = "Edit", .kind = .tool_result },
        .{ .ev = "tool_execution_end", .tool = null, .kind = .tool_result },
        .{ .ev = "Stop", .tool = null, .kind = .stop },
        .{ .ev = "SubagentStop", .tool = null, .kind = .stop },
        .{ .ev = "Notification", .tool = null, .kind = .notification },
        .{ .ev = "UserPromptSubmit", .tool = null, .kind = .prompt },
        .{ .ev = "SessionStart", .tool = null, .kind = .session_start },
        .{ .ev = "SessionEnd", .tool = null, .kind = .session_end },
        .{ .ev = "AssistantMessage", .tool = null, .kind = .message },
        .{ .ev = "", .tool = null, .kind = .message },
        .{ .ev = "permissionrequest", .tool = "Bash", .kind = .permission_request },
    };
    for (cases) |c| try testing.expectEqual(c.kind, model.classify(c.ev, c.tool));
}

test "unit: feed: claude permission request with suggestions offers every mode" {
    const it = try itemFrom(
        \\{"hook_event_name":"PermissionRequest","_source":"Claude","session_id":"s1",
        \\ "request_id":"req-1","tool_name":"Bash","tool_input":{"command":"rm -rf build\nls"},
        \\ "permission_suggestions":[{"type":"addRules"}],"workspace_id":"
    ++ ws_text ++
        \\","surface_id":"not-a-uuid","pid":4242,"cwd":"C:\\src"}
    , opts());
    defer it.destroy();
    try testing.expectEqual(model.Kind.permission_request, it.kind);
    try testing.expectEqual(model.Status.pending, it.status);
    try testing.expectEqualStrings("claude", it.source);
    try testing.expectEqualStrings("req-1", it.request_id.?);
    try testing.expectEqualStrings("s1", it.session_id.?);
    try testing.expectEqualStrings("Bash", it.title);
    try testing.expectEqualStrings("rm -rf build\nls", it.detail);
    try testing.expect(it.workspace_id.?.eql(try Uuid.parse(ws_text)));
    try testing.expect(it.surface_id == null);
    try testing.expectEqual(@as(?u32, 4242), it.pid);
    try testing.expectEqualStrings("C:\\src", it.cwd.?);
    inline for (.{ .once, .always, .all, .bypass, .deny }) |m| try testing.expect(it.permission_modes.has(m));
    try testing.expectEqualStrings("{\"command\":\"rm -rf build\\nls\"}", it.tool_input_json.?);
    const b = (try model.bannerText(gpa, it)).?;
    defer gpa.free(b.title);
    defer gpa.free(b.body);
    try testing.expectEqualStrings("Claude permission", b.title);
    try testing.expectEqualStrings("Bash needs approval", b.body);
}

test "unit: feed: permission without suggestions or tool keeps once and deny only" {
    const it = try itemFrom("{\"hook_event_name\":\"beforeShellExecution\"}", .{ .id = t_id, .now_ms = 0, .source = "cursor", .request_id = "top" });
    defer it.destroy();
    try testing.expectEqualStrings("cursor", it.source);
    try testing.expectEqualStrings("top", it.request_id.?);
    try testing.expect(it.permission_modes.has(.once) and it.permission_modes.has(.deny));
    try testing.expect(!it.permission_modes.has(.always) and !it.permission_modes.has(.all) and !it.permission_modes.has(.bypass));
    const b = (try model.bannerText(gpa, it)).?;
    defer gpa.free(b.title);
    defer gpa.free(b.body);
    try testing.expectEqualStrings("Cursor permission", b.title);
    try testing.expectEqualStrings("Decision needed", b.body);
}

test "unit: feed: top-level request id wins over the event's own" {
    const it = try itemFrom("{\"hook_event_name\":\"PermissionRequest\",\"request_id\":\"inner\"}", .{ .id = t_id, .now_ms = 0, .request_id = "outer" });
    defer it.destroy();
    try testing.expectEqualStrings("outer", it.request_id.?);
}

test "unit: feed: exit plan item carries plan text, file and allowed prompts" {
    const it = try itemFrom(
        \\{"hook_event_name":"PermissionRequest","source":"claude","tool_name":"ExitPlanMode",
        \\ "tool_input":{"plan":"\n  # Refactor parser  \nstep 2","planFilePath":"/tmp/p.md",
        \\ "allowedPrompts":[{"tool":"Bash","prompt":"run tests"},"plain",7]}}
    , opts());
    defer it.destroy();
    try testing.expectEqual(model.Kind.exit_plan, it.kind);
    try testing.expectEqualStrings("Claude plan ready", it.title);
    try testing.expectEqualStrings("# Refactor parser", it.detail);
    try testing.expectEqualStrings("/tmp/p.md", it.plan.?.file_path.?);
    try testing.expectEqual(@as(usize, 2), it.plan.?.allowed_prompts.len);
    try testing.expectEqualStrings("Bash: run tests", it.plan.?.allowed_prompts[0]);
    try testing.expect(it.exit_plan_modes.has(.ultraplan) and it.exit_plan_modes.has(.auto_accept));
}

test "unit: feed: non-claude plan offers manual and deny only" {
    const it = try itemFrom("{\"hook_event_name\":\"PreToolUse\",\"source\":\"gemini\",\"tool_name\":\"ExitPlanMode\"}", opts());
    defer it.destroy();
    try testing.expectEqualStrings("", it.plan.?.text);
    try testing.expect(it.exit_plan_modes.has(.manual) and it.exit_plan_modes.has(.deny));
    try testing.expect(!it.exit_plan_modes.has(.ultraplan) and !it.exit_plan_modes.has(.bypass_permissions));
}

test "unit: feed: question item parses multi-select questions and options" {
    const it = try itemFrom(
        \\{"hook_event_name":"PermissionRequest","source":"claude","tool_name":"AskUserQuestion",
        \\ "tool_input":{"questions":[
        \\   {"question":"Which DB? \u00e9\u4e2d","header":"DB","multiSelect":false,
        \\    "options":[{"label":"Postgres","description":"relational"},{"label":"SQLite"},{"nolabel":1}]},
        \\   {"question":"Features?","multiSelect":true,"options":["a","b"]},
        \\   {"question":"Free text?"},
        \\   "garbage"]}}
    , opts());
    defer it.destroy();
    try testing.expectEqual(model.Kind.question, it.kind);
    try testing.expectEqual(@as(usize, 3), it.questions.len);
    try testing.expectEqualStrings("Which DB? \u{e9}\u{4e2d}", it.questions[0].question);
    try testing.expectEqualStrings("DB", it.questions[0].header);
    try testing.expectEqual(@as(usize, 2), it.questions[0].options.len);
    try testing.expectEqualStrings("relational", it.questions[0].options[0].description);
    try testing.expect(it.questions[1].multi_select);
    try testing.expectEqualStrings("b", it.questions[1].options[1].label);
    try testing.expectEqual(@as(usize, 0), it.questions[2].options.len);
    try testing.expectEqualStrings("Which DB? \u{e9}\u{4e2d}", it.detail);
    try testing.expectEqualStrings("Claude question", it.title);
}

test "unit: feed: question without input has no questions" {
    const it = try itemFrom("{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":[1,2]}", opts());
    defer it.destroy();
    try testing.expectEqual(@as(usize, 0), it.questions.len);
    try testing.expectEqualStrings("", it.detail);
    try testing.expectEqualStrings("[1,2]", it.tool_input_json.?);
}

test "unit: feed: todo snapshot summarizes open, in progress and done" {
    const it = try itemFrom(
        \\{"hook_event_name":"PreToolUse","tool_name":"TodoWrite","tool_input":{"todos":[
        \\ {"content":"a","status":"pending","activeForm":"Doing a"},
        \\ {"content":"b","status":"completed"},
        \\ {"content":"c","status":"weird"},
        \\ {"status":"pending"}]}}
    , opts());
    defer it.destroy();
    try testing.expectEqual(model.Kind.todos, it.kind);
    try testing.expectEqual(model.Status.info, it.status);
    try testing.expectEqual(@as(usize, 3), it.todos.len);
    try testing.expectEqualStrings("Doing a", it.todos[0].active_form);
    try testing.expectEqualStrings("2 open, 1 done", it.detail);
    try testing.expectEqualStrings("Tasks", it.title);
}

test "unit: feed: todo summary formatting covers all parts and empty" {
    var buf: [64]u8 = undefined;
    const S = model.TodoSummary;
    try testing.expectEqualStrings("0 open", try std.fmt.bufPrint(&buf, "{f}", .{S{}}));
    try testing.expectEqualStrings("1 open, 2 in progress, 3 done", try std.fmt.bufPrint(&buf, "{f}", .{S{ .open = 1, .in_progress = 2, .done = 3 }}));
    try testing.expectEqualStrings("4 done", try std.fmt.bufPrint(&buf, "{f}", .{S{ .done = 4 }}));
    const todos = [_]model.Todo{ .{ .content = "x", .status = .in_progress }, .{ .content = "y" } };
    try testing.expectEqual(S{ .open = 1, .in_progress = 1 }, S.of(&todos));
}

test "unit: feed: activity rows (stop, prompt, notification, tool result, sessions)" {
    {
        const it = try itemFrom("{\"hook_event_name\":\"Stop\",\"source\":\"claude\",\"last_assistant_message\":\"All done.\\nDetails\"}", opts());
        defer it.destroy();
        try testing.expectEqual(model.Kind.stop, it.kind);
        try testing.expectEqual(model.Status.info, it.status);
        try testing.expectEqualStrings("Claude finished \u{2014} reply to continue", it.title);
        try testing.expectEqualStrings("All done.", it.detail);
        try testing.expect((try model.bannerText(gpa, it)) == null);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"fix the tests\\nplease\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("You: fix the tests", it.detail);
        try testing.expectEqualStrings("fix the tests\nplease", it.text.?);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"UserPromptSubmit\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("You:", it.detail);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"Notification\",\"source\":\"codex\",\"message\":\"Waiting\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("Codex", it.title);
        try testing.expectEqualStrings("Waiting", it.detail);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_response\":{\"is_error\":true}}", opts());
        defer it.destroy();
        try testing.expect(it.tool_error.?);
        try testing.expectEqualStrings("error", it.detail);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_response\":{\"content\":\"x\"}}", opts());
        defer it.destroy();
        try testing.expect(!it.tool_error.?);
        try testing.expectEqualStrings("ok", it.detail);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"SessionEnd\",\"reason\":\"logout\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("Session ended", it.title);
        try testing.expectEqualStrings("logout", it.detail);
        try testing.expectEqualStrings("unknown", it.source);
    }
}

test "unit: feed: malformed events are rejected" {
    try testing.expectError(error.InvalidEvent, itemFrom("[1]", opts()));
    try testing.expectError(error.InvalidEvent, itemFrom("\"x\"", opts()));
    try testing.expectError(error.MissingHookEventName, itemFrom("{}", opts()));
    try testing.expectError(error.MissingHookEventName, itemFrom("{\"hook_event_name\":\"\"}", opts()));
    try testing.expectError(error.MissingHookEventName, itemFrom("{\"hook_event_name\":5}", opts()));
    // --event fills a missing name.
    const it = try itemFrom("{\"tool_name\":7,\"pid\":-3,\"session_id\":null}", .{ .id = t_id, .now_ms = 0, .event_name = "Stop" });
    defer it.destroy();
    try testing.expectEqual(model.Kind.stop, it.kind);
    try testing.expect(it.tool_name == null and it.pid == null and it.session_id == null);
}

test "unit: feed: huge text fields are capped on code-point boundaries" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"hook_event_name\":\"Notification\",\"title\":\"");
    for (0..1000) |_| try json.appendSlice(gpa, "\u{1F600}");
    try json.appendSlice(gpa, "\",\"message\":\"");
    for (0..40_000) |_| try json.appendSlice(gpa, "\u{e9}");
    try json.appendSlice(gpa, "\"}");
    const it = try itemFrom(json.items, opts());
    defer it.destroy();
    try testing.expect(it.title.len <= model.caps.title);
    try testing.expect(std.unicode.utf8ValidateSlice(it.title));
    try testing.expect(std.mem.endsWith(u8, it.title, "\u{2026}"));
    try testing.expect(it.text.?.len <= model.caps.text);
    try testing.expect(std.unicode.utf8ValidateSlice(it.text.?));
    try testing.expect(it.detail.len <= model.caps.detail);
}

test "unit: feed: long non-ASCII agent names are capped on code-point boundaries" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"hook_event_name\":\"Stop\",\"_source\":\"AGENT");
    for (0..40) |_| try json.appendSlice(gpa, "\u{20AC}");
    try json.appendSlice(gpa, "\"}");
    const it = try itemFrom(json.items, opts());
    defer it.destroy();
    try testing.expect(it.source.len <= 64);
    try testing.expect(std.unicode.utf8ValidateSlice(it.source));
    try testing.expect(std.mem.startsWith(u8, it.source, "agent\u{20AC}"));
    try testing.expect(std.mem.indexOf(u8, it.title, " finished \u{2014} reply to continue") != null);
}

test "unit: feed: oversized tool input is dropped, not cut" {
    const head = "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Write\",\"tool_input\":";
    const pre = "{\"file_path\":\"a.txt\",\"content\":\"";
    const post = "\"}";
    // Serialized input exactly at the cap is kept; one byte more is dropped.
    for ([_]usize{ 0, 1 }) |extra| {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(gpa);
        try json.appendSlice(gpa, head ++ pre);
        try json.appendNTimes(gpa, 'x', model.caps.tool_input - pre.len - post.len + extra);
        try json.appendSlice(gpa, post ++ "}");
        const it = try itemFrom(json.items, opts());
        defer it.destroy();
        try testing.expectEqual(model.Kind.permission_request, it.kind);
        if (extra == 0) {
            try testing.expectEqual(model.caps.tool_input, it.tool_input_json.?.len);
        } else {
            try testing.expect(it.tool_input_json == null);
        }
        try testing.expectEqualStrings("a.txt", it.detail);
    }
}

test "unit: feed: resolve validates kind, supported mode and pending state" {
    const it = try itemFrom("{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}", opts());
    defer it.destroy();
    try testing.expectError(error.KindMismatch, it.resolve(.{ .exit_plan = .{ .mode = .manual } }, 5));
    try testing.expectError(error.UnsupportedMode, it.resolve(.{ .permission = .bypass }, 5));
    try it.resolve(.{ .permission = .deny }, 5);
    try testing.expectEqual(model.Status.resolved, it.status);
    try testing.expectEqual(@as(?i64, 5), it.resolved_at_ms);
    try testing.expectEqualStrings("denied", it.resolution.?.badge());
    try testing.expectError(error.NotPending, it.resolve(.{ .permission = .once }, 6));
    it.close(.expired, 7);
    try testing.expectEqual(model.Status.resolved, it.status);
}

test "unit: feed: stop card accepts one reply and stays informational" {
    const it = try itemFrom("{\"hook_event_name\":\"Stop\"}", opts());
    defer it.destroy();
    try it.resolve(.{ .reply = "continue with tests" }, 9);
    try testing.expectEqual(model.Status.info, it.status);
    try testing.expectEqualStrings("continue with tests", it.resolution.?.reply);
    try testing.expectError(error.NotPending, it.resolve(.{ .reply = "again" }, 10));
}

test "unit: feed: close times out pending items only once" {
    const it = try itemFrom("{\"hook_event_name\":\"PermissionRequest\"}", opts());
    defer it.destroy();
    it.close(.timed_out, 50);
    try testing.expectEqual(model.Status.timed_out, it.status);
    it.close(.expired, 60);
    try testing.expectEqual(model.Status.timed_out, it.status);
    try testing.expectEqual(@as(i64, 50), it.updated_at_ms);
}

test "unit: feed: resolution badges and equality" {
    const sels = [_][]const u8{ "a", "b" };
    const sels2 = [_][]const u8{ "a", "c" };
    const q: model.Resolution = .{ .question = .{ .selections = &sels } };
    try testing.expectEqualStrings("Submitted", q.badge());
    try testing.expect(q.eql(.{ .question = .{ .selections = &sels } }));
    try testing.expect(!q.eql(.{ .question = .{ .selections = &sels2 } }));
    try testing.expect(!q.eql(.{ .question = .{ .selections = sels[0..1] } }));
    try testing.expect(!q.eql(.{ .permission = .once }));
    const refine: model.Resolution = .{ .exit_plan = .{ .mode = .deny, .feedback = "split step 2" } };
    try testing.expectEqualStrings("refined", refine.badge());
    try testing.expectEqualStrings("denied", (model.Resolution{ .exit_plan = .{ .mode = .deny } }).badge());
    try testing.expect(!refine.eql(.{ .exit_plan = .{ .mode = .deny } }));
    try testing.expectEqualStrings("manual", (model.Resolution{ .exit_plan = .{ .mode = .manual } }).badge());
}

test "unit: feed: long free-text answers survive resolution intact" {
    const it = try itemFrom("{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Why?\"}}", opts());
    defer it.destroy();
    const long = try gpa.alloc(u8, 5000);
    defer gpa.free(long);
    @memset(long, 'x');
    const sels = [_][]const u8{long};
    try it.resolve(.{ .question = .{ .selections = &sels } }, 1);
    try testing.expectEqual(@as(usize, 5000), it.resolution.?.question.selections[0].len);
}

test "unit: feed: clone is a deep copy" {
    const it = try itemFrom(
        \\{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","session_id":"s",
        \\ "tool_input":{"questions":[{"question":"Q","options":[{"label":"L"}]}]}}
    , opts());
    const sels = [_][]const u8{"L"};
    try it.resolve(.{ .question = .{ .selections = &sels } }, 3);
    const c = try it.clone(gpa);
    it.destroy();
    defer c.destroy();
    try testing.expectEqualStrings("Q", c.questions[0].question);
    try testing.expectEqualStrings("L", c.questions[0].options[0].label);
    try testing.expectEqualStrings("L", c.resolution.?.question.selections[0]);
    try testing.expectEqualStrings("s", c.session_id.?);
}

test "unit: feed: parseReply validates each reply method" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const P = struct {
        fn v(al: std.mem.Allocator, s: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, s, .{});
        }
    };
    const ok = try model.parseReply(a, .permission, try P.v(a, "{\"request_id\":\"r\",\"mode\":\"bypass\"}"));
    try testing.expectEqualStrings("r", ok.request_id);
    try testing.expectEqual(model.PermissionMode.bypass, ok.resolution.permission);
    try testing.expectError(error.InvalidPermissionMode, model.parseReply(a, .permission, try P.v(a, "{\"request_id\":\"r\",\"mode\":\"yes\"}")));
    try testing.expectError(error.InvalidPermissionMode, model.parseReply(a, .permission, try P.v(a, "{\"request_id\":\"r\"}")));
    try testing.expectError(error.MissingRequestId, model.parseReply(a, .permission, try P.v(a, "{\"mode\":\"once\"}")));
    try testing.expectError(error.MissingRequestId, model.parseReply(a, .permission, try P.v(a, "{\"request_id\":\"\",\"mode\":\"once\"}")));
    try testing.expectError(error.MissingRequestId, model.parseReply(a, .permission, try P.v(a, "[]")));
    try testing.expectEqualStrings(model.PermissionMode.invalid_message, model.replyErrorMessage(error.InvalidPermissionMode));

    const plan = try model.parseReply(a, .exit_plan, try P.v(a, "{\"request_id\":\"r\",\"mode\":\"deny\",\"feedback\":\"more tests\"}"));
    try testing.expectEqualStrings("more tests", plan.resolution.exit_plan.feedback.?);
    const plan2 = try model.parseReply(a, .exit_plan, try P.v(a, "{\"request_id\":\"r\",\"mode\":\"autoAccept\",\"feedback\":\"\"}"));
    try testing.expect(plan2.resolution.exit_plan.feedback == null);
    try testing.expectError(error.InvalidExitPlanMode, model.parseReply(a, .exit_plan, try P.v(a, "{\"request_id\":\"r\",\"mode\":\"auto\"}")));

    const q = try model.parseReply(a, .question, try P.v(a, "{\"request_id\":\"r\",\"selections\":[\"Option 2\",\"\u{fc}\"]}"));
    try testing.expectEqual(@as(usize, 2), q.resolution.question.selections.len);
    const q0 = try model.parseReply(a, .question, try P.v(a, "{\"request_id\":\"r\",\"selections\":[]}"));
    try testing.expectEqual(@as(usize, 0), q0.resolution.question.selections.len);
    try testing.expectError(error.InvalidSelections, model.parseReply(a, .question, try P.v(a, "{\"request_id\":\"r\",\"selections\":[1]}")));
    try testing.expectError(error.InvalidSelections, model.parseReply(a, .question, try P.v(a, "{\"request_id\":\"r\",\"selections\":\"a\"}")));
}

test "unit: feed: parseReply frees its selections on error with a non-arena allocator" {
    const bad = try std.json.parseFromSlice(std.json.Value, gpa, "{\"request_id\":\"r\",\"selections\":[\"a\",1]}", .{});
    defer bad.deinit();
    try testing.expectError(error.InvalidSelections, model.parseReply(gpa, .question, bad.value));
    const good = try std.json.parseFromSlice(std.json.Value, gpa, "{\"request_id\":\"r\",\"selections\":[\"a\",\"b\"]}", .{});
    defer good.deinit();
    const r = try model.parseReply(gpa, .question, good.value);
    defer gpa.free(r.resolution.question.selections);
    try testing.expectEqualStrings("b", r.resolution.question.selections[1]);
}

test "unit: feed: bannerText survives allocation failure at every point" {
    inline for (.{
        "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}",
        "{\"hook_event_name\":\"PermissionRequest\"}",
        "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"ExitPlanMode\"}",
        "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\"}",
    }) |json| {
        const it = try itemFrom(json, opts());
        defer it.destroy();
        var i: usize = 0;
        while (true) : (i += 1) {
            var fa = testing.FailingAllocator.init(gpa, .{ .fail_index = i });
            const b = (model.bannerText(fa.allocator(), it) catch |e| {
                try testing.expectEqual(error.OutOfMemory, e);
                continue;
            }).?;
            fa.allocator().free(b.title);
            fa.allocator().free(b.body);
            break;
        }
    }
}

test "unit: feed: source display names and telemetry-only sources" {
    try testing.expectEqualStrings("Claude", model.sourceDisplayName("claude"));
    try testing.expectEqualStrings("OpenCode", model.sourceDisplayName("opencode"));
    try testing.expectEqualStrings("Rovo Dev", model.sourceDisplayName("rovo"));
    try testing.expectEqualStrings("mystery", model.sourceDisplayName("mystery"));
    try testing.expectEqualStrings("Agent", model.sourceDisplayName(""));
    try testing.expect(model.isTelemetryOnlySource("codex"));
    try testing.expect(model.isTelemetryOnlySource("Codex"));
    try testing.expect(!model.isTelemetryOnlySource("claude"));
}

test "unit: feed: agent name prefers the bridge stamp over a native source key" {
    {
        // Claude's SessionStart input has its own `source` (startup|resume|clear|compact).
        const it = try itemFrom("{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"_source\":\"Claude\",\"session_id\":\"s\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("claude", it.source);
        try testing.expectEqualStrings("startup", it.detail);
    }
    {
        const it = try itemFrom("{\"hook_event_name\":\"SessionStart\",\"source\":\"resume\"}", .{ .id = t_id, .now_ms = 0, .source = "claude" });
        defer it.destroy();
        try testing.expectEqualStrings("claude", it.source);
        try testing.expectEqualStrings("resume", it.detail);
    }
    {
        // cmux-shaped frame: `source` names the agent and nothing is stamped.
        const it = try itemFrom("{\"hook_event_name\":\"SessionStart\",\"source\":\"opencode\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("opencode", it.source);
        try testing.expectEqualStrings("", it.detail);
    }
    {
        // A stamp that repeats `source` is not a start reason.
        const it = try itemFrom("{\"hook_event_name\":\"SessionStart\",\"source\":\"claude\",\"_source\":\"claude\"}", opts());
        defer it.destroy();
        try testing.expectEqualStrings("", it.detail);
    }
}

test "unit: feed: codex permission hooks are telemetry unless the push blocks" {
    const json = "{\"hook_event_name\":\"PermissionRequest\",\"source\":\"codex\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}";
    {
        const it = try itemFrom(json, opts());
        defer it.destroy();
        try testing.expectEqual(model.Kind.tool_use, it.kind);
        try testing.expectEqual(model.Status.info, it.status);
        try testing.expectEqualStrings("Bash", it.title);
        try testing.expectEqualStrings("ls -la", it.detail);
        try testing.expectEqualStrings("PermissionRequest", it.hook_event_name);
        try testing.expect((try model.bannerText(gpa, it)) == null);
        try testing.expectError(error.NotPending, it.resolve(.{ .permission = .once }, 1));
    }
    {
        // codex-teams app-server bridge: a real decision.
        var o = opts();
        o.blocking = true;
        const it = try itemFrom(json, o);
        defer it.destroy();
        try testing.expectEqual(model.Kind.permission_request, it.kind);
        try testing.expectEqual(model.Status.pending, it.status);
    }
    {
        // Nothing waits for a non-blocking push, whatever the agent.
        var o = opts();
        o.blocking = false;
        const it = try itemFrom("{\"hook_event_name\":\"PermissionRequest\",\"source\":\"claude\",\"tool_name\":\"AskUserQuestion\"}", o);
        defer it.destroy();
        try testing.expectEqual(model.Kind.tool_use, it.kind);
        try testing.expect(it.questions.len == 0);
    }
}

test "unit: feed: a waiting pre-tool hook becomes an answerable permission request" {
    // Gemini's Feed trigger is its pre-tool hook (BeforeTool).
    const json = "{\"hook_event_name\":\"BeforeTool\",\"source\":\"gemini\",\"tool_name\":\"run_shell_command\",\"tool_input\":{\"command\":\"rm -r out\"}}";
    {
        var o = opts();
        o.blocking = true;
        const it = try itemFrom(json, o);
        defer it.destroy();
        try testing.expectEqual(model.Kind.permission_request, it.kind);
        try testing.expectEqual(model.Status.pending, it.status);
        try testing.expectEqualStrings("run_shell_command", it.title);
        try testing.expectEqualStrings("rm -r out", it.detail);
        try testing.expect(it.tool_input_json != null);
        try testing.expect(it.permission_modes.has(.once) and it.permission_modes.has(.deny));
        try testing.expect(!it.permission_modes.has(.bypass));
        const b = (try model.bannerText(gpa, it)).?;
        defer gpa.free(b.title);
        defer gpa.free(b.body);
        try testing.expectEqualStrings("Gemini permission", b.title);
        try testing.expectEqualStrings("run_shell_command needs approval", b.body);
    }
    {
        // Unknown blocking keeps the event-name classification.
        const it = try itemFrom(json, opts());
        defer it.destroy();
        try testing.expectEqual(model.Kind.tool_use, it.kind);
    }
    {
        // Plans and questions stay what they are; todo writes need an answer too.
        var o = opts();
        o.blocking = true;
        const plan = try itemFrom("{\"hook_event_name\":\"PreToolUse\",\"source\":\"copilot\",\"tool_name\":\"ExitPlanMode\"}", o);
        defer plan.destroy();
        try testing.expectEqual(model.Kind.exit_plan, plan.kind);
        const todo = try itemFrom("{\"hook_event_name\":\"PreToolUse\",\"source\":\"qoder\",\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[]}}", o);
        defer todo.destroy();
        try testing.expectEqual(model.Kind.permission_request, todo.kind);
        // Lifecycle events are never promoted.
        const stop = try itemFrom("{\"hook_event_name\":\"Stop\",\"source\":\"kimi\"}", o);
        defer stop.destroy();
        try testing.expectEqual(model.Kind.stop, stop.kind);
    }
    {
        // Claude's PreToolUse telemetry for AskUserQuestion is no second card
        // next to the waiting PermissionRequest.
        var o = opts();
        o.blocking = false;
        const it = try itemFrom("{\"hook_event_name\":\"PreToolUse\",\"source\":\"claude\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Q\"}}", o);
        defer it.destroy();
        try testing.expectEqual(model.Kind.tool_use, it.kind);
        try testing.expect(it.tool_input_json == null);
    }
}

test "unit: feed: raw tool input is kept for decisions only" {
    const it = try itemFrom("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"a.txt\",\"content\":\"body\"}}", opts());
    defer it.destroy();
    try testing.expectEqual(model.Kind.tool_use, it.kind);
    try testing.expect(it.tool_input_json == null);
    try testing.expectEqualStrings("a.txt", it.detail);
    const res = try itemFrom("{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"body\"},\"tool_response\":{}}", opts());
    defer res.destroy();
    try testing.expect(res.tool_input_json == null);
}

test "unit: feed: fromEvent survives allocation failure at every point" {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hook_event_name":"PermissionRequest","source":"claude","tool_name":"AskUserQuestion","session_id":"s",
        \\ "tool_input":{"questions":[{"question":"Q","header":"H","options":[{"label":"L","description":"D"}]}]}}
    , .{});
    defer parsed.deinit();
    var i: usize = 0;
    while (true) : (i += 1) {
        var fa = testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        const it = model.fromEvent(fa.allocator(), parsed.value, opts()) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        it.destroy();
        break;
    }
}
