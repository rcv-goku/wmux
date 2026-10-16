//! Vault session index (agents-vault-sidebar, hosted-vault-session-search-pane):
//! the session record model built from agent transcript metadata, a per-line
//! JSONL classifier shared with checkpoints.zig, and incremental indexing
//! state. Pure: callers stat and read files (worker thread) and feed the bytes
//! here; nothing in this file touches the file system or the clock.
//!
//! Supported transcript formats (interface facts only):
//! - Claude Code: `~/.claude/projects/<slug>/<session-id>.jsonl`, one record
//!   per line with `type`, `sessionId`, `cwd`, `gitBranch`, `timestamp`,
//!   `isMeta`, `isSidechain` and `message{role, content}`.
//! - Codex: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`, lines
//!   `{timestamp, type, payload}` with `session_meta` (id, cwd, git.branch) and
//!   `response_item` messages; the older un-wrapped item layout is accepted.
//! - Pi-style (`pi`, `omp` and the generic fallback for registered agents): a
//!   `{type:"session", id, cwd, timestamp}` header and `message{role, content}`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

/// Byte cap of the searchable transcript text kept per session (G6).
pub const max_text_bytes: usize = 1 << 20;
/// Byte cap of one indexed text block (tool output can be huge).
pub const max_block_bytes: usize = 4096;
/// Byte cap of titles, cwd, branch and ids.
pub const max_field_bytes: usize = 4096;
/// Lines longer than this are skipped as malformed (never parsed).
pub const max_line_bytes: usize = 16 << 20;
/// Records nesting arrays/objects deeper than this are skipped as malformed.
/// No agent record comes close, and it keeps the re-serialization in
/// `checkpoints.fork` within std.json.Stringify's checked nesting limit (256
/// levels in safe builds).
pub const max_json_depth: usize = 128;
/// Record timestamps outside years 0000-9999 (what ISO 8601 text can express)
/// are corrupt and ignored, which keeps the day arithmetic in `sectionFor` and
/// `writeIso8601` free of overflow.
pub const min_timestamp_ms: i64 = daysFromCivil(0, 1, 1) * 86_400_000;
pub const max_timestamp_ms: i64 = daysFromCivil(10000, 1, 1) * 86_400_000 - 1;
/// Title fallback when a session has no user prompt.
pub const untitled = "Untitled chat";
/// Suffix appended to the titles of forked sessions.
pub const fork_suffix = " (fork)";

/// How a transcript file is laid out.
pub const Format = enum {
    claude_code,
    codex,
    /// Pi-style header + message records; also the fallback for registered agents.
    pi,

    /// Format of a built-in or registered agent id.
    pub fn forAgent(agent: []const u8) Format {
        if (std.mem.eql(u8, agent, "claude")) return .claude_code;
        if (std.mem.eql(u8, agent, "codex")) return .codex;
        return .pi;
    }
};

/// Display name of a built-in agent id, or null for unknown/registered ids
/// (their name comes from the `vault.agents` registration).
pub fn builtinAgentName(agent: []const u8) ?[]const u8 {
    const names = std.StaticStringMap([]const u8).initComptime(.{
        .{ "amp", "Amp" },
        .{ "antigravity", "Antigravity" },
        .{ "campfire", "Campfire" },
        .{ "claude", "Claude Code" },
        .{ "codex", "Codex" },
        .{ "grok", "Grok" },
        .{ "hermes-agent", "Hermes Agent" },
        .{ "kimi", "Kimi Code" },
        .{ "omp", "OMP" },
        .{ "opencode", "OpenCode" },
        .{ "pi", "Pi" },
        .{ "rovodev", "Rovo Dev" },
    });
    return names.get(agent);
}

/// Live status filter values (cmux: Live, Active, Idle, Inactive, Ended). The
/// index cannot see live terminals; the app overrides `Session.status`.
pub const Status = enum {
    live,
    active,
    idle,
    inactive,
    ended,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .live => "Live",
            .active => "Active",
            .idle => "Idle",
            .inactive => "Inactive",
            .ended => "Ended",
        };
    }
};

