//! One-time migration of the legacy wmux session file
//! (`%LOCALAPPDATA%\ghostty\session-state.json`, v2 or v1) into a v3
//! session (ADR-9.8). Everything lands in one window; every object gets a
//! freshly minted UUID and a sequential ref (the old format has no ids).
//!
//! v2: `{version: 2, workspaces: [{name, working_dir, active_container,
//! split_tree}], active_workspace}` where `split_tree` nodes are
//! `{node_type: "leaf", container: {tabs: [{title, kind, cwd}], active_tab}}`
//! or `{node_type: "split", direction, ratio, left, right}`.
//! v1: no or lower `version`; each workspace has a flat `tabs[]`, migrated
//! into a single pane.
//!
//! Mapping: workspace `name` → `title.custom` (source `user`), `working_dir`
//! → `cwd`, `direction`/`ratio`/`left`/`right` → `split.dir/ratio/a/b`,
//! leaf order (left before right) → `panes[]`, `active_container` (a
//! position in v2's own container order, see `v2Container`) →
//! `focused_pane`, `active_tab` → `selected_tab`, tab `title` →
//! `title.auto`, tab `cwd` → terminal `cwd`, `kind: "browser"` → a browser
//! tab at `about:blank` (v2 stored no URL). Leaves without tabs disappear
//! and their split collapses to the sibling.

