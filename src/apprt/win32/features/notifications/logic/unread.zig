//! Unread model and auto-read (ADR-7.2): one query API over unread records,
//! manual workspace/surface marks, restored marks and the focused-read
//! indicator, plus cmux's auto-read, toggle, jump and mark-oldest rules.
//! Pure: callers pass UUIDs and an optional "openable" predicate; the app
//! performs focus changes and toast withdrawal with the returned ids.

const std = @import("std");
const store_mod = @import("store.zig");

const Uuid = store_mod.Uuid;
const IdList = store_mod.IdList;
const Record = store_mod.Record;
const Store = store_mod.Store;
const uuidEql = store_mod.uuidEql;

const WorkspaceSet = std.AutoArrayHashMapUnmanaged(Uuid, void);
/// surface -> owning workspace, in marking order (oldest first).
const SurfaceMarks = std.AutoArrayHashMapUnmanaged(Uuid, Uuid);

pub const Marks = struct {
    manual_workspaces: WorkspaceSet = .empty,
    restored_workspaces: WorkspaceSet = .empty,
    manual_surfaces: SurfaceMarks = .empty,
    restored_surfaces: SurfaceMarks = .empty,
    /// Notification arrived for the exact focused pane: stored read, ring kept.
    focused_read: SurfaceMarks = .empty,

    pub fn deinit(self: *Marks, gpa: std.mem.Allocator) void {
        self.manual_workspaces.deinit(gpa);
        self.restored_workspaces.deinit(gpa);
        self.manual_surfaces.deinit(gpa);
        self.restored_surfaces.deinit(gpa);
        self.focused_read.deinit(gpa);
    }

    fn clearAll(self: *Marks) void {
        self.manual_workspaces.clearRetainingCapacity();
        self.restored_workspaces.clearRetainingCapacity();
        self.manual_surfaces.clearRetainingCapacity();
        self.restored_surfaces.clearRetainingCapacity();
        self.focused_read.clearRetainingCapacity();
    }

    fn clearSurface(self: *Marks, surface: Uuid) bool {
        var changed = self.manual_surfaces.orderedRemove(surface);
        changed = self.restored_surfaces.orderedRemove(surface) or changed;
        changed = self.focused_read.orderedRemove(surface) or changed;
        return changed;
    }

    fn clearWorkspace(self: *Marks, workspace: Uuid) bool {
        var changed = self.manual_workspaces.orderedRemove(workspace);
        changed = self.restored_workspaces.orderedRemove(workspace) or changed;
        inline for (.{ &self.manual_surfaces, &self.restored_surfaces, &self.focused_read }) |m| {
            changed = removeInWorkspace(m, workspace) or changed;
        }
        return changed;
    }
};

fn removeInWorkspace(m: *SurfaceMarks, workspace: Uuid) bool {
    var changed = false;
    var i: usize = 0;
    while (i < m.count()) {
        if (uuidEql(m.values()[i], workspace)) {
            m.orderedRemoveAt(i);
            changed = true;
        } else i += 1;
    }
    return changed;
}

fn countInWorkspace(m: *const SurfaceMarks, workspace: Uuid) usize {
    var n: usize = 0;
    for (m.values()) |w| {
        if (uuidEql(w, workspace)) n += 1;
    }
    return n;
}

fn firstInWorkspace(m: *const SurfaceMarks, workspace: Uuid) ?Uuid {
    for (m.keys(), m.values()) |s, w| {
        if (uuidEql(w, workspace)) return s;
    }
    return null;
}

/// Caller-supplied predicate: can this target be opened right now (window,
/// workspace and surface still exist)? `surface == null` means the workspace.
pub const Openable = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, workspace: Uuid, surface: ?Uuid) bool,

    fn check(self: ?Openable, workspace: Uuid, surface: ?Uuid) bool {
        const o = self orelse return true;
        return o.func(o.ctx, workspace, surface);
    }
};

pub const JumpOptions = struct {
    /// Workspaces in window order (for the workspace-marker fallback).
    workspace_order: []const Uuid = &.{},
    openable: ?Openable = null,
    exclude_record: ?Uuid = null,
    exclude_workspace: ?Uuid = null,
};

pub const JumpTarget = struct {
    pub const Source = enum { record, manual_surface, workspace_marker };
    source: Source,
    workspace: Uuid,
    /// Surface to focus; null = focus the workspace's preferred pane.
    surface: ?Uuid,
    /// Record opened (already marked read); restore its scroll anchor.
    record: ?Uuid = null,
    /// The target was manually unread: flash it.
    flash: bool = false,
};

pub const ToggleResult = enum {
    marked_workspace_read,
    marked_surface_read,
    marked_surface_unread,
    marked_workspace_unread,
};

pub const MarkOldestResult = struct {
    /// Record moved to the oldest-unread position, if any.
    deferred: ?Uuid = null,
    /// The focused pane/workspace was marked manually unread instead.
    marked_manual: bool = false,
    target: ?JumpTarget = null,
};

pub const AddOptions = struct {
    /// Record targets the exact focused surface: store it read and keep the
    /// focused-read indicator (ADR-7.4 focus suppression).
    focused: bool = false,
};

