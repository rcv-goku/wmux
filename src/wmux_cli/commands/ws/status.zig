//! `workspace status [set <lane> | cycle]` (sidebar-workspace-status-cli)
//! and `workspace reconnect|disconnect` (remote-workspace-reconnect-
//! disconnect-cli).
//!
//! Status methods: `workspace.status.get`, `workspace.status.set {status}`,
//! `workspace.status.cycle`; the payload `{effective, inferred, override:
//! {status, inferred_at_override} | null}` prints as three lines. Remote
//! methods: `workspace.remote.reconnect`, `workspace.remote.disconnect`.
//! All target the caller's workspace by default.

const std = @import("std");
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const common = @import("common.zig");
const Def = common.opts.Def;
const Params = common.Params;

pub const lanes = [_][]const u8{ "todo", "working", "needs-attention", "review", "done", "auto", "none" };

pub fn isLane(s: []const u8) bool {
    for (lanes) |l| if (std.mem.eql(u8, l, s)) return true;
    return false;
}

const target_defs = [_]Def{ .{ .name = "--workspace" }, .{ .name = "--window" } };

pub fn runStatus(ctx: *Ctx, args: []const []const u8, u: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, args, &target_defs, &code)) orelse return code;
    const pos = o.positionals;
    var p = Params.init(ctx.arena);
    var method: []const u8 = "workspace.status.get";
    if (pos.len > 0) {
        const sub = pos[0];
        if (std.mem.eql(u8, sub, "set")) {
            if (pos.len < 2) return common.usage(ctx, u, "workspace status set requires a lane: {s}", .{try std.mem.join(ctx.arena, ", ", &lanes)});
            if (pos.len > 2) return common.usage(ctx, u, "unexpected argument '{s}'", .{pos[2]});
            if (!isLane(pos[1])) return common.usage(ctx, u, "Invalid workspace status '{s}'. Expected one of: {s}", .{ pos[1], try std.mem.join(ctx.arena, ", ", &lanes) });
            method = "workspace.status.set";
            try p.str("status", pos[1]);
        } else if (std.mem.eql(u8, sub, "cycle")) {
            if (pos.len > 1) return common.usage(ctx, u, "unexpected argument '{s}'", .{pos[1]});
            method = "workspace.status.cycle";
        } else {
            return common.usage(ctx, u, "Unknown workspace status subcommand: {s}. Try: cmux workspace status [set <lane|auto> | cycle]", .{sub});
        }
    }
    if (try common.putWorkspaceTarget(ctx, &p, u, o.get("--workspace"), common.windowText(ctx, o) != null)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    const v = switch (try common.request(ctx, method, &p)) {
        .code => |c| return c,
        .ok => |v| v,
    };
    if (ctx.json()) {
        try common.writeJsonResult(ctx, v);
        return output.exit.ok;
    }
    try writeStatus(ctx.out, v);
    return output.exit.ok;
}

/// The three status lines.
pub fn writeStatus(w: *std.Io.Writer, v: std.json.Value) !void {
    // cmux reads a missing lane as "todo".
    const inferred = common.str(v, "inferred") orelse "todo";
    try w.print("{s}\ninferred: {s}\n", .{ common.str(v, "effective") orelse "todo", inferred });
    const ov = common.field(v, "override");
    if (common.str(ov, "status")) |s| {
        const at = common.str(ov, "inferred_at_override") orelse inferred;
        try w.print("override: {s} (auto-clears when inferred moves off {s})\n", .{ s, at });
    } else try w.writeAll("override: none (auto)\n");
}

/// `workspace reconnect|disconnect [<handle>] [--workspace <h>]`.
pub fn runRemote(ctx: *Ctx, args: []const []const u8, u: []const u8, method: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, args, &target_defs, &code)) orelse return code;
    if (o.positionals.len > 1) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[1]});
    if (o.positionals.len == 1 and o.get("--workspace") != null) return common.usage(ctx, u, "give the workspace as an argument or --workspace, not both", .{});
    const explicit: ?[]const u8 = if (o.positionals.len == 1) o.positionals[0] else o.get("--workspace");
    var p = Params.init(ctx.arena);
    if (try common.putWorkspaceTarget(ctx, &p, u, explicit, common.windowText(ctx, o) != null)) |c| return c;
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    return common.simple(ctx, method, &p, &.{ "workspace", "window" });
}
