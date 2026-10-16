//! `config doctor|check|validate [--path <file>]... [--scope global|project]
//! [--json]`: JSONC syntax plus schema checks (paths, types, enums, bounds,
//! scope) of wmux.json, the shared cmux.json and the project file, or of
//! the given files. Exit 1 when any file has an error. Offline.

const std = @import("std");
const proto = @import("wmux_proto");
const validate = proto.settings.validate;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const docs = @import("../../docs.zig");
const util = @import("../cli_misc/util.zig");
const files = @import("files.zig");

pub const usage = "Usage: cmux config doctor [--path <file>]... [--scope global|project] [--json]";

const flag_specs = [_]util.FlagSpec{
    .{ .name = "--path", .value = true },
    .{ .name = "--scope", .value = true },
};

const Status = enum { ok, @"error", missing };

/// A file that exists but cannot be read.
const unreadable_message = std.fmt.comptimePrint("cannot read (unreadable or larger than {d} MiB)", .{files.max_file_bytes >> 20});

const Finding = struct {
    label: []const u8,
    path: []const u8,
    display_path: []const u8,
    status: Status,
    keys: usize = 0,
    bytes: ?usize = null,
    message: ?[]const u8 = null,
    issues: []const validate.Issue = &.{},
    errors: usize = 0,
};

pub fn run(ctx: *Ctx, args: []const []const u8) !u8 {
    const flags = (try util.flagsOrFail(ctx, "config doctor", usage, args, &flag_specs)) orelse return output.exit.usage;
    if (flags.positionals.len > 0) return util.usageFail(ctx, usage, "config doctor: unexpected argument '{s}'", .{flags.positionals[0]});
    var scope_override: ?validate.FileScope = null;
    if (flags.get("--scope")) |s| {
        scope_override = std.meta.stringToEnum(validate.FileScope, s) orelse return util.usageFail(ctx, usage, "--scope must be global or project", .{});
    }
    const loc = try files.locate(ctx);
    var findings: std.ArrayList(Finding) = .empty;
    const explicit = try flags.all(ctx.arena, "--path");
    if (explicit.len > 0) {
        for (explicit) |p| try findings.append(ctx.arena, try check(ctx, loc, "file", try util.resolvePath(ctx, p), scope_override orelse .global, true));
    } else {
        if (loc.wmux_json) |p| try findings.append(ctx.arena, try check(ctx, loc, "wmux.json", p, scope_override orelse .global, false));
        if (loc.cmux_json) |p| try findings.append(ctx.arena, try check(ctx, loc, "cmux.json", p, scope_override orelse .global, false));
        if (loc.project) |p| try findings.append(ctx.arena, try check(ctx, loc, "project", p, scope_override orelse .project, false));
    }
    var error_count: usize = 0;
    for (findings.items) |f| error_count += f.errors;
    const docs_loc = try docs.Locations.resolve(ctx.arena, ctx.env, ctx.platform.selfExePath(ctx.arena));
    const schema = if (docs_loc.install_dir) |i| try proto.paths.schemaFile(ctx.arena, proto.paths.Style.native, i) else "share\\wmux\\schema\\wmux.schema.json";
    const reload = try util.branded(ctx, "cmux reload-config");
    const docs_url = docs.find("settings").?.docs[0];
    if (ctx.json()) {
        try writeJson(ctx, findings.items, error_count, reload, docs_url, schema);
    } else {
        try writeText(ctx, findings.items, error_count, reload);
    }
    return if (error_count > 0) output.exit.runtime else output.exit.ok;
}

