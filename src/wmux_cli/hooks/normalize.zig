//! Hook event normalization (ADR-10.1 steps 2, 3, 5, 6, 7): map an agent's
//! native hook event (or the cmux subcommand the installed hook passes) to
//! cmux's subcommand set, derive the lifecycle signals the app needs, pick
//! the neutral acknowledgment, gate on the terminal environment, classify
//! notifications (title/subtitle/body/category) and encode the
//! `wmux.agent.hook` params.
//!
//! Names (agent ids, subcommands, native event names, env vars, payload
//! keys, subtitles, categories) are cmux interface facts; the tables are
//! clean-room. Pure std; borrows strings from the `Payload` it normalizes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const payload_mod = @import("payload.zig");
const Payload = payload_mod.Payload;

/// cmux's hook-capable agents (cmux `hooks setup` names plus Claude Code).
/// Tag order is the cmux store-suffix list order.
pub const Agent = enum {
    claude,
    codex,
    grok,
    opencode,
    pi,
    omp,
    campfire,
    amp,
    cursor,
    gemini,
    kiro,
    antigravity,
    rovodev,
    hermes_agent,
    copilot,
    codebuddy,
    factory,
    qoder,
    kimi,
    muse,

    /// The cmux agent id (CLI name and store suffix).
    pub fn id(self: Agent) []const u8 {
        return switch (self) {
            .hermes_agent => "hermes-agent",
            else => @tagName(self),
        };
    }

    /// Parse a CLI agent name: ids and cmux aliases (`agy`, `rovo`), plus
    /// the legacy wmux wire name `claude_code`. ASCII case-insensitive.
    pub fn parse(name: []const u8) ?Agent {
        var buf: [32]u8 = undefined;
        if (name.len == 0 or name.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, name);
        const aliases = .{
            .{ "agy", Agent.antigravity },
            .{ "rovo", Agent.rovodev },
            .{ "hermes-agent", Agent.hermes_agent },
            .{ "claude_code", Agent.claude },
            .{ "claude-code", Agent.claude },
        };
        inline for (aliases) |kv| {
            if (std.mem.eql(u8, lower, kv[0])) return kv[1];
        }
        if (std.mem.eql(u8, lower, "hermes_agent")) return null; // not a cmux spelling
        return std.meta.stringToEnum(Agent, lower);
    }

    /// Notification title (cmux agent display name).
    pub fn displayName(self: Agent) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex",
            .grok => "Grok",
            .opencode => "OpenCode",
            .pi => "Pi",
            .omp => "OMP",
            .campfire => "Campfire",
            .amp => "Amp",
            .cursor => "Cursor CLI",
            .gemini => "Gemini",
            .kiro => "Kiro CLI",
            .antigravity => "Antigravity",
            .rovodev => "Rovo Dev",
            .hermes_agent => "Hermes Agent",
            .copilot => "Copilot",
            .codebuddy => "CodeBuddy",
            .factory => "Factory",
            .qoder => "Qoder",
            .kimi => "Kimi Code",
            .muse => "Muse Code",
        };
    }

    /// Upper-case token used in `CMUX_<AGENT>_HOOKS_DISABLED`.
    pub fn envToken(self: Agent) []const u8 {
        return switch (self) {
            .claude => "CLAUDE",
            .codex => "CODEX",
            .grok => "GROK",
            .opencode => "OPENCODE",
            .pi => "PI",
            .omp => "OMP",
            .campfire => "CAMPFIRE",
            .amp => "AMP",
            .cursor => "CURSOR",
            .gemini => "GEMINI",
            .kiro => "KIRO",
            .antigravity => "ANTIGRAVITY",
            .rovodev => "ROVODEV",
            .hermes_agent => "HERMES_AGENT",
            .copilot => "COPILOT",
            .codebuddy => "CODEBUDDY",
            .factory => "FACTORY",
            .qoder => "QODER",
            .kimi => "KIMI",
            .muse => "MUSE",
        };
    }

    /// Lifecycle hook timeout in seconds (cmux: ~5 s, Gemini/Antigravity/
    /// Muse 10 s).
    pub fn hookTimeoutSeconds(self: Agent) u32 {
        return switch (self) {
            .gemini, .antigravity, .muse => 10,
            else => 5,
        };
    }

    /// Agents whose visible notifications are deduplicated per session.
    pub fn dedupesNotifications(self: Agent) bool {
        return switch (self) {
            .grok, .antigravity, .hermes_agent => true,
            else => false,
        };
    }
};