/// One indexed agent session. All slices are owned by the session.
pub const Session = struct {
    /// Agent id (`claude`, `codex`, `pi`, registered ids).
    agent: []u8,
    /// Native session id; falls back to the transcript file stem.
    id: []u8,
    /// Transcript path as given by the caller.
    path: []u8,
    cwd: []u8,
    branch: []u8,
    /// First user prompt (one line, capped); empty when none yet.
    title: []u8,
    /// Searchable transcript text, newline separated, capped at `max_text_bytes`.
    text: std.ArrayList(u8) = .empty,
    text_truncated: bool = false,
    /// True when this session was created by a Vault fork (set by the caller
    /// from the checkpoint store); adds the "(fork)" title suffix.
    forked: bool = false,
    status: Status = .inactive,
    created_ms: i64 = 0,
    /// Latest record timestamp seen in the transcript.
    last_record_ms: i64 = 0,
    /// File modification time from the last stat (0 = unknown).
    mtime_ms: i64 = 0,
    /// Number of user-prompt turns.
    turns: u32 = 0,
    malformed_lines: u32 = 0,

    pub fn deinit(self: *Session, gpa: Allocator) void {
        gpa.free(self.agent);
        gpa.free(self.id);
        gpa.free(self.path);
        gpa.free(self.cwd);
        gpa.free(self.branch);
        gpa.free(self.title);
        self.text.deinit(gpa);
        self.* = undefined;
    }

    /// Last activity used for ordering and date filters: the newer of the file
    /// mtime and the last record timestamp.
    pub fn modifiedMs(self: *const Session) i64 {
        return @max(self.mtime_ms, self.last_record_ms);
    }

    /// Display name of the agent (built-in table, else the raw id).
    pub fn agentName(self: *const Session) []const u8 {
        return builtinAgentName(self.agent) orelse self.agent;
    }

    /// True when some transcript content may be missing from `text`.
    pub fn partiallySearchable(self: *const Session) bool {
        return self.text_truncated or self.malformed_lines > 0;
    }

    /// Row title: first prompt or "Untitled chat", plus " (fork)" for forks.
    pub fn writeTitle(self: *const Session, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(if (self.title.len == 0) untitled else self.title);
        if (self.forked) try w.writeAll(fork_suffix);
    }
};

// ---------------------------------------------------------------------------
// Line classification (shared with checkpoints.zig)

pub const LineKind = enum {
    /// A user-authored prompt: starts a turn.
    user_prompt,
    /// Any other user record (tool results, injected context, meta).
    user_other,
    assistant,
    /// Session header / metadata record.
    meta,
    other,
    malformed,
};

/// Facts extracted from one transcript line. Slices point into the parse
/// arena passed to `classifyLine` and are only valid until it is reset.
pub const LineInfo = struct {
    kind: LineKind = .other,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    /// Text worth indexing (prompt, reply, tool output), possibly empty.
    text: []const u8 = "",
};

/// Parses one JSONL line (without the newline). Never fails on bad input:
/// unparsable, oversized and too deeply nested lines classify as
/// `.malformed`; only OOM is an error.
pub fn classifyLine(arena: Allocator, format: Format, line: []const u8) Allocator.Error!LineInfo {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return .{ .kind = .other };
    if (trimmed.len > max_line_bytes or nestingExceeds(trimmed, max_json_depth)) return .{ .kind = .malformed };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .kind = .malformed },
    };
    if (root != .object) return .{ .kind = .malformed };
    return switch (format) {
        .claude_code => classifyClaude(arena, root.object),
        .codex => classifyCodex(arena, root.object),
        .pi => classifyPi(arena, root.object),
    };
}