pub const Model = struct {
    gpa: std.mem.Allocator,
    store: Store,
    marks: Marks = .{},
    /// Local agent records restored from the previous session that the
    /// orphan sweep still watches (`persist.sweepOrphanedAgentRecords`).
    /// Ids whose record is gone are dropped lazily by the sweep.
    restored_agent_records: std.AutoArrayHashMapUnmanaged(Uuid, void) = .empty,

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa, .store = Store.init(gpa) };
    }

    pub fn deinit(self: *Model) void {
        self.store.deinit();
        self.marks.deinit(self.gpa);
        self.restored_agent_records.deinit(self.gpa);
        self.* = undefined;
    }

    // ------------------------------------------------------------ queries

    /// Unread records + workspace-level marks + surface marks (each source
    /// counts once; the focused-read indicator is read and does not count).
    pub fn globalUnreadCount(self: *const Model) usize {
        var n = self.store.countUnread(.all);
        n += self.marks.manual_surfaces.count();
        for (self.marks.restored_surfaces.keys()) |s| {
            if (!self.marks.manual_surfaces.contains(s)) n += 1;
        }
        n += self.marks.manual_workspaces.count();
        for (self.marks.restored_workspaces.keys()) |w| {
            if (!self.marks.manual_workspaces.contains(w)) n += 1;
        }
        return n;
    }

    pub fn workspaceUnreadCount(self: *const Model, workspace: Uuid) usize {
        var n = self.store.countUnread(.{ .workspace = workspace });
        n += countInWorkspace(&self.marks.manual_surfaces, workspace);
        for (self.marks.restored_surfaces.keys(), self.marks.restored_surfaces.values()) |s, w| {
            if (uuidEql(w, workspace) and !self.marks.manual_surfaces.contains(s)) n += 1;
        }
        if (self.marks.manual_workspaces.contains(workspace) or
            self.marks.restored_workspaces.contains(workspace)) n += 1;
        return n;
    }

    pub fn workspaceHasUnread(self: *const Model, workspace: Uuid) bool {
        return self.workspaceUnreadCount(workspace) > 0;
    }

    /// Surface is unread: an unread record, a manual or a restored mark.
    pub fn surfaceUnread(self: *const Model, surface: Uuid) bool {
        return self.store.countUnread(.{ .surface = surface }) > 0 or
            self.marks.manual_surfaces.contains(surface) or
            self.marks.restored_surfaces.contains(surface);
    }

    /// Pane ring / tab dot: unread, or the focused-read indicator.
    pub fn surfaceHasIndicator(self: *const Model, surface: Uuid) bool {
        return self.surfaceUnread(surface) or self.marks.focused_read.contains(surface);
    }

    // ----------------------------------------------------------- mutation

    /// Records a notification (see `Store.add`). A stored record clears the
    /// manual marker of its target, which it now indicates itself.
    pub fn add(self: *Model, template: Record, opts: AddOptions) !store_mod.AddResult {
        var t = template;
        if (opts.focused) t.read = true;
        if (opts.focused and t.surface != null) {
            try self.marks.focused_read.ensureUnusedCapacity(self.gpa, 1);
        }
        const result = try self.store.add(t);
        if (result.status != .added) return result;
        if (t.surface) |s| {
            _ = self.marks.manual_surfaces.orderedRemove(s);
            if (opts.focused) self.marks.focused_read.putAssumeCapacity(s, t.workspace);
        } else {
            _ = self.marks.manual_workspaces.orderedRemove(t.workspace);
        }
        return result;
    }

    /// Focusing a pane marks its records read and clears its markers; the
    /// focused-read indicator of every other pane goes away.
    pub fn focusSurface(self: *Model, surface: Uuid, out: ?*IdList) !usize {
        const n = try self.store.markReadScope(.{ .surface = surface }, out);
        _ = self.marks.manual_surfaces.orderedRemove(surface);
        _ = self.marks.restored_surfaces.orderedRemove(surface);
        var i: usize = 0;
        while (i < self.marks.focused_read.count()) {
            if (uuidEql(self.marks.focused_read.keys()[i], surface)) {
                i += 1;
            } else self.marks.focused_read.orderedRemoveAt(i);
        }
        return n;
    }

    /// Selecting a workspace marks only its own (surface-less) records read;
    /// other panes keep their records and markers.
    pub fn selectWorkspace(self: *Model, workspace: Uuid, out: ?*IdList) !usize {
        return self.store.markReadScope(.{ .workspace_own = workspace }, out);
    }

    pub const InputResult = struct {
        /// Something was cleared (flash when `notifications.paneFlashOnTyping`).
        changed: bool,
    };

    /// Explicit typing into a surface: its ordinary records are read, the
    /// OLDEST unread agent attention record (needs-permission) is read, and
    /// its markers and indicator are cleared. Newer attention records stay.
    pub fn explicitInput(self: *Model, surface: Uuid, out: ?*IdList) !InputResult {
        var changed = false;
        var oldest_attention: ?usize = null;
        for (self.store.records.items, 0..) |r, i| {
            if (r.read or r.surface == null or !uuidEql(r.surface.?, surface)) continue;
            if (r.isAgentAttention()) oldest_attention = i;
        }
        for (self.store.records.items, 0..) |*r, i| {
            if (r.read or r.surface == null or !uuidEql(r.surface.?, surface)) continue;
            if (r.isAgentAttention() and (oldest_attention == null or oldest_attention.? != i)) continue;
            if (out) |o| try o.append(self.gpa, r.id);
            r.read = true;
            changed = true;
        }
        changed = self.marks.clearSurface(surface) or changed;
        return .{ .changed = changed };
    }

    /// "Mark Workspace as Read": every record and marker in the workspace.
    pub fn markWorkspaceRead(self: *Model, workspace: Uuid, out: ?*IdList) !usize {
        const n = try self.store.markReadScope(.{ .workspace = workspace }, out);
        _ = self.marks.clearWorkspace(workspace);
        return n;
    }

    /// Clears a surface's unread state (records read, markers cleared).
    pub fn markSurfaceRead(self: *Model, surface: Uuid, out: ?*IdList) !usize {
        const n = try self.store.markReadScope(.{ .surface = surface }, out);
        _ = self.marks.clearSurface(surface);
        return n;
    }

    pub fn markAllRead(self: *Model, out: ?*IdList) !usize {
        const n = try self.store.markReadScope(.all, out);
        self.marks.clearAll();
        return n;
    }

    /// Removes every record (tombstoned) and every marker.
    pub fn clearAll(self: *Model, out: ?*IdList) !usize {
        const n = try self.store.removeScope(.all, .{}, out);
        self.marks.clearAll();
        self.restored_agent_records.clearRetainingCapacity();
        return n;
    }

    /// `clear-notifications --workspace [--surface]`.
    pub fn clearScope(self: *Model, scope: store_mod.Scope, out: ?*IdList) !usize {
        const n = try self.store.removeScope(scope, .{}, out);
        switch (scope) {
            .all => self.marks.clearAll(),
            .workspace => |w| _ = self.marks.clearWorkspace(w),
            .workspace_own => |w| {
                _ = self.marks.manual_workspaces.orderedRemove(w);
                _ = self.marks.restored_workspaces.orderedRemove(w);
            },
            .surface => |s| _ = self.marks.clearSurface(s),
        }
        return n;
    }

    /// Manual unread on a pane (Toggle Unread, `@ghostty-attention:ring`).
    /// Re-marking moves the pane to the most recent position.
    pub fn setSurfaceManualUnread(self: *Model, workspace: Uuid, surface: Uuid, on: bool) !void {
        if (on) try self.marks.manual_surfaces.ensureUnusedCapacity(self.gpa, 1);
        _ = self.marks.manual_surfaces.orderedRemove(surface);
        if (on) self.marks.manual_surfaces.putAssumeCapacity(surface, workspace);
    }

    pub fn setWorkspaceManualUnread(self: *Model, workspace: Uuid, on: bool) !void {
        if (on) {
            try self.marks.manual_workspaces.put(self.gpa, workspace, {});
        } else {
            _ = self.marks.manual_workspaces.orderedRemove(workspace);
        }
    }

    pub fn addRestoredWorkspaceMark(self: *Model, workspace: Uuid) !void {
        try self.marks.restored_workspaces.put(self.gpa, workspace, {});
    }

    pub fn addRestoredSurfaceMark(self: *Model, workspace: Uuid, surface: Uuid) !void {
        try self.marks.restored_surfaces.put(self.gpa, surface, workspace);
    }

    /// A pane moved to another workspace: its records and markers follow.
    pub fn retargetSurface(self: *Model, surface: Uuid, workspace: Uuid) void {
        _ = self.store.retargetSurface(surface, workspace);
        inline for (.{ &self.marks.manual_surfaces, &self.marks.restored_surfaces, &self.marks.focused_read }) |m| {
            if (m.getPtr(surface)) |w| w.* = workspace;
        }
    }

    /// A workspace closed: drop its records (not tombstoned) and markers.
    pub fn removeWorkspace(self: *Model, workspace: Uuid, out: ?*IdList) !usize {
        const n = try self.store.removeScope(.{ .workspace = workspace }, .{ .tombstone_ids = false }, out);
        _ = self.marks.clearWorkspace(workspace);
        return n;
    }

    /// A surface closed: drop its records (not tombstoned), its markers and
    /// its focused-read indicator, so a closed pane never keeps counting.
    pub fn removeSurface(self: *Model, surface: Uuid, out: ?*IdList) !usize {
        const n = try self.store.removeScope(.{ .surface = surface }, .{ .tombstone_ids = false }, out);
        _ = self.marks.clearSurface(surface);
        return n;
    }

    // ------------------------------------------------- toggle and jumping

    /// cmux Toggle Unread on the focused workspace/pane.
    pub fn toggleUnread(self: *Model, workspace: Uuid, focused_surface: ?Uuid, out: ?*IdList) !ToggleResult {
        const surface = focused_surface orelse {
            if (self.workspaceHasUnread(workspace)) {
                _ = try self.markWorkspaceRead(workspace, out);
                return .marked_workspace_read;
            }
            try self.setWorkspaceManualUnread(workspace, true);
            return .marked_workspace_unread;
        };
        if (self.workspaceHasVisibleIndicator(workspace)) {
            _ = try self.markWorkspaceRead(workspace, out);
            return .marked_workspace_read;
        }
        if (self.surfaceUnread(surface) or self.marks.manual_workspaces.contains(workspace)) {
            _ = try self.markSurfaceRead(surface, out);
            _ = self.marks.manual_workspaces.orderedRemove(workspace);
            return .marked_surface_read;
        }
        try self.setSurfaceManualUnread(workspace, surface, true);
        return .marked_surface_unread;
    }

    /// Any notification indicator in the workspace (unread record or
    /// focused-read ring), or a workspace-only restored marker.
    fn workspaceHasVisibleIndicator(self: *const Model, workspace: Uuid) bool {
        if (self.store.countUnread(.{ .workspace = workspace }) > 0) return true;
        if (countInWorkspace(&self.marks.focused_read, workspace) > 0) return true;
        return self.marks.restored_workspaces.contains(workspace);
    }

    /// Picks the next jump target without changing state.
    pub fn peekJump(self: *const Model, opts: JumpOptions) ?JumpTarget {
        // 1. Unread records, newest first, first openable one.
        for (self.store.records.items) |r| {
            if (r.read) continue;
            if (opts.exclude_record) |x| if (uuidEql(x, r.id)) continue;
            if (excluded(opts, r.workspace)) continue;
            if (!Openable.check(opts.openable, r.workspace, r.surface)) continue;
            return .{ .source = .record, .workspace = r.workspace, .surface = r.surface, .record = r.id };
        }
        // 2. Most recently marked manual-unread surface.
        const ms = &self.marks.manual_surfaces;
        var i = ms.count();
        while (i > 0) {
            i -= 1;
            const s = ms.keys()[i];
            const w = ms.values()[i];
            if (excluded(opts, w)) continue;
            if (!Openable.check(opts.openable, w, s)) continue;
            return .{ .source = .manual_surface, .workspace = w, .surface = s, .flash = true };
        }
        // 3. First workspace in window order carrying a workspace marker.
        for (opts.workspace_order) |w| {
            if (excluded(opts, w)) continue;
            const manual = self.marks.manual_workspaces.contains(w);
            const restored_pane = firstInWorkspace(&self.marks.restored_surfaces, w);
            if (!manual and !self.marks.restored_workspaces.contains(w) and restored_pane == null) continue;
            if (restored_pane) |s| {
                if (Openable.check(opts.openable, w, s))
                    return .{ .source = .workspace_marker, .workspace = w, .surface = s, .flash = manual };
            }
            if (!Openable.check(opts.openable, w, null)) continue;
            return .{ .source = .workspace_marker, .workspace = w, .surface = null, .flash = manual };
        }
        return null;
    }

    fn excluded(opts: JumpOptions, workspace: Uuid) bool {
        const x = opts.exclude_workspace orelse return false;
        return uuidEql(x, workspace);
    }

    /// Jump to Latest Unread: picks the target and applies its read state
    /// (record read / manual mark cleared / workspace marker cleared). The
    /// caller then focuses the target (which runs `focusSurface`).
    pub fn jumpToLatestUnread(self: *Model, opts: JumpOptions) ?JumpTarget {
        const t = self.peekJump(opts) orelse return null;
        switch (t.source) {
            .record => _ = self.store.markRead(t.record.?),
            .manual_surface => _ = self.marks.manual_surfaces.orderedRemove(t.surface.?),
            .workspace_marker => {
                _ = self.marks.manual_workspaces.orderedRemove(t.workspace);
                _ = self.marks.restored_workspaces.orderedRemove(t.workspace);
                if (t.surface) |s| _ = self.marks.restored_surfaces.orderedRemove(s);
            },
        }
        return t;
    }

    /// cmux "Mark as Oldest Unread and Jump to Next Latest Unread".
    pub fn markOldestUnreadAndJumpNext(
        self: *Model,
        workspace: Uuid,
        focused_surface: ?Uuid,
        opts: JumpOptions,
    ) !MarkOldestResult {
        const pick: ?*Record = blk: {
            if (focused_surface) |s| if (self.store.latest(.{ .surface = s })) |r| break :blk r;
            if (self.store.latest(.{ .workspace_own = workspace })) |r| break :blk r;
            break :blk self.store.latest(.{ .workspace = workspace });
        };
        var o = opts;
        if (pick) |r| {
            const id = r.id;
            _ = self.store.moveToOldestUnread(id);
            if (focused_surface) |s| _ = self.marks.focused_read.orderedRemove(s);
            o.exclude_record = id;
            return .{ .deferred = id, .target = self.jumpToLatestUnread(o) };
        }
        var marked = false;
        if (focused_surface) |s| {
            if (!self.surfaceUnread(s)) {
                try self.setSurfaceManualUnread(workspace, s, true);
                marked = true;
            }
        } else if (!self.workspaceHasUnread(workspace)) {
            try self.setWorkspaceManualUnread(workspace, true);
            marked = true;
        }
        o.exclude_workspace = workspace;
        return .{ .marked_manual = marked, .target = self.jumpToLatestUnread(o) };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testUuid = store_mod.testUuid;

const ws1 = testUuid(0xA1);
const ws2 = testUuid(0xA2);
const ws3 = testUuid(0xA3);
const pa = testUuid(0x1A);
const pb = testUuid(0x1B);
const pc = testUuid(0x1C);

fn mk(id: u32, ws: Uuid, sf: ?Uuid, t: i64) Record {
    return .{ .id = testUuid(id), .workspace = ws, .surface = sf, .title = "T", .body = "B", .created_at_ms = t };
}

fn addTo(m: *Model, r: Record, opts: AddOptions) !void {
    var res = try m.add(r, opts);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(store_mod.AddStatus.added, res.status);
}

test "unit: notifications: toggle unread on a read pane rings it and counts one" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
    try testing.expectEqual(ToggleResult.marked_surface_unread, try m.toggleUnread(ws1, pa, null));
    try testing.expectEqual(@as(usize, 1), m.globalUnreadCount());
    try testing.expectEqual(@as(usize, 1), m.workspaceUnreadCount(ws1));
    try testing.expect(m.surfaceHasIndicator(pa));
    try testing.expectEqual(@as(usize, 0), m.store.records.items.len);
    try testing.expectEqual(ToggleResult.marked_surface_read, try m.toggleUnread(ws1, pa, null));
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
    try testing.expect(!m.surfaceHasIndicator(pa));
}

