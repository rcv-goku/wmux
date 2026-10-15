//! Names of the CMUX_*/WMUX_* environment variables read or set by the app, CLI
//! and shells (ADR-3.9, Appendix G.2), plus a small pure `Env` lookup used by
//! `channel.zig` and `paths.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ----- read by the app and the CLI (Appendix G.2) -----
pub const WMUX_CHANNEL = "WMUX_CHANNEL";
pub const WMUX_TAG = "WMUX_TAG";
pub const WMUX_STATE_DIR = "WMUX_STATE_DIR";
pub const WMUX_CONFIG_DIR = "WMUX_CONFIG_DIR";
pub const XDG_CONFIG_HOME = "XDG_CONFIG_HOME";
pub const WMUX_WEB_DIR = "WMUX_WEB_DIR";
pub const WMUX_WEB_DEVTOOLS = "WMUX_WEB_DEVTOOLS";
pub const WMUX_TEST_MODE = "WMUX_TEST_MODE";
pub const WMUX_TEST_HIDDEN = "WMUX_TEST_HIDDEN";
pub const WMUX_TEST_TOAST_SINK = "WMUX_TEST_TOAST_SINK";
pub const WMUX_TEST_SESSION_RESTORE = "WMUX_TEST_SESSION_RESTORE";
pub const WMUX_DISABLE_SESSION_RESTORE = "WMUX_DISABLE_SESSION_RESTORE";
pub const CMUX_DISABLE_SESSION_RESTORE = "CMUX_DISABLE_SESSION_RESTORE";
pub const WMUX_SOCKET_MODE = "WMUX_SOCKET_MODE";
pub const CMUX_SOCKET_MODE = "CMUX_SOCKET_MODE";
pub const WMUX_SOCKET_ENABLE = "WMUX_SOCKET_ENABLE";
pub const CMUX_SOCKET_ENABLE = "CMUX_SOCKET_ENABLE";
pub const WMUX_SOCKET_PASSWORD = "WMUX_SOCKET_PASSWORD";
pub const CMUX_SOCKET_PASSWORD = "CMUX_SOCKET_PASSWORD";
pub const WMUX_SOCKET_PATH = "WMUX_SOCKET_PATH";
pub const CMUX_SOCKET_PATH = "CMUX_SOCKET_PATH";
/// Deprecated alias of `CMUX_SOCKET_PATH`; exported empty into terminals.
pub const CMUX_SOCKET = "CMUX_SOCKET";
pub const WMUX_ALLOW_SOCKET_OVERRIDE = "WMUX_ALLOW_SOCKET_OVERRIDE";
pub const CMUX_ALLOW_SOCKET_OVERRIDE = "CMUX_ALLOW_SOCKET_OVERRIDE";
pub const WMUX_SOCKET_CAPABILITY = "WMUX_SOCKET_CAPABILITY";
pub const CMUX_SOCKET_CAPABILITY = "CMUX_SOCKET_CAPABILITY";
pub const WMUX_CLI_RESPONSE_TIMEOUT_SEC = "WMUX_CLI_RESPONSE_TIMEOUT_SEC";
pub const CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC = "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC";
pub const WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS = "WMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS";
pub const CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS = "CMUX_APP_STARTUP_WAIT_TIMEOUT_SECONDS";
pub const WMUX_FOCUS_NEW = "WMUX_FOCUS_NEW";
pub const CMUX_FOCUS_NEW = "CMUX_FOCUS_NEW";
pub const WMUX_QUIET = "WMUX_QUIET";
pub const CMUX_QUIET = "CMUX_QUIET";
pub const WMUX_ARGV0 = "WMUX_ARGV0";