/// cmux's hook subcommand set (ADR-10.1 step 3), plus `pre-compact`
/// (wmux addition so PreCompact/PreCompress payloads are recognized as
/// activity instead of being rejected; it never changes lifecycle state).
pub const Event = enum {
    session_start,
    prompt_submit,
    pre_tool_use,
    post_tool_use,
    stop,
    notification,
    session_end,
    subagent_stop,
    agent_response,
    shell_exec,
    shell_done,
    shell_failed,
    approval_response,
    session_finalize,
    push_notification,
    auto_name,
    inbox_wait,
    inbox_drain,
    cron_create_guard,
    feed,
    pre_compact,

    /// The cmux subcommand spelling (`session-start`, ...).
    pub fn subcommand(self: Event) []const u8 {
        return switch (self) {
            inline else => |tag| comptime kebab(@tagName(tag)),
        };
    }

    /// Parse a subcommand, including cmux aliases `active`, `idle`, `notify`.
    pub fn parseSubcommand(s: []const u8) ?Event {
        if (std.mem.eql(u8, s, "active")) return .session_start;
        if (std.mem.eql(u8, s, "idle")) return .stop;
        if (std.mem.eql(u8, s, "notify")) return .notification;
        inline for (@typeInfo(Event).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, comptime kebab(f.name))) return @enumFromInt(f.value);
        }
        return null;
    }
};

fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
        const final = out;
        return &final;
    }
}

/// Why an agent is waiting on the user.
pub const InputKind = enum { permission, question, plan, waiting };

pub const Mapped = struct {
    event: Event,
    /// Stop variants that report an error (StopFailure, on_error, ...).
    failure: bool = false,
};

const NativeEntry = struct { []const u8, Mapped };

/// Claude Code-style names shared by Claude, Codex, Grok, Copilot,
/// CodeBuddy, Factory, Qoder, Kimi, Muse and others that adopted the same
/// hook vocabulary. Matched after `canonicalName` folding, so `PreToolUse`,
/// `preToolUse` and `pre_tool_use` are the same key.
const generic_natives = [_]NativeEntry{
    .{ "sessionstart", .{ .event = .session_start } },
    .{ "userpromptsubmit", .{ .event = .prompt_submit } },
    .{ "userpromptsubmitted", .{ .event = .prompt_submit } },
    .{ "pretooluse", .{ .event = .pre_tool_use } },
    .{ "posttooluse", .{ .event = .post_tool_use } },
    .{ "permissionrequest", .{ .event = .feed } },
    .{ "notification", .{ .event = .notification } },
    .{ "stop", .{ .event = .stop } },
    .{ "stopfailure", .{ .event = .stop, .failure = true } },
    .{ "subagentstop", .{ .event = .subagent_stop } },
    .{ "sessionend", .{ .event = .session_end } },
    .{ "precompact", .{ .event = .pre_compact } },
    .{ "erroroccurred", .{ .event = .stop, .failure = true } },
    // Codex legacy `notify` program payload type.
    .{ "agentturncomplete", .{ .event = .stop } },
};

const gemini_natives = [_]NativeEntry{
    .{ "beforeagent", .{ .event = .prompt_submit } },
    .{ "afteragent", .{ .event = .stop } },
    .{ "beforetool", .{ .event = .pre_tool_use } },
    .{ "aftertool", .{ .event = .post_tool_use } },
    .{ "precompress", .{ .event = .pre_compact } },
};

const cursor_natives = [_]NativeEntry{
    .{ "beforesubmitprompt", .{ .event = .prompt_submit } },
    .{ "beforeshellexecution", .{ .event = .shell_exec } },
    .{ "aftershellexecution", .{ .event = .shell_done } },
    .{ "beforemcpexecution", .{ .event = .pre_tool_use } },
    .{ "aftermcpexecution", .{ .event = .post_tool_use } },
    .{ "beforereadfile", .{ .event = .pre_tool_use } },
    .{ "afterfileedit", .{ .event = .post_tool_use } },
    .{ "afteragentresponse", .{ .event = .agent_response } },
};

const kiro_natives = [_]NativeEntry{
    .{ "agentspawn", .{ .event = .session_start } },
};

const rovodev_natives = [_]NativeEntry{
    .{ "oncomplete", .{ .event = .stop } },
    .{ "onerror", .{ .event = .stop, .failure = true } },
    .{ "ontoolpermission", .{ .event = .notification } },
};

