//! The handle registry (ARCHITECTURE.md ADR-2.2): every window, workspace,
//! workspace group, pane and surface carries an uppercase UUIDv4 and a
//! per-kind ref ordinal (`workspace:7`) minted when the object is created.
//! Refs are never reused: retiring an object burns its ref, and the
//! high-water mark only grows.
//!
//! Crash safety: `next` never passes `reserved`. Minting past the ceiling
//! first raises it by `reserve_step` and calls `on_reserve`, which the
//! session feature (W1-7) uses to write `STATE\run\handles.json`
//! synchronously before the new ref is handed out; at startup `seed` sets
//! `next = max(snapshot high-water, reserved)`. A crash therefore never
//! re-issues a ref a script may have seen.
//!
//! Pure (std + wmux_proto): the objects are opaque pointers here, so the
//! unit tests run in `zig build test-fast`. model/registry.zig adds the
//! typed lookups and the index resolution over the real model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

pub const Uuid = proto.uuid.Uuid;
pub const Kind = proto.handles.Kind;
pub const Ref = proto.handles.Ref;
pub const Handle = proto.handles.Handle;
pub const HandleText = proto.handles.HandleText;

/// How far one reservation raises a kind's ceiling (ADR-2.2).
pub const reserve_step: u32 = 64;

/// One live object.
pub const Entry = struct {
    kind: Kind,
    ref: u32,
    ptr: *anyopaque,
    /// The Ghostty core surface id (`GHOSTTY_SURFACE_ID`) of a terminal
    /// surface, 0 when none (core ids are never 0).
    core_id: u64 = 0,
};

pub const Error = error{ OutOfMemory, RefsExhausted };