// ----- exported into every terminal (ADR-3.9) -----
pub const CMUX_WORKSPACE_ID = "CMUX_WORKSPACE_ID";
pub const WMUX_WORKSPACE_ID = "WMUX_WORKSPACE_ID";
pub const CMUX_SURFACE_ID = "CMUX_SURFACE_ID";
pub const WMUX_SURFACE_ID = "WMUX_SURFACE_ID";
/// cmux legacy alias of the surface id (no WMUX_ twin).
pub const CMUX_PANEL_ID = "CMUX_PANEL_ID";
/// The **workspace** UUID (cmux legacy meaning; no WMUX_ twin).
pub const CMUX_TAB_ID = "CMUX_TAB_ID";
pub const CMUX_PANE_ID = "CMUX_PANE_ID";
pub const WMUX_PANE_ID = "WMUX_PANE_ID";
pub const CMUX_TERMINAL_LIFECYCLE_ID = "CMUX_TERMINAL_LIFECYCLE_ID";
pub const WMUX_TERMINAL_LIFECYCLE_ID = "WMUX_TERMINAL_LIFECYCLE_ID";
pub const CMUX_BUNDLE_ID = "CMUX_BUNDLE_ID";
pub const WMUX_BUNDLE_ID = "WMUX_BUNDLE_ID";
pub const CMUX_BUNDLED_CLI_PATH = "CMUX_BUNDLED_CLI_PATH";
pub const WMUX_BUNDLED_CLI_PATH = "WMUX_BUNDLED_CLI_PATH";
pub const CMUX_SHELL_INTEGRATION_DIR = "CMUX_SHELL_INTEGRATION_DIR";
pub const CMUX_HISTORY_FILE = "CMUX_HISTORY_FILE";
pub const CMUX_PORT = "CMUX_PORT";
pub const CMUX_PORT_END = "CMUX_PORT_END";
pub const CMUX_PORT_RANGE = "CMUX_PORT_RANGE";
pub const TERM = "TERM";
pub const COLORTERM = "COLORTERM";
pub const TERM_PROGRAM = "TERM_PROGRAM";
pub const TERM_PROGRAM_VERSION = "TERM_PROGRAM_VERSION";
pub const GHOSTTY_PID = "GHOSTTY_PID";
pub const GHOSTTY_SURFACE_ID = "GHOSTTY_SURFACE_ID";
pub const GHOSTTY_BIN_DIR = "GHOSTTY_BIN_DIR";
pub const PATH = "PATH";
pub const WSLENV = "WSLENV";

// ----- OS / base directories -----
pub const LOCALAPPDATA = "LOCALAPPDATA";
pub const USERPROFILE = "USERPROFILE";
pub const HOME = "HOME";
pub const XDG_STATE_HOME = "XDG_STATE_HOME";
pub const TMUX = "TMUX";

/// Keys the app re-applies last so no workspace/layout/config env can
/// override them (ADR-3.9). `CMUX_SOCKET_PASSWORD`, `CMUX_HISTORY_FILE` and the
/// port block are conditional and not listed.
pub const protected_terminal_env = [_][]const u8{
    CMUX_WORKSPACE_ID,          WMUX_WORKSPACE_ID,
    CMUX_SURFACE_ID,            WMUX_SURFACE_ID,
    CMUX_PANEL_ID,              CMUX_TAB_ID,
    CMUX_PANE_ID,               WMUX_PANE_ID,
    CMUX_TERMINAL_LIFECYCLE_ID, WMUX_TERMINAL_LIFECYCLE_ID,
    CMUX_SOCKET_PATH,           WMUX_SOCKET_PATH,
    CMUX_SOCKET,                CMUX_SOCKET_CAPABILITY,
    WMUX_SOCKET_CAPABILITY,     CMUX_BUNDLE_ID,
    WMUX_BUNDLE_ID,             CMUX_BUNDLED_CLI_PATH,
    WMUX_BUNDLED_CLI_PATH,      CMUX_SHELL_INTEGRATION_DIR,
};

pub fn isProtectedTerminalEnv(name: []const u8) bool {
    for (protected_terminal_env) |p| if (eqlEnvName(p, name)) return true;
    return false;
}

