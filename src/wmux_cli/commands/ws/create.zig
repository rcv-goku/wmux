//! `new-workspace` / `workspace create` (core-cli-new-workspace,
//! core-workspace-initial-command, cli-initial-command-input,
//! cli-workspace-env-vars) and `workspace env`.
//!
//! `workspace.create` params: `title`, `description`, `cwd` (relative paths
//! resolve against the CLI's working directory), `initial_input` (the
//! `--command` text plus one `\r`; blank text is dropped; `--layout` wins),
//! `layout` (a JSON object/array, else a layout name string),
//! `workspace_env`, `window_id`, `focus` (always sent; default false),
//! `group_id`, `group_placement`, `group_reference_workspace_id`, and the
//! wmux params `worktree` (branch) and `repo` (resolved like `cwd`;
//! defaults to the CLI's working directory) kept from `+workspace new`
//! (ADR-4.11, Appendix B.4).

const std = @import("std");
const proto = @import("wmux_proto");
const paths = proto.paths;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const common = @import("common.zig");
const envfile = @import("envfile.zig");
const Def = common.opts.Def;
const Params = common.Params;

pub const create_defs = [_]Def{
    .{ .name = "--name" },
    .{ .name = "--description" },
    .{ .name = "--cwd" },
    .{ .name = "--command" },
    .{ .name = "--env" },
    .{ .name = "--env-file" },
    .{ .name = "--layout" },
    .{ .name = "--window" },
    // A bare `--focus` (the `+workspace new --focus` spelling) means true.
    .{ .name = "--focus", .optional_value = true },
    .{ .name = "--no-focus", .takes_value = false },
    .{ .name = "--group" },
    .{ .name = "--group-placement" },
    .{ .name = "--group-reference" },
    // wmux extensions kept from `+workspace new` (ADR-4.11).
    .{ .name = "--worktree" },
    .{ .name = "--repo" },
};

pub const placements = [_][]const u8{ "afterCurrent", "top", "end" };

pub fn validPlacement(s: []const u8) bool {
    for (placements) |p| if (std.mem.eql(u8, p, s)) return true;
    return false;
}

/// Max bytes read from one `--env-file`.
pub const max_env_file = 1024 * 1024;

/// Absolute on Windows (`C:\`, `C:/`, `\\server`, `\`) or POSIX (`/`).
pub fn isAbsolute(p: []const u8) bool {
    if (p.len >= 1 and (p[0] == '/' or p[0] == '\\')) return true;
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/');
}

/// `p` resolved against the CLI's working directory when relative.
pub fn resolvePath(ctx: *Ctx, p: []const u8) ![]const u8 {
    if (isAbsolute(p)) return p;
    const cwd = ctx.platform.cwd(ctx.arena) orelse return p;
    if (std.mem.eql(u8, p, ".")) return cwd;
    return paths.join(ctx.arena, paths.Style.native, &.{ cwd, p });
}

fn parseFocus(s: []const u8) ?bool {
    const t = [_][]const u8{ "true", "1", "yes", "on" };
    const f = [_][]const u8{ "false", "0", "no", "off" };
    for (t) |x| if (std.ascii.eqlIgnoreCase(s, x)) return true;
    for (f) |x| if (std.ascii.eqlIgnoreCase(s, x)) return false;
    return null;
}

/// Last focus flag wins (`--focus [<bool>]`, `--focus=<bool>`, `--no-focus`).
fn focusValue(o: common.opts.Opts) error{Invalid}!bool {
    var v = false;
    for (o.entries) |e| {
        if (std.mem.eql(u8, e.name, "--no-focus")) v = false;
        if (std.mem.eql(u8, e.name, "--focus")) v = if (e.value) |s| parseFocus(s) orelse return error.Invalid else true;
    }
    return v;
}

