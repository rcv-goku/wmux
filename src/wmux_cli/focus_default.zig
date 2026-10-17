//! Focus flags and the interactive-vs-agent focus default (ADR-4.6,
//! cli-focus-default-detection). UI-opening commands accept `--focus`,
//! `--focus <true|false>`, `--focus=<bool>` and `--no-focus` (last wins,
//! nothing after `--` counts). Without a flag they focus only when run
//! interactively and not by a coding agent; `WMUX_FOCUS_NEW`/`CMUX_FOCUS_NEW`
//! = 1|0 force the default. Commands always send an explicit `focus`.
//! Interactive detection itself is OS-specific (`Platform.isInteractive`).

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const Env = env_names.Env;

/// The help line every focus-taking command prints (cmux wording).
pub const help_line = "Default: focus when run interactively, stay in the background when run by an agent or script.";

/// Agent markers listed by the cmux inventory that `wmux_proto.env_names`
/// does not carry yet (follow-up for the integrator: fold into
/// `env_names.agent_markers`).
pub const extra_agent_markers = [_][]const u8{
    "CODEX_SANDBOX",
    "CODEX_MANAGED_BY_BUN",
    "CLAUDE_CODE_SESSION_ID",
    "OPENCODE_PORT",
};

pub const FlagError = error{InvalidFocusValue};

fn parseBool(s: []const u8) ?bool {
    const t = [_][]const u8{ "true", "1", "yes", "on" };
    const f = [_][]const u8{ "false", "0", "no", "off" };
    for (t) |x| if (std.ascii.eqlIgnoreCase(s, x)) return true;
    for (f) |x| if (std.ascii.eqlIgnoreCase(s, x)) return false;
    return null;
}

/// Scans `args` for focus flags; the last one wins. A bare `--focus`
/// consumes the next token only when it is a boolean word. Returns null when
/// no flag was given. Tokens after `--` are ignored.
pub fn parseFlags(args: []const []const u8) FlagError!?bool {
    var result: ?bool = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--no-focus")) {
            result = false;
        } else if (std.mem.eql(u8, a, "--focus")) {
            if (i + 1 < args.len) {
                if (parseBool(args[i + 1])) |b| {
                    result = b;
                    i += 1;
                    continue;
                }
            }
            result = true;
        } else if (std.mem.startsWith(u8, a, "--focus=")) {
            result = parseBool(a["--focus=".len..]) orelse return error.InvalidFocusValue;
        }
    }
    return result;
}

/// Message for `error.InvalidFocusValue` (usage error, exit 2; cmux's
/// wording).
pub const invalid_value_message = "--focus must be true|false";

/// True when any coding-agent marker is set non-empty. `all_names` is the
/// list of every variable name in the environment (for the `CMUX_AGENT_*`
/// prefix); exact names are looked up through `env`.
pub fn isAgentEnvironment(env: Env, all_names: []const []const u8) bool {
    for (env_names.agent_markers) |m| if (env.getNonEmpty(m) != null) return true;
    for (extra_agent_markers) |m| if (env.getNonEmpty(m) != null) return true;
    for (all_names) |n| {
        if (env_names.isAgentMarker(n) and env.getNonEmpty(n) != null) return true;
    }
    return false;
}

/// `WMUX_FOCUS_NEW` then `CMUX_FOCUS_NEW`: `1`/`0` (and other boolean
/// words) force the default; anything else is ignored.
pub fn forcedDefault(env: Env) ?bool {
    for ([_][]const u8{ env_names.WMUX_FOCUS_NEW, env_names.CMUX_FOCUS_NEW }) |n| {
        if (env.getNonEmpty(n)) |v| if (parseBool(std.mem.trim(u8, v, " \t"))) |b| return b;
    }
    return null;
}

/// The default when no flag was given.
pub fn defaultFocus(interactive: bool, env: Env, all_names: []const []const u8) bool {
    if (forcedDefault(env)) |b| return b;
    return interactive and !isAgentEnvironment(env, all_names);
}