/// Inherited auth variables removed from terminals unless
/// `wmux.agents.preserveAuthEnv` (ADR-3.9).
pub const stripped_auth_env = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
};

/// Variables marking a non-interactive agent caller (ADR-4.6), plus any
/// name starting with `agent_marker_prefix`.
pub const agent_markers = [_][]const u8{
    "CLAUDECODE",
    "CLAUDE_CODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CODEX_CI",
    "CODEX_THREAD_ID",
    "CODEX_SESSION_ID",
    "OPENCODE",
    "OPENCODE_SESSION_ID",
    "AI_AGENT",
};
pub const agent_marker_prefix = "CMUX_AGENT_";

pub fn isAgentMarker(name: []const u8) bool {
    for (agent_markers) |m| if (eqlEnvName(m, name)) return true;
    return name.len > agent_marker_prefix.len and startsWithEnvName(name, agent_marker_prefix);
}

/// WSLENV entries appended in terminals (ADR-3.9), in order.
pub const wslenv_entries = [_][]const u8{
    "CMUX_WORKSPACE_ID/u",      "CMUX_SURFACE_ID/u",
    "CMUX_PANEL_ID/u",          "CMUX_TAB_ID/u",
    "CMUX_PANE_ID/u",           "CMUX_TERMINAL_LIFECYCLE_ID/u",
    "CMUX_SOCKET_PATH/u",       "CMUX_SOCKET_CAPABILITY/u",
    "CMUX_BUNDLED_CLI_PATH/up", "TERM_PROGRAM/u",
    "WMUX_WORKSPACE_ID/u",      "WMUX_SURFACE_ID/u",
    "WMUX_PANE_ID/u",           "WMUX_TERMINAL_LIFECYCLE_ID/u",
    "WMUX_SOCKET_PATH/u",       "WMUX_SOCKET_CAPABILITY/u",
    "WMUX_BUNDLED_CLI_PATH/up",
};
pub const wslenv_password_entry = "CMUX_SOCKET_PASSWORD/u";

/// `existing` WSLENV plus our entries, skipping names already present (with
/// any flags). Order of `existing` is kept; empty segments are dropped.
pub fn wslenvAppend(gpa: Allocator, existing: ?[]const u8, with_password: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (existing) |ex| {
        var it = std.mem.splitScalar(u8, ex, ':');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (out.items.len > 0) try out.append(gpa, ':');
            try out.appendSlice(gpa, seg);
        }
    }
    const pw = [_][]const u8{wslenv_password_entry};
    const groups = [_][]const []const u8{ &wslenv_entries, if (with_password) &pw else &.{} };
    for (groups) |group| for (group) |entry| {
        if (wslenvHas(out.items, wslenvName(entry))) continue;
        if (out.items.len > 0) try out.append(gpa, ':');
        try out.appendSlice(gpa, entry);
    };
    return out.toOwnedSlice(gpa);
}

fn wslenvName(entry: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, entry, '/') orelse entry.len;
    return entry[0..slash];
}

fn wslenvHas(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |seg| if (eqlEnvName(wslenvName(seg), name)) return true;
    return false;
}

/// `CMUX_<AGENT>_HOOKS_DISABLED` / `WMUX_<AGENT>_HOOKS_DISABLED`; the agent
/// name is upper-cased and `-`/`.` become `_` (`claude-code` → `CLAUDE_CODE`).
pub fn hooksDisabledName(gpa: Allocator, prefix: enum { cmux, wmux }, agent: []const u8) Allocator.Error![]u8 {
    const p = if (prefix == .cmux) "CMUX_" else "WMUX_";
    const suffix = "_HOOKS_DISABLED";
    const out = try gpa.alloc(u8, p.len + agent.len + suffix.len);
    @memcpy(out[0..p.len], p);
    for (agent, 0..) |c, i| out[p.len + i] = switch (c) {
        '-', '.', ' ' => '_',
        else => std.ascii.toUpper(c),
    };
    @memcpy(out[p.len + agent.len ..], suffix);
    return out;
}

