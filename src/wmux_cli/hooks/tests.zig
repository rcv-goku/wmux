//! Unit tests for the hook entrypoint's pure layers (ADR-12.1): payload
//! extraction and normalization. Fixtures are authored here (clean room).

const std = @import("std");
const testing = std.testing;
const payload = @import("payload.zig");
const normalize = @import("normalize.zig");
const Agent = normalize.Agent;
const Event = normalize.Event;

test {
    _ = payload;
    _ = normalize;
}

fn parseFixture(bytes: []const u8) !payload.Payload {
    return payload.parse(testing.allocator, bytes);
}

fn normalizeFixture(agent: Agent, arg: []const u8, bytes: []const u8) !struct { p: payload.Payload, n: ?normalize.Normalized } {
    var p = try parseFixture(bytes);
    errdefer p.deinit();
    return .{ .p = p, .n = normalize.normalize(agent, arg, &p) };
}

// ---------------------------------------------------------------------------
// payload

test "unit: agents: payload extracts claude session-start fields" {
    var p = try parseFixture(
        \\{"session_id":"5d0c1f0e-aaaa-4bbb-8ccc-000000000001","transcript_path":"C:/Users/dev/.claude/projects/demo/5d0c.jsonl",
        \\ "cwd":"C:\\src\\demo","hook_event_name":"SessionStart","source":"startup","permission_mode":"default","model":"sonnet"}
    );
    defer p.deinit();
    try testing.expect(!p.malformed and !p.oversized);
    try testing.expectEqualStrings("5d0c1f0e-aaaa-4bbb-8ccc-000000000001", p.session_id.?);
    try testing.expectEqualStrings("C:/Users/dev/.claude/projects/demo/5d0c.jsonl", p.transcript_path.?);
    try testing.expectEqualStrings("C:\\src\\demo", p.cwd.?);
    try testing.expectEqualStrings("SessionStart", p.hook_event_name.?);
    try testing.expectEqualStrings("startup", p.source.?);
    try testing.expectEqualStrings("default", p.permission_mode.?);
    try testing.expectEqualStrings("sonnet", p.model.?);
}

test "unit: agents: payload measures prompt length in code points and never stores the prompt" {
    var p = try parseFixture(
        \\{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"héllo wörld 👋"}
    );
    defer p.deinit();
    try testing.expectEqual(@as(usize, 13), p.prompt_length.?);
    try testing.expect(p.message == null);
}

test "unit: agents: payload prompt length is measured before capping on huge prompts" {
    const big_len = 300_000;
    const buf = try testing.allocator.alloc(u8, big_len + 64);
    defer testing.allocator.free(buf);
    const head = "{\"prompt\":\"";
    @memcpy(buf[0..head.len], head);
    @memset(buf[head.len .. head.len + big_len], 'x');
    const tail = "\"}";
    @memcpy(buf[head.len + big_len ..][0..tail.len], tail);
    var p = try parseFixture(buf[0 .. head.len + big_len + tail.len]);
    defer p.deinit();
    try testing.expectEqual(@as(usize, big_len), p.prompt_length.?);
}

