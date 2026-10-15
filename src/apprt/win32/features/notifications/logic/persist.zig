//! Notification persistence (ADR-7.9): the `notifications` value of a
//! workspace's session `ext` object. Saves the workspace's unread records
//! (latest 100), its manual and restored marks and its tombstones; restore
//! turns marks into restored-unread marks. Unknown keys are ignored so newer
//! snapshots load in older builds.
//!
//! Shape (version 1):
//! { "version": 1,
//!   "unread": [ { "id", "surface"?, "title", "subtitle", "body", "created_at_ms",
//!                 "read", "origin": "local" | "ssh-relay:<UUID>", "agent"?,
//!                 "correlation_key"?, "click_action"? {"kind","value"?},
//!                 "reply_shape", "scroll_anchor"?, "effects" } ],
//!   "manual": { "workspace": bool, "surfaces": ["UUID", ...] },
//!   "tombstones": ["UUID", ...] }

const std = @import("std");
const store_mod = @import("store.zig");
const unread_mod = @import("unread.zig");
const text = @import("text.zig");
const ingest = @import("ingest.zig");

const Uuid = store_mod.Uuid;
const Record = store_mod.Record;
const Model = unread_mod.Model;
const uuidEql = store_mod.uuidEql;
const parseUuid = store_mod.parseUuid;

pub const version: u32 = 1;
pub const max_saved_per_workspace: usize = 100;

pub const WireAgent = struct {
    kind: []const u8 = "",
    category: store_mod.AgentCategory = .other,
    session_id: ?[]const u8 = null,
    is_subagent: bool = false,
    pending_background: bool = false,
};

pub const WireClick = struct {
    kind: std.meta.Tag(store_mod.ClickAction),
    value: ?[]const u8 = null,
};

pub const WireRecord = struct {
    id: []const u8 = "",
    surface: ?[]const u8 = null,
    title: []const u8 = "",
    subtitle: []const u8 = "",
    body: []const u8 = "",
    created_at_ms: i64 = 0,
    read: bool = false,
    origin: []const u8 = "local",
    agent: ?WireAgent = null,
    correlation_key: ?[]const u8 = null,
    click_action: ?WireClick = null,
    reply_shape: store_mod.ReplyShape = .none,
    scroll_anchor: ?store_mod.ScreenAnchor = null,
    effects: store_mod.Effects = .{},
};

pub const WireManual = struct {
    workspace: bool = false,
    surfaces: []const []const u8 = &.{},
};

pub const Wire = struct {
    version: u32 = version,
    unread: []const WireRecord = &.{},
    manual: WireManual = .{},
    tombstones: []const []const u8 = &.{},
};

const origin_ssh_prefix = "ssh-relay:";

/// Serializes workspace `workspace` of `model` to JSON (caller frees).
pub fn snapshotAlloc(gpa: std.mem.Allocator, model: *const Model, workspace: Uuid) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var recs: std.ArrayList(WireRecord) = .empty;
    for (model.store.records.items) |*r| {
        if (recs.items.len >= max_saved_per_workspace) break;
        if (r.read or !uuidEql(r.workspace, workspace)) continue;
        try recs.append(arena, try toWire(arena, r));
    }

    var surfaces: std.ArrayList([]const u8) = .empty;
    const m = &model.marks;
    for (m.manual_surfaces.keys(), m.manual_surfaces.values()) |*s, w| {
        if (uuidEql(w, workspace)) try surfaces.append(arena, s);
    }
    for (m.restored_surfaces.keys(), m.restored_surfaces.values()) |*s, w| {
        if (uuidEql(w, workspace) and !m.manual_surfaces.contains(s.*)) try surfaces.append(arena, s);
    }

    var tombs: std.ArrayList([]const u8) = .empty;
    for (model.store.tombstones.keys(), model.store.tombstones.values()) |*id, w| {
        if (uuidEql(w, workspace)) try tombs.append(arena, id);
    }

    const wire: Wire = .{
        .unread = recs.items,
        .manual = .{
            .workspace = m.manual_workspaces.contains(workspace) or m.restored_workspaces.contains(workspace),
            .surfaces = surfaces.items,
        },
        .tombstones = tombs.items,
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(wire, .{ .emit_null_optional_fields = false }, &aw.writer);
    return aw.toOwnedSlice();
}

