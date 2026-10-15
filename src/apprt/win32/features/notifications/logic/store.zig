//! Notification record store (ADR-7.1): records newest first, cmux replacement
//! semantics, muted-workspace admission, history cap that evicts the oldest
//! read records first, and dismissal tombstones. Pure: records reference
//! workspaces and surfaces by UUID string, never by pointer.

const std = @import("std");

/// Canonical uppercase 8-4-4-4-12 UUID text (ADR-2.1). Local until
/// `wmux_proto/uuid.zig` (W0-P1) is filled; `parseUuid` normalizes input.
pub const Uuid = [36]u8;

pub const IdList = std.ArrayList(Uuid);

/// Parses a UUID case-insensitively (braces tolerated) into canonical form.
pub fn parseUuid(s: []const u8) ?Uuid {
    var t = s;
    if (t.len == 38 and t[0] == '{' and t[37] == '}') t = t[1..37];
    if (t.len != 36) return null;
    var out: Uuid = undefined;
    for (t, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return null;
            out[i] = '-';
        } else {
            if (!std.ascii.isHex(c)) return null;
            out[i] = std.ascii.toUpper(c);
        }
    }
    return out;
}

/// Random version-4 UUID in canonical form.
pub fn randomUuid(r: std.Random) Uuid {
    var b: [16]u8 = undefined;
    r.bytes(&b);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    const hex = "0123456789ABCDEF";
    var out: Uuid = undefined;
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 0x0F];
        o += 2;
    }
    return out;
}

pub fn uuidEql(a: Uuid, b: Uuid) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn optUuidEql(a: ?Uuid, b: ?Uuid) bool {
    if (a == null or b == null) return a == null and b == null;
    return uuidEql(a.?, b.?);
}

/// Placeholder scroll anchor (cmux "scroll position"); the terminal side owns
/// the final shape (W2-5).
pub const ScreenAnchor = struct {
    row: i64 = 0,
    col: u32 = 0,
};

/// Delivery effects (cmux hook `effects` keys).
pub const Effects = struct {
    record: bool = true,
    mark_unread: bool = true,
    reorder_workspace: bool = true,
    desktop: bool = true,
    sound: bool = true,
    command: bool = true,
    pane_flash: bool = true,
};

pub const Origin = union(enum) {
    local,
    /// Workspace UUID of the `cmux ssh` host relay.
    ssh_relay: Uuid,
};

pub const AgentCategory = enum { turn_complete, needs_permission, idle_reminder, other };

pub const Agent = struct {
    kind: []const u8,
    category: AgentCategory,
    session_id: ?[]const u8 = null,
    is_subagent: bool = false,
    pending_background: bool = false,
};

pub const ClickAction = union(enum) {
    open_file: []const u8,
    open_url: []const u8,
    reply,
};

pub const ReplyShape = enum { none, text };

/// A notification record. Strings are owned by the store once added; when
/// passed to `Store.add` they are borrowed and copied.
pub const Record = struct {
    id: Uuid,
    workspace: Uuid,
    surface: ?Uuid,
    title: []const u8 = "",
    subtitle: []const u8 = "",
    body: []const u8 = "",
    created_at_ms: i64,
    read: bool = false,
    origin: Origin = .local,
    agent: ?Agent = null,
    correlation_key: ?Uuid = null,
    click_action: ?ClickAction = null,
    reply_shape: ReplyShape = .none,
    scroll_anchor: ?ScreenAnchor = null,
    effects: Effects = .{},

    /// Deep copy of every string.
    pub fn clone(self: Record, gpa: std.mem.Allocator) !Record {
        var r = self;
        r.title = "";
        r.subtitle = "";
        r.body = "";
        r.agent = null;
        r.click_action = null;
        errdefer r.deinit(gpa);
        r.title = try gpa.dupe(u8, self.title);
        r.subtitle = try gpa.dupe(u8, self.subtitle);
        r.body = try gpa.dupe(u8, self.body);
        if (self.click_action) |ca| {
            // Built in a temporary so a failed dupe never leaves a
            // half-written union in `r`.
            const copy: ClickAction = switch (ca) {
                .open_file => |p| .{ .open_file = try gpa.dupe(u8, p) },
                .open_url => |u| .{ .open_url = try gpa.dupe(u8, u) },
                .reply => .reply,
            };
            r.click_action = copy;
        }
        if (self.agent) |a| {
            const kind = try gpa.dupe(u8, a.kind);
            errdefer gpa.free(kind);
            const sid = if (a.session_id) |s| try gpa.dupe(u8, s) else null;
            r.agent = .{
                .kind = kind,
                .category = a.category,
                .session_id = sid,
                .is_subagent = a.is_subagent,
                .pending_background = a.pending_background,
            };
        }
        return r;
    }

    /// Frees strings of a record produced by `clone`.
    pub fn deinit(self: *Record, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.subtitle);
        gpa.free(self.body);
        if (self.agent) |a| {
            gpa.free(a.kind);
            if (a.session_id) |s| gpa.free(s);
        }
        if (self.click_action) |ca| switch (ca) {
            .open_file => |p| gpa.free(p),
            .open_url => |u| gpa.free(u),
            .reply => {},
        };
        self.* = undefined;
    }

    pub fn isAgentAttention(self: Record) bool {
        const a = self.agent orelse return false;
        return a.category == .needs_permission;
    }
};