fn check(ctx: *Ctx, loc: files.Locations, label: []const u8, path: []const u8, scope: validate.FileScope, required: bool) !Finding {
    var f: Finding = .{ .label = label, .path = path, .display_path = try files.displayPath(ctx.arena, loc.home, path), .status = .ok };
    const src = (files.readExisting(ctx, path) catch {
        f.status = .@"error";
        f.message = unreadable_message;
        f.errors = 1;
        return f;
    }) orelse {
        f.status = .missing;
        f.message = "not found";
        if (required) f.errors = 1;
        return f;
    };
    f.bytes = src.len;
    if (std.mem.trim(u8, src, " \t\r\n").len == 0) {
        f.message = "empty";
        return f;
    }
    const report = try validate.validateText(ctx.arena, src, .{ .scope = scope, .specs = files.specs });
    f.issues = report.issues;
    f.errors = report.errorCount();
    if (f.errors > 0) f.status = .@"error";
    if (proto.jsonc.parseInto(ctx.arena, src, .{}, null)) |root| {
        if (root.data == .object) f.keys = root.data.object.len;
    } else |_| {}
    return f;
}

fn plural(n: usize, word: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {s}{s}", .{ n, word, if (n == 1) "" else "s" }) catch word;
}

fn writeText(ctx: *Ctx, findings: []const Finding, error_count: usize, reload: []const u8) !void {
    const w = ctx.out;
    if (findings.len == 0) try w.writeAll("No config files to check (no home directory or config directory is set).\n");
    for (findings) |f| {
        var b1: [48]u8 = undefined;
        var b2: [48]u8 = undefined;
        switch (f.status) {
            .missing => try w.print("{s}: {s}: not found\n", .{ f.label, f.display_path }),
            .ok => {
                var warnings: usize = 0;
                for (f.issues) |i| if (i.severity != .err) {
                    warnings += 1;
                };
                if (warnings > 0) {
                    try w.print("{s}: {s}: OK ({s}, {s})\n", .{ f.label, f.display_path, plural(f.keys, "key", &b1), plural(warnings, "note", &b2) });
                } else try w.print("{s}: {s}: OK ({s})\n", .{ f.label, f.display_path, plural(f.keys, "key", &b1) });
            },
            .@"error" => if (f.message) |m| {
                try w.print("{s}: {s}: {s}\n", .{ f.label, f.display_path, m });
            } else try w.print("{s}: {s}: {s}\n", .{ f.label, f.display_path, plural(f.errors, "error", &b1) }),
        }
        for (f.issues) |i| try w.print("  {f}\n", .{i});
    }
    var b: [48]u8 = undefined;
    if (error_count > 0) {
        try w.print("config doctor: {s}\n", .{plural(error_count, "error", &b)});
    } else try w.writeAll("config doctor: OK\n");
    try w.print("Reload after editing: {s}\n", .{reload});
}

fn writeJson(ctx: *Ctx, findings: []const Finding, error_count: usize, reload: []const u8, docs_url: []const u8, schema: []const u8) !void {
    var s: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(error_count == 0);
    try s.objectField("error_count");
    try s.write(error_count);
    try s.objectField("findings");
    try s.beginArray();
    for (findings) |f| {
        try s.beginObject();
        try s.objectField("label");
        try s.write(f.label);
        try s.objectField("display_path");
        try s.write(f.display_path);
        try s.objectField("path");
        try s.write(f.path);
        try s.objectField("status");
        try s.write(@tagName(f.status));
        try s.objectField("ok");
        try s.write(f.errors == 0);
        try s.objectField("keys");
        try s.write(f.keys);
        if (f.message) |m| {
            try s.objectField("message");
            try s.write(m);
        }
        if (f.bytes) |n| {
            try s.objectField("bytes");
            try s.write(n);
        }
        if (f.issues.len > 0) {
            try s.objectField("issues");
            try s.beginArray();
            for (f.issues) |i| try s.write(.{ .path = i.path, .message = i.message, .severity = i.severity.label(), .line = i.pos.line, .column = i.pos.col });
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("reload_command");
    try s.write(reload);
    try s.objectField("docs_url");
    try s.write(docs_url);
    try s.objectField("schema_url");
    try s.write(schema);
    try s.endObject();
    try ctx.out.writeByte('\n');
}
