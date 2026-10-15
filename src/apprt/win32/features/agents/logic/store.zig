//! Per-agent hook session store model (ADR-10.2): the JSON document kept in
//! `STATE\agents\<agent>-hook-sessions.json`, field-compatible with cmux's
//! `~/.cmuxterm/<agent>-hook-sessions.json` records, plus the merge rules
//! hook events apply and the prune rules the app runs.
//!
//! Document shape (keys are cmux's):
//!   { "version": 1,
//!     "sessions": { "<sessionId>": { "sessionId", "workspaceId", "surfaceId",
//!         "cwd", "title", "transcriptPath", "pid", "pidStartTime",
//!         "launchCommand": { "executable", "arguments", "workingDirectory",
//!                            "rejectionReason" },
//!         "lastPermissionMode", "isRestorable", "agentLifecycle",
//!         "turnSettled", "hookEventName", "lastSubtitle", "lastBody",
//!         "runtimeStatus", "activePromptTurnId", "lastPromptTurnId",
//!         "startedAt", "updatedAt", "lastAutoNameAt", "autoNameTurnCount",
//!         "hadPendingBackgroundWorkAtStop", ...unknown keys kept } },
//!     "activeSessionsByWorkspace": { "<workspaceId>": "<sessionId>" },
//!     "activeSessionsBySurface": { "<surfaceId>": "<sessionId>" } }
//! Timestamps are Unix seconds (JSON numbers, fractional allowed).
//!
//! A `Store` is a transient document: load (parse), mutate, serialize. All
//! memory lives in one arena owned by the store. File I/O, `LockFileEx` on
//! `<file>.lock` and the atomic replace belong to the caller (CLI writer,
//! app pruner); this file is pure and std-only (no sibling imports) so the
//! build can also expose it to the CLI.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Document format version written by this build.
pub const format_version: i64 = 1;

/// Store files larger than this are treated as corrupt by callers.
pub const max_file_bytes: usize = 16 << 20;

pub const max_id_bytes: usize = 256;
pub const max_path_bytes: usize = 4096;
pub const max_text_bytes: usize = 4096;
pub const max_arguments: usize = 256;

/// Unknown values nested deeper than this are dropped (with a diagnostic)
/// instead of preserved. std.json parses any depth, but writing a value
/// back recurses once per level and the safe-mode writer stops at 256
/// levels, so a deep value would crash every later rewrite.
pub const max_extra_depth: usize = 64;

/// Store-name suffixes (cmux's agent list). File: `<suffix>-hook-sessions.json`.
pub const known_suffixes = [_][]const u8{
    "claude",    "codex",       "grok",    "opencode",     "pi",
    "omp",       "campfire",    "amp",     "cursor",       "gemini",
    "kiro",      "antigravity", "rovodev", "hermes-agent", "copilot",
    "codebuddy", "factory",     "qoder",   "kimi",         "muse",
};

pub fn isKnownSuffix(suffix: []const u8) bool {
    for (known_suffixes) |s| if (std.mem.eql(u8, s, suffix)) return true;
    return false;
}

/// `<suffix>-hook-sessions.json` into `buf`; null for unknown suffixes.
pub fn fileName(buf: []u8, suffix: []const u8) ?[]const u8 {
    if (!isKnownSuffix(suffix)) return null;
    return std.fmt.bufPrint(buf, "{s}-hook-sessions.json", .{suffix}) catch null;
}

/// `<suffix>-hook-sessions.json.lock` into `buf` (ADR-10.2 lock file).
pub fn lockFileName(buf: []u8, suffix: []const u8) ?[]const u8 {
    if (!isKnownSuffix(suffix)) return null;
    return std.fmt.bufPrint(buf, "{s}-hook-sessions.json.lock", .{suffix}) catch null;
}