/// Which records an operation applies to.
pub const Scope = union(enum) {
    all,
    /// Every record of the workspace (surface-level and workspace-level).
    workspace: Uuid,
    /// Only the workspace's own records (`surface == null`).
    workspace_own: Uuid,
    /// Records of one surface (surface UUIDs are globally unique).
    surface: Uuid,

    pub fn matches(self: Scope, r: Record) bool {
        return switch (self) {
            .all => true,
            .workspace => |w| uuidEql(r.workspace, w),
            .workspace_own => |w| r.surface == null and uuidEql(r.workspace, w),
            .surface => |s| r.surface != null and uuidEql(r.surface.?, s),
        };
    }
};

pub const AddStatus = enum {
    added,
    /// Workspace is muted: dropped entirely.
    dropped_muted,
    /// The id was dismissed earlier.
    dropped_tombstoned,
    /// `effects.record == false`: nothing is stored.
    dropped_not_recorded,
    /// A record with this id already exists.
    dropped_duplicate,
};

pub const AddResult = struct {
    status: AddStatus,
    /// Records superseded by the new one (withdraw their toasts).
    replaced: IdList = .empty,
    /// Records evicted by the history cap (withdraw their toasts).
    evicted: IdList = .empty,

    pub fn deinit(self: *AddResult, gpa: std.mem.Allocator) void {
        self.replaced.deinit(gpa);
        self.evicted.deinit(gpa);
    }
};

