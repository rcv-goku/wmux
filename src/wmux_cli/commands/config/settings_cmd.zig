//! `cmux settings [open [target]|path|docs|<target>]` and `cmux shortcuts`
//! (cli-settings-command, cli-shortcuts-command). `path` and `docs` print
//! the config locations offline; every other form opens the Settings window
//! (`settings.open {target?, activate}`), starting wmux when needed.

const std = @import("std");
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");
const config = @import("../config.zig");

pub const settings_usage = "Usage: cmux settings [open [target]|path|docs|<target>]";
pub const shortcuts_usage = "Usage: cmux shortcuts";

pub const settings_spec: CommandSpec = .{ .name = "settings", .group = .customize, .usage = settings_usage, .help = @embedFile("../../help/settings.txt"), .socket = .launch_if_needed, .run = runSettings };
pub const shortcuts_spec: CommandSpec = .{ .name = "shortcuts", .group = .customize, .usage = shortcuts_usage, .help = @embedFile("../../help/shortcuts.txt"), .socket = .launch_if_needed, .run = runShortcuts };

/// cmux Settings targets (`shortcuts` and `json` are aliases).
pub const targets = [_][]const u8{
    "account",          "app",            "themes",             "terminal",           "networking",
    "computers",        "devices",        "sidebar-appearance", "custom-sidebars",    "automation",
    "browser",          "browser-import", "global-hotkey",      "keyboard-shortcuts", "shortcuts",
    "workspace-colors", "cmux-json",      "json",               "reset",
};

/// The canonical target for `name`, or null when unknown.
pub fn canonicalTarget(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "shortcuts")) return "keyboard-shortcuts";
    if (std.mem.eql(u8, name, "json")) return "cmux-json";
    for (targets) |t| if (std.mem.eql(u8, t, name)) return t;
    return null;
}

fn runSettings(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len > 0 and (std.mem.eql(u8, a[0], "path") or std.mem.eql(u8, a[0], "docs"))) {
        if (a.len > 1) return util.usageFail(ctx, settings_usage, "settings {s}: unexpected argument '{s}'", .{ a[0], a[1] });
        return config.writeSettingsDocs(ctx);
    }
    var rest = a;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "open")) rest = rest[1..];
    if (rest.len > 1) return util.usageFail(ctx, settings_usage, "settings: unexpected argument '{s}'", .{rest[1]});
    var target: ?[]const u8 = null;
    if (rest.len == 1) {
        if (rest[0].len > 0 and rest[0][0] == '-') return util.usageFail(ctx, settings_usage, "settings: unknown flag '{s}'", .{rest[0]});
        target = canonicalTarget(rest[0]) orelse return util.usageFail(ctx, settings_usage, "unknown settings target '{s}' (expected one of: {s})", .{ rest[0], try std.mem.join(ctx.arena, ", ", &targets) });
    }
    return open(ctx, target);
}

fn runShortcuts(ctx: *Ctx) !u8 {
    if (ctx.args().len > 0) return util.usageFail(ctx, shortcuts_usage, "shortcuts: unexpected argument '{s}'", .{ctx.args()[0]});
    return open(ctx, "keyboard-shortcuts");
}

/// Opening Settings is an explicit UI request, so it activates the window.
fn open(ctx: *Ctx, target: ?[]const u8) !u8 {
    var params = util.Params.init(ctx.arena);
    try params.optStr("target", target);
    try params.boolean("activate", true);
    return util.callSimple(ctx, "settings.open", &params, "OK");
}