/// cmux truthiness for flags such as `CMUX_ALLOW_SOCKET_OVERRIDE`:
/// `1`, `true`, `yes`, `on` (ASCII case-insensitive, surrounding spaces ok).
pub fn isTruthy(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t");
    const truthy = [_][]const u8{ "1", "true", "yes", "on" };
    for (truthy) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    return false;
}

/// Environment names compare case-insensitively on Windows and exactly
/// elsewhere.
pub fn eqlEnvName(a: []const u8, b: []const u8) bool {
    if (@import("builtin").os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

fn startsWithEnvName(name: []const u8, prefix: []const u8) bool {
    if (name.len < prefix.len) return false;
    return eqlEnvName(name[0..prefix.len], prefix);
}

/// Pure environment lookup so resolution logic is testable without touching
/// the process environment.
pub const Env = struct {
    ctx: ?*const anyopaque,
    getFn: *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8,

    /// Raw value (possibly empty), or null when unset.
    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, name);
    }

    /// Value, treating empty as unset.
    pub fn getNonEmpty(self: Env, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return if (v.len == 0) null else v;
    }

    /// First non-empty value among `names` (twin lookups: WMUX_ then CMUX_).
    pub fn first(self: Env, names: []const []const u8) ?[]const u8 {
        for (names) |n| if (self.getNonEmpty(n)) |v| return v;
        return null;
    }

    /// Backed by a `std.process.EnvMap` (case-insensitive on Windows).
    pub fn fromEnvMap(map: *const std.process.EnvMap) Env {
        return .{ .ctx = map, .getFn = envMapGet };
    }

    fn envMapGet(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const map: *const std.process.EnvMap = @ptrCast(@alignCast(ctx.?));
        return map.get(name);
    }

    pub const Pair = struct { []const u8, []const u8 };

    /// Backed by a slice of name/value pairs (tests, fixed environments).
    pub fn fromPairs(pairs: *const []const Pair) Env {
        return .{ .ctx = @ptrCast(pairs), .getFn = pairsGet };
    }

    fn pairsGet(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const pairs: *const []const Pair = @ptrCast(@alignCast(ctx.?));
        for (pairs.*) |p| if (eqlEnvName(p[0], name)) return p[1];
        return null;
    }

    /// An environment with nothing set.
    pub const empty: Env = .{ .ctx = null, .getFn = emptyGet };

    fn emptyGet(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};

const testing = std.testing;

test "unit: proto: env_names exact cmux spellings" {
    try testing.expectEqualStrings("CMUX_SOCKET_PATH", CMUX_SOCKET_PATH);
    try testing.expectEqualStrings("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC);
    try testing.expectEqualStrings("CMUX_TAB_ID", CMUX_TAB_ID);
    try testing.expect(isProtectedTerminalEnv("CMUX_SURFACE_ID"));
    try testing.expect(isProtectedTerminalEnv("CMUX_SOCKET"));
    try testing.expect(!isProtectedTerminalEnv("WMUX_TAB_ID"));
    try testing.expect(!isProtectedTerminalEnv("PATH"));
}

test "unit: proto: env_names protected list has no duplicates" {
    for (protected_terminal_env, 0..) |a, i| {
        for (protected_terminal_env[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "unit: proto: env_names agent markers" {
    try testing.expect(isAgentMarker("CLAUDECODE"));
    try testing.expect(isAgentMarker("CODEX_THREAD_ID"));
    try testing.expect(isAgentMarker("CMUX_AGENT_FOO"));
    try testing.expect(!isAgentMarker("CMUX_AGENT_"));
    try testing.expect(!isAgentMarker("CMUX_SURFACE_ID"));
    try testing.expect(!isAgentMarker(""));
}

test "unit: proto: env_names wslenv append" {
    const gpa = testing.allocator;
    const a = try wslenvAppend(gpa, null, false);
    defer gpa.free(a);
    try testing.expect(std.mem.startsWith(u8, a, "CMUX_WORKSPACE_ID/u:CMUX_SURFACE_ID/u:CMUX_PANEL_ID/u:CMUX_TAB_ID/u:CMUX_PANE_ID/u:CMUX_TERMINAL_LIFECYCLE_ID/u:CMUX_SOCKET_PATH/u:CMUX_SOCKET_CAPABILITY/u:CMUX_BUNDLED_CLI_PATH/up:TERM_PROGRAM/u:WMUX_"));
    try testing.expect(std.mem.indexOf(u8, a, "PASSWORD") == null);
    try testing.expect(a[a.len - 1] != ':');

    const b = try wslenvAppend(gpa, "USERPROFILE/p::TERM_PROGRAM:CMUX_SURFACE_ID/l", true);
    defer gpa.free(b);
    try testing.expect(std.mem.startsWith(u8, b, "USERPROFILE/p:TERM_PROGRAM:CMUX_SURFACE_ID/l:CMUX_WORKSPACE_ID/u:CMUX_PANEL_ID/u"));
    try testing.expect(std.mem.endsWith(u8, b, ":CMUX_SOCKET_PASSWORD/u"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b, "TERM_PROGRAM"));

    // Idempotent.
    const c = try wslenvAppend(gpa, b, true);
    defer gpa.free(c);
    try testing.expectEqualStrings(b, c);
    const d = try wslenvAppend(gpa, "", false);
    defer gpa.free(d);
    try testing.expectEqualStrings(a, d);
}

test "unit: proto: env_names hooks disabled names" {
    const gpa = testing.allocator;
    const a = try hooksDisabledName(gpa, .cmux, "claude");
    defer gpa.free(a);
    try testing.expectEqualStrings("CMUX_CLAUDE_HOOKS_DISABLED", a);
    const b = try hooksDisabledName(gpa, .wmux, "claude-code.x");
    defer gpa.free(b);
    try testing.expectEqualStrings("WMUX_CLAUDE_CODE_X_HOOKS_DISABLED", b);
    const c = try hooksDisabledName(gpa, .cmux, "");
    defer gpa.free(c);
    try testing.expectEqualStrings("CMUX__HOOKS_DISABLED", c);
}

test "unit: proto: env_names truthiness" {
    for ([_][]const u8{ "1", "true", "TRUE", "Yes", "on", " on " }) |v| try testing.expect(isTruthy(v));
    for ([_][]const u8{ "", "0", "false", "no", "off", "2", "y", "enabled" }) |v| try testing.expect(!isTruthy(v));
    try testing.expect(!isTruthy(null));
}

test "unit: proto: env_names env lookup" {
    const pairs: []const Env.Pair = &.{ .{ "A", "" }, .{ "B", "b" }, .{ "C", "\u{1F600}" } };
    const env = Env.fromPairs(&pairs);
    try testing.expectEqualStrings("", env.get("A").?);
    try testing.expectEqual(@as(?[]const u8, null), env.getNonEmpty("A"));
    try testing.expectEqualStrings("b", env.first(&.{ "A", "Z", "B", "C" }).?);
    try testing.expectEqual(@as(?[]const u8, null), env.first(&.{}));
    try testing.expectEqual(@as(?[]const u8, null), Env.empty.get("B"));

    var map = std.process.EnvMap.init(testing.allocator);
    defer map.deinit();
    try map.put("WMUX_TAG", "feature");
    const menv = Env.fromEnvMap(&map);
    try testing.expectEqualStrings("feature", menv.get(WMUX_TAG).?);
    try testing.expectEqual(@as(?[]const u8, null), menv.get(WMUX_CHANNEL));
}
