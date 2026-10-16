//! Hook stdin payload extraction (ADR-10.1 step 1). Every supported agent
//! sends a JSON object on stdin; key spellings differ per agent (snake_case,
//! camelCase, kebab-case, OpenCode-style `properties` envelopes, Codex's
//! legacy `notify` program payload (delivered as the last argv element,
//! see `argvPayload`), Cursor's `conversation_id`, Hermes `extra`, Rovo Dev
//! `attributes`, Amp `thread.id`, Antigravity `toolCall`, ...). This
//! file reads only the fields cmux consumes (session_id, transcript_path,
//! cwd, hook_event_name, tool_name/tool_input, message, permission_mode and
//! the prompt length) plus the few extra signals the classifier and the
//! lifecycle need. Parsing never fails on user input: malformed or oversized
//! payloads yield an empty `Payload` with a flag set, so the hook can still
//! print its neutral ack (a hook never fails its agent).
//!
//! Pure std; strings are heap copies owned by `Payload.arena` and capped on
//! code-point boundaries (G6).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Stdin cap (ADR-10.1 step 1). Larger payloads are not parsed.
pub const max_payload_bytes: usize = 1 << 20;

/// Byte caps for stored strings (G6).
pub const max_id_bytes: usize = 256;
pub const max_name_bytes: usize = 256;
pub const max_path_bytes: usize = 4096;
pub const max_text_bytes: usize = 8192;

pub const Payload = struct {
    arena: std.heap.ArenaAllocator,

    /// Input was not a JSON object (or not JSON at all).
    malformed: bool = false,
    /// Input exceeded `max_payload_bytes` and was not parsed.
    oversized: bool = false,

    hook_event_name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    /// `tool_input.command` (or a top-level `command`, Cursor shell hooks).
    tool_command: ?[]const u8 = null,
    /// `tool_input.message` (Claude `PushNotification` tool).
    tool_message: ?[]const u8 = null,
    message: ?[]const u8 = null,
    title: ?[]const u8 = null,
    error_text: ?[]const u8 = null,
    notification_type: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    last_assistant_message: ?[]const u8 = null,
    /// SessionStart `source` (startup|resume|clear|compact|fork) and similar.
    source: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    /// Cursor `stop.status`, Amp `agent.end.status`, OpenCode
    /// `properties.status.type`, Rovo Dev `attributes.status`, else
    /// Antigravity's Stop `terminationReason`.
    status: ?[]const u8 = null,
    matcher: ?[]const u8 = null,
    model: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,

    /// Length of the prompt in Unicode code points (bytes if the prompt is
    /// not valid UTF-8), measured on the full string before any capping.
    /// The prompt text itself is never stored.
    prompt_length: ?usize = null,
    /// `tool_input.run_in_background == true`.
    run_in_background: bool = false,
    /// Claude `stop_hook_active`.
    stop_hook_active: bool = false,
    /// Payload marks a nested/child agent (parent session ids, subagent
    /// ids, explicit `is_subagent`). `agent_id` is kept apart in `agent_id`
    /// because some agents (Kimi Code 2.x) send it for the main agent too;
    /// normalize decides per agent.
    is_subagent: bool = false,
    /// `agent_id`/`agentId` (Claude/Codex: present only inside a subagent).
    agent_id: ?[]const u8 = null,
    /// Hermes `extra.failed` (turn failed).
    failed: bool = false,
    /// Copilot `errorOccurred.recoverable` when present.
    recoverable: ?bool = null,
    /// A `PushNotification` tool response reports it skipped delivery
    /// (`user_present` or `config_off`).
    push_skipped: bool = false,

    pub fn deinit(self: *Payload) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// An empty payload (no fields), for callers with no stdin.
    pub fn empty(gpa: Allocator) Payload {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }
};

