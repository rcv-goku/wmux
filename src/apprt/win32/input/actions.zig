//! Actions registry [frozen] (ARCHITECTURE.md ADR-1.4, ADR-8.1; written in
//! W0-A3). Joins the complete action catalog (wmux_proto/actions_catalog.zig,
//! pure data keyed by cmux action ids) with the handlers features declare:
//!
//!     // features/<id>/mod.zig
//!     pub const action_handlers = @import("actions.zig").handlers;
//!     // features/<id>/actions.zig
//!     pub const handlers = [_]input.ActionHandler{ .{ .id = "splitRight", .run = splitRight } };
//!
//! Comptime checks (`@compileError` naming the feature and id): a handler
//! id must be a catalog id (not an alias) and an action has at most one
//! handler. A catalog entry without a handler is hidden from the palette
//! and its keys are inert (ADR-8.1). Consumers: the KeyRouter and palette
//! (W1-5, W2-7), menus, `wmux.action.run`, and the Ghostty `wmux:<id>`
//! binding action through `invoke`.

const std = @import("std");
const proto = @import("wmux_proto");

const App = @import("../App.zig");
const Tab = @import("../model/Tab.zig");
const Window = @import("../ui/Window.zig");
const apprt = @import("../../../apprt.zig");
const manifest = @import("../features/manifest.zig");

pub const catalog = proto.actions_catalog;

const log = std.log.scoped(.input);

/// What a handler did. A `performable` action whose handler returns
/// `.not_applicable` lets the key through (ADR-8.2).
pub const ActionResult = enum { handled, not_applicable };

/// Where an invocation came from.
pub const Source = enum { keyboard, palette, menu, rpc, ghostty, automation };

/// The context a handler runs in (UI thread).
pub const ActionCtx = struct {
    app: *App,
    /// The window the action targets (the focused one for keys).
    window: ?*Window = null,
    /// The focused tab of `window`, the target of tab-scoped actions.
    tab: ?*Tab = null,
    /// The digit of a numbered action or a parameter (`wmux:<id>:<arg>`).
    arg: ?[]const u8 = null,
    source: Source,
};

/// One handler, declared in its feature's actions.zig.
pub const ActionHandler = struct {
    /// A catalog id (`splitRight`, `wmux.toggleQuickTerminal`).
    id: []const u8,
    run: *const fn (ctx: *ActionCtx) ActionResult,
};

/// The registry over `modules` (a tuple of feature `mod.zig` namespaces).
/// The app instance joins features/manifest.zig; the unit tests join test
/// modules.
pub fn Actions(comptime modules: anytype) type {
    if (comptime joinError(modules)) |msg| @compileError(msg);
    return struct {
        /// The handler of every catalog entry, by catalog index.
        pub const by_entry: [catalog.entries.len]?ActionHandler = join(modules);

        /// Number of actions with a handler.
        pub const handled_count: usize = blk: {
            var n: usize = 0;
            for (by_entry) |h| {
                if (h != null) n += 1;
            }
            break :blk n;
        };

        /// The handler of action `id` (aliases resolved), or null when the
        /// id is unknown or has no handler yet.
        pub fn handlerFor(id: []const u8) ?*const ActionHandler {
            const entry = catalog.find(id) orelse return null;
            if (by_entry[indexOf(entry)]) |*h| return h;
            return null;
        }

        /// Whether `id` is a supported catalog action with a handler (the
        /// palette lists only these, ADR-8.8).
        pub fn isAvailable(id: []const u8) bool {
            const entry = catalog.find(id) orelse return false;
            return entry.availability == .supported and by_entry[indexOf(entry)] != null;
        }

        /// Run action `id` in `ctx`; null when the id is unknown, has no
        /// handler or is not available on Windows.
        pub fn run(id: []const u8, ctx: *ActionCtx) ?ActionResult {
            const entry = catalog.find(id) orelse return null;
            if (entry.availability != .supported) return null;
            const h = by_entry[indexOf(entry)] orelse return null;
            return h.run(ctx);
        }
    };
}

