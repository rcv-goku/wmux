//! INSTALL, CLI, SHARE, CONFIG, CMUX_CONFIG and STATE resolution shared by the app
//! and the CLI (Appendix G.1). Everything is pure: callers pass the
//! environment (`env_names.Env`), the executable path and a path `Style`.
//! `Style.native` follows builtin.os.tag; the Windows rules are fully testable
//! on any host by passing `.windows`. The POSIX style is a fallback for
//! non-Windows hosts (tests, a future remote daemon): it uses HOME instead of
//! USERPROFILE and XDG_STATE_HOME/~/.local/state instead of LOCALAPPDATA.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const env_names = @import("env_names.zig");
const Env = env_names.Env;

pub const Style = enum {
    windows,
    posix,

    pub const native: Style = if (builtin.os.tag == .windows) .windows else .posix;

    pub fn sep(s: Style) u8 {
        return if (s == .windows) '\\' else '/';
    }

    fn isSep(s: Style, c: u8) bool {
        return c == '/' or (s == .windows and c == '\\');
    }
};

/// Directory names under INSTALL and STATE (Appendix G.1).
pub const dirs = struct {
    pub const cli = "cli";
    pub const cli_posix = "posix";
    pub const share = "share";
    pub const run = "run";
    pub const session = "session";
    pub const events = "events";
    pub const agents = "agents";
    pub const spool = "spool";
    pub const shims = "shims";
    pub const teams = "teams";
    pub const webview2 = "webview2";
    pub const trust = "trust";
    pub const history = "history";
    pub const logs = "logs";
    pub const wait_for = "wait-for";
    pub const tmux = "tmux";
    pub const sidebars = "sidebars";
    pub const layouts = "layouts";
};

/// File names (Appendix G.1).
pub const files = struct {
    pub const gui_exe = "wmux.exe";
    pub const cli_exe = "cmux.exe";
    pub const wmux_json = "wmux.json";
    pub const cmux_json = "cmux.json";
    pub const ghostty_overlay = "config.ghostty";
    pub const instance_json = "instance.json";
    pub const handles_json = "handles.json";
    pub const socket_capability = "socket-capability.bin";
    pub const socket_password = "socket-control-password.bin";
    pub const settings_overrides = "settings-overrides.ghostty";
    pub const events_jsonl = "events.jsonl";
    pub const palette_usage = "palette-usage.json";
};

/// Joins non-empty parts with the style's separator without doubling
/// separators at the seams.
pub fn join(gpa: Allocator, style: Style, parts: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts) |part| {
        if (part.len == 0) continue;
        var p = part;
        if (out.items.len > 0) {
            while (out.items.len > 0 and style.isSep(out.items[out.items.len - 1])) out.items.len -= 1;
            while (p.len > 0 and style.isSep(p[0])) p = p[1..];
            try out.append(gpa, style.sep());
        }
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

/// Parent directory of `path` (trailing separators ignored); null when
/// `path` has no separator.
pub fn dirname(style: Style, path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 1 and style.isSep(path[end - 1])) end -= 1;
    var i = end;
    while (i > 0) {
        i -= 1;
        if (style.isSep(path[i])) {
            var d = i;
            while (d > 1 and style.isSep(path[d - 1])) d -= 1;
            // Keep the root separator ("C:\", "/").
            if (d == 0) return path[0..1];
            if (style == .windows and d == 2 and path[1] == ':') return path[0..3];
            return path[0..d];
        }
    }
    return null;
}

/// Last path component (trailing separators ignored).
pub fn basename(style: Style, path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and style.isSep(path[end - 1])) end -= 1;
    var i = end;
    while (i > 0 and !style.isSep(path[i - 1])) i -= 1;
    return path[i..end];
}

