//! RPC registry [frozen] (ARCHITECTURE.md ADR-1.4, ADR-3.6; written in
//! W0-A3). Aggregates, in manifest order, the tables every feature
//! declares in its `features/<id>/mod.zig`:
//!
//!     pub const rpc_methods = ...;      // []const rpc.Method       → all_methods, by_name
//!     pub const legacy_commands = ...;  // []const rpc.LegacyCommand → legacy_commands
//!     pub const text_verbs = ...;       // []const rpc.TextVerb      → text_verbs
//!
//! Comptime checks (`@compileError` naming the offender): no duplicate
//! method name, legacy command or text verb (verbs case-insensitively);
//! no empty name; `test_only` methods are `wmux.debug.*`; every legacy
//! command names a `legacy_json.Command` and every such command has
//! exactly one handler (the guarantee the old exhaustive switch in
//! `App.handleIpcRequest` gave). No codegen, no runtime registration:
//! adding an entry to a feature's table is the whole registration.

const std = @import("std");

const legacy_json = @import("compat/legacy_json.zig");
const manifest = @import("../features/manifest.zig");
const types = @import("types.zig");

/// The registry over `modules` (a tuple of feature `mod.zig` namespaces).
/// The app instance aggregates `features/manifest.zig`; the unit tests
/// instantiate it over test modules.
pub fn Registry(comptime modules: anytype) type {
    return struct {
        const Self = @This();

        const methods_array = collect(types.Method, modules, "rpc_methods");
        const legacy_array = collect(types.LegacyCommand, modules, "legacy_commands");
        const verbs_array = collect(types.TextVerb, modules, "text_verbs");

        /// Every v2 method, in manifest order.
        pub const all_methods: []const types.Method = &methods_array;

        /// Every legacy wmux-v1 JSON command, in manifest order.
        pub const legacy_commands: []const types.LegacyCommand = &legacy_array;

        /// Every cmux text-v1 verb, in manifest order.
        pub const text_verbs: []const types.TextVerb = &verbs_array;

        /// Method by exact name.
        pub const by_name = std.StaticStringMap(*const types.Method).initComptime(blk: {
            var kvs: [methods_array.len]struct { []const u8, *const types.Method } = undefined;
            for (&methods_array, 0..) |*m, i| kvs[i] = .{ m.name, m };
            break :blk kvs;
        });

        const legacy_by_name = std.StaticStringMap(*const types.LegacyCommand).initComptime(blk: {
            var kvs: [legacy_array.len]struct { []const u8, *const types.LegacyCommand } = undefined;
            for (&legacy_array, 0..) |*c, i| kvs[i] = .{ c.cmd, c };
            break :blk kvs;
        });

        comptime {
            @setEvalBranchQuota(1_000_000);
            for (methods_array) |m| checkMethod(m);
            if (firstDuplicate(namesOf(types.Method, &methods_array, "name"), false)) |dup|
                @compileError("rpc/registry.zig: duplicate rpc method '" ++ dup ++ "' in the features' rpc_methods");
            for (legacy_array) |c| {
                if (c.cmd.len == 0) @compileError("rpc/registry.zig: legacy command with an empty name");
            }
            if (firstDuplicate(namesOf(types.LegacyCommand, &legacy_array, "cmd"), false)) |dup|
                @compileError("rpc/registry.zig: duplicate legacy command '" ++ dup ++ "' in the features' legacy_commands");
            for (verbs_array) |v| {
                if (v.name.len == 0) @compileError("rpc/registry.zig: text verb with an empty name");
            }
            if (firstDuplicate(namesOf(types.TextVerb, &verbs_array, "name"), true)) |dup|
                @compileError("rpc/registry.zig: duplicate text verb '" ++ dup ++ "' in the features' text_verbs");
        }

        /// The v2 method named `name`.
        pub fn method(name: []const u8) ?*const types.Method {
            return Self.by_name.get(name);
        }

        /// The legacy command named `name`.
        pub fn legacyByName(name: []const u8) ?*const types.LegacyCommand {
            return Self.legacy_by_name.get(name);
        }

        /// The text verb named `name` (ASCII case-insensitive).
        pub fn textVerb(name: []const u8) ?*const types.TextVerb {
            for (Self.text_verbs) |*v| {
                if (std.ascii.eqlIgnoreCase(v.name, name)) return v;
            }
            return null;
        }
    };
}