/// True when the JSON text `bytes` opens more than `limit` nested arrays or
/// objects at some point. Brackets inside strings do not count.
fn nestingExceeds(bytes: []const u8, limit: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
        } else switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > limit) return true;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return false;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getObj(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn timestampOf(obj: std.json.ObjectMap) ?i64 {
    const v = obj.get("timestamp") orelse return null;
    const ts: i64 = switch (v) {
        .string => |s| parseIso8601Ms(s) orelse return null,
        // Epoch milliseconds (some agents) or seconds (heuristic: < 1e11).
        .integer => |n| if (n < 100_000_000_000) std.math.mul(i64, n, 1000) catch return null else n,
        else => return null,
    };
    if (ts < min_timestamp_ms or ts > max_timestamp_ms) return null;
    return ts;
}

/// Concatenated text of a message `content`: a string, or an array of blocks
/// whose `text` (text/input_text/output_text) or tool-result content is
/// collected. `include_tools` also collects tool_result content.
fn contentText(arena: Allocator, content: std.json.Value, include_tools: bool) Allocator.Error![]const u8 {
    switch (content) {
        .string => |s| return s,
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            for (arr.items) |item| {
                if (item != .object) {
                    if (item == .string) try appendBlock(arena, &out, item.string);
                    continue;
                }
                const t = getStr(item.object, "type") orelse "";
                if (std.mem.eql(u8, t, "text") or std.mem.eql(u8, t, "input_text") or
                    std.mem.eql(u8, t, "output_text"))
                {
                    if (getStr(item.object, "text")) |s| try appendBlock(arena, &out, s);
                } else if (include_tools and std.mem.eql(u8, t, "tool_result")) {
                    if (item.object.get("content")) |c| {
                        const inner = try contentText(arena, c, false);
                        try appendBlock(arena, &out, proto.utf8.truncateUtf8(inner, max_block_bytes));
                    }
                }
            }
            return out.items;
        },
        else => return "",
    }
}

fn appendBlock(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    if (s.len == 0) return;
    if (out.items.len > 0) try out.append(arena, '\n');
    try out.appendSlice(arena, s);
}

/// True when content holds only tool results (no user-authored text).
fn onlyToolResults(content: std.json.Value) bool {
    if (content != .array) return false;
    var any = false;
    for (content.array.items) |item| {
        if (item != .object) return false;
        const t = getStr(item.object, "type") orelse return false;
        if (!std.mem.eql(u8, t, "tool_result")) return false;
        any = true;
    }
    return any;
}

/// Injected, non-prompt user text (command output wrappers, environment
/// context, instruction files).
fn isInjectedPrompt(text: []const u8) bool {
    const t = std.mem.trimLeft(u8, text, " \t\r\n");
    if (t.len == 0) return true;
    const prefixes = [_][]const u8{
        "<local-command-",
        "<environment_context>",
        "<user_instructions>",
        "<system-reminder>",
        "# AGENTS.md instructions",
        "Caveat: The messages below were generated",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, t, p)) return true;
    return false;
}