test "unit: notifications: toggle unread with a notification marks the workspace read" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pb, 1), .{});
    try m.setSurfaceManualUnread(ws1, pc, true);
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    try testing.expectEqual(ToggleResult.marked_workspace_read, try m.toggleUnread(ws1, pa, &ids));
    try testing.expectEqual(@as(usize, 0), m.workspaceUnreadCount(ws1));
    try testing.expectEqual(@as(usize, 1), ids.items.len);
    // Records stay listed, read.
    try testing.expectEqual(@as(usize, 1), m.store.records.items.len);
}

test "unit: notifications: toggle unread without a focused pane toggles the workspace" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try testing.expectEqual(ToggleResult.marked_workspace_unread, try m.toggleUnread(ws2, null, null));
    try testing.expect(m.workspaceHasUnread(ws2));
    try testing.expectEqual(@as(usize, 1), m.globalUnreadCount());
    try testing.expectEqual(ToggleResult.marked_workspace_read, try m.toggleUnread(ws2, null, null));
    try testing.expect(!m.workspaceHasUnread(ws2));
    // A focused pane in a manually unread workspace represents that mark.
    try m.setWorkspaceManualUnread(ws2, true);
    try testing.expectEqual(ToggleResult.marked_surface_read, try m.toggleUnread(ws2, pa, null));
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
}

