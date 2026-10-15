//! Notification persistence (ADR-7.9): the `notifications` value of a
//! workspace's session `ext` object. Saves the workspace's unread records
//! (latest 100), its manual and restored marks and its tombstones; restore
//! turns marks into restored-unread marks. `snapshot` and `restore` take the
//! `std.json.Stringify` / `std.json.Value` of the ADR-1.3 state hooks.
//! Restore is tolerant so newer snapshots load in older builds: unknown keys
//! and unknown enum names are ignored, and a malformed entry is skipped on
//! its own instead of failing the workspace.
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
const Value = std.json.Value;
const uuidEql = store_mod.uuidEql;
const parseUuid = store_mod.parseUuid;

pub const version: u32 = 1;
pub const max_saved_per_workspace: usize = 100;

/// Enum-valued fields travel as their tag names; on restore an unknown name
/// falls back (`other`, `none`, no click action) instead of failing.
pub const WireAgent = struct {
    kind: []const u8 = "",
    category: []const u8 = @tagName(store_mod.AgentCategory.other),
    session_id: ?[]const u8 = null,
    is_subagent: bool = false,
    pending_background: bool = false,
};

pub const WireClick = struct {
    kind: []const u8 = "",
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
    reply_shape: []const u8 = @tagName(store_mod.ReplyShape.none),
    scroll_anchor: ?store_mod.ScreenAnchor = null,
    effects: store_mod.Effects = .{},
};

const origin_ssh_prefix = "ssh-relay:";
const OriginBuf = [origin_ssh_prefix.len + @sizeOf(Uuid)]u8;

/// Writes the section value of `workspace` with `jw` (ADR-1.3 `snapshot`).
/// Allocation-free; text is capped like ingress text, on code points.
pub fn snapshot(model: *const Model, workspace: Uuid, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    const m = &model.marks;
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(version);

    try jw.objectField("unread");
    try jw.beginArray();
    var saved: usize = 0;
    for (model.store.records.items) |*r| {
        if (saved == max_saved_per_workspace) break;
        if (r.read or !uuidEql(r.workspace, workspace)) continue;
        var origin_buf: OriginBuf = undefined;
        try jw.write(toWire(r, &origin_buf));
        saved += 1;
    }
    try jw.endArray();

    try jw.objectField("manual");
    try jw.beginObject();
    try jw.objectField("workspace");
    try jw.write(m.manual_workspaces.contains(workspace) or m.restored_workspaces.contains(workspace));
    try jw.objectField("surfaces");
    try jw.beginArray();
    for (m.manual_surfaces.keys(), m.manual_surfaces.values()) |*s, w| {
        if (uuidEql(w, workspace)) try jw.write(s);
    }
    for (m.restored_surfaces.keys(), m.restored_surfaces.values()) |*s, w| {
        if (uuidEql(w, workspace) and !m.manual_surfaces.contains(s.*)) try jw.write(s);
    }
    try jw.endArray();
    try jw.endObject();

    try jw.objectField("tombstones");
    try jw.beginArray();
    for (model.store.tombstones.keys(), model.store.tombstones.values()) |*id, w| {
        if (uuidEql(w, workspace)) try jw.write(id);
    }
    try jw.endArray();
    try jw.endObject();
}

/// `snapshot` into a new buffer (caller frees). Null optional fields are
/// omitted.
pub fn snapshotAlloc(gpa: std.mem.Allocator, model: *const Model, workspace: Uuid) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    // An allocating writer fails only when it cannot grow.
    snapshot(model, workspace, &jw) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Borrows from `r` and `origin_buf`.
