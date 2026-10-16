//! `cmux themes [list|set|clear]` (persistence-themes-cli): list the
//! available Ghostty themes (bundled under INSTALL\share\ghostty\themes,
//! the user's Ghostty themes directories and CONFIG\themes) with the current
//! light/dark choice; `set` writes `theme = light:X,dark:Y` into the wmux
//! Ghostty overlay (CONFIG\config.ghostty) and `clear` removes it, then a
//! reload is requested when wmux is running. Works without the app. The
//! interactive TTY picker is not available yet: bare `themes` lists.

const std = @import("std");
const proto = @import("wmux_proto");
const paths = proto.paths;
const command = @import("../../command.zig");
const CommandSpec = command.CommandSpec;
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const discovery = @import("../../discovery.zig");
const util = @import("../cli_misc/util.zig");
const files = @import("files.zig");

pub const usage = "Usage: cmux themes [list|set <name>|clear]";

pub const spec: CommandSpec = .{ .name = "themes", .group = .customize, .usage = usage, .help = @embedFile("../../help/themes.txt"), .socket = .none, .run = run };

pub const known_flags_message = "Known flags: --light <theme>, --dark <theme>";

/// The `theme = ...` value: one name for both appearances, or
/// `light:X,dark:Y` (either order, either half optional).
pub const Choice = struct {
    raw: ?[]const u8 = null,
    light: ?[]const u8 = null,
    dark: ?[]const u8 = null,
};

pub fn parseChoice(value: []const u8) Choice {
    const v = std.mem.trim(u8, value, " \t\"");
    var c: Choice = .{ .raw = v };
    if (std.mem.indexOf(u8, v, "light:") == null and std.mem.indexOf(u8, v, "dark:") == null) {
        if (v.len > 0) {
            c.light = v;
            c.dark = v;
        }
        return c;
    }
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, p, "light:")) c.light = std.mem.trim(u8, p["light:".len..], " \t");
        if (std.mem.startsWith(u8, p, "dark:")) c.dark = std.mem.trim(u8, p["dark:".len..], " \t");
    }
    return c;
}

/// Key of a Ghostty `key = value` line, or null for comments and blanks.
fn lineKey(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    return std.mem.trim(u8, t[0..eq], " \t");
}

/// The last `theme = ...` of a Ghostty config text.
pub fn themeOf(text: []const u8) ?Choice {
    var out: ?Choice = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const key = lineKey(line) orelse continue;
        if (!std.mem.eql(u8, key, "theme")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=').?;
        out = parseChoice(std.mem.trim(u8, line[eq + 1 ..], " \t\r"));
    }
    return out;
}

/// `text` without its `theme` lines, with `replacement` (a full line, or
/// null) where the first one was, else appended. Keeps the line endings.
pub fn rewriteTheme(arena: std.mem.Allocator, text: []const u8, replacement: ?[]const u8) ![]const u8 {
    const crlf = std.mem.indexOf(u8, text, "\r\n") != null;
    const nl: []const u8 = if (crlf) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    var placed = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    var lines: std.ArrayList([]const u8) = .empty;
    while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));
    // A trailing newline yields one empty last element.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    for (lines.items) |line| {
        if (lineKey(line)) |k| if (std.mem.eql(u8, k, "theme")) {
            if (!placed) if (replacement) |r| {
                if (!first) try out.appendSlice(arena, nl);
                try out.appendSlice(arena, r);
                first = false;
            };
            placed = true;
            continue;
        };
        if (!first) try out.appendSlice(arena, nl);
        try out.appendSlice(arena, line);
        first = false;
    }
    if (!placed) if (replacement) |r| {
        if (!first) try out.appendSlice(arena, nl);
        try out.appendSlice(arena, r);
        first = false;
    };
    if (!first) try out.appendSlice(arena, nl);
    return out.items;
}

const ThemeState = struct {
    overlay: ?[]const u8,
    current: Choice,
    source: ?[]const u8,
    names: []const []const u8,
};

/// Theme directories, highest priority first.
fn themeDirs(ctx: *Ctx) ![]const []const u8 {
    const style = paths.Style.native;
    var dirs: std.ArrayList([]const u8) = .empty;
    if (try paths.configDir(ctx.arena, ctx.env, style)) |d| try dirs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ d, "themes" }));
    if (ctx.env.getNonEmpty(proto.env_names.XDG_CONFIG_HOME)) |x| try dirs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ x, "ghostty", "themes" }));
    const home = if (style == .windows) ctx.env.getNonEmpty(proto.env_names.USERPROFILE) else ctx.env.getNonEmpty(proto.env_names.HOME);
    if (home) |h| try dirs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ h, ".config", "ghostty", "themes" }));
    if (try paths.legacyGhosttyDir(ctx.arena, ctx.env, style)) |g| try dirs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ g, "themes" }));
    if (ctx.platform.selfExePath(ctx.arena)) |exe| if (paths.installFromCliExe(style, exe)) |install| {
        try dirs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ try paths.shareDir(ctx.arena, style, install), "ghostty", "themes" }));
    };
    return dirs.items;
}