fn toWire(arena: std.mem.Allocator, r: *const Record) !WireRecord {
    return .{
        .id = &r.id,
        .surface = if (r.surface) |*s| s else null,
        .title = text.truncateUtf8(r.title, ingest.title_cap),
        .subtitle = text.truncateUtf8(r.subtitle, ingest.subtitle_cap),
        .body = text.truncateUtf8(r.body, ingest.body_cap),
        .created_at_ms = r.created_at_ms,
        .read = r.read,
        .origin = switch (r.origin) {
            .local => "local",
            .ssh_relay => |w| try std.fmt.allocPrint(arena, origin_ssh_prefix ++ "{s}", .{&w}),
        },
        .agent = if (r.agent) |a| .{
            .kind = a.kind,
            .category = a.category,
            .session_id = a.session_id,
            .is_subagent = a.is_subagent,
            .pending_background = a.pending_background,
        } else null,
        .correlation_key = if (r.correlation_key) |*k| k else null,
        .click_action = if (r.click_action) |ca| switch (ca) {
            .open_file => |p| .{ .kind = .open_file, .value = p },
            .open_url => |u| .{ .kind = .open_url, .value = u },
            .reply => .{ .kind = .reply },
        } else null,
        .reply_shape = r.reply_shape,
        .scroll_anchor = r.scroll_anchor,
        .effects = r.effects,
    };
}

pub const RestoreStats = struct {
    records: usize = 0,
    /// Malformed, duplicate, tombstoned or over-limit records.
    skipped: usize = 0,
    marks: usize = 0,
    tombstones: usize = 0,
};

pub const RestoreError = error{InvalidSnapshot} || std.mem.Allocator.Error;

