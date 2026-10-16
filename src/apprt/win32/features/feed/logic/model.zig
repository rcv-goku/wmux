//! Feed item model (pure): kinds, statuses, decision modes, resolutions and
//! the mapping from an agent hook event (the `event` object of `feed.push`)
//! to a `*Item`. Every item owns its strings in a private arena, so one
//! `destroy` frees everything. Text fields are capped on code-point
//! boundaries (G6); list lengths are bounded only by the hook input size.

const std = @import("std");
const proto = @import("wmux_proto");
const Uuid = proto.uuid.Uuid;
const utf8 = proto.utf8;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Byte caps for text taken from hook input.
pub const caps = struct {
    pub const title: usize = 512;
    pub const detail: usize = 4096;
    /// Prompt echo, assistant message, notification body, plan text.
    pub const text: usize = 64 * 1024;
    pub const short: usize = 1024;
    /// Raw `tool_input` kept for reply builders (Claude's AskUserQuestion
    /// answer echoes the original input). Matches `max_prompt_length`.
    pub const tool_input: usize = @intCast(proto.events_catalog.max_prompt_length);
};

/// Feed item kind. Wire names are cmux's `feed.list` kinds where cmux defines
/// them (`permissionRequest`, `exitPlan`, `question`); the activity kinds use
/// the same camelCase style.
pub const Kind = enum {
    permission_request,
    exit_plan,
    question,
    stop,
    todos,
    notification,
    message,
    prompt,
    tool_use,
    tool_result,
    session_start,
    session_end,

    const names = [_][]const u8{ "permissionRequest", "exitPlan", "question", "stop", "todos", "notification", "message", "prompt", "toolUse", "toolResult", "sessionStart", "sessionEnd" };

    pub fn wire(k: Kind) []const u8 {
        return names[@intFromEnum(k)];
    }

    pub fn parse(s: []const u8) ?Kind {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }

    /// Kinds that ask a human for a decision (cards under "Actionable").
    pub fn isDecision(k: Kind) bool {
        return switch (k) {
            .permission_request, .exit_plan, .question => true,
            else => false,
        };
    }

    /// Upper-case card label of the panel.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .permission_request => "PERMISSION",
            .exit_plan => "PLAN",
            .question => "QUESTION",
            .stop => "STOP",
            .todos => "TODOS",
            .notification => "NOTIFICATION",
            .message => "MESSAGE",
            .prompt => "PROMPT",
            .tool_use => "TOOL USE",
            .tool_result => "TOOL RESULT",
            .session_start => "SESSION START",
            .session_end => "SESSION END",
        };
    }
};

pub const Status = enum {
    /// A decision waiting for the user.
    pending,
    /// A decision answered from Feed, a banner or the socket.
    resolved,
    /// The soft wait ran out; the agent fell back to its own prompt.
    timed_out,
    /// The agent process exited, or the request was decided outside wmux.
    expired,
    /// Informational activity (never actionable).
    info,

    const names = [_][]const u8{ "pending", "resolved", "timedOut", "expired", "info" };

    pub fn wire(s: Status) []const u8 {
        return names[@intFromEnum(s)];
    }

    pub fn parse(s: []const u8) ?Status {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }

    pub fn isTerminal(s: Status) bool {
        return s != .pending;
    }
};

/// `feed.permission.reply` modes.
pub const PermissionMode = enum {
    once,
    always,
    all,
    bypass,
    deny,

    pub const invalid_message = "feed.permission.reply requires mode \u{2208} once|always|all|bypass|deny";

    pub fn wire(m: PermissionMode) []const u8 {
        return @tagName(m);
    }

    pub fn parse(s: []const u8) ?PermissionMode {
        return std.meta.stringToEnum(PermissionMode, s);
    }

    /// Resolved-card badge.
    pub fn badge(m: PermissionMode) []const u8 {
        return switch (m) {
            .once => "once",
            .always => "always",
            .all => "all tools",
            .bypass => "bypass",
            .deny => "denied",
        };
    }

    pub fn allows(m: PermissionMode) bool {
        return m != .deny;
    }
};

