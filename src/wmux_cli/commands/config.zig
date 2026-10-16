//! CLI command family `config` (Appendix C).
//! config <sub>, reload-config, themes, settings path|docs (W1-4);
//! settings [open] [target], shortcuts (W4-4); import (W7). This WP
//! (cf-cli-misc) adds `config`, `reload-config`, `themes`, `settings` and
//! `shortcuts` (config/*.zig); `import` stays with W7.
//!
//! `config` works offline except `config reload` (`wmux.config.reload`):
//! doctor|check|validate, path|paths, docs|documentation, get, set, unset,
//! toggle, cycle, preset and the font-size shorthands read and write the
//! JSON files directly with wmux_proto/settings and json_edit.

const std = @import("std");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const docs = @import("../docs.zig");
const util = @import("cli_misc/util.zig");
const doctor = @import("config/doctor.zig");
const edit = @import("config/edit.zig");
const settings_cmd = @import("config/settings_cmd.zig");
const themes = @import("config/themes.zig");

pub const usage = "Usage: cmux config <doctor|check|validate|path|paths|docs|documentation|reload|get|set|unset|toggle|cycle|preset|sidebar-font-size|surface-tab-bar-font-size>";

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "config", .group = .customize, .usage = usage, .help = @embedFile("../help/config.txt"), .socket = .none, .run = run },
    .{ .name = "reload-config", .group = .customize, .usage = "Usage: cmux reload-config", .help = @embedFile("../help/reload-config.txt"), .run = runReloadConfig },
    themes.spec,
    settings_cmd.settings_spec,
    settings_cmd.shortcuts_spec,
};

fn run(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0) return util.usageFail(ctx, usage, "config requires a subcommand", .{});
    const sub = a[0];
    const rest = a[1..];
    const eql = std.mem.eql;
    if (eql(u8, sub, "doctor") or eql(u8, sub, "check") or eql(u8, sub, "validate")) return doctor.run(ctx, rest);
    if (eql(u8, sub, "path") or eql(u8, sub, "paths") or eql(u8, sub, "docs") or eql(u8, sub, "documentation")) {
        if (rest.len > 0) return util.usageFail(ctx, usage, "config {s}: unexpected argument '{s}'", .{ sub, rest[0] });
        return writeSettingsDocs(ctx);
    }
    if (eql(u8, sub, "reload")) {
        if (rest.len > 0) return util.usageFail(ctx, usage, "config reload: unexpected argument '{s}'", .{rest[0]});
        return reload(ctx);
    }
    if (eql(u8, sub, "get")) return edit.runGet(ctx, rest);
    if (eql(u8, sub, "set")) return edit.runSet(ctx, rest);
    if (eql(u8, sub, "unset")) return edit.runUnset(ctx, rest);
    if (eql(u8, sub, "toggle")) return edit.runToggle(ctx, rest);
    if (eql(u8, sub, "cycle")) return edit.runCycle(ctx, rest);
    if (eql(u8, sub, "preset")) return edit.runPreset(ctx, rest);
    if (eql(u8, sub, "sidebar-font-size") or eql(u8, sub, "surface-tab-bar-font-size")) return edit.runShorthand(ctx, sub, rest);
    return util.usageFail(ctx, usage, "unknown config subcommand '{s}'", .{sub});
}

/// `config path|docs`, `settings path|docs`: the `docs settings` text
/// (`Config files:` ...) or its JSON.
pub fn writeSettingsDocs(ctx: *Ctx) !u8 {
    const topic = docs.find("settings").?;
    const loc = try docs.Locations.resolve(ctx.arena, ctx.env, ctx.platform.selfExePath(ctx.arena));
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    if (ctx.json()) try docs.writeTopicJson(ctx.arena, &aw.writer, topic, loc) else try docs.writeTopic(ctx.arena, &aw.writer, topic, loc);
    try ctx.print(aw.written());
    return output.exit.ok;
}

/// `wmux.config.reload` (reloads wmux.json and the Ghostty config and emits
/// `config.reloaded`).
fn reload(ctx: *Ctx) !u8 {
    return util.callSimple(ctx, "wmux.config.reload", null, "OK");
}

fn runReloadConfig(ctx: *Ctx) !u8 {
    if (ctx.args().len > 0) return util.usageFail(ctx, "Usage: cmux reload-config", "reload-config: unexpected argument '{s}'", .{ctx.args()[0]});
    return reload(ctx);
}

test {
    _ = doctor;
    _ = edit;
    _ = settings_cmd;
    _ = themes;
    _ = @import("config/tests.zig");
}