fn toWire(r: *const Record, origin_buf: *OriginBuf) WireRecord {
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
            .ssh_relay => |*w| blk: {
                @memcpy(origin_buf[0..origin_ssh_prefix.len], origin_ssh_prefix);
                @memcpy(origin_buf[origin_ssh_prefix.len..], w);
                break :blk origin_buf;
            },
        },
        .agent = if (r.agent) |a| .{
            .kind = a.kind,
            .category = @tagName(a.category),
            .session_id = a.session_id,
            .is_subagent = a.is_subagent,
            .pending_background = a.pending_background,
        } else null,
        .correlation_key = if (r.correlation_key) |*k| k else null,
        .click_action = if (r.click_action) |ca| .{
            .kind = @tagName(ca),
            .value = switch (ca) {
                .open_file, .open_url => |v| v,
                .reply => null,
            },
        } else null,
        .reply_shape = @tagName(r.reply_shape),
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

/// Restores the section value of `workspace` (ADR-1.3 `restore`). Records
/// land in `workspace` (the restored owner), marks become restored-unread
/// marks, and restored local agent records are watched by
/// `sweepOrphanedAgentRecords`. Only a value that is not an object fails;
/// sections of the wrong type and malformed entries are skipped.
pub fn restore(model: *Model, workspace: Uuid, v: Value) RestoreError!RestoreStats {
    const root = switch (v) {
        .object => |o| o,
        else => return error.InvalidSnapshot,
    };
    var arena_state = std.heap.ArenaAllocator.init(model.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stats: RestoreStats = .{};

    for (arrayItems(root.get("tombstones"))) |t| {
        const id = uuidValue(t) orelse continue;
        try model.store.addTombstone(id, workspace);
        stats.tombstones += 1;
    }

    var restored: usize = 0;
    for (arrayItems(root.get("unread"))) |item| {
        if (restored == max_saved_per_workspace) {
            stats.skipped += 1;
            continue;
        }
        const w = std.json.parseFromValueLeaky(WireRecord, arena, item, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                stats.skipped += 1;
                continue;
            },
        };
        const r = fromWire(&w, workspace) orelse {
            stats.skipped += 1;
            continue;
        };
        if (try model.store.insertRestored(r) != .added) {
            stats.skipped += 1;
            continue;
        }
        restored += 1;
        stats.records += 1;
        if (r.agent != null and r.origin == .local) {
            try model.restored_agent_records.put(model.gpa, r.id, {});
        }
    }

    if (root.get("manual")) |manual| {
        if (manual == .object) {
            if (manual.object.get("workspace")) |b| {
                if (b == .bool and b.bool) {
                    try model.addRestoredWorkspaceMark(workspace);
                    stats.marks += 1;
                }
            }
            for (arrayItems(manual.object.get("surfaces"))) |s| {
                const id = uuidValue(s) orelse continue;
                try model.addRestoredSurfaceMark(workspace, id);
                stats.marks += 1;
            }
        }
    }
    return stats;
}

/// `restore` from JSON text; text that is not JSON fails with
/// `error.InvalidSnapshot`.
pub fn restoreSlice(model: *Model, workspace: Uuid, json: []const u8) RestoreError!RestoreStats {
    const parsed = std.json.parseFromSlice(Value, model.gpa, json, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSnapshot,
    };
    defer parsed.deinit();
    return restore(model, workspace, parsed.value);
}

fn arrayItems(v: ?Value) []const Value {
    const x = v orelse return &.{};
    return switch (x) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn uuidValue(v: Value) ?Uuid {
    return switch (v) {
        .string => |s| parseUuid(s),
        else => null,
    };
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
            .category = std.meta.stringToEnum(store_mod.AgentCategory, a.category) orelse .other,
            .session_id = a.session_id,
            .is_subagent = a.is_subagent,
            .pending_background = a.pending_background,
        } else null,
        .correlation_key = if (w.correlation_key) |k| parseUuid(k) else null,
        .click_action = if (w.click_action) |ca| clickFromWire(ca) else null,
        .reply_shape = std.meta.stringToEnum(store_mod.ReplyShape, w.reply_shape) orelse .none,
        .scroll_anchor = w.scroll_anchor,
        .effects = w.effects,
    };
}

