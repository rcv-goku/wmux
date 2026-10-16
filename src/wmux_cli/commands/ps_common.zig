//! Shared helpers of the `pane_surface`, `terminal_io` and `system` (tree,
//! top, memory, shot) command families (WP CLI-fam-ps): a small option
//! parser with cmux's unknown-flag and missing-value errors, client-side
//! target selection (ADR-4.6: explicit flags, then `CMUX_WORKSPACE_ID` /
//! `CMUX_SURFACE_ID` when neither `--workspace` nor `--window` is given),
//! request params, one-call-and-render, and text renderers for handles.
//!
//! Handles are validated with `wmux_proto.handles.parseHandle` and sent as
//! typed (UUID or ref string); an index is sent as a JSON integer (ADR-2.6).

const std = @import("std");
const proto = @import("wmux_proto");
const handles = proto.handles;
const Kind = handles.Kind;
const selectors = proto.selectors;
const env_names = proto.env_names;
const idformat = proto.idformat;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const command = @import("../command.zig");
const Ctx = command.Ctx;
const output = @import("../output.zig");
const brand_mod = @import("../brand.zig");
const focus_default = @import("../focus_default.zig");

// ----- option parsing -----

pub const Spec = struct {
    /// Flags that take a value (`--name v` or `--name=v`).
    values: []const []const u8 = &.{},
    /// Flags without a value (`--scrollback`, `-L`).
    bools: []const []const u8 = &.{},
    /// Accept `--focus [true|false]`, `--focus=<bool>` and `--no-focus`.
    focus: bool = false,
    /// Everything from the first positional (or unknown dash word) on is
    /// positional (`send` text).
    stop_at_positional: bool = false,
};

pub const Opt = struct { name: []const u8, value: []const u8 };

pub const Opts = struct {
    values: []const Opt = &.{},
    bools: []const []const u8 = &.{},
    positionals: []const []const u8 = &.{},
    /// Last focus flag, null when none was given.
    focus: ?bool = null,
    /// A `--` terminator was present.
    dashdash: bool = false,
    /// How many `positionals` came before the `--` terminator.
    before_dashdash: usize = 0,

    /// Value of the last occurrence of any of `names`.
    pub fn get(self: Opts, names: []const []const u8) ?[]const u8 {
        var i = self.values.len;
        while (i > 0) {
            i -= 1;
            for (names) |n| if (std.mem.eql(u8, self.values[i].name, n)) return self.values[i].value;
        }
        return null;
    }

    pub fn has(self: Opts, name: []const u8) bool {
        for (self.bools) |b| if (std.mem.eql(u8, b, name)) return true;
        return false;
    }

    /// The last of `names` given as a bool flag (`-L -R` → `-R`).
    pub fn lastOf(self: Opts, names: []const []const u8) ?[]const u8 {
        var i = self.bools.len;
        while (i > 0) {
            i -= 1;
            for (names) |n| if (std.mem.eql(u8, self.bools[i], n)) return n;
        }
        return null;
    }
};

