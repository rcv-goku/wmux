//! Shared helpers of the cf-cli-misc command families (config, session,
//! layout_todo, open_files, right_sidebar): a small flag parser with cmux's
//! error wording, caller-context selector defaults (ADR-4.6), JSON params
//! building, one-call request/print helpers, handle text for `OK ...` lines
//! and a file-system hook for the writes, directory listings and directory
//! checks the `Platform` abstraction does not offer yet (see out/REPORT.md).

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const handles = proto.handles;
const idformat = proto.idformat;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const brand_mod = @import("../../brand.zig");
const client_mod = @import("../../client.zig");

// ----- flags -----

pub const FlagSpec = struct {
    name: []const u8,
    /// Takes a value (`--name v` or `--name=v`).
    value: bool = false,
    /// Alternate spelling stored under `name`.
    alias: ?[]const u8 = null,
};

pub const FlagHit = struct { name: []const u8, value: ?[]const u8 };

pub const Flags = struct {
    hits: []const FlagHit = &.{},
    positionals: []const []const u8 = &.{},
    /// Tokens after `--` (null when there was no terminator).
    payload: ?[]const []const u8 = null,

    /// Last value given for `name`.
    pub fn get(self: Flags, name: []const u8) ?[]const u8 {
        var out: ?[]const u8 = null;
        for (self.hits) |h| if (std.mem.eql(u8, h.name, name)) {
            out = h.value;
        };
        return out;
    }

    pub fn has(self: Flags, name: []const u8) bool {
        for (self.hits) |h| if (std.mem.eql(u8, h.name, name)) return true;
        return false;
    }

    /// Every value given for a repeatable flag.
    pub fn all(self: Flags, arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.hits) |h| if (std.mem.eql(u8, h.name, name)) {
            if (h.value) |v| try list.append(arena, v);
        };
        return list.items;
    }
};

pub const FlagError = error{ UnknownFlag, MissingValue, OutOfMemory };

/// Why `parseFlags` failed; `token` is the offending argument or flag.
pub const FlagDiag = struct { token: []const u8 = "" };

fn looksLikeFlag(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    // Negative numbers stay positional.
    if (std.ascii.isDigit(a[1])) return false;
    return true;
}

/// Parses `args` against `specs`. Unknown `-x`/`--x` tokens fail; `-` is a
/// positional; everything after `--` is payload.
pub fn parseFlags(arena: Allocator, args: []const []const u8, specs: []const FlagSpec, diag: *FlagDiag) FlagError!Flags {
    var hits: std.ArrayList(FlagHit) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var payload: ?[]const []const u8 = null;
    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            payload = args[i + 1 ..];
            break;
        }
        if (!looksLikeFlag(a)) {
            try pos.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = if (eq) |e| a[0..e] else a;
        for (specs) |s| {
            const match = std.mem.eql(u8, name, s.name) or (s.alias != null and std.mem.eql(u8, name, s.alias.?));
            if (!match) continue;
            if (!s.value) {
                if (eq != null) {
                    diag.token = a;
                    return error.UnknownFlag;
                }
                try hits.append(arena, .{ .name = s.name, .value = null });
                continue :outer;
            }
            if (eq) |e| {
                try hits.append(arena, .{ .name = s.name, .value = a[e + 1 ..] });
            } else {
                if (i + 1 >= args.len) {
                    diag.token = s.name;
                    return error.MissingValue;
                }
                i += 1;
                try hits.append(arena, .{ .name = s.name, .value = args[i] });
            }
            continue :outer;
        }
        diag.token = a;
        return error.UnknownFlag;
    }
    return .{ .hits = hits.items, .positionals = pos.items, .payload = payload };
}

/// `<prog>: <message>` plus the usage line on stderr; exit 2.
pub fn usageFail(ctx: *Ctx, usage: []const u8, comptime fmt: []const u8, a: anytype) u8 {
    const code = ctx.usageError(fmt, a);
    brand_mod.write(ctx.err, ctx.brand, usage) catch {};
    ctx.err.writeByte('\n') catch {};
    return code;
}