fn clickFromWire(ca: WireClick) ?store_mod.ClickAction {
    const kind = std.meta.stringToEnum(std.meta.Tag(store_mod.ClickAction), ca.kind) orelse return null;
    return switch (kind) {
        .open_file => .{ .open_file = ca.value orelse return null },
        .open_url => .{ .open_url = ca.value orelse return null },
        .reply => .reply,
    };
}

/// cmux: a restored notification of a local agent pane whose agent died with
/// the app is swept once it is read, unless the agent returned to that pane;
/// unread ones survive until read. Only records watched since `restore` are
/// considered (live records are never swept). `agent_returned` reports
/// whether an agent of `agent_kind` came back to `surface` since the restore;
/// once it did, the record is live again and no longer watched. Call after
/// restore and whenever records are read; swept ids go to `out`.
pub fn sweepOrphanedAgentRecords(
    model: *Model,
    ctx: *anyopaque,
    agent_returned: *const fn (ctx: *anyopaque, surface: ?Uuid, agent_kind: []const u8) bool,
    out: ?*store_mod.IdList,
) !usize {
    const watched = &model.restored_agent_records;
    var n: usize = 0;
    var i: usize = 0;
    while (i < watched.count()) {
        const id = watched.keys()[i];
        const idx = model.store.indexOf(id) orelse {
            watched.swapRemoveAt(i);
            continue;
        };
        const r = &model.store.records.items[idx];
        const agent = r.agent orelse {
            watched.swapRemoveAt(i);
            continue;
        };
        if (agent_returned(ctx, r.surface, agent.kind)) {
            watched.swapRemoveAt(i);
            continue;
        }
        if (!r.read) {
            i += 1;
            continue;
        }
        if (out) |o| try o.append(model.gpa, id);
        var old = model.store.records.orderedRemove(idx);
        old.deinit(model.gpa);
        watched.swapRemoveAt(i);
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
    const stats = try restoreSlice(&m2, ws1, json);
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
    const stats = try restoreSlice(&m2, ws1, json);
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
    const stats = try restoreSlice(&m2, ws1, json);
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
    const stats = try restoreSlice(&m, ws1, "{}");
    try testing.expectEqual(@as(usize, 0), stats.records + stats.marks + stats.tombstones);
}

test "unit: notifications: restore rejects malformed documents and skips bad entries" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try testing.expectError(error.InvalidSnapshot, restoreSlice(&m, ws1, ""));
    try testing.expectError(error.InvalidSnapshot, restoreSlice(&m, ws1, "{\"unread\":"));
    try testing.expectError(error.InvalidSnapshot, restoreSlice(&m, ws1, "[]"));
    try testing.expectError(error.InvalidSnapshot, restoreSlice(&m, ws1, "\"notifications\""));
    const no_id = try restoreSlice(&m, ws1, "{\"unread\":[{\"title\":\"no id\"}]}");
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
    const stats = try restoreSlice(&m, ws1, doc);
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

test "unit: notifications: restore skips a wrongly typed entry and keeps the rest" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    // One bad entry (wrong types, not an object) must not cost the
    // workspace its other records, marks and tombstones; unknown enum names
    // from a newer build fall back instead of failing.
    const doc =
        \\{"unread":[{"id":"00000000-0000-4000-8000-000000000001","created_at_ms":"soon"},
        \\           5, null, "x",
        \\           {"id":"00000000-0000-4000-8000-000000000002","effects":{"desktop":"no"}},
        \\           {"id":"00000000-0000-4000-8000-000000000003","created_at_ms":7,
        \\            "agent":{"kind":"claude","category":"error-report"},
        \\            "reply_shape":"choices","click_action":{"kind":"open_terminal","value":"x"}}],
        \\ "manual":{"workspace":true,"surfaces":[1,"00000000-0000-4000-8000-00000000001b"]},
        \\ "tombstones":[{"id":"x"},"00000000-0000-4000-8000-000000000009"]}
    ;
    const stats = try restoreSlice(&m, ws1, doc);
    try testing.expectEqual(@as(usize, 1), stats.records);
    try testing.expectEqual(@as(usize, 5), stats.skipped);
    try testing.expectEqual(@as(usize, 2), stats.marks);
    try testing.expectEqual(@as(usize, 1), stats.tombstones);
    const r = m.store.records.items[0];
    try testing.expectEqualStrings(&testUuid(3), &r.id);
    try testing.expectEqual(store_mod.AgentCategory.other, r.agent.?.category);
    try testing.expectEqual(store_mod.ReplyShape.none, r.reply_shape);
    try testing.expect(r.click_action == null);
    try testing.expect(m.marks.restored_workspaces.contains(ws1));
    try testing.expect(m.marks.restored_surfaces.contains(pb));
    try testing.expect(m.store.isTombstoned(testUuid(9)));
    // Sections of the wrong type are ignored, not fatal.
    const odd = try restoreSlice(&m, ws2, "{\"unread\":{},\"manual\":[],\"tombstones\":\"x\"}");
    try testing.expectEqual(@as(usize, 0), odd.records + odd.skipped + odd.marks + odd.tombstones);
    const flag = try restoreSlice(&m, ws2, "{\"manual\":{\"workspace\":\"yes\",\"surfaces\":null}}");
    try testing.expectEqual(@as(usize, 0), flag.marks);
}

