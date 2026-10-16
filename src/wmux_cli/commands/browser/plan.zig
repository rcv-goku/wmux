//! Pure mapping of one `cmux browser` verb onto a cmux v2 `browser.*` call
//! (Appendix B; SPEC.json `browser-cli-*`): the method, its params, how the
//! result prints as text, and any longer transport deadline. Every argument
//! check that cmux makes before contacting the app happens here, with
//! cmux's messages. Nothing here touches the platform.

const std = @import("std");
const proto = @import("wmux_proto");
const paths = proto.paths;
const Allocator = std.mem.Allocator;
const g = @import("grammar.zig");
const Flag = g.Flag;
const Opts = g.Opts;
const Diag = g.Diag;
const Error = g.Error;
const fail = g.fail;

/// How a successful result prints without `--json`.
pub const Render = enum {
    /// `OK`, then `post_action_snapshot` when present.
    ok,
    /// `result.url`.
    url,
    /// `result.focused` as true/false.
    focused,
    /// `result.value` as true/false.
    bool_value,
    /// `value`/`count`/`url`/`title`: strings raw, other values as JSON.
    value,
    snapshot,
    /// eval/addscript: strings raw, whole numbers without decimals,
    /// objects as JSON, a missing value as `OK`.
    eval,
    open,
    console,
    errors,
    downloads,
    profiles_list,
    profile_created,
    profile_renamed,
    profiles_cleared,
    profile_deleted,
    design_mode,
    tabs,
    imported,
    screenshot,
    /// The result as pretty JSON (commands whose text is their data).
    json,
};

pub const Call = struct {
    method: []const u8,
    params: std.json.ObjectMap,
    render: Render = .ok,
    /// Minimum response deadline for this call (ms).
    timeout_ms: ?u32 = null,
    /// `screenshot --out` (absolute).
    out_path: ?[]const u8 = null,
    /// `set-input-files`: check `params.files` on the client first.
    check_uploads: bool = false,
};

/// Verbs answered by the CLI itself.
pub const Local = enum { help, docs, skill, repl_guide, disable, enable, status };

pub const Plan = union(enum) {
    call: Call,
    local: Local,
    /// `system.identify` plus the browser fields of this surface (null:
    /// the focused surface when it is a browser).
    identify: ?[]const u8,
};

pub const Inputs = struct {
    verb: []const u8,
    rest: []const []const u8 = &.{},
    /// Surface handle from before the verb.
    surface: ?[]const u8 = null,
    surface_positional: bool = false,
    workspace: ?[]const u8 = null,
    window: ?[]const u8 = null,
    /// Global `--window` (before the command).
    global_window: ?[]const u8 = null,
    /// `CMUX_WORKSPACE_ID`/`WMUX_WORKSPACE_ID`.
    caller_workspace: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    home: ?[]const u8 = null,
    style: paths.Style = paths.Style.native,
    /// A coding-agent environment (browser import defaults).
    agent: bool = false,
};

/// Default deadlines (ms) from SPEC.json.
pub const snapshot_after_timeout_ms: u32 = 35_000;
pub const import_timeout_ms: u32 = 10 * 60 * 1000;
pub const upload_extra_ms: u32 = 10_000;
pub const wait_default_ms: u32 = 5_000;
pub const max_upload_files = 128;
pub const max_upload_bytes = 32 * 1024 * 1024;
pub const download_list_max = 25;

/// Verbs that accept `--snapshot-after`.
pub const mutating = [_][]const u8{
    "goto",    "navigate",         "back",           "forward",    "reload",
    "click",   "dblclick",         "hover",          "focus",      "check",
    "uncheck", "scroll-into-view", "scrollintoview", "scrollinto", "type",
    "fill",    "set-input-files",  "press",          "key",        "keydown",
    "keyup",   "select",           "scroll",         "download",
};

pub fn isMutating(verb: []const u8) bool {
    for (mutating) |m| if (std.mem.eql(u8, m, verb)) return true;
    return false;
}