pub const HandleRegistry = struct {
    /// Last ref issued per kind (the high-water mark the session persists).
    next: std.EnumArray(Kind, u32) = .initFill(0),
    /// Persisted reservation ceiling per kind; `next` never passes it.
    reserved: std.EnumArray(Kind, u32) = .initFill(0),
    by_uuid: std.AutoHashMapUnmanaged(Uuid, Entry) = .empty,
    by_ref: std.AutoHashMapUnmanaged(Ref, Uuid) = .empty,
    by_core_id: std.AutoHashMapUnmanaged(u64, Uuid) = .empty,
    /// Called after a mint or an adoption raised a ceiling and before the
    /// new ref is returned (UI thread, synchronous). Null: in memory only.
    on_reserve: ?ReserveHook = null,

    pub const ReserveHook = struct {
        ctx: *anyopaque,
        call: *const fn (ctx: *anyopaque, registry: *const HandleRegistry) void,
    };

    pub fn deinit(self: *HandleRegistry, gpa: Allocator) void {
        self.by_uuid.deinit(gpa);
        self.by_ref.deinit(gpa);
        self.by_core_id.deinit(gpa);
        self.* = undefined;
    }

    /// Start from persisted marks: `next = max(next, high_water, reserved)`
    /// and `reserved = max(reserved, next)` per kind (W1-7 calls this
    /// before restoring a session).
    pub fn seed(
        self: *HandleRegistry,
        high_water: std.EnumArray(Kind, u32),
        reserved: std.EnumArray(Kind, u32),
    ) void {
        for (std.enums.values(Kind)) |k| {
            const n = @max(self.next.get(k), high_water.get(k), reserved.get(k));
            self.next.set(k, n);
            self.reserved.set(k, @max(self.reserved.get(k), n));
        }
    }

    /// Register `ptr` as a new object of `kind` with a fresh UUID and ref.
    pub fn mint(self: *HandleRegistry, gpa: Allocator, kind: Kind, ptr: *anyopaque) Error!Handle {
        return self.mintUuid(gpa, kind, Uuid.nil, ptr);
    }

    /// Like `mint`, but keeps a UUID chosen in advance (a terminal's spawn
    /// identity is fixed before its tab and pane exist). A nil or live
    /// `uuid` gets a fresh one.
    pub fn mintUuid(self: *HandleRegistry, gpa: Allocator, kind: Kind, uuid: Uuid, ptr: *anyopaque) Error!Handle {
        try self.ensureUnusedCapacity(gpa);
        const id = if (uuid.isNil() or self.by_uuid.contains(uuid)) self.freshUuid() else uuid;
        const ref = try self.nextRef(kind);
        self.putAssumeCapacity(kind, id, ref, ptr);
        return .{ .uuid = id, .ref = ref };
    }

    /// Register `ptr` with a saved identity (session restore, ADR-2.7). A
    /// UUID that collides with a live object gets a fresh UUID and ref; a
    /// ref that is 0 or taken by a live object gets a fresh ref. An adopted
    /// ref raises the high-water mark (and the ceiling if needed).
    pub fn adopt(self: *HandleRegistry, gpa: Allocator, kind: Kind, saved: Handle, ptr: *anyopaque) Error!Handle {
        try self.ensureUnusedCapacity(gpa);
        if (saved.uuid.isNil() or self.by_uuid.contains(saved.uuid)) {
            const id = self.freshUuid();
            const ref = try self.nextRef(kind);
            self.putAssumeCapacity(kind, id, ref, ptr);
            return .{ .uuid = id, .ref = ref };
        }
        const ref_taken = saved.ref == 0 or self.by_ref.contains(.{ .kind = kind, .n = saved.ref });
        const ref = if (ref_taken) try self.nextRef(kind) else blk: {
            if (saved.ref > self.next.get(kind)) {
                self.next.set(kind, saved.ref);
                if (saved.ref > self.reserved.get(kind)) self.raiseCeiling(kind, saved.ref);
            }
            break :blk saved.ref;
        };
        self.putAssumeCapacity(kind, saved.uuid, ref, ptr);
        return .{ .uuid = saved.uuid, .ref = ref };
    }

    /// Forget the object `uuid` names (its ref stays burned). No-op for an
    /// unknown UUID.
    pub fn retire(self: *HandleRegistry, uuid: Uuid) void {
        const removed = self.by_uuid.fetchRemove(uuid) orelse return;
        _ = self.by_ref.remove(.{ .kind = removed.value.kind, .n = removed.value.ref });
        if (removed.value.core_id != 0) _ = self.by_core_id.remove(removed.value.core_id);
    }

    /// Record the Ghostty core surface id of the surface `uuid` names, so
    /// legacy decimal/hex surface ids keep resolving (ADR-2.1).
    pub fn bindCoreId(self: *HandleRegistry, gpa: Allocator, uuid: Uuid, core_id: u64) Allocator.Error!void {
        if (core_id == 0) return;
        const e = self.by_uuid.getPtr(uuid) orelse return;
        try self.by_core_id.ensureUnusedCapacity(gpa, 1);
        if (e.core_id != 0) _ = self.by_core_id.remove(e.core_id);
        e.core_id = core_id;
        self.by_core_id.putAssumeCapacity(core_id, uuid);
    }

    /// The live object `uuid` names.
    pub fn entry(self: *const HandleRegistry, uuid: Uuid) ?Entry {
        return self.by_uuid.get(uuid);
    }

    /// The live object of `kind` that `uuid` names, as a `*T`.
    pub fn get(self: *const HandleRegistry, comptime T: type, kind: Kind, uuid: Uuid) ?*T {
        const e = self.by_uuid.get(uuid) orelse return null;
        if (e.kind != kind) return null;
        return @ptrCast(@alignCast(e.ptr));
    }

    /// The UUID of the live object `ref` names.
    pub fn uuidOfRef(self: *const HandleRegistry, ref: Ref) ?Uuid {
        return self.by_ref.get(ref);
    }

    /// The UUID of the live terminal surface with core id `core_id`.
    pub fn uuidOfCoreId(self: *const HandleRegistry, core_id: u64) ?Uuid {
        return self.by_core_id.get(core_id);
    }

    /// The live object of `kind` a UUID, ref or (surfaces) legacy core id
    /// names. Indexes are positional and resolved by the caller in context
    /// (ADR-2.4), so `.index` yields null here.
    pub fn lookup(self: *const HandleRegistry, kind: Kind, text: HandleText) ?Entry {
        const uuid: Uuid = switch (text) {
            .uuid => |u| u,
            .ref => |r| blk: {
                if (r.kind != kind) return null;
                break :blk self.uuidOfRef(r) orelse return null;
            },
            .legacy_core_id => |id| blk: {
                if (kind != .surface) return null;
                break :blk self.uuidOfCoreId(id) orelse return null;
            },
            .index => return null,
        };
        const e = self.by_uuid.get(uuid) orelse return null;
        return if (e.kind == kind) e else null;
    }

    /// The handle of a live object, or null.
    pub fn handleOf(self: *const HandleRegistry, uuid: Uuid) ?Handle {
        const e = self.by_uuid.get(uuid) orelse return null;
        return .{ .uuid = uuid, .ref = e.ref };
    }

    /// Number of live objects.
    pub fn count(self: *const HandleRegistry) usize {
        return self.by_uuid.count();
    }

    fn ensureUnusedCapacity(self: *HandleRegistry, gpa: Allocator) Allocator.Error!void {
        try self.by_uuid.ensureUnusedCapacity(gpa, 1);
        try self.by_ref.ensureUnusedCapacity(gpa, 1);
    }

    fn putAssumeCapacity(self: *HandleRegistry, kind: Kind, uuid: Uuid, ref: u32, ptr: *anyopaque) void {
        self.by_uuid.putAssumeCapacityNoClobber(uuid, .{ .kind = kind, .ref = ref, .ptr = ptr });
        self.by_ref.putAssumeCapacityNoClobber(.{ .kind = kind, .n = ref }, uuid);
    }

    fn freshUuid(self: *const HandleRegistry) Uuid {
        while (true) {
            const u = Uuid.v4();
            if (!self.by_uuid.contains(u)) return u;
        }
    }

    /// Issue the next ref of `kind`, raising (and announcing) the ceiling
    /// first when the ref would pass it.
    fn nextRef(self: *HandleRegistry, kind: Kind) error{RefsExhausted}!u32 {
        const last = self.next.get(kind);
        if (last == std.math.maxInt(u32)) return error.RefsExhausted;
        const n = last + 1;
        if (n > self.reserved.get(kind)) self.raiseCeiling(kind, n);
        self.next.set(kind, n);
        return n;
    }

    /// Raise `kind`'s ceiling in `reserve_step` steps until it covers `n`,
    /// then run the reservation hook.
    fn raiseCeiling(self: *HandleRegistry, kind: Kind, n: u32) void {
        var ceiling = self.reserved.get(kind);
        while (ceiling < n) ceiling = std.math.add(u32, ceiling, reserve_step) catch std.math.maxInt(u32);
        self.reserved.set(kind, ceiling);
        if (self.on_reserve) |hook| hook.call(hook.ctx, self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Obj = struct { tag: u8 };

test "unit: model: registry mints per-kind refs from 1 with fresh uppercase UUIDs" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var a: Obj = .{ .tag = 1 };
    var b: Obj = .{ .tag = 2 };
    var c: Obj = .{ .tag = 3 };
    const ha = try reg.mint(testing.allocator, .workspace, &a);
    const hb = try reg.mint(testing.allocator, .workspace, &b);
    const hc = try reg.mint(testing.allocator, .pane, &c);
    try testing.expectEqual(@as(u32, 1), ha.ref);
    try testing.expectEqual(@as(u32, 2), hb.ref);
    // Refs count per kind.
    try testing.expectEqual(@as(u32, 1), hc.ref);
    try testing.expect(!ha.uuid.eql(hb.uuid));
    try testing.expectEqual(@as(u4, 4), ha.uuid.version());
    try testing.expectEqual(@as(usize, 3), reg.count());
    try testing.expectEqual(&b, reg.get(Obj, .workspace, hb.uuid).?);
    // The wrong kind finds nothing.
    try testing.expectEqual(@as(?*Obj, null), reg.get(Obj, .pane, hb.uuid));
}

test "unit: model: registry resolves uuid, ref and core id but not index" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var tab: Obj = .{ .tag = 7 };
    const h = try reg.mint(testing.allocator, .surface, &tab);
    try reg.bindCoreId(testing.allocator, h.uuid, 0xdeadbeef);

    const by_uuid = reg.lookup(.surface, .{ .uuid = h.uuid }).?;
    try testing.expectEqual(@as(*anyopaque, &tab), by_uuid.ptr);
    try testing.expect(reg.lookup(.surface, .{ .ref = .{ .kind = .surface, .n = h.ref } }) != null);
    try testing.expect(reg.lookup(.surface, .{ .legacy_core_id = 0xdeadbeef }) != null);
    // A ref of another kind, a core id for a non-surface and an index
    // resolve to nothing here.
    try testing.expectEqual(@as(?Entry, null), reg.lookup(.surface, .{ .ref = .{ .kind = .pane, .n = h.ref } }));
    try testing.expectEqual(@as(?Entry, null), reg.lookup(.pane, .{ .uuid = h.uuid }));
    try testing.expectEqual(@as(?Entry, null), reg.lookup(.pane, .{ .legacy_core_id = 0xdeadbeef }));
    try testing.expectEqual(@as(?Entry, null), reg.lookup(.surface, .{ .index = 0 }));
    // Text parsed by wmux_proto resolves the same way.
    const text = h.uuid.toText();
    var lower: [Uuid.text_len]u8 = undefined;
    const parsed = try proto.handles.parseHandle(.surface, std.ascii.lowerString(&lower, &text));
    try testing.expect(reg.lookup(.surface, parsed) != null);
}

test "unit: model: registry never reuses a retired ref" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var objs: [3]Obj = .{ .{ .tag = 0 }, .{ .tag = 1 }, .{ .tag = 2 } };
    const h1 = try reg.mint(testing.allocator, .pane, &objs[0]);
    const h2 = try reg.mint(testing.allocator, .pane, &objs[1]);
    reg.retire(h2.uuid);
    reg.retire(h2.uuid); // idempotent
    try testing.expectEqual(@as(?Uuid, null), reg.uuidOfRef(.{ .kind = .pane, .n = h2.ref }));
    const h3 = try reg.mint(testing.allocator, .pane, &objs[2]);
    try testing.expectEqual(@as(u32, 3), h3.ref);
    try testing.expect(reg.lookup(.pane, .{ .uuid = h1.uuid }) != null);
    try testing.expectEqual(@as(?Entry, null), reg.lookup(.pane, .{ .uuid = h2.uuid }));
    try testing.expectEqual(@as(usize, 2), reg.count());
}

