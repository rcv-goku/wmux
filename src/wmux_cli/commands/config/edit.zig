//! `config get|set|unset|toggle|cycle|preset` and the font-size shorthands
//! (persistence-config-get-set-mutations): one mutation path over the
//! lossless JSONC editor (`wmux_proto.json_edit`). Every write validates the
//! whole result first and refuses only errors the edit introduced; comments,
//! key order and unrelated keys survive. Writes target wmux.json (or the
//! shared cmux.json with `--file cmux`); the running app picks the change up
//! through its file watcher. Offline.

const std = @import("std");
const proto = @import("wmux_proto");
const settings = proto.settings;
const resolve = settings.resolve;
const jsonc = proto.jsonc;
const json_edit = proto.json_edit;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const util = @import("../cli_misc/util.zig");
const files = @import("files.zig");

pub const Edit = struct {
    path: []const u8,
    /// Minified JSON; null removes the key.
    value: ?[]const u8,
};

const file_flags = [_]util.FlagSpec{.{ .name = "--file", .value = true }};

/// Checks a setting path for get/set; prints the error (exit 2) or returns
/// the expanded path.
fn settingPath(ctx: *Ctx, verb: []const u8, raw: []const u8) ?[]const u8 {
    const path = resolve.expandShorthand(raw);
    const problem = resolve.settingPathProblem(files.specs, path) orelse return path;
    const hint = " (paths split on every '.', so keys that contain '.' cannot be addressed here; edit the file instead)";
    if (std.mem.eql(u8, problem, "unknown setting")) {
        _ = ctx.usageError("config {s}: unknown setting '{s}'" ++ hint, .{ verb, path });
    } else if (std.mem.startsWith(u8, problem, "not a valid setting path")) {
        _ = ctx.usageError("config {s}: '{s}' is not a valid setting path" ++ hint, .{ verb, path });
    } else _ = ctx.usageError("config {s}: '{s}' {s}", .{ verb, path, problem });
    return null;
}

fn parseFailed(ctx: *Ctx, verb: []const u8, f: files.ParseFailure) u8 {
    return ctx.runtimeError("config {s}: {s} does not parse ({f}); run 'cmux config doctor'", .{ verb, f.path, f.diag });
}

fn whichFile(ctx: *Ctx, flags: util.Flags, usage: []const u8) ?files.Which {
    const v = flags.get("--file") orelse return .wmux;
    if (std.mem.eql(u8, v, "wmux") or std.mem.eql(u8, v, "wmux.json")) return .wmux;
    if (std.mem.eql(u8, v, "cmux") or std.mem.eql(u8, v, "cmux.json")) return .cmux;
    _ = util.usageFail(ctx, usage, "--file must be wmux or cmux", .{});
    return null;
}

/// The effective entry of `path` (or prints why not and returns null).
fn effective(ctx: *Ctx, verb: []const u8, path: []const u8, code: *u8) !?*const resolve.Entry {
    const loc = try files.locate(ctx);
    var failure: ?files.ParseFailure = null;
    const resolved = try ctx.arena.create(resolve.Resolved);
    resolved.* = (try files.resolveAll(ctx, loc, &failure)) orelse {
        code.* = parseFailed(ctx, verb, failure.?);
        return null;
    };
    return resolved.get(path) orelse {
        code.* = ctx.usageError("config {s}: unknown setting '{s}'", .{ verb, path });
        return null;
    };
}

pub const get_usage = "Usage: cmux config get <setting.path> [--json]";

pub fn runGet(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config get", get_usage, args, &.{})) orelse return output.exit.usage;
    if (flags.positionals.len != 1) return util.usageFail(ctx, get_usage, "config get requires exactly one setting path", .{});
    const path = settingPath(ctx, "get", flags.positionals[0]) orelse return output.exit.usage;
    return printGet(ctx, path);
}

fn printGet(ctx: *Ctx, path: []const u8) !u8 {
    var code: u8 = 0;
    const e = (try effective(ctx, "get", path, &code)) orelse return code;
    const loc = try files.locate(ctx);
    const file: []const u8 = loc.wmux_json orelse "";
    if (ctx.json()) {
        var s: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("path");
        try s.write(path);
        try s.objectField("file");
        try s.write(file);
        try s.objectField("value");
        try e.value.write(&s);
        try s.objectField("configured");
        try s.write(e.configured());
        try s.objectField("source");
        try s.write(e.source.label());
        try s.objectField("default");
        try s.print("{s}", .{e.spec.default});
        try s.objectField("locked");
        try s.write(e.locked);
        try s.endObject();
        try ctx.out.writeByte('\n');
        return output.exit.ok;
    }
    try ctx.out.writeAll(e.json);
    switch (e.source) {
        .default => try ctx.out.writeAll("  (default)"),
        .wmux_json => {},
        .policy => try ctx.out.writeAll("  (managed by policy)"),
        else => try ctx.out.print("  (from {s})", .{e.source.label()}),
    }
    try ctx.out.writeByte('\n');
    return output.exit.ok;
}