/// `feed.exit_plan.reply` modes.
pub const ExitPlanMode = enum {
    ultraplan,
    bypass_permissions,
    auto_accept,
    manual,
    deny,

    const names = [_][]const u8{ "ultraplan", "bypassPermissions", "autoAccept", "manual", "deny" };

    /// wmux wording, modeled on the permission-reply message (cmux's exact
    /// text for this method is not in the inventory).
    pub const invalid_message = "feed.exit_plan.reply requires mode \u{2208} ultraplan|bypassPermissions|autoAccept|manual|deny";

    pub fn wire(m: ExitPlanMode) []const u8 {
        return names[@intFromEnum(m)];
    }

    pub fn parse(s: []const u8) ?ExitPlanMode {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }

    pub fn badge(m: ExitPlanMode) []const u8 {
        return switch (m) {
            .ultraplan => "ultraplan",
            .bypass_permissions => "bypass",
            .auto_accept => "auto",
            .manual => "manual",
            .deny => "denied",
        };
    }
};

/// Set of decision buttons an item supports ("buttons shown only when the
/// source agent/tool input supports them").
pub const PermissionModes = packed struct(u5) {
    once: bool = true,
    always: bool = false,
    all: bool = false,
    bypass: bool = false,
    deny: bool = true,

    pub fn has(self: PermissionModes, m: PermissionMode) bool {
        return switch (m) {
            .once => self.once,
            .always => self.always,
            .all => self.all,
            .bypass => self.bypass,
            .deny => self.deny,
        };
    }
};

pub const ExitPlanModes = packed struct(u5) {
    ultraplan: bool = false,
    bypass_permissions: bool = false,
    auto_accept: bool = false,
    manual: bool = true,
    deny: bool = true,

    pub fn has(self: ExitPlanModes, m: ExitPlanMode) bool {
        return switch (m) {
            .ultraplan => self.ultraplan,
            .bypass_permissions => self.bypass_permissions,
            .auto_accept => self.auto_accept,
            .manual => self.manual,
            .deny => self.deny,
        };
    }
};

pub const Resolution = union(enum) {
    permission: PermissionMode,
    exit_plan: struct { mode: ExitPlanMode, feedback: ?[]const u8 = null },
    question: struct { selections: []const []const u8 },
    /// Stop card "Send to Claude" text.
    reply: []const u8,

    pub fn badge(r: Resolution) []const u8 {
        return switch (r) {
            .permission => |m| m.badge(),
            .exit_plan => |p| if (p.mode == .deny and p.feedback != null) "refined" else p.mode.badge(),
            .question => "Submitted",
            .reply => "Sent",
        };
    }

    /// Kind of item this resolution answers.
    pub fn answers(r: Resolution) Kind {
        return switch (r) {
            .permission => .permission_request,
            .exit_plan => .exit_plan,
            .question => .question,
            .reply => .stop,
        };
    }

    pub fn eql(a: Resolution, b: Resolution) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .permission => |m| m == b.permission,
            .exit_plan => |p| p.mode == b.exit_plan.mode and optEql(p.feedback, b.exit_plan.feedback),
            .question => |q| blk: {
                const o = b.question.selections;
                if (q.selections.len != o.len) break :blk false;
                for (q.selections, o) |x, y| if (!std.mem.eql(u8, x, y)) break :blk false;
                break :blk true;
            },
            .reply => |t| std.mem.eql(u8, t, b.reply),
        };
    }

    /// Deep copy into `a`.
    pub fn dupe(r: Resolution, a: Allocator) Allocator.Error!Resolution {
        return switch (r) {
            .permission => r,
            .exit_plan => |p| .{ .exit_plan = .{ .mode = p.mode, .feedback = if (p.feedback) |f| try utf8.dupeTruncated(a, f, caps.text) else null } },
            .question => |q| blk: {
                const out = try a.alloc([]const u8, q.selections.len);
                for (q.selections, out) |s, *o| o.* = try utf8.dupeTruncated(a, s, caps.short);
                break :blk .{ .question = .{ .selections = out } };
            },
            .reply => |t| .{ .reply = try utf8.dupeTruncated(a, t, caps.text) },
        };
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const QuestionOption = struct {
    label: []const u8,
    description: []const u8 = "",
};

pub const Question = struct {
    question: []const u8,
    header: []const u8 = "",
    multi_select: bool = false,
    /// Empty: the card shows "Agent provided no options." plus free text.
    options: []const QuestionOption = &.{},
};

pub const Plan = struct {
    text: []const u8 = "",
    file_path: ?[]const u8 = null,
    allowed_prompts: []const []const u8 = &.{},
};

pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn parse(s: []const u8) TodoStatus {
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        return .pending;
    }

    pub fn wire(s: TodoStatus) []const u8 {
        return @tagName(s);
    }
};

