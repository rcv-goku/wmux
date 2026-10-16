//! `cmux markdown open <path>` (also `cmux markdown <path>`): a formatted,
//! live-reloading markdown viewer in a new split (panels-markdown-open-cli)
//! via `markdown.open {path, direction, font_size?, surface_id?,
//! workspace_id?, window_id?, focus}`. Direction defaults to right and focus
//! to false; the workspace defaults to the caller's unless --window is given.

const std = @import("std");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");

pub const usage = "Usage: cmux markdown open <path>";
pub const full_usage = "Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction left|right|up|down] [--focus <true|false>] [--font-size <points>]";

pub const spec: CommandSpec = .{ .name = "markdown", .group = .start, .usage = usage, .help = @embedFile("../../help/markdown.txt"), .run = run };

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--workspace", .value = true },
    .{ .name = "--surface", .value = true },
    .{ .name = "--window", .value = true },
    .{ .name = "--direction", .value = true },
    .{ .name = "--focus", .value = true },
    .{ .name = "--font-size", .value = true },
};

pub const directions = [_][]const u8{ "left", "right", "up", "down" };

/// `--font-size`: a number in 8...96, rounded to 2 decimals.
pub fn parseFontSize(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return null;
    if (!std.math.isFinite(v) or v < 8 or v > 96) return null;
    return @round(v * 100) / 100;
}

fn run(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "markdown open", full_usage, ctx.args(), &flag_specs)) orelse return output.exit.usage;
    var pos: std.ArrayList([]const u8) = .empty;
    try pos.appendSlice(ctx.arena, flags.positionals);
    // `markdown open <path>`, or the shorthand `markdown <path>`; an unknown
    // word followed by more arguments is an unknown subcommand.
    const opened = pos.items.len > 0 and std.mem.eql(u8, pos.items[0], "open");
    if (opened) _ = pos.orderedRemove(0);
    if (flags.payload) |p| try pos.appendSlice(ctx.arena, p);
    if (pos.items.len == 0) return ctx.usageError("markdown open requires a file path. {s}", .{try util.branded(ctx, usage)});
    if (pos.items.len > 1) {
        if (!opened) return util.usageFail(ctx, full_usage, "Unknown markdown subcommand '{s}'", .{pos.items[0]});
        return util.usageFail(ctx, full_usage, "markdown open: unexpected argument '{s}'", .{pos.items[1]});
    }
    const direction = flags.get("--direction") orelse "right";
    var known = false;
    for (directions) |d| if (std.mem.eql(u8, d, direction)) {
        known = true;
    };
    if (!known) return util.usageFail(ctx, full_usage, "--direction must be left, right, up or down", .{});
    var font: ?f64 = null;
    if (flags.get("--font-size")) |f| font = parseFontSize(f) orelse return ctx.usageError("--font-size must be a number between 8 and 96", .{});
    const focus = (util.explicitFocus(flags) catch return ctx.usageError("{s}", .{util.focus_value_message})) orelse false;
    const t = util.resolveTarget(ctx, flags, .{}) orelse return output.exit.usage;

    const path = try util.resolvePath(ctx, pos.items[0]);
    var params = util.Params.init(ctx.arena);
    try params.str("path", path);
    try params.str("direction", direction);
    if (font) |f| try params.float("font_size", f);
    try params.optStr("surface_id", t.surface);
    try params.optStr("workspace_id", t.workspace);
    try params.optStr("window_id", t.window);
    try params.boolean("focus", focus);
    const r = (try util.call(ctx, "markdown.open", &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try ctx.out.writeAll("OK");
    if (try util.handleText(ctx, r, "surface")) |s| try ctx.out.print(" surface={s}", .{s});
    if (try util.handleText(ctx, r, "pane")) |p| try ctx.out.print(" pane={s}", .{p});
    try ctx.out.print(" path={s}\n", .{util.fieldStr(r, "path") orelse path});
    return output.exit.ok;
}