/// How `mutate` changes the file.
const Mutation = union(enum) {
    /// One `json_edit` set (value) or remove (null) per edit.
    edits,
    /// One deep merge of the JSON object `patch` (`json_edit.merge`: nested
    /// objects merge key by key, cmux `settingPresets` semantics); the edits
    /// only name the settings it touches, whose values are read back
    /// afterwards. `label` names the patch in error messages.
    merge: struct { patch: []const u8, label: []const u8 },
};

/// Applies `edits` to one file in a single validated write and prints
/// `OK <path> = <json>` / `OK <path> unset` / `OK unchanged` lines plus
/// `path: <file>` (or `{ok, file, paths: [{path, changed, value?}]}`).
pub fn apply(ctx: *Ctx, verb: []const u8, which: files.Which, edits: []const Edit) !u8 {
    return mutate(ctx, verb, which, edits, .edits);
}

fn editFailed(ctx: *Ctx, verb: []const u8, file: []const u8, what: []const u8, err: json_edit.Error, diag: jsonc.Diagnostic) error{OutOfMemory}!u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError => ctx.runtimeError("config {s}: {s} does not parse ({f}); run 'cmux config doctor'", .{ verb, file, diag }),
        error.RootNotObject => ctx.runtimeError("config {s}: {s} is not a JSON object", .{ verb, file }),
        error.PathConflict => ctx.runtimeError("config {s}: '{s}' crosses a value that is not an object in {s}", .{ verb, what, file }),
        error.InvalidPath => ctx.usageError("config {s}: '{s}' is not a valid setting path", .{ verb, what }),
        error.InvalidValue => ctx.usageError("config {s}: the value for '{s}' is not a single JSON value", .{ verb, what }),
    };
}

