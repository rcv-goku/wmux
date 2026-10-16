//! Shared plumbing for the window, workspace and workspace-group command
//! families: usage errors with the usage line, handle validation with cmux's
//! CLI messages (ADR-4.6), v2 params building, one-call-and-render helpers
//! and result field access. Handles are sent as typed: UUIDs and refs as
//! strings, indexes as JSON integers (ADR-2.6).

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const handles = proto.handles;
const selectors = proto.selectors;
const idformat = proto.idformat;
const Kind = handles.Kind;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const brand_mod = @import("../../brand.zig");
const focus_default = @import("../../focus_default.zig");
pub const opts = @import("opts.zig");

/// `<prog>: <message>` and the usage line on stderr; exit 2.
pub fn usage(ctx: *Ctx, usage_line: []const u8, comptime fmt: []const u8, a: anytype) u8 {
    const code = ctx.usageError(fmt, a);
    brand_mod.write(ctx.err, ctx.brand, usage_line) catch {};
    ctx.err.writeByte('\n') catch {};
    return code;
}

/// Parses the command's arguments against `defs`; prints the usage error
/// and returns null on failure (exit code in `code.*`).
pub fn parseOpts(ctx: *Ctx, usage_line: []const u8, args: []const []const u8, defs: []const opts.Def, code: *u8) !?opts.Opts {
    var msg: []const u8 = "";
    return opts.parse(ctx.arena, args, defs, &msg) catch |err| switch (err) {
        error.Usage => {
            code.* = usage(ctx, usage_line, "{s}", .{msg});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Builds a v2 params object.
pub const Params = struct {
    map: std.json.ObjectMap,

    pub fn init(arena: Allocator) Params {
        return .{ .map = std.json.ObjectMap.init(arena) };
    }

    pub fn str(self: *Params, key: []const u8, v: []const u8) !void {
        try self.map.put(key, .{ .string = v });
    }

    pub fn int(self: *Params, key: []const u8, v: i64) !void {
        try self.map.put(key, .{ .integer = v });
    }

    pub fn boolean(self: *Params, key: []const u8, v: bool) !void {
        try self.map.put(key, .{ .bool = v });
    }

    pub fn value(self: *Params, key: []const u8, v: std.json.Value) !void {
        try self.map.put(key, v);
    }

    /// Minified JSON (`{}` when empty).
    pub fn json(self: *const Params, arena: Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = self.map }, .{});
    }
};

/// A handle as a JSON value: index → integer, UUID/ref → trimmed string.
/// On error `msg.*` holds cmux's CLI message.
pub fn handleValue(arena: Allocator, kind: Kind, text: []const u8, msg: *[]const u8) !?std.json.Value {
    const h = handles.parseHandle(kind, text) catch |err| {
        msg.* = try selectors.cliMessage(arena, selectors.cliProblemFor(err), kind, std.mem.trim(u8, text, " \t\r\n"));
        return null;
    };
    return switch (h) {
        .index => |i| .{ .integer = i },
        else => .{ .string = std.mem.trim(u8, text, " \t\r\n") },
    };
}

/// Validates `text` and stores it under `key`; returns an exit code on a
/// usage error.
pub fn putHandle(ctx: *Ctx, p: *Params, usage_line: []const u8, key: []const u8, kind: Kind, text: []const u8) !?u8 {
    var msg: []const u8 = "";
    const v = (try handleValue(ctx.arena, kind, text, &msg)) orelse return usage(ctx, usage_line, "{s}", .{msg});
    try p.value(key, v);
    return null;
}

/// The command's own `--window`, else the global `--window`.
pub fn windowText(ctx: *const Ctx, o: opts.Opts) ?[]const u8 {
    return o.get("--window") orelse ctx.parsed.globals.window;
}

/// `CMUX_WORKSPACE_ID` (or `WMUX_WORKSPACE_ID`) of the calling terminal.
pub fn callerWorkspace(ctx: *const Ctx) ?[]const u8 {
    return ctx.env.first(&.{ env_names.CMUX_WORKSPACE_ID, env_names.WMUX_WORKSPACE_ID });
}

/// Puts `window_id` from `--window` (command or global) when given.
pub fn putWindow(ctx: *Ctx, p: *Params, usage_line: []const u8, o: opts.Opts) !?u8 {
    const w = windowText(ctx, o) orelse return null;
    return putHandle(ctx, p, usage_line, "window_id", .window, w);
}

/// An explicit workspace handle (positional or `--workspace`) stored under
/// `key`. A blank value falls back to `CMUX_WORKSPACE_ID` when no window was
/// named, else fails with cmux's message (ADR-4.6); anything else is
/// validated like any handle.
pub fn putExplicitWorkspace(ctx: *Ctx, p: *Params, usage_line: []const u8, key: []const u8, text: []const u8, window_given: bool) !?u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        if (!window_given) if (callerWorkspace(ctx)) |ws| {
            try p.str(key, ws);
            return null;
        };
        return usage(ctx, usage_line, "{s}", .{proto.errors.msg.no_workspace_selected});
    }
    return putHandle(ctx, p, usage_line, key, .workspace, text);
}