pub const default_history_limit: usize = 500;
/// Bound on remembered dismissals; the oldest tombstones are forgotten first.
pub const max_tombstones: usize = 4096;

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Newest first.
    records: std.ArrayList(Record) = .empty,
    /// Dismissed record id -> its workspace, in dismissal order.
    tombstones: std.AutoArrayHashMapUnmanaged(Uuid, Uuid) = .empty,
    muted: std.AutoHashMapUnmanaged(Uuid, void) = .empty,
    /// `wmux.notifications.historyLimit`; values below 1 act as 1.
    history_limit: usize = default_history_limit,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.records.items) |*r| r.deinit(self.gpa);
        self.records.deinit(self.gpa);
        self.tombstones.deinit(self.gpa);
        self.muted.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn setMuted(self: *Store, workspace: Uuid, muted: bool) !void {
        if (muted) {
            try self.muted.put(self.gpa, workspace, {});
        } else {
            _ = self.muted.remove(workspace);
        }
    }

    pub fn isMuted(self: *const Store, workspace: Uuid) bool {
        return self.muted.contains(workspace);
    }

    pub fn isTombstoned(self: *const Store, id: Uuid) bool {
        return self.tombstones.contains(id);
    }

    pub fn indexOf(self: *const Store, id: Uuid) ?usize {
        for (self.records.items, 0..) |r, i| {
            if (uuidEql(r.id, id)) return i;
        }
        return null;
    }

    pub fn find(self: *Store, id: Uuid) ?*Record {
        const i = self.indexOf(id) orelse return null;
        return &self.records.items[i];
    }

    /// Newest record matching `scope`.
    pub fn latest(self: *Store, scope: Scope) ?*Record {
        for (self.records.items) |*r| {
            if (scope.matches(r.*)) return r;
        }
        return null;
    }

    /// Adds a copy of `template` (strings borrowed) at the newest position.
    /// Without a correlation key, every earlier record of the same
    /// (workspace, surface) is replaced; with one, only records on that
    /// surface carrying the same key are.
    pub fn add(self: *Store, template: Record) !AddResult {
        var result: AddResult = .{ .status = .added };
        errdefer result.deinit(self.gpa);
        if (self.isMuted(template.workspace)) return .{ .status = .dropped_muted };
        if (self.isTombstoned(template.id)) return .{ .status = .dropped_tombstoned };
        if (!template.effects.record) return .{ .status = .dropped_not_recorded };
        if (self.indexOf(template.id) != null) return .{ .status = .dropped_duplicate };

        var rec = try template.clone(self.gpa);
        errdefer rec.deinit(self.gpa);
        // Reserve everything up front so nothing below can fail half-way.
        try self.records.ensureUnusedCapacity(self.gpa, 1);
        try result.replaced.ensureTotalCapacity(self.gpa, self.records.items.len);
        try result.evicted.ensureTotalCapacity(self.gpa, self.records.items.len + 1);

        var i: usize = 0;
        while (i < self.records.items.len) {
            const r = self.records.items[i];
            if (supersedes(template, r)) {
                result.replaced.appendAssumeCapacity(r.id);
                var old = self.records.orderedRemove(i);
                old.deinit(self.gpa);
            } else i += 1;
        }
        self.records.insertAssumeCapacity(0, rec);
        self.enforceLimit(&result.evicted);
        return result;
    }

    fn supersedes(new: Record, old: Record) bool {
        if (!uuidEql(new.workspace, old.workspace)) return false;
        if (!optUuidEql(new.surface, old.surface)) return false;
        if (new.correlation_key) |k| {
            const ok = old.correlation_key orelse return false;
            return uuidEql(k, ok);
        }
        return true;
    }

    /// Evicts oldest read records first, then oldest unread, never the
    /// newest record. `out` must have capacity for every eviction.
    fn enforceLimit(self: *Store, out: *IdList) void {
        const limit = @max(self.history_limit, 1);
        while (self.records.items.len > limit) {
            var victim: usize = self.records.items.len - 1;
            var j: usize = self.records.items.len;
            while (j > 1) {
                j -= 1;
                if (self.records.items[j].read) {
                    victim = j;
                    break;
                }
            }
            out.appendAssumeCapacity(self.records.items[victim].id);
            var old = self.records.orderedRemove(victim);
            old.deinit(self.gpa);
        }
    }

    /// Applies a new history limit, evicting as `add` would.
    pub fn setHistoryLimit(self: *Store, limit: usize, out: ?*IdList) !void {
        self.history_limit = limit;
        var tmp: IdList = .empty;
        defer tmp.deinit(self.gpa);
        try tmp.ensureTotalCapacity(self.gpa, self.records.items.len);
        self.enforceLimit(&tmp);
        if (out) |o| try o.appendSlice(self.gpa, tmp.items);
    }

    pub fn markRead(self: *Store, id: Uuid) bool {
        const r = self.find(id) orelse return false;
        if (r.read) return false;
        r.read = true;
        return true;
    }

    pub fn markUnread(self: *Store, id: Uuid) bool {
        const r = self.find(id) orelse return false;
        if (!r.read) return false;
        r.read = false;
        return true;
    }

    /// Marks matching unread records read; appends their ids to `out`.
    pub fn markReadScope(self: *Store, scope: Scope, out: ?*IdList) !usize {
        var n: usize = 0;
        for (self.records.items) |*r| {
            if (r.read or !scope.matches(r.*)) continue;
            if (out) |o| try o.append(self.gpa, r.id);
            r.read = true;
            n += 1;
        }
        return n;
    }

    pub fn countUnread(self: *const Store, scope: Scope) usize {
        var n: usize = 0;
        for (self.records.items) |r| {
            if (!r.read and scope.matches(r)) n += 1;
        }
        return n;
    }

    pub fn count(self: *const Store, scope: Scope) usize {
        var n: usize = 0;
        for (self.records.items) |r| {
            if (scope.matches(r)) n += 1;
        }
        return n;
    }

    fn tombstone(self: *Store, id: Uuid, workspace: Uuid) !void {
        try self.tombstones.ensureUnusedCapacity(self.gpa, 1);
        self.tombstoneAssumeCapacity(id, workspace);
    }

    fn tombstoneAssumeCapacity(self: *Store, id: Uuid, workspace: Uuid) void {
        self.tombstones.putAssumeCapacity(id, workspace);
        while (self.tombstones.count() > max_tombstones) self.tombstones.orderedRemoveAt(0);
    }

    /// Removes one record and tombstones its id.
    pub fn dismiss(self: *Store, id: Uuid) !bool {
        const i = self.indexOf(id) orelse return false;
        try self.tombstones.ensureUnusedCapacity(self.gpa, 1);
        var r = self.records.orderedRemove(i);
        self.tombstoneAssumeCapacity(r.id, r.workspace);
        r.deinit(self.gpa);
        return true;
    }

    /// Removes matching records (`read_only` restricts to read ones); with
    /// `tombstone_ids` their ids are tombstoned. Removed ids go to `out`.
    pub fn removeScope(self: *Store, scope: Scope, opts: struct {
        read_only: bool = false,
        tombstone_ids: bool = true,
    }, out: ?*IdList) !usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.records.items.len) {
            const r = self.records.items[i];
            if (!scope.matches(r) or (opts.read_only and !r.read)) {
                i += 1;
                continue;
            }
            if (out) |o| try o.append(self.gpa, r.id);
            if (opts.tombstone_ids) try self.tombstone(r.id, r.workspace);
            var old = self.records.orderedRemove(i);
            old.deinit(self.gpa);
            n += 1;
        }
        return n;
    }

    /// Marks `id` unread and moves it just after the last other unread
    /// record, so it becomes the oldest unread (cmux "mark as oldest unread").
    pub fn moveToOldestUnread(self: *Store, id: Uuid) bool {
        const from = self.indexOf(id) orelse return false;
        var rec = self.records.orderedRemove(from);
        rec.read = false;
        var dest: usize = 0;
        for (self.records.items, 0..) |r, i| {
            if (!r.read) dest = i + 1;
        }
        self.records.insertAssumeCapacity(dest, rec);
        return true;
    }

    /// Moves every record of `surface` to `workspace` (pane moved).
    pub fn retargetSurface(self: *Store, surface: Uuid, workspace: Uuid) usize {
        var n: usize = 0;
        for (self.records.items) |*r| {
            if (r.surface != null and uuidEql(r.surface.?, surface) and !uuidEql(r.workspace, workspace)) {
                r.workspace = workspace;
                n += 1;
            }
        }
        return n;
    }

    /// Inserts a restored record ordered by `created_at_ms` (newest first,
    /// after existing records with the same time). No replacement, no cap.
    pub fn insertRestored(self: *Store, template: Record) !AddStatus {
        if (self.isTombstoned(template.id)) return .dropped_tombstoned;
        if (self.indexOf(template.id) != null) return .dropped_duplicate;
        try self.records.ensureUnusedCapacity(self.gpa, 1);
        const rec = try template.clone(self.gpa);
        var pos: usize = self.records.items.len;
        for (self.records.items, 0..) |r, i| {
            if (r.created_at_ms < template.created_at_ms) {
                pos = i;
                break;
            }
        }
        self.records.insertAssumeCapacity(pos, rec);
        return .added;
    }

    /// Restores a tombstone (from persistence).
    pub fn addTombstone(self: *Store, id: Uuid, workspace: Uuid) !void {
        try self.tombstone(id, workspace);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

pub fn testUuid(n: u32) Uuid {
    var buf: Uuid = undefined;
    _ = std.fmt.bufPrint(&buf, "00000000-0000-4000-8000-{X:0>12}", .{n}) catch unreachable;
    return buf;
}

const ws_a = testUuid(0xA0);
const ws_b = testUuid(0xB0);
const sf_1 = testUuid(0x1);
const sf_2 = testUuid(0x2);

fn mk(id: u32, ws: Uuid, sf: ?Uuid, t: i64) Record {
    return .{ .id = testUuid(id), .workspace = ws, .surface = sf, .title = "t", .body = "b", .created_at_ms = t };
}

fn addOk(s: *Store, r: Record) !void {
    var res = try s.add(r);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(AddStatus.added, res.status);
}

test "unit: notifications: parseUuid normalizes case and braces" {
    const want = "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D";
    try testing.expectEqualStrings(want, &parseUuid("0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d").?);
    try testing.expectEqualStrings(want, &parseUuid("{0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D}").?);
    try testing.expect(parseUuid("") == null);
    try testing.expect(parseUuid("0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3") == null);
    try testing.expect(parseUuid("0A1B2C3D_4E5F-4A6B-8C7D-8E9F0A1B2C3D") == null);
    try testing.expect(parseUuid("GA1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D") == null);
    try testing.expect(parseUuid("{0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D") == null);
}

test "unit: notifications: randomUuid is canonical v4" {
    var prng = std.Random.DefaultPrng.init(42);
    const u = randomUuid(prng.random());
    try testing.expect(parseUuid(&u) != null);
    try testing.expectEqualStrings(&u, &parseUuid(&u).?);
    try testing.expectEqual(@as(u8, '4'), u[14]);
    try testing.expect(std.mem.indexOfScalar(u8, "89AB", u[19]) != null);
}

test "unit: notifications: second notify from one pane replaces the first" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try addOk(&s, mk(1, ws_a, sf_1, 1));
    var res = try s.add(mk(2, ws_a, sf_1, 2));
    defer res.deinit(testing.allocator);
    try testing.expectEqual(AddStatus.added, res.status);
    try testing.expectEqual(@as(usize, 1), s.records.items.len);
    try testing.expectEqualStrings(&testUuid(2), &s.records.items[0].id);
    try testing.expectEqual(@as(usize, 1), res.replaced.items.len);
    try testing.expectEqualStrings(&testUuid(1), &res.replaced.items[0]);
}