fn classifyClaude(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error!LineInfo {
    var info: LineInfo = .{
        .session_id = getStr(obj, "sessionId"),
        .cwd = getStr(obj, "cwd"),
        .branch = getStr(obj, "gitBranch"),
        .timestamp_ms = timestampOf(obj),
    };
    const t = getStr(obj, "type") orelse "";
    const msg = getObj(obj, "message");
    if (std.mem.eql(u8, t, "user")) {
        const content = if (msg) |m| m.get("content") orelse .null else .null;
        if (getBool(obj, "isSidechain") or getBool(obj, "isMeta") or onlyToolResults(content)) {
            info.kind = .user_other;
            info.text = try contentText(arena, content, true);
            return info;
        }
        info.text = try contentText(arena, content, true);
        info.kind = if (isInjectedPrompt(info.text)) .user_other else .user_prompt;
    } else if (std.mem.eql(u8, t, "assistant")) {
        info.kind = .assistant;
        if (msg) |m| if (m.get("content")) |c| {
            info.text = try contentText(arena, c, false);
        };
    } else if (std.mem.eql(u8, t, "summary")) {
        info.kind = .meta;
    } else {
        info.kind = .other;
    }
    return info;
}

fn classifyCodex(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error!LineInfo {
    var info: LineInfo = .{ .timestamp_ms = timestampOf(obj) };
    const outer = getStr(obj, "type") orelse "";
    // New layout wraps items in `payload`; old layout has items at top level
    // and a first line `{id, timestamp, instructions, git}`.
    const payload = getObj(obj, "payload");
    if (std.mem.eql(u8, outer, "session_meta") or
        (payload == null and outer.len == 0 and getStr(obj, "id") != null))
    {
        const meta = payload orelse obj;
        info.kind = .meta;
        info.session_id = getStr(meta, "id");
        info.cwd = getStr(meta, "cwd");
        if (getObj(meta, "git")) |g| info.branch = getStr(g, "branch");
        if (info.timestamp_ms == null) info.timestamp_ms = timestampOf(meta);
        return info;
    }
    if (std.mem.eql(u8, outer, "turn_context")) {
        info.kind = .meta;
        if (payload) |p| info.cwd = getStr(p, "cwd");
        return info;
    }
    const item = if (std.mem.eql(u8, outer, "response_item")) payload orelse return info else if (payload == null) obj else return info;
    const it = getStr(item, "type") orelse "";
    if (!std.mem.eql(u8, it, "message")) {
        if (std.mem.eql(u8, it, "function_call_output")) {
            info.kind = .other;
            if (item.get("output")) |o| if (o == .string) {
                info.text = proto.utf8.truncateUtf8(o.string, max_block_bytes);
            };
        }
        return info;
    }
    const role = getStr(item, "role") orelse "";
    const content = item.get("content") orelse .null;
    info.text = try contentText(arena, content, false);
    if (std.mem.eql(u8, role, "user")) {
        info.kind = if (isInjectedPrompt(info.text)) .user_other else .user_prompt;
    } else if (std.mem.eql(u8, role, "assistant")) {
        info.kind = .assistant;
    } else {
        info.kind = .other;
        info.text = "";
    }
    return info;
}

fn classifyPi(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error!LineInfo {
    var info: LineInfo = .{
        .timestamp_ms = timestampOf(obj),
        .cwd = getStr(obj, "cwd"),
        .branch = getStr(obj, "gitBranch") orelse getStr(obj, "branch"),
    };
    const t = getStr(obj, "type") orelse "";
    if (std.mem.eql(u8, t, "session") or std.mem.eql(u8, t, "session_meta")) {
        info.kind = .meta;
        info.session_id = getStr(obj, "id") orelse getStr(obj, "sessionId");
        return info;
    }
    info.session_id = getStr(obj, "sessionId") orelse getStr(obj, "session_id");
    const msg = getObj(obj, "message") orelse obj;
    const role = getStr(msg, "role") orelse {
        info.kind = .other;
        return info;
    };
    const content = msg.get("content") orelse .null;
    if (std.mem.eql(u8, role, "user")) {
        if (onlyToolResults(content)) {
            info.kind = .user_other;
            info.text = try contentText(arena, content, true);
            return info;
        }
        info.text = try contentText(arena, content, true);
        info.kind = if (isInjectedPrompt(info.text)) .user_other else .user_prompt;
    } else if (std.mem.eql(u8, role, "assistant")) {
        info.kind = .assistant;
        info.text = try contentText(arena, content, false);
    } else {
        // toolResult / tool roles: index the output but never start a turn.
        info.kind = .other;
        info.text = proto.utf8.truncateUtf8(try contentText(arena, content, true), max_block_bytes);
    }
    return info;
}

// ---------------------------------------------------------------------------
// Time helpers

/// Days since 1970-01-01 of a proleptic Gregorian civil date.
pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

/// Inverse of `daysFromCivil`.
pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .month = m, .day = d };
}

fn digits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(y: i64, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if ((@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0) 29 else 28,
    };
}

/// Parses `yyyy-MM-dd` into days since the epoch; null when malformed or
/// not a real calendar date.
pub fn parseDate(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = digits(s[0..4]) orelse return null;
    const m = digits(s[5..7]) orelse return null;
    const d = digits(s[8..10]) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(y, @intCast(m))) return null;
    return daysFromCivil(y, @intCast(m), @intCast(d));
}

