//! `cmux browser` argument grammar (browser-cli-targeting-and-conventions):
//! where the target surface comes from, which verbs run without one, and a
//! small table-driven option scanner that rejects unknown flags and missing
//! values before anything contacts the app.
//!
//! `browser [--surface <h> | <h>] <sub> [args]`: the surface is `--surface`
//! (`--panel` is the legacy spelling) or the first token that is not a flag
//! and not a known verb. `--workspace`/`--window` may precede the verb too.
//! `--json` and `--id-format` were already removed by args.zig.

const std = @import("std");
const proto = @import("wmux_proto");
const handles = proto.handles;
const selectors = proto.selectors;
const Allocator = std.mem.Allocator;

/// Verbs that never need a surface (cmux list). The view verbs among them
/// accept an optional surface and fall back to the caller's workspace.
pub const surfaceless = [_][]const u8{
    "open",        "open-split", "new",       "identify", "import",    "profile",
    "profiles",    "react-grab", "reactgrab", "devtools", "dev-tools", "focus-mode",
    "design-mode", "zoom",       "history",   "repl",     "disable",   "enable",
    "status",      "help",       "docs",      "skill",
};

/// Verbs that act on one browser surface.
pub const surface_verbs = [_][]const u8{
    "goto",               "navigate",        "back",          "forward",       "reload",
    "url",                "get-url",         "focus-webview", "focus_webview", "is-webview-focused",
    "is_webview_focused", "snapshot",        "eval",          "wait",          "click",
    "dblclick",           "hover",           "focus",         "check",         "uncheck",
    "scroll-into-view",   "scrollintoview",  "scrollinto",    "type",          "fill",
    "press",              "key",             "keydown",       "keyup",         "select",
    "scroll",             "set-input-files", "get",           "is",            "find",
    "highlight",          "frame",           "dialog",        "download",      "cookies",
    "storage",            "state",           "tab",           "tabs",          "console",
    "errors",             "addinitscript",   "addscript",     "addstyle",      "viewport",
    "geolocation",        "geo",             "offline",       "screenshot",    "trace",
    "network",            "screencast",      "input",         "input_mouse",   "input_keyboard",
    "input_touch",
};

/// agent-browser verbs that the cmux CLI does not expose.
pub const not_exposed = [_][]const u8{
    "drag", "upload", "pdf",    "mouse", "set",  "window", "record",
    "tap",  "swipe",  "device", "close", "quit", "exit",   "connect",
};

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

pub fn isSurfaceless(verb: []const u8) bool {
    return inList(&surfaceless, verb);
}

pub fn isVerb(s: []const u8) bool {
    return inList(&surfaceless, s) or inList(&surface_verbs, s) or inList(&not_exposed, s);
}

pub fn isNotExposed(s: []const u8) bool {
    return inList(&not_exposed, s);
}

/// A token is an option when it starts with `-`, is longer than one byte and
/// is not a number (`-5`, `-0.25` are values: scroll deltas, coordinates).
pub fn isFlag(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    if (std.mem.eql(u8, a, "--")) return false;
    _ = std.fmt.parseFloat(f64, a) catch return true;
    return false;
}

pub const Kind = enum { value, boolean };

pub const Flag = struct {
    /// Canonical spelling (`--selector`); results are keyed by it.
    name: []const u8,
    kind: Kind = .value,
    /// Other spellings (`-s`, `--url`).
    aliases: []const []const u8 = &.{},
};

/// Flags every surface-targeting verb accepts.
pub const target_flags = [_]Flag{
    .{ .name = "--surface", .aliases = &.{"--panel"} },
    .{ .name = "--workspace" },
    .{ .name = "--window" },
};

pub const snapshot_after_flag: Flag = .{ .name = "--snapshot-after", .kind = .boolean };

pub const Entry = struct { name: []const u8, value: ?[]const u8 };

/// Scanned options and positionals of one verb.
pub const Opts = struct {
    entries: []const Entry = &.{},
    positionals: []const []const u8 = &.{},
    /// Tokens after `--` (also appended to `positionals`).
    payload: []const []const u8 = &.{},

    /// Last value of `name`.
    pub fn get(self: Opts, name: []const u8) ?[]const u8 {
        var out: ?[]const u8 = null;
        for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) {
            out = e.value;
        };
        return out;
    }

    pub fn has(self: Opts, name: []const u8) bool {
        return self.count(name) > 0;
    }

    pub fn count(self: Opts, name: []const u8) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) n += 1;
        }
        return n;
    }

    /// Every value of a repeatable option, in order.
    pub fn all(self: Opts, arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) if (e.value) |v| try list.append(arena, v);
        }
        return list.items;
    }
};