// Alias tables: the first key present with a usable value wins.
const keys_event = [_][]const u8{ "hook_event_name", "hookEventName", "hook-event-name", "event_name", "eventName", "event", "type", "hook" };
const keys_session = [_][]const u8{ "session_id", "sessionId", "sessionID", "session-id", "conversation_id", "conversationId", "thread_id", "threadId", "thread-id" };
const keys_transcript = [_][]const u8{ "transcript_path", "transcriptPath", "transcript-path", "session_file", "sessionFile" };
const keys_cwd = [_][]const u8{ "cwd", "working_directory", "workingDirectory", "directory", "project_dir", "projectDir", "workspaceRoot", "workspace_root" };
/// Cursor `workspace_roots`, Antigravity `workspacePaths` (agy sends no cwd).
const keys_roots = [_][]const u8{ "workspace_roots", "workspaceRoots", "workspacePaths", "workspace_paths" };
const keys_tool = [_][]const u8{ "tool_name", "toolName", "tool-name", "tool" };
const keys_tool_input = [_][]const u8{ "tool_input", "toolInput", "toolArgs", "tool_args", "args", "input", "parameters" };
const keys_tool_response = [_][]const u8{ "tool_response", "toolResponse", "tool_result", "toolResult", "result" };
const keys_message = [_][]const u8{ "message", "body", "text", "description", "summary" };
const keys_error = [_][]const u8{ "error", "error_message", "errorMessage" };
const keys_notification_type = [_][]const u8{ "notification_type", "notificationType", "kind" };
const keys_permission = [_][]const u8{ "permission_mode", "permissionMode" };
const keys_prompt = [_][]const u8{ "prompt", "user_prompt", "userPrompt", "user_message" };
const keys_last_message = [_][]const u8{ "last_assistant_message", "lastAssistantMessage", "last-assistant-message", "prompt_response", "promptResponse", "response", "assistant_response" };
const keys_turn = [_][]const u8{ "turn_id", "turnId", "turn-id", "generation_id", "generationId" };
const keys_subagent_ids = [_][]const u8{ "parent_session_id", "parentSessionId", "parentSessionID", "parent_thread_id", "parentThreadId", "parent_conversation_id", "subagent_id", "subagentId" };
const keys_agent_id = [_][]const u8{ "agent_id", "agentId" };
const keys_status = [_][]const u8{ "status", "terminationReason", "termination_reason" };
const keys_subagent_flags = [_][]const u8{ "is_subagent", "isSubagent", "subagent", "nested" };

/// Nested containers searched (one level, then their `info`) after the top
/// level: OpenCode bus events (`properties`, `properties.info`), generic
/// envelopes (`payload`, `data`), notification objects (`notification`),
/// Hermes shell-hook kwargs (`extra`), Rovo Dev event data (`attributes`).
const nested_containers = [_][]const u8{ "properties", "payload", "data", "notification", "event", "extra", "attributes" };

/// Parse a hook payload. Only allocation failure is an error; malformed,
/// non-object and oversized inputs return a flagged empty payload.
pub fn parse(gpa: Allocator, bytes: []const u8) Allocator.Error!Payload {
    var p: Payload = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer p.arena.deinit();
    const a = p.arena.allocator();

    if (bytes.len > max_payload_bytes) {
        p.oversized = true;
        return p;
    }
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n\xEF\xBB\xBF");
    if (trimmed.len == 0) return p; // `echo '' | cmux hooks ...`: nothing to read

    const root = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            p.malformed = true;
            return p;
        },
    };
    if (root != .object) {
        p.malformed = true;
        return p;
    }
    try extract(&p, a, root.object);
    return p;
}