test "unit: notifications: a new record clears the target's manual mark" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.setWorkspaceManualUnread(ws1, true);
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try testing.expect(!m.marks.manual_surfaces.contains(pa));
    try testing.expect(m.marks.manual_workspaces.contains(ws1));
    try addTo(&m, mk(2, ws1, null, 2), .{});
    try testing.expect(!m.marks.manual_workspaces.contains(ws1));
    try testing.expectEqual(@as(usize, 2), m.globalUnreadCount());
}

test "unit: notifications: dropped records leave marks untouched" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.store.setMuted(ws1, true);
    var res = try m.add(mk(1, ws1, pa, 1), .{ .focused = true });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(store_mod.AddStatus.dropped_muted, res.status);
    try testing.expect(m.marks.manual_surfaces.contains(pa));
    try testing.expect(!m.marks.focused_read.contains(pa));
}

test "unit: notifications: focused pane gets a read record with a focused-read ring" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{ .focused = true });
    try testing.expect(m.store.records.items[0].read);
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
    try testing.expect(m.surfaceHasIndicator(pa));
    try testing.expect(!m.surfaceUnread(pa));
    // Staying focused keeps it; focusing elsewhere clears it.
    _ = try m.focusSurface(pa, null);
    try testing.expect(m.surfaceHasIndicator(pa));
    _ = try m.focusSurface(pb, null);
    try testing.expect(!m.surfaceHasIndicator(pa));
}

