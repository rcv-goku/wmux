//! Running browser commands over a `Ctx`: target and verb parsing, the
//! client-side checks, the v2 call(s) with their deadlines, and output.

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const paths = proto.paths;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const brand_mod = @import("../../brand.zig");
const docs = @import("../../docs.zig");
const focus_default = @import("../../focus_default.zig");
const client_mod = @import("../../client.zig");
const system = @import("../system.zig");
const g = @import("grammar.zig");
const plan_mod = @import("plan.zig");
const render = @import("render.zig");
const availability = @import("availability.zig");
const files = @import("files.zig");

pub const usage_line = "Usage: cmux browser [--surface <id|ref|index> | <surface>] <subcommand> [args]";
pub const help_text = @embedFile("../../help/browser-cmd.txt");
pub const skill_text = @embedFile("../../help/browser-skill.txt");
pub const repl_guide_text = @embedFile("../../help/browser-repl-guide.txt");

/// `<prog>: <message>` (rebranded) on stderr; exit 2.
fn usage(ctx: *Ctx, msg: []const u8) u8 {
    ctx.err.print("{s}: ", .{ctx.brand.name()}) catch {};
    brand_mod.write(ctx.err, ctx.brand, msg) catch {};
    ctx.err.writeByte('\n') catch {};
    return output.exit.usage;
}

/// `<prog>: <message>` on stderr; exit 1.
fn runtime(ctx: *Ctx, comptime fmt: []const u8, a: anytype) u8 {
    return ctx.runtimeError(fmt, a);
}

fn home(ctx: *Ctx) ?[]const u8 {
    return switch (paths.Style.native) {
        .windows => ctx.env.first(&.{ env_names.USERPROFILE, env_names.HOME }),
        .posix => ctx.env.first(&.{ env_names.HOME, env_names.USERPROFILE }),
    };
}