/// Sorted theme names; the first directory wins on a case-insensitive clash.
fn themeNames(ctx: *Ctx) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (try themeDirs(ctx)) |d| {
        const entries = util.fs.listDir(ctx.arena, d) orelse continue;
        outer: for (entries) |e| {
            if (e.len == 0 or e[0] == '.') continue;
            for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, e)) continue :outer;
            try names.append(ctx.arena, e);
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lt);
    return names.items;
}

/// Ghostty config files the user's theme may come from (after the overlay).
fn ghosttyConfigs(ctx: *Ctx) ![]const []const u8 {
    const style = paths.Style.native;
    var cfgs: std.ArrayList([]const u8) = .empty;
    if (ctx.env.getNonEmpty(proto.env_names.XDG_CONFIG_HOME)) |x| {
        try cfgs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ x, "ghostty", "config" }));
        try cfgs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ x, "ghostty", "config.ghostty" }));
    }
    if (try paths.legacyGhosttyDir(ctx.arena, ctx.env, style)) |g| {
        try cfgs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ g, "config" }));
        try cfgs.append(ctx.arena, try paths.join(ctx.arena, style, &.{ g, "config.ghostty" }));
    }
    return cfgs.items;
}

fn state(ctx: *Ctx) !ThemeState {
    const style = paths.Style.native;
    const cfg = try paths.configDir(ctx.arena, ctx.env, style);
    const overlay = if (cfg) |d| try paths.join(ctx.arena, style, &.{ d, paths.files.ghostty_overlay }) else null;
    var s: ThemeState = .{ .overlay = overlay, .current = .{}, .source = null, .names = try themeNames(ctx) };
    if (overlay) |o| if (files.read(ctx, o)) |text| if (themeOf(text)) |c| {
        s.current = c;
        s.source = o;
        return s;
    };
    for (try ghosttyConfigs(ctx)) |g| if (files.read(ctx, g)) |text| if (themeOf(text)) |c| {
        s.current = c;
        s.source = g;
    };
    return s;
}

fn run(ctx: *Ctx) !u8 {
    const a = ctx.args();
    if (a.len == 0 or std.mem.eql(u8, a[0], "list")) {
        const rest = if (a.len == 0) a else a[1..];
        if (rest.len > 0) return util.usageFail(ctx, usage, "themes list: unexpected argument '{s}'", .{rest[0]});
        return list(ctx);
    }
    if (std.mem.eql(u8, a[0], "set")) return set(ctx, a[1..]);
    if (std.mem.eql(u8, a[0], "clear")) {
        if (a.len > 1) return util.usageFail(ctx, usage, "themes clear: unexpected argument '{s}'", .{a[1]});
        return clear(ctx);
    }
    return util.usageFail(ctx, usage, "unknown themes subcommand '{s}'", .{a[0]});
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.ascii.eqlIgnoreCase(x, b) else false;
}

fn list(ctx: *Ctx) !u8 {
    const s = try state(ctx);
    if (ctx.json()) {
        var j: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
        try j.beginObject();
        try j.objectField("themes");
        try j.beginArray();
        for (s.names) |n| try j.write(.{ .name = n, .current_light = eqlOpt(s.current.light, n), .current_dark = eqlOpt(s.current.dark, n) });
        try j.endArray();
        try j.objectField("current");
        try j.write(.{ .raw_value = s.current.raw, .light = s.current.light, .dark = s.current.dark, .source_path = s.source });
        try j.objectField("config_path");
        try j.write(s.overlay);
        try j.endObject();
        try ctx.out.writeByte('\n');
        return output.exit.ok;
    }
    const w = ctx.out;
    try w.print("Current light: {s}\n", .{s.current.light orelse "inherit"});
    try w.print("Current dark: {s}\n", .{s.current.dark orelse "inherit"});
    try w.print("Config: {s}\n", .{s.overlay orelse "(no config directory)"});
    if (s.source) |src| try w.print("Source: {s}\n", .{src});
    if (s.names.len == 0) try w.writeAll("No themes found.\n");
    for (s.names) |n| {
        try w.writeAll(n);
        if (eqlOpt(s.current.light, n)) try w.writeAll(" [light]");
        if (eqlOpt(s.current.dark, n)) try w.writeAll(" [dark]");
        try w.writeByte('\n');
    }
    return output.exit.ok;
}

const set_flags = [_]util.FlagSpec{
    .{ .name = "--light", .value = true },
    .{ .name = "--dark", .value = true },
};

