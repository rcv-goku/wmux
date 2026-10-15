//! Small least-recently-used cache with owned byte-string keys. The gfx text
//! system keeps DirectWrite text layouts in one (values are COM pointers,
//! released by the evict callback). Keys are compared exactly, so hash
//! collisions can never return the wrong layout.
//!
//! Eviction scans for the oldest entry: O(capacity) per insert into a full
//! cache, fine for the few hundred entries a sidebar needs. std-only.
const std = @import("std");

pub fn LruCache(comptime V: type) type {
    return struct {
        const Self = @This();

        /// Called with every value that leaves the cache (eviction,
        /// replacement, `clear`, `deinit`).
        pub const EvictFn = *const fn (ctx: ?*anyopaque, value: V) void;

        const Entry = struct {
            key: []u8,
            value: V,
            tick: u64,
        };

        gpa: std.mem.Allocator,
        capacity: usize,
        entries: std.ArrayListUnmanaged(Entry) = .empty,
        /// Key bytes are owned by `entries[i].key` (separate allocations, so
        /// they stay put when entries move).
        index: std.StringHashMapUnmanaged(usize) = .empty,
        tick: u64 = 0,
        evict_ctx: ?*anyopaque = null,
        evict_fn: ?EvictFn = null,
        hits: u64 = 0,
        misses: u64 = 0,

        pub fn init(gpa: std.mem.Allocator, capacity: usize, evict_ctx: ?*anyopaque, evict_fn: ?EvictFn) Self {
            return .{ .gpa = gpa, .capacity = @max(capacity, 1), .evict_ctx = evict_ctx, .evict_fn = evict_fn };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.entries.deinit(self.gpa);
            self.index.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// Value for `key` (marks it most recently used).
        pub fn get(self: *Self, key: []const u8) ?V {
            const i = self.index.get(key) orelse {
                self.misses += 1;
                return null;
            };
            self.hits += 1;
            self.tick += 1;
            self.entries.items[i].tick = self.tick;
            return self.entries.items[i].value;
        }

        /// Insert or replace. On success the cache owns `value`; on error it
        /// does not (the caller still owns it).
        pub fn put(self: *Self, key: []const u8, value: V) std.mem.Allocator.Error!void {
            self.tick += 1;
            if (self.index.get(key)) |i| {
                const e = &self.entries.items[i];
                self.evict(e.value);
                e.value = value;
                e.tick = self.tick;
                return;
            }
            const owned = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned);
            try self.entries.ensureUnusedCapacity(self.gpa, 1);
            try self.index.ensureUnusedCapacity(self.gpa, 1);
            if (self.entries.items.len >= self.capacity) self.removeAt(self.oldest());
            self.entries.appendAssumeCapacity(.{ .key = owned, .value = value, .tick = self.tick });
            self.index.putAssumeCapacityNoClobber(owned, self.entries.items.len - 1);
        }

        /// Remove `key` if present (its value is evicted).
        pub fn remove(self: *Self, key: []const u8) bool {
            const i = self.index.get(key) orelse return false;
            self.removeAt(i);
            return true;
        }

        /// Evict everything (e.g. after a font or DPI setting changes).
        pub fn clear(self: *Self) void {
            for (self.entries.items) |e| {
                self.evict(e.value);
                self.gpa.free(e.key);
            }
            self.entries.clearRetainingCapacity();
            self.index.clearRetainingCapacity();
        }

        fn evict(self: *Self, value: V) void {
            if (self.evict_fn) |f| f(self.evict_ctx, value);
        }

        fn oldest(self: *const Self) usize {
            var best: usize = 0;
            for (self.entries.items, 0..) |e, i| {
                if (e.tick < self.entries.items[best].tick) best = i;
            }
            return best;
        }

        fn removeAt(self: *Self, i: usize) void {
            const e = self.entries.items[i];
            _ = self.index.remove(e.key);
            self.evict(e.value);
            self.gpa.free(e.key);
            _ = self.entries.swapRemove(i);
            if (i < self.entries.items.len) {
                self.index.getPtr(self.entries.items[i].key).?.* = i;
            }
        }
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Recorder = struct {
    evicted: std.ArrayListUnmanaged(u32) = .empty,

    fn onEvict(ctx: ?*anyopaque, v: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.evicted.append(testing.allocator, v) catch unreachable;
    }
};

test "unit: gfx: lru evicts the least recently used entry" {
    var rec: Recorder = .{};
    defer rec.evicted.deinit(testing.allocator);
    var cache = LruCache(u32).init(testing.allocator, 3, &rec, Recorder.onEvict);
    defer cache.deinit();

    try cache.put("a", 1);
    try cache.put("b", 2);
    try cache.put("c", 3);
    try testing.expectEqual(@as(?u32, 1), cache.get("a")); // a is now newest
    try cache.put("d", 4); // evicts b
    try testing.expectEqualSlices(u32, &.{2}, rec.evicted.items);
    try testing.expect(cache.get("b") == null);
    try testing.expectEqual(@as(?u32, 3), cache.get("c"));
    try testing.expectEqual(@as(?u32, 4), cache.get("d"));
    try testing.expectEqual(@as(usize, 3), cache.count());
    try testing.expectEqual(@as(u64, 1), cache.misses);
}

test "unit: gfx: lru replaces, removes and clears with eviction callbacks" {
    var rec: Recorder = .{};
    defer rec.evicted.deinit(testing.allocator);
    var cache = LruCache(u32).init(testing.allocator, 4, &rec, Recorder.onEvict);
    defer cache.deinit();

    try cache.put("k", 1);
    try cache.put("k", 2); // replacement evicts the old value
    try testing.expectEqualSlices(u32, &.{1}, rec.evicted.items);
    try testing.expectEqual(@as(?u32, 2), cache.get("k"));
    try testing.expectEqual(@as(usize, 1), cache.count());

    try cache.put("x", 10);
    try cache.put("y", 11);
    try testing.expect(cache.remove("k"));
    try testing.expect(!cache.remove("k"));
    // swapRemove moved an entry; its index must still resolve.
    try testing.expectEqual(@as(?u32, 10), cache.get("x"));
    try testing.expectEqual(@as(?u32, 11), cache.get("y"));

    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.count());
    // `clear` evicts in storage order; compare as a set.
    std.mem.sort(u32, rec.evicted.items, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 10, 11 }, rec.evicted.items);
    try cache.put("again", 5);
    try testing.expectEqual(@as(?u32, 5), cache.get("again"));
}

test "unit: gfx: lru keys are copied and compared exactly" {
    var cache = LruCache(u32).init(testing.allocator, 8, null, null);
    defer cache.deinit();
    var buf = [_]u8{ 'a', 'b', 'c' };
    try cache.put(&buf, 7);
    buf[0] = 'z'; // mutating the caller's buffer must not affect the key
    try testing.expectEqual(@as(?u32, 7), cache.get("abc"));
    try testing.expect(cache.get("zbc") == null);
    try testing.expect(cache.get("ab") == null);
}

test "unit: gfx: lru churn keeps the index consistent" {
    var cache = LruCache(u32).init(testing.allocator, 16, null, null);
    defer cache.deinit();
    var key_buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i % 37}) catch unreachable;
        if (cache.get(key)) |v| {
            try testing.expectEqual(i % 37, v);
        } else {
            try cache.put(key, i % 37);
        }
        try testing.expect(cache.count() <= 16);
    }
    for (cache.entries.items, 0..) |e, idx| {
        try testing.expectEqual(idx, cache.index.get(e.key).?);
    }
}