/// Restores a workspace's section into `model`. Records land in `workspace`
/// (the restored owner); marks become restored-unread marks. A malformed
/// document fails as a whole; malformed entries inside it are skipped.
pub fn restore(model: *Model, workspace: Uuid, json: []const u8) RestoreError!RestoreStats {
    const gpa = model.gpa;
    const parsed = std.json.parseFromSlice(Wire, gpa, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSnapshot,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    var stats: RestoreStats = .{};

    for (wire.tombstones) |t| {
        const id = parseUuid(t) orelse continue;
        try model.store.addTombstone(id, workspace);
        stats.tombstones += 1;
    }

    var restored: usize = 0;
    for (wire.unread) |*w| {
        if (restored >= max_saved_per_workspace) {
            stats.skipped += 1;
            continue;
        }
        const r = fromWire(w, workspace) orelse {
            stats.skipped += 1;
            continue;
        };
        switch (try model.store.insertRestored(r)) {
            .added => {
                restored += 1;
                stats.records += 1;
            },
            else => stats.skipped += 1,
        }
    }

    if (wire.manual.workspace) {
        try model.addRestoredWorkspaceMark(workspace);
        stats.marks += 1;
    }
    for (wire.manual.surfaces) |s| {
        const id = parseUuid(s) orelse continue;
        try model.addRestoredSurfaceMark(workspace, id);
        stats.marks += 1;
    }
    return stats;
}

/// Borrowing conversion; null when a required UUID is malformed.
fn fromWire(w: *const WireRecord, workspace: Uuid) ?Record {
    const id = parseUuid(w.id) orelse return null;
    const surface: ?Uuid = if (w.surface) |s| (parseUuid(s) orelse return null) else null;
    const origin: store_mod.Origin = blk: {
        if (std.mem.startsWith(u8, w.origin, origin_ssh_prefix)) {
            if (parseUuid(w.origin[origin_ssh_prefix.len..])) |u| break :blk .{ .ssh_relay = u };
        }
        break :blk .local;
    };
    return .{
        .id = id,
        .workspace = workspace,
        .surface = surface,
        .title = text.truncateUtf8(w.title, ingest.title_cap),
        .subtitle = text.truncateUtf8(w.subtitle, ingest.subtitle_cap),
        .body = text.truncateUtf8(w.body, ingest.body_cap),
        .created_at_ms = w.created_at_ms,
        .read = w.read,
        .origin = origin,
        .agent = if (w.agent) |a| .{
            .kind = a.kind,
            .category = a.category,
            .session_id = a.session_id,
            .is_subagent = a.is_subagent,
            .pending_background = a.pending_background,
        } else null,
        .correlation_key = if (w.correlation_key) |k| parseUuid(k) else null,
        .click_action = if (w.click_action) |ca| switch (ca.kind) {
            .open_file => if (ca.value) |v| .{ .open_file = v } else null,
            .open_url => if (ca.value) |v| .{ .open_url = v } else null,
            .reply => .reply,
        } else null,
        .reply_shape = w.reply_shape,
        .scroll_anchor = w.scroll_anchor,
        .effects = w.effects,
    };
}

/// After restore: removes READ agent records whose surface no longer hosts
/// that agent (`agent_returned` false). Unread ones survive until read.
pub fn sweepOrphanedAgentRecords(
    model: *Model,
    ctx: *anyopaque,
    agent_returned: *const fn (ctx: *anyopaque, surface: ?Uuid, agent_kind: []const u8) bool,
    out: ?*store_mod.IdList,
) !usize {
    var n: usize = 0;
    var i: usize = 0;
    const items = &model.store.records;
    while (i < items.items.len) {
        const r = items.items[i];
        const orphan = r.read and r.agent != null and !agent_returned(ctx, r.surface, r.agent.?.kind);
        if (!orphan) {
            i += 1;
            continue;
        }
        if (out) |o| try o.append(model.gpa, r.id);
        var old = items.orderedRemove(i);
        old.deinit(model.gpa);
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testUuid = store_mod.testUuid;
const ws1 = testUuid(0xA1);
const ws2 = testUuid(0xA2);
const pa = testUuid(0x1A);
const pb = testUuid(0x1B);

fn addTo(m: *Model, r: Record) !void {
    var res = try m.add(r, .{});
    defer res.deinit(testing.allocator);
    try testing.expectEqual(store_mod.AddStatus.added, res.status);
}

test "unit: notifications: persistence round trip keeps unread records and fields" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try addTo(&m, .{
        .id = testUuid(1),
        .workspace = ws1,
        .surface = pa,
        .title = "Claude \u{1F916}",
        .subtitle = "Permission",
        .body = "line1\n\"quoted\" \\ back",
        .created_at_ms = 100,
        .origin = .{ .ssh_relay = ws2 },
        .agent = .{ .kind = "claude", .category = .needs_permission, .session_id = "s-1", .is_subagent = true },
        .correlation_key = testUuid(0x99),
        .click_action = .{ .open_file = "C:\\src\\a b.txt" },
        .reply_shape = .text,
        .scroll_anchor = .{ .row = -5, .col = 3 },
        .effects = .{ .desktop = false, .sound = false },
    });
    try addTo(&m, .{ .id = testUuid(2), .workspace = ws1, .surface = null, .title = "ws", .created_at_ms = 200 });
    try addTo(&m, .{ .id = testUuid(3), .workspace = ws1, .surface = pb, .created_at_ms = 300, .click_action = .reply });
    _ = m.store.markRead(testUuid(3)); // read: not saved
    try addTo(&m, .{ .id = testUuid(4), .workspace = ws2, .surface = testUuid(0x2A), .created_at_ms = 400 });

    const json = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(json);

    var m2 = Model.init(gpa);
    defer m2.deinit();
    const stats = try restore(&m2, ws1, json);
    try testing.expectEqual(@as(usize, 2), stats.records);
    try testing.expectEqual(@as(usize, 2), m2.store.records.items.len);
    const r2 = m2.store.records.items[0];
    try testing.expectEqualStrings(&testUuid(2), &r2.id);
    try testing.expect(r2.surface == null);
    const r = m2.store.records.items[1];
    try testing.expectEqualStrings(&testUuid(1), &r.id);
    try testing.expectEqualStrings(&ws1, &r.workspace);
    try testing.expectEqualStrings(&pa, &r.surface.?);
    try testing.expectEqualStrings("Claude \u{1F916}", r.title);
    try testing.expectEqualStrings("Permission", r.subtitle);
    try testing.expectEqualStrings("line1\n\"quoted\" \\ back", r.body);
    try testing.expectEqual(@as(i64, 100), r.created_at_ms);
    try testing.expectEqualStrings(&ws2, &r.origin.ssh_relay);
    try testing.expectEqualStrings("claude", r.agent.?.kind);
    try testing.expectEqual(store_mod.AgentCategory.needs_permission, r.agent.?.category);
    try testing.expectEqualStrings("s-1", r.agent.?.session_id.?);
    try testing.expect(r.agent.?.is_subagent);
    try testing.expectEqualStrings(&testUuid(0x99), &r.correlation_key.?);
    try testing.expectEqualStrings("C:\\src\\a b.txt", r.click_action.?.open_file);
    try testing.expectEqual(store_mod.ReplyShape.text, r.reply_shape);
    try testing.expectEqual(@as(i64, -5), r.scroll_anchor.?.row);
    try testing.expect(!r.effects.desktop and !r.effects.sound and r.effects.pane_flash);
    try testing.expectEqual(@as(usize, 2), m2.globalUnreadCount());
}

test "unit: notifications: persistence saves marks as restored-unread and tombstones" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try m.setSurfaceManualUnread(ws1, pa, true);
    try m.addRestoredSurfaceMark(ws1, pb);
    try m.setWorkspaceManualUnread(ws1, true);
    try m.setSurfaceManualUnread(ws2, testUuid(0x2A), true);
    try addTo(&m, .{ .id = testUuid(5), .workspace = ws1, .surface = testUuid(0x1C), .created_at_ms = 1 });
    _ = try m.store.dismiss(testUuid(5));

    const json = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(json);
    var m2 = Model.init(gpa);
    defer m2.deinit();
    const stats = try restore(&m2, ws1, json);
    try testing.expectEqual(@as(usize, 3), stats.marks);
    try testing.expectEqual(@as(usize, 1), stats.tombstones);
    try testing.expect(m2.marks.restored_workspaces.contains(ws1));
    try testing.expect(m2.marks.restored_surfaces.contains(pa));
    try testing.expect(m2.marks.restored_surfaces.contains(pb));
    try testing.expectEqual(@as(usize, 0), m2.marks.manual_surfaces.count());
    try testing.expectEqual(@as(usize, 3), m2.globalUnreadCount());
    // Restored marks clear when read.
    _ = try m2.focusSurface(pa, null);
    _ = try m2.markWorkspaceRead(ws1, null);
    try testing.expectEqual(@as(usize, 0), m2.globalUnreadCount());
    // A tombstoned id never comes back (replay of an old snapshot).
    var res = try m2.add(.{ .id = testUuid(5), .workspace = ws1, .surface = null, .created_at_ms = 2 }, .{});
    defer res.deinit(gpa);
    try testing.expectEqual(store_mod.AddStatus.dropped_tombstoned, res.status);
}

test "unit: notifications: persistence keeps the latest 100 unread per workspace" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    for (0..150) |i| try addTo(&m, .{
        .id = testUuid(@intCast(i + 1)),
        .workspace = ws1,
        .surface = testUuid(@intCast(0x10000 + i)),
        .created_at_ms = @intCast(i),
    });
    const json = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(json);
    var m2 = Model.init(gpa);
    defer m2.deinit();
    const stats = try restore(&m2, ws1, json);
    try testing.expectEqual(@as(usize, 100), stats.records);
    try testing.expectEqualStrings(&testUuid(150), &m2.store.records.items[0].id);
    try testing.expectEqualStrings(&testUuid(51), &m2.store.records.items[99].id);
}