pub const Todo = struct {
    content: []const u8,
    status: TodoStatus = .pending,
    active_form: []const u8 = "",
};

pub const TodoSummary = struct {
    open: usize = 0,
    in_progress: usize = 0,
    done: usize = 0,

    pub fn of(todos: []const Todo) TodoSummary {
        var s: TodoSummary = .{};
        for (todos) |t| switch (t.status) {
            .pending => s.open += 1,
            .in_progress => s.in_progress += 1,
            .completed => s.done += 1,
        };
        return s;
    }

    /// "2 open, 1 in progress, 3 done"; zero parts are omitted; an empty
    /// list reads "0 open".
    pub fn format(s: TodoSummary, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        const parts = [_]struct { n: usize, word: []const u8 }{
            .{ .n = s.open, .word = "open" },
            .{ .n = s.in_progress, .word = "in progress" },
            .{ .n = s.done, .word = "done" },
        };
        for (parts) |p| {
            if (p.n == 0) continue;
            if (!first) try w.writeAll(", ");
            try w.print("{d} {s}", .{ p.n, p.word });
            first = false;
        }
        if (first) try w.writeAll("0 open");
    }
};

pub const Item = struct {
    arena: std.heap.ArenaAllocator,
    id: Uuid,
    kind: Kind,
    status: Status,
    /// Agent name from `--source` (`claude`, `codex`, ...), lower case.
    source: []const u8,
    hook_event_name: []const u8,
    request_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    workspace_id: ?Uuid = null,
    surface_id: ?Uuid = null,
    /// Agent process id, for dead-agent expiry.
    pid: ?u32 = null,
    tool_name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    title: []const u8 = "",
    detail: []const u8 = "",
    /// Prompt echo ("You: ..."), assistant message, notification body.
    text: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    resolved_at_ms: ?i64 = null,
    questions: []const Question = &.{},
    plan: ?Plan = null,
    todos: []const Todo = &.{},
    permission_modes: PermissionModes = .{},
    exit_plan_modes: ExitPlanModes = .{},
    /// TOOL RESULT ok/error.
    tool_error: ?bool = null,
    tool_input_json: ?[]const u8 = null,
    resolution: ?Resolution = null,

    /// Creates an empty item; strings set later must live in `item.allocator()`.
    pub fn create(gpa: Allocator, id: Uuid, kind: Kind, now_ms: i64) Allocator.Error!*Item {
        const self = try gpa.create(Item);
        self.* = .{
            .arena = .init(gpa),
            .id = id,
            .kind = kind,
            .status = if (kind.isDecision()) .pending else .info,
            .source = "",
            .hook_event_name = "",
            .created_at_ms = now_ms,
            .updated_at_ms = now_ms,
        };
        return self;
    }

    pub fn destroy(self: *Item) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn allocator(self: *Item) Allocator {
        return self.arena.allocator();
    }

    pub fn isPending(self: *const Item) bool {
        return self.status == .pending;
    }

    /// Records a resolution (copied into the item). Pure state change; the
    /// decision lifecycle (idempotence, waking the hook) lives in decisions.zig.
    pub fn resolve(self: *Item, r: Resolution, now_ms: i64) error{ OutOfMemory, KindMismatch, NotPending, UnsupportedMode }!void {
        if (self.status != .pending and !(self.kind == .stop and self.resolution == null)) return error.NotPending;
        if (r.answers() != self.kind) return error.KindMismatch;
        switch (r) {
            .permission => |m| if (!self.permission_modes.has(m)) return error.UnsupportedMode,
            .exit_plan => |p| if (!self.exit_plan_modes.has(p.mode)) return error.UnsupportedMode,
            else => {},
        }
        self.resolution = try r.dupe(self.allocator());
        if (self.kind.isDecision()) self.status = .resolved;
        self.resolved_at_ms = now_ms;
        self.updated_at_ms = now_ms;
    }

    /// Terminal transition without a user answer (timeout, expiry).
    pub fn close(self: *Item, status: Status, now_ms: i64) void {
        std.debug.assert(status == .timed_out or status == .expired);
        if (self.status != .pending) return;
        self.status = status;
        self.updated_at_ms = now_ms;
    }

    /// Deep copy (fresh arena).
    pub fn clone(self: *const Item, gpa: Allocator) Allocator.Error!*Item {
        const out = try Item.create(gpa, self.id, self.kind, self.created_at_ms);
        errdefer out.destroy();
        const a = out.allocator();
        const arena = out.arena;
        out.* = self.*;
        out.arena = arena;
        out.source = try a.dupe(u8, self.source);
        out.hook_event_name = try a.dupe(u8, self.hook_event_name);
        out.request_id = try dupeOpt(a, self.request_id);
        out.session_id = try dupeOpt(a, self.session_id);
        out.tool_name = try dupeOpt(a, self.tool_name);
        out.cwd = try dupeOpt(a, self.cwd);
        out.title = try a.dupe(u8, self.title);
        out.detail = try a.dupe(u8, self.detail);
        out.text = try dupeOpt(a, self.text);
        out.tool_input_json = try dupeOpt(a, self.tool_input_json);
        out.questions = try dupeQuestions(a, self.questions);
        out.plan = if (self.plan) |p| try dupePlan(a, p) else null;
        out.todos = try dupeTodos(a, self.todos);
        out.resolution = if (self.resolution) |r| try r.dupe(a) else null;
        return out;
    }
};