const hermes_natives = [_]NativeEntry{
    .{ "prellmcall", .{ .event = .prompt_submit } },
    .{ "postllmcall", .{ .event = .stop } },
    .{ "pretoolcall", .{ .event = .pre_tool_use } },
    .{ "posttoolcall", .{ .event = .post_tool_use } },
    .{ "onsessionstart", .{ .event = .session_start } },
    .{ "onsessionend", .{ .event = .session_end } },
};

/// OpenCode plugin bus event types (`session.idle`, `tool.execute.before`).
const opencode_natives = [_]NativeEntry{
    .{ "sessioncreated", .{ .event = .session_start } },
    .{ "sessionidle", .{ .event = .stop } },
    .{ "sessionerror", .{ .event = .stop, .failure = true } },
    .{ "sessiondeleted", .{ .event = .session_end } },
    .{ "chatmessage", .{ .event = .prompt_submit } },
    .{ "toolexecutebefore", .{ .event = .pre_tool_use } },
    .{ "toolexecuteafter", .{ .event = .post_tool_use } },
    .{ "permissionupdated", .{ .event = .notification } },
    .{ "permissionasked", .{ .event = .notification } },
};

/// Pi-family extension events (Pi, OMP, Campfire).
const pi_natives = [_]NativeEntry{
    .{ "agentstart", .{ .event = .prompt_submit } },
    .{ "agentend", .{ .event = .stop } },
    .{ "toolexecutionstart", .{ .event = .pre_tool_use } },
    .{ "toolexecutionend", .{ .event = .post_tool_use } },
    .{ "sessionshutdown", .{ .event = .session_end } },
};

/// Amp plugin tab statuses.
const amp_natives = [_]NativeEntry{
    .{ "thinking", .{ .event = .prompt_submit } },
    .{ "running", .{ .event = .pre_tool_use } },
    .{ "reading", .{ .event = .pre_tool_use } },
    .{ "done", .{ .event = .stop } },
    .{ "interrupted", .{ .event = .stop } },
    .{ "error", .{ .event = .stop, .failure = true } },
};

fn agentNatives(agent: Agent) []const NativeEntry {
    return switch (agent) {
        .gemini, .antigravity => &gemini_natives,
        .cursor => &cursor_natives,
        .kiro => &kiro_natives,
        .rovodev => &rovodev_natives,
        .hermes_agent => &hermes_natives,
        .opencode => &opencode_natives,
        .pi, .omp, .campfire => &pi_natives,
        .amp => &amp_natives,
        else => &.{},
    };
}