/// Parses an RFC 3339 / ISO 8601 timestamp (`2026-10-16T12:34:56.789Z`,
/// fractional seconds optional, `Z` or `±hh:mm`, missing zone = UTC) into
/// Unix milliseconds.
pub fn parseIso8601Ms(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const days = parseDate(s[0..10]) orelse return null;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    if (s[13] != ':' or s[16] != ':') return null;
    const hh = digits(s[11..13]) orelse return null;
    const mi = digits(s[14..16]) orelse return null;
    const ss = digits(s[17..19]) orelse return null;
    if (hh > 23 or mi > 59 or ss > 60) return null;
    var i: usize = 19;
    var ms: i64 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            ms += @as(i64, s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
        if (i == start) return null;
    }
    var offset_min: i64 = 0;
    if (i < s.len) {
        const z = s[i];
        if (z == 'Z' or z == 'z') {
            i += 1;
        } else if (z == '+' or z == '-') {
            if (s.len - i != 6 or s[i + 3] != ':') return null;
            const oh = digits(s[i + 1 .. i + 3]) orelse return null;
            const om = digits(s[i + 4 .. i + 6]) orelse return null;
            offset_min = @as(i64, oh) * 60 + om;
            if (z == '-') offset_min = -offset_min;
            i += 6;
        } else return null;
    }
    if (i != s.len) return null;
    const secs = days * 86400 + @as(i64, hh) * 3600 + @as(i64, mi) * 60 + ss - offset_min * 60;
    return secs * 1000 + ms;
}

/// Writes `ms` as `yyyy-MM-ddTHH:mm:ssZ` (UTC, second precision).
pub fn writeIso8601(w: *std.Io.Writer, ms: i64) std.Io.Writer.Error!void {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86400);
    const rem: u64 = @intCast(secs - days * 86400);
    const c = civilFromDays(days);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(@max(c.year, 0))), c.month,       c.day,
        rem / 3600,                          rem / 60 % 60, rem % 60,
    });
}

/// Recency section of the All Sessions view.
pub const Section = enum {
    today,
    yesterday,
    last_7_days,
    last_30_days,
    older,

    pub fn label(self: Section) []const u8 {
        return switch (self) {
            .today => "Today",
            .yesterday => "Yesterday",
            .last_7_days => "Last 7 days",
            .last_30_days => "Last 30 days",
            .older => "Older",
        };
    }
};

/// Local-day difference based section; `tz_offset_min` is the local offset
/// from UTC (e.g. +120 for UTC+2). Future timestamps count as Today.
pub fn sectionFor(modified_ms: i64, now_ms: i64, tz_offset_min: i32) Section {
    const off = @as(i64, tz_offset_min) * 60_000;
    const day_now = @divFloor(now_ms + off, 86_400_000);
    const day_mod = @divFloor(modified_ms + off, 86_400_000);
    const diff = day_now - day_mod;
    if (diff <= 0) return .today;
    if (diff == 1) return .yesterday;
    if (diff < 7) return .last_7_days;
    if (diff < 30) return .last_30_days;
    return .older;
}

// ---------------------------------------------------------------------------
// Paths

/// Last component of a `/` or `\` path, ignoring trailing separators. The
/// Windows style accepts both separators, which suits transcripts written by
/// Windows and POSIX agents alike.
pub fn basename(path: []const u8) []const u8 {
    return proto.paths.basename(.windows, path);
}

/// File name without its final extension (`abc.jsonl` -> `abc`).
pub fn fileStem(path: []const u8) []const u8 {
    const b = basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, b, '.') orelse return b;
    return if (dot == 0) b else b[0..dot];
}

/// Claude Code project directory name for a cwd: every byte that is not an
/// ASCII letter or digit becomes `-` (so `C:\src\wmux` -> `C--src-wmux`).
pub fn claudeProjectSlug(gpa: Allocator, cwd: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, cwd.len);
    for (cwd, out) |c, *o| o.* = if (std.ascii.isAlphanumeric(c)) c else '-';
    return out;
}