/// Params under construction.
pub const P = struct {
    map: std.json.ObjectMap,

    pub fn init(arena: Allocator) P {
        return .{ .map = std.json.ObjectMap.init(arena) };
    }
    pub fn str(self: *P, k: []const u8, v: []const u8) !void {
        try self.map.put(k, .{ .string = v });
    }
    pub fn optStr(self: *P, k: []const u8, v: ?[]const u8) !void {
        if (v) |s| try self.str(k, s);
    }
    pub fn boolean(self: *P, k: []const u8, v: bool) !void {
        try self.map.put(k, .{ .bool = v });
    }
    pub fn int(self: *P, k: []const u8, v: i64) !void {
        try self.map.put(k, .{ .integer = v });
    }
    pub fn float(self: *P, k: []const u8, v: f64) !void {
        try self.map.put(k, .{ .float = v });
    }
    pub fn strings(self: *P, arena: Allocator, k: []const u8, list: []const []const u8) !void {
        var arr = std.json.Array.init(arena);
        for (list) |s| try arr.append(.{ .string = s });
        try self.map.put(k, .{ .array = arr });
    }
};

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn oneOf(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (eql(x, s)) return true;
    return false;
}

/// Per-verb planning state.
pub const C = struct {
    arena: Allocator,
    in: Inputs,
    diag: *Diag,
    /// `browser <verb>` for messages.
    label: []const u8,

    pub fn usage(c: *C, comptime fmt: []const u8, a: anytype) Error {
        return fail(c.arena, c.diag, fmt, a);
    }

    /// Scans the verb's arguments; mutating verbs also take
    /// `--snapshot-after`.
    pub fn scan(c: *C, table: []const Flag) Error!Opts {
        var t: []const Flag = table;
        if (isMutating(c.in.verb)) t = try std.mem.concat(c.arena, Flag, &.{ table, &.{g.snapshot_after_flag} });
        return g.scan(c.arena, c.label, c.in.rest, t, c.diag);
    }

    /// The surface from before the verb or from its own `--surface`.
    pub fn surface(c: *C, o: Opts) Error!?[]const u8 {
        const own = if (o.get("--surface")) |s| try g.checkSurface(c.arena, s, c.diag) else return c.in.surface;
        if (c.in.surface) |before| if (!eql(before, own)) {
            return c.usage("{s}: --surface {s} conflicts with surface {s} given before the subcommand", .{ c.label, own, before });
        };
        return own;
    }

    pub fn requireSurface(c: *C, o: Opts) Error![]const u8 {
        if (try c.surface(o)) |s| return s;
        if (eql(c.in.verb, "download")) return c.usage("browser download requires a surface handle", .{});
        return c.usage("browser {s} requires a surface handle (use: browser <surface> {s} ... or --surface)", .{ c.in.verb, c.in.verb });
    }

    /// A call on the required surface, with `snapshot_after` when asked.
    pub fn base(c: *C, o: Opts, method: []const u8, render: Render) Error!Base {
        var p = P.init(c.arena);
        try p.str("surface_id", try c.requireSurface(o));
        var call: Call = .{ .method = method, .params = undefined, .render = render };
        if (isMutating(c.in.verb) and o.has("--snapshot-after")) {
            try p.boolean("snapshot_after", true);
            call.timeout_ms = snapshot_after_timeout_ms;
        }
        return .{ .p = p, .call = call };
    }

    /// Optional surface, else the workspace (`--workspace`, else the
    /// caller's workspace unless `--window` is given) and window. Handles
    /// fail closed with cmux's messages before anything is sent (ADR-4.6);
    /// a blank `--workspace` falls back to the caller's workspace.
    pub fn viewTarget(c: *C, o: Opts, p: *P) Error!void {
        if (try c.surface(o)) |s| try p.str("surface_id", s);
        const window: ?[]const u8 = if (o.get("--window") orelse c.in.window orelse c.in.global_window) |w|
            try g.checkHandle(c.arena, .window, w, c.diag)
        else
            null;
        var ws: ?[]const u8 = null;
        if (o.get("--workspace") orelse c.in.workspace) |w| {
            if (std.mem.trim(u8, w, " \t\r\n").len == 0) {
                ws = (if (window == null) c.in.caller_workspace else null) orelse
                    return c.usage("{s}", .{proto.errors.msg.no_workspace_selected});
            } else ws = try g.checkHandle(c.arena, .workspace, w, c.diag);
        } else if (window == null) ws = c.in.caller_workspace;
        try p.optStr("workspace_id", ws);
        try p.optStr("window_id", window);
    }

    pub fn noPositionals(c: *C, o: Opts, max: usize) Error!void {
        if (o.positionals.len > max) return c.usage("{s}: unexpected argument '{s}'", .{ c.label, o.positionals[max] });
    }

    /// `~` expanded and made absolute against the working directory. A path
    /// the user gives as absolute is kept as typed. A Windows drive-relative
    /// path (`D:shot.png`) is resolved only when it names the working
    /// directory's drive; another drive's working directory is unknown here,
    /// so that path is kept as typed rather than glued onto ours. A Windows
    /// root-relative path (`\shots\p.png`) takes the working directory's
    /// drive or UNC share: the app resolving it would use its own current
    /// drive, which need not be ours.
    pub fn absPath(c: *C, path: []const u8) Error![]const u8 {
        var p = path;
        if (c.in.home) |h| {
            if (eql(p, "~")) return h;
            if (p.len >= 2 and p[0] == '~' and (p[1] == '/' or p[1] == '\\')) p = try c.joinPath(&.{ h, p[2..] });
        }
        if (c.in.style == .windows and isRootRelative(p)) {
            const root = windowsRoot(c.in.cwd orelse return p) orelse return p;
            return c.joinPath(&.{ root, p });
        }
        if (isAbsolute(c.in.style, p)) return p;
        const cwd = c.in.cwd orelse return p;
        if (c.in.style == .windows and hasDrive(p)) {
            if (!hasDrive(cwd) or std.ascii.toLower(cwd[0]) != std.ascii.toLower(p[0])) return p;
            return c.joinPath(&.{ cwd, p[2..] });
        }
        return c.joinPath(&.{ cwd, p });
    }

    /// `paths.join`, with `\` throughout for the Windows style so that a
    /// relative `shots/p.png` becomes `C:\work\shots\p.png` rather than a
    /// mixed-separator path.
    fn joinPath(c: *C, parts: []const []const u8) Error![]const u8 {
        const out = try paths.join(c.arena, c.in.style, parts);
        if (c.in.style == .windows) std.mem.replaceScalar(u8, out, '/', '\\');
        return out;
    }

    pub fn joined(c: *C, words: []const []const u8) Error![]const u8 {
        return std.mem.join(c.arena, " ", words);
    }
};