fn extract(p: *Payload, a: Allocator, root: std.json.ObjectMap) Allocator.Error!void {
    var scopes_buf: [1 + 2 * nested_containers.len + 1]std.json.ObjectMap = undefined;
    const scopes = collectScopes(root, &scopes_buf);

    p.hook_event_name = try findString(a, scopes, &keys_event, max_name_bytes);
    p.session_id = try findSessionId(a, root, scopes);
    p.transcript_path = try findString(a, scopes, &keys_transcript, max_path_bytes);
    p.cwd = try findString(a, scopes, &keys_cwd, max_path_bytes) orelse
        try findFirstArrayString(a, scopes, &keys_roots, max_path_bytes);
    p.tool_name = try findString(a, scopes, &keys_tool, max_name_bytes) orelse
        try findNestedToolName(a, root);
    p.message = try findString(a, scopes, &keys_message, max_text_bytes);
    p.title = try findString(a, scopes, &.{"title"}, max_text_bytes);
    p.error_text = try findErrorText(a, scopes);
    p.notification_type = try findString(a, scopes, &keys_notification_type, max_name_bytes);
    p.permission_mode = try findString(a, scopes, &keys_permission, max_name_bytes);
    p.last_assistant_message = try findString(a, scopes, &keys_last_message, max_text_bytes);
    p.source = try findString(a, scopes, &.{"source"}, max_name_bytes);
    p.reason = try findString(a, scopes, &.{"reason"}, max_text_bytes);
    p.status = try findStatus(a, scopes);
    p.matcher = try findString(a, scopes, &.{"matcher"}, max_name_bytes);
    p.model = try findModel(a, scopes);
    p.turn_id = try findString(a, scopes, &keys_turn, max_id_bytes);
    p.stop_hook_active = findBool(scopes, &.{ "stop_hook_active", "stopHookActive" }) orelse false;

    if (findRaw(scopes, &keys_prompt)) |v| {
        if (v == .string) p.prompt_length = countCodepoints(v.string);
    }

    p.is_subagent = (findBool(scopes, &keys_subagent_flags) orelse false) or
        (findRaw(scopes, &keys_subagent_ids) != null and !isEmptyValue(findRaw(scopes, &keys_subagent_ids).?));
    p.agent_id = try findString(a, scopes, &keys_agent_id, max_id_bytes);
    p.failed = findBool(scopes, &.{"failed"}) orelse false;
    p.recoverable = findBool(scopes, &.{"recoverable"});

    if (try toolInputObject(a, scopes)) |ti| {
        const ti_scope = [_]std.json.ObjectMap{ti};
        p.tool_command = try findString(a, &ti_scope, &.{ "command", "cmd" }, max_text_bytes);
        p.tool_message = try findString(a, &ti_scope, &.{"message"}, max_text_bytes);
        p.run_in_background = findBool(&ti_scope, &.{ "run_in_background", "runInBackground" }) orelse false;
    }
    if (p.tool_command == null) p.tool_command = try findString(a, scopes, &.{"command"}, max_text_bytes);

    if (findRaw(scopes, &keys_tool_response)) |v| p.push_skipped = valueMentionsSkip(v, 0);
}

fn collectScopes(root: std.json.ObjectMap, buf: []std.json.ObjectMap) []const std.json.ObjectMap {
    var n: usize = 0;
    buf[n] = root;
    n += 1;
    for (nested_containers) |key| {
        const v = root.get(key) orelse continue;
        if (v != .object) continue;
        buf[n] = v.object;
        n += 1;
        if (v.object.get("info")) |info| {
            if (info == .object) {
                buf[n] = info.object;
                n += 1;
            }
        }
    }
    return buf[0..n];
}

fn findRaw(scopes: []const std.json.ObjectMap, keys: []const []const u8) ?std.json.Value {
    for (scopes) |obj| {
        for (keys) |k| {
            const v = obj.get(k) orelse continue;
            if (v == .null) continue;
            return v;
        }
    }
    return null;
}

fn findString(a: Allocator, scopes: []const std.json.ObjectMap, keys: []const []const u8, cap: usize) Allocator.Error!?[]const u8 {
    for (scopes) |obj| {
        for (keys) |k| {
            const v = obj.get(k) orelse continue;
            switch (v) {
                .string => |s| if (std.mem.trim(u8, s, " \t\r\n").len > 0) return try dupeCapped(a, s, cap),
                .integer => |i| return try std.fmt.allocPrint(a, "{d}", .{i}),
                .number_string => |s| return try dupeCapped(a, s, cap),
                else => {},
            }
        }
    }
    return null;
}

fn findBool(scopes: []const std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (scopes) |obj| {
        for (keys) |k| {
            const v = obj.get(k) orelse continue;
            switch (v) {
                .bool => |b| return b,
                .string => |s| {
                    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
                    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
                },
                .integer => |i| return i != 0,
                else => {},
            }
        }
    }
    return null;
}