/// Fold a native event name for table lookup: ASCII lowercase, drop `_`,
/// `-`, `.`, `:` and spaces. Returns null when it does not fit `buf`.
pub fn canonicalName(buf: []u8, name: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (name) |c| {
        switch (c) {
            '_', '-', '.', ':', ' ' => continue,
            else => {},
        }
        if (n == buf.len) return null;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

/// Map an agent's native event name to a cmux subcommand: the agent's own
/// table first, then the shared Claude-style vocabulary.
pub fn mapNative(agent: Agent, native: []const u8) ?Mapped {
    var buf: [64]u8 = undefined;
    const key = canonicalName(&buf, native) orelse return null;
    if (key.len == 0) return null;
    for (agentNatives(agent)) |e| {
        if (std.mem.eql(u8, e[0], key)) return e[1];
    }
    for (generic_natives) |e| {
        if (std.mem.eql(u8, e[0], key)) return e[1];
    }
    return null;
}

/// One normalized hook event. String fields borrow from the `Payload`.
pub const Normalized = struct {
    agent: Agent,
    event: Event,
    /// The native event name when known (payload `hook_event_name`, or the
    /// native argument the hook was invoked with).
    native_event: ?[]const u8 = null,
    failure: bool = false,
    is_subagent: bool = false,
    /// Background work was started (`run_in_background`) by this event.
    background_pending: bool = false,
    /// Set for events that put the agent in needs-input.
    input_kind: ?InputKind = null,

    session_id: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    prompt_length: ?usize = null,
};

/// Normalize `cmux hooks <agent> <arg>` with its stdin payload. `arg` is a
/// cmux subcommand (or alias) or a native event name. When `arg` resolves
/// to nothing the payload's `hook_event_name` is tried. Null means the
/// event is unknown: print the neutral ack and exit 0.
pub fn normalize(agent: Agent, arg: []const u8, p: *const Payload) ?Normalized {
    const from_payload: ?Mapped = if (p.hook_event_name) |h| mapNative(agent, h) else null;
    var mapped: Mapped = undefined;
    var native: ?[]const u8 = p.hook_event_name;
    if (Event.parseSubcommand(arg)) |ev| {
        mapped = .{ .event = ev };
        // The payload refines the subcommand it agrees with (Stop vs
        // StopFailure share `stop`).
        if (from_payload) |fp| {
            if (fp.event == ev) mapped.failure = fp.failure;
        }
    } else if (mapNative(agent, arg)) |m| {
        mapped = m;
        if (native == null) native = arg;
    } else if (from_payload) |fp| {
        mapped = fp;
    } else return null;

    var n: Normalized = .{
        .agent = agent,
        .event = mapped.event,
        .native_event = native,
        .failure = mapped.failure,
        .is_subagent = p.is_subagent,
        .session_id = p.session_id,
        .transcript_path = p.transcript_path,
        .cwd = p.cwd,
        .tool_name = p.tool_name,
        .message = p.message orelse p.error_text,
        .permission_mode = p.permission_mode,
        .prompt_length = p.prompt_length,
    };

    switch (n.event) {
        .stop => {
            if (!n.failure) {
                if (p.status) |s| n.failure = isErrorStatus(s);
            }
            if (!n.failure and p.error_text != null) {
                // A stop that carries an error is a failed turn.
                n.failure = true;
            }
        },
        .post_tool_use => {
            if (agent == .claude and eqlOpt(p.tool_name, "PushNotification")) {
                n.event = .push_notification;
                n.message = p.tool_message orelse n.message;
            }
        },
        .pre_tool_use => {
            n.background_pending = p.run_in_background;
            if (eqlOpt(p.tool_name, "AskUserQuestion")) n.input_kind = .question;
            if (eqlOpt(p.tool_name, "ExitPlanMode")) n.input_kind = .plan;
        },
        .notification => n.input_kind = notificationKind(p),
        .feed => n.input_kind = .permission,
        .subagent_stop => n.is_subagent = true,
        else => {},
    }
    return n;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, b) else false;
}

fn isErrorStatus(s: []const u8) bool {
    const words = [_][]const u8{ "error", "errored", "failed", "failure" };
    for (words) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    return false;
}

/// Needs-input reason of a Notification payload: Claude's
/// `notification_type`, else the classifier's cue words.
fn notificationKind(p: *const Payload) InputKind {
    if (p.notification_type) |t| {
        if (std.mem.eql(u8, t, "permission_prompt")) return .permission;
        if (std.mem.eql(u8, t, "idle_prompt")) return .waiting;
        if (std.mem.eql(u8, t, "elicitation_dialog")) return .question;
    }
    const msg = p.message orelse p.title orelse return .waiting;
    var toks: Tokens = .init(msg);
    if (toks.hasPrefix(&.{ "permission", "approv" })) return .permission;
    if (toks.hasPrefix(&.{"plan"})) return .plan;
    if (std.mem.indexOfScalar(u8, msg, '?') != null or toks.hasPrefix(&.{"question"})) return .question;
    return .waiting;
}

// ---------------------------------------------------------------------------
// Environment gating and acknowledgment (ADR-10.1 steps 2 and 7)

/// True when the hook runs inside a wmux/cmux terminal: explicit
/// `--surface`/`--workspace` flags, or a non-empty `CMUX_SURFACE_ID`,
/// `CMUX_WORKSPACE_ID` or their `WMUX_` twins.
pub fn insideWmux(env: *const std.process.EnvMap, has_target_flags: bool) bool {
    if (has_target_flags) return true;
    const names = [_][]const u8{ "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "WMUX_SURFACE_ID", "WMUX_WORKSPACE_ID" };
    for (names) |name| {
        if (env.get(name)) |v| {
            if (std.mem.trim(u8, v, " \t").len > 0) return true;
        }
    }
    return false;
}

/// `CMUX_<AGENT>_HOOKS_DISABLED=1` or `WMUX_<AGENT>_HOOKS_DISABLED=1`.
pub fn hooksDisabled(agent: Agent, env: *const std.process.EnvMap) bool {
    const prefixes = [_][]const u8{ "CMUX_", "WMUX_" };
    var buf: [64]u8 = undefined;
    for (prefixes) |prefix| {
        const name = std.fmt.bufPrint(&buf, "{s}{s}_HOOKS_DISABLED", .{ prefix, agent.envToken() }) catch continue;
        if (env.get(name)) |v| {
            const t = std.mem.trim(u8, v, " \t");
            if (std.mem.eql(u8, t, "1") or std.ascii.eqlIgnoreCase(t, "true")) return true;
        }
    }
    return false;
}

/// The neutral acknowledgment printed on stdout for (agent, event): `{}`
/// for nearly everything; Cursor's gating hooks expect an explicit
/// allow/continue decision.
pub fn neutralAck(agent: Agent, event: ?Event) []const u8 {
    if (agent == .cursor) {
        if (event) |ev| switch (ev) {
            .prompt_submit => return "{\"continue\":true}",
            .shell_exec, .pre_tool_use => return "{\"permission\":\"allow\"}",
            else => {},
        };
    }
    return "{}";
}

/// The session-store lifecycle value written for this event (cmux store
/// values), or null when the event leaves it unchanged.
pub fn storeLifecycle(n: Normalized, background_pending_at_stop: bool) ?[]const u8 {
    if (n.is_subagent) return null;
    return switch (n.event) {
        .session_start => "idle",
        .prompt_submit, .post_tool_use, .push_notification, .shell_exec, .shell_done, .shell_failed, .approval_response => "running",
        .pre_tool_use => if (n.input_kind != null) "needsInput" else "running",
        .notification, .feed => "needsInput",
        .stop => if (background_pending_at_stop) "backgroundWorkPending" else "idle",
        .session_end, .session_finalize => "idle",
        else => null,
    };
}

/// Whether this event's notification is dropped by
/// `automation.suppressSubagentNotifications` (default true).
pub fn suppressedAsSubagent(n: Normalized, suppress_subagent_notifications: bool) bool {
    return suppress_subagent_notifications and (n.is_subagent or n.event == .subagent_stop);
}

// ---------------------------------------------------------------------------
// Notification formatting (feature notifications-agent-hook-formatting)

pub const Category = enum {
    turn_complete,
    needs_permission,
    idle_reminder,
    other,

    pub fn wireName(self: Category) []const u8 {
        return switch (self) {
            .turn_complete => "turn-complete",
            .needs_permission => "needs-permission",
            .idle_reminder => "idle-reminder",
            .other => "other",
        };
    }
};

/// Formatted notification. Strings are allocated by `format`/`classify`
/// into the caller's allocator (use an arena) except `title`, which may
/// be static.
pub const Formatted = struct {
    title: []const u8,
    subtitle: []const u8,
    body: []const u8,
    category: Category,
};

pub const max_body_chars: usize = 180;
pub const max_claude_stop_chars: usize = 200;
pub const max_push_chars: usize = 240;

/// Classify a (signal, message) pair. `signal` is the joined event/type/
/// kind/notification_type/matcher/reason strings; `message` the payload
/// text. Null when there is nothing to show (nothing is fabricated).
pub fn classify(a: Allocator, agent: Agent, signal: []const u8, message: ?[]const u8) Allocator.Error!?Formatted {
    const msg = message orelse "";
    const both = try std.mem.concat(a, u8, &.{ signal, " ", msg });
    var toks: Tokens = .init(both);
    const has_msg = std.mem.trim(u8, msg, " \t\r\n").len > 0;
    const title = agent.displayName();

    if (toks.hasPrefix(&.{ "permission", "approve", "approval" })) {
        return .{ .title = title, .subtitle = "Permission", .body = try bodyOr(a, msg, "Approval needed", max_body_chars), .category = .needs_permission };
    }
    if (toks.hasPrefix(&.{ "error", "fail", "exception" })) {
        const fallback = try std.fmt.allocPrint(a, "{s} reported an error", .{title});
        return .{ .title = title, .subtitle = "Error", .body = try bodyOr(a, msg, fallback, max_body_chars), .category = .other };
    }
    if (toks.hasExact(&.{"done"}) or toks.hasPrefix(&.{ "succeed", "complet", "finish", "success" })) {
        return .{ .title = title, .subtitle = "Completed", .body = try bodyOr(a, msg, "Task completed", max_body_chars), .category = .turn_complete };
    }
    if (isWaiting(both)) {
        return .{ .title = title, .subtitle = "Waiting", .body = try bodyOr(a, msg, "Waiting for input", max_body_chars), .category = .idle_reminder };
    }
    if (has_msg) {
        return .{ .title = title, .subtitle = "Attention", .body = try singleLine(a, msg, max_body_chars), .category = .other };
    }
    return null;
}

pub const FormatOptions = struct {
    /// Surface title, for Pi's `Pi · <title>`.
    surface_title: ?[]const u8 = null,
    /// Last assistant message read from the transcript (Claude Stop).
    transcript_last_message: ?[]const u8 = null,
    /// Previously stored session summary (store `lastBody`).
    stored_summary: ?[]const u8 = null,
    /// Payload, for signal words and nested text.
    payload: ?*const Payload = null,
};

/// Build the notification for a normalized event, or null when the event
/// produces none (lifecycle-only events, Grok Stop, skipped pushes).
pub fn format(a: Allocator, n: Normalized, opts: FormatOptions) Allocator.Error!?Formatted {
    var f: Formatted = switch (n.event) {
        .stop => (try formatStop(a, n, opts)) orelse return null,
        .notification, .feed => blk: {
            const signal = try signalOf(a, n, opts.payload);
            break :blk (try classify(a, n.agent, signal, n.message)) orelse
                if (n.event == .feed or n.input_kind == .permission)
                    Formatted{ .title = n.agent.displayName(), .subtitle = "Permission", .body = "Approval needed", .category = .needs_permission }
                else
                    return null;
        },
        .push_notification => blk: {
            if (opts.payload) |p| if (p.push_skipped) return null;
            const msg = n.message orelse return null;
            const body = try singleLine(a, msg, max_push_chars);
            if (body.len == 0) return null;
            break :blk Formatted{ .title = n.agent.displayName(), .subtitle = "Attention", .body = body, .category = .other };
        },
        else => return null,
    };
    f.title = try titleFor(a, n.agent, opts.surface_title);
    return f;
}

fn formatStop(a: Allocator, n: Normalized, opts: FormatOptions) Allocator.Error!?Formatted {
    const title = n.agent.displayName();
    if (n.failure) {
        // A failed turn is an error whatever its text says: running it
        // through the classifier would turn "permission denied" into a
        // pending permission prompt on an agent that has stopped.
        const fallback = try std.fmt.allocPrint(a, "{s} reported an error", .{title});
        return .{ .title = title, .subtitle = "Error", .body = try bodyOr(a, n.message orelse "", fallback, max_body_chars), .category = .other };
    }
    if (n.agent == .grok) return null; // Grok's Notification payload carries the text
    const last: ?[]const u8 = if (opts.payload) |p| p.last_assistant_message orelse opts.transcript_last_message else opts.transcript_last_message;
    if (n.agent == .claude) {
        const project = if (n.cwd) |c| projectName(c) else "";
        const subtitle = if (project.len > 0) try std.fmt.allocPrint(a, "Completed in {s}", .{project}) else "Completed";
        const body = if (last) |m| try singleLine(a, m, max_claude_stop_chars) else "";
        if (body.len > 0) return .{ .title = title, .subtitle = subtitle, .body = body, .category = .turn_complete };
        const where = if (project.len > 0) try std.fmt.allocPrint(a, " in {s}", .{project}) else "";
        const fallback = if (opts.stored_summary) |s|
            try std.fmt.allocPrint(a, "Claude session completed{s}. Last: {s}", .{ where, s })
        else
            try std.fmt.allocPrint(a, "Claude session completed{s}", .{where});
        return .{ .title = title, .subtitle = subtitle, .body = try singleLine(a, fallback, max_claude_stop_chars), .category = .turn_complete };
    }
    return .{ .title = title, .subtitle = "Completed", .body = try bodyOr(a, last orelse "", "Task completed", max_body_chars), .category = .turn_complete };
}

fn titleFor(a: Allocator, agent: Agent, surface_title: ?[]const u8) Allocator.Error![]const u8 {
    const name = agent.displayName();
    if (agent == .pi) {
        if (surface_title) |t| {
            const tt = std.mem.trim(u8, t, " \t");
            if (tt.len > 0 and !std.mem.eql(u8, tt, name)) return std.fmt.allocPrint(a, "{s} · {s}", .{ name, tt });
        }
    }
    return name;
}

/// Join the signal strings: native event, notification type, matcher,
/// reason, status.
fn signalOf(a: Allocator, n: Normalized, p: ?*const Payload) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    if (n.native_event) |e| try parts.append(a, e);
    if (p) |pl| {
        for ([_]?[]const u8{ pl.notification_type, pl.matcher, pl.reason, pl.status }) |s| {
            if (s) |v| try parts.append(a, v);
        }
    }
    return std.mem.join(a, " ", parts.items);
}

/// Last path component of a Windows or POSIX directory.
pub fn projectName(cwd: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, cwd, "/\\");
    const idx = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    return trimmed[idx + 1 ..];
}