test "unit: agents: payload tool input fields and background flag" {
    var p = try parseFixture(
        \\{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash",
        \\ "tool_input":{"command":"npm test","run_in_background":true,"description":"tests"}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("Bash", p.tool_name.?);
    try testing.expectEqualStrings("npm test", p.tool_command.?);
    try testing.expect(p.run_in_background);
}

test "unit: agents: payload decodes copilot camelCase keys and string-encoded toolArgs" {
    var p = try parseFixture(
        \\{"sessionId":"cop-1","cwd":"/home/u/p","toolName":"shell","toolArgs":"{\"command\":\"ls -la\"}","timestamp":1760000000}
    );
    defer p.deinit();
    try testing.expectEqualStrings("cop-1", p.session_id.?);
    try testing.expectEqualStrings("shell", p.tool_name.?);
    try testing.expectEqualStrings("ls -la", p.tool_command.?);
}

test "unit: agents: payload reads cursor conversation id and first workspace root" {
    var p = try parseFixture(
        \\{"conversation_id":"conv-9","generation_id":"gen-3","hook_event_name":"beforeShellExecution",
        \\ "workspace_roots":["/work/app","/work/lib"],"command":"rm -rf build"}
    );
    defer p.deinit();
    try testing.expectEqualStrings("conv-9", p.session_id.?);
    try testing.expectEqualStrings("gen-3", p.turn_id.?);
    try testing.expectEqualStrings("/work/app", p.cwd.?);
    try testing.expectEqualStrings("rm -rf build", p.tool_command.?);
}

test "unit: agents: payload reads opencode bus envelope" {
    var p = try parseFixture(
        \\{"type":"session.created","properties":{"info":{"id":"ses_abc","directory":"/srv/repo","title":"New session"}}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("session.created", p.hook_event_name.?);
    try testing.expectEqualStrings("ses_abc", p.session_id.?);
    try testing.expectEqualStrings("/srv/repo", p.cwd.?);
    try testing.expectEqualStrings("New session", p.title.?);
}

test "unit: agents: payload reads codex legacy notify payload" {
    var p = try parseFixture(
        \\{"type":"agent-turn-complete","thread-id":"th-77","turn-id":"t-2","cwd":"D:\\code",
        \\ "input-messages":["fix it"],"last-assistant-message":"Fixed the failing test."}
    );
    defer p.deinit();
    try testing.expectEqualStrings("agent-turn-complete", p.hook_event_name.?);
    try testing.expectEqualStrings("th-77", p.session_id.?);
    try testing.expectEqualStrings("t-2", p.turn_id.?);
    try testing.expectEqualStrings("Fixed the failing test.", p.last_assistant_message.?);
}

test "unit: agents: payload malformed, non-object, empty and oversized inputs never fail" {
    const cases = [_][]const u8{ "{not json", "[1,2,3]", "\"str\"", "42", "{\"a\":", "\x00\xff" };
    for (cases) |c| {
        var p = try parseFixture(c);
        defer p.deinit();
        try testing.expect(p.malformed);
        try testing.expect(p.session_id == null);
    }
    var e = try parseFixture("  \r\n");
    defer e.deinit();
    try testing.expect(!e.malformed and e.session_id == null);

    const huge = try testing.allocator.alloc(u8, payload.max_payload_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    var o = try parseFixture(huge);
    defer o.deinit();
    try testing.expect(o.oversized and !o.malformed);
}

test "unit: agents: payload tolerates BOM, duplicate keys, nulls and wrong types" {
    var p = try parseFixture("\xEF\xBB\xBF{\"session_id\":\"old\",\"session_id\":\"new\",\"cwd\":null,\"tool_name\":7,\"message\":{\"x\":1}}");
    defer p.deinit();
    try testing.expectEqualStrings("new", p.session_id.?);
    try testing.expect(p.cwd == null);
    try testing.expectEqualStrings("7", p.tool_name.?);
    try testing.expect(p.message == null);
}

test "unit: agents: payload caps ids on a code-point boundary" {
    var buf: [600]u8 = undefined;
    var n: usize = 0;
    const head = "{\"session_id\":\"";
    @memcpy(buf[0..head.len], head);
    n = head.len;
    // 127 two-byte chars then a 3-byte char straddling the 256-byte cap.
    for (0..127) |_| {
        @memcpy(buf[n..][0..2], "é");
        n += 2;
    }
    @memcpy(buf[n..][0..3], "€");
    n += 3;
    @memcpy(buf[n..][0..2], "\"}");
    n += 2;
    var p = try parseFixture(buf[0..n]);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 254), p.session_id.?.len);
    try testing.expect(std.unicode.utf8ValidateSlice(p.session_id.?));
}

test "unit: agents: payload nested notification text, error objects and push skip outcome" {
    var p = try parseFixture(
        \\{"hook_event_name":"PostToolUse","tool_name":"PushNotification","tool_input":{"message":"Build finished"},
        \\ "tool_response":{"status":"skipped","reason":"user_present"},"notification":{"body":"nested body"},
        \\ "error":{"message":"rate limited"}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("Build finished", p.tool_message.?);
    try testing.expect(p.push_skipped);
    try testing.expectEqualStrings("nested body", p.message.?);
    try testing.expectEqualStrings("rate limited", p.error_text.?);
}

/// `{"<key>":` + `depth` x `[` + `inner` + `depth` x `]` + `}`; caller frees.
fn nestedArrayDoc(key: []const u8, depth: usize, inner: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.print(gpa, "{{\"{s}\":", .{key});
    try doc.appendNTimes(gpa, '[', depth);
    try doc.appendSlice(gpa, inner);
    try doc.appendNTimes(gpa, ']', depth);
    try doc.append(gpa, '}');
    return doc.toOwnedSlice(gpa);
}

test "unit: agents: payload survives a tool response nested to the stdin cap" {
    // Half a million nested arrays fit under the 1 MiB cap and std.json
    // parses them; scanning them for a push skip outcome must not recurse
    // once per level.
    const deep = try nestedArrayDoc("tool_response", 500_000, "");
    defer testing.allocator.free(deep);
    try testing.expect(deep.len <= payload.max_payload_bytes);
    var p = try parseFixture(deep);
    defer p.deinit();
    try testing.expect(!p.malformed and !p.oversized and !p.push_skipped);

    // Skip outcomes a few arrays down are still found; deeper ones are not
    // searched.
    const shallow = try nestedArrayDoc("tool_response", 3, "{\"reason\":\"user_present\"}");
    defer testing.allocator.free(shallow);
    var s = try parseFixture(shallow);
    defer s.deinit();
    try testing.expect(s.push_skipped);
    const buried = try nestedArrayDoc("tool_response", 50, "\"config_off\"");
    defer testing.allocator.free(buried);
    var b = try parseFixture(buried);
    defer b.deinit();
    try testing.expect(!b.push_skipped);
}

test "unit: agents: payload detects subagent markers" {
    var a = try parseFixture("{\"session_id\":\"c\",\"parent_session_id\":\"p\"}");
    defer a.deinit();
    try testing.expect(a.is_subagent);
    var b = try parseFixture("{\"session_id\":\"c\",\"parent_session_id\":\"\"}");
    defer b.deinit();
    try testing.expect(!b.is_subagent);
    var c = try parseFixture("{\"isSubagent\":true}");
    defer c.deinit();
    try testing.expect(c.is_subagent);
}

test "unit: agents: payload truncateUtf8 boundaries" {
    try testing.expectEqualStrings("", payload.truncateUtf8("", 4));
    try testing.expectEqualStrings("abc", payload.truncateUtf8("abc", 3));
    try testing.expectEqualStrings("a", payload.truncateUtf8("a€", 3));
    try testing.expectEqualStrings("a€", payload.truncateUtf8("a€b", 4));
    try testing.expectEqualStrings("", payload.truncateUtf8("€", 0));
}

// ---------------------------------------------------------------------------
// agent catalog and subcommands

test "unit: agents: agent names, aliases and ids" {
    try testing.expectEqual(Agent.antigravity, Agent.parse("agy").?);
    try testing.expectEqual(Agent.rovodev, Agent.parse("rovo").?);
    try testing.expectEqual(Agent.hermes_agent, Agent.parse("hermes-agent").?);
    try testing.expectEqual(Agent.claude, Agent.parse("Claude").?);
    try testing.expectEqual(Agent.claude, Agent.parse("claude_code").?);
    try testing.expect(Agent.parse("hermes_agent") == null);
    try testing.expect(Agent.parse("") == null);
    try testing.expect(Agent.parse("aider") == null);
    try testing.expect(Agent.parse("x" ** 100) == null);
    try testing.expectEqualStrings("hermes-agent", Agent.hermes_agent.id());
    try testing.expectEqualStrings("Claude Code", Agent.claude.displayName());
    try testing.expectEqualStrings("HERMES_AGENT", Agent.hermes_agent.envToken());
    try testing.expectEqual(@as(u32, 10), Agent.gemini.hookTimeoutSeconds());
    try testing.expectEqual(@as(u32, 5), Agent.codex.hookTimeoutSeconds());
    // Every agent parses back from its id.
    inline for (@typeInfo(Agent).@"enum".fields) |f| {
        const a: Agent = @enumFromInt(f.value);
        try testing.expectEqual(a, Agent.parse(a.id()).?);
    }
}

test "unit: agents: subcommand spellings and aliases" {
    try testing.expectEqualStrings("session-start", Event.session_start.subcommand());
    try testing.expectEqualStrings("cron-create-guard", Event.cron_create_guard.subcommand());
    try testing.expectEqual(Event.session_start, Event.parseSubcommand("active").?);
    try testing.expectEqual(Event.stop, Event.parseSubcommand("idle").?);
    try testing.expectEqual(Event.notification, Event.parseSubcommand("notify").?);
    try testing.expectEqual(Event.push_notification, Event.parseSubcommand("push-notification").?);
    try testing.expect(Event.parseSubcommand("session_start") == null);
    try testing.expect(Event.parseSubcommand("") == null);
    inline for (@typeInfo(Event).@"enum".fields) |f| {
        const e: Event = @enumFromInt(f.value);
        try testing.expectEqual(e, Event.parseSubcommand(e.subcommand()).?);
    }
}

test "unit: agents: claude native events map to subcommands" {
    const cases = .{
        .{ "SessionStart", Event.session_start, false },
        .{ "UserPromptSubmit", Event.prompt_submit, false },
        .{ "PreToolUse", Event.pre_tool_use, false },
        .{ "PostToolUse", Event.post_tool_use, false },
        .{ "Notification", Event.notification, false },
        .{ "Stop", Event.stop, false },
        .{ "StopFailure", Event.stop, true },
        .{ "SubagentStop", Event.subagent_stop, false },
        .{ "SessionEnd", Event.session_end, false },
        .{ "PreCompact", Event.pre_compact, false },
        .{ "PermissionRequest", Event.feed, false },
    };
    inline for (cases) |c| {
        const m = normalize.mapNative(.claude, c[0]).?;
        try testing.expectEqual(c[1], m.event);
        try testing.expectEqual(c[2], m.failure);
    }
    try testing.expect(normalize.mapNative(.claude, "Bogus") == null);
    try testing.expect(normalize.mapNative(.claude, "") == null);
    try testing.expect(normalize.mapNative(.claude, "a" ** 200) == null);
}

test "unit: agents: per-agent native vocabularies" {
    const cases = .{
        .{ Agent.gemini, "BeforeAgent", Event.prompt_submit },
        .{ Agent.gemini, "AfterAgent", Event.stop },
        .{ Agent.gemini, "BeforeTool", Event.pre_tool_use },
        .{ Agent.gemini, "PreCompress", Event.pre_compact },
        .{ Agent.antigravity, "AfterAgent", Event.stop },
        .{ Agent.cursor, "beforeSubmitPrompt", Event.prompt_submit },
        .{ Agent.cursor, "beforeShellExecution", Event.shell_exec },
        .{ Agent.cursor, "afterShellExecution", Event.shell_done },
        .{ Agent.cursor, "stop", Event.stop },
        .{ Agent.kiro, "agentSpawn", Event.session_start },
        .{ Agent.kiro, "userPromptSubmit", Event.prompt_submit },
        .{ Agent.kiro, "preToolUse", Event.pre_tool_use },
        .{ Agent.rovodev, "on_complete", Event.stop },
        .{ Agent.hermes_agent, "pre_llm_call", Event.prompt_submit },
        .{ Agent.copilot, "userPromptSubmitted", Event.prompt_submit },
        .{ Agent.copilot, "sessionEnd", Event.session_end },
        .{ Agent.opencode, "session.idle", Event.stop },
        .{ Agent.opencode, "tool.execute.before", Event.pre_tool_use },
        .{ Agent.pi, "agent_end", Event.stop },
        .{ Agent.omp, "tool_execution_start", Event.pre_tool_use },
        .{ Agent.campfire, "session_shutdown", Event.session_end },
        .{ Agent.amp, "thinking", Event.prompt_submit },
        .{ Agent.codex, "agent-turn-complete", Event.stop },
        .{ Agent.codebuddy, "Stop", Event.stop },
        .{ Agent.factory, "PreToolUse", Event.pre_tool_use },
        .{ Agent.qoder, "UserPromptSubmit", Event.prompt_submit },
        .{ Agent.kimi, "PostToolUse", Event.post_tool_use },
        .{ Agent.muse, "SessionStart", Event.session_start },
        .{ Agent.grok, "Notification", Event.notification },
    };
    inline for (cases) |c| {
        const m = normalize.mapNative(c[0], c[1]) orelse {
            std.log.err("unmapped {s} {s}", .{ @tagName(c[0]), c[1] });
            return error.Unmapped;
        };
        try testing.expectEqual(c[2], m.event);
    }
    try testing.expect(normalize.mapNative(.rovodev, "on_error").?.failure);
    try testing.expect(normalize.mapNative(.opencode, "session.error").?.failure);
    // Gemini's names are not part of the shared vocabulary.
    try testing.expect(normalize.mapNative(.claude, "AfterAgent") == null);
}

// ---------------------------------------------------------------------------
// normalize

test "unit: agents: normalize claude prompt-submit with payload" {
    var r = try normalizeFixture(.claude, "prompt-submit",
        \\{"session_id":"s-1","cwd":"C:/w","hook_event_name":"UserPromptSubmit","prompt":"run the tests","permission_mode":"acceptEdits"}
    );
    defer r.p.deinit();
    const n = r.n.?;
    try testing.expectEqual(Event.prompt_submit, n.event);
    try testing.expectEqualStrings("UserPromptSubmit", n.native_event.?);
    try testing.expectEqual(@as(usize, 13), n.prompt_length.?);
    try testing.expectEqualStrings("acceptEdits", n.permission_mode.?);
    try testing.expectEqualStrings("running", normalize.storeLifecycle(n, false).?);
}

test "unit: agents: normalize stop failure refines the stop subcommand" {
    var r = try normalizeFixture(.claude, "stop",
        \\{"session_id":"s-1","hook_event_name":"StopFailure","error":"overloaded"}
    );
    defer r.p.deinit();
    try testing.expectEqual(Event.stop, r.n.?.event);
    try testing.expect(r.n.?.failure);
    // A payload event that disagrees with the subcommand does not override it.
    var r2 = try normalizeFixture(.claude, "stop", "{\"hook_event_name\":\"PreToolUse\"}");
    defer r2.p.deinit();
    try testing.expectEqual(Event.stop, r2.n.?.event);
    try testing.expect(!r2.n.?.failure);
}

test "unit: agents: normalize uses native argument then payload event name" {
    var r = try normalizeFixture(.gemini, "AfterAgent", "{\"session_id\":\"g\",\"prompt_response\":\"All done\"}");
    defer r.p.deinit();
    try testing.expectEqual(Event.stop, r.n.?.event);
    try testing.expectEqualStrings("AfterAgent", r.n.?.native_event.?);

    var r2 = try normalizeFixture(.cursor, "hook", "{\"hook_event_name\":\"stop\",\"status\":\"error\",\"conversation_id\":\"c\"}");
    defer r2.p.deinit();
    try testing.expectEqual(Event.stop, r2.n.?.event);
    try testing.expect(r2.n.?.failure);

    var r3 = try normalizeFixture(.codex, "unknown-thing", "{}");
    defer r3.p.deinit();
    try testing.expect(r3.n == null);
}

test "unit: agents: normalize claude PushNotification post-tool-use becomes push-notification" {
    var r = try normalizeFixture(.claude, "post-tool-use",
        \\{"session_id":"s","tool_name":"PushNotification","tool_input":{"message":"Deploy done"}}
    );
    defer r.p.deinit();
    try testing.expectEqual(Event.push_notification, r.n.?.event);
    try testing.expectEqualStrings("Deploy done", r.n.?.message.?);
    // Other agents keep post-tool-use.
    var r2 = try normalizeFixture(.codex, "post-tool-use", "{\"tool_name\":\"PushNotification\"}");
    defer r2.p.deinit();
    try testing.expectEqual(Event.post_tool_use, r2.n.?.event);
}

test "unit: agents: normalize needs-input kinds" {
    var perm = try normalizeFixture(.claude, "notification",
        \\{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
    );
    defer perm.p.deinit();
    try testing.expectEqual(normalize.InputKind.permission, perm.n.?.input_kind.?);

    var idle = try normalizeFixture(.claude, "notify", "{\"message\":\"Claude is waiting for your input\",\"notification_type\":\"idle_prompt\"}");
    defer idle.p.deinit();
    try testing.expectEqual(normalize.InputKind.waiting, idle.n.?.input_kind.?);

    var q = try normalizeFixture(.claude, "pre-tool-use", "{\"tool_name\":\"AskUserQuestion\"}");
    defer q.p.deinit();
    try testing.expectEqual(normalize.InputKind.question, q.n.?.input_kind.?);
    try testing.expectEqualStrings("needsInput", normalize.storeLifecycle(q.n.?, false).?);

    var plan = try normalizeFixture(.claude, "pre-tool-use", "{\"tool_name\":\"ExitPlanMode\"}");
    defer plan.p.deinit();
    try testing.expectEqual(normalize.InputKind.plan, plan.n.?.input_kind.?);

    var feed = try normalizeFixture(.claude, "feed", "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}");
    defer feed.p.deinit();
    try testing.expectEqual(normalize.InputKind.permission, feed.n.?.input_kind.?);

    var plain = try normalizeFixture(.grok, "notification", "{}");
    defer plain.p.deinit();
    try testing.expectEqual(normalize.InputKind.waiting, plain.n.?.input_kind.?);
}

test "unit: agents: normalize background work and subagent flags" {
    var bg = try normalizeFixture(.claude, "pre-tool-use", "{\"tool_name\":\"Bash\",\"tool_input\":{\"run_in_background\":true}}");
    defer bg.p.deinit();
    try testing.expect(bg.n.?.background_pending);

    var sub = try normalizeFixture(.claude, "subagent-stop", "{\"session_id\":\"s\"}");
    defer sub.p.deinit();
    try testing.expect(sub.n.?.is_subagent);
    try testing.expect(normalize.storeLifecycle(sub.n.?, false) == null);
    try testing.expect(normalize.suppressedAsSubagent(sub.n.?, true));
    try testing.expect(!normalize.suppressedAsSubagent(sub.n.?, false));

    var stop = try normalizeFixture(.claude, "stop", "{\"session_id\":\"s\"}");
    defer stop.p.deinit();
    try testing.expectEqualStrings("backgroundWorkPending", normalize.storeLifecycle(stop.n.?, true).?);
    try testing.expectEqualStrings("idle", normalize.storeLifecycle(stop.n.?, false).?);
}

test "unit: agents: normalize tolerates an empty or malformed payload" {
    var r = try normalizeFixture(.codex, "stop", "{garbage");
    defer r.p.deinit();
    try testing.expectEqual(Event.stop, r.n.?.event);
    try testing.expect(r.n.?.session_id == null);
}

// ---------------------------------------------------------------------------
// environment gating and acks

test "unit: agents: inside-wmux detection and per-agent disable flags" {
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try testing.expect(!normalize.insideWmux(&env, false));
    try testing.expect(normalize.insideWmux(&env, true));
    try env.put("CMUX_SURFACE_ID", "  ");
    try testing.expect(!normalize.insideWmux(&env, false));
    try env.put("WMUX_WORKSPACE_ID", "6A1F2E3D-0000-4000-8000-000000000001");
    try testing.expect(normalize.insideWmux(&env, false));

    try testing.expect(!normalize.hooksDisabled(.codex, &env));
    try env.put("CMUX_CODEX_HOOKS_DISABLED", "1");
    try testing.expect(normalize.hooksDisabled(.codex, &env));
    try testing.expect(!normalize.hooksDisabled(.claude, &env));
    try env.put("WMUX_HERMES_AGENT_HOOKS_DISABLED", "true");
    try testing.expect(normalize.hooksDisabled(.hermes_agent, &env));
    try env.put("CMUX_GROK_HOOKS_DISABLED", "0");
    try testing.expect(!normalize.hooksDisabled(.grok, &env));
}

test "unit: agents: neutral acknowledgments" {
    try testing.expectEqualStrings("{}", normalize.neutralAck(.codex, .stop));
    try testing.expectEqualStrings("{}", normalize.neutralAck(.claude, null));
    try testing.expectEqualStrings("{}", normalize.neutralAck(.claude, .cron_create_guard));
    try testing.expectEqualStrings("{\"permission\":\"allow\"}", normalize.neutralAck(.cursor, .shell_exec));
    try testing.expectEqualStrings("{\"continue\":true}", normalize.neutralAck(.cursor, .prompt_submit));
    try testing.expectEqualStrings("{}", normalize.neutralAck(.cursor, .stop));
}

// ---------------------------------------------------------------------------
// notification formatting

fn classifyT(a: std.mem.Allocator, agent: Agent, signal: []const u8, msg: ?[]const u8) !?normalize.Formatted {
    return normalize.classify(a, agent, signal, msg);
}

test "unit: agents: classifier categories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const perm = (try classifyT(a, .claude, "Notification", "Claude needs your permission to use Bash")).?;
    try testing.expectEqualStrings("Claude Code", perm.title);
    try testing.expectEqualStrings("Permission", perm.subtitle);
    try testing.expectEqualStrings("Claude needs your permission to use Bash", perm.body);
    try testing.expectEqual(normalize.Category.needs_permission, perm.category);

    const perm_empty = (try classifyT(a, .codex, "permission_prompt", null)).?;
    try testing.expectEqualStrings("Approval needed", perm_empty.body);

    const err = (try classifyT(a, .gemini, "StopFailure", "")).?;
    try testing.expectEqualStrings("Error", err.subtitle);
    try testing.expectEqualStrings("Gemini reported an error", err.body);
    try testing.expectEqual(normalize.Category.other, err.category);

    const done = (try classifyT(a, .codex, "", "Task finished successfully")).?;
    try testing.expectEqualStrings("Completed", done.subtitle);
    try testing.expectEqual(normalize.Category.turn_complete, done.category);

    const done_word = (try classifyT(a, .codex, "done", null)).?;
    try testing.expectEqualStrings("Task completed", done_word.body);

    const wait = (try classifyT(a, .grok, "", "Grok needs your input")).?;
    try testing.expectEqualStrings("Waiting", wait.subtitle);
    try testing.expectEqual(normalize.Category.idle_reminder, wait.category);

    const idle_prompt = (try classifyT(a, .claude, "idle_prompt", null)).?;
    try testing.expectEqualStrings("Waiting for input", idle_prompt.body);

    const question = (try classifyT(a, .kiro, "", "I have a question: which branch?")).?;
    try testing.expectEqualStrings("Waiting", question.subtitle);

    const attention = (try classifyT(a, .amp, "", "Heads up: config reloaded")).?;
    try testing.expectEqualStrings("Attention", attention.subtitle);

    try testing.expect((try classifyT(a, .amp, "", null)) == null);
    try testing.expect((try classifyT(a, .amp, "", "   ")) == null);
    // "doneness" is not the word "done"; "question" alone without a cue is plain attention.
    try testing.expectEqualStrings("Attention", (try classifyT(a, .amp, "", "doneness question")).?.subtitle);
}

test "unit: agents: bodies are single-line and capped at 180 chars with ellipsis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("a b c", try normalize.singleLine(a, "  a\n\tb\r\n  c  ", 180));
    try testing.expectEqualStrings("", try normalize.singleLine(a, " \n ", 180));

    const long = "é" ** 400;
    const out = try normalize.singleLine(a, long, 180);
    try testing.expectEqual(@as(usize, 180), try std.unicode.utf8CountCodepoints(out));
    try testing.expect(std.mem.endsWith(u8, out, "…"));

    const exact = "x" ** 180;
    try testing.expectEqualStrings(exact, try normalize.singleLine(a, exact, 180));

    const invalid = try normalize.singleLine(a, "ok\xffok", 180);
    try testing.expect(std.unicode.utf8ValidateSlice(invalid));
}

test "unit: agents: claude stop notification uses project and last assistant message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try normalizeFixture(.claude, "stop", "{\"session_id\":\"s\",\"cwd\":\"C:\\\\src\\\\wmux\\\\\"}");
    defer r.p.deinit();
    const f = (try normalize.format(a, r.n.?, .{ .payload = &r.p, .transcript_last_message = "All 42 tests pass.\nDone." })).?;
    try testing.expectEqualStrings("Claude Code", f.title);
    try testing.expectEqualStrings("Completed in wmux", f.subtitle);
    try testing.expectEqualStrings("All 42 tests pass. Done.", f.body);
    try testing.expectEqual(normalize.Category.turn_complete, f.category);

    const g = (try normalize.format(a, r.n.?, .{ .payload = &r.p, .stored_summary = "Refactored parser" })).?;
    try testing.expectEqualStrings("Claude session completed in wmux. Last: Refactored parser", g.body);

    var r2 = try normalizeFixture(.claude, "stop", "{}");
    defer r2.p.deinit();
    const h = (try normalize.format(a, r2.n.?, .{ .payload = &r2.p })).?;
    try testing.expectEqualStrings("Completed", h.subtitle);
    try testing.expectEqualStrings("Claude session completed", h.body);

    const long = "word " ** 100;
    const k = (try normalize.format(a, r.n.?, .{ .payload = &r.p, .transcript_last_message = long })).?;
    try testing.expect((try std.unicode.utf8CountCodepoints(k.body)) <= 200);
}

test "unit: agents: stop notifications for other agents, grok and failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var codex = try normalizeFixture(.codex, "stop", "{\"last_assistant_message\":\"Refactor complete\"}");
    defer codex.p.deinit();
    const f = (try normalize.format(a, codex.n.?, .{ .payload = &codex.p })).?;
    try testing.expectEqualStrings("Codex", f.title);
    try testing.expectEqualStrings("Completed", f.subtitle);
    try testing.expectEqualStrings("Refactor complete", f.body);

    var bare = try normalizeFixture(.gemini, "stop", "{}");
    defer bare.p.deinit();
    try testing.expectEqualStrings("Task completed", (try normalize.format(a, bare.n.?, .{ .payload = &bare.p })).?.body);

    var grok = try normalizeFixture(.grok, "stop", "{\"message\":\"x\"}");
    defer grok.p.deinit();
    try testing.expect((try normalize.format(a, grok.n.?, .{ .payload = &grok.p })) == null);

    var fail = try normalizeFixture(.claude, "stop", "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate limit reached\"}");
    defer fail.p.deinit();
    const e = (try normalize.format(a, fail.n.?, .{ .payload = &fail.p })).?;
    try testing.expectEqualStrings("Error", e.subtitle);
    try testing.expectEqualStrings("rate limit reached", e.body);

    // Failure text with permission, approval or completion words is still
    // an error, never a needs-permission prompt or a turn-complete.
    const texts = [_][]const u8{ "API Error: permission denied for this model", "Request was not approved", "Completed with errors", "" };
    for (texts) |t| {
        const doc = try std.fmt.allocPrint(a, "{{\"hook_event_name\":\"StopFailure\",\"error\":\"{s}\"}}", .{t});
        var r = try normalizeFixture(.claude, "stop", doc);
        defer r.p.deinit();
        const f2 = (try normalize.format(a, r.n.?, .{ .payload = &r.p })).?;
        try testing.expectEqualStrings("Error", f2.subtitle);
        try testing.expectEqual(normalize.Category.other, f2.category);
        try testing.expectEqualStrings(if (t.len > 0) t else "Claude Code reported an error", f2.body);
    }
    // Same for a failure flagged only by `status`, even on Grok, whose
    // plain Stop is silent.
    var status = try normalizeFixture(.grok, "stop", "{\"status\":\"failed\",\"message\":\"Approval required to continue\"}");
    defer status.p.deinit();
    const g = (try normalize.format(a, status.n.?, .{ .payload = &status.p })).?;
    try testing.expectEqualStrings("Error", g.subtitle);
    try testing.expectEqualStrings("Approval required to continue", g.body);
}

test "unit: agents: permission, push and pi title formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var feed = try normalizeFixture(.claude, "feed", "{\"hook_event_name\":\"PermissionRequest\"}");
    defer feed.p.deinit();
    const f = (try normalize.format(a, feed.n.?, .{ .payload = &feed.p })).?;
    try testing.expectEqualStrings("Permission", f.subtitle);
    try testing.expectEqualStrings("Approval needed", f.body);

    var push = try normalizeFixture(.claude, "post-tool-use", "{\"tool_name\":\"PushNotification\",\"tool_input\":{\"message\":\"" ++ ("z" ** 300) ++ "\"}}");
    defer push.p.deinit();
    const pf = (try normalize.format(a, push.n.?, .{ .payload = &push.p })).?;
    try testing.expectEqual(@as(usize, 240), try std.unicode.utf8CountCodepoints(pf.body));

    var skipped = try normalizeFixture(.claude, "post-tool-use", "{\"tool_name\":\"PushNotification\",\"tool_input\":{\"message\":\"hi\"},\"tool_response\":\"skipped: config_off\"}");
    defer skipped.p.deinit();
    try testing.expect((try normalize.format(a, skipped.n.?, .{ .payload = &skipped.p })) == null);

    var pi = try normalizeFixture(.pi, "notification", "{\"message\":\"Pi needs your input\"}");
    defer pi.p.deinit();
    try testing.expectEqualStrings("Pi · api-server", (try normalize.format(a, pi.n.?, .{ .payload = &pi.p, .surface_title = "api-server" })).?.title);
    try testing.expectEqualStrings("Pi", (try normalize.format(a, pi.n.?, .{ .payload = &pi.p, .surface_title = "Pi" })).?.title);

    var pre = try normalizeFixture(.claude, "pre-tool-use", "{}");
    defer pre.p.deinit();
    try testing.expect((try normalize.format(a, pre.n.?, .{ .payload = &pre.p })) == null);
}

test "unit: agents: dedupe fingerprint is stable and body-sensitive" {
    const a: normalize.Formatted = .{ .title = "Grok", .subtitle = "Completed", .body = "x", .category = .turn_complete };
    var b = a;
    try testing.expectEqual(normalize.fingerprint(a), normalize.fingerprint(b));
    b.body = "y";
    try testing.expect(normalize.fingerprint(a) != normalize.fingerprint(b));
    try testing.expect(Agent.grok.dedupesNotifications());
    try testing.expect(!Agent.claude.dedupesNotifications());
}

test "unit: agents: project name from windows and posix paths" {
    try testing.expectEqualStrings("wmux", normalize.projectName("C:\\src\\wmux"));
    try testing.expectEqualStrings("wmux", normalize.projectName("/home/u/wmux/"));
    try testing.expectEqualStrings("proj", normalize.projectName("proj"));
    try testing.expectEqualStrings("", normalize.projectName("/"));
}

test "unit: agents: last assistant message from a transcript tail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tail =
        \\ial line cut by the tail window"}
        \\{"type":"user","message":{"role":"user","content":"please fix"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"text","text":"Fixed it."}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        \\{"type":"assistant", broken json
        \\
    ;
    try testing.expectEqualStrings("Looking. Fixed it.", (try normalize.lastAssistantMessage(a, tail)).?);
    try testing.expect((try normalize.lastAssistantMessage(a, "")) == null);
    try testing.expect((try normalize.lastAssistantMessage(a, "{\"type\":\"user\"}\n")) == null);
    try testing.expectEqualStrings("plain", (try normalize.lastAssistantMessage(a, "{\"type\":\"assistant\",\"message\":{\"content\":\"plain\"}}")).?);
}

// ---------------------------------------------------------------------------
// wire params

test "unit: agents: wmux.agent.hook params encoding" {
    var r = try normalizeFixture(.claude, "pre-tool-use",
        \\{"session_id":"s-1","cwd":"C:\\w \"q\"","transcript_path":"C:/t.jsonl","tool_name":"Bash","tool_input":{"run_in_background":true}}
    );
    defer r.p.deinit();
    const json = try normalize.hookParamsAlloc(testing.allocator, r.n.?, .{
        .seq = 7,
        .surface_id = "AAAAAAAA-0000-4000-8000-000000000001",
        .workspace_id = "BBBBBBBB-0000-4000-8000-000000000002",
        .pid = 4242,
    });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"agent":"claude","event":"pre-tool-use","seq":7,"session_id":"s-1","surface_id":"AAAAAAAA-0000-4000-8000-000000000001","workspace_id":"BBBBBBBB-0000-4000-8000-000000000002","cwd":"C:\\w \"q\"","pid":4242,"transcript_path":"C:/t.jsonl","tool_name":"Bash","background_pending":true}
    , json);

    // Round-trips through std.json.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("C:\\w \"q\"", parsed.value.object.get("cwd").?.string);
}

