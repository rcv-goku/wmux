//! Config file locations, reading, layering and writing for the offline
//! `config` subcommands (ADR-5.1, ADR-5.6). Reads go through
//! `Platform.readFile`; writes through `util.fs` (atomic replace).

const std = @import("std");
const proto = @import("wmux_proto");
const settings = proto.settings;
const jsonc = proto.jsonc;
const paths = proto.paths;
const Allocator = std.mem.Allocator;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const platform_mod = @import("../../platform.zig");
const util = @import("../cli_misc/util.zig");

/// The spec registry the CLI resolves against. Tests point it at
/// `settings.validate.test_fixture_specs` while the real registry fills up.
pub var specs: []const settings.spec.Spec = settings.specs_manifest.all;

/// Max bytes read from a config file.
pub const max_file_bytes = 4 * 1024 * 1024;

pub const Which = enum { wmux, cmux };

pub const Locations = struct {
    wmux_json: ?[]const u8,
    cmux_json: ?[]const u8,
    /// First existing project file from the cwd upward.
    project: ?[]const u8,
    home: ?[]const u8,

    pub fn file(self: Locations, which: Which) ?[]const u8 {
        return switch (which) {
            .wmux => self.wmux_json,
            .cmux => self.cmux_json,
        };
    }
};

pub fn locate(ctx: *Ctx) !Locations {
    const style = paths.Style.native;
    const cfg = try paths.configDir(ctx.arena, ctx.env, style);
    const cmux_cfg = try paths.cmuxConfigDir(ctx.arena, ctx.env, style);
    var project: ?[]const u8 = null;
    if (ctx.platform.cwd(ctx.arena)) |cwd| {
        const candidates = try settings.resolve.projectCandidates(ctx.arena, cwd);
        for (candidates) |c| if (ctx.platform.pathExists(c)) {
            project = c;
            break;
        };
    }
    return .{
        .wmux_json = if (cfg) |d| try paths.join(ctx.arena, style, &.{ d, paths.files.wmux_json }) else null,
        .cmux_json = if (cmux_cfg) |d| try paths.join(ctx.arena, style, &.{ d, paths.files.cmux_json }) else null,
        .project = project,
        .home = if (style == .windows) ctx.env.getNonEmpty(proto.env_names.USERPROFILE) else ctx.env.getNonEmpty(proto.env_names.HOME),
    };
}

/// Contents of `path`: null when the file does not exist;
/// `error.Unreadable` when it exists but cannot be read (or is larger than
/// `max_file_bytes`). Unlike `read`, an unreadable file is never mistaken
/// for a missing one, so a rewrite cannot replace a file it did not read.
pub fn readExisting(ctx: *Ctx, path: []const u8) error{Unreadable}!?[]const u8 {
    if (read(ctx, path)) |bytes| return bytes;
    if (ctx.platform.pathExists(path)) return error.Unreadable;
    return null;
}

/// `~`-relative spelling of `path` for display.
pub fn displayPath(arena: Allocator, home: ?[]const u8, path: []const u8) ![]const u8 {
    const h = home orelse return path;
    if (h.len == 0 or path.len <= h.len or !std.mem.startsWith(u8, path, h)) return path;
    const sep = path[h.len];
    if (sep != '/' and sep != '\\') return path;
    return std.fmt.allocPrint(arena, "~{s}", .{path[h.len..]});
}

pub fn read(ctx: *Ctx, path: []const u8) ?[]const u8 {
    return ctx.platform.readFile(ctx.arena, path, max_file_bytes);
}

/// A parsed config file.
pub const Parsed = struct {
    path: []const u8,
    src: []const u8,
    root: jsonc.Node,
};

pub const ParseFailure = struct { path: []const u8, diag: jsonc.Diagnostic };

/// Parses `path` when it exists. A syntax error fills `failure`.
pub fn parseFile(ctx: *Ctx, path: ?[]const u8, failure: *?ParseFailure) !?Parsed {
    const p = path orelse return null;
    const src = read(ctx, p) orelse return null;
    if (std.mem.trim(u8, src, " \t\r\n").len == 0) return null;
    var diag: jsonc.Diagnostic = .{};
    const root = jsonc.parseInto(ctx.arena, src, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            failure.* = .{ .path = p, .diag = diag };
            return null;
        },
    };
    return .{ .path = p, .src = src, .root = root };
}

/// Managed policy for `automation.socketControlMode` (the one value the
/// CLI platform layer reads today).
fn policyValues(ctx: *Ctx) ![]const settings.resolve.PolicyValue {
    var list: std.ArrayList(settings.resolve.PolicyValue) = .empty;
    for ([_]platform_mod.PolicyHive{ .hklm, .hkcu }) |hive| switch (ctx.platform.policy(ctx.arena, hive)) {
        .string => |s| try list.append(ctx.arena, .{
            .path = "automation.socketControlMode",
            .hive = if (hive == .hklm) .hklm else .hkcu,
            .data = .{ .json = try std.json.Stringify.valueAlloc(ctx.arena, s, .{}) },
        }),
        else => {},
    };
    return list.items;
}

/// Effective settings from cmux.json, wmux.json, the project file and
/// policy. A file that does not parse fills `failure` and resolution stops.
pub fn resolveAll(ctx: *Ctx, loc: Locations, failure: *?ParseFailure) !?settings.resolve.Resolved {
    var layers: std.ArrayList(settings.resolve.Layer) = .empty;
    const inputs = [_]struct { ?[]const u8, settings.resolve.Source }{
        .{ loc.cmux_json, .cmux_json },
        .{ loc.wmux_json, .wmux_json },
        .{ loc.project, .project },
    };
    for (inputs) |in| {
        const parsed = (try parseFile(ctx, in[0], failure)) orelse {
            if (failure.* != null) return null;
            continue;
        };
        const node = try ctx.arena.create(jsonc.Node);
        node.* = parsed.root;
        try layers.append(ctx.arena, .{ .source = in[1], .root = node, .src = parsed.src });
    }
    return try settings.resolve.resolve(ctx.arena, specs, layers.items, try policyValues(ctx));
}

pub fn writeFile(path: []const u8, arena: Allocator, bytes: []const u8) util.WriteError!void {
    return util.fs.writeFile(arena, path, bytes);
}