fn bodyOr(a: Allocator, msg: []const u8, fallback: []const u8, max_chars: usize) Allocator.Error![]const u8 {
    const body = try singleLine(a, msg, max_chars);
    return if (body.len > 0) body else fallback;
}

/// Collapse all whitespace runs to one space, trim, and cap at `max_chars`
/// code points (the last one being `…` when truncated).
pub fn singleLine(a: Allocator, s: []const u8, max_chars: usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var chars: usize = 0;
    var pending_space = false;
    var truncated = false;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = s[i..end];
        i = end;
        if (cp.len == 1 and std.ascii.isWhitespace(cp[0])) {
            pending_space = out.items.len > 0;
            continue;
        }
        const need: usize = if (pending_space) 2 else 1;
        if (chars + need > max_chars) {
            truncated = true;
            break;
        }
        if (pending_space) {
            try out.append(a, ' ');
            chars += 1;
            pending_space = false;
        }
        // Invalid bytes become U+FFFD so the body stays valid UTF-8.
        if (std.unicode.utf8ValidateSlice(cp)) try out.appendSlice(a, cp) else try out.appendSlice(a, "\u{FFFD}");
        chars += 1;
    }
    if (truncated and max_chars > 0) {
        // Drop code points until the ellipsis fits in `max_chars`.
        while (chars + 1 > max_chars) {
            dropLastCodepoint(&out);
            chars -= 1;
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            out.items.len -= 1;
            chars -= 1;
        }
        try out.appendSlice(a, "…");
    }
    return out.toOwnedSlice(a);
}

