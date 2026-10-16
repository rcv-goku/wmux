//! CLI command family `system` (Appendix C).
//! help, version, guide (--skill), docs, welcome, ping, capabilities, rpc,
//! socket-status (W1-2); identify, tree (W2-2); top, memory (W5a); sudo (W7).
//! `identify` ships with W1-2 as a plain JSON print so the version-skew
//! diagnosis and scripts have it; WP CLI-fam-ps adds its `--workspace`,
//! `--surface`, `--window` and `--no-caller` flags and the `tree`, `top`,
//! `memory` and `shot`/`screenshot` commands (inspect.zig).

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const help = @import("../help.zig");
const guide = @import("../guide.zig");
const docs = @import("../docs.zig");
const welcome = @import("../welcome.zig");
const socket_status = @import("../socket_status.zig");
const discovery = @import("../discovery.zig");
const brand_mod = @import("../brand.zig");
const inspect = @import("inspect.zig");

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "help", .group = .diagnostics, .usage = "Usage: cmux help [topic]", .help = @embedFile("../help/help.txt"), .socket = .none, .run = runHelp },
    .{ .name = "version", .group = .diagnostics, .usage = "Usage: cmux version", .help = @embedFile("../help/version.txt"), .socket = .none, .handles_help = true, .run = runVersion },
    .{ .name = "guide", .group = .start, .usage = guide.usage, .help = @embedFile("../help/guide.txt"), .socket = .none, .run = runGuide },
    .{ .name = "docs", .group = .start, .usage = docs.usage, .help = @embedFile("../help/docs.txt"), .socket = .none, .run = runDocs },
    .{ .name = "welcome", .group = .start, .usage = "Usage: cmux welcome", .help = welcome.help_text, .socket = .none, .run = runWelcome },
    .{ .name = "socket-status", .group = .diagnostics, .usage = socket_status.usage, .help = @embedFile("../help/socket-status.txt"), .socket = .none, .run = runSocketStatus },
    .{ .name = "ping", .group = .diagnostics, .usage = "Usage: cmux ping", .help = @embedFile("../help/ping.txt"), .run = runPing },
    .{ .name = "capabilities", .group = .diagnostics, .usage = "Usage: cmux capabilities", .help = @embedFile("../help/capabilities.txt"), .run = runCapabilities },
    .{ .name = "rpc", .group = .diagnostics, .usage = "Usage: cmux rpc <method> [json-params]", .help = @embedFile("../help/rpc.txt"), .run = runRpc },
    .{ .name = "identify", .group = .inspect, .usage = "Usage: cmux identify", .help = @embedFile("../help/identify.txt"), .run = runIdentify },
    .{ .name = "tree", .group = .inspect, .usage = inspect.tree_usage, .help = @embedFile("../help/tree.txt"), .run = inspect.runTree },
    .{ .name = "top", .group = .inspect, .usage = inspect.top_usage, .help = @embedFile("../help/top.txt"), .run = inspect.runTop },
    .{ .name = "memory", .group = .inspect, .usage = inspect.memory_usage, .help = @embedFile("../help/memory.txt"), .run = inspect.runMemory },
    .{ .name = "shot", .aliases = &.{"screenshot"}, .group = .inspect, .usage = inspect.shot_usage, .help = @embedFile("../help/shot.txt"), .run = inspect.runShot },
};

/// Max params read from stdin by `rpc -` (the server's line cap).
pub const max_stdin_params = 16 * 1024 * 1024;

fn noArgs(ctx: *Ctx, usage: []const u8) ?u8 {
    if (ctx.args().len == 0) return null;
    return usageWithLine(ctx, usage, "unexpected argument '{s}'", .{ctx.args()[0]});
}

fn usageWithLine(ctx: *Ctx, usage: []const u8, comptime fmt: []const u8, a: anytype) u8 {
    const code = ctx.usageError(fmt, a);
    brand_mod.write(ctx.err, ctx.brand, usage) catch {};
    ctx.err.writeByte('\n') catch {};
    return code;
}

fn runHelp(ctx: *Ctx) !u8 {
    try help.writeHelpCommand(ctx.out, ctx.brand, ctx.args());
    return output.exit.ok;
}

