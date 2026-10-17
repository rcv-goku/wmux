//! The resolved settings snapshot (ARCHITECTURE.md ADR-5.2): immutable
//! once published, refcounted so worker threads can keep reading one
//! while the UI thread swaps in the next, and swapped atomically by
//! `Holder`. The UI thread reads `Holder.current` directly; any other
//! thread takes `Holder.acquire` and `release`s when done.

const std = @import("std");
const proto = @import("wmux_proto");

const layers = @import("logic/layers.zig");

const Allocator = std.mem.Allocator;
const resolve = proto.settings.resolve;

/// A file the snapshot was built from (or looked for), for the watcher.
pub const FileRecord = struct {
    pub const Kind = enum { cmux_json, wmux_json, pack, project, policy_file };

    kind: Kind,
    path: []const u8,
    /// Content hash at load time; null when the file did not exist.
    hash: ?u64,
};

pub const Snapshot = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    /// Revision: 1 for the startup snapshot, +1 for every successful
    /// reload (set by the UI thread when it publishes the snapshot).
    rev: u64 = 0,
    resolved: resolve.Resolved,
    /// Owns everything below.
    arena: std.heap.ArenaAllocator,
    files: []const FileRecord = &.{},
    /// Merged `actions` / `commands` JSON across packs, cmux.json,
    /// wmux.json and the project file (id-keyed overrides), or null.
    actions_json: ?[]const u8 = null,
    commands_json: ?[]const u8 = null,
    /// The generated Ghostty overrides file contents for this snapshot.
    ghostty_overrides: []const u8 = "",
    /// Non-fatal problems found while loading (missing pack, bad pack
    /// entry, newer schemaVersion), for the log and `config doctor`.
    warnings: []const layers.FileError = &.{},

    /// A new snapshot owning `resolved`, with one reference.
    pub fn create(gpa: Allocator, resolved: resolve.Resolved) Allocator.Error!*Snapshot {
        const self = try gpa.create(Snapshot);
        self.* = .{ .gpa = gpa, .resolved = resolved, .arena = .init(gpa) };
        return self;
    }

    /// The allocator for strings the snapshot owns.
    pub fn allocator(self: *Snapshot) Allocator {
        return self.arena.allocator();
    }

    pub fn retain(self: *Snapshot) *Snapshot {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    /// Drops one reference; the last one frees the snapshot.
    pub fn release(self: *Snapshot) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.resolved.deinit();
        self.arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn get(self: *const Snapshot, path: []const u8) ?*const resolve.Entry {
        return self.resolved.get(path);
    }
};

/// The current snapshot. `swap` and `current` are UI-thread operations;
/// `acquire` may be called from any thread.
pub const Holder = struct {
    mutex: std.Thread.Mutex = .{},
    snap: ?*Snapshot = null,

    /// The current snapshot, borrowed (UI thread: valid until the next
    /// `swap`, which only the UI thread performs).
    pub fn current(self: *Holder) ?*Snapshot {
        return self.snap;
    }

    /// The current snapshot with an extra reference (any thread); the
    /// caller `release`s it.
    pub fn acquire(self: *Holder) ?*Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.snap orelse return null;
        return s.retain();
    }

    /// Publishes `next` (taking over its reference) and returns the
    /// previous snapshot, whose reference the caller now owns.
    pub fn swap(self: *Holder, next: ?*Snapshot) ?*Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const prev = self.snap;
        self.snap = next;
        return prev;
    }
};

const testing = std.testing;

test "unit: settings: snapshots are refcounted and swapped atomically" {
    const gpa = testing.allocator;
    const fixtures: []const proto.settings.spec.Spec = &proto.settings.validate.test_fixture_specs;
    var holder: Holder = .{};
    try testing.expect(holder.acquire() == null);

    const a = try Snapshot.create(gpa, try resolve.resolve(gpa, fixtures, &.{}, &.{}));
    a.rev = 1;
    a.files = try a.allocator().dupe(FileRecord, &.{.{ .kind = .wmux_json, .path = "w", .hash = 1 }});
    try testing.expect(holder.swap(a) == null);

    // A worker holds rev 1 across the swap to rev 2.
    const held = holder.acquire().?;
    const b = try Snapshot.create(gpa, try resolve.resolve(gpa, fixtures, &.{}, &.{}));
    b.rev = 2;
    const prev = holder.swap(b).?;
    prev.release();
    try testing.expectEqual(@as(u64, 1), held.rev);
    try testing.expectEqualStrings("system", held.get("app.appearance").?.value.asString().?);
    held.release(); // frees rev 1
    try testing.expectEqual(@as(u64, 2), holder.current().?.rev);
    holder.swap(null).?.release();
}