/// CLI text row `agent<TAB>id<TAB>status<TAB>modified<TAB>title<TAB>cwd`.
/// Tabs and newlines inside fields are replaced by spaces.
pub fn writeTextRow(w: *std.Io.Writer, s: *const Session) std.Io.Writer.Error!void {
    try writeField(w, s.agent);
    try w.writeByte('\t');
    try writeField(w, s.id);
    try w.writeByte('\t');
    try w.writeAll(@tagName(s.status));
    try w.writeByte('\t');
    try writeIso8601(w, s.modifiedMs());
    try w.writeByte('\t');
    try writeField(w, if (s.title.len == 0) untitled else s.title);
    if (s.forked) try w.writeAll(fork_suffix);
    try w.writeByte('\t');
    try writeField(w, s.cwd);
    try w.writeByte('\n');
}

fn writeField(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| try w.writeByte(if (c == '\t' or c == '\n' or c == '\r') ' ' else c);
}

// ---------------------------------------------------------------------------
// Incremental indexing

/// Result of a stat, supplied by the caller.
pub const FileStamp = struct {
    size: u64,
    mtime_ms: i64,
};

/// What the caller should read next for a transcript.
pub const Plan = union(enum) {
    /// Nothing changed since the last ingest.
    unchanged,
    /// Read bytes `[offset, size)` and call `Index.ingest` with that offset.
    /// Offset 0 means a full (re)parse.
    read_from: u64,
};

/// Per-transcript state: the session plus how far the file was consumed.
pub const Entry = struct {
    session: Session,
    format: Format,
    stamp: FileStamp,
    /// Bytes consumed (always ends at a line boundary).
    consumed: u64 = 0,
    /// Set by `Index.beginScan`, cleared by `Index.markSeen`/`ingest`.
    stale: bool = false,
    /// A failed ingest left the session half-applied: re-parse from 0.
    dirty: bool = false,

    fn deinit(self: *Entry, gpa: Allocator) void {
        self.session.deinit(gpa);
        self.* = undefined;
    }
};