test "unit: notifications: different panes keep separate rows newest first" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try addOk(&s, mk(1, ws_a, sf_1, 1));
    try addOk(&s, mk(2, ws_a, sf_2, 2));
    try addOk(&s, mk(3, ws_a, null, 3));
    try testing.expectEqual(@as(usize, 3), s.records.items.len);
    try testing.expectEqualStrings(&testUuid(3), &s.records.items[0].id);
    try testing.expectEqualStrings(&testUuid(1), &s.records.items[2].id);
    // Workspace-level record replaces only the workspace-level one.
    try addOk(&s, mk(4, ws_a, null, 4));
    try testing.expectEqual(@as(usize, 3), s.records.items.len);
    try testing.expect(s.indexOf(testUuid(3)) == null);
}

test "unit: notifications: same surface id in another workspace is not replaced" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try addOk(&s, mk(1, ws_a, null, 1));
    try addOk(&s, mk(2, ws_b, null, 2));
    try testing.expectEqual(@as(usize, 2), s.records.items.len);
}

test "unit: notifications: correlation key replaces only matching records" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const k1 = testUuid(0x501);
    const k2 = testUuid(0x502);
    var r1 = mk(1, ws_a, sf_1, 1);
    r1.correlation_key = k1;
    var r2 = mk(2, ws_a, sf_1, 2);
    r2.correlation_key = k2;
    try addOk(&s, r1);
    try addOk(&s, r2);
    try addOk(&s, mk(3, ws_a, sf_2, 3)); // other surface
    try testing.expectEqual(@as(usize, 3), s.records.items.len);
    var r4 = mk(4, ws_a, sf_1, 4);
    r4.correlation_key = k1;
    var res = try s.add(r4);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res.replaced.items.len);
    try testing.expectEqualStrings(&testUuid(1), &res.replaced.items[0]);
    try testing.expect(s.indexOf(testUuid(2)) != null);
    // An uncorrelated record replaces everything on the surface.
    var res2 = try s.add(mk(5, ws_a, sf_1, 5));
    defer res2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), res2.replaced.items.len);
    try testing.expectEqual(@as(usize, 2), s.records.items.len);
}