/// The app registry: every feature of features/manifest.zig.
pub const app = Registry(manifest.modules);

pub const all_methods = app.all_methods;
pub const by_name = app.by_name;
pub const legacy_commands = app.legacy_commands;
pub const text_verbs = app.text_verbs;
pub const method = app.method;
pub const textVerb = app.textVerb;

const command_count = @typeInfo(legacy_json.Command).@"enum".fields.len;

/// Every legacy command's entry, indexed by `@intFromEnum(legacy_json.Command)`.
const by_command: [command_count]*const types.LegacyCommand = blk: {
    @setEvalBranchQuota(1_000_000);
    var result: [command_count]*const types.LegacyCommand = undefined;
    var seen: [command_count]bool = @splat(false);
    for (app.legacy_commands) |*entry| {
        const cmd = std.meta.stringToEnum(legacy_json.Command, entry.cmd) orelse
            @compileError("rpc/registry.zig: legacy command table names unknown command: " ++ entry.cmd);
        seen[@intFromEnum(cmd)] = true;
        result[@intFromEnum(cmd)] = entry;
    }
    for (seen, 0..) |ok, idx| {
        if (!ok) @compileError("rpc/registry.zig: legacy command has no handler: " ++
            @tagName(@as(legacy_json.Command, @enumFromInt(idx))));
    }
    break :blk result;
};

/// The entry of a parsed legacy command. Total: `legacy_json.parseLine`
/// only yields known commands and the comptime check above guarantees an
/// entry each.
pub fn legacyCommand(cmd: legacy_json.Command) *const types.LegacyCommand {
    return by_command[@intFromEnum(cmd)];
}

// ---------------------------------------------------------------------------
// Comptime helpers
// ---------------------------------------------------------------------------

/// A module's `decl` table as a slice (declared as an array, the usual
/// `[_]T{...}`, or as a slice).
fn tableOf(comptime T: type, comptime m: type, comptime decl: []const u8) []const T {
    const value = @field(m, decl);
    return switch (@typeInfo(@TypeOf(value))) {
        .array => &value,
        else => value,
    };
}

fn countDecl(comptime T: type, comptime modules: anytype, comptime decl: []const u8) usize {
    var n: usize = 0;
    inline for (modules) |m| {
        if (@hasDecl(m, decl)) n += tableOf(T, m, decl).len;
    }
    return n;
}

/// The `decl` tables of `modules`, concatenated in order.
fn collect(comptime T: type, comptime modules: anytype, comptime decl: []const u8) [countDecl(T, modules, decl)]T {
    @setEvalBranchQuota(1_000_000);
    var out: [countDecl(T, modules, decl)]T = undefined;
    var i: usize = 0;
    inline for (modules) |m| {
        if (@hasDecl(m, decl)) {
            for (tableOf(T, m, decl)) |entry| {
                out[i] = entry;
                i += 1;
            }
        }
    }
    return out;
}

fn namesOf(comptime T: type, comptime entries: []const T, comptime field: []const u8) []const []const u8 {
    var names: [entries.len][]const u8 = undefined;
    for (entries, 0..) |e, i| names[i] = @field(e, field);
    const final = names;
    return &final;
}

/// The first name that repeats an earlier one (ASCII case-insensitively
/// when `ignore_case`), or null.
fn firstDuplicate(comptime names: []const []const u8, comptime ignore_case: bool) ?[]const u8 {
    @setEvalBranchQuota(1_000_000);
    for (names, 0..) |a, i| {
        for (names[0..i]) |b| {
            const same = if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
            if (same) return a;
        }
    }
    return null;
}