fn dupeOpt(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |v| try a.dupe(u8, v) else null;
}

fn dupeQuestions(a: Allocator, qs: []const Question) Allocator.Error![]const Question {
    const out = try a.alloc(Question, qs.len);
    for (qs, out) |q, *o| {
        const opts = try a.alloc(QuestionOption, q.options.len);
        for (q.options, opts) |src, *dst| dst.* = .{ .label = try a.dupe(u8, src.label), .description = try a.dupe(u8, src.description) };
        o.* = .{ .question = try a.dupe(u8, q.question), .header = try a.dupe(u8, q.header), .multi_select = q.multi_select, .options = opts };
    }
    return out;
}

fn dupePlan(a: Allocator, p: Plan) Allocator.Error!Plan {
    const prompts = try a.alloc([]const u8, p.allowed_prompts.len);
    for (p.allowed_prompts, prompts) |s, *d| d.* = try a.dupe(u8, s);
    return .{ .text = try a.dupe(u8, p.text), .file_path = try dupeOpt(a, p.file_path), .allowed_prompts = prompts };
}

fn dupeTodos(a: Allocator, ts: []const Todo) Allocator.Error![]const Todo {
    const out = try a.alloc(Todo, ts.len);
    for (ts, out) |t, *o| o.* = .{ .content = try a.dupe(u8, t.content), .status = t.status, .active_form = try a.dupe(u8, t.active_form) };
    return out;
}

// ---------------------------------------------------------------------------
// Sources and classification

/// Display name of a `--source` value ("claude" -> "Claude").
pub fn sourceDisplayName(source: []const u8) []const u8 {
    const table = std.StaticStringMap([]const u8).initComptime(.{
        .{ "claude", "Claude" },       .{ "codex", "Codex" },       .{ "grok", "Grok" },
        .{ "hermes", "Hermes" },       .{ "opencode", "OpenCode" }, .{ "cursor", "Cursor" },
        .{ "gemini", "Gemini" },       .{ "kiro", "Kiro" },         .{ "copilot", "Copilot" },
        .{ "codebuddy", "CodeBuddy" }, .{ "factory", "Factory" },   .{ "qoder", "Qoder" },
        .{ "kimi", "Kimi" },           .{ "pi", "Pi" },             .{ "omp", "OMP" },
        .{ "campfire", "Campfire" },   .{ "rovodev", "Rovo Dev" },  .{ "rovo", "Rovo Dev" },
    });
    if (table.get(source)) |n| return n;
    return if (source.len == 0) "Agent" else source;
}

/// Sources whose permission hooks are non-blocking telemetry (Codex keeps
/// its own approval UI; codex-teams bridges arrive with `blocking = true`).
pub fn isTelemetryOnlySource(source: []const u8) bool {
    return std.ascii.eqlIgnoreCase(source, "codex");
}

fn eqlAny(s: []const u8, comptime set: []const []const u8) bool {
    inline for (set) |c| if (std.ascii.eqlIgnoreCase(s, c)) return true;
    return false;
}