fn runVersion(ctx: *Ctx) !u8 {
    try ctx.out.print("{s}\n", .{ctx.version_summary});
    return output.exit.ok;
}

fn runGuide(ctx: *Ctx) !u8 {
    if (noArgs(ctx, guide.usage)) |code| return code;
    try guide.write(ctx.out, ctx.brand, ctx.json());
    return output.exit.ok;
}

fn runDocs(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len > 1) return usageWithLine(ctx, docs.usage, "docs takes at most one topic", .{});
    if (a.len == 0) {
        if (ctx.json()) try docs.writeTopicListJson(ctx.out) else {
            var aw: std.Io.Writer.Allocating = .init(ctx.arena);
            try docs.writeTopicList(&aw.writer);
            try ctx.print(aw.written());
        }
        return output.exit.ok;
    }
    const topic = docs.find(a[0]) orelse return usageWithLine(ctx, docs.usage, "unknown docs topic '{s}'", .{a[0]});
    const loc = try docs.Locations.resolve(ctx.arena, ctx.env, ctx.platform.selfExePath(ctx.arena));
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    if (ctx.json()) try docs.writeTopicJson(ctx.arena, &aw.writer, topic, loc) else try docs.writeTopic(ctx.arena, &aw.writer, topic, loc);
    try ctx.print(aw.written());
    return output.exit.ok;
}

fn runWelcome(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "Usage: cmux welcome")) |code| return code;
    try welcome.write(ctx.out, ctx.brand, .{
        .color = ctx.platform.stdoutIsTerminal() and ctx.env.get("NO_COLOR") == null,
        .light = ctx.platform.prefersLightTheme(),
    });
    return output.exit.ok;
}

fn settingsMode(ctx: *Ctx, dir: ?[]const u8, file: []const u8) ?[]const u8 {
    const d = dir orelse return null;
    const path = proto.paths.join(ctx.arena, proto.paths.Style.native, &.{ d, file }) catch return null;
    const bytes = ctx.platform.readFile(ctx.arena, path, 4 * 1024 * 1024) orelse return null;
    return socket_status.modeFromSettings(ctx.arena, bytes);
}

/// Inputs for socket-status from files, environment, registry and the pipe
/// namespace; nothing connects.
pub fn socketStatusInputs(ctx: *Ctx) !socket_status.Inputs {
    const style = proto.paths.Style.native;
    const cfg = try proto.paths.configDir(ctx.arena, ctx.env, style);
    const cmux_cfg = try proto.paths.cmuxConfigDir(ctx.arena, ctx.env, style);
    const din = try ctx.discoveryInputs();
    var socket_path: ?[]const u8 = null;
    if (try discovery.explicitPath(ctx.arena, din)) |o| switch (o) {
        .explicit => |e| socket_path = e.path,
        else => {},
    };
    if (socket_path == null) socket_path = try discovery.defaultPath(ctx.arena, din);
    return .{
        .cmux_json = settingsMode(ctx, cmux_cfg, proto.paths.files.cmux_json),
        .wmux_json = settingsMode(ctx, cfg, proto.paths.files.wmux_json),
        .env = ctx.env,
        .hklm = ctx.platform.policy(ctx.arena, .hklm),
        .hkcu = ctx.platform.policy(ctx.arena, .hkcu),
        .socket_path = socket_path,
        .socket_path_state = if (socket_path) |p| ctx.platform.pipeState(ctx.arena, p) else .other,
    };
}

fn runSocketStatus(ctx: *Ctx) !u8 {
    if (noArgs(ctx, socket_status.usage)) |code| return code;
    const status = socket_status.resolve(try socketStatusInputs(ctx));
    if (ctx.json()) try socket_status.writeJson(ctx.out, status) else try socket_status.writeText(ctx.out, status);
    return output.exit.ok;
}

fn runPing(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "Usage: cmux ping")) |code| return code;
    const out = (try ctx.call("system.ping", null)) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            if (ctx.json()) try output.writeJson(ctx.out, ok.result) else try ctx.out.writeAll("PONG\n");
            return output.exit.ok;
        },
        else => return ctx.reportError("system.ping", out),
    }
}