fn checkMethod(comptime m: types.Method) void {
    if (m.name.len == 0) @compileError("rpc/registry.zig: rpc method with an empty name");
    if (m.test_only and !std.mem.startsWith(u8, m.name, "wmux.debug."))
        @compileError("rpc/registry.zig: test_only method '" ++ m.name ++ "' must be wmux.debug.*");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestHandlers = struct {
    fn ping(ctx: *types.Ctx) types.Error!void {
        ctx.ok(.{ .pong = true });
    }
    fn fail(ctx: *types.Ctx) types.Error!void {
        return ctx.fail(.not_found, "Workspace not found", null);
    }
    fn legacy(app_ptr: *@import("../App.zig"), req: *types.LegacyRequest) anyerror!void {
        _ = app_ptr;
        _ = req;
    }
    fn parse(args: []const u8, arena: std.mem.Allocator) anyerror!std.json.Value {
        _ = arena;
        return .{ .string = args };
    }
    fn format(result: std.json.Value, w: *std.Io.Writer) anyerror!void {
        _ = result;
        try w.writeAll("OK");
    }
};

const ModA = struct {
    pub const id = "a";
    pub const rpc_methods = [_]types.Method{
        .{ .name = "system.ping", .handler = TestHandlers.ping, .lane = .pipe, .access = .read },
        .{ .name = "wmux.a.fail", .handler = TestHandlers.fail },
    };
    pub const legacy_commands = [_]types.LegacyCommand{
        .{ .cmd = "workspace-list", .handler = TestHandlers.legacy, .read_only = true },
    };
};
const ModB = struct {
    pub const id = "b";
};
const ModC = struct {
    pub const id = "c";
    pub const rpc_methods = [_]types.Method{
        .{ .name = "wmux.debug.ready", .handler = TestHandlers.ping, .test_only = true },
    };
    pub const text_verbs = [_]types.TextVerb{
        .{ .name = "ping", .method = "system.ping", .parse = TestHandlers.parse, .format = TestHandlers.format },
    };
};

test "unit: rpc: registry aggregates every module's tables in order" {
    const R = Registry(.{ ModA, ModB, ModC });
    try testing.expectEqual(@as(usize, 3), R.all_methods.len);
    try testing.expectEqualStrings("system.ping", R.all_methods[0].name);
    try testing.expectEqualStrings("wmux.a.fail", R.all_methods[1].name);
    try testing.expectEqualStrings("wmux.debug.ready", R.all_methods[2].name);
    try testing.expectEqual(@as(usize, 1), R.legacy_commands.len);
    try testing.expectEqual(@as(usize, 1), R.text_verbs.len);
    // A registry over modules that declare nothing is empty.
    const E = Registry(.{ModB});
    try testing.expectEqual(@as(usize, 0), E.all_methods.len);
    try testing.expectEqual(@as(?*const types.Method, null), E.method("system.ping"));
}

test "unit: rpc: registry round trip from name to handler and reply" {
    const R = Registry(.{ ModA, ModB, ModC });
    const m = R.method("system.ping").?;
    try testing.expectEqual(types.Lane.pipe, m.lane);
    try testing.expectEqual(types.Access.read, m.access);
    try testing.expect(R.method("system.Ping") == null);
    try testing.expect(R.method("") == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{})).object;
    var ctx: types.Ctx = .{ .app = undefined, .arena = arena, .id = .null, .method = m, .raw_params = params, .origin = .{ .in_process = .@"test" } };
    try m.handler(&ctx);
    try testing.expectEqualStrings("{\"pong\":true}", ctx.reply.ok);

    const f = R.method("wmux.a.fail").?;
    var ctx2: types.Ctx = .{ .app = undefined, .arena = arena, .id = .null, .method = f, .raw_params = params, .origin = .{ .in_process = .@"test" } };
    try testing.expectError(error.RpcFailed, f.handler(&ctx2));
    try testing.expectEqual(types.ErrorCode.not_found, ctx2.reply.err.code);
}

test "unit: rpc: registry finds legacy commands and text verbs" {
    const R = Registry(.{ ModA, ModB, ModC });
    const c = R.legacyByName("workspace-list").?;
    try testing.expect(c.read_only);
    try testing.expectEqual(@as(?*const types.LegacyCommand, null), R.legacyByName("workspace-lst"));
    // Text verbs are case-insensitive (ADR-3.7).
    try testing.expectEqualStrings("system.ping", R.textVerb("PING").?.method);
    try testing.expectEqual(@as(?*const types.TextVerb, null), R.textVerb("pong"));
}

test "unit: rpc: registry duplicate detection names the duplicate" {
    comptime {
        if (firstDuplicate(&.{ "a.b", "c.d", "a.b" }, false)) |dup| {
            if (!std.mem.eql(u8, dup, "a.b")) @compileError("wrong duplicate");
        } else @compileError("duplicate missed");
        if (firstDuplicate(&.{ "ping", "PING" }, false) != null) @compileError("case-sensitive names differ");
        if (firstDuplicate(&.{ "ping", "PING" }, true) == null) @compileError("case-insensitive duplicate missed");
        if (firstDuplicate(&.{}, false) != null) @compileError("empty list has no duplicate");
    }
}
