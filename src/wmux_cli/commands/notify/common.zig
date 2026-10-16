//! Shared pieces of the `notify`, `sidebar_meta` and `events` families:
//! a strict cmux-style option scanner, target selection with cmux's handle
//! errors (ADR-4.6), a params builder, `OK`/`--json` output helpers, the
//! foreground grant for focus-intent commands (ADR-3.11) and a small file
//! hook for the commands that touch files (`feed clear`, `events
//! --cursor-file`), which the `Platform` interface does not cover yet.

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const handles = proto.handles;
const selectors = proto.selectors;
const Allocator = std.mem.Allocator;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const focus_default = @import("../../focus_default.zig");
const brand_mod = @import("../../brand.zig");

/// The first line of a help text (its `Usage:` line).
pub fn usageOf(comptime help: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        return help[0 .. std.mem.indexOfScalar(u8, help, '\n') orelse help.len];
    }
}

// ----- option scanning -----

pub const OptKind = enum { value, flag };

/// One accepted option. `canonical` folds aliases (`--tab` → `--workspace`).
pub const Opt = struct {
    name: []const u8,
    kind: OptKind = .value,
    canonical: ?[]const u8 = null,

    fn key(o: Opt) []const u8 {
        return o.canonical orelse o.name;
    }
};

/// One option occurrence, under its canonical name.
pub const Hit = struct { name: []const u8, value: ?[]const u8 };

pub const Problem = union(enum) {
    /// Unknown option, stray positional, misplaced `--` (the tokens).
    unexpected: []const []const u8,
    /// `--opt` at the end, or followed by a token starting with `--`.
    missing_value: []const u8,
    /// `--opt=` with nothing after `=`.
    empty_value: []const u8,
};

pub const Mode = struct {
    /// Tokens not starting with `--` are positionals (else unexpected).
    positionals: bool = true,
    /// `--` must be the final token (cmux `notify`).
    dashdash_last_only: bool = false,
};

pub const Scanned = struct {
    hits: []const Hit = &.{},
    positionals: []const []const u8 = &.{},

    /// Last value of `name` (canonical spelling).
    pub fn get(self: Scanned, name: []const u8) ?[]const u8 {
        var out: ?[]const u8 = null;
        for (self.hits) |h| if (std.mem.eql(u8, h.name, name)) {
            out = h.value;
        };
        return out;
    }

    pub fn has(self: Scanned, name: []const u8) bool {
        for (self.hits) |h| if (std.mem.eql(u8, h.name, name)) return true;
        return false;
    }

    /// Every value of a repeatable option, in order.
    pub fn all(self: Scanned, arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.hits) |h| if (std.mem.eql(u8, h.name, name)) {
            if (h.value) |v| try list.append(arena, v);
        };
        return list.items;
    }
};

pub const ScanResult = union(enum) { ok: Scanned, problem: Problem };

fn findOpt(opts: []const Opt, name: []const u8) ?Opt {
    for (opts) |o| if (std.mem.eql(u8, o.name, name)) return o;
    return null;
}

/// Scans `argv` (the command's arguments). Value options take `--opt value`
/// or `--opt=value`; flags reject `=value`; everything after `--` is
/// positional. Unexpected tokens are collected so the error names them all.
pub fn scan(arena: Allocator, argv: []const []const u8, opts: []const Opt, mode: Mode) Allocator.Error!ScanResult {
    var hits: std.ArrayList(Hit) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var bad: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            if (mode.dashdash_last_only) {
                if (i + 1 != argv.len) try bad.append(arena, a);
                continue;
            }
            for (argv[i + 1 ..]) |rest| {
                if (mode.positionals) try pos.append(arena, rest) else try bad.append(arena, rest);
            }
            break;
        }
        const is_opt = std.mem.startsWith(u8, a, "--") or (a.len > 1 and a[0] == '-' and findOpt(opts, a) != null);
        if (!is_opt) {
            if (mode.positionals) try pos.append(arena, a) else try bad.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = if (eq) |e| a[0..e] else a;
        const opt = findOpt(opts, name) orelse {
            try bad.append(arena, a);
            continue;
        };
        switch (opt.kind) {
            .flag => {
                if (eq != null) {
                    try bad.append(arena, a);
                    continue;
                }
                try hits.append(arena, .{ .name = opt.key(), .value = null });
            },
            .value => {
                if (eq) |e| {
                    const v = a[e + 1 ..];
                    if (v.len == 0) return .{ .problem = .{ .empty_value = name } };
                    try hits.append(arena, .{ .name = opt.key(), .value = v });
                } else {
                    if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "--"))
                        return .{ .problem = .{ .missing_value = name } };
                    i += 1;
                    try hits.append(arena, .{ .name = opt.key(), .value = argv[i] });
                }
            },
        }
    }
    if (bad.items.len > 0) return .{ .problem = .{ .unexpected = bad.items } };
    return .{ .ok = .{ .hits = hits.items, .positionals = pos.items } };
}