test "unit: model: registry retire drops the core id binding" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var tab: Obj = .{ .tag = 1 };
    const h = try reg.mint(testing.allocator, .surface, &tab);
    try reg.bindCoreId(testing.allocator, h.uuid, 42);
    try testing.expect(reg.uuidOfCoreId(42).?.eql(h.uuid));
    reg.retire(h.uuid);
    try testing.expectEqual(@as(?Uuid, null), reg.uuidOfCoreId(42));
}

test "unit: model: registry mintUuid keeps a chosen UUID unless it is taken" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var a: Obj = .{ .tag = 1 };
    var b: Obj = .{ .tag = 2 };
    const chosen = Uuid.v4();
    const ha = try reg.mintUuid(testing.allocator, .surface, chosen, &a);
    try testing.expect(ha.uuid.eql(chosen));
    // The same UUID again collides with a live object: a fresh one.
    const hb = try reg.mintUuid(testing.allocator, .surface, chosen, &b);
    try testing.expect(!hb.uuid.eql(chosen));
    try testing.expectEqual(@as(u32, 2), hb.ref);
}

test "unit: model: registry adopt keeps saved identities and mints on collision" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var objs: [4]Obj = .{ .{ .tag = 0 }, .{ .tag = 1 }, .{ .tag = 2 }, .{ .tag = 3 } };
    const saved: Handle = .{ .uuid = Uuid.v4(), .ref = 12 };
    const h = try reg.adopt(testing.allocator, .workspace, saved, &objs[0]);
    try testing.expect(h.uuid.eql(saved.uuid));
    try testing.expectEqual(@as(u32, 12), h.ref);
    // The adopted ref raised the high-water mark: the next mint is 13.
    try testing.expectEqual(@as(u32, 13), (try reg.mint(testing.allocator, .workspace, &objs[1])).ref);
    // A live UUID collision (restore-session --from) gets a fresh UUID and ref.
    const dup = try reg.adopt(testing.allocator, .workspace, saved, &objs[2]);
    try testing.expect(!dup.uuid.eql(saved.uuid));
    try testing.expectEqual(@as(u32, 14), dup.ref);
    // A free UUID whose ref is taken keeps the UUID with a fresh ref.
    const other: Handle = .{ .uuid = Uuid.v4(), .ref = 12 };
    const moved = try reg.adopt(testing.allocator, .workspace, other, &objs[3]);
    try testing.expect(moved.uuid.eql(other.uuid));
    try testing.expectEqual(@as(u32, 15), moved.ref);
}