pub fn run(ctx: *Ctx, args: []const []const u8, u: []const u8) !u8 {
    var code: u8 = 0;
    const o = (try common.parseOpts(ctx, u, args, &create_defs, &code)) orelse return code;
    if (o.positionals.len > 0) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[0]});
    var p = Params.init(ctx.arena);
    if (o.get("--name")) |v| {
        if (std.mem.trim(u8, v, " \t\r\n").len == 0) return common.usage(ctx, u, "--name requires a non-empty value", .{});
        try p.str("title", v);
    }
    if (o.get("--description")) |v| try p.str("description", v);
    if (o.get("--cwd")) |v| {
        if (v.len == 0) return common.usage(ctx, u, "--cwd requires a non-empty value", .{});
        try p.str("cwd", try resolvePath(ctx, v));
    }
    // The app runs `git worktree` in the repository, which defaults to this
    // CLI's directory (the app's own directory is never the caller's).
    if (o.get("--worktree")) |branch| {
        if (std.mem.trim(u8, branch, " \t\r\n").len == 0) return common.usage(ctx, u, "--worktree requires a non-empty branch", .{});
        try p.str("worktree", branch);
        const repo = if (o.get("--repo")) |r| blk: {
            if (r.len == 0) return common.usage(ctx, u, "--repo requires a non-empty value", .{});
            break :blk try resolvePath(ctx, r);
        } else ctx.platform.cwd(ctx.arena) orelse
            return ctx.runtimeError("cannot determine the current directory for --worktree; pass --repo <path>", .{});
        try p.str("repo", repo);
    } else if (o.has("--repo")) return common.usage(ctx, u, "--repo requires --worktree", .{});
    if (o.get("--layout")) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len == 0) return common.usage(ctx, u, "--layout requires a non-empty value", .{});
        if (t[0] == '{' or t[0] == '[') {
            const lv = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, t, .{}) catch
                return common.usage(ctx, u, "--layout is not valid JSON", .{});
            try p.value("layout", lv);
        } else try p.str("layout", t);
    } else if (o.get("--command")) |v| {
        // Typed into the new interactive shell with one Enter.
        if (std.mem.trim(u8, v, " \t\r\n").len > 0) try p.str("initial_input", try std.mem.concat(ctx.arena, u8, &.{ v, "\r" }));
    }
    var env: ?envfile.EnvSet = null;
    if (try envSet(ctx, u, o, &env)) |c| return c;
    if (env) |*set| try p.value("workspace_env", try set.toJson(ctx.arena));
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    try p.boolean("focus", focusValue(o) catch return common.usage(ctx, u, "--focus must be true or false", .{}));
    if (o.get("--group")) |g| {
        if (try common.putHandle(ctx, &p, u, "group_id", .workspace_group, g)) |c| return c;
    }
    if (o.get("--group-placement")) |v| {
        if (!o.has("--group")) return common.usage(ctx, u, "--group-placement requires --group", .{});
        if (!validPlacement(v)) return common.usage(ctx, u, "--group-placement must be one of: afterCurrent, top, end", .{});
        try p.str("group_placement", v);
    }
    if (o.get("--group-reference")) |v| {
        if (!o.has("--group")) return common.usage(ctx, u, "--group-reference requires --group", .{});
        if (try common.putHandle(ctx, &p, u, "group_reference_workspace_id", .workspace, v)) |c| return c;
    }
    return common.created(ctx, "workspace.create", &p, "workspace");
}