fn dropLastCodepoint(out: *std.ArrayList(u8)) void {
    if (out.items.len == 0) return;
    var n = out.items.len - 1;
    while (n > 0 and (out.items[n] & 0xC0) == 0x80) n -= 1;
    out.items.len = n;
}

/// Lowercase word tokens; splits on non-alphanumerics and camelCase
/// boundaries (`StopFailure` → `stop`, `failure`).
const Tokens = struct {
    s: []const u8,

    fn init(s: []const u8) Tokens {
        return .{ .s = s };
    }

    const Iter = struct {
        s: []const u8,
        i: usize = 0,
        buf: [64]u8 = undefined,

        fn next(it: *Iter) ?[]const u8 {
            while (it.i < it.s.len and !std.ascii.isAlphanumeric(it.s[it.i])) it.i += 1;
            if (it.i >= it.s.len) return null;
            const start = it.i;
            it.i += 1;
            while (it.i < it.s.len and std.ascii.isAlphanumeric(it.s[it.i])) {
                const c = it.s[it.i];
                const prev = it.s[it.i - 1];
                if (std.ascii.isUpper(c) and std.ascii.isLower(prev)) break;
                it.i += 1;
            }
            const word = it.s[start..it.i];
            const n = @min(word.len, it.buf.len);
            for (word[0..n], 0..) |c, k| it.buf[k] = std.ascii.toLower(c);
            return it.buf[0..n];
        }
    };

    fn iter(self: Tokens) Iter {
        return .{ .s = self.s };
    }

    fn hasPrefix(self: *Tokens, prefixes: []const []const u8) bool {
        var it = self.iter();
        while (it.next()) |t| {
            for (prefixes) |p| if (std.mem.startsWith(u8, t, p)) return true;
        }
        return false;
    }

    fn hasExact(self: *Tokens, words: []const []const u8) bool {
        var it = self.iter();
        while (it.next()) |t| {
            for (words) |w| if (std.mem.eql(u8, t, w)) return true;
        }
        return false;
    }
};