const std = @import("std");
const schema = @import("schema_v3.zig");
const limits = @import("limits.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Suffix appended to the legacy file name once it has been migrated.
pub const migrated_suffix = ".migrated";

pub const Options = struct {
    /// Source of the minted UUIDs (tests pass a seeded PRNG).
    random: std.Random,
    app_version: []const u8 = "",
    channel: []const u8 = "",
    /// Becomes `created_at`.
    now_ms: i64 = 0,
    /// Placement seeded from the old `window-state` file, if any.
    placement: ?schema.Placement = null,
};

pub const Error = error{
    OutOfMemory,
    /// Not JSON, not an object, over the size or nesting limits, or no
    /// `workspaces` array.
    Corrupt,
    /// The file already is a v3 (or foreign) `schema` document.
    NotLegacy,
    /// A legacy-shaped file claiming a version above 2.
    FutureVersion,
};

pub const Result = struct {
    session: schema.Session,
    /// Version of the source file (1 or 2).
    source_version: u32,
    limits: limits.Report,
};

/// Converts a legacy file into a v3 session allocated in `arena`.
pub fn migrate(arena: Allocator, bytes: []const u8, opts: Options) Error!Result {
    if (bytes.len > limits.max_file_bytes) return error.Corrupt;
    if (limits.exceedsJsonDepth(bytes, limits.max_json_depth)) return error.Corrupt;
    const root = std.json.parseFromSliceLeaky(Value, arena, bytes, .{
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return error.Corrupt,
    };
    if (obj.get("schema") != null) return error.NotLegacy;
    const wss_v = switch (obj.get("workspaces") orelse return error.Corrupt) {
        .array => |a| a.items,
        else => return error.Corrupt,
    };
    const raw_version = getUsize(obj, "version") orelse 1;
    if (raw_version > 2) return error.FutureVersion;
    const version: u32 = if (raw_version == 2) 2 else 1;

    var m: Migrator = .{ .arena = arena, .random = opts.random };
    var ts_buf: [24]u8 = undefined;
    var session: schema.Session = .{
        .app_version = opts.app_version,
        .channel = opts.channel,
        .created_at = try arena.dupe(u8, schema.formatTimestamp(opts.now_ms, &ts_buf)),
        .clean_exit = true,
    };

    var window: schema.Window = .{
        .id = try m.mintId(),
        .ref = m.nextRef(.window),
        .placement = opts.placement,
    };
    var wss: std.ArrayList(schema.Workspace) = .empty;
    for (wss_v) |wv| {
        const wo = asObject(wv) orelse continue;
        try wss.append(arena, try m.workspace(wo, version));
    }
    window.workspaces = wss.items;
    if (window.workspaces.len > 0) {
        const active = getUsize(obj, "active_workspace") orelse 0;
        const idx = if (active < window.workspaces.len) active else 0;
        window.selected_workspace = window.workspaces[idx].id;
    }

    const windows = try arena.alloc(schema.Window, 1);
    windows[0] = window;
    session.windows = windows;
    try schema.normalize(arena, &session);
    const report = try limits.apply(arena, &session);
    return .{ .session = session, .source_version = version, .limits = report };
}

const Migrator = struct {
    arena: Allocator,
    random: std.Random,
    refs: std.EnumArray(schema.Kind, u32) = .initFill(0),

    fn mintId(self: *Migrator) ![]const u8 {
        var buf: [36]u8 = undefined;
        schema.mintUuid(self.random, &buf);
        return self.arena.dupe(u8, &buf);
    }

    fn nextRef(self: *Migrator, kind: schema.Kind) u32 {
        const n = self.refs.get(kind) + 1;
        self.refs.set(kind, n);
        return n;
    }

    fn workspace(self: *Migrator, o: ObjectMap, version: u32) !schema.Workspace {
        var ws: schema.Workspace = .{
            .id = try self.mintId(),
            .ref = self.nextRef(.workspace),
            .cwd = text(o, "working_dir"),
        };
        if (text(o, "name")) |name| {
            if (name.len > 0) ws.title = .{ .custom = name, .source = .user };
        }
        var panes: std.ArrayList(schema.Pane) = .empty;
        if (version >= 2) {
            if (getObject(o, "split_tree")) |root| {
                ws.layout = try self.node(root, &panes, 0);
            }
            if (ws.layout) |layout| {
                // Out of range: v2 focused its first container.
                const active = getUsize(o, "active_container") orelse 0;
                ws.focused_pane = v2Container(layout, active) orelse v2Container(layout, 0);
            }
        } else {
            if (try self.pane(o, &panes)) |id| ws.layout = .{ .pane = id };
        }
        ws.panes = panes.items;
        if (ws.focused_pane == null and ws.panes.len > 0) ws.focused_pane = ws.panes[0].id;
        return ws;
    }

    fn node(self: *Migrator, o: ObjectMap, panes: *std.ArrayList(schema.Pane), depth: usize) !?schema.Layout {
        if (depth > limits.max_layout_depth) return null;
        const kind = getString(o, "node_type") orelse return null;
        if (std.mem.eql(u8, kind, "leaf")) {
            const c = getObject(o, "container") orelse return null;
            const id = try self.pane(c, panes) orelse return null;
            return .{ .pane = id };
        }
        if (!std.mem.eql(u8, kind, "split")) return null;
        const a = if (getObject(o, "left")) |l| try self.node(l, panes, depth + 1) else null;
        const b = if (getObject(o, "right")) |r| try self.node(r, panes, depth + 1) else null;
        if (a == null) return b;
        if (b == null) return a;
        const split = try self.arena.create(schema.Split);
        const dir = getString(o, "direction") orelse "horizontal";
        split.* = .{
            .dir = if (std.mem.eql(u8, dir, "vertical")) .vertical else .horizontal,
            .ratio = schema.sanitizeRatio(getFloat(o, "ratio") orelse 0.5),
            .a = a.?,
            .b = b.?,
        };
        return .{ .split = split };
    }

    /// Appends a pane built from `{tabs, active_tab}`; null when no tabs.
    fn pane(self: *Migrator, c: ObjectMap, panes: *std.ArrayList(schema.Pane)) !?[]const u8 {
        const tabs_v = switch (c.get("tabs") orelse return null) {
            .array => |a| a.items,
            else => return null,
        };
        var tabs: std.ArrayList(schema.Tab) = .empty;
        for (tabs_v) |tv| {
            const to = asObject(tv) orelse continue;
            try tabs.append(self.arena, try self.tab(to));
        }
        if (tabs.items.len == 0) return null;
        const active = getUsize(c, "active_tab") orelse 0;
        const sel = @min(active, tabs.items.len - 1);
        const p: schema.Pane = .{
            .id = try self.mintId(),
            .ref = self.nextRef(.pane),
            .selected_tab = tabs.items[sel].id,
            .tabs = tabs.items,
        };
        try panes.append(self.arena, p);
        return p.id;
    }

    fn tab(self: *Migrator, o: ObjectMap) !schema.Tab {
        const kind = getString(o, "kind") orelse "terminal";
        const panel: schema.Panel = if (std.mem.eql(u8, kind, "browser"))
            .{ .browser = .{ .url = "about:blank" } }
        else
            .{ .terminal = .{ .cwd = text(o, "cwd") } };
        return .{
            .id = try self.mintId(),
            .ref = self.nextRef(.surface),
            .title = .{ .auto = text(o, "title") },
            .panel = panel,
        };
    }
};

/// The pane v2 meant by container `index`. v2 saved `active_container` as a
/// position in `SplitTree.iterator()`, which walks the tree's node array,
/// not the tree, and its reader rebuilt that array with
/// `left.split(.root, dir, ratio, right)`: the right subtree's nodes come
/// first and a lone left leaf moves to the end. So a split whose `a` is a
/// single pane counts `b`'s panes and then that pane; any other split
/// counts `a`'s panes and then `b`'s. A right split of one pane is thus
/// [right, left]. Following the v2 reader keeps the focus v2 restored.
fn v2Container(layout: schema.Layout, index: usize) ?[]const u8 {
    var remaining = index;
    return v2ContainerAt(layout, &remaining);
}

fn v2ContainerAt(l: schema.Layout, remaining: *usize) ?[]const u8 {
    switch (l) {
        .pane => |id| {
            if (remaining.* == 0) return id;
            remaining.* -= 1;
            return null;
        },
        .split => |s| {
            const first, const second = if (s.a == .pane) .{ s.b, s.a } else .{ s.a, s.b };
            return v2ContainerAt(first, remaining) orelse v2ContainerAt(second, remaining);
        },
    }
}

fn asObject(v: Value) ?ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn getObject(o: ObjectMap, k: []const u8) ?ObjectMap {
    return asObject(o.get(k) orelse return null);
}

fn getString(o: ObjectMap, k: []const u8) ?[]const u8 {
    return switch (o.get(k) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Non-empty string field capped like every v3 text field.
fn text(o: ObjectMap, k: []const u8) ?[]const u8 {
    const s = getString(o, k) orelse return null;
    if (s.len == 0) return null;
    return limits.truncateUtf8(s, limits.max_text_bytes);
}

fn getUsize(o: ObjectMap, k: []const u8) ?usize {
    return switch (o.get(k) orelse return null) {
        .integer => |i| std.math.cast(usize, i),
        else => null,
    };
}

fn getFloat(o: ObjectMap, k: []const u8) ?f64 {
    return switch (o.get(k) orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn seeded(prng: *std.Random.DefaultPrng) Options {
    prng.* = .init(0x5E55);
    return .{ .random = prng.random() };
}

test "unit: session: v2 fixture migrates to the golden v3 document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x5E55);
    const r = try migrate(arena.allocator(), @embedFile("testdata/v2_basic.json"), .{
        .random = prng.random(),
        .app_version = "1.2.0",
        .channel = "stable",
        .now_ms = 1_792_058_400_000,
        .placement = .{ .x = 10, .y = 20, .w = 1280, .h = 800, .maximized = true },
    });
    try testing.expectEqual(@as(u32, 2), r.source_version);
    try testing.expect(!r.limits.any());
    const out = try schema.writeAlloc(testing.allocator, &r.session, .{ .pretty = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(@embedFile("testdata/v2_basic.migrated.json"), out);

    // The migrated document is a valid v3 file that reads back unchanged.
    var p = try schema.parse(testing.allocator, out, .{}, null);
    defer p.deinit();
    const again = try schema.writeAlloc(testing.allocator, &p.session, .{ .pretty = true });
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "unit: session: v2 migration maps tree, focus, tabs and cwd" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = undefined;
    const r = try migrate(arena.allocator(), @embedFile("testdata/v2_basic.json"), seeded(&prng));
    const w = r.session.windows[0];
    try testing.expectEqual(@as(usize, 2), w.workspaces.len);
    try testing.expectEqualStrings(w.workspaces[1].id.?, w.selected_workspace.?);
    const ws = w.workspaces[0];
    try testing.expectEqualStrings("api ✓", ws.title.custom.?);
    try testing.expectEqualStrings("C:\\src\\api", ws.cwd.?);
    const split = ws.layout.?.split;
    try testing.expectEqual(schema.SplitDir.vertical, split.dir);
    try testing.expectEqual(@as(f32, 0.3), split.ratio);
    try testing.expectEqualStrings(ws.panes[0].id.?, split.a.pane);
    try testing.expectEqualStrings(ws.panes[1].id.?, split.b.pane);
    // v2 counted this split's containers as [b, a]: active_container 1 is
    // the left (`a`) pane.
    try testing.expectEqualStrings(ws.panes[0].id.?, ws.focused_pane.?);
    // active_tab 1 selects the browser tab, which restores at about:blank.
    try testing.expectEqualStrings(ws.panes[0].tabs[1].id.?, ws.panes[0].selected_tab.?);
    try testing.expectEqualStrings("about:blank", ws.panes[0].tabs[1].panel.browser.url);
    try testing.expectEqualStrings("Docs", ws.panes[0].tabs[1].title.auto.?);
    try testing.expectEqualStrings("D:\\logs", ws.panes[1].tabs[0].panel.terminal.cwd.?);
    // Out-of-range active_tab 7 clamps to the last tab.
    const p2 = w.workspaces[1].panes[0];
    try testing.expectEqualStrings(p2.tabs[0].id.?, p2.selected_tab.?);
    // Refs are sequential per kind and handles.next follows them.
    try testing.expectEqual(@as(u32, 4), p2.tabs[0].ref);
    try testing.expectEqual(@as(u32, 5), r.session.handles.next.surface);
    try testing.expectEqual(@as(u32, 4), r.session.handles.next.pane);
    try testing.expectEqual(@as(u32, 3), r.session.handles.next.workspace);
}

/// Title of the first tab of the focused pane of the first workspace.
fn focusedTitle(r: Result) ?[]const u8 {
    const ws = r.session.windows[0].workspaces[0];
    const pane = schema.findPane(ws.panes, ws.focused_pane orelse return null) orelse return null;
    return pane.tabs[0].title.auto;
}

test "unit: session: v2 active_container follows SplitTree node order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = undefined;
    const leaf = struct {
        fn f(comptime t: []const u8) []const u8 {
            return "{\"node_type\":\"leaf\",\"container\":{\"tabs\":[{\"title\":\"" ++ t ++ "\"}]}}";
        }
    }.f;
    const split = struct {
        fn f(comptime a: []const u8, comptime b: []const u8) []const u8 {
            return "{\"node_type\":\"split\",\"direction\":\"horizontal\",\"left\":" ++ a ++ ",\"right\":" ++ b ++ "}";
        }
    }.f;
    const Case = struct { tree: []const u8, order: []const []const u8 };
    const cases = [_]Case{
        // One split, as after a right split of one pane: the right pane is
        // container 0 (the common case).
        .{ .tree = split(leaf("A"), leaf("B")), .order = &.{ "B", "A" } },
        // The left side split again.
        .{ .tree = split(split(leaf("A"), leaf("C")), leaf("B")), .order = &.{ "C", "A", "B" } },
        // The right side split again.
        .{ .tree = split(leaf("A"), split(leaf("B"), leaf("C"))), .order = &.{ "C", "B", "A" } },
        .{ .tree = leaf("A"), .order = &.{"A"} },
    };
    for (cases) |c| {
        for (0..c.order.len + 1) |active| {
            const doc = try std.fmt.allocPrint(arena.allocator(), "{{\"version\":2,\"workspaces\":[{{\"split_tree\":{s},\"active_container\":{d}}}]}}", .{ c.tree, active });
            const r = try migrate(arena.allocator(), doc, seeded(&prng));
            // Out of range falls back to container 0, as v2 did.
            const want = if (active < c.order.len) c.order[active] else c.order[0];
            try testing.expectEqualStrings(want, focusedTitle(r).?);
        }
    }
}

test "unit: session: v1 fixture migrates flat tabs into one pane" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = undefined;
    const r = try migrate(arena.allocator(), @embedFile("testdata/v1_flat.json"), seeded(&prng));
    try testing.expectEqual(@as(u32, 1), r.source_version);
    const ws = r.session.windows[0].workspaces[0];
    try testing.expectEqualStrings("old", ws.title.custom.?);
    try testing.expectEqualStrings("C:\\old", ws.cwd.?);
    try testing.expectEqual(@as(usize, 1), ws.panes.len);
    try testing.expectEqual(@as(usize, 2), ws.panes[0].tabs.len);
    try testing.expectEqualStrings("two", ws.panes[0].tabs[1].title.auto.?);
    try testing.expect(ws.panes[0].tabs[0].panel == .terminal);
    try testing.expectEqualStrings(ws.panes[0].id.?, ws.layout.?.pane);
    try testing.expectEqualStrings(ws.panes[0].id.?, ws.focused_pane.?);
}

test "unit: session: v2 empty leaves collapse and empty workspaces survive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = undefined;
    const r = try migrate(arena.allocator(),
        \\{"version":2,"workspaces":[
        \\ {"name":"","split_tree":{"node_type":"split","direction":"horizontal","ratio":0.5,
        \\   "left":{"node_type":"leaf","container":{"tabs":[],"active_tab":0}},
        \\   "right":{"node_type":"split","ratio":null,"left":{"node_type":"leaf","container":{"tabs":[{"title":"x"}]}},"right":{"node_type":"bogus"}}},
        \\  "active_container":5},
        \\ {"name":"empty","split_tree":null},
        \\ 42,
        \\ {"name":"weird","split_tree":{"node_type":"leaf","container":{"tabs":"no"}}}],
        \\ "active_workspace":-1}
    , seeded(&prng));
    const w = r.session.windows[0];
    try testing.expectEqual(@as(usize, 3), w.workspaces.len);
    try testing.expectEqualStrings(w.workspaces[0].id.?, w.selected_workspace.?);
    const ws = w.workspaces[0];
    try testing.expectEqual(schema.TitleSource.auto, ws.title.source);
    try testing.expect(ws.title.custom == null);
    try testing.expectEqual(@as(usize, 1), ws.panes.len);
    try testing.expectEqualStrings(ws.panes[0].id.?, ws.layout.?.pane);
    try testing.expectEqualStrings(ws.panes[0].id.?, ws.focused_pane.?);
    try testing.expectEqual(@as(usize, 0), w.workspaces[1].panes.len);
    try testing.expect(w.workspaces[1].layout == null);
    try testing.expect(w.workspaces[1].focused_pane == null);
    try testing.expectEqual(@as(usize, 0), w.workspaces[2].panes.len);
}

test "unit: session: migration refuses corrupt, v3 and future legacy files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = undefined;
    const a = arena.allocator();
    try testing.expectError(error.Corrupt, migrate(a, "", seeded(&prng)));
    try testing.expectError(error.Corrupt, migrate(a, "{\"version\":2,\"workspaces\":[", seeded(&prng)));
    try testing.expectError(error.Corrupt, migrate(a, "[]", seeded(&prng)));
    try testing.expectError(error.Corrupt, migrate(a, "{\"version\":2}", seeded(&prng)));
    try testing.expectError(error.Corrupt, migrate(a, "{\"version\":2,\"workspaces\":{}}", seeded(&prng)));
    try testing.expectError(error.NotLegacy, migrate(a, @embedFile("testdata/v3_full.json"), seeded(&prng)));
    try testing.expectError(error.FutureVersion, migrate(a, "{\"version\":3,\"workspaces\":[]}", seeded(&prng)));
    const v2 = std.mem.trimRight(u8, @embedFile("testdata/v2_basic.json"), "\n");
    for (0..v2.len) |n| {
        if (migrate(a, v2[0..n], seeded(&prng))) |_| return error.TestUnexpectedResult else |err| try testing.expectEqual(error.Corrupt, err);
    }
}

/// A v2 file whose split tree is a right-leaning chain of `splits` splits,
/// each with a one-tab leaf on the left.
fn chainV2(gpa: Allocator, splits: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const leaf = "{\"node_type\":\"leaf\",\"container\":{\"tabs\":[{}]}}";
    try aw.writer.writeAll("{\"version\":2,\"workspaces\":[{\"split_tree\":");
    for (0..splits) |_| try aw.writer.writeAll("{\"node_type\":\"split\",\"left\":" ++ leaf ++ ",\"right\":");
    try aw.writer.writeAll(leaf);
    for (0..splits) |_| try aw.writer.writeAll("}");
    try aw.writer.writeAll("}]}");
    return aw.toOwnedSlice();
}

test "unit: session: deep v2 split trees are bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = undefined;

    // Deeper than `max_layout_depth`: the part below the cap is dropped and
    // the leaves at depths 1 through `max_layout_depth` remain.
    const deep = try chainV2(testing.allocator, 100);
    defer testing.allocator.free(deep);
    const r = try migrate(arena.allocator(), deep, seeded(&prng));
    const ws = r.session.windows[0].workspaces[0];
    try testing.expect(ws.layout.?.depth() <= limits.max_layout_depth);
    try testing.expectEqual(limits.max_layout_depth, ws.panes.len);
    for (ws.panes) |pane| try testing.expect(schema.layoutContains(ws.layout.?, pane.id.?));

    // Nested past `max_json_depth`: refused before parsing.
    const hostile = try chainV2(testing.allocator, limits.max_json_depth);
    defer testing.allocator.free(hostile);
    try testing.expectError(error.Corrupt, migrate(arena.allocator(), hostile, seeded(&prng)));
}

test "unit: session: migration applies the snapshot limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"version\":1,\"workspaces\":[");
    for (0..limits.max_workspaces_per_window + 5) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll("{\"name\":\"w\",\"tabs\":[");
        const n: usize = if (i == 0) limits.max_surfaces_per_workspace + 3 else 1;
        for (0..n) |j| {
            if (j > 0) try aw.writer.writeAll(",");
            try aw.writer.writeAll("{\"title\":\"t\"}");
        }
        try aw.writer.writeAll("]}");
    }
    try aw.writer.writeAll("]}");
    var prng: std.Random.DefaultPrng = undefined;
    const r = try migrate(arena.allocator(), aw.written(), seeded(&prng));
    try testing.expectEqual(@as(usize, 5), r.limits.dropped_workspaces);
    try testing.expectEqual(@as(usize, 3), r.limits.dropped_surfaces);
    const w = r.session.windows[0];
    try testing.expectEqual(limits.max_workspaces_per_window, w.workspaces.len);
    try testing.expectEqual(limits.max_surfaces_per_workspace, w.workspaces[0].panes[0].tabs.len);
}