/// A usage problem (printed as `cmux: <message>`, exit 2).
pub const Diag = struct { message: []const u8 = "" };

pub const Error = error{ Usage, OutOfMemory };

pub fn fail(arena: Allocator, diag: *Diag, comptime fmt: []const u8, a: anytype) Error {
    diag.message = try std.fmt.allocPrint(arena, fmt, a);
    return error.Usage;
}

fn findFlag(table: []const Flag, name: []const u8) ?*const Flag {
    for (table) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
        for (f.aliases) |al| if (std.mem.eql(u8, al, name)) return f;
    }
    return null;
}

/// Scans `args` against `table` (plus `target_flags`). `label` names the
/// verb in messages (`browser click`).
pub fn scan(arena: Allocator, label: []const u8, args: []const []const u8, table: []const Flag, diag: *Diag) Error!Opts {
    var entries: std.ArrayList(Entry) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var payload: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            payload = args[i + 1 ..];
            try pos.appendSlice(arena, payload);
            break;
        }
        if (!isFlag(a)) {
            try pos.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = if (eq) |e| a[0..e] else a;
        const f = findFlag(table, name) orelse findFlag(&target_flags, name) orelse
            return fail(arena, diag, "{s} does not support {s}", .{ label, name });
        switch (f.kind) {
            .boolean => {
                if (eq != null) return fail(arena, diag, "{s}: {s} does not take a value", .{ label, name });
                try entries.append(arena, .{ .name = f.name, .value = null });
            },
            .value => {
                if (eq) |e| {
                    try entries.append(arena, .{ .name = f.name, .value = a[e + 1 ..] });
                } else {
                    if (i + 1 >= args.len) return fail(arena, diag, "{s}: {s} requires a value", .{ label, name });
                    i += 1;
                    try entries.append(arena, .{ .name = f.name, .value = args[i] });
                }
            },
        }
    }
    return .{ .entries = entries.items, .positionals = pos.items, .payload = payload };
}

/// Where `browser` was pointed before the verb.
pub const Target = struct {
    /// The verb as typed (null: none given).
    verb: ?[]const u8 = null,
    /// Arguments after the verb.
    rest: []const []const u8 = &.{},
    /// Surface handle text (trimmed, validated).
    surface: ?[]const u8 = null,
    /// The surface came from the first positional token.
    surface_positional: bool = false,
    workspace: ?[]const u8 = null,
    window: ?[]const u8 = null,
};

/// A validated handle of `kind` (trimmed) or a usage error with cmux's text.
pub fn checkHandle(arena: Allocator, kind: handles.Kind, text: []const u8, diag: *Diag) Error![]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    _ = handles.parseHandle(kind, t) catch |err| {
        diag.message = try selectors.cliMessage(arena, selectors.cliProblemFor(err), kind, t);
        return error.Usage;
    };
    return t;
}

/// A validated surface handle (trimmed) or a usage error with cmux's text.
pub fn checkSurface(arena: Allocator, text: []const u8, diag: *Diag) Error![]const u8 {
    return checkHandle(arena, .surface, text, diag);
}

/// Splits `browser` arguments into the target and the verb's arguments.
pub fn splitTarget(arena: Allocator, args: []const []const u8, diag: *Diag) Error!Target {
    var t: Target = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (isFlag(a)) {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const name = if (eq) |e| a[0..e] else a;
            const f = findFlag(&target_flags, name) orelse
                return fail(arena, diag, "browser: unknown option '{s}' before the subcommand", .{name});
            const value = if (eq) |e| a[e + 1 ..] else blk: {
                if (i + 1 >= args.len) return fail(arena, diag, "browser: {s} requires a value", .{name});
                i += 1;
                break :blk args[i];
            };
            if (std.mem.eql(u8, f.name, "--surface")) {
                t.surface = try checkSurface(arena, value, diag);
                t.surface_positional = false;
            } else if (std.mem.eql(u8, f.name, "--workspace")) t.workspace = value else t.window = value;
            continue;
        }
        if (isVerb(a)) {
            t.verb = a;
            t.rest = args[i + 1 ..];
            return t;
        }
        if (t.surface != null) {
            return fail(arena, diag, "browser: unknown subcommand '{s}'. Run 'cmux browser --help' for the list.", .{a});
        }
        t.surface = try checkSurface(arena, a, diag);
        t.surface_positional = true;
    }
    return t;
}