/// Parses flags, printing cmux's wording on failure (`<cmd>: unknown flag
/// '<x>'. Usage: ...`, `<flag> requires a value`). Null means exit 2.
pub fn flagsOrFail(ctx: *Ctx, label: []const u8, usage: []const u8, args: []const []const u8, specs: []const FlagSpec) Allocator.Error!?Flags {
    var diag: FlagDiag = .{};
    const u = try brand_mod.alloc(ctx.arena, ctx.brand, usage);
    return parseFlags(ctx.arena, args, specs, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownFlag => {
            _ = ctx.usageError("{s}: unknown flag '{s}'. {s}", .{ label, diag.token, u });
            return null;
        },
        error.MissingValue => {
            _ = ctx.usageError("{s}: {s} requires a value. {s}", .{ label, diag.token, u });
            return null;
        },
    };
}

// ----- selectors (ADR-4.6) -----

pub const Target = struct {
    window: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    surface: ?[]const u8 = null,
    pane: ?[]const u8 = null,
};

pub const TargetRules = struct {
    /// `--workspace` defaults to `CMUX_WORKSPACE_ID` unless a window is given.
    workspace_default: bool = true,
    /// `--surface` defaults to `CMUX_SURFACE_ID` unless `--workspace` or a
    /// window is given.
    surface_default: bool = false,
    /// `--pane` also suppresses the surface default (`open`).
    pane_blocks_surface_default: bool = false,
};

fn checkHandle(ctx: *Ctx, kind: handles.Kind, value: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, value, " \t\r\n");
    _ = handles.parseHandle(kind, t) catch |err| {
        const noun = kind.nounCapitalized();
        switch (err) {
            error.Blank => _ = ctx.usageError("{s} handle is blank", .{noun}),
            else => _ = ctx.usageError("Invalid {s} handle: {s} (expected UUID, ref like {s}:1, or index)", .{ kind.noun(), t, kind.name() }),
        }
        return null;
    };
    return t;
}

/// Explicit `--window/--workspace/--surface/--pane` flags (validated), else
/// the caller's environment per `rules`. Null: a usage error was printed.
pub fn resolveTarget(ctx: *Ctx, flags: Flags, rules: TargetRules) ?Target {
    var t: Target = .{};
    const window = flags.get("--window") orelse ctx.parsed.globals.window;
    if (window) |w| t.window = checkHandle(ctx, .window, w) orelse return null;
    const env_ws = ctx.env.first(&.{ env_names.CMUX_WORKSPACE_ID, env_names.WMUX_WORKSPACE_ID });
    const env_sf = ctx.env.first(&.{ env_names.CMUX_SURFACE_ID, env_names.WMUX_SURFACE_ID });
    if (flags.get("--workspace")) |w| {
        if (std.mem.trim(u8, w, " \t\r\n").len == 0) {
            if (env_ws == null or t.window != null) {
                _ = ctx.usageError("No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset", .{});
                return null;
            }
            t.workspace = env_ws;
        } else t.workspace = checkHandle(ctx, .workspace, w) orelse return null;
    } else if (rules.workspace_default and t.window == null) t.workspace = env_ws;
    if (flags.get("--pane")) |p| t.pane = checkHandle(ctx, .pane, p) orelse return null;
    if (flags.get("--surface")) |s| {
        t.surface = checkHandle(ctx, .surface, s) orelse return null;
    } else if (rules.surface_default and !flags.has("--workspace") and t.window == null and
        !(rules.pane_blocks_surface_default and t.pane != null))
    {
        t.surface = env_sf;
    }
    return t;
}

// ----- params -----