/// Maps a native hook event name (any supported agent) plus tool name to a
/// feed kind.
pub fn classify(hook_event_name: []const u8, tool_name: ?[]const u8) Kind {
    const tool = tool_name orelse "";
    const permission_events = &[_][]const u8{ "PermissionRequest", "permission.asked", "permission_request", "beforeShellExecution", "beforeMCPExecution", "pre_approval_request" };
    const pre_tool = &[_][]const u8{ "PreToolUse", "preToolUse", "pre_tool_call", "tool_execution_start", "BeforeTool", "tool.execute.before" };
    const post_tool = &[_][]const u8{ "PostToolUse", "postToolUse", "post_tool_call", "tool_execution_end", "AfterTool", "tool.execute.after", "post_approval_response", "PostToolUseFailure" };
    if (eqlAny(hook_event_name, permission_events)) {
        if (std.mem.eql(u8, tool, "ExitPlanMode")) return .exit_plan;
        if (std.mem.eql(u8, tool, "AskUserQuestion")) return .question;
        return .permission_request;
    }
    if (eqlAny(hook_event_name, pre_tool)) {
        if (std.mem.eql(u8, tool, "TodoWrite")) return .todos;
        if (std.mem.eql(u8, tool, "ExitPlanMode")) return .exit_plan;
        if (std.mem.eql(u8, tool, "AskUserQuestion")) return .question;
        return .tool_use;
    }
    if (eqlAny(hook_event_name, post_tool)) return .tool_result;
    if (eqlAny(hook_event_name, &.{ "Stop", "SubagentStop", "stop", "session.idle", "AfterAgent" })) return .stop;
    if (eqlAny(hook_event_name, &.{ "Notification", "notification" })) return .notification;
    if (eqlAny(hook_event_name, &.{ "UserPromptSubmit", "userPromptSubmit", "beforeSubmitPrompt", "BeforeAgent" })) return .prompt;
    if (eqlAny(hook_event_name, &.{ "SessionStart", "sessionStart", "session_start", "session.created" })) return .session_start;
    if (eqlAny(hook_event_name, &.{ "SessionEnd", "sessionEnd", "session_end", "session.deleted" })) return .session_end;
    return .message;
}

/// Native-banner text for a pending decision (title, body).
pub const Banner = struct { title: []const u8, body: []const u8 };