/// Persisted lifecycle values (cmux `agentLifecycle`).
pub const Lifecycle = enum {
    running,
    idle,
    needsInput,
    backgroundWorkPending,
    unknown,

    /// Unknown strings decode as `.unknown` (forward compatible).
    pub fn parse(s: []const u8) Lifecycle {
        return std.meta.stringToEnum(Lifecycle, s) orelse .unknown;
    }
};

pub const LaunchCommand = struct {
    executable: ?[]const u8 = null,
    arguments: []const []const u8 = &.{},
    working_directory: ?[]const u8 = null,
    rejection_reason: ?[]const u8 = null,
};

pub const Record = struct {
    session_id: []const u8,
    workspace_id: ?[]const u8 = null,
    surface_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    pid: ?i64 = null,
    pid_start_time: ?i64 = null,
    launch_command: ?LaunchCommand = null,
    last_permission_mode: ?[]const u8 = null,
    is_restorable: ?bool = null,
    agent_lifecycle: Lifecycle = .unknown,
    turn_settled: ?bool = null,
    hook_event_name: ?[]const u8 = null,
    last_subtitle: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    runtime_status: ?[]const u8 = null,
    active_prompt_turn_id: ?[]const u8 = null,
    last_prompt_turn_id: ?[]const u8 = null,
    started_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
    last_auto_name_at_ms: ?i64 = null,
    auto_name_turn_count: ?i64 = null,
    had_pending_background_work_at_stop: ?bool = null,
    /// Keys this build does not know, preserved on rewrite.
    extra: ExtraMap = .empty,

    /// Most recent known timestamp (updatedAt, else startedAt, else 0).
    pub fn lastSeenMs(self: Record) i64 {
        return self.updated_at_ms orelse self.started_at_ms orelse 0;
    }
};

pub const Diagnostic = struct {
    /// Session key, or "" for document-level problems.
    key: []const u8,
    reason: []const u8,
};

/// Turn bookkeeping requested by a hook event.
pub const TurnOp = enum { none, begin, settle };

/// A hook event's changes to one record. Null fields leave the stored
/// value unchanged (merge, not replace).
pub const Update = struct {
    session_id: []const u8,
    now_ms: i64,
    workspace_id: ?[]const u8 = null,
    surface_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    pid: ?i64 = null,
    pid_start_time: ?i64 = null,
    launch_command: ?LaunchCommand = null,
    permission_mode: ?[]const u8 = null,
    is_restorable: ?bool = null,
    lifecycle: ?Lifecycle = null,
    hook_event_name: ?[]const u8 = null,
    last_subtitle: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    runtime_status: ?[]const u8 = null,
    turn: TurnOp = .none,
    turn_id: ?[]const u8 = null,
    had_pending_background_work_at_stop: ?bool = null,
    last_auto_name_at_ms: ?i64 = null,
    auto_name_turn_count: ?i64 = null,
    /// Make this the active session of its surface and workspace, and drop
    /// superseded sessions bound to the same surface.
    activate: bool = true,
};

pub const PruneOptions = struct {
    now_ms: i64,
    /// Records not updated for this long are dropped (null = keep).
    max_age_ms: ?i64 = default_max_age_ms,
    /// Keep at most this many records, most recently updated first.
    max_entries: ?usize = default_max_entries,
};

pub const default_max_age_ms: i64 = 30 * std.time.ms_per_day;
pub const default_max_entries: usize = 512;