test "unit: notifications: focusing a pane reads only that pane" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    try m.addRestoredSurfaceMark(ws1, pa);
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try m.focusSurface(pa, &ids));
    try testing.expectEqualStrings(&testUuid(1), &ids.items[0]);
    try testing.expect(!m.surfaceHasIndicator(pa));
    try testing.expect(m.surfaceUnread(pb));
    try testing.expectEqual(@as(usize, 1), m.globalUnreadCount());
}

test "unit: notifications: selecting a workspace reads only its own records" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, null, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    try m.setSurfaceManualUnread(ws1, pc, true);
    try m.addRestoredWorkspaceMark(ws1);
    try testing.expectEqual(@as(usize, 1), try m.selectWorkspace(ws1, null));
    try testing.expect(m.store.find(testUuid(1)).?.read);
    try testing.expect(!m.store.find(testUuid(2)).?.read);
    try testing.expect(m.surfaceUnread(pc));
    try testing.expect(m.marks.restored_workspaces.contains(ws1));
    // "Mark Workspace as Read" clears everything in it.
    _ = try m.markWorkspaceRead(ws1, null);
    try testing.expectEqual(@as(usize, 0), m.workspaceUnreadCount(ws1));
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
}

test "unit: notifications: typing reads the surface and only the oldest attention record" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    const k1 = testUuid(0x701);
    const k2 = testUuid(0x702);
    const k3 = testUuid(0x703);
    var r1 = mk(1, ws1, pa, 1);
    r1.correlation_key = k1;
    r1.agent = .{ .kind = "claude", .category = .needs_permission };
    var r2 = mk(2, ws1, pa, 2);
    r2.correlation_key = k2;
    r2.agent = .{ .kind = "claude", .category = .needs_permission };
    var r3 = mk(3, ws1, pa, 3);
    r3.correlation_key = k3;
    try addTo(&m, r1, .{});
    try addTo(&m, r2, .{});
    try addTo(&m, r3, .{});
    try addTo(&m, mk(4, ws1, pb, 4), .{});
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    const res = try m.explicitInput(pa, &ids);
    try testing.expect(res.changed);
    try testing.expectEqual(@as(usize, 2), ids.items.len);
    try testing.expect(m.store.find(testUuid(1)).?.read);
    try testing.expect(!m.store.find(testUuid(2)).?.read);
    try testing.expect(m.store.find(testUuid(3)).?.read);
    try testing.expect(!m.store.find(testUuid(4)).?.read);
    // Second keystroke clears the next attention record.
    _ = try m.explicitInput(pa, null);
    try testing.expect(!m.surfaceUnread(pa));
    try testing.expect(!(try m.explicitInput(pa, null)).changed);
}