test "unit: agents: wmux.agent.hook params send a known background state at stop" {
    var stop = try normalizeFixture(.claude, "stop", "{\"session_id\":\"s\"}");
    defer stop.p.deinit();
    // The app needs an explicit false to clear the pending state it tracked
    // from an earlier run_in_background tool; unknown stays omitted.
    const cases = .{
        .{ @as(?bool, false), "{\"agent\":\"claude\",\"event\":\"stop\",\"seq\":2,\"session_id\":\"s\",\"background_pending\":false}" },
        .{ @as(?bool, true), "{\"agent\":\"claude\",\"event\":\"stop\",\"seq\":2,\"session_id\":\"s\",\"background_pending\":true}" },
        .{ @as(?bool, null), "{\"agent\":\"claude\",\"event\":\"stop\",\"seq\":2,\"session_id\":\"s\"}" },
    };
    inline for (cases) |c| {
        const json = try normalize.hookParamsAlloc(testing.allocator, stop.n.?, .{ .seq = 2, .background_pending = c[0] });
        defer testing.allocator.free(json);
        try testing.expectEqualStrings(c[1], json);
    }

    // A tool started in the background reports true whatever the context says.
    var bg = try normalizeFixture(.claude, "pre-tool-use", "{\"tool_input\":{\"run_in_background\":true}}");
    defer bg.p.deinit();
    const json = try normalize.hookParamsAlloc(testing.allocator, bg.n.?, .{ .seq = 3, .background_pending = false });
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"background_pending\":true") != null);
}

test "unit: agents: wmux.agent.hook params minimal and flagged forms" {
    var r = try normalizeFixture(.hermes_agent, "stop", "{\"hook_event_name\":\"on_error\",\"status\":\"failed\"}");
    defer r.p.deinit();
    const json = try normalize.hookParamsAlloc(testing.allocator, r.n.?, .{ .seq = 0 });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"agent":"hermes-agent","event":"stop","seq":0,"hook_event_name":"on_error","failure":true}
    , json);

    var q = try normalizeFixture(.claude, "notification", "{\"message\":\"Allow edit?\",\"notification_type\":\"permission_prompt\"}");
    defer q.p.deinit();
    const json2 = try normalize.hookParamsAlloc(testing.allocator, q.n.?, .{ .seq = 1 });
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(
        \\{"agent":"claude","event":"notification","seq":1,"message":"Allow edit?","input_kind":"permission"}
    , json2);
}