/// An insertion-ordered JSON object for request params.
pub const Params = struct {
    obj: std.json.ObjectMap,

    pub fn init(arena: Allocator) Params {
        return .{ .obj = std.json.ObjectMap.init(arena) };
    }

    pub fn put(self: *Params, key: []const u8, v: std.json.Value) Allocator.Error!void {
        try self.obj.put(key, v);
    }

    pub fn str(self: *Params, key: []const u8, v: []const u8) Allocator.Error!void {
        try self.obj.put(key, .{ .string = v });
    }

    pub fn optStr(self: *Params, key: []const u8, v: ?[]const u8) Allocator.Error!void {
        if (v) |x| try self.str(key, x);
    }

    pub fn boolean(self: *Params, key: []const u8, v: bool) Allocator.Error!void {
        try self.obj.put(key, .{ .bool = v });
    }

    pub fn int(self: *Params, key: []const u8, v: i64) Allocator.Error!void {
        try self.obj.put(key, .{ .integer = v });
    }

    pub fn float(self: *Params, key: []const u8, v: f64) Allocator.Error!void {
        try self.obj.put(key, .{ .float = v });
    }

    pub fn strings(self: *Params, key: []const u8, list: []const []const u8) Allocator.Error!void {
        var arr = std.json.Array.init(self.obj.allocator);
        for (list) |x| try arr.append(.{ .string = x });
        try self.obj.put(key, .{ .array = arr });
    }

    /// `window_id`, `workspace_id`, `pane_id`, `surface_id` when set.
    pub fn target(self: *Params, t: Target) Allocator.Error!void {
        try self.optStr("window_id", t.window);
        try self.optStr("workspace_id", t.workspace);
        try self.optStr("pane_id", t.pane);
        try self.optStr("surface_id", t.surface);
    }

    pub fn json(self: *const Params, arena: Allocator) Allocator.Error![]const u8 {
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = self.obj }, .{});
    }
};

// ----- calls and output -----

/// One request; prints the error and returns null on failure (exit 1).
pub fn call(ctx: *Ctx, method: []const u8, params: ?*const Params) !?std.json.Value {
    const pj: ?[]const u8 = if (params) |p| try p.json(ctx.arena) else null;
    const out = (try ctx.call(method, pj)) orelse return null;
    switch (out) {
        .ok => |ok| return ok.result,
        else => {
            _ = try ctx.reportError(method, out);
            return null;
        },
    }
}

/// `--json`: the id-formatted result, pretty.
pub fn writeJsonResult(ctx: *Ctx, v: std.json.Value) !void {
    try output.writeResult(ctx.arena, ctx.out, v, ctx.parsed.globals.id_format);
}

/// Calls `method` and prints the JSON result with `--json`, else `text`
/// (rebranded) followed by a newline when `text` is not empty.
pub fn callSimple(ctx: *Ctx, method: []const u8, params: ?*const Params, text: []const u8) !u8 {
    const r = (try call(ctx, method, params)) orelse return output.exit.runtime;
    if (ctx.json()) {
        try writeJsonResult(ctx, r);
    } else if (text.len > 0) {
        try ctx.print(text);
        try ctx.out.writeByte('\n');
    }
    return output.exit.ok;
}

pub fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn fieldStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

pub fn fieldInt(v: std.json.Value, key: []const u8) ?i64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| if (@floor(x) == x and @abs(x) < 1e15) @intFromFloat(x) else null,
        else => null,
    };
}

/// Handle text for `<kind>_ref`/`<kind>_id` of `v` in the `--id-format`
/// mode (refs by default), or null when the result has neither.
pub fn handleText(ctx: *Ctx, v: std.json.Value, comptime kind: []const u8) !?[]const u8 {
    const ref = fieldStr(v, kind ++ "_ref");
    const id = fieldStr(v, kind ++ "_id");
    if (ref == null and id == null) return null;
    return try idformat.handleTextAlloc(ctx.arena, ctx.parsed.globals.id_format, ref, id, .{});
}

/// The rebranded `msg` on stdout plus a newline.
pub fn printLine(ctx: *Ctx, msg: []const u8) !void {
    try ctx.print(msg);
    try ctx.out.writeByte('\n');
}

// ----- paths -----

/// `~` / `~/x` / `~\x` expanded with `USERPROFILE` (Windows) or `HOME`, then
/// made absolute against the CLI's cwd. No file-system access.
pub fn resolvePath(ctx: *Ctx, p: []const u8) Allocator.Error![]const u8 {
    const style = proto.paths.Style.native;
    var path = p;
    if (p.len > 0 and p[0] == '~' and (p.len == 1 or p[1] == '/' or p[1] == '\\')) {
        const home = if (style == .windows) ctx.env.getNonEmpty(env_names.USERPROFILE) else ctx.env.getNonEmpty(env_names.HOME);
        if (home) |h| path = if (p.len <= 2) h else try proto.paths.join(ctx.arena, style, &.{ h, p[2..] });
    }
    if (isAbsolute(path)) return path;
    const cwd = ctx.platform.cwd(ctx.arena) orelse return path;
    if (std.mem.eql(u8, path, ".")) return cwd;
    return proto.paths.join(ctx.arena, style, &.{ cwd, path });
}