/// The app registry: every feature of features/manifest.zig.
pub const app = Actions(manifest.modules);

pub const handlerFor = app.handlerFor;
pub const isAvailable = app.isAvailable;
pub const run = app.run;

/// Split a `wmux:` binding parameter into the action id and its optional
/// argument at the first colon (`selectSurfaceByNumber:3`).
pub fn parseBinding(param: []const u8) struct { id: []const u8, arg: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, param, ':')) |colon| {
        return .{ .id = param[0..colon], .arg = param[colon + 1 ..] };
    }
    return .{ .id = param, .arg = null };
}

/// Run the action of a Ghostty `wmux:<id>[:<arg>]` binding (the apprt
/// `wmux_action`, ADR-8.7) for the surface it fired in. Returns whether
/// the action was performed: false lets a `performable:` binding pass the
/// key to the terminal.
pub fn invoke(app_ptr: *App, target: apprt.Target, param: []const u8) bool {
    const parsed = parseBinding(param);
    var ctx: ActionCtx = .{ .app = app_ptr, .arg = parsed.arg, .source = .ghostty };
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const rt = core_surface.rt_surface;
            ctx.window = rt.parent_window;
            ctx.tab = rt.tab;
        },
    }
    const result = run(parsed.id, &ctx) orelse {
        log.debug("wmux action '{s}' has no handler", .{parsed.id});
        return false;
    };
    return result == .handled;
}

// ---------------------------------------------------------------------------
// Comptime join
// ---------------------------------------------------------------------------

/// The catalog index of `entry` (works at comptime, unlike pointer math).
fn indexOf(entry: *const catalog.Entry) usize {
    return std.sort.binarySearch(catalog.Entry, &catalog.entries, entry.id, orderById).?;
}

fn orderById(id: []const u8, e: catalog.Entry) std.math.Order {
    return std.mem.order(u8, id, e.id);
}

/// A module's handler table as a slice (an array, the usual `[_]...{}`, or
/// a slice).
fn tableOf(comptime m: type) []const ActionHandler {
    const value = m.action_handlers;
    return switch (@typeInfo(@TypeOf(value))) {
        .array => &value,
        else => value,
    };
}

/// The compile error the join of `modules` would raise, or null.
fn joinError(comptime modules: anytype) ?[]const u8 {
    @setEvalBranchQuota(1_000_000);
    var owner: [catalog.entries.len]?[]const u8 = @splat(null);
    inline for (modules) |m| {
        if (!@hasDecl(m, "action_handlers")) continue;
        for (tableOf(m)) |h| {
            const entry = catalog.find(h.id) orelse
                return "input/actions.zig: features/" ++ m.id ++ " has a handler for unknown action id '" ++ h.id ++ "'";
            if (!std.mem.eql(u8, entry.id, h.id))
                return "input/actions.zig: features/" ++ m.id ++ " names action '" ++ entry.id ++ "' by its alias '" ++ h.id ++ "'";
            const idx = indexOf(entry);
            if (owner[idx]) |first|
                return "input/actions.zig: action '" ++ h.id ++ "' has two handlers (features/" ++ first ++ " and features/" ++ m.id ++ ")";
            owner[idx] = m.id;
        }
    }
    return null;
}