fn findFirstArrayString(a: Allocator, scopes: []const std.json.ObjectMap, keys: []const []const u8, cap: usize) Allocator.Error!?[]const u8 {
    const v = findRaw(scopes, keys) orelse return null;
    if (v != .array) return null;
    for (v.array.items) |item| {
        if (item == .string and item.string.len > 0) return try dupeCapped(a, item.string, cap);
    }
    return null;
}

/// Session ids: the alias table, then Amp's `thread.id`, then an OpenCode
/// `session.*` event's `properties.info.id`.
fn findSessionId(a: Allocator, root: std.json.ObjectMap, scopes: []const std.json.ObjectMap) Allocator.Error!?[]const u8 {
    if (try findString(a, scopes, &keys_session, max_id_bytes)) |s| return s;
    if (root.get("thread")) |thread| {
        if (thread == .object) {
            const scope = [_]std.json.ObjectMap{thread.object};
            if (try findString(a, &scope, &.{"id"}, max_id_bytes)) |s| return s;
        }
    }
    const props = root.get("properties") orelse return null;
    if (props != .object) return null;
    const info = props.object.get("info") orelse return null;
    if (info != .object) return null;
    const scope = [_]std.json.ObjectMap{info.object};
    return findString(a, &scope, &.{"id"}, max_id_bytes);
}

/// `error` may be a string or an object with a `message` (OpenCode nests
/// it as `{name, data: {message}}`).
fn findErrorText(a: Allocator, scopes: []const std.json.ObjectMap) Allocator.Error!?[]const u8 {
    const v = findRaw(scopes, &keys_error) orelse return null;
    switch (v) {
        .string => |s| return if (s.len > 0) try dupeCapped(a, s, max_text_bytes) else null,
        .object => |o| {
            const scope = [_]std.json.ObjectMap{o};
            if (try findString(a, &scope, &.{"message"}, max_text_bytes)) |m| return m;
            if (o.get("data")) |data| {
                if (data == .object) {
                    const data_scope = [_]std.json.ObjectMap{data.object};
                    if (try findString(a, &data_scope, &.{"message"}, max_text_bytes)) |m| return m;
                }
            }
            return (try findString(a, &scope, &.{ "name", "type" }, max_text_bytes)) orelse
                try a.dupe(u8, "error");
        },
        .bool => |b| return if (b) try a.dupe(u8, "error") else null,
        else => return null,
    }
}

/// `status` may be a string or an object `{type}` (OpenCode
/// `session.status`); Antigravity's Stop reports `terminationReason`.
fn findStatus(a: Allocator, scopes: []const std.json.ObjectMap) Allocator.Error!?[]const u8 {
    for (scopes) |obj| {
        for (keys_status) |k| {
            const v = obj.get(k) orelse continue;
            switch (v) {
                .string => |s| if (s.len > 0) return try dupeCapped(a, s, max_name_bytes),
                .object => |o| {
                    const scope = [_]std.json.ObjectMap{o};
                    if (try findString(a, &scope, &.{"type"}, max_name_bytes)) |t| return t;
                },
                else => {},
            }
        }
    }
    return null;
}

/// Tool names that live below the top level: Antigravity `toolCall.name`,
/// Rovo Dev `attributes.tool_calls[0].tool_name` (or `tool_results[0]`).
fn findNestedToolName(a: Allocator, root: std.json.ObjectMap) Allocator.Error!?[]const u8 {
    if (root.get("toolCall")) |tc| {
        if (tc == .object) {
            const scope = [_]std.json.ObjectMap{tc.object};
            if (try findString(a, &scope, &.{ "name", "tool_name", "toolName" }, max_name_bytes)) |s| return s;
        }
    }
    const attrs = root.get("attributes") orelse return null;
    if (attrs != .object) return null;
    for ([_][]const u8{ "tool_calls", "tool_results" }) |key| {
        const arr = attrs.object.get(key) orelse continue;
        if (arr != .array) continue;
        for (arr.array.items) |item| {
            if (item != .object) continue;
            const scope = [_]std.json.ObjectMap{item.object};
            if (try findString(a, &scope, &.{ "tool_name", "toolName", "name" }, max_name_bytes)) |s| return s;
        }
    }
    return null;
}