/// Prints a scan problem in cmux's wording (`<cmd>: unexpected arguments:
/// <args>`, `<cmd>: --opt requires a value`); exit code 2.
pub fn reportProblem(ctx: *Ctx, cmd: []const u8, p: Problem) u8 {
    switch (p) {
        .unexpected => |toks| {
            const joined = std.mem.join(ctx.arena, " ", toks) catch "";
            return ctx.usageError("{s}: unexpected arguments: {s}", .{ cmd, joined });
        },
        .missing_value, .empty_value => |name| return ctx.usageError("{s}: {s} requires a value", .{ cmd, name }),
    }
}

/// Scans or prints the problem; null means "exit with the returned code".
pub fn scanOrReport(ctx: *Ctx, cmd: []const u8, opts: []const Opt, mode: Mode, code: *u8) !?Scanned {
    switch (try scan(ctx.arena, ctx.args(), opts, mode)) {
        .ok => |s| return s,
        .problem => |p| {
            code.* = reportProblem(ctx, cmd, p);
            return null;
        },
    }
}

/// cmux's boolean words (`true/false`, `1/0`, `yes/no`), any case.
pub fn parseBool(s: []const u8) ?bool {
    const t = std.mem.trim(u8, s, " \t");
    for ([_][]const u8{ "true", "1", "yes" }) |w| if (std.ascii.eqlIgnoreCase(t, w)) return true;
    for ([_][]const u8{ "false", "0", "no" }) |w| if (std.ascii.eqlIgnoreCase(t, w)) return false;
    return null;
}

// ----- targets (ADR-4.6) -----

pub fn envWorkspace(ctx: *const Ctx) ?[]const u8 {
    return ctx.env.first(&.{ env_names.CMUX_WORKSPACE_ID, env_names.WMUX_WORKSPACE_ID });
}

pub fn envSurface(ctx: *const Ctx) ?[]const u8 {
    return ctx.env.first(&.{ env_names.CMUX_SURFACE_ID, env_names.WMUX_SURFACE_ID });
}

/// Inside tmux the env surface names the pane hosting tmux, not the caller.
pub fn insideTmux(ctx: *const Ctx) bool {
    return ctx.env.getNonEmpty("TMUX") != null;
}

/// Resolved selectors, as trimmed handle text the router accepts (UUID, ref
/// or index). `*_explicit` tells a flag from an environment default.
pub const Target = struct {
    window: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    surface: ?[]const u8 = null,
    workspace_explicit: bool = false,
    surface_explicit: bool = false,

    /// Writes the present selectors as `window_id`/`workspace_id`/`surface_id`.
    pub fn put(self: Target, p: *Params) !void {
        if (self.window) |w| try p.str("window_id", w);
        if (self.workspace) |w| try p.str("workspace_id", w);
        if (self.surface) |s| try p.str("surface_id", s);
    }
};

pub const TargetRules = struct {
    /// Default the workspace to `CMUX_WORKSPACE_ID` when neither
    /// `--workspace` nor `--window` is given.
    env_workspace: bool = true,
    /// Default the surface to `CMUX_SURFACE_ID` under the same condition.
    env_surface: bool = false,
    /// Ignore the env surface inside tmux.
    tmux_ignores_env_surface: bool = true,
};