fn mutate(ctx: *Ctx, verb: []const u8, which: files.Which, edits: []const Edit, how: Mutation) !u8 {
    const loc = try files.locate(ctx);
    const file = loc.file(which) orelse return ctx.runtimeError("config {s}: no config directory (set USERPROFILE, XDG_CONFIG_HOME or WMUX_CONFIG_DIR)", .{verb});
    // Policy-managed settings refuse writes (ADR-5.1 row 7). The lock comes
    // from the policy values alone, so a config file that does not parse
    // cannot hide it.
    const policy = try files.policyValues(ctx);
    for (edits) |e| if (resolve.policyValueFor(policy, e.path) != null) return ctx.runtimeError("config {s}: '{s}' is managed by policy and cannot be changed", .{ verb, e.path });
    const original = (files.readExisting(ctx, file) catch
        return ctx.runtimeError("config {s}: cannot read {s} (unreadable or larger than {d} MiB); it was not changed", .{ verb, file, files.max_file_bytes >> 20 })) orelse "";
    const before: []const u8 = if (std.mem.trim(u8, original, " \t\r\n").len == 0) "{}\n" else original;
    var text = before;
    const changed = try ctx.arena.alloc(bool, edits.len);
    // The value each path ends up with (null after an unset).
    const values = try ctx.arena.alloc(?[]const u8, edits.len);
    switch (how) {
        .edits => for (edits, 0..) |e, i| {
            var diag: jsonc.Diagnostic = .{};
            const r = (if (e.value) |v| json_edit.set(ctx.arena, text, e.path, v, &diag) else json_edit.remove(ctx.arena, text, e.path, &diag)) catch |err|
                return editFailed(ctx, verb, file, e.path, err, diag);
            changed[i] = r.changed;
            values[i] = e.value;
            text = r.text;
        },
        .merge => |m| {
            var diag: jsonc.Diagnostic = .{};
            const r = json_edit.merge(ctx.arena, text, m.patch, &diag) catch |err|
                return editFailed(ctx, verb, file, m.label, err, diag);
            text = r.text;
            // Both texts parse: merge parsed `before` (or took a blank file
            // as an empty object) and wrote valid JSON.
            const old_root = jsonc.parseInto(ctx.arena, if (files.isBlank(before)) "{}" else before, .{}, null) catch |err| return editFailed(ctx, verb, file, "", err, .{});
            const new_root = jsonc.parseInto(ctx.arena, text, .{}, null) catch |err| return editFailed(ctx, verb, file, "", err, .{});
            for (edits, 0..) |e, i| {
                const old = old_root.getDotted(e.path);
                const new = new_root.getDotted(e.path);
                changed[i] = if (old != null and new != null) !old.?.eql(new.?) else (old != null) != (new != null);
                values[i] = if (new) |n| try n.toJsonAlloc(ctx.arena) else null;
            }
        },
    }
    const any = !std.mem.eql(u8, text, before);
    if (any) {
        var check = try settings.validate.checkEdit(ctx.arena, before, text, .{ .specs = files.specs });
        if (!check.accepted()) {
            try ctx.err.print("{s}: config {s}: refusing to write {s}; the change is invalid:\n", .{ ctx.brand.name(), verb, file });
            for (check.introduced) |issue| try ctx.err.print("  {s}: {s}\n", .{ issue.path, issue.message });
            return output.exit.runtime;
        }
        files.writeFile(file, ctx.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return ctx.runtimeError("config {s}: cannot write {s}", .{ verb, file }),
        };
    }
    if (ctx.json()) {
        var s: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("file");
        try s.write(file);
        try s.objectField("paths");
        try s.beginArray();
        for (edits, changed, values) |e, c, value| {
            try s.beginObject();
            try s.objectField("path");
            try s.write(e.path);
            try s.objectField("changed");
            try s.write(c);
            if (value) |v| {
                try s.objectField("value");
                try s.print("{s}", .{v});
            }
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try ctx.out.writeByte('\n');
        return output.exit.ok;
    }
    for (edits, changed, values) |e, c, value| {
        if (!c) {
            try ctx.out.writeAll("OK unchanged\n");
        } else if (value) |v| {
            try ctx.out.print("OK {s} = {s}\n", .{ e.path, v });
        } else try ctx.out.print("OK {s} unset\n", .{e.path});
    }
    try ctx.out.print("path: {s}\n", .{file});
    return output.exit.ok;
}

fn valueJson(ctx: *Ctx, verb: []const u8, text: []const u8) !?[]const u8 {
    return resolve.cliValueJson(ctx.arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => {
            _ = ctx.usageError("config {s}: the value is not valid UTF-8", .{verb});
            return null;
        },
    };
}

pub const set_usage = "Usage: cmux config set <setting.path> <value> [--file wmux|cmux] [--json]";

pub fn runSet(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config set", set_usage, args, &file_flags)) orelse return output.exit.usage;
    var pos: std.ArrayList([]const u8) = .empty;
    try pos.appendSlice(ctx.arena, flags.positionals);
    // `config set key -- -1` style values.
    if (flags.payload) |p| try pos.appendSlice(ctx.arena, p);
    if (pos.items.len != 2) return util.usageFail(ctx, set_usage, "config set requires a setting path and a value", .{});
    const which = whichFile(ctx, flags, set_usage) orelse return output.exit.usage;
    const path = settingPath(ctx, "set", pos.items[0]) orelse return output.exit.usage;
    const v = (try valueJson(ctx, "set", pos.items[1])) orelse return output.exit.usage;
    return apply(ctx, "set", which, &.{.{ .path = path, .value = v }});
}

pub const unset_usage = "Usage: cmux config unset <setting.path> [--file wmux|cmux] [--json]";

pub fn runUnset(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config unset", unset_usage, args, &file_flags)) orelse return output.exit.usage;
    if (flags.positionals.len != 1) return util.usageFail(ctx, unset_usage, "config unset requires exactly one setting path", .{});
    const which = whichFile(ctx, flags, unset_usage) orelse return output.exit.usage;
    const path = settingPath(ctx, "unset", flags.positionals[0]) orelse return output.exit.usage;
    return apply(ctx, "unset", which, &.{.{ .path = path, .value = null }});
}

pub const toggle_usage = "Usage: cmux config toggle <setting.path> [--file wmux|cmux] [--json]";

pub fn runToggle(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config toggle", toggle_usage, args, &file_flags)) orelse return output.exit.usage;
    if (flags.positionals.len != 1) return util.usageFail(ctx, toggle_usage, "config toggle requires exactly one setting path", .{});
    const which = whichFile(ctx, flags, toggle_usage) orelse return output.exit.usage;
    const path = settingPath(ctx, "toggle", flags.positionals[0]) orelse return output.exit.usage;
    var code: u8 = 0;
    const e = (try effective(ctx, "toggle", path, &code)) orelse return code;
    const v = resolve.toggled(e) orelse return ctx.usageError("config toggle: '{s}' is not a boolean setting", .{path});
    return apply(ctx, "toggle", which, &.{.{ .path = path, .value = v }});
}

pub const cycle_usage = "Usage: cmux config cycle <setting.path> <value1> [value2...] [--file wmux|cmux] [--json]";

pub fn runCycle(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config cycle", cycle_usage, args, &file_flags)) orelse return output.exit.usage;
    var pos: std.ArrayList([]const u8) = .empty;
    try pos.appendSlice(ctx.arena, flags.positionals);
    if (flags.payload) |p| try pos.appendSlice(ctx.arena, p);
    if (pos.items.len < 2) return util.usageFail(ctx, cycle_usage, "config cycle requires a setting path and at least one value", .{});
    const which = whichFile(ctx, flags, cycle_usage) orelse return output.exit.usage;
    const path = settingPath(ctx, "cycle", pos.items[0]) orelse return output.exit.usage;
    var code: u8 = 0;
    const e = (try effective(ctx, "cycle", path, &code)) orelse return code;
    const values = pos.items[1..];
    const idx = (try resolve.cycleIndex(ctx.arena, &e.value, values)) orelse 0;
    const v = (try valueJson(ctx, "cycle", values[idx])) orelse return output.exit.usage;
    return apply(ctx, "cycle", which, &.{.{ .path = path, .value = v }});
}

pub const preset_usage = "Usage: cmux config preset <name> [--file wmux|cmux] [--json]";

pub fn runPreset(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config preset", preset_usage, args, &file_flags)) orelse return output.exit.usage;
    if (flags.positionals.len != 1) return util.usageFail(ctx, preset_usage, "config preset requires exactly one preset name", .{});
    const which = whichFile(ctx, flags, preset_usage) orelse return output.exit.usage;
    const name = flags.positionals[0];
    const loc = try files.locate(ctx);
    var preset: ?jsonc.Node = null;
    for ([_]?[]const u8{ loc.wmux_json, loc.cmux_json }) |file| {
        var failure: ?files.ParseFailure = null;
        const parsed = (try files.parseFile(ctx, file, &failure)) orelse {
            if (failure) |f| return parseFailed(ctx, "preset", f);
            continue;
        };
        const presets = parsed.root.get("settingPresets") orelse continue;
        if (presets.get(name)) |p| {
            preset = p.*;
            break;
        }
    }
    const p = preset orelse return ctx.usageError("config preset: unknown preset '{s}' (define it under settingPresets in wmux.json)", .{name});
    if (p.data != .object) return ctx.usageError("config preset: settingPresets.{s} must be an object", .{name});
    var edits: std.ArrayList(Edit) = .empty;
    if (try flatten(ctx, &edits, "", &p)) |bad| return ctx.usageError("config preset: settingPresets.{s} names '{s}', which is not a setting", .{ name, bad });
    if (edits.items.len == 0) return ctx.usageError("config preset: settingPresets.{s} is empty", .{name});
    // One deep merge: nested objects merge key by key, including the keys
    // of an object-typed setting (cmux), so a preset that adds one entry
    // keeps the others.
    return mutate(ctx, "preset", which, edits.items, .{ .merge = .{ .patch = try p.toJsonAlloc(ctx.arena), .label = try std.fmt.allocPrint(ctx.arena, "settingPresets.{s}", .{name}) } });
}

/// The settings a preset names: a declared setting (an object-typed one
/// included) ends the walk; other objects are sections walked key by key.
/// Returns the first path that is neither, or null. The edits carry no
/// value: `mutate` reads the merged values back.
fn flatten(ctx: *Ctx, edits: *std.ArrayList(Edit), prefix: []const u8, node: *const jsonc.Node) !?[]const u8 {
    for (node.data.object) |m| {
        const path = if (prefix.len == 0) m.key else try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ prefix, m.key });
        if (settings.spec.find(files.specs, path) != null) {
            try edits.append(ctx.arena, .{ .path = path, .value = null });
        } else if (m.value.data == .object) {
            if (try flatten(ctx, edits, path, &m.value)) |bad| return bad;
        } else return path;
    }
    return null;
}