test "unit: notifications: typing clears manual marks and the focused-read ring" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{ .focused = true });
    try m.addRestoredSurfaceMark(ws1, pa);
    const res = try m.explicitInput(pa, null);
    try testing.expect(res.changed);
    try testing.expect(!m.surfaceHasIndicator(pa));
}

test "unit: notifications: mark all read clears every source and keeps rows" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try addTo(&m, mk(2, ws2, null, 2), .{});
    try addTo(&m, mk(3, ws3, pc, 3), .{ .focused = true });
    try m.setSurfaceManualUnread(ws2, pb, true);
    try m.setWorkspaceManualUnread(ws3, true);
    try m.addRestoredWorkspaceMark(ws1);
    try m.addRestoredSurfaceMark(ws2, testUuid(0x77));
    try testing.expectEqual(@as(usize, 6), m.globalUnreadCount());
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), try m.markAllRead(&ids));
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
    try testing.expectEqual(@as(usize, 3), m.store.records.items.len);
    try testing.expect(!m.surfaceHasIndicator(pc));
}

test "unit: notifications: clear all empties records and markers" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try addTo(&m, mk(2, ws2, null, 2), .{});
    try m.setSurfaceManualUnread(ws2, pb, true);
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), try m.clearAll(&ids));
    try testing.expectEqual(@as(usize, 2), ids.items.len);
    try testing.expectEqual(@as(usize, 0), m.store.records.items.len);
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
    try testing.expect(m.store.isTombstoned(testUuid(1)));
    try testing.expectEqual(@as(usize, 0), try m.clearAll(null));
}

test "unit: notifications: clear scope removes a surface or a workspace" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    try addTo(&m, mk(3, ws2, null, 3), .{});
    try m.setSurfaceManualUnread(ws1, pc, true);
    try testing.expectEqual(@as(usize, 1), try m.clearScope(.{ .surface = pa }, null));
    try testing.expectEqual(@as(usize, 1), try m.clearScope(.{ .workspace = ws1 }, null));
    try testing.expect(!m.workspaceHasUnread(ws1));
    try testing.expect(m.workspaceHasUnread(ws2));
}

test "unit: notifications: jump order is newest unread first across workspaces" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(2, ws2, pb, 10), .{});
    try addTo(&m, mk(3, ws3, pc, 20), .{});
    const order = [_]Uuid{ ws1, ws2, ws3 };
    const t1 = m.jumpToLatestUnread(.{ .workspace_order = &order }).?;
    try testing.expectEqual(JumpTarget.Source.record, t1.source);
    try testing.expectEqualStrings(&ws3, &t1.workspace);
    try testing.expectEqualStrings(&pc, &t1.surface.?);
    const t2 = m.jumpToLatestUnread(.{ .workspace_order = &order }).?;
    try testing.expectEqualStrings(&ws2, &t2.workspace);
    try testing.expect(m.jumpToLatestUnread(.{ .workspace_order = &order }) == null);
}

const ClosedSet = struct {
    closed: Uuid,
    fn openable(ctx: *anyopaque, workspace: Uuid, surface: ?Uuid) bool {
        _ = workspace;
        const self: *ClosedSet = @ptrCast(@alignCast(ctx));
        const s = surface orelse return true;
        return !uuidEql(s, self.closed);
    }
};

test "unit: notifications: jump skips records whose surface cannot be opened" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    var cs: ClosedSet = .{ .closed = pb };
    const o: Openable = .{ .ctx = &cs, .func = ClosedSet.openable };
    const t = m.jumpToLatestUnread(.{ .openable = o }).?;
    try testing.expectEqualStrings(&pa, &t.surface.?);
    // The unopenable record stays unread.
    try testing.expect(!m.store.find(testUuid(2)).?.read);
}

test "unit: notifications: jump falls back to manual surfaces then workspace markers" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.setSurfaceManualUnread(ws2, pb, true);
    try m.setWorkspaceManualUnread(ws3, true);
    try m.addRestoredWorkspaceMark(ws1);
    const order = [_]Uuid{ ws1, ws2, ws3 };
    const t1 = m.jumpToLatestUnread(.{ .workspace_order = &order }).?;
    try testing.expectEqual(JumpTarget.Source.manual_surface, t1.source);
    try testing.expectEqualStrings(&pb, &t1.surface.?); // most recent mark
    try testing.expect(t1.flash);
    const t2 = m.jumpToLatestUnread(.{ .workspace_order = &order }).?;
    try testing.expectEqualStrings(&pa, &t2.surface.?);
    const t3 = m.jumpToLatestUnread(.{ .workspace_order = &order }).?;
    try testing.expectEqual(JumpTarget.Source.workspace_marker, t3.source);
    try testing.expectEqualStrings(&ws1, &t3.workspace);
    try testing.expect(!t3.flash); // restored, not manual
    const t4 = m.jumpToLatestUnread(.{ .workspace_order = &order }).?;
    try testing.expectEqualStrings(&ws3, &t4.workspace);
    try testing.expect(t4.flash);
    try testing.expect(m.jumpToLatestUnread(.{ .workspace_order = &order }) == null);
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
}

