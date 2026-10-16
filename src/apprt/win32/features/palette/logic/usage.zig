//! Palette usage statistics (`STATE\palette-usage.json`, ADR-8.8 / W2-7).
//!
//! cmux keeps `{useCount, lastUsedAt}` per command id and boosts frequently and
//! recently used commands; the boost drops to one third once the user types a
//! query. wmux persists the same per-id pair in a versioned JSON file:
//!
//! ```json
//! {"version":1,"commands":{"palette.newWorkspace":{"useCount":3,"lastUsedAt":1760000000000}}}
//! ```
//!
//! `lastUsedAt` is Unix time in milliseconds. Entries are written sorted by id
//! so the file is byte-stable. Loading is lenient: unknown keys are ignored,
//! malformed entries are skipped, and only a file that is not a JSON object
//! (or has an unsupported `version`) is rejected so the caller can start over.
//!
//! Frecency = log2(1 + useCount) × 0.5^(age / half_life). It decays smoothly,
//! so old habits fade without rewriting the file; `prune` drops entries whose
//! frecency fell below a floor and caps the entry count.
//!
//! Pure std. The UI thread owns a `Store`; the file is read and written by a
//! worker with a serialized copy (G3).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const file_name = "palette-usage.json";
pub const format_version: i64 = 1;

/// Ids longer than this are ignored (G6).
pub const max_id_bytes: usize = 256;
/// Entries kept after `prune` / load.
pub const max_entries: usize = 500;
/// Use counts saturate here.
pub const max_use_count: u32 = 100_000;
/// Frecency halves every week of non-use.
pub const half_life_ms: i64 = 7 * std.time.ms_per_day;
/// `prune` drops entries whose frecency is below this (one use, ~7 weeks old).
pub const prune_floor: f64 = 1.0 / 128.0;
/// Boost (score units) per unit of frecency, and its ceiling.
pub const boost_scale: f64 = 20.0;
pub const max_boost: i32 = 100;
/// The boost is divided by this when the query is non-empty (cmux: one third).
pub const query_boost_divisor: i32 = 3;

pub const Entry = struct {
    use_count: u32 = 0,
    /// Unix milliseconds.
    last_used_at: i64 = 0,
};

/// Frecency of `e` at `now_ms`. A `last_used_at` in the future (clock moved
/// back) counts as "just now".
pub fn frecency(e: Entry, now_ms: i64) f64 {
    if (e.use_count == 0) return 0;
    const age: f64 = @floatFromInt(@max(0, now_ms -| e.last_used_at));
    const freq = std.math.log2(1.0 + @as(f64, @floatFromInt(e.use_count)));
    return freq * std.math.pow(f64, 0.5, age / @as(f64, @floatFromInt(half_life_ms)));
}

/// Ranking boost for `e` in score units; one third with a non-empty query.
pub fn boost(e: Entry, now_ms: i64, query_empty: bool) i32 {
    const raw = @min(@as(f64, @floatFromInt(max_boost)), boost_scale * frecency(e, now_ms));
    const b: i32 = @intFromFloat(@round(raw));
    return if (query_empty) b else @divTrunc(b, query_boost_divisor);
}

pub const LoadError = error{ InvalidFormat, UnsupportedVersion } || Allocator.Error;