/// `config sidebar-font-size [points]`, `config surface-tab-bar-font-size
/// [points]`: get or set the JSON path the shorthand names.
pub fn runShorthand(ctx: *Ctx, word: []const u8, args: []const []const u8) !u8 {
    const usage = "Usage: cmux config <sidebar-font-size|surface-tab-bar-font-size> [points]";
    const flags = (try util.flagsOrFail(ctx, word, usage, args, &file_flags)) orelse return output.exit.usage;
    if (flags.positionals.len > 1) return util.usageFail(ctx, usage, "config {s}: unexpected argument '{s}'", .{ word, flags.positionals[1] });
    const path = settingPath(ctx, word, word) orelse return output.exit.usage;
    if (flags.positionals.len == 0) return printGet(ctx, path);
    const pts = std.fmt.parseFloat(f64, flags.positionals[0]) catch return util.usageFail(ctx, usage, "config {s}: '{s}' is not a number", .{ word, flags.positionals[0] });
    if (!std.math.isFinite(pts) or pts <= 0) return util.usageFail(ctx, usage, "config {s}: '{s}' is not a positive number", .{ word, flags.positionals[0] });
    const which = whichFile(ctx, flags, usage) orelse return output.exit.usage;
    const v = (try valueJson(ctx, word, flags.positionals[0])) orelse return output.exit.usage;
    return apply(ctx, word, which, &.{.{ .path = path, .value = v }});
}