test "unit: notifications: jump prefers a restored unread pane in a marked workspace" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.addRestoredSurfaceMark(ws2, pb);
    const order = [_]Uuid{ ws1, ws2 };
    try testing.expectEqual(@as(usize, 1), m.globalUnreadCount());
    const t = m.peekJump(.{ .workspace_order = &order }).?;
    try testing.expectEqualStrings(&pb, &t.surface.?);
    _ = m.jumpToLatestUnread(.{ .workspace_order = &order });
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
}

test "unit: notifications: mark oldest unread cycles through every unread item" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    // Unread A (newest), B, C on three panes of ws1.
    try addTo(&m, mk(3, ws1, pc, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    try addTo(&m, mk(1, ws1, pa, 3), .{});
    var focused: Uuid = pa;
    const expect_next = [_]Uuid{ pb, pc, pa, pb, pc, pa };
    for (expect_next) |want| {
        const res = try m.markOldestUnreadAndJumpNext(ws1, focused, .{});
        try testing.expect(res.deferred != null);
        const t = res.target.?;
        try testing.expectEqualStrings(&want, &t.surface.?);
        _ = try m.focusSurface(t.surface.?, null);
        focused = t.surface.?;
        // Nothing lost: exactly two remain unread (the focused one is read).
        try testing.expectEqual(@as(usize, 3), m.store.records.items.len);
        try testing.expectEqual(@as(usize, 2), m.globalUnreadCount());
    }
}

test "unit: notifications: mark oldest unread moves the focused record behind the queue" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(3, ws1, pc, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    try addTo(&m, mk(1, ws1, pa, 3), .{});
    const res = try m.markOldestUnreadAndJumpNext(ws1, pa, .{});
    try testing.expectEqualStrings(&testUuid(1), &res.deferred.?);
    try testing.expectEqualStrings(&testUuid(1), &m.store.records.items[2].id);
    try testing.expect(!m.store.records.items[2].read);
    try testing.expectEqualStrings(&pb, &res.target.?.surface.?);
}

test "unit: notifications: mark oldest without a record marks the pane and jumps elsewhere" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pb, 1), .{});
    try addTo(&m, mk(2, ws2, pc, 2), .{});
    const res = try m.markOldestUnreadAndJumpNext(ws3, pa, .{});
    try testing.expect(res.deferred == null);
    try testing.expect(res.marked_manual);
    try testing.expect(m.surfaceUnread(pa));
    try testing.expectEqualStrings(&ws2, &res.target.?.workspace);
    // Already unread pane is not re-marked; the jump excludes this workspace.
    const res2 = try m.markOldestUnreadAndJumpNext(ws3, pa, .{});
    try testing.expect(!res2.marked_manual);
    try testing.expectEqualStrings(&ws1, &res2.target.?.workspace);
    // Nothing else left: no target, pane mark kept.
    const res3 = try m.markOldestUnreadAndJumpNext(ws3, pa, .{});
    try testing.expect(res3.target == null);
    try testing.expect(m.surfaceUnread(pa));
    // No focused pane: the workspace is marked.
    const res4 = try m.markOldestUnreadAndJumpNext(ws1, null, .{});
    try testing.expect(res4.marked_manual or res4.deferred != null);
}

test "unit: notifications: mark oldest falls back to workspace-level records" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, null, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{});
    const res = try m.markOldestUnreadAndJumpNext(ws1, pa, .{});
    try testing.expectEqualStrings(&testUuid(1), &res.deferred.?);
    try testing.expectEqualStrings(&testUuid(2), &res.target.?.record.?);
}

test "unit: notifications: retargeted pane notifies its new workspace" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try m.setSurfaceManualUnread(ws1, pb, true);
    m.retargetSurface(pa, ws2);
    m.retargetSurface(pb, ws2);
    try testing.expect(!m.workspaceHasUnread(ws1));
    try testing.expectEqual(@as(usize, 2), m.workspaceUnreadCount(ws2));
    try testing.expectEqual(@as(usize, 2), try m.removeWorkspace(ws2, null) + 1);
    try testing.expectEqual(@as(usize, 0), m.globalUnreadCount());
    try testing.expect(!m.store.isTombstoned(testUuid(1)));
}

test "unit: notifications: closing a pane drops its records and markers" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try addTo(&m, mk(1, ws1, pa, 1), .{});
    try addTo(&m, mk(2, ws1, pb, 2), .{ .focused = true });
    try addTo(&m, mk(3, ws1, null, 3), .{});
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.addRestoredSurfaceMark(ws1, pa);
    var ids: IdList = .empty;
    defer ids.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try m.removeSurface(pa, &ids));
    try testing.expectEqualStrings(&testUuid(1), &ids.items[0]);
    try testing.expect(!m.surfaceHasIndicator(pa));
    try testing.expect(!m.store.isTombstoned(testUuid(1)));
    // The focused-read ring of a closed pane goes too; other rows stay.
    _ = try m.removeSurface(pb, null);
    try testing.expect(!m.surfaceHasIndicator(pb));
    try testing.expectEqual(@as(usize, 1), m.store.records.items.len);
    try testing.expectEqual(@as(usize, 1), m.globalUnreadCount());
    try testing.expectEqual(@as(usize, 0), try m.removeSurface(pc, null));
}