test "unit: model: registry reservation raises the ceiling in steps before issuing" {
    const Recorder = struct {
        calls: usize = 0,
        last_ceiling: u32 = 0,
        last_next: u32 = 0,

        fn call(ctx: *anyopaque, r: *const HandleRegistry) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.last_ceiling = r.reserved.get(.surface);
            self.last_next = r.next.get(.surface);
        }
    };
    var rec: Recorder = .{};
    var reg: HandleRegistry = .{ .on_reserve = .{ .ctx = &rec, .call = Recorder.call } };
    defer reg.deinit(testing.allocator);
    var obj: Obj = .{ .tag = 0 };
    _ = try reg.mint(testing.allocator, .surface, &obj);
    // The first ref needed a reservation, announced before `next` moved.
    try testing.expectEqual(@as(usize, 1), rec.calls);
    try testing.expectEqual(reserve_step, rec.last_ceiling);
    try testing.expectEqual(@as(u32, 0), rec.last_next);
    var i: u32 = 1;
    while (i < reserve_step) : (i += 1) {
        const h = try reg.mint(testing.allocator, .surface, &obj);
        reg.retire(h.uuid);
    }
    try testing.expectEqual(@as(usize, 1), rec.calls);
    _ = try reg.mint(testing.allocator, .surface, &obj);
    try testing.expectEqual(@as(usize, 2), rec.calls);
    try testing.expectEqual(2 * reserve_step, rec.last_ceiling);
    try testing.expectEqual(reserve_step, rec.last_next);
}

