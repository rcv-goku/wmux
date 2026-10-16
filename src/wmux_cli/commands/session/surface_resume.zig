//! `surface-resume <show|get|set|clear>` (also spelled `surface resume ...`):
//! read or change the restart command bound to a terminal surface
//! (persistence-surface-resume-binding-cli). Methods `surface.resume.get`,
//! `surface.resume.set`, `surface.resume.clear`. Selectors default to the
//! caller's `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID`. The other cmux `surface`
//! subcommands (`ls`, `open`, `new-terminal`) are cmux Cloud features.

const std = @import("std");
const proto = @import("wmux_proto");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");

pub const usage = "Usage: cmux surface-resume <show|set|clear> [flags]";

pub const spec: CommandSpec = .{
    .name = "surface-resume",
    .aliases = &.{"surface"},
    .group = .agents,
    .usage = usage ++ "\n       cmux surface resume show [--json] [flags]\n       cmux surface resume set [flags] -- <argv...>",
    .help = @embedFile("../../help/surface-resume.txt"),
    .run = run,
};

/// cmux `surface` subcommands that need cmux Cloud.
const cloud_subs = [_][]const u8{ "ls", "open", "new-terminal" };

const selector_flags = [_]util.FlagSpec{
    .{ .name = "--workspace", .value = true },
    .{ .name = "--surface", .value = true },
    .{ .name = "--window", .value = true },
};

const set_flags = selector_flags ++ [_]util.FlagSpec{
    .{ .name = "--name", .value = true },
    .{ .name = "--kind", .value = true },
    .{ .name = "--checkpoint", .value = true },
    .{ .name = "--checkpoint-id", .value = true },
    .{ .name = "--source", .value = true },
    .{ .name = "--cwd", .value = true },
    .{ .name = "--shell", .value = true },
};

const clear_flags = selector_flags ++ [_]util.FlagSpec{
    .{ .name = "--checkpoint", .value = true },
    .{ .name = "--checkpoint-id", .value = true },
    .{ .name = "--source", .value = true },
};

const rules: util.TargetRules = .{ .surface_default = true };

fn run(ctx: *Ctx) !u8 {
    var rest = ctx.args();
    const typed = ctx.parsed.command orelse "surface-resume";
    if (std.mem.eql(u8, typed, "surface")) {
        if (rest.len == 0) return util.usageFail(ctx, usage, "surface requires a subcommand (resume)", .{});
        for (cloud_subs) |c| if (std.mem.eql(u8, rest[0], c)) {
            try ctx.err.print("{s} surface {s}: not supported on wmux (requires cmux cloud/macOS)\n", .{ ctx.brand.name(), c });
            return output.exit.usage;
        };
        if (!std.mem.eql(u8, rest[0], "resume")) return util.usageFail(ctx, usage, "unknown surface subcommand '{s}'", .{rest[0]});
        rest = rest[1..];
    }
    var sub: []const u8 = "show";
    if (rest.len > 0 and rest[0].len > 0 and rest[0][0] != '-') {
        sub = rest[0];
        rest = rest[1..];
    }
    if (std.mem.eql(u8, sub, "show") or std.mem.eql(u8, sub, "get")) return runShow(ctx, rest);
    if (std.mem.eql(u8, sub, "set")) return runSet(ctx, rest);
    if (std.mem.eql(u8, sub, "clear")) return runClear(ctx, rest);
    return util.usageFail(ctx, usage, "unknown surface resume subcommand '{s}' (expected show, get, set or clear)", .{sub});
}

fn noPositionals(ctx: *Ctx, flags: util.Flags, label: []const u8) ?u8 {
    if (flags.positionals.len > 0) return util.usageFail(ctx, usage, "{s}: unexpected argument '{s}'", .{ label, flags.positionals[0] });
    if (flags.payload) |p| if (p.len > 0) return util.usageFail(ctx, usage, "{s}: unexpected argument '{s}'", .{ label, p[0] });
    return null;
}