test "unit: notifications: snapshot and restore work inside a session document" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    try addTo(&m, .{ .id = testUuid(1), .workspace = ws1, .surface = pa, .title = "t", .created_at_ms = 3 });
    try m.setSurfaceManualUnread(ws1, pb, true);

    // The session writer owns the Stringify and nests our value (ADR-9.2).
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("ext");
    try jw.beginObject();
    try jw.objectField("notifications");
    try snapshot(&m, ws1, &jw);
    try jw.endObject();
    try jw.endObject();

    const parsed = try std.json.parseFromSlice(Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const section = parsed.value.object.get("ext").?.object.get("notifications").?;
    var m2 = Model.init(gpa);
    defer m2.deinit();
    const stats = try restore(&m2, ws1, section);
    try testing.expectEqual(@as(usize, 1), stats.records);
    try testing.expectEqual(@as(usize, 1), stats.marks);
    try testing.expect(m2.surfaceUnread(pa) and m2.surfaceUnread(pb));
    try testing.expectError(error.InvalidSnapshot, restore(&m2, ws1, .{ .integer = 1 }));
}

test "unit: notifications: restore is leak-free under allocation failure" {
    const S = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var m = Model.init(gpa);
            defer m.deinit();
            const doc =
                \\{"unread":[{"id":"00000000-0000-4000-8000-000000000001","title":"a","body":"b",
                \\            "agent":{"kind":"claude","category":"turn_complete","session_id":"s"},
                \\            "click_action":{"kind":"open_url","value":"https://example.invalid/"}},
                \\           {"id":"00000000-0000-4000-8000-000000000002","surface":"00000000-0000-4000-8000-00000000001a"}],
                \\ "manual":{"workspace":true,"surfaces":["00000000-0000-4000-8000-00000000001b"]},
                \\ "tombstones":["00000000-0000-4000-8000-000000000009"]}
            ;
            _ = try restoreSlice(&m, ws1, doc);
            const json = try snapshotAlloc(gpa, &m, ws1);
            gpa.free(json);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
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
    _ = try restoreSlice(&m2, ws1, json);
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
    _ = try restoreSlice(&m2, ws1, j1);
    _ = try restoreSlice(&m2, ws2, j2);
    const order = [_]u32{ 2, 3, 1 };
    for (order, 0..) |n, i| try testing.expectEqualStrings(&testUuid(n), &m2.store.records.items[i].id);
    // Restoring the same snapshot twice does not duplicate.
    const again = try restoreSlice(&m2, ws1, j1);
    try testing.expectEqual(@as(usize, 0), again.records);
    try testing.expectEqual(@as(usize, 3), m2.store.records.items.len);
}

