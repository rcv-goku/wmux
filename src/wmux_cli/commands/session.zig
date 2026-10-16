//! CLI command family `session` (Appendix C).
//! restore-session [--from <channel|path>] [--export <path> [--force]].
//! Owner: W1-7 (import/export: W4-7); CLI: cf-cli-misc. Also hosts the
//! surface resume binding verbs `surface-resume <show|get|set|clear>` (also
//! spelled `surface resume ...`), see surface_resume.zig.
//!
//! - `restore-session` alone reopens the previous session
//!   (`session.restore_previous`), starting wmux when needed.
//! - `--from` imports another install's session (a channel name or bundle
//!   id: full trust) or an exported file (untrusted) as additional windows
//!   (`session.import {source|path}`); `--export <path> [--force]` writes this
//!   install's session (`session.export {path, force}`). Both need a running
//!   app and never start one, so they cannot race startup restore.

const std = @import("std");
const proto = @import("wmux_proto");
const command = @import("../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../output.zig");
const discovery = @import("../discovery.zig");
const brand_mod = @import("../brand.zig");
const util = @import("cli_misc/util.zig");
const surface_resume = @import("session/surface_resume.zig");

pub const restore_usage = "Usage: cmux restore-session [--from <channel|path>] [--export <path> [--force]]";

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{
    .{ .name = "restore-session", .group = .start, .usage = restore_usage, .help = @embedFile("../help/restore-session.txt"), .socket = .launch_if_needed, .run = runRestore },
    surface_resume.spec,
};

pub const not_running_message = "restore-session: cmux is not running. Open cmux, then run this command again.";

/// cmux channel names accepted by `--from` (`debug:<tag>`, `dev:<tag>` and
/// bundle ids `com.cmuxterm.app...` are recognized by shape).
pub const channel_sources = [_][]const u8{ "stable", "release", "nightly", "rc", "staging", "debug" };

pub const FromKind = enum { source, path };

/// `--from` resolution (cmux rule): a value with a path separator, a
/// leading `~` or `.`, or a `.json` suffix is a file; a channel name or
/// bundle id is a source (and wins over a same-named file: use `./nightly`);
/// any other bare name is a file when it exists, otherwise a source.
pub fn classifyFrom(value: []const u8, exists: bool) FromKind {
    if (std.mem.indexOfAny(u8, value, "/\\") != null) return .path;
    if (value.len > 0 and (value[0] == '~' or value[0] == '.')) return .path;
    if (std.ascii.endsWithIgnoreCase(value, ".json")) return .path;
    if (isSourceName(value)) return .source;
    return if (exists) .path else .source;
}

pub fn isSourceName(value: []const u8) bool {
    for (channel_sources) |c| if (std.mem.eql(u8, c, value)) return true;
    for ([_][]const u8{ "debug:", "dev:" }) |prefix| {
        if (std.mem.startsWith(u8, value, prefix) and value.len > prefix.len) return true;
    }
    return std.mem.startsWith(u8, value, "com.cmuxterm.app");
}

const restore_flags = [_]util.FlagSpec{
    .{ .name = "--from", .value = true },
    .{ .name = "--export", .value = true },
    .{ .name = "--force" },
};

fn runRestore(ctx: *Ctx) !u8 {
    const flags = (try util.flagsOrFail(ctx, "restore-session", restore_usage, ctx.args(), &restore_flags)) orelse return output.exit.usage;
    if (flags.positionals.len > 0) return util.usageFail(ctx, restore_usage, "restore-session: unexpected argument '{s}'", .{flags.positionals[0]});
    const from = flags.get("--from");
    const export_path = flags.get("--export");
    if (from != null and export_path != null) return util.usageFail(ctx, restore_usage, "restore-session: --from and --export cannot be combined", .{});
    if (flags.has("--force") and export_path == null) return util.usageFail(ctx, restore_usage, "restore-session: --force requires --export <path>", .{});
    if (from) |f| if (std.mem.trim(u8, f, " \t").len == 0) return util.usageFail(ctx, restore_usage, "restore-session: --from requires a value", .{});
    if (export_path) |e| if (std.mem.trim(u8, e, " \t").len == 0) return util.usageFail(ctx, restore_usage, "restore-session: --export requires a value", .{});

    if (from == null and export_path == null) {
        var params = util.Params.init(ctx.arena);
        return util.callSimple(ctx, "session.restore_previous", &params, "OK");
    }

    // Import/export never start the app (cmux rule).
    ctx.socket = .required;
    if (!try appRunning(ctx)) {
        try brand_mod.write(ctx.err, ctx.brand, not_running_message);
        try ctx.err.writeByte('\n');
        return output.exit.runtime;
    }
    var params = util.Params.init(ctx.arena);
    var method: []const u8 = undefined;
    var shown: []const u8 = undefined;
    if (from) |f| {
        method = "session.import";
        const resolved = try util.resolvePath(ctx, f);
        switch (classifyFrom(f, ctx.platform.pathExists(resolved))) {
            .source => {
                try params.str("source", f);
                shown = f;
            },
            .path => {
                try params.str("path", resolved);
                shown = resolved;
            },
        }
    } else {
        method = "session.export";
        shown = try util.resolvePath(ctx, export_path.?);
        try params.str("path", shown);
        try params.boolean("force", flags.has("--force"));
    }
    const r = (try util.call(ctx, method, &params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try util.writeJsonResult(ctx, r);
        return output.exit.ok;
    }
    try ctx.out.print("OK {s}\n", .{util.fieldStr(r, "path") orelse shown});
    if (util.fieldInt(r, "held_back_resume_count")) |n| if (n > 0) {
        try ctx.out.print("Held back automatic resume in {d} terminal(s) from this file. Review their commands and resume them manually.\n", .{n});
    };
    if (util.fieldInt(r, "dropped_remote_workspace_count")) |n| if (n > 0) {
        try ctx.out.print("Opened {d} workspace(s) without the file's SSH/cloud connection and environment variables.\n", .{n});
    };
    return output.exit.ok;
}

/// True when discovery finds a live (or explicitly named) control pipe.
fn appRunning(ctx: *Ctx) !bool {
    const in = try ctx.discoveryInputs();
    switch (try discovery.resolve(ctx.arena, ctx.platform, in)) {
        .none => return false,
        .live => |l| {
            l.transport.close();
            return true;
        },
        .explicit, .rejected => return true,
    }
}

test {
    _ = surface_resume;
    _ = @import("session/tests.zig");
}