const StrMap = std.StringArrayHashMapUnmanaged([]const u8);
/// Unmanaged on purpose: a `Store` moves by value, so nothing may capture
/// its arena's allocator.
const ExtraMap = std.StringArrayHashMapUnmanaged(std.json.Value);

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    /// Version read from the file (or `format_version` for a new store).
    version: i64 = format_version,
    sessions: std.StringArrayHashMapUnmanaged(Record) = .empty,
    active_by_workspace: StrMap = .empty,
    active_by_surface: StrMap = .empty,
    /// Unknown top-level keys, preserved on rewrite.
    extra: ExtraMap = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(gpa: Allocator) Store {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn alloc(self: *Store) Allocator {
        return self.arena.allocator();
    }

    fn diag(self: *Store, key: []const u8, reason: []const u8) Allocator.Error!void {
        try self.diagnostics.append(self.alloc(), .{ .key = try self.alloc().dupe(u8, key), .reason = reason });
    }

    /// Parse a store file. Only allocation failure is an error: a document
    /// that is not a JSON object yields an empty store with a diagnostic,
    /// and corrupt session entries are dropped one by one.
    pub fn parse(gpa: Allocator, bytes: []const u8) Allocator.Error!Store {
        var self = Store.init(gpa);
        errdefer self.deinit();
        const a = self.alloc();

        const trimmed = std.mem.trim(u8, bytes, " \t\r\n\xEF\xBB\xBF");
        if (trimmed.len == 0) return self;
        if (bytes.len > max_file_bytes) {
            try self.diag("", "file too large");
            return self;
        }
        const root = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{
            .duplicate_field_behavior = .use_last,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.diag("", "not valid JSON");
                return self;
            },
        };
        if (root != .object) {
            try self.diag("", "document is not an object");
            return self;
        }

        var it = root.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const v = e.value_ptr.*;
            if (std.mem.eql(u8, key, "version")) {
                if (v == .integer) self.version = v.integer else try self.diag("", "version is not an integer");
            } else if (std.mem.eql(u8, key, "sessions")) {
                if (v != .object) {
                    try self.diag("", "sessions is not an object");
                    continue;
                }
                var sit = v.object.iterator();
                while (sit.next()) |se| try self.decodeEntry(se.key_ptr.*, se.value_ptr.*);
            } else if (std.mem.eql(u8, key, "activeSessionsByWorkspace") or std.mem.eql(u8, key, "activeSessionsBySurface")) {
                // Decoded after sessions so dangling references can be dropped.
            } else {
                try self.keepExtra(&self.extra, "", key, v);
            }
        }
        inline for (.{ .{ "activeSessionsByWorkspace", &self.active_by_workspace }, .{ "activeSessionsBySurface", &self.active_by_surface } }) |m| {
            if (root.object.get(m[0])) |v| try self.decodeActiveMap(m[0], v, m[1]);
        }
        return self;
    }

    /// Preserve an unknown key's value unless it nests too deeply to write
    /// back (`max_extra_depth`). `diag_key` is the session key, or "".
    fn keepExtra(self: *Store, map: *ExtraMap, diag_key: []const u8, k: []const u8, v: std.json.Value) Allocator.Error!void {
        if (nestsDeeperThan(v, max_extra_depth)) return self.diag(diag_key, "unknown value nested too deeply; dropped");
        try map.put(self.alloc(), k, v);
    }

    fn decodeEntry(self: *Store, key: []const u8, v: std.json.Value) Allocator.Error!void {
        if (key.len == 0 or key.len > max_id_bytes) return self.diag(key, "invalid session key");
        if (v != .object) return self.diag(key, "entry is not an object");
        const o = v.object;
        var r: Record = .{ .session_id = key };
        if (o.get("sessionId")) |sid| {
            if (sid != .string) return self.diag(key, "sessionId is not a string");
            if (!std.mem.eql(u8, sid.string, key)) try self.diag(key, "sessionId differs from key; key wins");
        }

        var it = o.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            const val = e.value_ptr.*;
            if (std.mem.eql(u8, k, "sessionId")) continue;
            const known = try self.decodeField(&r, key, k, val);
            if (!known) try self.keepExtra(&r.extra, key, k, val);
        }
        try self.sessions.put(self.alloc(), key, r);
    }

    /// Decode one known field; returns false for unknown keys. A known key
    /// with the wrong type is dropped with a diagnostic (the entry stays).
    fn decodeField(self: *Store, r: *Record, key: []const u8, k: []const u8, v: std.json.Value) Allocator.Error!bool {
        const string_fields = .{
            .{ "workspaceId", "workspace_id", max_id_bytes },
            .{ "surfaceId", "surface_id", max_id_bytes },
            .{ "cwd", "cwd", max_path_bytes },
            .{ "title", "title", max_text_bytes },
            .{ "transcriptPath", "transcript_path", max_path_bytes },
            .{ "lastPermissionMode", "last_permission_mode", max_id_bytes },
            .{ "hookEventName", "hook_event_name", max_id_bytes },
            .{ "lastSubtitle", "last_subtitle", max_text_bytes },
            .{ "lastBody", "last_body", max_text_bytes },
            .{ "runtimeStatus", "runtime_status", max_id_bytes },
            .{ "activePromptTurnId", "active_prompt_turn_id", max_id_bytes },
            .{ "lastPromptTurnId", "last_prompt_turn_id", max_id_bytes },
        };
        inline for (string_fields) |f| {
            if (std.mem.eql(u8, k, f[0])) {
                switch (v) {
                    .string => |s| @field(r, f[1]) = truncateUtf8(s, f[2]),
                    .null => {},
                    else => try self.diag(key, "string field has wrong type: " ++ f[0]),
                }
                return true;
            }
        }
        const int_fields = .{
            .{ "pid", "pid" },
            .{ "pidStartTime", "pid_start_time" },
            .{ "autoNameTurnCount", "auto_name_turn_count" },
        };
        inline for (int_fields) |f| {
            if (std.mem.eql(u8, k, f[0])) {
                switch (v) {
                    .integer => |i| @field(r, f[1]) = i,
                    .float => |x| @field(r, f[1]) = floatToInt(x),
                    .null => {},
                    else => try self.diag(key, "integer field has wrong type: " ++ f[0]),
                }
                return true;
            }
        }
        const time_fields = .{
            .{ "startedAt", "started_at_ms" },
            .{ "updatedAt", "updated_at_ms" },
            .{ "lastAutoNameAt", "last_auto_name_at_ms" },
        };
        inline for (time_fields) |f| {
            if (std.mem.eql(u8, k, f[0])) {
                if (decodeTimestampMs(v)) |ms| {
                    @field(r, f[1]) = ms;
                } else if (v != .null) try self.diag(key, "timestamp has wrong type: " ++ f[0]);
                return true;
            }
        }
        const bool_fields = .{
            .{ "isRestorable", "is_restorable" },
            .{ "turnSettled", "turn_settled" },
            .{ "hadPendingBackgroundWorkAtStop", "had_pending_background_work_at_stop" },
        };
        inline for (bool_fields) |f| {
            if (std.mem.eql(u8, k, f[0])) {
                switch (v) {
                    .bool => |b| @field(r, f[1]) = b,
                    .null => {},
                    else => try self.diag(key, "bool field has wrong type: " ++ f[0]),
                }
                return true;
            }
        }
        if (std.mem.eql(u8, k, "agentLifecycle")) {
            switch (v) {
                .string => |s| r.agent_lifecycle = Lifecycle.parse(s),
                .null => {},
                else => try self.diag(key, "string field has wrong type: agentLifecycle"),
            }
            return true;
        }
        if (std.mem.eql(u8, k, "launchCommand")) {
            switch (v) {
                .object => |o| r.launch_command = try self.decodeLaunch(key, o),
                .null => {},
                else => try self.diag(key, "launchCommand is not an object"),
            }
            return true;
        }
        return false;
    }

    fn decodeLaunch(self: *Store, key: []const u8, o: std.json.ObjectMap) Allocator.Error!LaunchCommand {
        var lc: LaunchCommand = .{};
        lc.executable = optStr(o, "executable", max_path_bytes);
        lc.working_directory = optStr(o, "workingDirectory", max_path_bytes);
        lc.rejection_reason = optStr(o, "rejectionReason", max_text_bytes);
        if (o.get("arguments")) |args| {
            if (args == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (args.array.items) |item| {
                    if (list.items.len == max_arguments) break;
                    if (item == .string) {
                        try list.append(self.alloc(), truncateUtf8(item.string, max_text_bytes));
                    } else {
                        try self.diag(key, "launchCommand argument is not a string");
                    }
                }
                lc.arguments = list.items;
            } else if (args != .null) try self.diag(key, "launchCommand.arguments is not an array");
        }
        return lc;
    }

    fn decodeActiveMap(self: *Store, comptime name: []const u8, v: std.json.Value, map: *StrMap) Allocator.Error!void {
        if (v != .object) return self.diag("", name ++ " is not an object");
        var it = v.object.iterator();
        while (it.next()) |e| {
            const val = e.value_ptr.*;
            if (val != .string) {
                try self.diag(e.key_ptr.*, "active session reference is not a string");
                continue;
            }
            if (!self.sessions.contains(val.string)) {
                try self.diag(e.key_ptr.*, "active session reference points at a missing session");
                continue;
            }
            try map.put(self.alloc(), e.key_ptr.*, val.string);
        }
    }

    pub fn get(self: *const Store, session_id: []const u8) ?*const Record {
        return self.sessions.getPtr(session_id);
    }

    pub fn count(self: *const Store) usize {
        return self.sessions.count();
    }

    /// The active record for a surface, if any.
    pub fn activeForSurface(self: *const Store, surface_id: []const u8) ?*const Record {
        const sid = self.active_by_surface.get(surface_id) orelse return null;
        return self.sessions.getPtr(sid);
    }

    /// The active record for a workspace, if any.
    pub fn activeForWorkspace(self: *const Store, workspace_id: []const u8) ?*const Record {
        const sid = self.active_by_workspace.get(workspace_id) orelse return null;
        return self.sessions.getPtr(sid);
    }

    /// Merge a hook event into the store (ADR-10.2 rules):
    /// 1. get-or-create the record (`startedAt` = now on create);
    /// 2. every non-null update field overwrites, null keeps;
    /// 3. turn bookkeeping: `begin` sets activePromptTurnId and clears
    ///    turnSettled; `settle` moves it to lastPromptTurnId and sets
    ///    turnSettled;
    /// 4. `updatedAt` = now (never moves backwards);
    /// 5. with `activate`, the record becomes the active session of its
    ///    surface and workspace, and other sessions on the same surface are
    ///    superseded (removed).
    pub fn applyHook(self: *Store, u: Update) (Allocator.Error || error{MissingSessionId})!void {
        const a = self.alloc();
        const sid_in = std.mem.trim(u8, u.session_id, " \t\r\n");
        if (sid_in.len == 0) return error.MissingSessionId;
        const sid = truncateUtf8(sid_in, max_id_bytes);

        const gop = try self.sessions.getOrPut(a, sid);
        if (!gop.found_existing) {
            const key = try a.dupe(u8, sid);
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{ .session_id = key, .started_at_ms = u.now_ms };
        }
        const r = gop.value_ptr;

        try setStr(a, &r.workspace_id, u.workspace_id, max_id_bytes);
        try setStr(a, &r.surface_id, u.surface_id, max_id_bytes);
        try setStr(a, &r.cwd, u.cwd, max_path_bytes);
        try setStr(a, &r.title, u.title, max_text_bytes);
        try setStr(a, &r.transcript_path, u.transcript_path, max_path_bytes);
        try setStr(a, &r.last_permission_mode, u.permission_mode, max_id_bytes);
        try setStr(a, &r.hook_event_name, u.hook_event_name, max_id_bytes);
        try setStr(a, &r.last_subtitle, u.last_subtitle, max_text_bytes);
        try setStr(a, &r.last_body, u.last_body, max_text_bytes);
        try setStr(a, &r.runtime_status, u.runtime_status, max_id_bytes);
        if (u.pid) |pid| {
            r.pid = pid;
            // A new process without a known start time must not inherit the
            // old process's start time.
            r.pid_start_time = u.pid_start_time;
        } else if (u.pid_start_time) |t| r.pid_start_time = t;
        if (u.launch_command) |lc| r.launch_command = try copyLaunch(a, lc);
        if (u.is_restorable) |b| r.is_restorable = b;
        if (u.lifecycle) |l| r.agent_lifecycle = l;
        if (u.had_pending_background_work_at_stop) |b| r.had_pending_background_work_at_stop = b;
        if (u.last_auto_name_at_ms) |t| r.last_auto_name_at_ms = t;
        if (u.auto_name_turn_count) |c| r.auto_name_turn_count = c;

        switch (u.turn) {
            .none => {},
            .begin => {
                if (u.turn_id) |t| r.active_prompt_turn_id = try a.dupe(u8, truncateUtf8(t, max_id_bytes));
                r.turn_settled = false;
            },
            .settle => {
                const last = if (u.turn_id) |t| try a.dupe(u8, truncateUtf8(t, max_id_bytes)) else r.active_prompt_turn_id;
                if (last) |l| r.last_prompt_turn_id = l;
                r.active_prompt_turn_id = null;
                r.turn_settled = true;
            },
        }
        r.updated_at_ms = @max(r.updated_at_ms orelse u.now_ms, u.now_ms);

        if (u.activate) try self.activate(r.session_id);
    }

    fn activate(self: *Store, sid: []const u8) Allocator.Error!void {
        const a = self.alloc();
        const r = self.sessions.getPtr(sid).?;
        if (r.surface_id) |surface| {
            // Supersede: other sessions bound to the same surface go away.
            var i: usize = 0;
            while (i < self.sessions.count()) {
                const other = &self.sessions.values()[i];
                const same_surface = if (other.surface_id) |s| std.mem.eql(u8, s, surface) else false;
                if (same_surface and !std.mem.eql(u8, other.session_id, sid)) {
                    self.sessions.orderedRemoveAt(i);
                    continue;
                }
                i += 1;
            }
            const rec = self.sessions.getPtr(sid).?;
            try self.active_by_surface.put(a, rec.surface_id.?, rec.session_id);
        }
        const rec = self.sessions.getPtr(sid).?;
        if (rec.workspace_id) |ws| try self.active_by_workspace.put(a, ws, rec.session_id);
        self.fixupActiveMaps();
    }

    /// Remove one session. Returns whether it existed.
    pub fn remove(self: *Store, session_id: []const u8) bool {
        const removed = self.sessions.orderedRemove(session_id);
        if (removed) self.fixupActiveMaps();
        return removed;
    }

    /// Remove every session bound to `surface_id` (surface closed for good).
    pub fn removeSurface(self: *Store, surface_id: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.sessions.count()) {
            const r = self.sessions.values()[i];
            if (r.surface_id != null and std.mem.eql(u8, r.surface_id.?, surface_id)) {
                self.sessions.orderedRemoveAt(i);
                n += 1;
                continue;
            }
            i += 1;
        }
        if (n > 0) self.fixupActiveMaps();
        return n;
    }

    /// Drop records older than `max_age_ms`, then keep the `max_entries`
    /// most recently updated. Active maps are repaired. Returns the number
    /// of removed records.
    pub fn prune(self: *Store, opts: PruneOptions) usize {
        var removed: usize = 0;
        if (opts.max_age_ms) |age| {
            const cutoff = opts.now_ms -| age;
            var i: usize = 0;
            while (i < self.sessions.count()) {
                if (self.sessions.values()[i].lastSeenMs() < cutoff) {
                    self.sessions.orderedRemoveAt(i);
                    removed += 1;
                    continue;
                }
                i += 1;
            }
        }
        if (opts.max_entries) |max| {
            while (self.sessions.count() > max) {
                // Remove the oldest (first on ties, i.e. earliest inserted).
                var oldest: usize = 0;
                for (self.sessions.values(), 0..) |r, i| {
                    if (r.lastSeenMs() < self.sessions.values()[oldest].lastSeenMs()) oldest = i;
                }
                self.sessions.orderedRemoveAt(oldest);
                removed += 1;
            }
        }
        if (removed > 0) self.fixupActiveMaps();
        return removed;
    }

    /// Drop active-map entries that point at missing sessions or at sessions
    /// no longer bound to that surface/workspace.
    fn fixupActiveMaps(self: *Store) void {
        inline for (.{ .{ &self.active_by_surface, "surface_id" }, .{ &self.active_by_workspace, "workspace_id" } }) |m| {
            const map = m[0];
            var i: usize = 0;
            while (i < map.count()) {
                const key = map.keys()[i];
                const sid = map.values()[i];
                const ok = if (self.sessions.getPtr(sid)) |r|
                    (if (@field(r, m[1])) |bound| std.mem.eql(u8, bound, key) else false)
                else
                    false;
                if (!ok) {
                    map.orderedRemoveAt(i);
                    continue;
                }
                i += 1;
            }
        }
    }

    /// Serialize the document (2-space indent, null fields omitted).
    pub fn write(self: *const Store, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(@max(self.version, format_version));
        try jw.objectField("sessions");
        try jw.beginObject();
        for (self.sessions.values()) |r| {
            try jw.objectField(r.session_id);
            try writeRecord(&jw, r);
        }
        try jw.endObject();
        inline for (.{ .{ "activeSessionsByWorkspace", &self.active_by_workspace }, .{ "activeSessionsBySurface", &self.active_by_surface } }) |m| {
            try jw.objectField(m[0]);
            try jw.beginObject();
            var it = m[1].iterator();
            while (it.next()) |e| {
                try jw.objectField(e.key_ptr.*);
                try jw.write(e.value_ptr.*);
            }
            try jw.endObject();
        }
        var it = self.extra.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
        try jw.endObject();
    }

    /// Serialize into a gpa-owned slice (with a trailing newline).
    pub fn toOwnedJson(self: *const Store, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        self.write(&aw.writer) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

fn writeRecord(jw: *std.json.Stringify, r: Record) std.Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("sessionId");
    try jw.write(r.session_id);
    try optStrField(jw, "workspaceId", r.workspace_id);
    try optStrField(jw, "surfaceId", r.surface_id);
    try optStrField(jw, "cwd", r.cwd);
    try optStrField(jw, "title", r.title);
    try optStrField(jw, "transcriptPath", r.transcript_path);
    try optField(jw, "pid", r.pid);
    try optField(jw, "pidStartTime", r.pid_start_time);
    if (r.launch_command) |lc| {
        try jw.objectField("launchCommand");
        try jw.beginObject();
        try optStrField(jw, "executable", lc.executable);
        try jw.objectField("arguments");
        try jw.write(lc.arguments);
        try optStrField(jw, "workingDirectory", lc.working_directory);
        try optStrField(jw, "rejectionReason", lc.rejection_reason);
        try jw.endObject();
    }
    try optStrField(jw, "lastPermissionMode", r.last_permission_mode);
    try optField(jw, "isRestorable", r.is_restorable);
    try jw.objectField("agentLifecycle");
    try jw.write(@tagName(r.agent_lifecycle));
    try optField(jw, "turnSettled", r.turn_settled);
    try optStrField(jw, "hookEventName", r.hook_event_name);
    try optStrField(jw, "lastSubtitle", r.last_subtitle);
    try optStrField(jw, "lastBody", r.last_body);
    try optStrField(jw, "runtimeStatus", r.runtime_status);
    try optStrField(jw, "activePromptTurnId", r.active_prompt_turn_id);
    try optStrField(jw, "lastPromptTurnId", r.last_prompt_turn_id);
    try optTimeField(jw, "startedAt", r.started_at_ms);
    try optTimeField(jw, "updatedAt", r.updated_at_ms);
    try optTimeField(jw, "lastAutoNameAt", r.last_auto_name_at_ms);
    try optField(jw, "autoNameTurnCount", r.auto_name_turn_count);
    try optField(jw, "hadPendingBackgroundWorkAtStop", r.had_pending_background_work_at_stop);
    var it = r.extra.iterator();
    while (it.next()) |e| {
        try jw.objectField(e.key_ptr.*);
        try jw.write(e.value_ptr.*);
    }
    try jw.endObject();
}

