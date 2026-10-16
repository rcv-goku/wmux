//! `cmux layout <save|list|get|open|delete>`: saved workspace layouts
//! (core-saved-layouts) over `layout.{save,list,get,open,delete}`. Output
//! and limits follow the merged store model in
//! src/apprt/win32/features/layouts/logic/store.zig: 'OK layout=<name>
//! unsupported=<n>', the NAME/PANES/SURFACES/DESCRIPTION table, 'No saved
//! layouts', 'OK deleted=true'; errors duplicateName, notFound and
//! corruptFile come from the app.

const std = @import("std");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");

pub const usage = "Usage: cmux layout <save|list|get|open|delete> [args]";

pub const spec: CommandSpec = .{ .name = "layout", .group = .automation, .usage = usage, .help = @embedFile("../../help/layout.txt"), .run = run };

/// Store limits (layouts/logic/store.zig).
pub const max_name_bytes: usize = 256;
pub const max_description_bytes: usize = 4096;
pub const no_layouts_text = "No saved layouts";
pub const table_header = "NAME\tPANES\tSURFACES\tDESCRIPTION";

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--workspace", .value = true },
    .{ .name = "--window", .value = true },
    .{ .name = "--overwrite" },
    .{ .name = "--description", .value = true },
    .{ .name = "--cwd", .value = true },
    .{ .name = "--focus", .value = true },
};

const Sub = enum { save, list, get, open, delete };

/// Flags each subcommand accepts besides --window.
fn allowed(sub: Sub, flag: []const u8) bool {
    if (std.mem.eql(u8, flag, "--window")) return true;
    return switch (sub) {
        .save => std.mem.eql(u8, flag, "--workspace") or std.mem.eql(u8, flag, "--overwrite") or std.mem.eql(u8, flag, "--description"),
        .open => std.mem.eql(u8, flag, "--cwd") or std.mem.eql(u8, flag, "--focus"),
        .list, .get, .delete => false,
    };
}

fn run(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "layout", usage, ctx.args(), &flag_specs)) orelse return output.exit.usage;
    var pos: std.ArrayList([]const u8) = .empty;
    try pos.appendSlice(ctx.arena, flags.positionals);
    if (flags.payload) |p| try pos.appendSlice(ctx.arena, p);
    if (pos.items.len == 0) return util.usageFail(ctx, usage, "layout requires a subcommand", .{});
    const name_word = pos.items[0];
    const sub = std.meta.stringToEnum(Sub, name_word) orelse return util.usageFail(ctx, usage, "unknown layout subcommand '{s}'", .{name_word});
    for (flags.hits) |hit| {
        if (!allowed(sub, hit.name)) return util.usageFail(ctx, usage, "layout {s}: {s} is not valid here", .{ name_word, hit.name });
    }
    const args = pos.items[1..];
    const want: usize = if (sub == .list) 0 else 1;
    if (args.len < want) return util.usageFail(ctx, usage, "layout {s} requires a name", .{name_word});
    if (args.len > want) return util.usageFail(ctx, usage, "layout {s}: unexpected argument '{s}'", .{ name_word, args[want] });

    var params = util.Params.init(ctx.arena);
    var name: []const u8 = "";
    if (want == 1) {
        name = std.mem.trim(u8, args[0], " \t\r\n");
        if (name.len == 0) return util.usageFail(ctx, usage, "layout {s} requires a name", .{name_word});
        if (name.len > max_name_bytes) return util.usageFail(ctx, usage, "layout name is longer than {d} bytes", .{max_name_bytes});
        if (!std.unicode.utf8ValidateSlice(name)) return util.usageFail(ctx, usage, "layout name must be UTF-8", .{});
        try params.str("name", name);
    }
    switch (sub) {
        .save => {
            const t = util.resolveTarget(ctx, flags, .{}) orelse return output.exit.usage;
            try params.optStr("window_id", t.window);
            try params.optStr("workspace_id", t.workspace);
            try params.boolean("overwrite", flags.has("--overwrite"));
            if (flags.get("--description")) |d| {
                if (d.len > max_description_bytes) return util.usageFail(ctx, usage, "layout description is longer than {d} bytes", .{max_description_bytes});
                try params.str("description", d);
            }
            const r = (try util.call(ctx, "layout.save", &params)) orelse return output.exit.runtime;
            if (ctx.json()) return jsonOut(ctx, r);
            try ctx.out.print("OK layout={s} unsupported={d}\n", .{ util.fieldStr(r, "name") orelse name, util.fieldInt(r, "unsupported") orelse 0 });
        },
        .list => {
            const t = util.resolveTarget(ctx, flags, .{ .workspace_default = false }) orelse return output.exit.usage;
            try params.optStr("window_id", t.window);
            const r = (try util.call(ctx, "layout.list", &params)) orelse return output.exit.runtime;
            if (ctx.json()) return jsonOut(ctx, r);
            try writeTable(ctx.out, r);
        },
        .get => {
            const r = (try util.call(ctx, "layout.get", &params)) orelse return output.exit.runtime;
            try util.writeJsonResult(ctx, util.field(r, "layout") orelse r);
        },
        .open => {
            const t = util.resolveTarget(ctx, flags, .{ .workspace_default = false }) orelse return output.exit.usage;
            try params.optStr("window_id", t.window);
            if (flags.get("--cwd")) |c| try params.str("cwd", try util.resolvePath(ctx, c));
            var focus = false;
            if (flags.get("--focus")) |f| {
                if (std.mem.eql(u8, f, "true")) focus = true else if (!std.mem.eql(u8, f, "false"))
                    return util.usageFail(ctx, usage, "--focus must be true|false", .{});
            }
            try params.boolean("focus", focus);
            const r = (try util.call(ctx, "layout.open", &params)) orelse return output.exit.runtime;
            if (ctx.json()) return jsonOut(ctx, r);
            if (try util.handleText(ctx, r, "workspace")) |ws| {
                try ctx.out.print("OK workspace={s}\n", .{ws});
            } else try ctx.out.writeAll("OK\n");
        },
        .delete => {
            const r = (try util.call(ctx, "layout.delete", &params)) orelse return output.exit.runtime;
            if (ctx.json()) return jsonOut(ctx, r);
            const deleted = if (util.field(r, "deleted")) |d| !(d == .bool and !d.bool) else true;
            try ctx.out.print("OK deleted={}\n", .{deleted});
        },
    }
    return output.exit.ok;
}

fn jsonOut(ctx: *Ctx, r: std.json.Value) !u8 {
    try util.writeJsonResult(ctx, r);
    return output.exit.ok;
}

/// `layout list` text from `{layouts: [{name, panes, surfaces, description?}]}`.
pub fn writeTable(w: *std.Io.Writer, r: std.json.Value) !void {
    const list = util.field(r, "layouts") orelse return w.print("{s}\n", .{no_layouts_text});
    if (list != .array or list.array.items.len == 0) return w.print("{s}\n", .{no_layouts_text});
    try w.print("{s}\n", .{table_header});
    for (list.array.items) |l| {
        try writeCell(w, util.fieldStr(l, "name") orelse "");
        try w.print("\t{d}\t{d}\t", .{ util.fieldInt(l, "panes") orelse 0, util.fieldInt(l, "surfaces") orelse 0 });
        try writeCell(w, util.fieldStr(l, "description") orelse "");
        try w.writeByte('\n');
    }
}

/// Table cells turn tabs and line breaks into spaces so rows stay parseable.
fn writeCell(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| try w.writeByte(switch (c) {
        '\t', '\r', '\n' => ' ',
        else => c,
    });
}