const testing = std.testing;

test "unit: browser-cli: target from --surface, --panel or the first positional" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .{};
    const p = try splitTarget(a, &.{ "surface:2", "url" }, &d);
    try testing.expectEqualStrings("surface:2", p.surface.?);
    try testing.expect(p.surface_positional);
    try testing.expectEqualStrings("url", p.verb.?);
    const f = try splitTarget(a, &.{ "--surface", " surface:2 ", "url", "x" }, &d);
    try testing.expectEqualStrings("surface:2", f.surface.?);
    try testing.expect(!f.surface_positional);
    try testing.expectEqual(@as(usize, 1), f.rest.len);
    const l = try splitTarget(a, &.{ "--panel=7", "--workspace", "workspace:1", "back" }, &d);
    try testing.expectEqualStrings("7", l.surface.?);
    try testing.expectEqualStrings("workspace:1", l.workspace.?);
    const u = try splitTarget(a, &.{ "0B6E5C1A-3F0D-4C4B-9C59-3B7C1F2A9D10", "click", "#x" }, &d);
    try testing.expectEqualStrings("click", u.verb.?);
    const none = try splitTarget(a, &.{}, &d);
    try testing.expectEqual(@as(?[]const u8, null), none.verb);
    // A verb name is never taken as a surface.
    const v = try splitTarget(a, &.{ "click", "#x" }, &d);
    try testing.expectEqual(@as(?[]const u8, null), v.surface);
}

test "unit: browser-cli: target errors carry cmux handle messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .{};
    try testing.expectError(error.Usage, splitTarget(a, &.{ "bogus!", "url" }, &d));
    try testing.expectEqualStrings("Invalid surface handle: bogus! (expected UUID, ref like surface:1, or index)", d.message);
    try testing.expectError(error.Usage, splitTarget(a, &.{ "--surface", "  ", "url" }, &d));
    try testing.expectEqualStrings("Surface handle is blank", d.message);
    try testing.expectError(error.Usage, splitTarget(a, &.{ "workspace:2", "url" }, &d));
    try testing.expectError(error.Usage, splitTarget(a, &.{ "surface:1", "frobnicate" }, &d));
    try testing.expectEqualStrings("browser: unknown subcommand 'frobnicate'. Run 'cmux browser --help' for the list.", d.message);
    try testing.expectError(error.Usage, splitTarget(a, &.{"--surface"}, &d));
    try testing.expectError(error.Usage, splitTarget(a, &.{ "--bogus", "url" }, &d));
    try testing.expectError(error.Usage, splitTarget(a, &.{ "\u{1F600}", "url" }, &d));
}

test "unit: browser-cli: option scanner values, booleans, numbers and payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .{};
    const table = [_]Flag{
        .{ .name = "--selector", .aliases = &.{"-s"} },
        .{ .name = "--interactive", .kind = .boolean, .aliases = &.{"-i"} },
        .{ .name = "--file" },
    };
    const o = try scan(a, "browser x", &.{ "-s", "#a", "-i", "--file=a", "--file", "b", "-5", "pos", "--", "--json", "-i" }, &table, &d);
    try testing.expectEqualStrings("#a", o.get("--selector").?);
    try testing.expect(o.has("--interactive"));
    try testing.expectEqual(@as(usize, 2), (try o.all(a, "--file")).len);
    try testing.expectEqual(@as(usize, 4), o.positionals.len);
    try testing.expectEqualStrings("-5", o.positionals[0]);
    try testing.expectEqual(@as(usize, 2), o.payload.len);
    try testing.expectError(error.Usage, scan(a, "browser open", &.{"--x"}, &table, &d));
    try testing.expectEqualStrings("browser open does not support --x", d.message);
    try testing.expectError(error.Usage, scan(a, "browser x", &.{"--selector"}, &table, &d));
    try testing.expectEqualStrings("browser x: --selector requires a value", d.message);
    try testing.expectError(error.Usage, scan(a, "browser x", &.{"-i=1"}, &table, &d));
    const t = try scan(a, "browser x", &.{ "--panel", "surface:3" }, &table, &d);
    try testing.expectEqualStrings("surface:3", t.get("--surface").?);
    try testing.expect(isFlag("--x") and isFlag("-i") and !isFlag("-") and !isFlag("-0.5") and !isFlag("--"));
}