fn optStrField(jw: *std.json.Stringify, key: []const u8, v: ?[]const u8) std.Io.Writer.Error!void {
    const s = v orelse return;
    try jw.objectField(key);
    try jw.write(s);
}

fn optField(jw: *std.json.Stringify, key: []const u8, v: anytype) std.Io.Writer.Error!void {
    const x = v orelse return;
    try jw.objectField(key);
    try jw.write(x);
}

/// Milliseconds are written as Unix seconds; whole seconds stay integers.
fn optTimeField(jw: *std.json.Stringify, key: []const u8, ms: ?i64) std.Io.Writer.Error!void {
    const t = ms orelse return;
    try jw.objectField(key);
    if (@rem(t, 1000) == 0) {
        try jw.write(@divTrunc(t, 1000));
    } else {
        try jw.write(@as(f64, @floatFromInt(t)) / 1000.0);
    }
}

/// Unix seconds (int or float) → ms. Values above 1e11 are taken as
/// milliseconds already (tolerates writers that store ms).
pub fn decodeTimestampMs(v: std.json.Value) ?i64 {
    const secs: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    if (!std.math.isFinite(secs) or secs < 0) return null;
    if (secs > 1e11) return floatToInt(secs);
    return floatToInt(@round(secs * 1000.0));
}