fn isOneOf(t: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, t, w)) return true;
    return false;
}

/// cmux's waiting cues: idle/wait/waiting/awaiting; `input` after
/// need/needs/require/request/wait/user/your; `<idle|input|user> prompt`;
/// `question` with a `?` or an answer/respond/reply/choose/confirm/continue.
fn isWaiting(text: []const u8) bool {
    var it: Tokens.Iter = .{ .s = text };
    var prev_buf: [64]u8 = undefined;
    var prev: []const u8 = "";
    var saw_question = false;
    var saw_answer_verb = false;
    while (it.next()) |t| {
        if (isOneOf(t, &.{ "idle", "wait", "waiting", "awaiting" })) return true;
        if (std.mem.eql(u8, t, "input") and isOneOf(prev, &.{ "need", "needs", "require", "request", "wait", "user", "your" })) return true;
        if (std.mem.eql(u8, t, "prompt") and isOneOf(prev, &.{ "idle", "input", "user" })) return true;
        if (std.mem.eql(u8, t, "question")) saw_question = true;
        if (isOneOf(t, &.{ "answer", "respond", "reply", "choose", "confirm", "continue" })) saw_answer_verb = true;
        @memcpy(prev_buf[0..t.len], t);
        prev = prev_buf[0..t.len];
    }
    return saw_question and (saw_answer_verb or std.mem.indexOfScalar(u8, text, '?') != null);
}