/// Validates one explicit handle; prints cmux's message and returns the exit
/// code on failure.
pub fn checkHandle(ctx: *Ctx, kind: handles.Kind, text: []const u8) ?u8 {
    _ = handles.parseHandle(kind, text) catch |err| {
        const msg = selectors.cliMessage(ctx.arena, selectors.cliProblemFor(err), kind, std.mem.trim(u8, text, " \t\r\n")) catch "invalid handle";
        return ctx.usageError("{s}", .{msg});
    };
    return null;
}

/// Builds the target from `--window`/`--workspace`/`--surface` (the global
/// `--window` counts when the command has none) and the caller environment.
pub fn resolveTarget(ctx: *Ctx, s: Scanned, rules: TargetRules, code: *u8) ?Target {
    var t: Target = .{};
    const win = s.get("--window") orelse ctx.parsed.globals.window;
    const ws = s.get("--workspace");
    const sf = s.get("--surface");
    if (win) |w| {
        if (checkHandle(ctx, .window, w)) |c| return fail(code, c);
        t.window = std.mem.trim(u8, w, " \t\r\n");
    }
    if (ws) |w| {
        if (std.mem.trim(u8, w, " \t\r\n").len == 0) {
            // A blank --workspace falls back to the caller's workspace.
            t.workspace = envWorkspace(ctx) orelse {
                code.* = ctx.usageError("No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset", .{});
                return null;
            };
        } else {
            if (checkHandle(ctx, .workspace, w)) |c| return fail(code, c);
            t.workspace = std.mem.trim(u8, w, " \t\r\n");
            t.workspace_explicit = true;
        }
    }
    if (sf) |x| {
        if (checkHandle(ctx, .surface, x)) |c| return fail(code, c);
        t.surface = std.mem.trim(u8, x, " \t\r\n");
        t.surface_explicit = true;
    }
    const scoped = ws != null or win != null;
    if (!scoped) {
        if (rules.env_workspace) t.workspace = envWorkspace(ctx);
        if (rules.env_surface and t.surface == null and !(rules.tmux_ignores_env_surface and insideTmux(ctx)))
            t.surface = envSurface(ctx);
    }
    return t;
}

fn fail(code: *u8, c: u8) ?Target {
    code.* = c;
    return null;
}

// ----- params -----

/// An ordered JSON object for request params.
pub const Params = struct {
    arena: Allocator,
    map: std.json.ObjectMap,

    pub fn init(arena: Allocator) Params {
        return .{ .arena = arena, .map = std.json.ObjectMap.init(arena) };
    }

    pub fn str(self: *Params, k: []const u8, v: []const u8) !void {
        try self.map.put(k, .{ .string = v });
    }

    pub fn boolean(self: *Params, k: []const u8, v: bool) !void {
        try self.map.put(k, .{ .bool = v });
    }

    pub fn int(self: *Params, k: []const u8, v: i64) !void {
        try self.map.put(k, .{ .integer = v });
    }

    pub fn float(self: *Params, k: []const u8, v: f64) !void {
        try self.map.put(k, .{ .float = v });
    }

    pub fn value(self: *Params, k: []const u8, v: std.json.Value) !void {
        try self.map.put(k, v);
    }

    pub fn strings(self: *Params, k: []const u8, items: []const []const u8) !void {
        var arr = std.json.Array.init(self.arena);
        for (items) |s| try arr.append(.{ .string = s });
        try self.map.put(k, .{ .array = arr });
    }

    /// A nested object (`caller`, `effects`).
    pub fn object(self: *Params, k: []const u8, child: Params) !void {
        try self.map.put(k, .{ .object = child.map });
    }

    pub fn json(self: *const Params) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.arena, std.json.Value{ .object = self.map }, .{});
    }
};