test "unit: notifications: re-marking a pane makes it the latest manual jump target" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.setSurfaceManualUnread(ws1, pb, true);
    try m.setSurfaceManualUnread(ws1, pa, true);
    try testing.expectEqual(@as(usize, 2), m.globalUnreadCount());
    try testing.expectEqualStrings(&pa, &m.peekJump(.{}).?.surface.?);
    try m.setSurfaceManualUnread(ws1, pa, false);
    try m.setSurfaceManualUnread(ws1, pa, false);
    try testing.expectEqualStrings(&pb, &m.peekJump(.{}).?.surface.?);
}

test "unit: notifications: unread model is leak-free under allocation failure" {
    const S = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var m = Model.init(gpa);
            defer m.deinit();
            var ids: IdList = .empty;
            defer ids.deinit(gpa);
            var r1 = mk(1, ws1, pa, 1);
            r1.agent = .{ .kind = "claude", .category = .needs_permission, .session_id = "s" };
            var a = try m.add(r1, .{});
            a.deinit(gpa);
            var b = try m.add(mk(2, ws1, pb, 2), .{ .focused = true });
            b.deinit(gpa);
            var c = try m.add(mk(3, ws2, null, 3), .{});
            c.deinit(gpa);
            try m.setSurfaceManualUnread(ws2, pc, true);
            try m.addRestoredWorkspaceMark(ws3);
            try m.addRestoredSurfaceMark(ws3, testUuid(0x1D));
            _ = try m.toggleUnread(ws1, pa, &ids);
            _ = try m.markOldestUnreadAndJumpNext(ws2, null, .{ .workspace_order = &.{ ws1, ws2, ws3 } });
            _ = try m.explicitInput(pa, &ids);
            _ = try m.focusSurface(pb, &ids);
            _ = try m.selectWorkspace(ws2, &ids);
            _ = try m.clearScope(.{ .workspace = ws3 }, &ids);
            _ = try m.removeSurface(pc, &ids);
            _ = try m.markAllRead(&ids);
            _ = try m.clearAll(&ids);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}

test "unit: notifications: random operations keep counts consistent" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const r = prng.random();
    var m = Model.init(testing.allocator);
    defer m.deinit();
    m.store.history_limit = 16;
    const wss = [_]Uuid{ ws1, ws2, ws3 };
    var next_id: u32 = 1;
    for (0..4000) |_| {
        const ws = wss[r.uintLessThan(usize, wss.len)];
        const sf: ?Uuid = if (r.uintLessThan(u8, 5) == 0) null else testUuid(0x100 + r.uintLessThan(u32, 8));
        switch (r.uintLessThan(u8, 14)) {
            0...4 => {
                var rec = mk(next_id, ws, sf, next_id);
                if (r.uintLessThan(u8, 4) == 0) rec.correlation_key = testUuid(0x900 + r.uintLessThan(u32, 3));
                if (r.uintLessThan(u8, 4) == 0) rec.agent = .{ .kind = "claude", .category = .needs_permission };
                next_id += 1;
                var res = try m.add(rec, .{ .focused = r.uintLessThan(u8, 6) == 0 });
                res.deinit(testing.allocator);
            },
            5 => if (sf) |s| {
                _ = try m.focusSurface(s, null);
            },
            6 => _ = try m.selectWorkspace(ws, null),
            7 => _ = try m.toggleUnread(ws, sf, null),
            8 => _ = try m.markOldestUnreadAndJumpNext(ws, sf, .{ .workspace_order = &wss }),
            9 => _ = m.jumpToLatestUnread(.{ .workspace_order = &wss }),
            10 => if (sf) |s| {
                _ = try m.explicitInput(s, null);
            },
            11 => if (sf) |s| m.retargetSurface(s, ws),
            12 => if (sf) |s| {
                _ = try m.removeSurface(s, null);
            },
            else => if (m.store.records.items.len > 0) {
                const victim = m.store.records.items[r.uintLessThan(usize, m.store.records.items.len)].id;
                _ = try m.store.dismiss(victim);
            },
        }
        try testing.expect(m.store.records.items.len <= 16);
        for (m.store.records.items, 0..) |a, i| {
            for (m.store.records.items[i + 1 ..]) |b| try testing.expect(!uuidEql(a.id, b.id));
        }
        var sum: usize = 0;
        for (wss) |w| sum += m.workspaceUnreadCount(w);
        try testing.expectEqual(m.globalUnreadCount(), sum);
        // A jump target exists exactly when something is unread.
        try testing.expectEqual(m.globalUnreadCount() > 0, m.peekJump(.{ .workspace_order = &wss }) != null);
    }
}

test "unit: notifications: restored and manual marks on one surface count once" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.addRestoredSurfaceMark(ws1, pa);
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.addRestoredWorkspaceMark(ws1);
    try m.setWorkspaceManualUnread(ws1, true);
    try testing.expectEqual(@as(usize, 2), m.globalUnreadCount());
    try testing.expectEqual(@as(usize, 2), m.workspaceUnreadCount(ws1));
}
