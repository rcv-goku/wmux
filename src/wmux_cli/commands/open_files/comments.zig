//! `cmux comments list|ls [--repo <path>] [--all] [--json]`
//! (panels-comments-cli): read-only listing of diff review comments for one
//! git repository via `comments.list {repo, all}`. The repository root is
//! the nearest directory with `.git` at or above --repo (default: the
//! current directory). Unknown subcommands fail before the repository is
//! resolved or the app is contacted.

const std = @import("std");
const proto = @import("wmux_proto");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");

pub const usage = "Usage: cmux comments <subcommand> [options]";
const list_usage = "Usage: cmux comments list [--repo <path>] [--all] [--json]";

pub const spec: CommandSpec = .{ .name = "comments", .group = .inspect, .usage = usage, .help = @embedFile("../../help/comments.txt"), .run = run };

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--repo", .value = true },
    .{ .name = "--all" },
};

fn run(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0 or a[0].len == 0 or a[0][0] == '-') return util.usageFail(ctx, list_usage, "comments requires a subcommand (list)", .{});
    if (!std.mem.eql(u8, a[0], "list") and !std.mem.eql(u8, a[0], "ls")) return util.usageFail(ctx, list_usage, "unknown comments subcommand '{s}'", .{a[0]});
    const flags = (try util.flagsOrFail(ctx, "comments list", list_usage, a[1..], &flag_specs)) orelse return output.exit.usage;
    if (flags.positionals.len > 0) return util.usageFail(ctx, list_usage, "comments list: unexpected argument '{s}'", .{flags.positionals[0]});
    const start = if (flags.get("--repo")) |r| try util.resolvePath(ctx, r) else ctx.platform.cwd(ctx.arena) orelse
        return ctx.runtimeError("comments list: cannot determine the current directory; pass --repo <path>", .{});
    const root = (try util.gitRoot(ctx, start)) orelse return ctx.runtimeError("comments list: not inside a git repository: {s}", .{start});
    var params = util.Params.init(ctx.arena);
    try params.str("repo", root);
    try params.boolean("all", flags.has("--all"));
    const r = (try util.call(ctx, "comments.list", &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try writeText(ctx.out, r);
    return output.exit.ok;
}

/// A count line, then `<basename>:<start>[-<end>]  <message>` per comment.
pub fn writeText(w: *std.Io.Writer, r: std.json.Value) !void {
    const list: []const std.json.Value = if (util.field(r, "comments")) |c| (if (c == .array) c.array.items else &.{}) else &.{};
    try w.print("{d} comment{s}\n", .{ list.len, if (list.len == 1) "" else "s" });
    for (list) |c| {
        const file = util.fieldStr(c, "file") orelse util.fieldStr(c, "path") orelse "";
        try w.writeAll(proto.paths.basename(.windows, file));
        if (util.fieldInt(c, "start_line") orelse util.fieldInt(c, "line")) |s| {
            try w.print(":{d}", .{s});
            if (util.fieldInt(c, "end_line")) |e| if (e != s) try w.print("-{d}", .{e});
        }
        try w.writeAll("  ");
        const msg = util.fieldStr(c, "message") orelse util.fieldStr(c, "body") orelse "";
        // One line per comment.
        for (msg) |ch| try w.writeByte(if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch);
        try w.writeByte('\n');
    }
}