test "unit: notifications: muted workspace, tombstone, duplicate and record=false are dropped" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.setMuted(ws_b, true);
    var r = try s.add(mk(1, ws_b, sf_1, 1));
    try testing.expectEqual(AddStatus.dropped_muted, r.status);
    r.deinit(testing.allocator);
    try s.setMuted(ws_b, false);
    try addOk(&s, mk(1, ws_b, sf_1, 1));
    r = try s.add(mk(1, ws_a, sf_2, 1));
    try testing.expectEqual(AddStatus.dropped_duplicate, r.status);
    r.deinit(testing.allocator);
    try testing.expect(try s.dismiss(testUuid(1)));
    try testing.expect(!try s.dismiss(testUuid(1)));
    r = try s.add(mk(1, ws_b, sf_1, 1));
    try testing.expectEqual(AddStatus.dropped_tombstoned, r.status);
    r.deinit(testing.allocator);
    var nr = mk(2, ws_a, sf_1, 1);
    nr.effects.record = false;
    r = try s.add(nr);
    try testing.expectEqual(AddStatus.dropped_not_recorded, r.status);
    r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.records.items.len);
}

test "unit: notifications: history cap evicts oldest read records first" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.history_limit = 3;
    try addOk(&s, mk(1, ws_a, testUuid(0x11), 1));
    try addOk(&s, mk(2, ws_a, testUuid(0x12), 2));
    try addOk(&s, mk(3, ws_a, testUuid(0x13), 3));
    _ = s.markRead(testUuid(2));
    var res = try s.add(mk(4, ws_a, testUuid(0x14), 4));
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res.evicted.items.len);
    try testing.expectEqualStrings(&testUuid(2), &res.evicted.items[0]);
    // No read records left: the oldest unread goes.
    var res2 = try s.add(mk(5, ws_a, testUuid(0x15), 5));
    defer res2.deinit(testing.allocator);
    try testing.expectEqualStrings(&testUuid(1), &res2.evicted.items[0]);
    try testing.expectEqual(@as(usize, 3), s.records.items.len);
}