/// `model` may be a string or an object `{id|name|display_name}`.
fn findModel(a: Allocator, scopes: []const std.json.ObjectMap) Allocator.Error!?[]const u8 {
    const v = findRaw(scopes, &.{"model"}) orelse return null;
    switch (v) {
        .string => |s| return if (s.len > 0) try dupeCapped(a, s, max_name_bytes) else null,
        .object => |o| {
            const scope = [_]std.json.ObjectMap{o};
            return findString(a, &scope, &.{ "id", "name", "display_name", "displayName" }, max_name_bytes);
        },
        else => return null,
    }
}

/// `tool_input` as an object; a JSON-encoded string (Copilot `toolArgs`) is
/// decoded. Antigravity nests it as `toolCall.args`.
fn toolInputObject(a: Allocator, scopes: []const std.json.ObjectMap) Allocator.Error!?std.json.ObjectMap {
    const v = findRaw(scopes, &keys_tool_input) orelse blk: {
        const tc = scopes[0].get("toolCall") orelse return null;
        if (tc != .object) return null;
        break :blk tc.object.get("args") orelse return null;
    };
    switch (v) {
        .object => |o| return o,
        .string => |s| {
            const inner = std.json.parseFromSliceLeaky(std.json.Value, a, s, .{
                .duplicate_field_behavior = .use_last,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            return if (inner == .object) inner.object else null;
        },
        else => return null,
    }
}

fn isEmptyValue(v: std.json.Value) bool {
    return switch (v) {
        .null => true,
        .string => |s| s.len == 0,
        .bool => |b| !b,
        else => false,
    };
}

/// Array nesting levels of a tool response searched for a skip outcome.
/// std.json parses any depth, so the scan must stop on its own: a payload
/// of nested arrays under the stdin cap would otherwise overflow the stack.
const max_skip_scan_depth: usize = 8;

/// True when a tool response (a string, the string members of an object,
/// or such values inside arrays up to `max_skip_scan_depth` levels deep)
/// names one of the PushNotification skip outcomes.
fn valueMentionsSkip(v: std.json.Value, depth: usize) bool {
    switch (v) {
        .string => |s| return std.mem.indexOf(u8, s, "user_present") != null or
            std.mem.indexOf(u8, s, "config_off") != null,
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .string and valueMentionsSkip(e.value_ptr.*, depth)) return true;
            }
            return false;
        },
        .array => |arr| {
            if (depth >= max_skip_scan_depth) return false;
            for (arr.items) |item| if (valueMentionsSkip(item, depth + 1)) return true;
            return false;
        },
        else => return false,
    }
}

/// Codex's legacy `notify` program receives its JSON as the last argv
/// element (stdin is null). Returns that element when it looks like a JSON
/// object, so the CLI can hand it to `parse` instead of empty stdin.
/// Register that program with the `stop` subcommand (or the native
/// `agent-turn-complete` name), not `notify`: `notify` is cmux's alias of
/// `notification`, the payload never turns a subcommand into a stop, and a
/// finished turn would read as needs-input.
pub fn argvPayload(args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    const last = args[args.len - 1];
    const t = std.mem.trim(u8, last, " \t\r\n");
    if (t.len < 2 or t[0] != '{') return null;
    return last;
}

fn countCodepoints(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn dupeCapped(a: Allocator, s: []const u8, cap: usize) Allocator.Error![]const u8 {
    return a.dupe(u8, truncateUtf8(s, cap));
}

/// Longest prefix of `s` that is at most `cap` bytes and does not split a
/// UTF-8 sequence.
pub fn truncateUtf8(s: []const u8, cap: usize) []const u8 {
    if (s.len <= cap) return s;
    var end = cap;
    // Back up over continuation bytes (10xxxxxx) to a sequence start.
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}
