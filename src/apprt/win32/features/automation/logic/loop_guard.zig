//! Automation origin and cycle prevention (cli-automation-origin-loop-guard).
//!
//! An event caused by an automation action is tagged with an
//! `automation_origin` object `{rule_id, chain, depth}`: `chain` holds the ids
//! of the rules that produced it, oldest first, and `depth` its length. A rule
//! whose id is in that chain does not fire for the event, so neither a rule
//! that triggers itself nor a ring of rules can loop; once the chain holds
//! `max_chain` ids, no rule fires at all.
//!
//! `run` actions hand the origin to their child process in
//! `CMUX_AUTOMATION_RULE_ID` and `CMUX_AUTOMATION_CHAIN`. While those are set,
//! the CLI attaches the same origin (top-level `automation_origin`) to each
//! v2 request it makes, so a script that calls `cmux` keeps the chain.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Longest chain; an origin at this depth fires no further rules.
pub const max_chain: usize = 16;
/// Longest accepted rule id in an origin (bytes). Longer ids make the origin malformed.
pub const max_rule_id_len: usize = 256;

pub const env_rule_id = "CMUX_AUTOMATION_RULE_ID";
pub const env_chain = "CMUX_AUTOMATION_CHAIN";
pub const env_event = "CMUX_AUTOMATION_EVENT";
pub const env_event_json = "CMUX_AUTOMATION_EVENT_JSON";

/// The `automation_origin` envelope (ADR-3.10 `Event.automation_origin`).
pub const AutomationOrigin = struct {
    /// The rule whose action produced the event (the last chain entry).
    rule_id: []const u8,
    /// Rule ids, oldest first; never empty.
    chain: []const []const u8,
    /// Number of rules in the chain.
    depth: u32,

    pub fn contains(self: *const AutomationOrigin, rule_id: []const u8) bool {
        for (self.chain) |id| {
            if (std.mem.eql(u8, id, rule_id)) return true;
        }
        return std.mem.eql(u8, self.rule_id, rule_id);
    }

    /// Writes `{"rule_id":…,"chain":[…],"depth":n}`.
    pub fn write(self: *const AutomationOrigin, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        try jw.beginObject();
        try jw.objectField("rule_id");
        try jw.write(self.rule_id);
        try jw.objectField("chain");
        try jw.write(self.chain);
        try jw.objectField("depth");
        try jw.write(self.depth);
        try jw.endObject();
    }

    pub fn jsonStringify(self: *const AutomationOrigin, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        return self.write(jw);
    }
};

pub const SkipReason = enum {
    /// The rule is already in the chain (self-trigger or cycle).
    cycle,
    /// The chain reached `max_chain`.
    depth,
};

/// Why `rule_id` must not fire for an event with `origin`, or null when it may.
pub fn skipReason(origin: ?*const AutomationOrigin, rule_id: []const u8) ?SkipReason {
    const o = origin orelse return null;
    if (o.contains(rule_id)) return .cycle;
    if (o.chain.len >= max_chain or o.depth >= max_chain) return .depth;
    return null;
}

pub fn shouldSkip(origin: ?*const AutomationOrigin, rule_id: []const u8) bool {
    return skipReason(origin, rule_id) != null;
}

/// The origin carried by events that `rule_id`'s actions emit while handling
/// an event with `parent` origin: the parent chain plus `rule_id`. Strings are
/// copied into `arena`. Fails with `error.ChainTooLong` past `max_chain`.
pub fn extend(arena: Allocator, parent: ?*const AutomationOrigin, rule_id: []const u8) error{ OutOfMemory, ChainTooLong }!AutomationOrigin {
    const prev: []const []const u8 = if (parent) |p| p.chain else &.{};
    if (prev.len >= max_chain) return error.ChainTooLong;
    const chain = try arena.alloc([]const u8, prev.len + 1);
    for (prev, 0..) |id, i| chain[i] = try arena.dupe(u8, id);
    chain[prev.len] = try arena.dupe(u8, rule_id);
    return .{ .rule_id = chain[prev.len], .chain = chain, .depth = @intCast(chain.len) };
}