pub const Store = struct {
    /// Keys are owned by the store.
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const empty: Store = .{};

    pub fn deinit(self: *Store, gpa: Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.map.deinit(gpa);
        self.* = undefined;
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    pub fn get(self: *const Store, id: []const u8) ?Entry {
        return self.map.get(id);
    }

    /// Boost for `id` (0 when unknown).
    pub fn boostFor(self: *const Store, id: []const u8, now_ms: i64, query_empty: bool) i32 {
        const e = self.map.get(id) orelse return 0;
        return boost(e, now_ms, query_empty);
    }

    /// Records one use of `id` at `now_ms`. Over-long and empty ids are
    /// ignored. `lastUsedAt` never moves backwards.
    pub fn record(self: *Store, gpa: Allocator, id: []const u8, now_ms: i64) Allocator.Error!void {
        if (id.len == 0 or id.len > max_id_bytes) return;
        const gop = try self.map.getOrPut(gpa, id);
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, id) catch |err| {
                self.map.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        const e = gop.value_ptr;
        e.use_count = @min(max_use_count, e.use_count +| 1);
        e.last_used_at = @max(e.last_used_at, now_ms);
    }

    /// Forgets `id`; returns whether it was present.
    pub fn remove(self: *Store, gpa: Allocator, id: []const u8) bool {
        const kv = self.map.fetchRemove(id) orelse return false;
        gpa.free(kv.key);
        return true;
    }

    /// Drops entries with frecency below `prune_floor` at `now_ms`, then keeps
    /// at most `limit` entries, preferring higher frecency, then the more
    /// recent use, then the smaller id. Returns the number removed.
    pub fn prune(self: *Store, gpa: Allocator, now_ms: i64, limit: usize) Allocator.Error!usize {
        const Cand = struct { key: []const u8, f: f64, last: i64 };
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(gpa);
        try cands.ensureTotalCapacity(gpa, self.map.count());
        var it = self.map.iterator();
        while (it.next()) |kv| {
            cands.appendAssumeCapacity(.{
                .key = kv.key_ptr.*,
                .f = frecency(kv.value_ptr.*, now_ms),
                .last = kv.value_ptr.last_used_at,
            });
        }
        std.mem.sort(Cand, cands.items, {}, struct {
            fn lessThan(_: void, a: Cand, b: Cand) bool {
                if (a.f != b.f) return a.f > b.f;
                if (a.last != b.last) return a.last > b.last;
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);
        var removed: usize = 0;
        for (cands.items, 0..) |c, i| {
            if (i < limit and c.f >= prune_floor) continue;
            const kv = self.map.fetchRemove(c.key).?;
            gpa.free(kv.key);
            removed += 1;
        }
        return removed;
    }

    /// Parses the file contents. See the module comment for leniency rules.
    /// Over-long ids and invalid entries are skipped; at most `max_entries`
    /// survive (most frecent at `now_ms`).
    pub fn parse(gpa: Allocator, bytes: []const u8, now_ms: i64) LoadError!Store {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .duplicate_field_behavior = .use_first }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFormat,
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidFormat,
        };
        if (root.get("version")) |v| switch (v) {
            .integer => |n| if (n != format_version) return error.UnsupportedVersion,
            else => return error.InvalidFormat,
        };
        var store: Store = .empty;
        errdefer store.deinit(gpa);
        const commands = switch (root.get("commands") orelse return store) {
            .object => |o| o,
            else => return error.InvalidFormat,
        };
        var it = commands.iterator();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            if (id.len == 0 or id.len > max_id_bytes) continue;
            const e = parseEntry(kv.value_ptr.*) orelse continue;
            if (store.map.contains(id)) continue;
            const key = try gpa.dupe(u8, id);
            store.map.put(gpa, key, e) catch |err| {
                gpa.free(key);
                return err;
            };
        }
        if (store.map.count() > max_entries) _ = try store.prune(gpa, now_ms, max_entries);
        return store;
    }

    /// Serializes to the file format, entries sorted by id. Caller owns.
    pub fn serialize(self: *const Store, gpa: Allocator) Allocator.Error![]u8 {
        const keys = try gpa.alloc([]const u8, self.map.count());
        defer gpa.free(keys);
        var it = self.map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sort([]const u8, keys, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        writeJson(self, &jw, keys) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn writeJson(self: *const Store, jw: *std.json.Stringify, keys: []const []const u8) std.Io.Writer.Error!void {
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(format_version);
        try jw.objectField("commands");
        try jw.beginObject();
        for (keys) |k| {
            const e = self.map.get(k).?;
            try jw.objectField(k);
            try jw.beginObject();
            try jw.objectField("useCount");
            try jw.write(e.use_count);
            try jw.objectField("lastUsedAt");
            try jw.write(e.last_used_at);
            try jw.endObject();
        }
        try jw.endObject();
        try jw.endObject();
    }
};

fn parseEntry(v: std.json.Value) ?Entry {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const count = intField(o, "useCount") orelse return null;
    if (count <= 0) return null;
    const last = intField(o, "lastUsedAt") orelse 0;
    return .{
        .use_count = @intCast(@min(count, max_use_count)),
        .last_used_at = last,
    };
}

/// Integer field; integral floats (e.g. `3.0`) are accepted, anything else
/// (strings, fractions, out-of-range numbers) is rejected.
fn intField(o: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (o.get(name) orelse return null) {
        .integer => |n| n,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.0e15) @intFromFloat(f) else null,
        else => null,
    };
}

const testing = std.testing;
const day = std.time.ms_per_day;
const t0: i64 = 1_760_000_000_000;

test "unit: palette: usage record counts uses and keeps the latest time" {
    const gpa = testing.allocator;
    var s: Store = .empty;
    defer s.deinit(gpa);
    try s.record(gpa, "palette.newWorkspace", t0);
    try s.record(gpa, "palette.newWorkspace", t0 + 10);
    try s.record(gpa, "palette.newWorkspace", t0 + 5); // clock went back
    const e = s.get("palette.newWorkspace").?;
    try testing.expectEqual(@as(u32, 3), e.use_count);
    try testing.expectEqual(t0 + 10, e.last_used_at);
    try testing.expect(s.get("other") == null);
    try testing.expectEqual(@as(i32, 0), s.boostFor("other", t0, true));
}

test "unit: palette: usage ignores empty and over-long ids" {
    const gpa = testing.allocator;
    var s: Store = .empty;
    defer s.deinit(gpa);
    try s.record(gpa, "", t0);
    const long = "x" ** (max_id_bytes + 1);
    try s.record(gpa, long, t0);
    try s.record(gpa, long[0..max_id_bytes], t0);
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "unit: palette: usage frecency decays with age and grows with count" {
    const one: Entry = .{ .use_count = 1, .last_used_at = t0 };
    const many: Entry = .{ .use_count = 15, .last_used_at = t0 };
    try testing.expectApproxEqAbs(@as(f64, 1.0), frecency(one, t0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), frecency(one, t0 + 7 * day), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), frecency(many, t0), 1e-9);
    try testing.expect(frecency(many, t0 + 7 * day) > frecency(one, t0));
    // Future timestamps count as now; zero uses have no frecency.
    try testing.expectApproxEqAbs(@as(f64, 1.0), frecency(one, t0 - day), 1e-9);
    try testing.expectEqual(@as(f64, 0), frecency(.{}, t0));
    // Extreme ages do not overflow.
    try testing.expect(frecency(.{ .use_count = 1, .last_used_at = std.math.minInt(i64) }, std.math.maxInt(i64)) >= 0);
}

test "unit: palette: usage boost is capped and one third with a query" {
    const e: Entry = .{ .use_count = 3, .last_used_at = t0 }; // frecency 2
    try testing.expectEqual(@as(i32, 40), boost(e, t0, true));
    try testing.expectEqual(@as(i32, 13), boost(e, t0, false));
    const huge: Entry = .{ .use_count = max_use_count, .last_used_at = t0 };
    try testing.expectEqual(max_boost, boost(huge, t0, true));
    try testing.expectEqual(@divTrunc(max_boost, 3), boost(huge, t0, false));
    try testing.expectEqual(@as(i32, 0), boost(e, t0 + 365 * day, true));
}

test "unit: palette: usage serialize is sorted and round-trips" {
    const gpa = testing.allocator;
    var s: Store = .empty;
    defer s.deinit(gpa);
    try s.record(gpa, "palette.toggleSidebar", t0);
    try s.record(gpa, "palette.newWorkspace", t0 + 1);
    try s.record(gpa, "palette.newWorkspace", t0 + 2);
    try s.record(gpa, "palette.\"quoted\" ✓", t0);
    const bytes = try s.serialize(gpa);
    defer gpa.free(bytes);
    try testing.expectEqualStrings(
        "{\"version\":1,\"commands\":{" ++
            "\"palette.\\\"quoted\\\" ✓\":{\"useCount\":1,\"lastUsedAt\":1760000000000}," ++
            "\"palette.newWorkspace\":{\"useCount\":2,\"lastUsedAt\":1760000000002}," ++
            "\"palette.toggleSidebar\":{\"useCount\":1,\"lastUsedAt\":1760000000000}}}",
        bytes,
    );
    var back = try Store.parse(gpa, bytes, t0);
    defer back.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), back.count());
    try testing.expectEqual(Entry{ .use_count = 2, .last_used_at = t0 + 2 }, back.get("palette.newWorkspace").?);
    const again = try back.serialize(gpa);
    defer gpa.free(again);
    try testing.expectEqualStrings(bytes, again);
}