fn member(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn parseBoolWord(s: []const u8) ?bool {
    for ([_][]const u8{ "true", "1", "yes", "on" }) |x| if (std.ascii.eqlIgnoreCase(s, x)) return true;
    for ([_][]const u8{ "false", "0", "no", "off" }) |x| if (std.ascii.eqlIgnoreCase(s, x)) return false;
    return null;
}

/// Parses a command's arguments. On a usage problem returns error.Usage
/// with the message in `diag`.
pub fn parse(arena: Allocator, args: []const []const u8, spec: Spec, diag: *[]const u8) (error{Usage} || Allocator.Error)!Opts {
    var values: std.ArrayList(Opt) = .empty;
    var bools: std.ArrayList([]const u8) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var out: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            out.dashdash = true;
            out.before_dashdash = pos.items.len;
            try pos.appendSlice(arena, args[i + 1 ..]);
            break;
        }
        const is_flag = a.len > 1 and a[0] == '-' and !isNumber(a);
        if (!is_flag) {
            if (spec.stop_at_positional) {
                try pos.appendSlice(arena, args[i..]);
                break;
            }
            try pos.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = if (eq) |e| a[0..e] else a;
        if (spec.focus and std.mem.eql(u8, name, "--focus")) {
            if (eq) |e| {
                out.focus = parseBoolWord(a[e + 1 ..]) orelse {
                    diag.* = focus_default.invalid_value_message;
                    return error.Usage;
                };
            } else if (i + 1 < args.len and parseBoolWord(args[i + 1]) != null) {
                out.focus = parseBoolWord(args[i + 1]);
                i += 1;
            } else out.focus = true;
            continue;
        }
        if (spec.focus and std.mem.eql(u8, a, "--no-focus")) {
            out.focus = false;
            continue;
        }
        if (member(spec.values, name)) {
            if (eq) |e| {
                try values.append(arena, .{ .name = name, .value = a[e + 1 ..] });
            } else {
                if (i + 1 >= args.len) {
                    diag.* = try std.fmt.allocPrint(arena, "{s} requires a value", .{name});
                    return error.Usage;
                }
                try values.append(arena, .{ .name = name, .value = args[i + 1] });
                i += 1;
            }
            continue;
        }
        if (eq == null and member(spec.bools, a)) {
            try bools.append(arena, a);
            continue;
        }
        // Text commands: an unknown dash word starts the text (`send -la`,
        // legacy `+send --version`), as `--version` is ordinary text after
        // the command (ADR-4.4).
        if (spec.stop_at_positional) {
            try pos.appendSlice(arena, args[i..]);
            break;
        }
        diag.* = try std.fmt.allocPrint(arena, "unknown flag '{s}'", .{a});
        return error.Usage;
    }
    if (!out.dashdash) out.before_dashdash = pos.items.len;
    out.values = values.items;
    out.bools = bools.items;
    out.positionals = pos.items;
    return out;
}

/// `-5`, `-0.5`: negative numbers are values, not flags.
fn isNumber(s: []const u8) bool {
    if (s.len < 2 or s[0] != '-') return false;
    for (s[1..]) |c| if (!(std.ascii.isDigit(c) or c == '.')) return false;
    return true;
}

// ----- usage errors -----

/// `<prog>: <message>` and the usage line on stderr; exit 2.
pub fn usageWithLine(ctx: *Ctx, usage: []const u8, comptime fmt: []const u8, a: anytype) u8 {
    const code = ctx.usageError(fmt, a);
    brand_mod.write(ctx.err, ctx.brand, usage) catch {};
    ctx.err.writeByte('\n') catch {};
    return code;
}

