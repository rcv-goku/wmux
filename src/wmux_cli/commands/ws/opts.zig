//! Command option scanning for the window/workspace/workspace-group
//! families: `--flag value`, `--flag=value`, boolean flags, repeatable
//! flags, aliases and positionals. Everything after `--` is positional and
//! verbatim. A value flag followed by another `--option` (or nothing) is a
//! usage error, so `new-window --name --json` cannot take `--json` as a name,
//! unless its value is optional (`--focus` alone records a null value).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Def = struct {
    name: []const u8,
    takes_value: bool = true,
    /// The value may be left out: with nothing, `--` or another `--option`
    /// next, the entry records a null value instead of a usage error.
    optional_value: bool = false,
    /// Alternate spellings recorded under `name`.
    aliases: []const []const u8 = &.{},
};

pub const Entry = struct { name: []const u8, value: ?[]const u8 };

pub const Opts = struct {
    entries: []const Entry = &.{},
    positionals: []const []const u8 = &.{},

    /// Last value of `name` (last wins).
    pub fn get(self: Opts, name: []const u8) ?[]const u8 {
        var out: ?[]const u8 = null;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) out = e.value;
        }
        return out;
    }

    pub fn has(self: Opts, name: []const u8) bool {
        for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
        return false;
    }

    /// Every value of a repeatable flag, in order.
    pub fn all(self: Opts, arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) if (e.value) |v| try list.append(arena, v);
        }
        return list.items;
    }
};

pub const Error = error{ Usage, OutOfMemory };

fn find(defs: []const Def, name: []const u8) ?*const Def {
    for (defs) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
        for (d.aliases) |a| if (std.mem.eql(u8, a, name)) return d;
    }
    return null;
}

fn looksLikeOption(s: []const u8) bool {
    return s.len > 2 and std.mem.startsWith(u8, s, "--");
}

/// Scans `args`; on a usage error `msg.*` holds the message.
pub fn parse(arena: Allocator, args: []const []const u8, defs: []const Def, msg: *[]const u8) Error!Opts {
    var entries: std.ArrayList(Entry) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            try pos.appendSlice(arena, args[i + 1 ..]);
            break;
        }
        if (!looksLikeOption(a)) {
            try pos.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = if (eq) |e| a[0..e] else a;
        const def = find(defs, name) orelse {
            msg.* = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{name});
            return error.Usage;
        };
        if (!def.takes_value) {
            if (eq != null) {
                msg.* = try std.fmt.allocPrint(arena, "{s} does not take a value", .{name});
                return error.Usage;
            }
            try entries.append(arena, .{ .name = def.name, .value = null });
            continue;
        }
        if (eq) |e| {
            try entries.append(arena, .{ .name = def.name, .value = a[e + 1 ..] });
            continue;
        }
        if (i + 1 >= args.len or looksLikeOption(args[i + 1]) or std.mem.eql(u8, args[i + 1], "--")) {
            if (def.optional_value) {
                try entries.append(arena, .{ .name = def.name, .value = null });
                continue;
            }
            msg.* = try std.fmt.allocPrint(arena, "{s} requires a value", .{name});
            return error.Usage;
        }
        i += 1;
        try entries.append(arena, .{ .name = def.name, .value = args[i] });
    }
    return .{ .entries = entries.items, .positionals = pos.items };
}

const testing = std.testing;

const test_defs = [_]Def{
    .{ .name = "--name" },
    .{ .name = "--env" },
    .{ .name = "--force", .takes_value = false },
    .{ .name = "--before", .aliases = &.{"--before-workspace"} },
};

fn parseOk(a: Allocator, args: []const []const u8) !Opts {
    var msg: []const u8 = "";
    return parse(a, args, &test_defs, &msg);
}

fn expectUsage(args: []const []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var msg: []const u8 = "";
    try testing.expectError(error.Usage, parse(arena_state.allocator(), args, &test_defs, &msg));
    try testing.expectEqualStrings(want, msg);
}

test "unit: cli-ws: opts values, equals form, repeats, aliases and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o = try parseOk(a, &.{ "pos1", "--name", "a", "--name=b", "--env", "A=1", "--env=B=2", "--force", "--before-workspace", "workspace:2", "-", "--", "--name", "x" });
    try testing.expectEqualStrings("b", o.get("--name").?);
    const envs = try o.all(a, "--env");
    try testing.expectEqual(@as(usize, 2), envs.len);
    try testing.expectEqualStrings("B=2", envs[1]);
    try testing.expect(o.has("--force"));
    try testing.expectEqualStrings("workspace:2", o.get("--before").?);
    try testing.expectEqual(@as(usize, 4), o.positionals.len);
    try testing.expectEqualStrings("-", o.positionals[1]);
    try testing.expectEqualStrings("--name", o.positionals[2]);
    try testing.expect(o.get("--missing") == null);
}

test "unit: cli-ws: opts empty, unicode and equals-empty values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const e = try parseOk(a, &.{});
    try testing.expectEqual(@as(usize, 0), e.positionals.len);
    const u = try parseOk(a, &.{ "--name", "\u{65e5}\u{672c} \u{1F600}", "--env=" });
    try testing.expectEqualStrings("\u{65e5}\u{672c} \u{1F600}", u.get("--name").?);
    try testing.expectEqualStrings("", u.get("--env").?);
}

test "unit: cli-ws: opts usage errors" {
    try expectUsage(&.{"--bogus"}, "unknown option '--bogus'");
    try expectUsage(&.{"--bogus=1"}, "unknown option '--bogus'");
    try expectUsage(&.{"--name"}, "--name requires a value");
    try expectUsage(&.{ "--name", "--force" }, "--name requires a value");
    try expectUsage(&.{ "--name", "--" }, "--name requires a value");
    try expectUsage(&.{"--force=yes"}, "--force does not take a value");
}

test "unit: cli-ws: opts optional values stand alone before options, -- or the end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const defs = [_]Def{ .{ .name = "--focus", .optional_value = true }, .{ .name = "--name" } };
    var msg: []const u8 = "";
    const bare = try parse(a, &.{"--focus"}, &defs, &msg);
    try testing.expect(bare.has("--focus"));
    try testing.expect(bare.get("--focus") == null);
    const mixed = try parse(a, &.{ "--focus", "--name", "x", "--focus", "--", "pos" }, &defs, &msg);
    try testing.expectEqual(@as(usize, 3), mixed.entries.len);
    try testing.expect(mixed.entries[0].value == null);
    try testing.expectEqualStrings("x", mixed.get("--name").?);
    try testing.expect(mixed.entries[2].value == null);
    try testing.expectEqual(@as(usize, 1), mixed.positionals.len);
    const valued = try parse(a, &.{ "--focus", "false", "--focus=true" }, &defs, &msg);
    try testing.expectEqualStrings("false", valued.entries[0].value.?);
    try testing.expectEqualStrings("true", valued.get("--focus").?);
    // Flags without an optional value still need one.
    try testing.expectError(error.Usage, parse(a, &.{ "--name", "--focus" }, &defs, &msg));
    try testing.expectEqualStrings("--name requires a value", msg);
}