test "unit: palette: usage serialize of an empty store" {
    const gpa = testing.allocator;
    var s: Store = .empty;
    defer s.deinit(gpa);
    const bytes = try s.serialize(gpa);
    defer gpa.free(bytes);
    try testing.expectEqualStrings("{\"version\":1,\"commands\":{}}", bytes);
}

test "unit: palette: usage parse is lenient about entries" {
    const gpa = testing.allocator;
    const text =
        \\{"version":1,"extra":true,"commands":{
        \\ "ok":{"useCount":2,"lastUsedAt":5,"future":"x"},
        \\ "float":{"useCount":3.0,"lastUsedAt":7.0},
        \\ "frac":{"useCount":1.5},
        \\ "zero":{"useCount":0,"lastUsedAt":1},
        \\ "neg":{"useCount":-4},
        \\ "str":{"useCount":"9"},
        \\ "notobj":[1,2],
        \\ "nolast":{"useCount":1},
        \\ "big":{"useCount":99999999999,"lastUsedAt":1},
        \\ "":{"useCount":1}
        \\}}
    ;
    var s = try Store.parse(gpa, text, 0);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), s.count());
    try testing.expectEqual(Entry{ .use_count = 2, .last_used_at = 5 }, s.get("ok").?);
    try testing.expectEqual(Entry{ .use_count = 3, .last_used_at = 7 }, s.get("float").?);
    try testing.expectEqual(Entry{ .use_count = 1, .last_used_at = 0 }, s.get("nolast").?);
    try testing.expectEqual(max_use_count, s.get("big").?.use_count);
}