/// `cmux browser ...`.
pub fn runBrowser(ctx: *Ctx) !u8 {
    const args = ctx.args();
    if (args.len > 0 and std.mem.eql(u8, args[0], "--skill")) {
        if (args.len > 1) return usage(ctx, "browser --skill takes no arguments");
        return runLocal(ctx, .skill);
    }
    var diag: g.Diag = .{};
    const t = g.splitTarget(ctx.arena, args, &diag) catch |err| switch (err) {
        error.Usage => return usage(ctx, diag.message),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const verb = t.verb orelse {
        _ = usage(ctx, "browser requires a subcommand");
        try brand_mod.write(ctx.err, ctx.brand, usage_line ++ "\nRun 'cmux browser --help' for the subcommands.\n");
        return output.exit.usage;
    };
    const in: plan_mod.Inputs = .{
        .verb = verb,
        .rest = t.rest,
        .surface = t.surface,
        .surface_positional = t.surface_positional,
        .workspace = t.workspace,
        .window = t.window,
        .global_window = ctx.parsed.globals.window,
        .caller_workspace = ctx.env.first(&.{ env_names.CMUX_WORKSPACE_ID, env_names.WMUX_WORKSPACE_ID }),
        .cwd = ctx.platform.cwd(ctx.arena),
        .home = home(ctx),
        .agent = focus_default.isAgentEnvironment(ctx.env, ctx.env_names),
    };
    const p = plan_mod.plan(ctx.arena, in, &diag) catch |err| switch (err) {
        error.Usage => return usage(ctx, diag.message),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return switch (p) {
        .local => |l| runLocal(ctx, l),
        .identify => |s| runIdentify(ctx, s),
        .call => |c| runCall(ctx, c, t.surface orelse surfaceParam(c)),
    };
}

fn surfaceParam(c: plan_mod.Call) ?[]const u8 {
    const v = c.params.get("surface_id") orelse return null;
    return if (v == .string) v.string else null;
}

/// A legacy top-level alias: `cmux <alias> args` = `cmux browser <verb> args`.
pub fn runAlias(ctx: *Ctx, verb: []const u8) !u8 {
    ctx.parsed.args = try std.mem.concat(ctx.arena, []const u8, &.{ &.{verb}, ctx.parsed.args });
    return runBrowser(ctx);
}

/// Connects (once) and raises the response deadline to `min_ms`.
fn callWith(ctx: *Ctx, method: []const u8, params_json: ?[]const u8, min_ms: ?u32) !?client_mod.Outcome {
    const c = (try ctx.connect()) orelse return null;
    if (min_ms) |ms| c.opts.response_timeout_ms = @max(c.opts.response_timeout_ms, ms);
    return try ctx.call(method, params_json);
}

fn paramsJson(ctx: *Ctx, params: std.json.ObjectMap) ![]const u8 {
    return std.json.Stringify.valueAlloc(ctx.arena, std.json.Value{ .object = params }, .{});
}

/// `set-input-files`: every path is a readable regular file and the total
/// stays within 32 MiB (cmux messages).
fn checkUploads(ctx: *Ctx, c: plan_mod.Call) ?u8 {
    const list = (c.params.get("files") orelse return null).array.items;
    var total: usize = 0;
    for (list) |f| {
        const bytes = ctx.platform.readFile(ctx.arena, f.string, plan_mod.max_upload_bytes) orelse
            return usage(ctx, "Every upload path must be a readable regular file");
        total += bytes.len;
        ctx.arena.free(bytes);
        if (total > plan_mod.max_upload_bytes) return usage(ctx, "The combined upload must be no larger than 32 MiB");
    }
    return null;
}

fn runCall(ctx: *Ctx, c: plan_mod.Call, surface: ?[]const u8) !u8 {
    if (c.check_uploads) if (checkUploads(ctx, c)) |code| return code;
    const out = (try callWith(ctx, c.method, try paramsJson(ctx, c.params), c.timeout_ms)) orelse return output.exit.runtime;
    const result = switch (out) {
        .ok => |ok| ok.result,
        else => return ctx.reportError(c.method, out),
    };
    if (c.render == .screenshot) return @import("screenshot.zig").finish(ctx, c, result, surface);
    if (ctx.json()) {
        try output.writeResult(ctx.arena, ctx.out, result, ctx.parsed.globals.id_format);
    } else {
        try render.write(ctx.arena, ctx.out, ctx.err, c.render, result, .{
            .prog = ctx.brand.name(),
            .id_format = ctx.parsed.globals.id_format,
            .surface = surface,
        });
    }
    return output.exit.ok;
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

/// `browser identify [--surface <h>]`: `system.identify` (with the caller)
/// plus `browser: {surface, url, title}` for the given surface, or for the
/// focused surface when it is a browser.
fn runIdentify(ctx: *Ctx, explicit: ?[]const u8) !u8 {
    const out = (try callWith(ctx, "system.identify", try system.callerParams(ctx), null)) orelse return output.exit.runtime;
    var result = switch (out) {
        .ok => |ok| ok.result,
        else => return ctx.reportError("system.identify", out),
    };
    var surface = explicit;
    if (surface == null) if (field(result, "focused")) |f| {
        const kind = strField(f, "surface_type") orelse "";
        if (std.mem.eql(u8, kind, "browser")) surface = strField(f, "surface_id") orelse strField(f, "surface_ref");
    };
    if (surface) |s| if (result == .object) {
        const params = try std.json.Stringify.valueAlloc(ctx.arena, .{ .surface_id = s }, .{});
        var browser = std.json.ObjectMap.init(ctx.arena);
        try browser.put("surface", .{ .string = s });
        inline for (.{ .{ "browser.url.get", "url" }, .{ "browser.get.title", "title" } }) |m| {
            const r = (try callWith(ctx, m[0], params, null)) orelse return output.exit.runtime;
            switch (r) {
                .ok => |ok| {
                    const v = field(ok.result, m[1]) orelse field(ok.result, "value") orelse std.json.Value.null;
                    try browser.put(m[1], v);
                },
                // A named surface must be a browser; the focused one is best effort.
                else => if (explicit != null) return ctx.reportError(m[0], r),
            }
        }
        try result.object.put("browser", .{ .object = browser });
    };
    if (ctx.json()) {
        try output.writeResult(ctx.arena, ctx.out, result, ctx.parsed.globals.id_format);
    } else try ctx.out.writeAll("OK\n");
    return output.exit.ok;
}

fn runLocal(ctx: *Ctx, l: plan_mod.Local) !u8 {
    switch (l) {
        .help => try ctx.print(help_text),
        .skill => try ctx.print(skill_text),
        .repl_guide => try ctx.print(repl_guide_text),
        .docs => {
            const topic = docs.find("browser") orelse return runtime(ctx, "no browser docs in this build", .{});
            const loc = try docs.Locations.resolve(ctx.arena, ctx.env, ctx.platform.selfExePath(ctx.arena));
            var aw: std.Io.Writer.Allocating = .init(ctx.arena);
            if (ctx.json()) try docs.writeTopicJson(ctx.arena, &aw.writer, topic, loc) else try docs.writeTopic(ctx.arena, &aw.writer, topic, loc);
            try ctx.print(aw.written());
        },
        .disable, .enable, .status => return runAvailability(ctx, l),
    }
    return output.exit.ok;
}

/// `disable-browser`, `enable-browser`, `browser-status` (and the `browser`
/// verbs): offline, through `wmux.json`.
pub fn runAvailability(ctx: *Ctx, l: plan_mod.Local) !u8 {
    const style = paths.Style.native;
    const dir = (try paths.configDir(ctx.arena, ctx.env, style)) orelse
        return runtime(ctx, "cannot locate the settings directory (set WMUX_CONFIG_DIR)", .{});
    const wmux_path = try paths.join(ctx.arena, style, &.{ dir, paths.files.wmux_json });
    const cmux_path: ?[]const u8 = if (try paths.cmuxConfigDir(ctx.arena, ctx.env, style)) |c| try paths.join(ctx.arena, style, &.{ c, paths.files.cmux_json }) else null;
    const max = 4 * 1024 * 1024;
    const wmux_bytes = ctx.platform.readFile(ctx.arena, wmux_path, max);
    const cmux_bytes = if (cmux_path) |p| ctx.platform.readFile(ctx.arena, p, max) else null;
    // No managed DisableEmbeddedBrowser source reaches the CLI yet (REPORT).
    var st = try availability.status(ctx.arena, wmux_bytes, cmux_bytes, wmux_path, null);
    if (l != .status) {
        if (st.managed) return runtime(ctx, "{s}", .{try availability.managedMessage(ctx.arena, st.domain)});
        // A settings file that exists but cannot be read (locked, denied or
        // over the size cap) is not "missing": rewriting it from `{}` would
        // drop every other setting.
        if (wmux_bytes == null and ctx.platform.pathExists(wmux_path)) {
            return runtime(ctx, "cannot update {s}: it exists but cannot be read (locked, access denied or larger than 4 MiB)", .{wmux_path});
        }
        const want = l == .enable;
        const edited = availability.edit(ctx.arena, wmux_bytes, want) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RootNotObject => return runtime(ctx, "cannot update {s}: its top level is not a JSON object", .{wmux_path}),
            // Valid JSON whose "wmux" or "wmux.browser" holds a non-object:
            // say so instead of suggesting the file be removed.
            error.PathConflict => return runtime(ctx, "cannot update {s}: \"wmux\" or \"wmux.browser\" is not an object", .{wmux_path}),
            else => return runtime(ctx, "cannot update {s}: it is not valid JSON (fix or remove it first)", .{wmux_path}),
        };
        if (edited.changed and !files.writer.write(wmux_path, edited.text)) return runtime(ctx, "cannot write {s}", .{wmux_path});
        st.enabled = want;
    }
    if (ctx.json()) {
        try availability.writeJson(ctx.out, st);
    } else if (l == .status) {
        try ctx.out.writeAll(if (st.enabled) "enabled\n" else "disabled\n");
    } else {
        try ctx.out.print("{s} browser {s}\n", .{ ctx.brand.name(), if (st.enabled) "enabled" else "disabled" });
    }
    return output.exit.ok;
}
