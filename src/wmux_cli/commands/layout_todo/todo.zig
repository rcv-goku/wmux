//! `cmux todo <sub>`: the per-workspace checklist (sidebar-todo-cli) over
//! `workspace.todo.{list,add,set_state,edit,remove,move,clear,set,open}`.
//! Targets the caller's workspace (`CMUX_WORKSPACE_ID`) unless `--workspace`
//! or `--window` is given. `<index|id>` is resolved client-side: a UUID is
//! sent as `item_id`; a 1-based number from `todo list` is looked up with
//! `workspace.todo.list` first, so every mutation names an exact item.

const std = @import("std");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");
const rules = @import("todo_rules.zig");

pub const usage = "Usage: cmux todo <add|list|check|uncheck|start|edit|rm|move|clear|set|open> [args]";

pub const spec: CommandSpec = .{ .name = "todo", .group = .automation, .usage = usage, .help = @embedFile("../../help/todo.txt"), .run = run };

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--workspace", .value = true },
    .{ .name = "--window", .value = true },
    .{ .name = "--state", .value = true },
    .{ .name = "--origin", .value = true },
};

const Sub = enum { add, list, check, uncheck, start, edit, rm, move, clear, set, open };

fn parseSub(s: []const u8) ?Sub {
    const map = std.StaticStringMap(Sub).initComptime(.{
        .{ "add", .add },     .{ "list", .list },       .{ "ls", .list },
        .{ "check", .check }, .{ "uncheck", .uncheck }, .{ "start", .start },
        .{ "edit", .edit },   .{ "rm", .rm },           .{ "remove", .rm },
        .{ "move", .move },   .{ "mv", .move },         .{ "clear", .clear },
        .{ "set", .set },     .{ "open", .open },
    });
    return map.get(s);
}

/// Positional arguments each subcommand takes (after the subcommand).
fn arity(sub: Sub) struct { min: usize, max: usize } {
    return switch (sub) {
        .list, .clear, .open => .{ .min = 0, .max = 0 },
        .add, .check, .uncheck, .start, .rm => .{ .min = 1, .max = 1 },
        .edit, .move => .{ .min = 2, .max = 2 },
        .set => .{ .min = 0, .max = 1 },
    };
}

fn run(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "todo", usage, ctx.args(), &flag_specs)) orelse return output.exit.usage;
    var pos: std.ArrayList([]const u8) = .empty;
    try pos.appendSlice(ctx.arena, flags.positionals);
    // `--` lets item text start with a dash.
    if (flags.payload) |p| try pos.appendSlice(ctx.arena, p);
    if (pos.items.len == 0) return util.usageFail(ctx, usage, "todo requires a subcommand", .{});
    const name = pos.items[0];
    const sub = parseSub(name) orelse return util.usageFail(ctx, usage, "unknown todo subcommand '{s}'", .{name});
    const args = pos.items[1..];
    const ar = arity(sub);
    if (args.len < ar.min) return util.usageFail(ctx, usage, "todo {s}: {s}", .{ name, missingText(sub) });
    if (args.len > ar.max) return util.usageFail(ctx, usage, "todo {s}: unexpected argument '{s}'", .{ name, args[ar.max] });
    if (sub != .add) {
        if (flags.has("--state")) return util.usageFail(ctx, usage, "todo {s}: --state is only valid with todo add", .{name});
        if (flags.has("--origin")) return util.usageFail(ctx, usage, "todo {s}: --origin is only valid with todo add", .{name});
    }
    const target = util.resolveTarget(ctx, flags, .{}) orelse return output.exit.usage;
    var params = util.Params.init(ctx.arena);
    try params.optStr("window_id", target.window);
    try params.optStr("workspace_id", target.workspace);

    switch (sub) {
        .list => {
            const r = (try util.call(ctx, "workspace.todo.list", &params)) orelse return output.exit.runtime;
            if (ctx.json()) {
                try util.writeJsonResult(ctx, r);
            } else try rules.writeList(ctx.out, rules.itemsOf(r) orelse &.{});
            return output.exit.ok;
        },
        .add => {
            const text = rules.trimText(args[0]) orelse return util.usageFail(ctx, usage, "todo add: text must be UTF-8", .{});
            if (text.len == 0) return util.usageFail(ctx, usage, "todo add requires non-empty text", .{});
            try params.str("text", text);
            if (flags.get("--state")) |s| {
                if (!rules.isState(s)) return util.usageFail(ctx, usage, "--state must be pending, in-progress or completed", .{});
                try params.str("state", s);
            }
            if (flags.get("--origin")) |o| {
                if (!rules.isOrigin(o)) return util.usageFail(ctx, usage, "--origin must be user or agent", .{});
                try params.str("origin", o);
            }
            return mutate(ctx, "workspace.todo.add", &params);
        },
        .check, .uncheck, .start => {
            if (try itemId(ctx, &params, args[0])) |code| return code;
            try params.str("state", switch (sub) {
                .check => "completed",
                .uncheck => "pending",
                else => "in-progress",
            });
            return mutate(ctx, "workspace.todo.set_state", &params);
        },
        .edit => {
            const text = rules.trimText(args[1]) orelse return util.usageFail(ctx, usage, "todo edit: text must be UTF-8", .{});
            if (text.len == 0) return util.usageFail(ctx, usage, "todo edit requires non-empty text", .{});
            if (try itemId(ctx, &params, args[0])) |code| return code;
            try params.str("text", text);
            return mutate(ctx, "workspace.todo.edit", &params);
        },
        .rm => {
            if (try itemId(ctx, &params, args[0])) |code| return code;
            return mutate(ctx, "workspace.todo.remove", &params);
        },
        .move => {
            const to = rules.parseTarget(args[1]);
            if (to == null or to.? != .index) return util.usageFail(ctx, usage, "todo move: invalid position '{s}' (expected a 1-based index)", .{args[1]});
            if (try itemId(ctx, &params, args[0])) |code| return code;
            // 0-based storage position (ADR-2.4 index semantics).
            try params.int("index", @intCast(to.?.index - 1));
            return mutate(ctx, "workspace.todo.move", &params);
        },
        .clear => return mutate(ctx, "workspace.todo.clear", &params),
        .open => return util.callSimple(ctx, "workspace.todo.open", &params, "OK"),
        .set => {
            const text = if (args.len == 1) args[0] else ctx.platform.readStdin(ctx.arena, rules.max_input_bytes) catch |err| switch (err) {
                error.TooLarge => return util.usageFail(ctx, usage, "todo set input is too large", .{}),
                error.ReadFailed => return ctx.runtimeError("cannot read todo items from stdin", .{}),
                error.OutOfMemory => return error.OutOfMemory,
            };
            var check: rules.SetCheck = .{};
            rules.checkSet(ctx.arena, text, &check) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try ctx.err.print("{s}: ", .{ctx.brand.name()});
                try rules.writeSetError(ctx.err, err, check);
                try ctx.err.writeByte('\n');
                return output.exit.usage;
            };
            var arr = std.json.Array.init(ctx.arena);
            try arr.appendSlice(check.items);
            try params.put("items", .{ .array = arr });
            return mutate(ctx, "workspace.todo.set", &params);
        },
    }
}