const ReturnedKind = struct {
    kind: []const u8,
    fn returned(ctx: *anyopaque, surface: ?Uuid, agent_kind: []const u8) bool {
        _ = surface;
        const self: *ReturnedKind = @ptrCast(@alignCast(ctx));
        return std.mem.eql(u8, agent_kind, self.kind);
    }
};

test "unit: notifications: restored agent records are swept once read unless the agent returned" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    const pc = testUuid(0x1C);
    const pd = testUuid(0x1D);
    try addTo(&m, .{ .id = testUuid(1), .workspace = ws1, .surface = pa, .created_at_ms = 1, .agent = .{ .kind = "claude", .category = .turn_complete } });
    try addTo(&m, .{ .id = testUuid(2), .workspace = ws1, .surface = pb, .created_at_ms = 2, .agent = .{ .kind = "codex", .category = .turn_complete } });
    try addTo(&m, .{ .id = testUuid(3), .workspace = ws1, .surface = pc, .created_at_ms = 3 });
    try addTo(&m, .{ .id = testUuid(4), .workspace = ws1, .surface = pd, .created_at_ms = 4, .origin = .{ .ssh_relay = ws2 }, .agent = .{ .kind = "claude", .category = .turn_complete } });
    const json = try snapshotAlloc(gpa, &m, ws1);
    defer gpa.free(json);

    var m2 = Model.init(gpa);
    defer m2.deinit();
    _ = try restoreSlice(&m2, ws1, json);
    // Only the two local agent records are watched.
    try testing.expectEqual(@as(usize, 2), m2.restored_agent_records.count());
    var nobody: ReturnedKind = .{ .kind = "" };
    // Right after restore everything is unread: nothing is swept.
    try testing.expectEqual(@as(usize, 0), try sweepOrphanedAgentRecords(&m2, &nobody, ReturnedKind.returned, null));
    // A live agent record of this session is never swept.
    try addTo(&m2, .{ .id = testUuid(5), .workspace = ws1, .surface = testUuid(0x1E), .created_at_ms = 9, .agent = .{ .kind = "claude", .category = .turn_complete } });
    _ = try m2.markAllRead(null);
    // The codex agent came back to its pane; claude did not.
    var codex: ReturnedKind = .{ .kind = "codex" };
    var ids: store_mod.IdList = .empty;
    defer ids.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try sweepOrphanedAgentRecords(&m2, &codex, ReturnedKind.returned, &ids));
    try testing.expectEqualStrings(&testUuid(1), &ids.items[0]);
    try testing.expectEqual(@as(usize, 4), m2.store.records.items.len);
    try testing.expectEqual(@as(usize, 0), m2.restored_agent_records.count());
    // The returned agent's record stays even if the agent leaves again.
    try testing.expectEqual(@as(usize, 0), try sweepOrphanedAgentRecords(&m2, &nobody, ReturnedKind.returned, null));
    try testing.expect(m2.store.indexOf(testUuid(2)) != null);
}

test "unit: notifications: sweep forgets watched records that are gone" {
    const gpa = testing.allocator;
    var m = Model.init(gpa);
    defer m.deinit();
    const doc =
        \\{"unread":[{"id":"00000000-0000-4000-8000-000000000001","surface":"00000000-0000-4000-8000-00000000001a",
        \\            "agent":{"kind":"claude","category":"needs_permission"}}]}
    ;
    _ = try restoreSlice(&m, ws1, doc);
    try testing.expectEqual(@as(usize, 1), m.restored_agent_records.count());
    try testing.expect(try m.store.dismiss(testUuid(1)));
    var nobody: ReturnedKind = .{ .kind = "" };
    try testing.expectEqual(@as(usize, 0), try sweepOrphanedAgentRecords(&m, &nobody, ReturnedKind.returned, null));
    try testing.expectEqual(@as(usize, 0), m.restored_agent_records.count());
}