pub fn bannerText(a: Allocator, item: *const Item) Allocator.Error!?Banner {
    const name = sourceDisplayName(item.source);
    return switch (item.kind) {
        .permission_request => .{
            .title = try std.fmt.allocPrint(a, "{s} permission", .{name}),
            .body = if (item.tool_name) |t| try std.fmt.allocPrint(a, "{s} needs approval", .{t}) else try a.dupe(u8, "Decision needed"),
        },
        .exit_plan => .{ .title = try std.fmt.allocPrint(a, "{s} plan ready", .{name}), .body = try a.dupe(u8, "Review and approve the plan") },
        .question => .{ .title = try std.fmt.allocPrint(a, "{s} question", .{name}), .body = try a.dupe(u8, "Agent is asking a question") },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Hook event -> item

pub const FromEventOptions = struct {
    id: Uuid,
    now_ms: i64,
    /// `feed.push` top-level `request_id`; wins over the event's own.
    request_id: ?[]const u8 = null,
    /// `--source` when the event lacks `source`/`_source`.
    source: ?[]const u8 = null,
    /// `--event` when the event lacks `hook_event_name`.
    event_name: ?[]const u8 = null,
};

pub const FromEventError = error{ OutOfMemory, InvalidEvent, MissingHookEventName };

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getStrAny(obj: std.json.ObjectMap, comptime keys: []const []const u8) ?[]const u8 {
    inline for (keys) |k| if (getStr(obj, k)) |s| if (s.len > 0) return s;
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn getObj(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn getArr(obj: std.json.ObjectMap, key: []const u8) ?[]const Value {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn getUuid(obj: std.json.ObjectMap, comptime keys: []const []const u8) ?Uuid {
    const s = getStrAny(obj, keys) orelse return null;
    return Uuid.parse(s) catch null;
}

fn getPid(obj: std.json.ObjectMap) ?u32 {
    inline for (.{ "pid", "_pid", "agent_pid" }) |k| {
        if (obj.get(k)) |v| switch (v) {
            .integer => |n| if (n > 0 and n <= std.math.maxInt(u32)) return @intCast(n),
            .string => |s| if (std.fmt.parseInt(u32, s, 10)) |n| {
                if (n > 0) return n;
            } else |_| {},
            else => {},
        };
    }
    return null;
}

/// First line of `s`, trimmed.
fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfAny(u8, t, "\r\n") orelse t.len;
    return std.mem.trimRight(u8, t[0..end], " \t");
}

fn capDupe(a: Allocator, s: []const u8, cap: usize) Allocator.Error![]const u8 {
    return utf8.dupeTruncatedEllipsis(a, s, cap);
}

fn lowerDupe(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const t = utf8.truncateUtf8(s, 64);
    const out = try a.alloc(u8, t.len);
    for (t, out) |c, *o| o.* = std.ascii.toLower(c);
    return out;
}

/// Builds an item from a hook event object. `ev` stays owned by the caller.
pub fn fromEvent(gpa: Allocator, ev: Value, opts: FromEventOptions) FromEventError!*Item {
    const obj = switch (ev) {
        .object => |o| o,
        else => return error.InvalidEvent,
    };
    const event_name = getStrAny(obj, &.{"hook_event_name"}) orelse opts.event_name orelse return error.MissingHookEventName;
    if (event_name.len == 0) return error.MissingHookEventName;
    const tool_name = getStrAny(obj, &.{ "tool_name", "tool" });
    const kind = classify(event_name, tool_name);

    const item = try Item.create(gpa, opts.id, kind, opts.now_ms);
    errdefer item.destroy();
    const a = item.allocator();

    item.hook_event_name = try a.dupe(u8, utf8.truncateUtf8(event_name, caps.short));
    item.source = try lowerDupe(a, getStrAny(obj, &.{ "source", "_source" }) orelse opts.source orelse "unknown");
    item.tool_name = if (tool_name) |t| try a.dupe(u8, utf8.truncateUtf8(t, caps.short)) else null;
    const rid = opts.request_id orelse getStrAny(obj, &.{ "request_id", "_opencode_request_id" });
    item.request_id = if (rid) |r| try a.dupe(u8, utf8.truncateUtf8(r, caps.short)) else null;
    if (getStrAny(obj, &.{"session_id"})) |s| item.session_id = try a.dupe(u8, utf8.truncateUtf8(s, caps.short));
    if (getStrAny(obj, &.{"cwd"})) |s| item.cwd = try a.dupe(u8, utf8.truncateUtf8(s, caps.detail));
    item.workspace_id = getUuid(obj, &.{ "workspace_id", "_workspace_id" });
    item.surface_id = getUuid(obj, &.{ "surface_id", "_surface_id" });
    item.pid = getPid(obj);

    const input = getObj(obj, "tool_input");
    if (obj.get("tool_input")) |ti| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        std.json.Stringify.value(ti, .{}, &aw.writer) catch return error.OutOfMemory;
        // Larger inputs are dropped rather than cut (cut JSON is useless).
        if (aw.written().len <= caps.tool_input) item.tool_input_json = try a.dupe(u8, aw.written());
    }

    const name = sourceDisplayName(item.source);
    switch (kind) {
        .permission_request => {
            item.title = try capDupe(a, tool_name orelse "Permission", caps.title);
            item.detail = try capDupe(a, permissionDetail(input) orelse tool_name orelse "", caps.detail);
            const claude = std.mem.eql(u8, item.source, "claude");
            const has_rule = if (obj.get("permission_suggestions")) |s| switch (s) {
                .array => |arr| arr.items.len > 0,
                .object => true,
                else => false,
            } else false;
            item.permission_modes = .{ .always = has_rule, .all = has_rule, .bypass = claude };
        },
        .exit_plan => {
            const p = try parsePlan(a, input);
            item.plan = p;
            item.title = try std.fmt.allocPrint(a, "{s} plan ready", .{name});
            item.detail = try capDupe(a, firstLine(p.text), caps.detail);
            const claude = std.mem.eql(u8, item.source, "claude");
            item.exit_plan_modes = .{ .ultraplan = claude, .bypass_permissions = claude, .auto_accept = claude };
        },
        .question => {
            item.questions = try parseQuestions(a, input);
            item.title = try std.fmt.allocPrint(a, "{s} question", .{name});
            item.detail = if (item.questions.len > 0) try capDupe(a, item.questions[0].question, caps.detail) else "";
        },
        .todos => {
            item.todos = try parseTodos(a, input);
            item.title = "Tasks";
            var aw: std.Io.Writer.Allocating = .init(a);
            aw.writer.print("{f}", .{TodoSummary.of(item.todos)}) catch return error.OutOfMemory;
            item.detail = aw.written();
        },
        .stop => {
            item.title = try std.fmt.allocPrint(a, "{s} finished \u{2014} reply to continue", .{name});
            if (getStrAny(obj, &.{ "last_assistant_message", "message" })) |m| item.text = try capDupe(a, m, caps.text);
            item.detail = if (item.text) |t| try capDupe(a, firstLine(t), caps.detail) else "";
        },
        .notification => {
            item.title = try capDupe(a, getStrAny(obj, &.{"title"}) orelse name, caps.title);
            if (getStrAny(obj, &.{ "message", "body" })) |m| item.text = try capDupe(a, m, caps.text);
            item.detail = if (item.text) |t| try capDupe(a, firstLine(t), caps.detail) else "";
        },
        .prompt => {
            item.title = "You";
            if (getStrAny(obj, &.{ "prompt", "message" })) |m| item.text = try capDupe(a, m, caps.text);
            item.detail = if (item.text) |t| try std.fmt.allocPrint(a, "You: {s}", .{utf8.truncateUtf8(firstLine(t), caps.detail - 5)}) else "You:";
        },
        .tool_use => {
            item.title = try capDupe(a, tool_name orelse "Tool", caps.title);
            item.detail = try capDupe(a, permissionDetail(input) orelse "", caps.detail);
        },
        .tool_result => {
            item.title = try capDupe(a, tool_name orelse "Tool", caps.title);
            item.tool_error = toolError(obj);
            item.detail = if (item.tool_error orelse false) "error" else "ok";
        },
        .session_start => {
            item.title = "Session started";
            item.detail = try capDupe(a, getStrAny(obj, &.{"source_detail"}) orelse "", caps.detail);
        },
        .session_end => {
            item.title = "Session ended";
            item.detail = try capDupe(a, getStrAny(obj, &.{"reason"}) orelse "", caps.detail);
        },
        .message => {
            item.title = try capDupe(a, event_name, caps.title);
            if (getStrAny(obj, &.{ "message", "text", "content" })) |m| item.text = try capDupe(a, m, caps.text);
            item.detail = if (item.text) |t| try capDupe(a, firstLine(t), caps.detail) else "";
        },
    }
    return item;
}

/// One-line summary of a tool input (command, path, url, ...).
fn permissionDetail(input: ?std.json.ObjectMap) ?[]const u8 {
    const o = input orelse return null;
    return getStrAny(o, &.{ "command", "file_path", "path", "notebook_path", "url", "pattern", "query", "description", "prompt" });
}

fn toolError(obj: std.json.ObjectMap) bool {
    if (getBool(obj, "is_error")) |b| return b;
    if (getObj(obj, "tool_response")) |r| {
        if (getBool(r, "is_error")) |b| return b;
        if (getBool(r, "success")) |b| return !b;
        if (r.get("error")) |e| return e != .null;
    }
    if (getStr(obj, "error")) |_| return true;
    return false;
}

fn parsePlan(a: Allocator, input: ?std.json.ObjectMap) Allocator.Error!Plan {
    const o = input orelse return .{};
    var p: Plan = .{};
    if (getStr(o, "plan")) |t| p.text = try capDupe(a, t, caps.text);
    if (getStrAny(o, &.{ "planFilePath", "plan_file_path", "file_path" })) |f| p.file_path = try a.dupe(u8, utf8.truncateUtf8(f, caps.detail));
    if (getArr(o, "allowedPrompts")) |arr| {
        var list: std.ArrayList([]const u8) = .empty;
        for (arr) |v| switch (v) {
            .string => |s| try list.append(a, try capDupe(a, s, caps.short)),
            .object => |po| if (getStrAny(po, &.{ "prompt", "description" })) |s| {
                const tool = getStr(po, "tool");
                const line = if (tool) |t| try std.fmt.allocPrint(a, "{s}: {s}", .{ utf8.truncateUtf8(t, 64), utf8.truncateUtf8(s, caps.short) }) else try capDupe(a, s, caps.short);
                try list.append(a, line);
            },
            else => {},
        };
        p.allowed_prompts = list.items;
    }
    return p;
}

fn parseQuestions(a: Allocator, input: ?std.json.ObjectMap) Allocator.Error![]const Question {
    const o = input orelse return &.{};
    const arr = getArr(o, "questions") orelse {
        // Single-question shape.
        const q = getStr(o, "question") orelse return &.{};
        const out = try a.alloc(Question, 1);
        out[0] = .{ .question = try capDupe(a, q, caps.detail), .options = try parseOptions(a, getArr(o, "options")) };
        return out;
    };
    var list: std.ArrayList(Question) = .empty;
    for (arr) |v| {
        const qo = switch (v) {
            .object => |x| x,
            else => continue,
        };
        try list.append(a, .{
            .question = try capDupe(a, getStr(qo, "question") orelse "", caps.detail),
            .header = try capDupe(a, getStr(qo, "header") orelse "", caps.short),
            .multi_select = getBool(qo, "multiSelect") orelse getBool(qo, "multi_select") orelse false,
            .options = try parseOptions(a, getArr(qo, "options")),
        });
    }
    return list.items;
}

fn parseOptions(a: Allocator, arr: ?[]const Value) Allocator.Error![]const QuestionOption {
    const items = arr orelse return &.{};
    var list: std.ArrayList(QuestionOption) = .empty;
    for (items) |v| switch (v) {
        .string => |s| try list.append(a, .{ .label = try capDupe(a, s, caps.short) }),
        .object => |oo| if (getStr(oo, "label")) |l| try list.append(a, .{
            .label = try capDupe(a, l, caps.short),
            .description = try capDupe(a, getStr(oo, "description") orelse "", caps.detail),
        }),
        else => {},
    };
    return list.items;
}

fn parseTodos(a: Allocator, input: ?std.json.ObjectMap) Allocator.Error![]const Todo {
    const o = input orelse return &.{};
    const arr = getArr(o, "todos") orelse return &.{};
    var list: std.ArrayList(Todo) = .empty;
    for (arr) |v| {
        const to = switch (v) {
            .object => |x| x,
            else => continue,
        };
        const content = getStrAny(to, &.{ "content", "text", "title" }) orelse continue;
        try list.append(a, .{
            .content = try capDupe(a, content, caps.short),
            .status = TodoStatus.parse(getStr(to, "status") orelse ""),
            .active_form = try capDupe(a, getStr(to, "activeForm") orelse "", caps.short),
        });
    }
    return list.items;
}

/// Parses a `feed.permission.reply` / `feed.exit_plan.reply` /
/// `feed.question.reply` params object into a resolution. Strings in the
/// result borrow from `params`. Errors carry cmux's message via `replyErrorMessage`.
pub const ReplyError = error{ MissingRequestId, InvalidPermissionMode, InvalidExitPlanMode, InvalidSelections, OutOfMemory };

pub const Reply = struct { request_id: []const u8, resolution: Resolution };

pub const ReplyMethod = enum { permission, exit_plan, question };

pub fn parseReply(a: Allocator, method: ReplyMethod, params: Value) ReplyError!Reply {
    const obj = switch (params) {
        .object => |o| o,
        else => return error.MissingRequestId,
    };
    const rid = getStr(obj, "request_id") orelse return error.MissingRequestId;
    if (rid.len == 0) return error.MissingRequestId;
    switch (method) {
        .permission => {
            const m = PermissionMode.parse(getStr(obj, "mode") orelse "") orelse return error.InvalidPermissionMode;
            return .{ .request_id = rid, .resolution = .{ .permission = m } };
        },
        .exit_plan => {
            const m = ExitPlanMode.parse(getStr(obj, "mode") orelse "") orelse return error.InvalidExitPlanMode;
            const fb = getStr(obj, "feedback");
            return .{ .request_id = rid, .resolution = .{ .exit_plan = .{ .mode = m, .feedback = if (fb) |f| (if (f.len == 0) null else f) else null } } };
        },
        .question => {
            const arr = getArr(obj, "selections") orelse return error.InvalidSelections;
            const out = try a.alloc([]const u8, arr.len);
            for (arr, out) |v, *o| o.* = switch (v) {
                .string => |s| s,
                else => return error.InvalidSelections,
            };
            return .{ .request_id = rid, .resolution = .{ .question = .{ .selections = out } } };
        },
    }
}

pub fn replyErrorMessage(err: ReplyError) []const u8 {
    return switch (err) {
        error.MissingRequestId => "request_id is required",
        error.InvalidPermissionMode => PermissionMode.invalid_message,
        error.InvalidExitPlanMode => ExitPlanMode.invalid_message,
        error.InvalidSelections => "selections must be an array of strings",
        error.OutOfMemory => "out of memory",
    };
}