test "unit: notifications: persistence of an empty workspace" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    const json = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        \\{"version":1,"unread":[],"manual":{"workspace":false,"surfaces":[]},"tombstones":[]}
    , json);
    const stats = try restore(&m, ws1, "{}");
    try testing.expectEqual(@as(usize, 0), stats.records + stats.marks + stats.tombstones);
}

test "unit: notifications: restore rejects malformed documents and skips bad entries" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try testing.expectError(error.InvalidSnapshot, restore(&m, ws1, ""));
    try testing.expectError(error.InvalidSnapshot, restore(&m, ws1, "{\"unread\":"));
    try testing.expectError(error.InvalidSnapshot, restore(&m, ws1, "[]"));
    const no_id = try restore(&m, ws1, "{\"unread\":[{\"title\":\"no id\"}]}");
    try testing.expectEqual(@as(usize, 1), no_id.skipped);
    const doc =
        \\{"version":7,"future":{"x":1},
        \\ "unread":[{"id":"not-a-uuid"},
        \\           {"id":"00000000-0000-4000-8000-000000000001","surface":"bad"},
        \\           {"id":"00000000-0000-4000-8000-000000000002","origin":"ssh-relay:junk",
        \\            "correlation_key":"junk","click_action":{"kind":"open_url"},"extra":true},
        \\           {"id":"00000000-0000-4000-8000-000000000002"}],
        \\ "manual":{"workspace":true,"surfaces":["junk","{00000000-0000-4000-8000-00000000001a}"]},
        \\ "tombstones":["junk"]}
    ;
    const stats = try restore(&m, ws1, doc);
    try testing.expectEqual(@as(usize, 1), stats.records);
    try testing.expectEqual(@as(usize, 3), stats.skipped);
    try testing.expectEqual(@as(usize, 2), stats.marks);
    try testing.expectEqual(@as(usize, 0), stats.tombstones);
    const r = m.store.records.items[0];
    try testing.expect(r.origin == .local);
    try testing.expect(r.correlation_key == null);
    try testing.expect(r.click_action == null);
    try testing.expect(m.marks.restored_surfaces.contains(pa));
}