/// Per-session dedupe fingerprint (`status:hash(body)`).
pub fn fingerprint(f: Formatted) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(f.subtitle);
    h.update(":");
    h.update(f.body);
    return h.final();
}

// ---------------------------------------------------------------------------
// Claude transcript tail (Stop body)

/// Last assistant text in a Claude transcript JSONL tail (the bytes may
/// start mid-line; partial and malformed lines are skipped). Returns a
/// slice allocated in `a`, or null.
pub fn lastAssistantMessage(a: Allocator, jsonl: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, jsonl, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{') continue;
        if (std.mem.indexOf(u8, line, "assistant") == null) continue;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (v != .object) continue;
        const ty = v.object.get("type") orelse continue;
        if (ty != .string or !std.mem.eql(u8, ty.string, "assistant")) continue;
        const msg = v.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        switch (content) {
            .string => |s| try text.appendSlice(a, s),
            .array => |arr| for (arr.items) |part| {
                if (part != .object) continue;
                const pt = part.object.get("type") orelse continue;
                if (pt != .string or !std.mem.eql(u8, pt.string, "text")) continue;
                const t = part.object.get("text") orelse continue;
                if (t != .string) continue;
                if (text.items.len > 0) try text.append(a, ' ');
                try text.appendSlice(a, t.string);
            },
            else => continue,
        }
        if (std.mem.trim(u8, text.items, " \t\r\n").len == 0) continue; // tool-use-only turn
        return try a.dupe(u8, payload_mod.truncateUtf8(text.items, payload_mod.max_text_bytes));
    }
    return null;
}

// ---------------------------------------------------------------------------
// wmux.agent.hook params (ADR-10.1 step 5)

/// Values the CLI resolves outside the payload.
pub const WireContext = struct {
    seq: u64,
    surface_id: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    pid: ?u32 = null,
    /// Background work pending at Stop, as the CLI found it in the
    /// transcript: true or false when known, null when unknown. A known
    /// false is sent too, so the app clears the pending state it tracked
    /// from earlier `run_in_background` tools. The event's own
    /// `run_in_background` always sends true.
    background_pending: ?bool = null,
};

/// Write the `wmux.agent.hook` params object. Null fields are omitted.
/// Keys beyond ADR-10.1's list (`hook_event_name`, `failure`,
/// `is_subagent`, `background_pending`, `input_kind`) carry the signals the
/// app-side lifecycle needs.
pub fn writeHookParams(n: Normalized, ctx: WireContext, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();
    try jw.objectField("agent");
    try jw.write(n.agent.id());
    try jw.objectField("event");
    try jw.write(n.event.subcommand());
    try jw.objectField("seq");
    try jw.write(ctx.seq);
    try optField(&jw, "session_id", n.session_id);
    try optField(&jw, "surface_id", ctx.surface_id);
    try optField(&jw, "workspace_id", ctx.workspace_id);
    try optField(&jw, "cwd", n.cwd);
    if (ctx.pid) |pid| {
        try jw.objectField("pid");
        try jw.write(pid);
    }
    try optField(&jw, "transcript_path", n.transcript_path);
    try optField(&jw, "tool_name", n.tool_name);
    try optField(&jw, "message", n.message);
    try optField(&jw, "permission_mode", n.permission_mode);
    if (n.prompt_length) |len| {
        try jw.objectField("prompt_length");
        try jw.write(len);
    }
    try optField(&jw, "hook_event_name", n.native_event);
    if (n.failure) {
        try jw.objectField("failure");
        try jw.write(true);
    }
    if (n.is_subagent) {
        try jw.objectField("is_subagent");
        try jw.write(true);
    }
    const background: ?bool = if (n.background_pending) true else ctx.background_pending;
    if (background) |b| {
        try jw.objectField("background_pending");
        try jw.write(b);
    }
    if (n.input_kind) |k| {
        try jw.objectField("input_kind");
        try jw.write(@tagName(k));
    }
    try jw.endObject();
}

fn optField(jw: *std.json.Stringify, key: []const u8, v: ?[]const u8) std.Io.Writer.Error!void {
    const s = v orelse return;
    try jw.objectField(key);
    try jw.write(s);
}

/// Allocating convenience wrapper around `writeHookParams`.
pub fn hookParamsAlloc(gpa: Allocator, n: Normalized, ctx: WireContext) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeHookParams(n, ctx, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}