/// Workspace target (ADR-4.6): `explicit` (positional or `--workspace`),
/// else `CMUX_WORKSPACE_ID` when no window was named, else nothing (the
/// server uses the window's selected workspace).
pub fn putWorkspaceTarget(ctx: *Ctx, p: *Params, usage_line: []const u8, explicit: ?[]const u8, window_given: bool) !?u8 {
    if (explicit) |e| return putExplicitWorkspace(ctx, p, usage_line, "workspace_id", e, window_given);
    if (window_given) return null;
    if (callerWorkspace(ctx)) |ws| try p.str("workspace_id", ws);
    return null;
}

/// For a request that should raise wmux (ADR-3.11, ADR-4.6): an interactive,
/// non-agent caller lets the app take the foreground with
/// `AllowSetForegroundWindow(server_pid)` and marks the request
/// `focus:true, foreground_grant:true`. The pipe is opened here when
/// discovery did not already open it (`--socket`, `CMUX_SOCKET_PATH`), so the
/// server PID is known; an open failure is left for the request to report.
/// Returns false when discovery found no app (already reported; exit 1).
pub fn grantForeground(ctx: *Ctx, p: *Params) !bool {
    if (!ctx.platform.isInteractive() or focus_default.isAgentEnvironment(ctx.env, ctx.env_names)) return true;
    const client = (try ctx.connect()) orelse return false;
    if (client.conn == null) {
        const t = ctx.platform.connect(client.gpa, client.opts.path, client.opts.connect_timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return true,
        };
        client.adopt(t);
    }
    const pid = client.conn.?.serverPid() orelse return true;
    ctx.platform.allowForeground(pid);
    try p.boolean("focus", true);
    try p.boolean("foreground_grant", true);
    return true;
}

pub const Reply = union(enum) {
    ok: std.json.Value,
    /// Already reported; exit with this code.
    code: u8,
};

/// One request; errors are printed (with the version-skew diagnosis).
pub fn request(ctx: *Ctx, method: []const u8, p: *const Params) !Reply {
    const params_json = try p.json(ctx.arena);
    const out = (try ctx.call(method, params_json)) orelse return .{ .code = output.exit.runtime };
    return switch (out) {
        .ok => |ok| .{ .ok = ok.result },
        else => .{ .code = try ctx.reportError(method, out) },
    };
}

/// `--json`: the id-formatted result.
pub fn writeJsonResult(ctx: *Ctx, v: std.json.Value) !void {
    try output.writeResult(ctx.arena, ctx.out, v, ctx.parsed.globals.id_format);
}

/// Calls `method` and prints the JSON result or `OK`.
pub fn simple(ctx: *Ctx, method: []const u8, p: *const Params) !u8 {
    switch (try request(ctx, method, p)) {
        .code => |c| return c,
        .ok => |v| {
            if (ctx.json()) try writeJsonResult(ctx, v) else try ctx.out.writeAll("OK\n");
            return output.exit.ok;
        },
    }
}

/// Calls `method` and prints the JSON result or `OK <handle>` of the
/// created `prefix` object (`workspace`, `window`, `workspace_group`).
pub fn created(ctx: *Ctx, method: []const u8, p: *const Params, prefix: []const u8) !u8 {
    switch (try request(ctx, method, p)) {
        .code => |c| return c,
        .ok => |v| {
            if (ctx.json()) {
                try writeJsonResult(ctx, v);
                return output.exit.ok;
            }
            try ctx.out.writeAll("OK");
            if (try handleText(ctx, v, prefix)) |t| try ctx.out.print(" {s}", .{t});
            try ctx.out.writeByte('\n');
            return output.exit.ok;
        },
    }
}

// ----- result access -----

pub fn obj(v: ?std.json.Value) ?std.json.ObjectMap {
    const x = v orelse return null;
    return if (x == .object) x.object else null;
}

pub fn field(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const o = obj(v) orelse return null;
    return o.get(key);
}

pub fn str(v: ?std.json.Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn int(v: ?std.json.Value, key: []const u8) ?i64 {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @floor(f) == f and @abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn boolean(v: ?std.json.Value, key: []const u8) bool {
    const x = field(v, key) orelse return false;
    return x == .bool and x.bool;
}

/// Items of `v[key]` when it is an array, `v` itself when `v` is an array.
pub fn list(v: std.json.Value, key: []const u8) ?[]const std.json.Value {
    if (v == .array) return v.array.items;
    const x = field(v, key) orelse return null;
    return if (x == .array) x.array.items else null;
}

/// The handle of `v` in text form for `--id-format`: `<p>_ref`/`<p>_id`,
/// then `ref`/`id`; null when `v` carries neither.
pub fn handleText(ctx: *Ctx, v: std.json.Value, prefix: []const u8) !?[]const u8 {
    const a = ctx.arena;
    const ref = str(v, try std.fmt.allocPrint(a, "{s}_ref", .{prefix})) orelse str(v, "ref");
    const id = str(v, try std.fmt.allocPrint(a, "{s}_id", .{prefix})) orelse str(v, "id");
    if (ref == null and id == null) return null;
    return try idformat.handleTextAlloc(a, ctx.parsed.globals.id_format, ref, id, .{});
}

/// Writes a number as an integer when whole, else with up to two decimals.
pub fn writeNumber(w: *Writer, v: std.json.Value) !void {
    switch (v) {
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (@floor(f) == f and @abs(f) < 1e15) try w.print("{d}", .{@as(i64, @intFromFloat(f))}) else try w.print("{d:.2}", .{f});
        },
        .number_string => |s| try w.writeAll(s),
        else => try w.writeAll("?"),
    }
}