/// All indexed transcripts keyed by path. Owned by one thread (the indexer
/// worker); hand results to the UI as copies.
pub const Index = struct {
    gpa: Allocator,
    entries: std.StringArrayHashMapUnmanaged(*Entry) = .empty,

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.values()) |e| {
            e.deinit(self.gpa);
            self.gpa.destroy(e);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: *const Index) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Index, path: []const u8) ?*Entry {
        return self.entries.get(path);
    }

    /// Decides what to read for `path` given a fresh stat. A shrunk file or an
    /// mtime that moved backwards is re-parsed from 0 (rewritten/replaced).
    pub fn plan(self: *const Index, path: []const u8, stamp: FileStamp) Plan {
        const e = self.entries.get(path) orelse return .{ .read_from = 0 };
        if (e.dirty) return .{ .read_from = 0 };
        if (stamp.size < e.consumed or stamp.mtime_ms < e.stamp.mtime_ms) return .{ .read_from = 0 };
        if (stamp.size == e.stamp.size and stamp.mtime_ms == e.stamp.mtime_ms) return .unchanged;
        if (stamp.size == e.consumed) return .unchanged;
        return .{ .read_from = e.consumed };
    }

    pub const IngestError = Allocator.Error || error{OffsetMismatch};

    /// Feeds bytes `[offset, offset + bytes.len)` of the transcript at `path`.
    /// `offset` must be 0 (full parse; resets the entry) or the entry's
    /// `consumed`. Only complete lines are consumed; an unterminated tail is
    /// consumed only when `at_eof` and it parses as a JSON object. Returns the
    /// entry.
    pub fn ingest(
        self: *Index,
        path: []const u8,
        agent: []const u8,
        stamp: FileStamp,
        offset: u64,
        bytes: []const u8,
        at_eof: bool,
    ) IngestError!*Entry {
        const gop = try self.entries.getOrPut(self.gpa, path);
        if (!gop.found_existing) {
            errdefer self.entries.swapRemoveAt(gop.index);
            if (offset != 0) return error.OffsetMismatch;
            const e = try self.gpa.create(Entry);
            errdefer self.gpa.destroy(e);
            e.* = .{ .session = try newSession(self.gpa, agent, path), .format = Format.forAgent(agent), .stamp = stamp };
            gop.value_ptr.* = e;
            gop.key_ptr.* = e.session.path;
        }
        const e = gop.value_ptr.*;
        if (offset == 0 and (e.consumed != 0 or e.dirty or !std.mem.eql(u8, e.session.agent, agent))) {
            const fresh = try newSession(self.gpa, agent, path);
            e.session.deinit(self.gpa);
            e.* = .{ .session = fresh, .format = Format.forAgent(agent), .stamp = stamp };
            gop.key_ptr.* = e.session.path;
        } else if (offset != e.consumed or e.dirty) {
            return error.OffsetMismatch;
        }
        errdefer e.dirty = true;
        e.stale = false;
        e.stamp = stamp;
        e.session.mtime_ms = stamp.mtime_ms;
        e.consumed += try feed(self.gpa, &e.session, e.format, bytes, at_eof);
        return e;
    }

    /// Marks every entry stale before a directory scan.
    pub fn beginScan(self: *Index) void {
        for (self.entries.values()) |e| e.stale = true;
    }

    /// Marks a transcript as still present (unchanged files are not ingested).
    pub fn markSeen(self: *Index, path: []const u8) void {
        if (self.entries.get(path)) |e| e.stale = false;
    }

    /// Drops entries not seen since `beginScan`; returns how many.
    pub fn endScan(self: *Index) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.entries.count()) {
            const e = self.entries.values()[i];
            if (e.stale) {
                self.entries.swapRemoveAt(i);
                e.deinit(self.gpa);
                self.gpa.destroy(e);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    /// Sessions newest first (ties: agent, then id). Caller frees the slice;
    /// the pointers stay valid until the next mutation.
    pub fn sessions(self: *const Index, gpa: Allocator) Allocator.Error![]*const Session {
        const out = try gpa.alloc(*const Session, self.entries.count());
        for (self.entries.values(), out) |e, *o| o.* = &e.session;
        sortByRecency(out);
        return out;
    }
};

/// Sorts newest first; ties by agent then id for a stable, total order.
pub fn sortByRecency(list: []*const Session) void {
    std.mem.sort(*const Session, list, {}, struct {
        fn lt(_: void, a: *const Session, b: *const Session) bool {
            const ma = a.modifiedMs();
            const mb = b.modifiedMs();
            if (ma != mb) return ma > mb;
            const o = std.mem.order(u8, a.agent, b.agent);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
}

fn newSession(gpa: Allocator, agent: []const u8, path: []const u8) Allocator.Error!Session {
    const a = try proto.utf8.dupeTruncated(gpa, agent, max_field_bytes);
    errdefer gpa.free(a);
    const p = try gpa.dupe(u8, path);
    errdefer gpa.free(p);
    const id = try proto.utf8.dupeTruncated(gpa, fileStem(path), max_field_bytes);
    errdefer gpa.free(id);
    const cwd = try gpa.alloc(u8, 0);
    errdefer gpa.free(cwd);
    const branch = try gpa.alloc(u8, 0);
    errdefer gpa.free(branch);
    const title = try gpa.alloc(u8, 0);
    return .{ .agent = a, .id = id, .path = p, .cwd = cwd, .branch = branch, .title = title };
}

/// Iterates complete lines of `bytes`; see `Index.ingest` for the tail rule.
pub const LineIterator = struct {
    bytes: []const u8,
    at_eof: bool,
    pos: usize = 0,

    pub const Line = struct { start: usize, end: usize, next: usize };

    /// Next line `[start, end)`, with `next` the offset after its newline.
    /// An unterminated tail is returned only when `at_eof` (the caller decides
    /// whether to consume it).
    pub fn next(self: *LineIterator) ?Line {
        if (self.pos >= self.bytes.len) return null;
        const start = self.pos;
        if (std.mem.indexOfScalarPos(u8, self.bytes, start, '\n')) |nl| {
            self.pos = nl + 1;
            return .{ .start = start, .end = nl, .next = nl + 1 };
        }
        if (!self.at_eof) return null;
        self.pos = self.bytes.len;
        return .{ .start = start, .end = self.bytes.len, .next = self.bytes.len };
    }
};

/// True when an unterminated tail is one complete JSON object (safe to consume).
pub fn tailIsComplete(gpa: Allocator, line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] != '{') return false;
    return std.json.validate(gpa, t) catch false;
}

/// Folds `bytes` into `s`; returns the number of bytes consumed.
fn feed(gpa: Allocator, s: *Session, format: Format, bytes: []const u8, at_eof: bool) Allocator.Error!u64 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var it: LineIterator = .{ .bytes = bytes, .at_eof = at_eof };
    var consumed: usize = 0;
    while (it.next()) |ln| {
        const line = bytes[ln.start..ln.end];
        // An unterminated tail (no newline) may still be mid-write.
        if (ln.next == ln.end and !tailIsComplete(gpa, line)) break;
        _ = arena_state.reset(.retain_capacity);
        const info = try classifyLine(arena_state.allocator(), format, line);
        try apply(gpa, s, info);
        consumed = ln.next;
    }
    return consumed;
}

fn setField(gpa: Allocator, field: *[]u8, value: []const u8) Allocator.Error!void {
    const v = proto.utf8.truncateUtf8(value, max_field_bytes);
    if (std.mem.eql(u8, field.*, v)) return;
    const copy = try gpa.dupe(u8, v);
    gpa.free(field.*);
    field.* = copy;
}

/// One-line title from prompt text: first non-empty line, whitespace
/// collapsed, capped at 200 bytes on a code-point boundary.
pub fn titleFromPrompt(buf: []u8, text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        var n: usize = 0;
        var prev_space = false;
        for (line) |c| {
            const space = c == ' ' or c == '\t';
            if (space and prev_space) continue;
            if (n == buf.len) break;
            buf[n] = if (space) ' ' else c;
            n += 1;
            prev_space = space;
        }
        return proto.utf8.truncateUtf8(buf[0..n], @min(n, 200));
    }
    return "";
}

