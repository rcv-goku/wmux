//! Agent lifecycle state machine (ADR-10.4), pure. One authoritative
//! `AgentSession` per surface, driven by `wmux.agent.hook` events and two
//! backstops that do not depend on hook delivery: the owned-process exit
//! watcher (PID + creation time identity) and the transcript tail.
//!
//! Transitions (cmux table): session-start -> idle; prompt-submit,
//! pre/post-tool-use -> running; permission/question/plan/notification ->
//! needsInput; stop -> idle, or backgroundWorkPending when background work
//! is pending; subagent-stop -> unchanged; session-end -> ended (retained).
//! Duplicate events are no-ops; every observable change bumps a monotonic
//! version (registry-wide clock, so a replacement session on the same
//! surface never reuses a version). Subagent events never touch the parent.
//!
//! Std only (no wmux_proto, no sibling imports), so the CLI or tests can
//! share it. Strings are heap-owned and capped on code-point boundaries.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_id_bytes: usize = 256;
pub const max_path_bytes: usize = 4096;

pub const State = enum {
    unknown,
    running,
    needsInput,
    idle,
    backgroundWorkPending,
    ended,

    /// The hook-store `agentLifecycle` value for this state. `ended` is
    /// persisted as `idle`: the record is retained and stays resumable.
    pub fn storeValue(self: State) []const u8 {
        return switch (self) {
            .ended => "idle",
            else => @tagName(self),
        };
    }
};

/// Lifecycle inputs. Hook events arrive by subcommand name (`fromWire`);
/// `process_exited` and `transcript_turn_complete` come from the backstops.
pub const Event = enum {
    session_start,
    prompt_submit,
    pre_tool_use,
    post_tool_use,
    todo_write,
    permission_request,
    ask_user_question,
    exit_plan_mode,
    notification,
    stop,
    subagent_stop,
    session_end,
    /// Background work reported at Stop has finished.
    background_settled,
    /// Recognized hook events that do not change state (auto-name,
    /// inbox-wait/drain, cron-create-guard, pre-compact, agent-response).
    informational,

    /// Map a `wmux.agent.hook` `event` (cmux subcommand, aliases included)
    /// plus its optional `input_kind` to a lifecycle event. Null for names
    /// this build does not know (ignored by the caller).
    pub fn fromWire(name: []const u8, input_kind: ?[]const u8) ?Event {
        const table = [_]struct { []const u8, Event }{
            .{ "session-start", .session_start },
            .{ "active", .session_start },
            .{ "prompt-submit", .prompt_submit },
            .{ "approval-response", .prompt_submit },
            .{ "pre-tool-use", .pre_tool_use },
            .{ "shell-exec", .pre_tool_use },
            .{ "post-tool-use", .post_tool_use },
            .{ "push-notification", .post_tool_use },
            .{ "shell-done", .post_tool_use },
            .{ "shell-failed", .post_tool_use },
            .{ "notification", .notification },
            .{ "notify", .notification },
            .{ "feed", .permission_request },
            .{ "stop", .stop },
            .{ "idle", .stop },
            .{ "subagent-stop", .subagent_stop },
            .{ "session-end", .session_end },
            .{ "session-finalize", .session_end },
            .{ "agent-response", .informational },
            .{ "auto-name", .informational },
            .{ "inbox-wait", .informational },
            .{ "inbox-drain", .informational },
            .{ "cron-create-guard", .informational },
            .{ "pre-compact", .informational },
        };
        var ev: ?Event = null;
        for (table) |e| {
            if (std.mem.eql(u8, e[0], name)) {
                ev = e[1];
                break;
            }
        }
        const base = ev orelse return null;
        if (base == .pre_tool_use) {
            if (input_kind) |k| {
                if (std.mem.eql(u8, k, "question")) return .ask_user_question;
                if (std.mem.eql(u8, k, "plan")) return .exit_plan_mode;
                if (std.mem.eql(u8, k, "permission")) return .permission_request;
            }
        }
        return base;
    }

    fn isWork(self: Event) bool {
        return switch (self) {
            .prompt_submit, .pre_tool_use, .post_tool_use, .todo_write => true,
            else => false,
        };
    }

    fn isNeedsInput(self: Event) bool {
        return switch (self) {
            .permission_request, .ask_user_question, .exit_plan_mode, .notification => true,
            else => false,
        };
    }
};