test "unit: notifications: persistence truncates huge bodies on code points" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    const huge = try gpa.alloc(u8, 3 * 10_000);
    defer gpa.free(huge);
    for (0..10_000) |i| @memcpy(huge[i * 3 ..][0..3], "\u{20AC}");
    try addTo(&m, .{ .id = testUuid(1), .workspace = ws1, .surface = pa, .title = huge, .body = huge, .created_at_ms = 1 });
    try testing.expectEqual(huge.len, m.store.records.items[0].body.len); // store is uncapped
    const json = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(json);
    var m2 = Model.init(gpa);
    defer m2.deinit();
    _ = try restore(&m2, ws1, json);
    const r = m2.store.records.items[0];
    try testing.expectEqual(@as(usize, 1023), r.title.len);
    try testing.expectEqual(@as(usize, 8190), r.body.len);
    try testing.expect(std.unicode.utf8ValidateSlice(r.body));
}

test "unit: notifications: restore merges with live records in time order" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try addTo(&m, .{ .id = testUuid(1), .workspace = ws1, .surface = pa, .created_at_ms = 10 });
    try addTo(&m, .{ .id = testUuid(2), .workspace = ws2, .surface = pb, .created_at_ms = 30 });
    const j1 = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(j1);
    const j2 = try snapshotAlloc(gpa, &m, ws2);
    defer gpa.free(j2);
    var m2 = Model.init(gpa);
    defer m2.deinit();
    try addTo(&m2, .{ .id = testUuid(3), .workspace = ws1, .surface = testUuid(0x3A), .created_at_ms = 20 });
    _ = try restore(&m2, ws1, j1);
    _ = try restore(&m2, ws2, j2);
    const order = [_]u32{ 2, 3, 1 };
    for (order, 0..) |n, i| try testing.expectEqualStrings(&testUuid(n), &m2.store.records.items[i].id);
    // Restoring the same snapshot twice does not duplicate.
    const again = try restore(&m2, ws1, j1);
    try testing.expectEqual(@as(usize, 0), again.records);
    try testing.expectEqual(@as(usize, 3), m2.store.records.items.len);
}

test "unit: notifications: read agent records are swept when the agent did not return" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try addTo(&m, .{ .id = testUuid(1), .workspace = ws1, .surface = pa, .created_at_ms = 1, .agent = .{ .kind = "claude", .category = .turn_complete } });
    try addTo(&m, .{ .id = testUuid(2), .workspace = ws1, .surface = pb, .created_at_ms = 2, .agent = .{ .kind = "codex", .category = .turn_complete } });
    try addTo(&m, .{ .id = testUuid(3), .workspace = ws1, .surface = testUuid(0x1C), .created_at_ms = 3 });
    _ = try m.markAllRead(null);
    _ = m.store.markUnread(testUuid(2));
    const Ctx = struct {
        fn returned(ctx: *anyopaque, surface: ?Uuid, kind: []const u8) bool {
            _ = ctx;
            _ = surface;
            return std.mem.eql(u8, kind, "gemini");
        }
    };
    var dummy: u8 = 0;
    var ids: store_mod.IdList = .empty;
    defer ids.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try sweepOrphanedAgentRecords(&m, &dummy, Ctx.returned, &ids));
    try testing.expectEqualStrings(&testUuid(1), &ids.items[0]);
    try testing.expectEqual(@as(usize, 2), m.store.records.items.len);
}
