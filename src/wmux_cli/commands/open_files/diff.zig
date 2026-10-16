//! `cmux diff [<patch>|-|<PR URL>] [--source ...] ...` (panels-diff-cli):
//! a diff viewer panel via `wmux.diff.open` (Appendix B.3). The CLI reads a
//! patch file or piped stdin itself and sends the text; git sources
//! (`--unstaged`, `--staged`, `--branch`, `--last-turn`, `--repo`, `--base`,
//! `--session`) are described to the app, which runs git (the CLI platform
//! layer has no captured-output process API). Focus defaults to false; the
//! workspace and surface default to the caller's.

const std = @import("std");
const proto = @import("wmux_proto");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");
const open = @import("open.zig");

pub const usage = "Usage: cmux diff [<patch>|-] [--source <source>] [--repo <path>] [--base <ref>] [--staged|--unstaged] [--json]";

pub const spec: CommandSpec = .{ .name = "diff", .group = .inspect, .usage = usage, .help = @embedFile("../../help/diff.txt"), .run = run };

/// Max patch bytes read from a file or stdin.
pub const max_patch_bytes = 16 * 1024 * 1024;
pub const default_font_size: f64 = 10;
pub const sources = [_][]const u8{ "unstaged", "staged", "branch", "last-turn" };
pub const no_input_message = "diff requires a patch file, piped stdin, or a git source (--unstaged, --staged, --branch, --last-turn, --repo, --base)";

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--source", .value = true },
    .{ .name = "--unstaged" },
    .{ .name = "--staged" },
    .{ .name = "--branch" },
    .{ .name = "--last-turn" },
    .{ .name = "--workspace", .value = true },
    .{ .name = "--surface", .value = true },
    .{ .name = "--window", .value = true },
    .{ .name = "--session", .value = true, .alias = "--agent-session" },
    .{ .name = "--repo", .value = true },
    .{ .name = "--cwd", .value = true },
    .{ .name = "--path", .value = true },
    .{ .name = "--base", .value = true, .alias = "--branch-base" },
    .{ .name = "--focus", .value = true },
    .{ .name = "--no-focus" },
    .{ .name = "--title", .value = true },
    .{ .name = "--layout", .value = true },
    .{ .name = "--font-size", .value = true },
};

pub const SourceError = error{ InvalidSource, Conflict };

/// The single git source named by the flags (in order of appearance), or
/// null. `conflict` receives the two different names on `error.Conflict`.
pub fn pickSource(flags: util.Flags, conflict: *[2][]const u8) SourceError!?[]const u8 {
    var found: ?[]const u8 = null;
    for (flags.hits) |h| {
        const name: []const u8 = if (std.mem.eql(u8, h.name, "--source")) blk: {
            const v = h.value.?;
            for (sources) |s| if (std.mem.eql(u8, s, v)) break :blk s;
            return error.InvalidSource;
        } else if (std.mem.eql(u8, h.name, "--unstaged")) "unstaged" else if (std.mem.eql(u8, h.name, "--staged")) "staged" else if (std.mem.eql(u8, h.name, "--branch")) "branch" else if (std.mem.eql(u8, h.name, "--last-turn")) "last-turn" else continue;
        if (found) |f| if (!std.mem.eql(u8, f, name)) {
            conflict.* = .{ f, name };
            return error.Conflict;
        };
        found = name;
    }
    return found;
}

/// `--font-size`: > 0 and <= 96.
pub fn parseFontSize(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return null;
    if (!std.math.isFinite(v) or v <= 0 or v > 96) return null;
    return v;
}

fn repoFlag(flags: util.Flags) ?[]const u8 {
    var out: ?[]const u8 = null;
    for (flags.hits) |h| {
        if (std.mem.eql(u8, h.name, "--repo") or std.mem.eql(u8, h.name, "--cwd") or std.mem.eql(u8, h.name, "--path")) out = h.value;
    }
    return out;
}