fn floatToInt(x: f64) i64 {
    if (!std.math.isFinite(x)) return 0;
    const max: f64 = @floatFromInt(std.math.maxInt(i64));
    const min: f64 = @floatFromInt(std.math.minInt(i64));
    if (x >= max) return std.math.maxInt(i64);
    if (x <= min) return std.math.minInt(i64);
    return @intFromFloat(x);
}

/// Whether `v` nests arrays/objects more than `limit` levels deep (a scalar
/// is 0 levels, `[]` is 1). Recursion stops at `limit`, so the check itself
/// is safe on any input.
fn nestsDeeperThan(v: std.json.Value, limit: usize) bool {
    switch (v) {
        .array => |arr| {
            if (limit == 0) return true;
            for (arr.items) |item| if (nestsDeeperThan(item, limit - 1)) return true;
            return false;
        },
        .object => |o| {
            if (limit == 0) return true;
            var it = o.iterator();
            while (it.next()) |e| if (nestsDeeperThan(e.value_ptr.*, limit - 1)) return true;
            return false;
        },
        else => return false,
    }
}

fn optStr(o: std.json.ObjectMap, key: []const u8, cap: usize) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) truncateUtf8(v.string, cap) else null;
}

fn setStr(a: Allocator, slot: *?[]const u8, v: ?[]const u8, cap: usize) Allocator.Error!void {
    const s = v orelse return;
    slot.* = try a.dupe(u8, truncateUtf8(s, cap));
}

fn copyLaunch(a: Allocator, lc: LaunchCommand) Allocator.Error!LaunchCommand {
    const n = @min(lc.arguments.len, max_arguments);
    const args = try a.alloc([]const u8, n);
    for (lc.arguments[0..n], 0..) |arg, i| args[i] = try a.dupe(u8, truncateUtf8(arg, max_text_bytes));
    return .{
        .executable = if (lc.executable) |e| try a.dupe(u8, truncateUtf8(e, max_path_bytes)) else null,
        .arguments = args,
        .working_directory = if (lc.working_directory) |d| try a.dupe(u8, truncateUtf8(d, max_path_bytes)) else null,
        .rejection_reason = if (lc.rejection_reason) |r| try a.dupe(u8, truncateUtf8(r, max_text_bytes)) else null,
    };
}

/// Longest prefix of at most `cap` bytes that does not split a UTF-8
/// sequence.
pub fn truncateUtf8(s: []const u8, cap: usize) []const u8 {
    if (s.len <= cap) return s;
    var end = cap;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}