fn eqlName(style: Style, a: []const u8, b: []const u8) bool {
    return if (style == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// INSTALL from the GUI `wmux.exe` path: its directory.
pub fn installFromGuiExe(style: Style, exe_path: []const u8) ?[]const u8 {
    return dirname(style, exe_path);
}

/// INSTALL from the CLI path `INSTALL\cli\cmux.exe` (or a byte copy such as
/// `wmux.com`): the parent of `cli`. Falls back to the exe's directory when it
/// does not live in a `cli` directory (e.g. a forwarder elsewhere on PATH).
pub fn installFromCliExe(style: Style, exe_path: []const u8) ?[]const u8 {
    const dir = dirname(style, exe_path) orelse return null;
    if (eqlName(style, basename(style, dir), dirs.cli)) return dirname(style, dir) orelse dir;
    return dir;
}

pub fn cliDir(gpa: Allocator, style: Style, install: []const u8) Allocator.Error![]u8 {
    return join(gpa, style, &.{ install, dirs.cli });
}

/// `INSTALL\cli\cmux.exe` (exported as `CMUX_BUNDLED_CLI_PATH`).
pub fn cliExe(gpa: Allocator, style: Style, install: []const u8) Allocator.Error![]u8 {
    return join(gpa, style, &.{ install, dirs.cli, files.cli_exe });
}

pub fn shareDir(gpa: Allocator, style: Style, install: []const u8) Allocator.Error![]u8 {
    return join(gpa, style, &.{ install, dirs.share });
}

/// `SHARE\wmux\shell-integration` (exported as `CMUX_SHELL_INTEGRATION_DIR`).
pub fn shellIntegrationDir(gpa: Allocator, style: Style, install: []const u8) Allocator.Error![]u8 {
    return join(gpa, style, &.{ install, dirs.share, "wmux", "shell-integration" });
}

/// `SHARE\wmux\schema\wmux.schema.json`.
pub fn schemaFile(gpa: Allocator, style: Style, install: []const u8) Allocator.Error![]u8 {
    return join(gpa, style, &.{ install, dirs.share, "wmux", "schema", "wmux.schema.json" });
}

fn home(env: Env, style: Style) ?[]const u8 {
    return if (style == .windows) env.getNonEmpty(env_names.USERPROFILE) else env.getNonEmpty(env_names.HOME);
}

/// CONFIG: `%WMUX_CONFIG_DIR%` → `%XDG_CONFIG_HOME%\wmux` →
/// `%USERPROFILE%\.config\wmux` (HOME on POSIX). Null when no base is set.
pub fn configDir(gpa: Allocator, env: Env, style: Style) Allocator.Error!?[]u8 {
    if (env.getNonEmpty(env_names.WMUX_CONFIG_DIR)) |d| return try gpa.dupe(u8, d);
    if (env.getNonEmpty(env_names.XDG_CONFIG_HOME)) |x| return try join(gpa, style, &.{ x, "wmux" });
    if (home(env, style)) |h| return try join(gpa, style, &.{ h, ".config", "wmux" });
    return null;
}

/// CMUX_CONFIG (read-only compat): `%XDG_CONFIG_HOME%\cmux` →
/// `%USERPROFILE%\.config\cmux`.
pub fn cmuxConfigDir(gpa: Allocator, env: Env, style: Style) Allocator.Error!?[]u8 {
    if (env.getNonEmpty(env_names.XDG_CONFIG_HOME)) |x| return try join(gpa, style, &.{ x, "cmux" });
    if (home(env, style)) |h| return try join(gpa, style, &.{ h, ".config", "cmux" });
    return null;
}

/// STATE: `%WMUX_STATE_DIR%` (used as is) → `%LOCALAPPDATA%\wmux\<channel>`.
/// POSIX: `$XDG_STATE_HOME/wmux/<channel>` → `$HOME/.local/state/wmux/<channel>`.
pub fn stateDir(gpa: Allocator, env: Env, style: Style, channel: []const u8) Allocator.Error!?[]u8 {
    if (env.getNonEmpty(env_names.WMUX_STATE_DIR)) |d| return try gpa.dupe(u8, d);
    switch (style) {
        .windows => if (env.getNonEmpty(env_names.LOCALAPPDATA)) |l| return try join(gpa, style, &.{ l, "wmux", channel }),
        .posix => {
            if (env.getNonEmpty(env_names.XDG_STATE_HOME)) |x| return try join(gpa, style, &.{ x, "wmux", channel });
            if (env.getNonEmpty(env_names.HOME)) |h| return try join(gpa, style, &.{ h, ".local", "state", "wmux", channel });
        },
    }
    return null;
}

/// Legacy Ghostty directory `%LOCALAPPDATA%\ghostty` (still holds the
/// Ghostty config; migrated from once).
pub fn legacyGhosttyDir(gpa: Allocator, env: Env, style: Style) Allocator.Error!?[]u8 {
    const l = env.getNonEmpty(env_names.LOCALAPPDATA) orelse return null;
    return try join(gpa, style, &.{ l, "ghostty" });
}

/// `STATE\run\<file>`.
pub fn runFile(gpa: Allocator, style: Style, state: []const u8, file: []const u8) Allocator.Error![]u8 {
    return join(gpa, style, &.{ state, dirs.run, file });
}

/// `STATE\history\surface-<uuid>.history` (`CMUX_HISTORY_FILE`).
pub fn historyFile(gpa: Allocator, style: Style, state: []const u8, surface_uuid: []const u8) Allocator.Error![]u8 {
    const name = try std.fmt.allocPrint(gpa, "surface-{s}.history", .{surface_uuid});
    defer gpa.free(name);
    return join(gpa, style, &.{ state, dirs.history, name });
}

pub const ShimKind = enum { agents, teams };

/// `STATE\shims\<build-id>\{agents,teams}`.
pub fn shimsDir(gpa: Allocator, style: Style, state: []const u8, build_id: []const u8, kind: ShimKind) Allocator.Error![]u8 {
    return join(gpa, style, &.{ state, dirs.shims, build_id, @tagName(kind) });
}

pub const ExeKind = enum { gui, cli };

/// All roots at once. Each optional field is null when its base variables
/// are missing (callers report that; nothing guesses a directory).
pub const Paths = struct {
    install: ?[]u8,
    cli: ?[]u8,
    share: ?[]u8,
    config: ?[]u8,
    cmux_config: ?[]u8,
    state: ?[]u8,

    pub fn resolve(gpa: Allocator, env: Env, style: Style, exe_path: []const u8, exe_kind: ExeKind, channel: []const u8) Allocator.Error!Paths {
        var p: Paths = .{ .install = null, .cli = null, .share = null, .config = null, .cmux_config = null, .state = null };
        errdefer p.deinit(gpa);
        const install = switch (exe_kind) {
            .gui => installFromGuiExe(style, exe_path),
            .cli => installFromCliExe(style, exe_path),
        };
        if (install) |i| {
            p.install = try gpa.dupe(u8, i);
            p.cli = try cliDir(gpa, style, i);
            p.share = try shareDir(gpa, style, i);
        }
        p.config = try configDir(gpa, env, style);
        p.cmux_config = try cmuxConfigDir(gpa, env, style);
        p.state = try stateDir(gpa, env, style, channel);
        return p;
    }

    pub fn deinit(self: *Paths, gpa: Allocator) void {
        inline for (@typeInfo(Paths).@"struct".fields) |f| {
            if (@field(self, f.name)) |s| gpa.free(s);
            @field(self, f.name) = null;
        }
    }
};

const testing = std.testing;

fn envOf(pairs: *const []const Env.Pair) Env {
    return Env.fromPairs(pairs);
}

fn expectOpt(want: ?[]const u8, got: ?[]u8) !void {
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expectEqual(@as(?[]u8, null), got);
}

test "unit: proto: paths join" {
    const gpa = testing.allocator;
    const cases = [_]struct { Style, []const []const u8, []const u8 }{
        .{ .windows, &.{ "C:\\a", "b", "c.txt" }, "C:\\a\\b\\c.txt" },
        .{ .windows, &.{ "C:\\a\\", "\\b\\", "c" }, "C:\\a\\b\\c" },
        .{ .windows, &.{ "C:/a/", "b" }, "C:/a\\b" },
        .{ .windows, &.{ "", "a", "", "b" }, "a\\b" },
        .{ .posix, &.{ "/home/u/", "/x", "y" }, "/home/u/x/y" },
        .{ .posix, &.{ "a\\b", "c" }, "a\\b/c" },
        .{ .posix, &.{}, "" },
    };
    for (cases) |c| {
        const got = try join(gpa, c[0], c[1]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "unit: proto: paths dirname and basename" {
    try testing.expectEqualStrings("C:\\Program Files\\wmux", dirname(.windows, "C:\\Program Files\\wmux\\wmux.exe").?);
    try testing.expectEqualStrings("C:\\", dirname(.windows, "C:\\wmux.exe").?);
    try testing.expectEqualStrings("C:\\a", dirname(.windows, "C:\\a\\\\b\\").?);
    try testing.expectEqualStrings("/", dirname(.posix, "/x").?);
    try testing.expectEqual(@as(?[]const u8, null), dirname(.windows, "wmux.exe"));
    try testing.expectEqual(@as(?[]const u8, null), dirname(.posix, ""));
    try testing.expectEqualStrings("a/b", dirname(.windows, "a/b/c").?);
    try testing.expectEqualStrings("cmux.exe", basename(.windows, "C:\\x\\cli\\cmux.exe"));
    try testing.expectEqualStrings("cli", basename(.windows, "C:\\x\\cli\\"));
    try testing.expectEqualStrings("", basename(.posix, ""));
}

test "unit: proto: paths install from exe" {
    const p = "C:\\Users\\J\u{f6}rg\\AppData\\Local\\Programs\\wmux";
    try testing.expectEqualStrings(p, installFromGuiExe(.windows, p ++ "\\wmux.exe").?);
    try testing.expectEqualStrings(p, installFromCliExe(.windows, p ++ "\\cli\\cmux.exe").?);
    try testing.expectEqualStrings(p, installFromCliExe(.windows, p ++ "\\CLI\\wmux.com").?);
    try testing.expectEqualStrings("C:\\bin", installFromCliExe(.windows, "C:\\bin\\cmux.exe").?);
    try testing.expectEqualStrings("zig-out\\bin", installFromCliExe(.windows, "zig-out\\bin\\cli\\cmux.exe").?);
    try testing.expectEqualStrings("/opt/wmux/CLI", installFromCliExe(.posix, "/opt/wmux/CLI/cmux").?);
    try testing.expectEqualStrings("cli", installFromCliExe(.windows, "cli\\cmux.exe").?);
    try testing.expectEqual(@as(?[]const u8, null), installFromCliExe(.windows, "cmux.exe"));
}

test "unit: proto: paths install-derived files" {
    const gpa = testing.allocator;
    const i = "C:\\wmux";
    const got = [_][]u8{
        try cliDir(gpa, .windows, i),
        try cliExe(gpa, .windows, i),
        try shareDir(gpa, .windows, i),
        try shellIntegrationDir(gpa, .windows, i),
        try schemaFile(gpa, .windows, i),
    };
    defer for (got) |g| gpa.free(g);
    try testing.expectEqualStrings("C:\\wmux\\cli", got[0]);
    try testing.expectEqualStrings("C:\\wmux\\cli\\cmux.exe", got[1]);
    try testing.expectEqualStrings("C:\\wmux\\share", got[2]);
    try testing.expectEqualStrings("C:\\wmux\\share\\wmux\\shell-integration", got[3]);
    try testing.expectEqualStrings("C:\\wmux\\share\\wmux\\schema\\wmux.schema.json", got[4]);
}

test "unit: proto: paths config precedence" {
    const gpa = testing.allocator;
    const all: []const Env.Pair = &.{ .{ "WMUX_CONFIG_DIR", "D:\\cfg" }, .{ "XDG_CONFIG_HOME", "C:\\xdg" }, .{ "USERPROFILE", "C:\\Users\\u" } };
    try expectOpt("D:\\cfg", try configDir(gpa, envOf(&all), .windows));
    const xdg: []const Env.Pair = &.{ .{ "WMUX_CONFIG_DIR", "" }, .{ "XDG_CONFIG_HOME", "C:\\xdg" }, .{ "USERPROFILE", "C:\\Users\\u" } };
    try expectOpt("C:\\xdg\\wmux", try configDir(gpa, envOf(&xdg), .windows));
    try expectOpt("C:\\xdg\\cmux", try cmuxConfigDir(gpa, envOf(&xdg), .windows));
    const prof: []const Env.Pair = &.{ .{ "USERPROFILE", "C:\\Users\\\u{4e2d}" }, .{ "HOME", "/h" } };
    try expectOpt("C:\\Users\\\u{4e2d}\\.config\\wmux", try configDir(gpa, envOf(&prof), .windows));
    try expectOpt("C:\\Users\\\u{4e2d}\\.config\\cmux", try cmuxConfigDir(gpa, envOf(&prof), .windows));
    try expectOpt("/h/.config/wmux", try configDir(gpa, envOf(&prof), .posix));
    try expectOpt(null, try configDir(gpa, Env.empty, .windows));
    try expectOpt(null, try cmuxConfigDir(gpa, Env.empty, .posix));
}

test "unit: proto: paths state precedence" {
    const gpa = testing.allocator;
    const over: []const Env.Pair = &.{ .{ "WMUX_STATE_DIR", "E:\\state" }, .{ "LOCALAPPDATA", "C:\\L" } };
    try expectOpt("E:\\state", try stateDir(gpa, envOf(&over), .windows, "stable"));
    const local: []const Env.Pair = &.{.{ "LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local" }};
    try expectOpt("C:\\Users\\u\\AppData\\Local\\wmux\\dev-x", try stateDir(gpa, envOf(&local), .windows, "dev-x"));
    try expectOpt(null, try stateDir(gpa, envOf(&local), .posix, "stable"));
    try expectOpt("C:\\Users\\u\\AppData\\Local\\ghostty", try legacyGhosttyDir(gpa, envOf(&local), .windows));
    const posix: []const Env.Pair = &.{.{ "HOME", "/home/u" }};
    try expectOpt("/home/u/.local/state/wmux/stable", try stateDir(gpa, envOf(&posix), .posix, "stable"));
    const xdg: []const Env.Pair = &.{ .{ "HOME", "/home/u" }, .{ "XDG_STATE_HOME", "/s" } };
    try expectOpt("/s/wmux/test-0a1b2c3d", try stateDir(gpa, envOf(&xdg), .posix, "test-0a1b2c3d"));
    try expectOpt(null, try stateDir(gpa, Env.empty, .windows, "stable"));
    try expectOpt(null, try legacyGhosttyDir(gpa, Env.empty, .windows));
}

test "unit: proto: paths state files" {
    const gpa = testing.allocator;
    const s = "C:\\L\\wmux\\stable";
    const got = [_][]u8{
        try runFile(gpa, .windows, s, files.instance_json),
        try historyFile(gpa, .windows, s, "9B690ABC-DEF0-4123-8456-789ABCDEF012"),
        try shimsDir(gpa, .windows, s, "1.2.3-abc", .agents),
        try shimsDir(gpa, .windows, s, "1.2.3-abc", .teams),
    };
    defer for (got) |g| gpa.free(g);
    try testing.expectEqualStrings("C:\\L\\wmux\\stable\\run\\instance.json", got[0]);
    try testing.expectEqualStrings("C:\\L\\wmux\\stable\\history\\surface-9B690ABC-DEF0-4123-8456-789ABCDEF012.history", got[1]);
    try testing.expectEqualStrings("C:\\L\\wmux\\stable\\shims\\1.2.3-abc\\agents", got[2]);
    try testing.expectEqualStrings("C:\\L\\wmux\\stable\\shims\\1.2.3-abc\\teams", got[3]);
}

test "unit: proto: paths resolve all" {
    const gpa = testing.allocator;
    const pairs: []const Env.Pair = &.{ .{ "LOCALAPPDATA", "C:\\L" }, .{ "USERPROFILE", "C:\\U" } };
    var p = try Paths.resolve(gpa, envOf(&pairs), .windows, "C:\\L\\Programs\\wmux\\cli\\cmux.exe", .cli, "stable");
    defer p.deinit(gpa);
    try testing.expectEqualStrings("C:\\L\\Programs\\wmux", p.install.?);
    try testing.expectEqualStrings("C:\\L\\Programs\\wmux\\cli", p.cli.?);
    try testing.expectEqualStrings("C:\\L\\Programs\\wmux\\share", p.share.?);
    try testing.expectEqualStrings("C:\\U\\.config\\wmux", p.config.?);
    try testing.expectEqualStrings("C:\\U\\.config\\cmux", p.cmux_config.?);
    try testing.expectEqualStrings("C:\\L\\wmux\\stable", p.state.?);

    var q = try Paths.resolve(gpa, Env.empty, .windows, "wmux.exe", .gui, "stable");
    defer q.deinit(gpa);
    try testing.expectEqual(@as(?[]u8, null), q.install);
    try testing.expectEqual(@as(?[]u8, null), q.state);
}

test "unit: proto: paths native style follows os" {
    try testing.expectEqual(builtin.os.tag == .windows, Style.native == .windows);
    try testing.expectEqual(@as(u8, '\\'), Style.windows.sep());
    try testing.expectEqual(@as(u8, '/'), Style.posix.sep());
}