/// Parses `ctx.args()`; prints the usage error itself and returns null.
pub fn parseArgs(ctx: *Ctx, usage: []const u8, spec: Spec) !?Opts {
    var diag: []const u8 = "";
    return parse(ctx.arena, ctx.args(), spec, &diag) catch |err| switch (err) {
        error.Usage => {
            _ = usageWithLine(ctx, usage, "{s}", .{diag});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

// ----- request params -----

pub const Params = struct {
    map: std.json.ObjectMap,

    pub fn init(arena: Allocator) Params {
        return .{ .map = std.json.ObjectMap.init(arena) };
    }

    pub fn str(self: *Params, key: []const u8, v: []const u8) !void {
        try self.map.put(key, .{ .string = v });
    }

    pub fn boolean(self: *Params, key: []const u8, v: bool) !void {
        try self.map.put(key, .{ .bool = v });
    }

    pub fn int(self: *Params, key: []const u8, v: i64) !void {
        try self.map.put(key, .{ .integer = v });
    }

    pub fn float(self: *Params, key: []const u8, v: f64) !void {
        try self.map.put(key, .{ .float = v });
    }

    pub fn value(self: *Params, key: []const u8, v: std.json.Value) !void {
        try self.map.put(key, v);
    }

    pub fn has(self: *const Params, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Minified JSON (`{}` when empty).
    pub fn json(self: *const Params, arena: Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = self.map }, .{});
    }
};

/// A handle as it goes on the wire: an index as a JSON integer, anything
/// else as the trimmed string.
pub fn handleValue(h: handles.HandleText, text: []const u8) std.json.Value {
    return switch (h) {
        .index => |n| .{ .integer = n },
        else => .{ .string = std.mem.trim(u8, text, " \t\r\n") },
    };
}

/// Validates `text` as a `kind` handle; prints cmux's CLI message and returns
/// null on failure (exit 2).
pub fn checkHandle(ctx: *Ctx, kind: Kind, text: []const u8) !?std.json.Value {
    const h = handles.parseHandle(kind, text) catch |err| {
        const m = try selectors.cliMessage(ctx.arena, selectors.cliProblemFor(err), kind, std.mem.trim(u8, text, " \t\r\n"));
        _ = ctx.usageError("{s}", .{m});
        return null;
    };
    return handleValue(h, text);
}

/// Puts `key: <handle>` after validating it; false when the handle was bad
/// (already reported).
pub fn putHandle(ctx: *Ctx, p: *Params, key: []const u8, kind: Kind, text: []const u8) !bool {
    const v = (try checkHandle(ctx, kind, text)) orelse return false;
    try p.value(key, v);
    return true;
}

pub fn envWorkspace(ctx: *Ctx) ?[]const u8 {
    return ctx.env.first(&.{ env_names.CMUX_WORKSPACE_ID, env_names.WMUX_WORKSPACE_ID });
}

pub fn envSurface(ctx: *Ctx) ?[]const u8 {
    return ctx.env.first(&.{ env_names.CMUX_SURFACE_ID, env_names.WMUX_SURFACE_ID });
}

/// Which selectors a command takes and how they default (ADR-4.6).
pub const TargetSpec = struct {
    /// Flag names selecting the surface (`--surface`, `--panel`, `--tab`).
    surface_flags: []const []const u8 = &.{"--surface"},
    /// Default the surface to `CMUX_SURFACE_ID` (neither --workspace nor
    /// --window given).
    env_surface: bool = true,
    /// Default the workspace to `CMUX_WORKSPACE_ID` (neither --workspace nor
    /// --window given).
    env_workspace: bool = true,
    /// Accept `--pane`.
    pane: bool = false,
    /// Param key for the surface (`surface_id`, `tab_id`).
    surface_key: []const u8 = "surface_id",
};

/// The `--window` value: the command's own flag, else the global option.
pub fn windowText(ctx: *Ctx, o: Opts) ?[]const u8 {
    return o.get(&.{"--window"}) orelse ctx.parsed.globals.window;
}

/// Adds `window_id`, `workspace_id`, `surface_id` (and `pane_id`) to `p`
/// from the flags and the caller environment. Returns false after printing
/// a selector error (exit 2).
pub fn addTargets(ctx: *Ctx, p: *Params, o: Opts, spec: TargetSpec) !bool {
    const window = windowText(ctx, o);
    const ws_flag = o.get(&.{"--workspace"});
    if (window) |w| if (!try putHandle(ctx, p, "window_id", .window, w)) return false;
    if (ws_flag) |w| {
        if (std.mem.trim(u8, w, " \t\r\n").len == 0) {
            const env_ws = envWorkspace(ctx) orelse {
                _ = ctx.usageError("{s}", .{proto.errors.msg.no_workspace_selected});
                return false;
            };
            try p.str("workspace_id", env_ws);
        } else if (!try putHandle(ctx, p, "workspace_id", .workspace, w)) return false;
    } else if (window == null and spec.env_workspace) {
        if (envWorkspace(ctx)) |w| try p.str("workspace_id", w);
    }
    if (spec.pane) if (o.get(&.{"--pane"})) |pn| {
        if (!try putHandle(ctx, p, "pane_id", .pane, pn)) return false;
    };
    if (spec.surface_flags.len > 0) {
        if (o.get(spec.surface_flags)) |s| {
            if (!try putHandle(ctx, p, spec.surface_key, .surface, s)) return false;
        } else if (spec.env_surface and ws_flag == null and window == null) {
            if (envSurface(ctx)) |s| try p.str(spec.surface_key, s);
        }
    }
    return true;
}

/// `caller {workspace_id, surface_id}` from the environment (ADR-4.5).
pub fn addCaller(ctx: *Ctx, p: *Params) !void {
    const ws = envWorkspace(ctx);
    const sf = envSurface(ctx);
    if (ws == null and sf == null) return;
    var c = std.json.ObjectMap.init(ctx.arena);
    if (ws) |w| try c.put("workspace_id", .{ .string = w });
    if (sf) |s| try c.put("surface_id", .{ .string = s });
    try p.value("caller", .{ .object = c });
}

// ----- calling and rendering -----

pub const RenderFn = *const fn (ctx: *Ctx, result: std.json.Value) anyerror!void;

/// One request; `--json` prints the id-formatted result, otherwise `render`
/// writes the text form. Errors print through `Ctx.reportError` (exit 1).
pub fn callRender(ctx: *Ctx, method: []const u8, p: *const Params, render: RenderFn) !u8 {
    const out = (try ctx.call(method, try p.json(ctx.arena))) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            if (ctx.json()) {
                try output.writeResult(ctx.arena, ctx.out, ok.result, ctx.parsed.globals.id_format);
            } else try render(ctx, ok.result);
            return output.exit.ok;
        },
        else => return ctx.reportError(method, out),
    }
}