fn join(comptime modules: anytype) [catalog.entries.len]?ActionHandler {
    @setEvalBranchQuota(1_000_000);
    var out: [catalog.entries.len]?ActionHandler = @splat(null);
    inline for (modules) |m| {
        if (!@hasDecl(m, "action_handlers")) continue;
        for (tableOf(m)) |h| out[indexOf(catalog.find(h.id).?)] = h;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestRuns = struct {
    var last_arg: ?[]const u8 = null;

    fn split(ctx: *ActionCtx) ActionResult {
        last_arg = ctx.arg;
        return .handled;
    }
    fn nothing(ctx: *ActionCtx) ActionResult {
        _ = ctx;
        return .not_applicable;
    }
};

const ModSplit = struct {
    pub const id = "panes_surfaces";
    pub const action_handlers = [_]ActionHandler{
        .{ .id = "splitRight", .run = TestRuns.split },
        .{ .id = "selectSurfaceByNumber", .run = TestRuns.split },
    };
};
const ModEmpty = struct {
    pub const id = "windows";
    pub const action_handlers = [_]ActionHandler{};
};
const ModNone = struct {
    pub const id = "about";
};
const ModFind = struct {
    pub const id = "find";
    pub const action_handlers: []const ActionHandler = &.{.{ .id = "find", .run = TestRuns.nothing }};
};

test "unit: input: actions join handlers onto catalog entries" {
    const A = Actions(.{ ModSplit, ModEmpty, ModNone, ModFind });
    try testing.expectEqual(@as(usize, 3), A.handled_count);
    try testing.expect(A.handlerFor("splitRight") != null);
    try testing.expect(A.handlerFor("splitDown") == null);
    try testing.expect(A.handlerFor("noSuchAction") == null);
    try testing.expect(A.isAvailable("find"));
    try testing.expect(!A.isAvailable("splitDown"));
}

test "unit: input: actions run passes the argument and reports the result" {
    const A = Actions(.{ ModSplit, ModFind });
    var ctx: ActionCtx = .{ .app = undefined, .arg = "3", .source = .ghostty };
    try testing.expectEqual(@as(?ActionResult, .handled), A.run("selectSurfaceByNumber", &ctx));
    try testing.expectEqualStrings("3", TestRuns.last_arg.?);
    try testing.expectEqual(@as(?ActionResult, .not_applicable), A.run("find", &ctx));
    try testing.expectEqual(@as(?ActionResult, null), A.run("splitDown", &ctx));
    try testing.expectEqual(@as(?ActionResult, null), A.run("bogus", &ctx));
}

test "unit: input: actions parse wmux binding parameters" {
    const plain = parseBinding("newSurface");
    try testing.expectEqualStrings("newSurface", plain.id);
    try testing.expectEqual(@as(?[]const u8, null), plain.arg);
    const numbered = parseBinding("selectSurfaceByNumber:3");
    try testing.expectEqualStrings("selectSurfaceByNumber", numbered.id);
    try testing.expectEqualStrings("3", numbered.arg.?);
    const nested = parseBinding("wmux.selectLayout.tiled:a:b");
    try testing.expectEqualStrings("wmux.selectLayout.tiled", nested.id);
    try testing.expectEqualStrings("a:b", nested.arg.?);
}

test "unit: input: actions join rejects unknown ids, aliases and duplicates" {
    const Unknown = struct {
        pub const id = "x";
        pub const action_handlers = [_]ActionHandler{.{ .id = "splitSideways", .run = TestRuns.split }};
    };
    const Alias = struct {
        pub const id = "chrome";
        pub const action_handlers = [_]ActionHandler{.{ .id = "toggleRightSidebar", .run = TestRuns.split }};
    };
    comptime {
        const unknown = joinError(.{Unknown}) orelse @compileError("unknown id accepted");
        if (std.mem.indexOf(u8, unknown, "unknown action id 'splitSideways'") == null) @compileError(unknown);
        const alias = joinError(.{Alias}) orelse @compileError("alias accepted");
        if (std.mem.indexOf(u8, alias, "by its alias 'toggleRightSidebar'") == null) @compileError(alias);
        const dup = joinError(.{ ModSplit, ModSplit }) orelse @compileError("duplicate accepted");
        if (std.mem.indexOf(u8, dup, "'splitRight' has two handlers") == null) @compileError(dup);
        if (joinError(.{ ModSplit, ModEmpty, ModNone, ModFind }) != null) @compileError("valid join rejected");
    }
}