/// One hook event as the lifecycle sees it. Strings are borrowed for the
/// duration of `apply`.
pub const Input = struct {
    event: Event,
    now_ms: i64,
    session_id: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    /// Agent id (`claude`, `codex`, ...).
    kind: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    pid: ?u32 = null,
    pid_start_time: ?u64 = null,
    /// Stop reported an error (StopFailure and friends).
    failure: bool = false,
    is_subagent: bool = false,
    /// On pre-tool-use: this tool runs in the background. On stop: the
    /// authoritative pending state when known (null = use what was tracked).
    background_pending: ?bool = null,

    /// Build an `Input` from parsed `wmux.agent.hook` params. Null when the
    /// object lacks a known `event`. Borrowed strings point into `params`.
    pub fn fromHookParams(params: std.json.ObjectMap, now_ms: i64) ?Input {
        const ev_name = getString(params, "event") orelse return null;
        const ev = Event.fromWire(ev_name, getString(params, "input_kind")) orelse return null;
        var in: Input = .{
            .event = ev,
            .now_ms = now_ms,
            .session_id = getString(params, "session_id"),
            .workspace_id = getString(params, "workspace_id"),
            .kind = getString(params, "agent"),
            .transcript_path = getString(params, "transcript_path"),
            .failure = getBool(params, "failure"),
            .is_subagent = getBool(params, "is_subagent"),
        };
        if (params.get("pid")) |v| {
            if (v == .integer and v.integer > 0 and v.integer <= std.math.maxInt(u32)) in.pid = @intCast(v.integer);
        }
        if (params.get("pid_start_time")) |v| {
            if (v == .integer and v.integer > 0) in.pid_start_time = @intCast(v.integer);
        }
        if (params.get("background_pending")) |v| {
            if (v == .bool) in.background_pending = v.bool;
        }
        return in;
    }
};