fn apply(gpa: Allocator, s: *Session, info: LineInfo) Allocator.Error!void {
    if (info.kind == .malformed) {
        s.malformed_lines +|= 1;
        return;
    }
    if (info.session_id) |id| if (id.len > 0) try setField(gpa, &s.id, id);
    if (info.cwd) |c| if (c.len > 0) try setField(gpa, &s.cwd, c);
    if (info.branch) |b| if (b.len > 0) try setField(gpa, &s.branch, b);
    if (info.timestamp_ms) |ts| {
        if (s.created_ms == 0 or ts < s.created_ms) s.created_ms = ts;
        if (ts > s.last_record_ms) s.last_record_ms = ts;
    }
    if (info.kind == .user_prompt) {
        s.turns +|= 1;
        if (s.title.len == 0) {
            var buf: [256]u8 = undefined;
            try setField(gpa, &s.title, titleFromPrompt(&buf, info.text));
        }
    }
    if (info.text.len > 0) try appendText(gpa, s, info.text);
}

fn appendText(gpa: Allocator, s: *Session, text: []const u8) Allocator.Error!void {
    if (s.text_truncated) return;
    const sep: usize = if (s.text.items.len > 0) 1 else 0;
    const room = max_text_bytes -| (s.text.items.len + sep);
    const block = proto.utf8.truncateUtf8(text, room);
    if (block.len < text.len) s.text_truncated = true;
    if (block.len == 0) return;
    if (sep == 1) try s.text.append(gpa, '\n');
    try s.text.appendSlice(gpa, block);
}