/// The available name matching `want` case-insensitively.
fn canonical(names: []const []const u8, want: []const u8) ?[]const u8 {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, want)) return n;
    return null;
}

fn set(ctx: *Ctx, args: []const []const u8) !u8 {
    var diag: util.FlagDiag = .{};
    const flags = util.parseFlags(ctx.arena, args, &set_flags, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownFlag => return ctx.usageError("themes set: unknown flag '{s}'. {s}", .{ diag.token, known_flags_message }),
        error.MissingValue => return ctx.usageError("themes set: {s} requires a theme. {s}", .{ diag.token, known_flags_message }),
    };
    var pos: std.ArrayList([]const u8) = .empty;
    try pos.appendSlice(ctx.arena, flags.positionals);
    if (flags.payload) |p| try pos.appendSlice(ctx.arena, p);
    // Theme names may contain spaces when passed unquoted.
    const both: ?[]const u8 = if (pos.items.len > 0) try std.mem.join(ctx.arena, " ", pos.items) else null;
    const want_light = flags.get("--light") orelse both;
    const want_dark = flags.get("--dark") orelse both;
    if (want_light == null and want_dark == null) return util.usageFail(ctx, usage, "themes set requires a theme name (or --light <theme> and/or --dark <theme>)", .{});
    const s = try state(ctx);
    const overlay = s.overlay orelse return ctx.runtimeError("themes set: no config directory (set USERPROFILE, XDG_CONFIG_HOME or WMUX_CONFIG_DIR)", .{});
    var light: ?[]const u8 = null;
    var dark: ?[]const u8 = null;
    if (want_light) |l| light = canonical(s.names, l) orelse return ctx.runtimeError("themes set: unknown theme '{s}'; run 'cmux themes list'", .{l});
    if (want_dark) |d| dark = canonical(s.names, d) orelse return ctx.runtimeError("themes set: unknown theme '{s}'; run 'cmux themes list'", .{d});
    // Keep the other half: the current choice, else the half being set.
    light = light orelse s.current.light orelse dark;
    dark = dark orelse s.current.dark orelse light;
    const raw = try std.fmt.allocPrint(ctx.arena, "light:{s},dark:{s}", .{ light.?, dark.? });
    const line = try std.fmt.allocPrint(ctx.arena, "theme = {s}", .{raw});
    const old = files.read(ctx, overlay) orelse "";
    const text = try rewriteTheme(ctx.arena, old, line);
    if (!std.mem.eql(u8, text, old)) files.writeFile(overlay, ctx.arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return ctx.runtimeError("themes set: cannot write {s}", .{overlay}),
    };
    const reload = try requestReload(ctx);
    if (ctx.json()) {
        var j: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
        try j.write(.{ .ok = true, .light = light.?, .dark = dark.?, .raw_value = raw, .config_path = overlay, .reload_requested = reload == .requested, .reload_target_bundle_id = @as(?[]const u8, null) });
        try ctx.out.writeByte('\n');
    } else try ctx.out.print("OK light={s} dark={s} config={s} reload={s}\n", .{ light.?, dark.?, overlay, @tagName(reload) });
    return output.exit.ok;
}

fn clear(ctx: *Ctx) !u8 {
    const style = paths.Style.native;
    const cfg = (try paths.configDir(ctx.arena, ctx.env, style)) orelse return ctx.runtimeError("themes clear: no config directory (set USERPROFILE, XDG_CONFIG_HOME or WMUX_CONFIG_DIR)", .{});
    const overlay = try paths.join(ctx.arena, style, &.{ cfg, paths.files.ghostty_overlay });
    if (files.read(ctx, overlay)) |old| {
        const text = try rewriteTheme(ctx.arena, old, null);
        if (!std.mem.eql(u8, text, old)) files.writeFile(overlay, ctx.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return ctx.runtimeError("themes clear: cannot write {s}", .{overlay}),
        };
    }
    const reload = try requestReload(ctx);
    if (ctx.json()) {
        var j: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
        try j.write(.{ .ok = true, .cleared = true, .config_path = overlay, .reload_requested = reload == .requested });
        try ctx.out.writeByte('\n');
    } else try ctx.out.print("OK cleared config={s} reload={s}\n", .{ overlay, @tagName(reload) });
    return output.exit.ok;
}

const Reload = enum { requested, skipped, failed };

/// `wmux.config.reload` when an app is running; never starts one and never
/// prints discovery errors.
fn requestReload(ctx: *Ctx) !Reload {
    const in = try ctx.discoveryInputs();
    switch (try discovery.resolve(ctx.arena, ctx.platform, in)) {
        .none, .rejected => return .skipped,
        .live => |l| l.transport.close(),
        .explicit => {},
    }
    const out = (try ctx.call("wmux.config.reload", null)) orelse return .failed;
    return if (out == .ok) .requested else .failed;
}