test "unit: model: registry seed round trips the persisted marks" {
    // What the session persists (next and reserved) and seeds back after a
    // restart: no ref issued before the restart is issued again.
    var before: HandleRegistry = .{};
    var obj: Obj = .{ .tag = 0 };
    for (0..5) |_| _ = try before.mint(testing.allocator, .workspace, &obj);
    const persisted_next = before.next;
    const persisted_reserved = before.reserved;
    before.deinit(testing.allocator);

    var after: HandleRegistry = .{};
    defer after.deinit(testing.allocator);
    after.seed(persisted_next, persisted_reserved);
    // Crash-safe: the next ref starts above the persisted ceiling.
    const h = try after.mint(testing.allocator, .workspace, &obj);
    try testing.expectEqual(reserve_step + 1, h.ref);
    try testing.expectEqual(@as(u32, 1), (try after.mint(testing.allocator, .window, &obj)).ref);

    // A clean snapshot whose high-water mark is above the ceiling wins too.
    var hw = std.EnumArray(Kind, u32).initFill(0);
    hw.set(.pane, 500);
    after.seed(hw, std.EnumArray(Kind, u32).initFill(0));
    try testing.expectEqual(@as(u32, 501), (try after.mint(testing.allocator, .pane, &obj)).ref);
}

test "unit: model: registry handle text round trips through refs" {
    var reg: HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var obj: Obj = .{ .tag = 0 };
    _ = try reg.mint(testing.allocator, .workspace_group, &obj);
    const h = try reg.mint(testing.allocator, .workspace_group, &obj);
    var buf: [Ref.max_text_len]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{h.refOf(.workspace_group)});
    try testing.expectEqualStrings("workspace_group:2", text);
    const parsed = try proto.handles.parseHandle(.workspace_group, text);
    try testing.expect(reg.lookup(.workspace_group, parsed).?.ref == 2);
    try testing.expect(reg.handleOf(h.uuid).?.uuid.eql(h.uuid));
}