fn validId(id: []const u8) bool {
    return id.len > 0 and id.len <= max_rule_id_len and std.unicode.utf8ValidateSlice(id);
}

/// Reads an `automation_origin` value (request envelope or event JSON).
/// Lenient about shape but never trusts it blindly: returns null when the
/// value is not an object, has no usable `rule_id`, or carries a malformed
/// chain. `rule_id` is appended when the chain does not end with it, and
/// `depth` is the larger of the stated depth and the chain length, so a
/// forged small depth cannot reset the bound. Strings alias `v`.
pub fn fromJson(arena: Allocator, v: std.json.Value) Allocator.Error!?AutomationOrigin {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const rule_id = switch (obj.get("rule_id") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!validId(rule_id)) return null;
    var list: std.ArrayList([]const u8) = .empty;
    if (obj.get("chain")) |c| switch (c) {
        .array => |arr| {
            if (arr.items.len > max_chain) return null;
            for (arr.items) |item| switch (item) {
                .string => |s| {
                    if (!validId(s)) return null;
                    try list.append(arena, s);
                },
                else => return null,
            };
        },
        .null => {},
        else => return null,
    };
    if (list.items.len == 0 or !std.mem.eql(u8, list.items[list.items.len - 1], rule_id)) {
        if (list.items.len >= max_chain) return null;
        try list.append(arena, rule_id);
    }
    var depth: u32 = @intCast(list.items.len);
    if (obj.get("depth")) |d| switch (d) {
        .integer => |n| if (n > depth) {
            depth = if (n > max_chain) @intCast(max_chain) else @intCast(n);
        },
        else => {},
    };
    return .{ .rule_id = rule_id, .chain = try list.toOwnedSlice(arena), .depth = depth };
}

/// The CLI side: the origin to attach to every v2 request when the
/// environment has `CMUX_AUTOMATION_RULE_ID` (`rule_id`). `chain_json` is
/// the raw `CMUX_AUTOMATION_CHAIN` value (a JSON string array); when it is
/// absent or malformed the chain is just `[rule_id]`. Returns null when
/// `rule_id` is null or unusable. Strings are copied into `arena`.
pub fn fromEnv(arena: Allocator, rule_id: ?[]const u8, chain_json: ?[]const u8) Allocator.Error!?AutomationOrigin {
    const id = rule_id orelse return null;
    if (!validId(id)) return null;
    var list: std.ArrayList([]const u8) = .empty;
    if (chain_json) |text| parsed: {
        if (text.len > max_chain * (max_rule_id_len * 6 + 4) + 2) break :parsed;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch break :parsed;
        const arr = switch (v) {
            .array => |a| a,
            else => break :parsed,
        };
        if (arr.items.len > max_chain) break :parsed;
        var tmp: std.ArrayList([]const u8) = .empty;
        for (arr.items) |item| switch (item) {
            .string => |s| {
                if (!validId(s)) break :parsed;
                try tmp.append(arena, try arena.dupe(u8, s));
            },
            else => break :parsed,
        };
        list = tmp;
    }
    var depth: u32 = 0;
    if (list.items.len == 0 or !std.mem.eql(u8, list.items[list.items.len - 1], id)) {
        if (list.items.len >= max_chain) {
            // Full chain: drop the oldest id but keep the depth at the bound.
            _ = list.orderedRemove(0);
            depth = max_chain;
        }
        try list.append(arena, try arena.dupe(u8, id));
    }
    const chain = try list.toOwnedSlice(arena);
    return .{ .rule_id = chain[chain.len - 1], .chain = chain, .depth = @max(depth, @as(u32, @intCast(chain.len))) };
}

/// `CMUX_AUTOMATION_CHAIN` value: the chain as a JSON string array. Owned by `gpa`.
pub fn chainJsonAlloc(gpa: Allocator, origin: *const AutomationOrigin) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, origin.chain, .{});
}