/// `{"workspace_id":…,"surface_id":…}` from the caller environment (ADR-3.9);
/// an empty object outside wmux terminals.
pub fn callerObject(ctx: *Ctx) Params {
    var c = Params.init(ctx.arena);
    if (envWorkspace(ctx)) |w| c.str("workspace_id", w) catch {};
    if (envSurface(ctx)) |s| c.str("surface_id", s) catch {};
    return c;
}

// ----- calls and output -----

/// Sends one request; prints connection and RPC errors. Null means the
/// caller exits 1.
pub fn request(ctx: *Ctx, method: []const u8, p: ?*const Params) !?std.json.Value {
    const body: ?[]const u8 = if (p) |x| try x.json() else null;
    const out = (try ctx.call(method, body)) orelse return null;
    switch (out) {
        .ok => |ok| return ok.result,
        else => {
            _ = try ctx.reportError(method, out);
            return null;
        },
    }
}

/// `OK`, or the id-formatted result with `--json`.
pub fn printOk(ctx: *Ctx, result: std.json.Value) !u8 {
    if (ctx.json()) {
        try output.writeResult(ctx.arena, ctx.out, result, ctx.parsed.globals.id_format);
    } else try ctx.out.writeAll("OK\n");
    return output.exit.ok;
}

/// The common shape: one request, then `OK` / `--json`.
pub fn callOk(ctx: *Ctx, method: []const u8, p: ?*const Params) !u8 {
    const r = (try request(ctx, method, p)) orelse return output.exit.runtime;
    return printOk(ctx, r);
}

pub fn field(v: std.json.Value, k: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(k),
        else => null,
    };
}