test "unit: notifications: history cap of 500 holds under a flood" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    var i: u32 = 0;
    while (i < 1200) : (i += 1) try addOk(&s, mk(i + 1, ws_a, testUuid(0x10000 + i), i));
    try testing.expectEqual(@as(usize, 500), s.records.items.len);
    try testing.expectEqualStrings(&testUuid(1200), &s.records.items[0].id);
    var ev: IdList = .empty;
    defer ev.deinit(testing.allocator);
    try s.setHistoryLimit(0, &ev); // clamps to 1
    try testing.expectEqual(@as(usize, 1), s.records.items.len);
    try testing.expectEqual(@as(usize, 499), ev.items.len);
}

test "unit: notifications: newest read record survives a cap of one" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.history_limit = 1;
    try addOk(&s, mk(1, ws_a, sf_1, 1));
    var r = mk(2, ws_a, sf_2, 2);
    r.read = true;
    try addOk(&s, r);
    try testing.expectEqualStrings(&testUuid(2), &s.records.items[0].id);
}

test "unit: notifications: scope mark read, count and remove" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try addOk(&s, mk(1, ws_a, sf_1, 1));
    try addOk(&s, mk(2, ws_a, null, 2));
    try addOk(&s, mk(3, ws_b, sf_2, 3));
    try testing.expectEqual(@as(usize, 3), s.countUnread(.all));
    try testing.expectEqual(@as(usize, 2), s.countUnread(.{ .workspace = ws_a }));
    try testing.expectEqual(@as(usize, 1), s.countUnread(.{ .workspace_own = ws_a }));
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try s.markReadScope(.{ .surface = sf_1 }, &ids));
    try testing.expectEqualStrings(&testUuid(1), &ids.items[0]);
    try testing.expectEqual(@as(usize, 0), try s.markReadScope(.{ .surface = sf_1 }, null));
    try testing.expectEqual(@as(usize, 1), try s.removeScope(.all, .{ .read_only = true }, null));
    try testing.expect(s.isTombstoned(testUuid(1)));
    try testing.expectEqual(@as(usize, 1), try s.removeScope(.{ .workspace = ws_b }, .{ .tombstone_ids = false }, null));
    try testing.expect(!s.isTombstoned(testUuid(3)));
    try testing.expectEqual(@as(usize, 1), s.count(.all));
}