/// Minified `automation_origin` JSON. Owned by `gpa`.
pub fn toJsonAlloc(gpa: Allocator, origin: *const AutomationOrigin) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, origin, .{});
}

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// The variables a `run` action adds to its child environment, in a fixed
/// order. `event_json` is the serialized event (exported twice, as cmux
/// does); `origin` is the action's origin from `extend`. Values are
/// allocated in `arena`.
pub fn runEnv(arena: Allocator, origin: *const AutomationOrigin, event_json: []const u8) Allocator.Error![4]EnvVar {
    return .{
        .{ .name = env_event, .value = event_json },
        .{ .name = env_event_json, .value = event_json },
        .{ .name = env_rule_id, .value = origin.rule_id },
        .{ .name = env_chain, .value = try chainJsonAlloc(arena, origin) },
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "unit: automation: loop guard skips a rule already in the chain" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(!shouldSkip(null, "a"));
    const a = try extend(arena, null, "a");
    try testing.expectEqualStrings("a", a.rule_id);
    try testing.expectEqual(@as(u32, 1), a.depth);
    // Direct self-trigger.
    try testing.expectEqual(SkipReason.cycle, skipReason(&a, "a").?);
    try testing.expect(!shouldSkip(&a, "b"));
    // Multi-rule cycle a -> b -> a.
    const ab = try extend(arena, &a, "b");
    try testing.expectEqual(@as(u32, 2), ab.depth);
    try testing.expectEqualStrings("b", ab.rule_id);
    try testing.expect(shouldSkip(&ab, "a"));
    try testing.expect(shouldSkip(&ab, "b"));
    try testing.expect(!shouldSkip(&ab, "c"));
    // Ids compare exactly (case matters, unicode kept).
    try testing.expect(!shouldSkip(&ab, "A"));
    const u = try extend(arena, &ab, "règle-✓");
    try testing.expect(shouldSkip(&u, "règle-✓"));
}

test "unit: automation: loop guard bounds the chain length" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var o: ?AutomationOrigin = null;
    var buf: [16]u8 = undefined;
    for (0..max_chain) |i| {
        const id = try std.fmt.bufPrint(&buf, "r{d}", .{i});
        o = try extend(arena, if (o) |*p| p else null, id);
    }
    try testing.expectEqual(@as(u32, max_chain), o.?.depth);
    try testing.expectEqual(SkipReason.depth, skipReason(&o.?, "fresh").?);
    try testing.expectError(error.ChainTooLong, extend(arena, &o.?, "fresh"));
}

test "unit: automation: loop guard parses automation_origin JSON leniently" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"rule_id":"b","chain":["a","b"],"depth":2}
    , .{});
    const o = (try fromJson(arena, v)).?;
    try testing.expectEqual(@as(usize, 2), o.chain.len);
    try testing.expect(shouldSkip(&o, "a"));

    // rule_id missing from the chain is appended; depth never below chain length.
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"rule_id":"c","chain":["a"],"depth":0}
    , .{});
    const o2 = (try fromJson(arena, v2)).?;
    try testing.expectEqual(@as(usize, 2), o2.chain.len);
    try testing.expectEqual(@as(u32, 2), o2.depth);
    try testing.expect(shouldSkip(&o2, "c"));

    // A large stated depth is kept (clamped) and stops further rules.
    const v3 = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"rule_id":"c","depth":99999999999}
    , .{});
    const o3 = (try fromJson(arena, v3)).?;
    try testing.expectEqual(@as(u32, max_chain), o3.depth);
    try testing.expectEqual(SkipReason.depth, skipReason(&o3, "z").?);

    // Negative, fractional or non-numeric depths never lower the chain length.
    for ([_][]const u8{ "-5", "1.5", "\"9\"", "null" }) |d| {
        const text = try std.fmt.allocPrint(arena, "{{\"rule_id\":\"c\",\"chain\":[\"a\",\"b\",\"c\"],\"depth\":{s}}}", .{d});
        const dv = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        const od = (try fromJson(arena, dv)).?;
        try testing.expectEqual(@as(u32, 3), od.depth);
    }

    // Malformed shapes are ignored rather than trusted.
    const bad = [_][]const u8{
        "3",                                 "\"x\"",                                "{}",
        "{\"rule_id\":\"\"}",                "{\"rule_id\":7}",                      "{\"rule_id\":\"a\",\"chain\":\"a\"}",
        "{\"rule_id\":\"a\",\"chain\":[1]}", "{\"rule_id\":\"a\",\"chain\":[\"\"]}",
    };
    for (bad) |text| {
        const bv = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        try testing.expect((try fromJson(arena, bv)) == null);
    }
    // Over-long chains and ids are rejected.
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(arena, "{\"rule_id\":\"x\",\"chain\":[");
    for (0..max_chain + 1) |i| {
        if (i > 0) try long.append(arena, ',');
        try long.appendSlice(arena, "\"x\"");
    }
    try long.appendSlice(arena, "]}");
    const lv = try std.json.parseFromSliceLeaky(std.json.Value, arena, long.items, .{});
    try testing.expect((try fromJson(arena, lv)) == null);
    const huge_id = try arena.alloc(u8, max_rule_id_len + 1);
    @memset(huge_id, 'a');
    var obj: std.json.ObjectMap = .init(arena);
    try obj.put("rule_id", .{ .string = huge_id });
    try testing.expect((try fromJson(arena, .{ .object = obj })) == null);
}