/// A string field, null when absent, null-valued or empty.
pub fn strField(v: std.json.Value, k: []const u8) ?[]const u8 {
    const f = field(v, k) orelse return null;
    return switch (f) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

pub fn boolField(v: std.json.Value, k: []const u8) ?bool {
    const f = field(v, k) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

pub fn arrayField(v: std.json.Value, k: []const u8) ?[]const std.json.Value {
    const f = field(v, k) orelse return null;
    return switch (f) {
        .array => |a| a.items,
        else => null,
    };
}

/// First present array among `keys`.
pub fn firstArray(v: std.json.Value, keys: []const []const u8) []const std.json.Value {
    for (keys) |k| if (arrayField(v, k)) |a| return a;
    return &.{};
}

/// Writes the `<kind>_ref`/`<kind>_id` handle of `v` per `--id-format`;
/// false when neither is present.
pub fn writeHandleOf(ctx: *Ctx, w: *std.Io.Writer, v: std.json.Value, kind: handles.Kind) !bool {
    const ref = strField(v, kind.refKey());
    const id = strField(v, kind.idKey());
    if (ref == null and id == null) return false;
    try proto.idformat.writeHandle(w, ctx.parsed.globals.id_format, ref, id, .{});
    return true;
}

/// `OK <workspace> <surface>` for focus-intent results.
pub fn printOpened(ctx: *Ctx, result: std.json.Value) !void {
    try ctx.out.writeAll("OK");
    for ([_]handles.Kind{ .workspace, .surface }) |k| {
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        if (try writeHandleOf(ctx, &aw.writer, result, k)) try ctx.out.print(" {s}", .{aw.written()});
    }
    try ctx.out.writeByte('\n');
}

/// For focus-intent requests from an interactive, non-agent caller: lets the
/// app take the foreground with `AllowSetForegroundWindow(server_pid)` and
/// marks the request `focus:true, foreground_grant:true` (ADR-3.11). The
/// pipe is opened here when discovery did not open it (`--socket`, or
/// `CMUX_SOCKET_PATH`, which every wmux terminal sets), so the server PID is
/// known; an open failure is left for the request to report. False when
/// discovery found no app; the error is already printed and the caller exits
/// 1 (connecting again would print it twice).
pub fn grantForeground(ctx: *Ctx, p: *Params) !bool {
    if (!focus_default.defaultFocus(ctx.platform.isInteractive(), ctx.env, ctx.env_names)) return true;
    const c = (try ctx.connect()) orelse return false;
    if (c.conn == null) {
        const t = ctx.platform.connect(c.gpa, c.opts.path, c.opts.connect_timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return true,
        };
        c.adopt(t);
    }
    const pid = c.conn.?.serverPid() orelse return true;
    ctx.platform.allowForeground(pid);
    try p.boolean("focus", true);
    try p.boolean("foreground_grant", true);
    return true;
}

/// Writes `text` rebranded and a newline to stderr; exit code 1.
pub fn runtimeText(ctx: *Ctx, text: []const u8) u8 {
    brand_mod.write(ctx.err, ctx.brand, text) catch {};
    ctx.err.writeByte('\n') catch {};
    return output.exit.runtime;
}

// ----- file hook -----

/// File effects the `Platform` vtable lacks (framework follow-up: add
/// `deleteFile`/`writeFile` to `Platform`). Tests swap `files`.
pub const FileOps = struct {
    delete: *const fn (path: []const u8) anyerror!void,
    write: *const fn (path: []const u8, bytes: []const u8) anyerror!void,
};

fn nativeDelete(path: []const u8) anyerror!void {
    try std.fs.cwd().deleteFile(path);
}

/// A temp file renamed over `path`: a run stopped mid-write (`events` is
/// stopped with Ctrl+C) never leaves a torn or empty cursor file behind.
fn nativeWrite(path: []const u8, bytes: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    var af = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer af.deinit();
    af.file_writer.interface.writeAll(bytes) catch return af.file_writer.err orelse error.WriteFailed;
    try af.finish();
}

pub var files: FileOps = .{ .delete = nativeDelete, .write = nativeWrite };

// ----- prompt answers -----

/// Reads the answer line of a `[y/N]` prompt from stdin. `Platform.readStdin`
/// reads to EOF, which a console (or a mintty pipe) only sends on Ctrl+Z or
/// Ctrl+D, so prompts read one line instead (framework follow-up:
/// `Platform.readLine`). The test harness swaps this hook.
pub var read_answer: *const fn (ctx: *Ctx, max: usize) []const u8 = nativeReadAnswer;

fn nativeReadAnswer(ctx: *Ctx, max: usize) []const u8 {
    return readLineFrom(ctx.arena, max, std.fs.File.stdin());
}

/// Bytes of `src` up to the first newline (excluded) or EOF, at most `max`.
/// Reads one byte at a time, so nothing after the line is consumed; a read
/// error ends the line.
pub fn readLineFrom(arena: Allocator, max: usize, src: anytype) []const u8 {
    var line: std.ArrayList(u8) = .empty;
    var byte: [1]u8 = undefined;
    while (line.items.len < max) {
        const n = src.read(&byte) catch break;
        if (n == 0 or byte[0] == '\n') break;
        line.append(arena, byte[0]) catch break;
    }
    return line.items;
}

const testing = std.testing;

const t_opts = [_]Opt{
    .{ .name = "--title" },
    .{ .name = "--reply", .kind = .flag },
    .{ .name = "--tab", .canonical = "--workspace" },
    .{ .name = "--workspace" },
    .{ .name = "-y", .kind = .flag, .canonical = "--yes" },
};

fn scanT(arena: Allocator, argv: []const []const u8, mode: Mode) !ScanResult {
    return scan(arena, argv, &t_opts, mode);
}

test "unit: cli-notify-common: scan values, flags, aliases and positionals" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const r = (try scanT(a, &.{ "--title", "a b", "pos", "--title=\u{1F600}", "--reply", "--tab", "2", "-y", "-0.5", "--", "--title", "x" }, .{})).ok;
    try testing.expectEqualStrings("\u{1F600}", r.get("--title").?);
    try testing.expect(r.has("--reply") and r.has("--yes"));
    try testing.expectEqualStrings("2", r.get("--workspace").?);
    try testing.expectEqual(@as(usize, 2), (try r.all(a, "--title")).len);
    try testing.expectEqual(@as(usize, 4), r.positionals.len);
    try testing.expectEqualStrings("-0.5", r.positionals[1]);
    try testing.expectEqualStrings("--title", r.positionals[2]);
    const empty = (try scanT(a, &.{}, .{})).ok;
    try testing.expect(empty.get("--title") == null and empty.positionals.len == 0);
}

test "unit: cli-notify-common: scan problems" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try testing.expectEqualStrings("--title", (try scanT(a, &.{"--title"}, .{})).problem.missing_value);
    try testing.expectEqualStrings("--title", (try scanT(a, &.{ "--title", "--reply" }, .{})).problem.missing_value);
    try testing.expectEqualStrings("--title", (try scanT(a, &.{"--title="}, .{})).problem.empty_value);
    const u = (try scanT(a, &.{ "--reply=1", "x", "--nope", "-z" }, .{ .positionals = false })).problem.unexpected;
    try testing.expectEqual(@as(usize, 4), u.len);
    try testing.expectEqualStrings("--reply=1", u[0]);
    try testing.expectEqualStrings("-z", u[3]);
    const d = (try scanT(a, &.{ "--", "--reply" }, .{ .dashdash_last_only = true })).problem.unexpected;
    try testing.expectEqualStrings("--", d[0]);
    try testing.expect((try scanT(a, &.{ "--reply", "--" }, .{ .dashdash_last_only = true })) == .ok);
    try testing.expectEqual(@as(?bool, true), parseBool(" YES "));
    try testing.expectEqual(@as(?bool, false), parseBool("0"));
    try testing.expectEqual(@as(?bool, null), parseBool("maybe"));
    try testing.expectEqual(@as(?bool, null), parseBool(""));
}