test "unit: palette: usage parse rejects malformed files" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidFormat, Store.parse(gpa, "", 0));
    try testing.expectError(error.InvalidFormat, Store.parse(gpa, "{", 0));
    try testing.expectError(error.InvalidFormat, Store.parse(gpa, "[]", 0));
    try testing.expectError(error.InvalidFormat, Store.parse(gpa, "{\"commands\":[]}", 0));
    try testing.expectError(error.InvalidFormat, Store.parse(gpa, "{\"version\":\"1\"}", 0));
    try testing.expectError(error.UnsupportedVersion, Store.parse(gpa, "{\"version\":2,\"commands\":{}}", 0));
    // Missing version and missing commands are fine.
    var s = try Store.parse(gpa, "{}", 0);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), s.count());
    var s2 = try Store.parse(gpa, "{\"commands\":{\"a\":{\"useCount\":1}}}", 0);
    defer s2.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), s2.count());
}

test "unit: palette: usage parse keeps the first of duplicate ids" {
    const gpa = testing.allocator;
    var s = try Store.parse(gpa, "{\"commands\":{\"a\":{\"useCount\":1},\"a\":{\"useCount\":9}}}", 0);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "unit: palette: usage prune drops stale entries and caps the count" {
    const gpa = testing.allocator;
    var s: Store = .empty;
    defer s.deinit(gpa);
    try s.record(gpa, "stale", t0 - 120 * day);
    try s.record(gpa, "fresh", t0);
    try s.record(gpa, "busy", t0 - 2 * day);
    for (0..20) |_| try s.record(gpa, "busy", t0 - 2 * day);
    try s.record(gpa, "tie-b", t0 - day);
    try s.record(gpa, "tie-a", t0 - day);
    try testing.expectEqual(@as(usize, 1), try s.prune(gpa, t0, max_entries));
    try testing.expect(s.get("stale") == null);
    // Cap at 2: busy (highest frecency), then fresh (frecency 1 > ties' ~0.9).
    try testing.expectEqual(@as(usize, 2), try s.prune(gpa, t0, 2));
    try testing.expect(s.get("busy") != null);
    try testing.expect(s.get("fresh") != null);
    try testing.expectEqual(@as(usize, 2), try s.prune(gpa, t0, 0));
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "unit: palette: usage parse caps huge files" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll("{\"version\":1,\"commands\":{");
    const n = max_entries + 50;
    for (0..n) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("\"cmd.{d}\":{{\"useCount\":{d},\"lastUsedAt\":{d}}}", .{ i, i + 1, t0 });
    }
    try aw.writer.writeAll("}}");
    var s = try Store.parse(gpa, aw.written(), t0);
    defer s.deinit(gpa);
    try testing.expectEqual(max_entries, s.count());
    // The least used ones were dropped.
    try testing.expect(s.get("cmd.0") == null);
    try testing.expect(s.get("cmd.549") != null);
}

test "unit: palette: usage remove forgets an id" {
    const gpa = testing.allocator;
    var s: Store = .empty;
    defer s.deinit(gpa);
    try s.record(gpa, "a", t0);
    try testing.expect(s.remove(gpa, "a"));
    try testing.expect(!s.remove(gpa, "a"));
    try testing.expectEqual(@as(usize, 0), s.count());
}