/// `--env-file` files in order, then `--env` (which overrides) into
/// `out.*` (left null when neither flag was given). Returns an exit code on
/// bad input.
fn envSet(ctx: *Ctx, u: []const u8, o: common.opts.Opts, out: *?envfile.EnvSet) !?u8 {
    const files = try o.all(ctx.arena, "--env-file");
    const assigns = try o.all(ctx.arena, "--env");
    if (files.len == 0 and assigns.len == 0) return null;
    var set: envfile.EnvSet = .{};
    for (files) |f| {
        if (f.len == 0) return common.usage(ctx, u, "--env-file requires a non-empty value", .{});
        const path = try resolvePath(ctx, f);
        const bytes = ctx.platform.readFile(ctx.arena, path, max_env_file) orelse
            return ctx.runtimeError("cannot read --env-file '{s}'", .{f});
        var line: usize = 0;
        const pairs = envfile.parseFile(ctx.arena, bytes, &line) catch |err| switch (err) {
            error.Malformed => return ctx.runtimeError("invalid line {d} in --env-file '{s}': expected KEY=VALUE", .{ line, f }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        for (pairs) |pr| try set.put(ctx.arena, pr);
    }
    for (assigns) |a| {
        const pr = envfile.parseAssignment(a) orelse return common.usage(ctx, u, "--env expects KEY=VALUE", .{});
        try set.put(ctx.arena, pr);
    }
    out.* = set;
    return null;
}

/// `v` with every scalar replaced by `***`; object keys (the variable
/// names) and nulls are kept.
pub fn maskValues(arena: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    switch (v) {
        .object => |m| {
            var out = std.json.ObjectMap.init(arena);
            try out.ensureTotalCapacity(m.count());
            var it = m.iterator();
            while (it.next()) |e| out.putAssumeCapacity(e.key_ptr.*, try maskValues(arena, e.value_ptr.*));
            return .{ .object = out };
        },
        .array => |arr| {
            var out = try std.json.Array.initCapacity(arena, arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try maskValues(arena, item));
            return .{ .array = out };
        },
        .null => return .null,
        else => return .{ .string = envfile.mask },
    }
}

/// Keys of a `workspace.env` result that name its target, never a value.
const env_target_keys = [_][]const u8{ "workspace_id", "workspace_ref", "window_id", "window_ref" };

/// Keys of a `workspace.env` result that hold the variable set (cmux:
/// `env`; `workspace_env` is accepted too).
const env_set_keys = [_][]const u8{ "env", "workspace_env" };

/// The `workspace.env` result for `--mask`: every value goes through
/// `maskValues` except the target handles and a numeric `count` (cmux
/// reports the number of variables, which is not secret). Anything else
/// fails closed: a set under any key, or a result that is not an object,
/// is masked too.
pub fn maskEnvResult(arena: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    if (v != .object) return maskValues(arena, v);
    var out = std.json.ObjectMap.init(arena);
    try out.ensureTotalCapacity(v.object.count());
    var it = v.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const target = for (env_target_keys) |k| {
            if (std.mem.eql(u8, k, key)) break true;
        } else false;
        const count = std.mem.eql(u8, key, "count") and e.value_ptr.* == .integer;
        out.putAssumeCapacity(key, if (target or count) e.value_ptr.* else try maskValues(arena, e.value_ptr.*));
    }
    return .{ .object = out };
}

/// `--json` for `workspace env`: `--id-format` rewrites the result's
/// handles only. The variable set is user data (a variable may be called
/// `id`, or `x_id` next to `x_ref`), so it is put back verbatim after
/// formatting, as cmux does.
fn writeEnvJson(ctx: *Ctx, v: std.json.Value) !void {
    if (v != .object or ctx.parsed.globals.id_format == .both) return common.writeJsonResult(ctx, v);
    var formatted = try output.formatIds(ctx.arena, v, ctx.parsed.globals.id_format);
    for (env_set_keys) |k| {
        if (v.object.get(k)) |set| try formatted.object.put(k, set);
    }
    try output.writeJson(ctx.out, formatted);
}

const EnvLine = struct { key: []const u8, value: std.json.Value };

fn envLineLess(_: void, a: EnvLine, b: EnvLine) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// `workspace env [<handle>|--workspace <h>] [--mask]`: the configured
/// set as `KEY=VALUE` lines sorted by name (`--mask` shows `***` instead
/// of each value).
pub fn runEnv(ctx: *Ctx, args: []const []const u8, u: []const u8) !u8 {
    var code: u8 = 0;
    const defs = [_]Def{ .{ .name = "--workspace" }, .{ .name = "--window" }, .{ .name = "--mask", .takes_value = false } };
    const o = (try common.parseOpts(ctx, u, args, &defs, &code)) orelse return code;
    if (o.positionals.len > 1) return common.usage(ctx, u, "unexpected argument '{s}'", .{o.positionals[1]});
    if (o.positionals.len == 1 and o.get("--workspace") != null) return common.usage(ctx, u, "give the workspace as an argument or --workspace, not both", .{});
    const explicit: ?[]const u8 = if (o.positionals.len == 1) o.positionals[0] else o.get("--workspace");
    var p = Params.init(ctx.arena);
    if (try common.putWindow(ctx, &p, u, o)) |c| return c;
    if (try common.putWorkspaceTarget(ctx, &p, u, explicit, common.windowText(ctx, o) != null)) |c| return c;
    const result = switch (try common.request(ctx, "workspace.env", &p)) {
        .code => |c| return c,
        .ok => |r| r,
    };
    // No value survives --mask, whatever the result's shape.
    const v = if (o.has("--mask")) try maskEnvResult(ctx.arena, result) else result;
    const env_key = if (common.field(v, "env") != null) "env" else "workspace_env";
    if (ctx.json()) {
        try writeEnvJson(ctx, v);
        return output.exit.ok;
    }
    const m = common.obj(common.field(v, env_key)) orelse std.json.ObjectMap.init(ctx.arena);
    if (m.count() == 0) {
        try ctx.out.writeAll("No environment variables\n");
        return output.exit.ok;
    }
    var lines = try ctx.arena.alloc(EnvLine, m.count());
    var it = m.iterator();
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) lines[n] = .{ .key = e.key_ptr.*, .value = e.value_ptr.* };
    std.mem.sort(EnvLine, lines, {}, envLineLess);
    for (lines) |l| {
        try ctx.out.print("{s}=", .{l.key});
        switch (l.value) {
            .string => |s| try ctx.out.writeAll(s),
            .null => {},
            else => try std.json.Stringify.value(l.value, .{}, ctx.out),
        }
        try ctx.out.writeByte('\n');
    }
    return output.exit.ok;
}