fn runShow(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "surface resume show", usage, args, &selector_flags)) orelse return output.exit.usage;
    if (noPositionals(ctx, flags, "surface resume show")) |c| return c;
    const t = util.resolveTarget(ctx, flags, rules) orelse return output.exit.usage;
    var params = util.Params.init(ctx.arena);
    try params.target(t);
    const r = (try util.call(ctx, "surface.resume.get", &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try ctx.out.print("{s}\n", .{bindingText(r)});
    return output.exit.ok;
}

/// Plain `show` output: the command, `No resume binding`, or `null` when
/// the public view hides a private routed command.
pub fn bindingText(r: std.json.Value) []const u8 {
    const b = util.field(r, "resume_binding") orelse return "No resume binding";
    if (b != .object) return "No resume binding";
    return util.fieldStr(b, "command") orelse "null";
}

fn checkpointOf(flags: util.Flags) ?[]const u8 {
    // --checkpoint-id wins over --checkpoint (cmux).
    return flags.get("--checkpoint-id") orelse flags.get("--checkpoint");
}

fn runSet(ctx: *Ctx, args: []const []const u8) !u8 {
    const label = "surface resume set";
    const flags = (try util.flagsOrFail(ctx, label, usage, args, &set_flags)) orelse return output.exit.usage;
    const shell = flags.get("--shell");
    if (flags.positionals.len > 0) {
        if (shell != null) return util.usageFail(ctx, usage, "{s}: unexpected argument '{s}' after the --shell value (--shell takes one complete command string; quote it)", .{ label, flags.positionals[0] });
        return util.usageFail(ctx, usage, "{s}: unexpected argument '{s}' (use --shell <command> or -- <argv...>)", .{ label, flags.positionals[0] });
    }
    const argv: []const []const u8 = flags.payload orelse &.{};
    if (shell != null and argv.len > 0) return util.usageFail(ctx, usage, "{s} accepts either --shell <command> or -- <argv...>, not both", .{label});
    if (shell == null and argv.len == 0) return util.usageFail(ctx, usage, "{s} requires --shell <command> or -- <argv...>", .{label});
    if (shell) |s| if (std.mem.trim(u8, s, " \t\r\n").len == 0) return util.usageFail(ctx, usage, "{s}: --shell requires a non-empty command", .{label});
    if (argv.len > 0 and argv[0].len == 0) return util.usageFail(ctx, usage, "{s}: the program after -- is empty", .{label});

    const t = util.resolveTarget(ctx, flags, rules) orelse return output.exit.usage;
    var params = util.Params.init(ctx.arena);
    try params.target(t);
    try params.optStr("name", flags.get("--name"));
    try params.optStr("kind", flags.get("--kind"));
    try params.optStr("checkpoint_id", checkpointOf(flags));
    try params.str("source", flags.get("--source") orelse "cli");
    const cwd = if (flags.get("--cwd")) |c| try util.resolvePath(ctx, c) else ctx.env.getNonEmpty("PWD") orelse ctx.platform.cwd(ctx.arena);
    try params.optStr("cwd", cwd);
    if (shell) |s| {
        try params.str("command", s);
    } else {
        // Display form (POSIX quoting, as cmux stores it); the structured
        // argv lets the app re-quote for the surface's own shell.
        const cmd = proto.shell_quote.commandAlloc(ctx.arena, .posix, argv) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unrepresentable => return util.usageFail(ctx, usage, "{s}: an argument cannot be represented as a shell word", .{label}),
        };
        try params.str("command", cmd);
        var launch = util.Params.init(ctx.arena);
        try launch.strings("argv", argv);
        try params.put("launch_command", .{ .object = launch.obj });
    }
    const r = (try util.call(ctx, "surface.resume.set", &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try ctx.out.writeAll("OK\n");
    if (util.field(r, "approval_required")) |a| if (a == .bool and a.bool) {
        try ctx.out.writeAll("Approval required: approve this command from the terminal context menu or Settings > Terminal > Resume Commands before it resumes automatically.\n");
    };
    return output.exit.ok;
}

fn runClear(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "surface resume clear", usage, args, &clear_flags)) orelse return output.exit.usage;
    if (noPositionals(ctx, flags, "surface resume clear")) |c| return c;
    const t = util.resolveTarget(ctx, flags, rules) orelse return output.exit.usage;
    var params = util.Params.init(ctx.arena);
    try params.target(t);
    try params.optStr("checkpoint_id", checkpointOf(flags));
    try params.optStr("source", flags.get("--source"));
    const r = (try util.call(ctx, "surface.resume.clear", &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    const cleared = if (util.field(r, "cleared")) |c| c == .bool and c.bool else false;
    try ctx.out.print("OK cleared={}\n", .{cleared});
    return output.exit.ok;
}