pub fn obj(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = obj(v) orelse return null;
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(v: std.json.Value, key: []const u8) bool {
    const o = obj(v) orelse return false;
    return switch (o.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

pub fn getNum(v: std.json.Value, key: []const u8) ?f64 {
    const o = obj(v) orelse return null;
    return switch (o.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn getArr(v: std.json.Value, key: []const u8) []const std.json.Value {
    const o = obj(v) orelse return &.{};
    return switch (o.get(key) orelse return &.{}) {
        .array => |a| a.items,
        else => &.{},
    };
}

pub fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    const o = obj(v) orelse return null;
    return o.get(key);
}

/// Writes the handle of `v` under `--id-format`: `<prefix>_ref`/`<prefix>_id`
/// or, with a null prefix, `ref`/`id`. Returns false when neither exists.
pub fn writeHandle(ctx: *Ctx, w: *Writer, v: std.json.Value, prefix: ?[]const u8, tab: bool) !bool {
    var rk_buf: [64]u8 = undefined;
    var ik_buf: [64]u8 = undefined;
    const rk = if (prefix) |p| try std.fmt.bufPrint(&rk_buf, "{s}_ref", .{p}) else "ref";
    const ik = if (prefix) |p| try std.fmt.bufPrint(&ik_buf, "{s}_id", .{p}) else "id";
    const ref = getStr(v, rk);
    const id = getStr(v, ik);
    if (ref == null and id == null) return false;
    try idformat.writeHandle(w, ctx.parsed.globals.id_format, ref, id, .{ .tab_context = tab });
    return true;
}

/// `OK` followed by the surface, pane, workspace and window handles the
/// result carries (`OK surface:3 pane:2 workspace:1`). A remote tmux mirror
/// that only accepted the request prints cmux's asynchronous note.
pub fn writeOk(ctx: *Ctx, result: std.json.Value) !void {
    const w = ctx.out;
    try w.writeAll("OK");
    const accepted = getBool(result, "accepted");
    if (accepted) try w.writeAll(" accepted");
    for ([_][]const u8{ "surface", "pane", "workspace", "window" }) |k| {
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        if (try writeHandle(ctx, &aw.writer, result, k, false)) {
            try w.writeByte(' ');
            try w.writeAll(aw.written());
        }
    }
    if (accepted) try w.writeAll(" (routed to remote tmux; the new pane arrives asynchronously)");
    try w.writeByte('\n');
}

pub fn renderOk(ctx: *Ctx, result: std.json.Value) anyerror!void {
    try writeOk(ctx, result);
}

/// Writes `s` with control characters (other than tab) shown as spaces, so a
/// hostile title cannot drive the terminal.
pub fn writeClean(w: *Writer, s: []const u8) !void {
    for (s) |c| try w.writeByte(if ((c < 0x20 and c != '\t') or c == 0x7f) ' ' else c);
}

/// `"<title>"` with control characters neutralized.
pub fn writeQuoted(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeClean(w, s);
    try w.writeByte('"');
}

/// Bytes as `12.3 MiB` / `512 KiB` / `100 B`.
pub fn writeBytes(w: *Writer, bytes: f64) !void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v = if (bytes < 0) 0 else bytes;
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (u == 0) try w.print("{d} {s}", .{ toInt(v), units[0] }) else try w.print("{d:.1} {s}", .{ v, units[u] });
}

/// A JSON number as an integer: NaN → 0, clamped to the i64 range (server
/// numbers never trap the CLI).
pub fn toInt(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    if (v >= 9.2e18) return std.math.maxInt(i64);
    if (v <= -9.2e18) return std.math.minInt(i64);
    return @intFromFloat(v);
}