test "unit: automation: loop guard frees everything on allocation failure" {
    const S = struct {
        fn run(gpa: Allocator) !void {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const a = try extend(arena, null, "a");
            const ab = try extend(arena, &a, "règle-b");
            _ = try runEnv(arena, &ab, "{\"name\":\"workspace.created\"}");
            _ = try fromEnv(arena, "c", "[\"a\",\"règle-b\"]");
            const json = try toJsonAlloc(gpa, &ab);
            defer gpa.free(json);
            const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
            _ = try fromJson(arena, v);
            const chain = try chainJsonAlloc(gpa, &ab);
            gpa.free(chain);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}

test "unit: automation: loop guard round-trips through the run environment and the CLI" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try extend(arena, null, "a");
    const ab = try extend(arena, &a, "b");
    const env = try runEnv(arena, &ab, "{\"name\":\"workspace.created\"}");
    try testing.expectEqualStrings(env_event, env[0].name);
    try testing.expectEqualStrings(env[0].value, env[1].value);
    try testing.expectEqualStrings("b", env[2].value);
    try testing.expectEqualStrings("[\"a\",\"b\"]", env[3].value);

    // A shell script calling the CLI rebuilds the same origin.
    const cli = (try fromEnv(arena, env[2].value, env[3].value)).?;
    try testing.expectEqual(@as(u32, 2), cli.depth);
    try testing.expect(shouldSkip(&cli, "a"));
    const json = try toJsonAlloc(testing.allocator, &cli);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"rule_id\":\"b\",\"chain\":[\"a\",\"b\"],\"depth\":2}", json);

    // No rule id: no origin. Malformed or missing chain: just the rule id.
    try testing.expect((try fromEnv(arena, null, "[\"a\"]")) == null);
    try testing.expect((try fromEnv(arena, "", null)) == null);
    for ([_]?[]const u8{ null, "", "not json", "{\"a\":1}", "[1,2]", "[\"\"]" }) |c| {
        const o = (try fromEnv(arena, "r", c)).?;
        try testing.expectEqual(@as(usize, 1), o.chain.len);
        try testing.expectEqualStrings("r", o.chain[0]);
    }
    // A chain that does not end with the rule id gets it appended.
    const o = (try fromEnv(arena, "c", "[\"a\",\"b\"]")).?;
    try testing.expectEqual(@as(usize, 3), o.chain.len);
    try testing.expectEqualStrings("c", o.rule_id);
    // A full chain stays at the depth bound instead of restarting.
    var full: std.ArrayList(u8) = .empty;
    try full.append(arena, '[');
    for (0..max_chain) |i| {
        if (i > 0) try full.append(arena, ',');
        try full.print(arena, "\"r{d}\"", .{i});
    }
    try full.append(arena, ']');
    const f = (try fromEnv(arena, "new", full.items)).?;
    try testing.expectEqual(max_chain, f.chain.len);
    try testing.expectEqual(SkipReason.depth, skipReason(&f, "other").?);
}