/// Flags first, then the default.
pub fn resolve(args: []const []const u8, interactive: bool, env: Env, all_names: []const []const u8) FlagError!bool {
    if (try parseFlags(args)) |b| return b;
    return defaultFocus(interactive, env, all_names);
}

const testing = std.testing;

test "unit: cli-focus: flags last one wins and double dash stops" {
    try testing.expectEqual(@as(?bool, null), try parseFlags(&.{}));
    try testing.expectEqual(@as(?bool, true), try parseFlags(&.{"--focus"}));
    try testing.expectEqual(@as(?bool, false), try parseFlags(&.{ "--focus", "false" }));
    try testing.expectEqual(@as(?bool, true), try parseFlags(&.{ "--focus", "TRUE" }));
    try testing.expectEqual(@as(?bool, false), try parseFlags(&.{"--focus=false"}));
    try testing.expectEqual(@as(?bool, false), try parseFlags(&.{ "--focus", "--no-focus" }));
    try testing.expectEqual(@as(?bool, true), try parseFlags(&.{ "--no-focus", "--focus=1" }));
    try testing.expectEqual(@as(?bool, false), try parseFlags(&.{ "--no-focus", "--", "--focus" }));
    // A non-boolean token after a bare --focus is the command's own argument.
    try testing.expectEqual(@as(?bool, true), try parseFlags(&.{ "--focus", "README.md" }));
    try testing.expectError(error.InvalidFocusValue, parseFlags(&.{"--focus=maybe"}));
    try testing.expectError(error.InvalidFocusValue, parseFlags(&.{"--focus="}));
    try testing.expectEqual(@as(?bool, null), try parseFlags(&.{ "--focused", "--focus-mode" }));
}

test "unit: cli-focus: default is interactive and not an agent" {
    try testing.expect(defaultFocus(true, Env.empty, &.{}));
    try testing.expect(!defaultFocus(false, Env.empty, &.{}));
    const claude: []const Env.Pair = &.{.{ "CLAUDECODE", "1" }};
    try testing.expect(!defaultFocus(true, Env.fromPairs(&claude), &.{"CLAUDECODE"}));
    const empty_marker: []const Env.Pair = &.{.{ "CLAUDECODE", "" }};
    try testing.expect(defaultFocus(true, Env.fromPairs(&empty_marker), &.{"CLAUDECODE"}));
    const sandbox: []const Env.Pair = &.{.{ "CODEX_SANDBOX", "seatbelt" }};
    try testing.expect(!defaultFocus(true, Env.fromPairs(&sandbox), &.{}));
    const kind: []const Env.Pair = &.{.{ "CMUX_AGENT_KIND", "claude" }};
    try testing.expect(!defaultFocus(true, Env.fromPairs(&kind), &.{ "PATH", "CMUX_AGENT_KIND" }));
}

test "unit: cli-focus: CMUX_FOCUS_NEW forces the default" {
    const agent_forced: []const Env.Pair = &.{ .{ "CLAUDECODE", "1" }, .{ "CMUX_FOCUS_NEW", "1" } };
    try testing.expect(defaultFocus(false, Env.fromPairs(&agent_forced), &.{}));
    const off: []const Env.Pair = &.{.{ "WMUX_FOCUS_NEW", "0" }};
    try testing.expect(!defaultFocus(true, Env.fromPairs(&off), &.{}));
    const wmux_wins: []const Env.Pair = &.{ .{ "WMUX_FOCUS_NEW", "0" }, .{ "CMUX_FOCUS_NEW", "1" } };
    try testing.expect(!defaultFocus(true, Env.fromPairs(&wmux_wins), &.{}));
    const junk: []const Env.Pair = &.{.{ "CMUX_FOCUS_NEW", "sometimes" }};
    try testing.expectEqual(@as(?bool, null), forcedDefault(Env.fromPairs(&junk)));
    // An explicit flag beats everything.
    try testing.expect(!try resolve(&.{"--no-focus"}, true, Env.fromPairs(&agent_forced), &.{}));
}