pub fn isAbsolute(style: paths.Style, p: []const u8) bool {
    return switch (style) {
        .posix => p.len > 0 and p[0] == '/',
        .windows => (p.len > 0 and (p[0] == '\\' or p[0] == '/')) or
            (p.len >= 3 and hasDrive(p) and (p[2] == '\\' or p[2] == '/')),
    };
}

/// `X:` drive prefix (Windows).
fn hasDrive(p: []const u8) bool {
    return p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':';
}

fn isSep(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

/// `\dir\file` or `/dir/file` (Windows): rooted, but on no particular drive.
/// `\\server\share` and `\\?\...` name their own root.
pub fn isRootRelative(p: []const u8) bool {
    return p.len > 0 and isSep(p[0]) and !(p.len > 1 and isSep(p[1]));
}

/// The root a Windows root-relative path hangs off: `X:` for a drive path,
/// `\\server\share` for a UNC path; null for anything else.
pub fn windowsRoot(cwd: []const u8) ?[]const u8 {
    if (hasDrive(cwd)) return cwd[0..2];
    if (cwd.len < 3 or !isSep(cwd[0]) or !isSep(cwd[1]) or cwd[2] == '?' or cwd[2] == '.') return null;
    // `\\server\share[\...]`: the root ends before the third separator.
    var seps: usize = 0;
    for (cwd[2..], 2..) |ch, i| {
        if (!isSep(ch)) continue;
        seps += 1;
        if (seps == 2) return cwd[0..i];
    }
    return if (seps == 1 and !isSep(cwd[cwd.len - 1])) cwd else null;
}

/// A call on the required surface (see `C.base`).
pub const Base = struct {
    p: P,
    call: Call,

    pub fn plan(b: Base) Plan {
        return done(b.p, b.call);
    }
};

pub fn done(p: P, call: Call) Plan {
    var c = call;
    c.params = p.map;
    return .{ .call = c };
}

/// Plans one verb.
pub fn plan(arena: Allocator, in: Inputs, diag: *Diag) Error!Plan {
    var c: C = .{ .arena = arena, .in = in, .diag = diag, .label = try std.fmt.allocPrint(arena, "browser {s}", .{in.verb}) };
    const v = in.verb;
    if (g.isNotExposed(v)) return c.usage("browser {s} is not supported by the cmux CLI", .{v});
    // `browser <surface> open <url>` navigates that surface, so it takes
    // navigate's options (`--snapshot-after`); messages still say `open`.
    if (oneOf(v, &.{ "open", "open-split", "new" }) and in.surface_positional) {
        c.in.verb = "navigate";
        return planNavigate(&c);
    }
    if (oneOf(v, &.{ "open", "open-split", "new" })) return planOpen(&c);
    if (eql(v, "identify")) return planIdentify(&c);
    if (oneOf(v, &.{ "help", "docs", "skill" })) {
        const o = try c.scan(&.{});
        try c.noPositionals(o, 0);
        return .{ .local = if (eql(v, "help")) .help else if (eql(v, "docs")) .docs else .skill };
    }
    if (oneOf(v, &.{ "disable", "enable", "status" })) {
        const o = try c.scan(&.{});
        if (o.positionals.len > 0) return c.usage("Unexpected argument: {s}", .{o.positionals[0]});
        return .{ .local = if (eql(v, "disable")) .disable else if (eql(v, "enable")) .enable else .status };
    }
    if (oneOf(v, &.{ "profiles", "profile" })) return @import("plan_more.zig").planProfiles(&c);
    if (eql(v, "import")) return @import("plan_more.zig").planImport(&c);
    if (oneOf(v, &.{ "react-grab", "reactgrab", "devtools", "dev-tools", "focus-mode", "design-mode", "zoom", "history", "repl" })) return @import("plan_more.zig").planView(&c);
    return @import("plan_page.zig").planSurfaceVerb(&c);
}

pub fn parseBool(s: []const u8) ?bool {
    if (eql(s, "true")) return true;
    if (eql(s, "false")) return false;
    return null;
}

/// `open|open-split|new [url] [--workspace] [--window] [--focus <bool>]
/// [--profile <name|uuid>]` -> `browser.open_split`. A `--surface` anchors
/// the placement; words are joined (search queries).
fn planOpen(c: *C) Error!Plan {
    const o = try c.scan(&.{ .{ .name = "--focus" }, .{ .name = "--profile" } });
    var p = P.init(c.arena);
    if (o.positionals.len > 0) try p.str("url", try c.joined(o.positionals));
    try c.viewTarget(o, &p);
    try p.optStr("profile", o.get("--profile"));
    var focus = false;
    if (o.get("--focus")) |f| focus = parseBool(f) orelse return c.usage("--focus must be true or false", .{});
    try p.boolean("focus", focus);
    return done(p, .{ .method = "browser.open_split", .params = undefined, .render = .open });
}

/// `goto|navigate <url> [--snapshot-after]` -> `browser.navigate`.
fn planNavigate(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    var b = try c.base(o, "browser.navigate", .ok);
    try c.noPositionals(o, 1);
    const url = if (o.positionals.len == 1) std.mem.trim(u8, o.positionals[0], " \t\r\n") else "";
    if (url.len == 0) return c.usage("{s} requires a URL", .{c.label});
    try b.p.str("url", url);
    return b.plan();
}

pub fn navigate(c: *C) Error!Plan {
    return planNavigate(c);
}

/// `identify [--surface <h>]`.
fn planIdentify(c: *C) Error!Plan {
    const o = try c.scan(&.{});
    try c.noPositionals(o, 0);
    return .{ .identify = try c.surface(o) };
}