fn missingText(sub: Sub) []const u8 {
    return switch (sub) {
        .add => "missing text. Usage: cmux todo add \"text\" [--state <pending|in-progress|completed>] [--origin <user|agent>]",
        .edit => "missing item or text. Usage: cmux todo edit <index|id> \"text\"",
        .move => "missing item or position. Usage: cmux todo move <index|id> <new-index>",
        else => "missing item. Expected an item UUID or a 1-based index from `cmux todo list`",
    };
}

/// Adds `item_id` for `raw` to `params`; returns an exit code on failure.
fn itemId(ctx: *Ctx, params: *util.Params, raw: []const u8) !?u8 {
    const t = rules.parseTarget(raw) orelse {
        try ctx.err.print("{s}: ", .{ctx.brand.name()});
        try rules.writeInvalidTarget(ctx.err, raw);
        try ctx.err.writeByte('\n');
        return output.exit.usage;
    };
    switch (t) {
        .id => |id| try params.str("item_id", id),
        .index => |n| {
            var lp = util.Params.init(ctx.arena);
            try lp.optStr("window_id", util.fieldStr(.{ .object = params.obj }, "window_id"));
            try lp.optStr("workspace_id", util.fieldStr(.{ .object = params.obj }, "workspace_id"));
            const r = (try util.call(ctx, "workspace.todo.list", &lp)) orelse return output.exit.runtime;
            const id = rules.idAt(rules.itemsOf(r) orelse &.{}, n) orelse {
                try ctx.err.print("{s}: ", .{ctx.brand.name()});
                try rules.writeInvalidTarget(ctx.err, raw);
                try ctx.err.writeByte('\n');
                return output.exit.runtime;
            };
            try params.str("item_id", id);
        },
    }
    return null;
}

/// Sends a mutation and prints `OK (<c>/<t> completed)` from the returned
/// list payload (or the payload itself with --json).
fn mutate(ctx: *Ctx, method: []const u8, params: *const util.Params) !u8 {
    const r = (try util.call(ctx, method, params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    if (rules.itemsOf(r)) |items| {
        const p = rules.progressOf(items);
        try ctx.out.print("OK ({d}/{d} completed)\n", .{ p.completed, p.total });
    } else try ctx.out.writeAll("OK\n");
    return output.exit.ok;
}