pub fn isAbsolute(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    if (std.mem.startsWith(u8, p, "\\\\")) return true;
    return builtin.os.tag != .windows and p.len > 0 and p[0] == '/';
}

// ----- file-system hook -----

pub const WriteError = error{ WriteFailed, OutOfMemory };

/// Writes, directory listings and directory checks (reads go through
/// `Platform.readFile`). Tests swap in an in-memory implementation.
pub const Fs = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Creates parent directories and replaces `path` atomically.
        writeFile: *const fn (ptr: ?*anyopaque, arena: Allocator, path: []const u8, bytes: []const u8) WriteError!void,
        /// Entry names of a directory, or null when it cannot be listed.
        listDir: *const fn (ptr: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const []const u8,
        isDir: *const fn (ptr: ?*anyopaque, path: []const u8) bool,
    };

    pub fn writeFile(f: Fs, arena: Allocator, path: []const u8, bytes: []const u8) WriteError!void {
        return f.vtable.writeFile(f.ptr, arena, path, bytes);
    }

    pub fn listDir(f: Fs, arena: Allocator, path: []const u8) ?[]const []const u8 {
        return f.vtable.listDir(f.ptr, arena, path);
    }

    pub fn isDir(f: Fs, path: []const u8) bool {
        return f.vtable.isDir(f.ptr, path);
    }
};

/// The process-wide hook (tests replace it and restore `native_fs`).
pub var fs: Fs = native_fs;

pub const native_fs: Fs = .{ .vtable = &.{ .writeFile = nativeWrite, .listDir = nativeList, .isDir = nativeIsDir } };

fn nativeWrite(_: ?*anyopaque, arena: Allocator, path: []const u8, bytes: []const u8) WriteError!void {
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.makePath(d) catch return error.WriteFailed;
    var rnd: [6]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const tmp = try std.fmt.allocPrint(arena, "{s}.wmux-tmp-{x}", .{ path, rnd });
    cwd.writeFile(.{ .sub_path = tmp, .data = bytes }) catch return error.WriteFailed;
    std.fs.rename(cwd, tmp, cwd, path) catch {
        cwd.deleteFile(tmp) catch {};
        return error.WriteFailed;
    };
}

fn nativeList(_: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const []const u8 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next() catch return null) |e| {
        names.append(arena, arena.dupe(u8, e.name) catch return null) catch return null;
    }
    return names.items;
}

fn nativeIsDir(_: ?*anyopaque, path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

// ----- focus -----

pub const focus_value_message = "--focus must be true|false";

/// `--no-focus` (wins) or `--focus <true|false>`; null when neither was
/// given. The caller falls back to its default.
pub fn explicitFocus(flags: Flags) error{InvalidFocusValue}!?bool {
    if (flags.has("--no-focus")) return false;
    const v = flags.get("--focus") orelse return null;
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return error.InvalidFocusValue;
}

/// Directory of the nearest `.git` at or above `start` (no git process).
pub fn gitRoot(ctx: *Ctx, start: []const u8) Allocator.Error!?[]const u8 {
    const style = proto.paths.Style.native;
    var d = start;
    while (true) {
        const marker = try proto.paths.join(ctx.arena, style, &.{ d, ".git" });
        if (ctx.platform.pathExists(marker)) return d;
        const parent = proto.paths.dirname(style, d) orelse return null;
        // The root is its own parent.
        if (parent.len >= d.len) return null;
        d = parent;
    }
}

/// `text` with the brand applied (`cmux` → `wmux` when invoked as wmux).
pub fn branded(ctx: *Ctx, text: []const u8) Allocator.Error![]const u8 {
    return brand_mod.alloc(ctx.arena, ctx.brand, text);
}