fn getString(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn getBool(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

pub const AgentSession = struct {
    surface_id: []u8,
    workspace_id: ?[]u8 = null,
    kind: ?[]u8 = null,
    session_id: ?[]u8 = null,
    transcript_path: ?[]u8 = null,
    state: State = .unknown,
    pid: ?u32 = null,
    pid_start_time: ?u64 = null,
    version: u64 = 0,
    last_activity_ms: i64 = 0,
    pending_background: bool = false,
    /// The last Stop reported an error (sidebar error status; W3-4).
    last_stop_failed: bool = false,

    fn deinit(self: *AgentSession, gpa: Allocator) void {
        gpa.free(self.surface_id);
        freeOpt(gpa, self.workspace_id);
        freeOpt(gpa, self.kind);
        freeOpt(gpa, self.session_id);
        freeOpt(gpa, self.transcript_path);
        self.* = undefined;
    }
};

pub const Outcome = enum {
    /// State or bindings changed; `version` was bumped.
    changed,
    /// Recognized, but nothing observable changed (duplicates).
    unchanged,
    /// Nested/subagent event; the parent session is untouched.
    ignored_subagent,
    /// Event for a different session id than the live one on this surface
    /// (e.g. a nested `codex exec`); the binding is not overwritten.
    ignored_foreign_session,
    /// No session on this surface and the event cannot create one.
    ignored_no_session,
    /// Backstop did not match the current process identity.
    ignored_stale_process,
};

pub const Registry = struct {
    gpa: Allocator,
    sessions: std.ArrayList(AgentSession) = .empty,
    /// Monotonic version clock shared by all sessions.
    clock: u64 = 0,

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (self.sessions.items) |*s| s.deinit(self.gpa);
        self.sessions.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const Registry, surface_id: []const u8) ?*const AgentSession {
        const i = self.indexOf(surface_id) orelse return null;
        return &self.sessions.items[i];
    }

    pub fn count(self: *const Registry) usize {
        return self.sessions.items.len;
    }

    /// Drop the session bound to a closed surface. Returns whether one existed.
    pub fn remove(self: *Registry, surface_id: []const u8) bool {
        const i = self.indexOf(surface_id) orelse return false;
        var s = self.sessions.orderedRemove(i);
        s.deinit(self.gpa);
        return true;
    }

    fn indexOf(self: *const Registry, surface_id: []const u8) ?usize {
        // Stored ids are capped, so compare the capped form: an over-long id
        // must find its own entry instead of creating a second one.
        const key = truncateUtf8(surface_id, max_id_bytes);
        for (self.sessions.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.surface_id, key)) return i;
        }
        return null;
    }

    fn bump(self: *Registry, s: *AgentSession, now_ms: i64) void {
        self.clock += 1;
        s.version = self.clock;
        s.last_activity_ms = @max(s.last_activity_ms, now_ms);
    }

    /// Apply one hook event for `surface_id`.
    pub fn apply(self: *Registry, surface_id: []const u8, in: Input) Allocator.Error!Outcome {
        if (in.is_subagent or in.event == .subagent_stop) return .ignored_subagent;

        const idx = self.indexOf(surface_id);
        if (idx == null) {
            // Any event that carries a session id (or a session-start)
            // creates the binding; hooks may be installed mid-session.
            if (in.event != .session_start and in.session_id == null) return .ignored_no_session;
            const owned = try dupeCapped(self.gpa, surface_id, max_id_bytes);
            errdefer self.gpa.free(owned);
            try self.sessions.append(self.gpa, .{ .surface_id = owned });
        }
        const s = &self.sessions.items[idx orelse self.sessions.items.len - 1];
        const created = idx == null;
        var changed = created;

        if (in.session_id) |sid| {
            const same = if (s.session_id) |cur| std.mem.eql(u8, cur, truncateUtf8(sid, max_id_bytes)) else false;
            if (!same) {
                const replace = s.session_id == null or in.event == .session_start or s.state == .ended;
                if (!replace) return .ignored_foreign_session;
                try replaceOpt(self.gpa, &s.session_id, sid, max_id_bytes);
                // A new session on this surface starts clean.
                s.pending_background = false;
                s.last_stop_failed = false;
                s.transcript_path = clearOpt(self.gpa, s.transcript_path);
                s.pid = null;
                s.pid_start_time = null;
                if (!created) s.state = .unknown;
                changed = true;
            }
        }

        if (try updateOpt(self.gpa, &s.workspace_id, in.workspace_id, max_id_bytes)) changed = true;
        if (try updateOpt(self.gpa, &s.kind, in.kind, max_id_bytes)) changed = true;
        if (try updateOpt(self.gpa, &s.transcript_path, in.transcript_path, max_path_bytes)) changed = true;
        if (in.pid) |pid| {
            if (s.pid != pid or (in.pid_start_time != null and s.pid_start_time != in.pid_start_time)) {
                s.pid = pid;
                s.pid_start_time = in.pid_start_time;
                changed = true;
            }
        }

        const next = nextState(s, in);
        if (next.state != s.state) {
            s.state = next.state;
            changed = true;
        }
        if (next.pending_background != s.pending_background) {
            s.pending_background = next.pending_background;
            changed = true;
        }
        if (next.last_stop_failed != s.last_stop_failed) {
            s.last_stop_failed = next.last_stop_failed;
            changed = true;
        }

        if (changed) {
            self.bump(s, in.now_ms);
            return .changed;
        }
        // Repeated work events still count as activity (hibernation idle
        // windows), without a version bump.
        if (in.event.isWork()) s.last_activity_ms = @max(s.last_activity_ms, in.now_ms);
        return .unchanged;
    }

    /// Exit-watcher backstop: the process `pid` (created at `start_time`,
    /// when known) exited. Only sessions whose current process identity
    /// matches flip to `ended`, so a predecessor's exit never ends a
    /// session resumed under a new PID.
    pub fn onProcessExit(self: *Registry, surface_id: []const u8, pid: u32, start_time: ?u64, now_ms: i64) Outcome {
        const i = self.indexOf(surface_id) orelse return .ignored_no_session;
        const s = &self.sessions.items[i];
        if (s.pid != pid) return .ignored_stale_process;
        if (start_time != null and s.pid_start_time != null and start_time.? != s.pid_start_time.?) return .ignored_stale_process;
        if (s.state == .ended) return .unchanged;
        s.state = .ended;
        s.pending_background = false;
        self.bump(s, now_ms);
        return .changed;
    }

    /// Transcript-tail backstop: a completed assistant turn was observed
    /// for `session_id`. Clears a stuck `running` (no Stop hook); never
    /// creates a session or overrides needs-input.
    pub fn onTranscriptTurnComplete(self: *Registry, surface_id: []const u8, session_id: []const u8, now_ms: i64) Outcome {
        const i = self.indexOf(surface_id) orelse return .ignored_no_session;
        const s = &self.sessions.items[i];
        const cur = s.session_id orelse return .ignored_foreign_session;
        if (!std.mem.eql(u8, cur, truncateUtf8(session_id, max_id_bytes))) return .ignored_foreign_session;
        if (s.state != .running) return .unchanged;
        s.state = if (s.pending_background) .backgroundWorkPending else .idle;
        self.bump(s, now_ms);
        return .changed;
    }
};