test "unit: cli-notify-common: native writes replace the whole file and leave no temp file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "events.seq" });
    defer testing.allocator.free(path);
    try nativeWrite(path, "18446744073709551615\n");
    try nativeWrite(path, "7\n");
    const got = try tmp.dir.readFileAlloc(testing.allocator, "events.seq", 64);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("7\n", got);
    var n: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);
    try nativeDelete(path);
    try testing.expectError(error.FileNotFound, tmp.dir.access("events.seq", .{}));
}

const ByteSource = struct {
    data: []const u8,
    pos: usize = 0,
    fail_at: ?usize = null,

    fn read(self: *ByteSource, buf: []u8) error{ReadFailed}!usize {
        if (self.fail_at) |f| if (self.pos == f) return error.ReadFailed;
        const n = @min(buf.len, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

test "unit: cli-notify-common: prompt answers stop at the first newline" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    // A console line ends in CRLF; nothing after the line is consumed.
    var con: ByteSource = .{ .data = "y\r\nrm -rf /\n" };
    try testing.expectEqualStrings("y\r", readLineFrom(a, 64, &con));
    try testing.expectEqual(@as(usize, 3), con.pos);
    var eof: ByteSource = .{ .data = "" };
    try testing.expectEqualStrings("", readLineFrom(a, 64, &eof));
    var no_nl: ByteSource = .{ .data = "Yes \u{1F600}" };
    try testing.expectEqualStrings("Yes \u{1F600}", readLineFrom(a, 64, &no_nl));
    var long: ByteSource = .{ .data = "abcdef\n" };
    try testing.expectEqualStrings("ab", readLineFrom(a, 2, &long));
    var broken: ByteSource = .{ .data = "yes\n", .fail_at = 1 };
    try testing.expectEqualStrings("y", readLineFrom(a, 64, &broken));
}

test "unit: cli-notify-common: params keep insertion order" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    var p = Params.init(st.allocator());
    try p.str("b", "x\"y");
    try p.int("a", -1);
    try p.boolean("c", true);
    try p.strings("d", &.{ "1", "\u{e9}" });
    var child = Params.init(st.allocator());
    try child.float("v", 0.25);
    try p.object("e", child);
    try testing.expectEqualStrings("{\"b\":\"x\\\"y\",\"a\":-1,\"c\":true,\"d\":[\"1\",\"\u{e9}\"],\"e\":{\"v\":0.25}}", try p.json());
}