fn runCapabilities(ctx: *Ctx) !u8 {
    if (noArgs(ctx, "Usage: cmux capabilities")) |code| return code;
    const out = (try ctx.call("system.capabilities", null)) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            try output.writeResult(ctx.arena, ctx.out, ok.result, ctx.parsed.globals.id_format);
            return output.exit.ok;
        },
        else => return ctx.reportError("system.capabilities", out),
    }
}

/// `{"caller":{"workspace_id":…,"surface_id":…}}` from the environment, or
/// null outside wmux terminals (ADR-4.5).
pub fn callerParams(ctx: *Ctx) !?[]const u8 {
    const ws = ctx.env.first(&.{ env_names.CMUX_WORKSPACE_ID, env_names.WMUX_WORKSPACE_ID });
    const sf = ctx.env.first(&.{ env_names.CMUX_SURFACE_ID, env_names.WMUX_SURFACE_ID });
    if (ws == null and sf == null) return null;
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(.{ .caller = .{ .workspace_id = ws, .surface_id = sf } });
    return aw.written();
}

fn runIdentify(ctx: *Ctx) !u8 {
    const params = if (ctx.args().len == 0 and ctx.parsed.globals.window == null)
        try callerParams(ctx)
    else blk: {
        const p = (try inspect.identifyParams(ctx)) orelse return output.exit.usage;
        break :blk try p.json(ctx.arena);
    };
    const out = (try ctx.call("system.identify", params)) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            try output.writeResult(ctx.arena, ctx.out, ok.result, ctx.parsed.globals.id_format);
            return output.exit.ok;
        },
        else => return ctx.reportError("system.identify", out),
    }
}

const rpc_usage = "Usage: cmux rpc <method> [json-params]";

fn runRpc(ctx: *Ctx) !u8 {
    // Positionals, allowing `cmux rpc -- <method> ...`.
    var pos: std.ArrayList([]const u8) = .empty;
    for (ctx.args()) |a| {
        if (std.mem.eql(u8, a, "--") and pos.items.len == 0) continue;
        try pos.append(ctx.arena, a);
    }
    if (pos.items.len == 0) return usageWithLine(ctx, rpc_usage, "rpc requires a method", .{});
    if (pos.items.len > 2) return usageWithLine(ctx, rpc_usage, "unexpected argument '{s}'", .{pos.items[2]});
    const method = std.mem.trim(u8, pos.items[0], " \t");
    if (method.len == 0) return usageWithLine(ctx, rpc_usage, "rpc requires a method", .{});

    var params_text: []const u8 = "{}";
    if (pos.items.len == 2) {
        if (std.mem.eql(u8, pos.items[1], "-")) {
            params_text = ctx.platform.readStdin(ctx.arena, max_stdin_params) catch |err| switch (err) {
                error.TooLarge => return ctx.usageError("rpc params on stdin exceed 16 MiB", .{}),
                error.ReadFailed => return ctx.runtimeError("cannot read rpc params from stdin", .{}),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (std.mem.trim(u8, params_text, " \t\r\n").len == 0) params_text = "{}";
        } else params_text = pos.items[1];
    }
    var params = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, params_text, .{}) catch
        return usageWithLine(ctx, rpc_usage, "rpc params are not valid JSON", .{});
    if (params != .object) return usageWithLine(ctx, rpc_usage, "rpc params must be a JSON object", .{});
    if (ctx.parsed.globals.window) |win| {
        if (std.mem.eql(u8, method, "surface.read_selection") and params.object.get("window_id") == null) {
            try params.object.put("window_id", .{ .string = win });
        }
    }
    const params_json = try std.json.Stringify.valueAlloc(ctx.arena, params, .{});
    const out = (try ctx.call(method, params_json)) orelse return output.exit.runtime;
    switch (out) {
        .ok => |ok| {
            const v = if (ctx.parsed.globals.id_format_explicit) try output.formatIds(ctx.arena, ok.result, ctx.parsed.globals.id_format) else ok.result;
            try output.writeJson(ctx.out, v);
            return output.exit.ok;
        },
        else => return ctx.reportError(method, out),
    }
}