const Next = struct { state: State, pending_background: bool, last_stop_failed: bool };

/// The pure transition function.
pub fn nextState(s: *const AgentSession, in: Input) Next {
    var n: Next = .{ .state = s.state, .pending_background = s.pending_background, .last_stop_failed = s.last_stop_failed };
    switch (in.event) {
        .session_start => {
            // A fresh session (or a resume/clear of the same one) is idle
            // until the first prompt; a live running/needs-input state of
            // the same session is not reset by a repeated SessionStart.
            switch (s.state) {
                .unknown, .ended => n.state = .idle,
                else => {},
            }
            if (s.state == .ended) n.pending_background = false;
        },
        .prompt_submit, .pre_tool_use, .post_tool_use, .todo_write => {
            n.state = .running;
            n.last_stop_failed = false;
            if (in.event == .pre_tool_use and in.background_pending == true) n.pending_background = true;
        },
        .permission_request, .ask_user_question, .exit_plan_mode, .notification => {
            if (s.state != .ended) n.state = .needsInput;
        },
        .stop => {
            if (s.state != .ended) {
                const pending = in.background_pending orelse s.pending_background;
                n.pending_background = pending;
                n.state = if (pending) .backgroundWorkPending else .idle;
                n.last_stop_failed = in.failure;
            }
        },
        .background_settled => {
            n.pending_background = false;
            if (s.state == .backgroundWorkPending) n.state = .idle;
        },
        .session_end => {
            n.state = .ended;
            n.pending_background = false;
        },
        .subagent_stop, .informational => {},
    }
    return n;
}

/// Event-bus topic for a hook event: `agent.hook.<HookEventName>`. Uses the
/// native name when present, else the subcommand. Caller frees.
pub fn hookTopic(gpa: Allocator, hook_event_name: []const u8) Allocator.Error![]u8 {
    const name = truncateUtf8(hook_event_name, max_id_bytes);
    return std.fmt.allocPrint(gpa, "agent.hook.{s}", .{name});
}

fn freeOpt(gpa: Allocator, s: ?[]u8) void {
    if (s) |v| gpa.free(v);
}

fn clearOpt(gpa: Allocator, s: ?[]u8) ?[]u8 {
    freeOpt(gpa, s);
    return null;
}

fn dupeCapped(gpa: Allocator, s: []const u8, cap: usize) Allocator.Error![]u8 {
    return gpa.dupe(u8, truncateUtf8(s, cap));
}

fn replaceOpt(gpa: Allocator, slot: *?[]u8, v: []const u8, cap: usize) Allocator.Error!void {
    const copy = try dupeCapped(gpa, v, cap);
    freeOpt(gpa, slot.*);
    slot.* = copy;
}

/// Overwrite `slot` with `v` when `v` is non-null and different.
fn updateOpt(gpa: Allocator, slot: *?[]u8, v: ?[]const u8, cap: usize) Allocator.Error!bool {
    const new = truncateUtf8(v orelse return false, cap);
    if (new.len == 0) return false;
    if (slot.*) |cur| {
        if (std.mem.eql(u8, cur, new)) return false;
    }
    try replaceOpt(gpa, slot, new, cap);
    return true;
}

/// Longest prefix of at most `cap` bytes that does not split a UTF-8
/// sequence.
pub fn truncateUtf8(s: []const u8, cap: usize) []const u8 {
    if (s.len <= cap) return s;
    var end = cap;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}