test "unit: notifications: moveToOldestUnread requeues behind the last unread" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    // Order newest first: 4(read) 3 2 1(read)
    try addOk(&s, mk(1, ws_a, testUuid(0x11), 1));
    try addOk(&s, mk(2, ws_a, testUuid(0x12), 2));
    try addOk(&s, mk(3, ws_a, testUuid(0x13), 3));
    try addOk(&s, mk(4, ws_a, testUuid(0x14), 4));
    _ = s.markRead(testUuid(1));
    _ = s.markRead(testUuid(4));
    try testing.expect(s.moveToOldestUnread(testUuid(3)));
    const order = [_]u32{ 4, 2, 3, 1 };
    for (order, 0..) |n, i| try testing.expectEqualStrings(&testUuid(n), &s.records.items[i].id);
    // A read record becomes unread and goes behind the unread ones.
    try testing.expect(s.moveToOldestUnread(testUuid(4)));
    try testing.expect(!s.records.items[2].read);
    try testing.expectEqualStrings(&testUuid(4), &s.records.items[2].id);
    try testing.expect(!s.moveToOldestUnread(testUuid(99)));
}

test "unit: notifications: retarget and restored insertion order" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try addOk(&s, mk(1, ws_a, sf_1, 10));
    try testing.expectEqual(@as(usize, 1), s.retargetSurface(sf_1, ws_b));
    try testing.expectEqualStrings(&ws_b, &s.records.items[0].workspace);
    try testing.expectEqual(AddStatus.added, try s.insertRestored(mk(2, ws_a, sf_2, 20)));
    try testing.expectEqual(AddStatus.added, try s.insertRestored(mk(3, ws_a, null, 5)));
    try testing.expectEqual(AddStatus.added, try s.insertRestored(mk(4, ws_a, testUuid(9), 10)));
    const order = [_]u32{ 2, 1, 4, 3 };
    for (order, 0..) |n, i| try testing.expectEqualStrings(&testUuid(n), &s.records.items[i].id);
    try testing.expectEqual(AddStatus.dropped_duplicate, try s.insertRestored(mk(2, ws_a, sf_2, 20)));
    try s.addTombstone(testUuid(7), ws_a);
    try testing.expectEqual(AddStatus.dropped_tombstoned, try s.insertRestored(mk(7, ws_a, sf_2, 20)));
}

test "unit: notifications: tombstones are bounded" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    var i: u32 = 0;
    while (i < max_tombstones + 10) : (i += 1) try s.addTombstone(testUuid(i), ws_a);
    try testing.expectEqual(max_tombstones, s.tombstones.count());
    try testing.expect(!s.isTombstoned(testUuid(0)));
    try testing.expect(s.isTombstoned(testUuid(max_tombstones + 9)));
}

test "unit: notifications: records own deep copies of all strings" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    var title_buf = "hello".*;
    var r = mk(1, ws_a, sf_1, 1);
    r.title = &title_buf;
    r.agent = .{ .kind = "claude", .category = .needs_permission, .session_id = "sess" };
    r.click_action = .{ .open_url = "https://example.invalid/" };
    r.subtitle = "\u{1F600} sub";
    try addOk(&s, r);
    title_buf[0] = 'J';
    const got = s.records.items[0];
    try testing.expectEqualStrings("hello", got.title);
    try testing.expectEqualStrings("claude", got.agent.?.kind);
    try testing.expectEqualStrings("sess", got.agent.?.session_id.?);
    try testing.expectEqualStrings("https://example.invalid/", got.click_action.?.open_url);
    try testing.expect(got.isAgentAttention());
}

test "unit: notifications: add is leak-free under allocation failure" {
    const S = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var s = Store.init(gpa);
            defer s.deinit();
            var r = mk(1, ws_a, sf_1, 1);
            r.agent = .{ .kind = "codex", .category = .turn_complete, .session_id = "x" };
            r.click_action = .{ .open_file = "C:\\a.txt" };
            var a = try s.add(r);
            a.deinit(gpa);
            var b = try s.add(mk(2, ws_a, sf_1, 2));
            b.deinit(gpa);
            _ = try s.dismiss(testUuid(2));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}