fn run(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "diff", usage, ctx.args(), &flag_specs)) orelse return output.exit.usage;
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.appendSlice(ctx.arena, flags.positionals);
    if (flags.payload) |p| try inputs.appendSlice(ctx.arena, p);
    if (inputs.items.len > 1) return util.usageFail(ctx, usage, "diff accepts at most one patch file, got '{s}' and '{s}'", .{ inputs.items[0], inputs.items[1] });
    var conflict: [2][]const u8 = undefined;
    var source = pickSource(flags, &conflict) catch |err| switch (err) {
        error.InvalidSource => return util.usageFail(ctx, usage, "--source must be unstaged, staged, branch or last-turn", .{}),
        error.Conflict => return util.usageFail(ctx, usage, "diff accepts only one source, got {s} and {s}", .{ conflict[0], conflict[1] }),
    };
    const repo_flag = repoFlag(flags);
    const base = flags.get("--base");
    const session = flags.get("--session");
    const git = source != null or repo_flag != null or base != null or session != null;
    if (inputs.items.len == 1 and git) return util.usageFail(ctx, usage, "diff accepts either a patch file or a git source, not both", .{});
    if (git and source == null) source = if (base != null) "branch" else if (session != null) "last-turn" else "unstaged";

    var font: f64 = default_font_size;
    if (flags.get("--font-size")) |f| font = parseFontSize(f) orelse return ctx.usageError("--font-size must be a number greater than 0 and at most 96", .{});
    const layout = flags.get("--layout");
    if (layout) |l| if (!std.mem.eql(u8, l, "split") and !std.mem.eql(u8, l, "unified")) return ctx.usageError("--layout must be split or unified", .{});
    const focus = (util.explicitFocus(flags) catch return ctx.usageError("{s}", .{util.focus_value_message})) orelse false;
    const t = util.resolveTarget(ctx, flags, .{ .surface_default = true }) orelse return output.exit.usage;

    var params = util.Params.init(ctx.arena);
    if (inputs.items.len == 1) {
        const input = inputs.items[0];
        if (open.isWebUrl(input)) {
            try params.str("url", input);
        } else if (std.mem.eql(u8, input, "-")) {
            if (try readStdinPatch(ctx, &params)) |code| return code;
        } else {
            const abs = try util.resolvePath(ctx, input);
            const text = ctx.platform.readFile(ctx.arena, abs, max_patch_bytes) orelse return ctx.runtimeError("diff: cannot read patch file {s}", .{abs});
            try params.str("patch", text);
            try params.str("patch_path", abs);
            if (try util.gitRoot(ctx, parentDir(abs))) |root| try params.str("repo", root);
        }
    } else if (source) |s| {
        try params.str("source", s);
        const repo_start = if (repo_flag) |r| try util.resolvePath(ctx, r) else ctx.platform.cwd(ctx.arena);
        if (repo_start) |rs| try params.str("repo", (try util.gitRoot(ctx, rs)) orelse rs);
        try params.optStr("base", base);
        try params.optStr("session", session);
    } else {
        if (ctx.platform.isInteractive()) return util.usageFail(ctx, usage, "{s}", .{no_input_message});
        if (try readStdinPatch(ctx, &params)) |code| return code;
    }
    try params.optStr("title", flags.get("--title"));
    try params.optStr("layout", layout);
    try params.float("font_size", font);
    try params.boolean("focus", focus);
    try params.target(t);
    const r = (try util.call(ctx, "wmux.diff.open", &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try ctx.out.writeAll("OK");
    if (try util.handleText(ctx, r, "surface")) |s| try ctx.out.print(" surface={s}", .{s});
    if (try util.handleText(ctx, r, "pane")) |p| try ctx.out.print(" pane={s}", .{p});
    try ctx.out.writeByte('\n');
    return output.exit.ok;
}

fn parentDir(path: []const u8) []const u8 {
    return proto.paths.dirname(proto.paths.Style.native, path) orelse path;
}

/// Piped patch text as `patch`, with the repository guessed from the cwd so
/// comments persist per repository.
fn readStdinPatch(ctx: *Ctx, params: *util.Params) !?u8 {
    const text = ctx.platform.readStdin(ctx.arena, max_patch_bytes) catch |err| switch (err) {
        error.TooLarge => return ctx.usageError("diff: the patch on stdin exceeds 16 MiB", .{}),
        error.ReadFailed => return ctx.runtimeError("diff: cannot read the patch from stdin", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return util.usageFail(ctx, usage, "{s}", .{no_input_message});
    try params.str("patch", text);
    if (ctx.platform.cwd(ctx.arena)) |cwd| if (try util.gitRoot(ctx, cwd)) |root| try params.str("repo", root);
    return null;
}
