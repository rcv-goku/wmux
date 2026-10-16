//! Pure-logic tests of the sidebar pipeline ("unit: sidebar: ..."):
//! row model, row layout (goldens at DPI scales 1.0/1.25/1.5/2.0) and the
//! virtual list. std + wmux_proto only, so the file can join
//! `zig build test-fast` (ADR-12.1/12.2).
const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("row_model.zig");
const layout = @import("row_layout.zig");
const vlist = @import("virtual_list.zig");
const geometry = @import("../../gfx/logic/geometry.zig");
const text_style = @import("../../gfx/logic/text_style.zig");

test {
    _ = model;
    _ = layout;
    _ = vlist;
}

const testing = std.testing;
const Uuid = model.Uuid;
const Dpi = geometry.Dpi;
const Point = geometry.Point;

fn testId(n: u8) Uuid {
    var u: Uuid = .nil;
    u.b[15] = n;
    return u;
}

/// A representative window: a pinned workspace with badge, spinner, pin,
/// mute and status glyph; a group with two members; a workspace with every
/// detail kind.
fn fixture(a: std.mem.Allocator) ![]const model.Node {
    var b = model.RowBuilder.init(a);
    b.beginSlot(.description);
    try b.markdown("Ship the [docs](https://example.com) today", 0);
    b.beginSlot(.status_entries);
    try b.text("hammer", "compiling", try model.ColorSpec.parseHex("#ff9500"));
    try b.text(null, "tests 12/40", null);
    try b.text(null, "lint ok", null);
    try b.text(null, "fourth", null);
    try b.collapsible(3, null);
    b.beginSlot(.progress);
    try b.progress(0.5, "Building...");
    b.beginSlot(.log);
    try b.text(null, "Compilation failed", .{ .tone = .@"error" });
    b.beginSlot(.branch_dir);
    try b.lineEx(.{ .icon = "branch", .runs = &.{.{ .text = "~/src/very/deep/nested/project/directory/tree" }}, .overflow = .truncate_start });
    b.beginSlot(.pull_requests);
    try b.lineEx(.{ .runs = &.{.{ .text = "PR #42 open" }}, .link = "https://github.com/o/r/pull/42", .color = .{ .tone = .pr_open }, .tooltip = "Open PR #42" });
    b.beginSlot(.ports);
    try b.chips(&.{
        .{ .text = ":3000", .link = "http://localhost:3000" },
        .{ .text = ":8000", .link = "http://localhost:8000" },
        .{ .text = ":5173", .link = "http://localhost:5173" },
    });
    b.beginSlot(.agent_status);
    try b.pills(&.{ .{ .icon = "sparkles", .text = "Claude" }, .{ .text = "running" } });
    const rich = b.finish();

    const nodes = try a.alloc(model.Node, 3);
    nodes[0] = .{ .workspace = .{
        .id = testId(1),
        .custom_title = "Pinned and busy",
        .pinned = true,
        .muted = true,
        .status_glyph = .{ .icon = "bolt" },
        .shortcut_hint = "Ctrl+1",
        .details = .{ .badge = 3, .spinner = true },
    } };
    const members = try a.alloc(model.WorkspaceInput, 2);
    members[0] = .{ .id = testId(2), .auto_title = "zsh" };
    members[1] = .{ .id = testId(3), .custom_title = "A sixty character workspace name that will not fit on a row", .color = model.Color.hex(0xff0000) };
    nodes[1] = .{ .group = .{ .id = testId(10), .title = "Backend", .color = model.Color.hex(0x30a14e), .members = members } };
    nodes[2] = .{ .workspace = .{ .id = testId(4), .custom_title = "Rich", .details = rich } };
    return nodes;
}

fn layoutFixture(a: std.mem.Allocator, scale: f32, settings: model.Settings, width: f32) !struct { rows: []model.Row, lay: layout.Layout } {
    const nodes = try fixture(a);
    const rows = try model.build(a, .{ .nodes = nodes, .settings = settings });
    var fake: text_style.FakeMeasurer = .{};
    const lay = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = width, .dpi = Dpi.fromScale(scale) });
    return .{ .rows = rows, .lay = lay };
}

fn dump(a: std.mem.Allocator, rows: []const model.Row, lay: layout.Layout) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try layout.dumpLayout(&aw.writer, rows, lay);
    return aw.written();
}

// Goldens: the fixture at width 240 DIPs with FakeMeasurer (0.5 em
// advance, 1.25 em lines). Coordinates are DIPs snapped to the device-pixel
// grid of each scale (1/1.25 = 0.8 DIP steps at 125%, 2/3 at 150%).
const golden_100 =
    \\content 335.00
    \\row 0 workspace top=0.00 h=30.00
    \\  spinner [10.00 8.00 24.00 22.00]
    \\  badge [29.00 7.00 45.00 23.00]
    \\  pin [50.00 8.00 64.00 22.00]
    \\  mute [69.00 8.00 83.00 22.00]
    \\  glyph [88.00 8.00 102.00 22.00]
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  hint [191.00 7.00 230.00 23.00] show=modifier_hold
    \\  title [107.00 7.00 209.00 23.00]
    \\row 1 group_header top=30.00 h=27.00
    \\  rail [0.00 0.00 3.00 27.00]
    \\  chevron [10.00 9.00 24.00 23.00] toggle_group
    \\  title [29.00 9.00 230.00 23.00]
    \\row 2 workspace top=57.00 h=30.00
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  title [10.00 7.00 209.00 23.00]
    \\row 3 workspace top=87.00 h=30.00
    \\  rail [0.00 0.00 3.00 30.00]
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  title [10.00 7.00 209.00 23.00] trunc
    \\row 4 workspace top=117.00 h=218.00
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  title [10.00 7.00 209.00 23.00]
    \\  text [10.00 26.00 230.00 40.00]
    \\  link [60.00 26.00 82.00 40.00] open_link
    \\  pill [10.00 43.00 69.00 60.00]
    \\  pill_icon [16.00 45.00 28.00 57.00]
    \\  pill_text [32.00 45.00 63.00 58.00]
    \\  pill [73.00 43.00 121.00 60.00]
    \\  pill_text [79.00 45.00 115.00 58.00]
    \\  icon [10.00 63.00 22.00 75.00]
    \\  text [27.00 63.00 230.00 76.00]
    \\  text [10.00 79.00 230.00 93.00]
    \\  text [10.00 96.00 230.00 110.00]
    \\  toggle [10.00 113.00 56.00 126.00] toggle_expand
    \\  progress_label [170.00 129.00 230.00 142.00]
    \\  progress_track [10.00 134.00 165.00 138.00]
    \\  text [10.00 145.00 230.00 159.00]
    \\  icon [10.00 163.00 22.00 175.00]
    \\  text [27.00 162.00 230.00 176.00] trunc "…/deep/nested/project/directory/tree"
    \\  text [10.00 179.00 230.00 193.00] open_link
    \\  chip [10.00 196.00 46.00 210.00] open_link
    \\  chip [50.00 196.00 85.00 210.00] open_link
    \\  chip [89.00 196.00 125.00 210.00] open_link
    \\
;

const golden_125 =
    \\content 336.00
    \\row 0 workspace top=0.00 h=30.40
    \\  spinner [10.40 8.00 24.00 22.40]
    \\  badge [28.80 7.20 44.80 23.20]
    \\  pin [50.40 8.00 64.00 22.40]
    \\  mute [68.80 8.00 83.20 22.40]
    \\  glyph [88.00 8.00 102.40 22.40]
    \\  close [214.40 7.20 230.40 23.20] close show=hover
    \\  hint [190.40 7.20 230.40 23.20] show=modifier_hold
    \\  title [107.20 7.20 208.80 23.20]
    \\row 1 group_header top=30.40 h=27.20
    \\  rail [0.00 0.00 3.20 27.20]
    \\  chevron [10.40 8.80 24.00 23.20] toggle_group
    \\  title [28.80 9.60 230.40 22.40]
    \\row 2 workspace top=57.60 h=30.40
    \\  close [214.40 7.20 230.40 23.20] close show=hover
    \\  title [10.40 7.20 208.80 23.20]
    \\row 3 workspace top=88.00 h=30.40
    \\  rail [0.00 0.00 3.20 30.40]
    \\  close [214.40 7.20 230.40 23.20] close show=hover
    \\  title [10.40 7.20 208.80 23.20] trunc
    \\row 4 workspace top=118.40 h=217.60
    \\  close [214.40 7.20 230.40 23.20] close show=hover
    \\  title [10.40 7.20 208.80 23.20]
    \\  text [10.40 26.40 230.40 40.00]
    \\  link [59.20 26.40 81.60 40.00] open_link
    \\  pill [10.40 42.40 68.80 59.20]
    \\  pill_icon [16.00 44.80 28.00 56.80]
    \\  pill_text [32.00 44.80 62.40 57.60]
    \\  pill [72.80 42.40 120.80 59.20]
    \\  pill_text [78.40 44.80 114.40 57.60]
    \\  icon [10.40 63.20 22.40 75.20]
    \\  text [27.20 62.40 230.40 76.00]
    \\  text [10.40 79.20 230.40 92.80]
    \\  text [10.40 96.00 230.40 109.60]
    \\  toggle [10.40 112.80 56.00 125.60] toggle_expand
    \\  progress_label [169.60 128.80 230.40 142.40]
    \\  progress_track [10.40 133.60 164.80 137.60]
    \\  text [10.40 145.60 230.40 159.20]
    \\  icon [10.40 163.20 22.40 175.20]
    \\  text [27.20 162.40 230.40 176.00] trunc "…/deep/nested/project/directory/tree"
    \\  text [10.40 179.20 230.40 192.80] open_link
    \\  chip [10.40 196.00 45.60 210.40] open_link
    \\  chip [49.60 196.00 85.60 210.40] open_link
    \\  chip [89.60 196.00 124.80 210.40] open_link
    \\
;

const golden_150 =
    \\content 335.33
    \\row 0 workspace top=0.00 h=30.00
    \\  spinner [10.00 8.00 24.00 22.00]
    \\  badge [29.33 7.33 45.33 23.33]
    \\  pin [50.00 8.00 64.00 22.00]
    \\  mute [69.33 8.00 83.33 22.00]
    \\  glyph [88.00 8.00 102.00 22.00]
    \\  close [214.00 7.33 230.00 23.33] close show=hover
    \\  hint [190.67 7.33 230.00 23.33] show=modifier_hold
    \\  title [107.33 7.33 209.33 22.67]
    \\row 1 group_header top=30.00 h=27.33
    \\  rail [0.00 0.00 3.33 27.33]
    \\  chevron [10.00 9.33 24.00 23.33] toggle_group
    \\  title [29.33 9.33 230.00 22.67]
    \\row 2 workspace top=57.33 h=30.00
    \\  close [214.00 7.33 230.00 23.33] close show=hover
    \\  title [10.00 7.33 209.33 22.67]
    \\row 3 workspace top=87.33 h=30.00
    \\  rail [0.00 0.00 3.33 30.00]
    \\  close [214.00 7.33 230.00 23.33] close show=hover
    \\  title [10.00 7.33 209.33 22.67] trunc
    \\row 4 workspace top=117.33 h=218.00
    \\  close [214.00 7.33 230.00 23.33] close show=hover
    \\  title [10.00 7.33 209.33 22.67]
    \\  text [10.00 26.00 230.00 40.00]
    \\  link [59.33 26.00 81.33 40.00] open_link
    \\  pill [10.00 42.67 68.67 59.33]
    \\  pill_icon [16.00 45.33 28.00 57.33]
    \\  pill_text [32.00 44.67 62.67 57.33]
    \\  pill [72.67 42.67 120.67 59.33]
    \\  pill_text [78.67 44.67 114.67 57.33]
    \\  icon [10.00 63.33 22.00 75.33]
    \\  text [27.33 62.67 230.00 76.00]
    \\  text [10.00 79.33 230.00 93.33]
    \\  text [10.00 96.00 230.00 110.00]
    \\  toggle [10.00 112.67 56.00 125.33] toggle_expand
    \\  progress_label [169.33 128.67 230.00 142.67]
    \\  progress_track [10.00 133.33 164.67 137.33]
    \\  text [10.00 145.33 230.00 159.33]
    \\  icon [10.00 163.33 22.00 175.33]
    \\  text [27.33 162.00 230.00 176.00] trunc "…/deep/nested/project/directory/tree"
    \\  text [10.00 178.67 230.00 192.67] open_link
    \\  chip [10.00 195.33 45.33 210.67] open_link
    \\  chip [49.33 195.33 85.33 210.67] open_link
    \\  chip [89.33 195.33 124.67 210.67] open_link
    \\
;

const golden_200 =
    \\content 334.50
    \\row 0 workspace top=0.00 h=30.00
    \\  spinner [10.00 8.00 24.00 22.00]
    \\  badge [29.00 7.00 45.00 23.00]
    \\  pin [50.00 8.00 64.00 22.00]
    \\  mute [69.00 8.00 83.00 22.00]
    \\  glyph [88.00 8.00 102.00 22.00]
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  hint [191.00 7.00 230.00 23.00] show=modifier_hold
    \\  title [107.00 7.00 209.00 23.00]
    \\row 1 group_header top=30.00 h=27.00
    \\  rail [0.00 0.00 3.00 27.00]
    \\  chevron [10.00 9.00 24.00 23.00] toggle_group
    \\  title [29.00 9.50 230.00 22.50]
    \\row 2 workspace top=57.00 h=30.00
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  title [10.00 7.00 209.00 23.00]
    \\row 3 workspace top=87.00 h=30.00
    \\  rail [0.00 0.00 3.00 30.00]
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  title [10.00 7.00 209.00 23.00] trunc
    \\row 4 workspace top=117.00 h=217.50
    \\  close [214.00 7.00 230.00 23.00] close show=hover
    \\  title [10.00 7.00 209.00 23.00]
    \\  text [10.00 26.00 230.00 40.00]
    \\  link [59.50 26.00 81.50 40.00] open_link
    \\  pill [10.00 43.00 69.00 59.50]
    \\  pill_icon [16.00 45.00 28.00 57.00]
    \\  pill_text [32.00 45.00 63.00 57.50]
    \\  pill [73.00 43.00 120.50 59.50]
    \\  pill_text [79.00 45.00 114.50 57.50]
    \\  icon [10.00 63.50 22.00 75.50]
    \\  text [27.00 62.50 230.00 76.50]
    \\  text [10.00 79.50 230.00 93.00]
    \\  text [10.00 96.00 230.00 110.00]
    \\  toggle [10.00 113.00 56.00 125.50] toggle_expand
    \\  progress_label [169.50 128.50 230.00 142.50]
    \\  progress_track [10.00 133.50 164.50 137.50]
    \\  text [10.00 145.50 230.00 159.00]
    \\  icon [10.00 163.00 22.00 175.00]
    \\  text [27.00 162.00 230.00 176.00] trunc "…/deep/nested/project/directory/tree"
    \\  text [10.00 179.00 230.00 192.50] open_link
    \\  chip [10.00 195.50 45.50 210.50] open_link
    \\  chip [49.50 195.50 85.50 210.50] open_link
    \\  chip [89.50 195.50 125.00 210.50] open_link
    \\
;

fn expectGolden(scale: f32, golden: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try layoutFixture(a, scale, .{}, 240);
    try testing.expectEqualStrings(golden, try dump(a, r.rows, r.lay));
}

test "unit: sidebar: layout golden at scale 1.0" {
    try expectGolden(1.0, golden_100);
}

test "unit: sidebar: layout golden at scale 1.25" {
    try expectGolden(1.25, golden_125);
}

test "unit: sidebar: layout golden at scale 1.5" {
    try expectGolden(1.5, golden_150);
}

test "unit: sidebar: layout golden at scale 2.0" {
    try expectGolden(2.0, golden_200);
}

fn onGrid(v: f32, scale: f32) bool {
    const px = v * scale;
    return @abs(px - @round(px)) < 1e-3;
}

test "unit: sidebar: every row edge and element rect is on the device pixel grid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0, 3.0 }) |s| {
        for ([_]f32{ 180, 233.3, 240, 400 }) |w| {
            const r = try layoutFixture(a, s, .{ .wrap_workspace_titles = true }, w);
            var expect_top: f32 = 0;
            for (r.lay.rows) |g| {
                try testing.expectApproxEqAbs(expect_top, g.top, 1e-3);
                try testing.expect(onGrid(g.top, s) and onGrid(g.height, s));
                for (g.elements) |e| {
                    try testing.expect(onGrid(e.rect.left, s) and onGrid(e.rect.top, s));
                    try testing.expect(onGrid(e.rect.right, s) and onGrid(e.rect.bottom, s));
                    try testing.expect(e.rect.bottom <= g.height + 1e-3);
                }
                expect_top += g.height;
            }
            try testing.expectApproxEqAbs(expect_top, r.lay.content_height, 1e-3);
        }
    }
}

fn titleOf(g: layout.RowGeom) layout.Element {
    for (g.elements) |e| if (e.kind == .title) return e;
    unreachable;
}

fn findKind(g: layout.RowGeom, kind: layout.ElementKind) ?layout.Element {
    for (g.elements) |e| if (e.kind == kind) return e;
    return null;
}

test "unit: sidebar: long title truncates by default and wraps when enabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try layoutFixture(a, 1.0, .{}, 240);
    const wrapped = try layoutFixture(a, 1.0, .{ .wrap_workspace_titles = true }, 240);
    // Row 3 holds the 60-character name.
    try testing.expect(titleOf(one.lay.rows[3]).truncated);
    try testing.expect(!titleOf(wrapped.lay.rows[3]).truncated);
    try testing.expect(wrapped.lay.rows[3].height > one.lay.rows[3].height);
    // Short titles are unaffected by the wrap setting.
    try testing.expectEqual(one.lay.rows[2].height, wrapped.lay.rows[2].height);
    // Compact agent status forces one line again.
    const compact = try layoutFixture(a, 1.0, .{ .wrap_workspace_titles = true, .compact_agent_status = true }, 240);
    try testing.expect(titleOf(compact.lay.rows[3]).truncated);
    // Its tooltip is the full title.
    const tip = try layout.elementTooltip(a, &one.rows[3], titleOf(one.lay.rows[3]));
    try testing.expectEqualStrings("A sixty character workspace name that will not fit on a row", tip.?);
    try testing.expect((try layout.elementTooltip(a, &one.rows[2], titleOf(one.lay.rows[2]))) == null);
}

test "unit: sidebar: larger font size makes rows taller and badges wider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try fixture(a);
    const rows = try model.build(a, .{ .nodes = nodes });
    var fake: text_style.FakeMeasurer = .{};
    const base = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = 240 });
    const big = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = 240, .metrics = .{ .font_size = 16 } });
    const mag = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = 240, .metrics = .{ .magnification = 1.28 } });
    for (base.rows, big.rows) |b0, b1| try testing.expect(b1.height > b0.height);
    try testing.expect(big.content_height > base.content_height);
    try testing.expect(findKind(big.rows[0], .badge).?.rect.width() > findKind(base.rows[0], .badge).?.rect.width());
    // 12.5 x 1.28 = 16: magnification scales on top of the font size.
    try testing.expectApproxEqAbs(big.content_height, mag.content_height, 1e-3);
    // Garbage metrics fall back to sane values.
    try testing.expectEqual(layout.default_font_size, (layout.Metrics{ .font_size = std.math.nan(f32) }).fontSize());
    try testing.expectEqual(@as(f32, 6), (layout.Metrics{ .font_size = 0.5 }).fontSize());
    try testing.expectEqual(@as(f32, 72), (layout.Metrics{ .font_size = 1e9 }).fontSize());
    try testing.expectEqual(layout.default_font_size, (layout.Metrics{ .magnification = -1 }).fontSize());
}

test "unit: sidebar: hideAllDetails leaves title-only rows with the spinner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try layoutFixture(a, 1.0, .{ .hide_all_details = true }, 240);
    const plain_h = r.lay.rows[2].height;
    try testing.expectEqual(plain_h, r.lay.rows[4].height);
    try testing.expect(findKind(r.lay.rows[0], .spinner) != null);
    for (r.lay.rows[4].elements) |e| try testing.expect(e.item == layout.no_item);
}

test "unit: sidebar: trailing badge hides on hover and close shows in the same spot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try layoutFixture(a, 1.0, .{ .notification_badge_position = .trailing }, 240);
    const g = r.lay.rows[0];
    const badge = findKind(g, .badge).?;
    const close = findKind(g, .close).?;
    try testing.expectEqual(layout.Show.not_hover, badge.show);
    try testing.expectEqual(layout.Show.hover, close.show);
    try testing.expectEqual(@as(u16, 1), badge.sub);
    try testing.expectEqualStrings("3", layout.elementText(&r.rows[0], badge).plain);
    // Both end at the right padding; the title stops before them.
    try testing.expectEqual(badge.rect.right, close.rect.right);
    try testing.expect(titleOf(g).rect.right <= @min(badge.rect.left, close.rect.left));

    const p: Point = .{ .x = close.rect.center().x, .y = close.rect.center().y };
    const idle = vlist.hitTest(r.lay.rows, 240, p, .{}).?;
    try testing.expectEqual(layout.Action.select, idle.action);
    const hover = vlist.hitTest(r.lay.rows, 240, p, .{ .hovered_row = 0 }).?;
    try testing.expectEqual(layout.Action.close, hover.action);
    const tip_at = vlist.elementAt(r.lay.rows, p, .{}).?;
    try testing.expectEqual(layout.ElementKind.badge, g.elements[tip_at.element].kind);
}

test "unit: sidebar: links, chips, toggles and group headers hit-test to actions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try layoutFixture(a, 1.5, .{}, 240);
    const g = r.lay.rows[4];
    var saw_link = false;
    var chips: usize = 0;
    for (g.elements, 0..) |e, i| {
        if (e.action == .none) continue;
        const c = g.absRect(e).center();
        const hit = vlist.hitTest(r.lay.rows, 240, c, .{}).?;
        try testing.expectEqual(@as(usize, 4), hit.row);
        if (e.show == .always) {
            try testing.expectEqual(@as(?usize, i), hit.element);
            try testing.expectEqual(e.action, hit.action);
        }
        switch (e.kind) {
            .link => {
                saw_link = true;
                try testing.expectEqualStrings("https://example.com", layout.elementLink(&r.rows[4], e).?);
                try testing.expectEqualStrings("docs", layout.elementText(&r.rows[4], e).plain);
            },
            .chip => {
                chips += 1;
                try testing.expect(std.mem.startsWith(u8, layout.elementLink(&r.rows[4], e).?, "http://localhost:"));
            },
            .toggle => {
                try testing.expectEqual(@intFromEnum(model.Slot.status_entries), e.sub);
                try testing.expectEqualStrings("Show more", layout.elementText(&r.rows[4], e).plain);
            },
            .text => {
                try testing.expectEqualStrings("https://github.com/o/r/pull/42", layout.elementLink(&r.rows[4], e).?);
                try testing.expectEqualStrings("Open PR #42", (try layout.elementTooltip(a, &r.rows[4], e)).?);
            },
            else => {},
        }
    }
    try testing.expect(saw_link);
    try testing.expectEqual(@as(usize, 3), chips);
    // Group header: anywhere toggles collapse.
    const hdr = r.lay.rows[1];
    const h = vlist.hitTest(r.lay.rows, 240, .{ .x = 200, .y = hdr.top + 1 }, .{}).?;
    try testing.expectEqual(layout.Action.toggle_group, h.action);
    // Outside the sidebar or below the content: nothing.
    try testing.expect(vlist.hitTest(r.lay.rows, 240, .{ .x = 240, .y = 5 }, .{}) == null);
    try testing.expect(vlist.hitTest(r.lay.rows, 240, .{ .x = -1, .y = 5 }, .{}) == null);
    try testing.expect(vlist.hitTest(r.lay.rows, 240, .{ .x = 5, .y = r.lay.content_height }, .{}) == null);
    try testing.expect(vlist.hitTest(r.lay.rows, 240, .{ .x = std.math.nan(f32), .y = 5 }, .{}) == null);
}

test "unit: sidebar: truncate-start paths keep the end and tooltip the original" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try layoutFixture(a, 1.0, .{}, 240);
    var found = false;
    for (r.lay.rows[4].elements) |e| if (e.text_override) |s| {
        found = true;
        try testing.expect(std.mem.startsWith(u8, s, "\u{2026}/"));
        try testing.expect(std.mem.endsWith(u8, s, "/directory/tree"));
        try testing.expect(e.truncated);
        try testing.expectEqualStrings("~/src/very/deep/nested/project/directory/tree", (try layout.elementTooltip(a, &r.rows[4], e)).?);
    };
    try testing.expect(found);
}

test "unit: sidebar: ellipsize helpers at boundaries, unicode and tiny widths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: text_style.FakeMeasurer = .{};
    const m = fake.measurer();
    const st: text_style.TextStyle = .{ .size = 10 }; // 5 DIPs per code point
    try testing.expectEqualStrings("abcdef", try layout.ellipsizeEnd(a, m, "abcdef", &st, 30));
    try testing.expectEqualStrings("abcd\u{2026}", try layout.ellipsizeEnd(a, m, "abcdef", &st, 29.9));
    try testing.expectEqualStrings("\u{2026}", try layout.ellipsizeEnd(a, m, "abcdef", &st, 0));
    try testing.expectEqualStrings("", try layout.ellipsizeEnd(a, m, "", &st, 0));
    try testing.expectEqualStrings("日本\u{2026}", try layout.ellipsizeEnd(a, m, "日本語テキスト", &st, 15));
    try testing.expectEqualStrings("🚀\u{2026}", try layout.ellipsizeEnd(a, m, "🚀🚀🚀", &st, 10));

    try testing.expectEqualStrings("\u{2026}/dir", try layout.ellipsizeStart(a, m, "/a/deep/dir", &st, 25));
    try testing.expectEqualStrings("\u{2026}/deep/dir", try layout.ellipsizeStart(a, m, "/a/deep/dir", &st, 50));
    try testing.expectEqualStrings("\u{2026}\\b\\c", try layout.ellipsizeStart(a, m, "C:\\aaaa\\b\\c", &st, 25));
    // No separator fits: character suffix.
    try testing.expectEqualStrings("\u{2026}name", try layout.ellipsizeStart(a, m, "averylongname", &st, 25));
    try testing.expectEqualStrings("\u{2026}テキ", try layout.ellipsizeStart(a, m, "日本語テキ", &st, 15));
    try testing.expectEqualStrings("\u{2026}", try layout.ellipsizeStart(a, m, "abc/def", &st, 1));
    try testing.expectEqualStrings("\xff\xfe", try layout.ellipsizeStart(a, m, "\xff\xfe", &st, 100));
    try testing.expectEqualStrings("\u{2026}\xfe", try layout.ellipsizeStart(a, m, "\xff\xff\xfe", &st, 10));
}

test "unit: sidebar: degenerate widths never produce inverted rects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f32{ 0, -50, std.math.nan(f32), std.math.inf(f32), 1, 12 }) |w| {
        const r = try layoutFixture(a, 1.25, .{}, w);
        for (r.lay.rows) |g| {
            try testing.expect(g.height > 0 and std.math.isFinite(g.height));
            for (g.elements) |e| {
                try testing.expect(e.rect.right >= e.rect.left - 1e-3);
                try testing.expect(e.rect.bottom >= e.rect.top - 1e-3);
            }
        }
    }
}

test "unit: sidebar: wrapped description with links resolves runs via text position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = model.RowBuilder.init(a);
    b.beginSlot(.description);
    try b.markdown("Ship\n- verify [docs](https://example.com) and the rest of a long line", 0);
    const nodes = [_]model.Node{.{ .workspace = .{ .id = testId(1), .details = b.finish() } }};
    const rows = try model.build(a, .{ .nodes = &nodes });
    var fake: text_style.FakeMeasurer = .{};
    const lay = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = 200 });
    const text = findKind(lay.rows[0], .text).?;
    try testing.expectEqual(layout.Action.text_links, text.action);
    try testing.expect(findKind(lay.rows[0], .link) == null);
    const runs = layout.elementText(&rows[0], text).runs;
    const joined = try model.joinRuns(a, runs);
    const at = std.mem.indexOf(u8, joined, "docs").?;
    try testing.expectEqualStrings("https://example.com", runs[model.runAtOffset(runs, at).?].link.?);
    // Two explicit lines plus wrapping: taller than two detail lines.
    try testing.expect(text.rect.height() >= 3 * 12.5 * 0.88 * 1.25 - 0.5);
    // Hidden by the toggle.
    const off = try model.build(a, .{ .nodes = &nodes, .settings = .{ .show_workspace_description = false } });
    const lay_off = try layout.layoutRows(a, null, off, fake.measurer(), .{ .width = 200 });
    try testing.expect(lay_off.rows[0].height < lay.rows[0].height);
}

test "unit: sidebar: notification preview is capped at the line limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    for (0..30) |i| try body.print(a, "line {d}\n", .{i});
    const settings: model.Settings = .{};
    var b = model.RowBuilder.init(a);
    b.beginSlot(.notification_preview);
    try b.markdownPlain(body.items, settings.notification_message_line_limit);
    const nodes = [_]model.Node{.{ .workspace = .{ .id = testId(1), .details = b.finish() } }};
    const rows = try model.build(a, .{ .nodes = &nodes, .settings = settings });
    var fake: text_style.FakeMeasurer = .{};
    const lay = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = 240 });
    const text = findKind(lay.rows[0], .text).?;
    try testing.expect(text.truncated);
    try testing.expectApproxEqAbs(@as(f32, 12) * 12.5 * 0.88 * 1.25, text.rect.height(), 1.0);
}

test "unit: sidebar: unicode titles measure by code point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]model.Node{
        .{ .workspace = .{ .id = testId(1), .custom_title = "日本語のワークスペース名前がとても長い場合" } },
        .{ .workspace = .{ .id = testId(2), .custom_title = "🚀 deploy" } },
    };
    const rows = try model.build(a, .{ .nodes = &nodes });
    var fake: text_style.FakeMeasurer = .{};
    const lay = try layout.layoutRows(a, null, rows, fake.measurer(), .{ .width = 160 });
    try testing.expect(titleOf(lay.rows[0]).truncated);
    try testing.expect(!titleOf(lay.rows[1]).truncated);
}

test "unit: sidebar: layout cache reuses rows and survives eviction and clear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try fixture(a);
    const rows = try model.build(a, .{ .nodes = nodes });
    var fake: text_style.FakeMeasurer = .{};
    var cache = layout.Cache.init(testing.allocator, 3); // smaller than the row count
    defer cache.deinit();
    const params: layout.Params = .{ .width = 240, .dpi = Dpi.fromScale(1.5) };
    const first = try layout.layoutRows(a, &cache, rows, fake.measurer(), params);
    const uncached = try layout.layoutRows(a, null, rows, fake.measurer(), params);
    try testing.expectEqual(@as(usize, 3), cache.count());
    const second = try layout.layoutRows(a, &cache, rows, fake.measurer(), params);
    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.count());
    // Layouts copied out of the cache stay valid after eviction/clear.
    const d_first = try dump(a, rows, first);
    try testing.expectEqualStrings(try dump(a, rows, uncached), d_first);
    try testing.expectEqualStrings(d_first, try dump(a, rows, second));

    // Width, DPI and font size are part of the key.
    var big = std.heap.ArenaAllocator.init(testing.allocator);
    defer big.deinit();
    var cache2 = layout.Cache.init(testing.allocator, 64);
    defer cache2.deinit();
    _ = try layout.layoutRows(big.allocator(), &cache2, rows, fake.measurer(), params);
    const n = cache2.count();
    _ = try layout.layoutRows(big.allocator(), &cache2, rows, fake.measurer(), params);
    try testing.expectEqual(n, cache2.count());
    _ = try layout.layoutRows(big.allocator(), &cache2, rows, fake.measurer(), .{ .width = 241, .dpi = params.dpi });
    try testing.expect(cache2.count() > n);
    const n2 = cache2.count();
    _ = try layout.layoutRows(big.allocator(), &cache2, rows, fake.measurer(), .{ .width = 240, .dpi = Dpi.fromScale(2) });
    try testing.expect(cache2.count() > n2);
}

test "unit: sidebar: layout cache never serves a stale group rail or link action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = [_]model.Node{
        .{ .group = .{ .id = testId(10), .title = "G" } },
        .{ .workspace = .{ .id = testId(1), .details = .{ .items = &.{
            .{ .slot = .agent_status, .body = .{ .pills = &.{.{ .text = "PR #7" }} } },
            .{ .slot = .ports, .body = .{ .chips = &.{.{ .text = ":3000" }} } },
        } } } },
    };
    // Same titles and texts; only the group color and the links appear.
    const after = [_]model.Node{
        .{ .group = .{ .id = testId(10), .title = "G", .color = model.Color.hex(0x30a14e) } },
        .{ .workspace = .{ .id = testId(1), .details = .{ .items = &.{
            .{ .slot = .agent_status, .body = .{ .pills = &.{.{ .text = "PR #7", .link = "https://github.com/o/r/pull/7" }} } },
            .{ .slot = .ports, .body = .{ .chips = &.{.{ .text = ":3000", .link = "http://localhost:3000" }} } },
        } } } },
    };
    const rows_before = try model.build(a, .{ .nodes = &before });
    const rows_after = try model.build(a, .{ .nodes = &after });
    for (rows_before, rows_after) |b, c| try testing.expect(b.content_hash != c.content_hash);

    var fake: text_style.FakeMeasurer = .{};
    var cache = layout.Cache.init(testing.allocator, 16);
    defer cache.deinit();
    const params: layout.Params = .{ .width = 240 };
    const first = try layout.layoutRows(a, &cache, rows_before, fake.measurer(), params);
    try testing.expect(findKind(first.rows[0], .rail) == null);
    try testing.expectEqual(layout.Action.none, findKind(first.rows[1], .pill).?.action);
    try testing.expectEqual(layout.Action.none, findKind(first.rows[1], .chip).?.action);

    const cached = try layout.layoutRows(a, &cache, rows_after, fake.measurer(), params);
    try testing.expect(findKind(cached.rows[0], .rail) != null);
    try testing.expectEqual(layout.Action.open_link, findKind(cached.rows[1], .pill).?.action);
    try testing.expectEqual(layout.Action.open_link, findKind(cached.rows[1], .chip).?.action);
    const fresh = try layout.layoutRows(a, null, rows_after, fake.measurer(), params);
    try testing.expectEqualStrings(try dump(a, rows_after, fresh), try dump(a, rows_after, cached));
}

test "unit: sidebar: thousands of rows lay out and virtualize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 5000;
    const nodes = try a.alloc(model.Node, n);
    for (nodes, 0..) |*node, i| {
        var id: Uuid = .nil;
        std.mem.writeInt(u32, id.b[12..16], @intCast(i), .big);
        node.* = .{ .workspace = .{ .id = id, .custom_title = try std.fmt.allocPrint(a, "ws {d}", .{i}), .pinned = i % 97 == 0 } };
    }
    const rows = try model.build(a, .{ .nodes = nodes });
    try testing.expectEqual(@as(usize, n), rows.len);
    var fake: text_style.FakeMeasurer = .{};
    var cache = layout.Cache.init(testing.allocator, 8192);
    defer cache.deinit();
    const lay = try layout.layoutRows(a, &cache, rows, fake.measurer(), .{ .width = 240 });
    try testing.expectApproxEqAbs(@as(f32, n) * lay.rows[1].height, lay.content_height, 1);
    var s: vlist.Scroll = .{};
    s.resize(lay.content_height, 600);
    try testing.expect(s.ensureVisible(lay.rows, n - 1));
    const vis = s.visible(lay.rows);
    try testing.expect(vis.contains(n - 1));
    try testing.expect(vis.len() <= 22);
    try testing.expectEqual(s.maxOffset(), s.offset);
}

test "unit: sidebar: debug snapshot is valid JSON with rows and geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try layoutFixture(a, 1.25, .{}, 240);
    var aw: std.Io.Writer.Allocating = .init(a);
    try layout.writeSnapshot(a, &aw.writer, r.rows, r.lay);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 120), root.get("dpi").?.integer);
    const rows = root.get("rows").?.array.items;
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqualStrings("group_header", rows[1].object.get("kind").?.string);
    try testing.expectEqualStrings("00000000-0000-0000-0000-00000000000A", rows[1].object.get("id").?.string);
    const els = rows[0].object.get("elements").?.array.items;
    var saw_title = false;
    for (els) |e| if (std.mem.eql(u8, e.object.get("kind").?.string, "title")) {
        saw_title = true;
        try testing.expectEqualStrings("Pinned and busy", e.object.get("text").?.string);
    };
    try testing.expect(saw_title);
}

test "unit: sidebar: empty model lays out to nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: text_style.FakeMeasurer = .{};
    const lay = try layout.layoutRows(a, null, &.{}, fake.measurer(), .{ .width = 240 });
    try testing.expectEqual(@as(f32, 0), lay.content_height);
    try testing.expectEqual(@as(usize, 0), vlist.visibleRange(lay.rows, 0, 100).len());
    try testing.expect(vlist.hitTest(lay.rows, 240, .{ .x = 1, .y = 1 }, .{}) == null);
    try testing.expectEqual(@as(?usize, null), vlist.moveFocus(lay.rows, null, .down, 100));
    try testing.expectEqual(vlist.Command.none, vlist.handleKey(lay.rows, null, .enter, false, 100));
}

// ─── Virtual list over synthetic geometry ───────────────────────────────

fn uniformRows(a: std.mem.Allocator, n: usize, h: f32) ![]layout.RowGeom {
    const rows = try a.alloc(layout.RowGeom, n);
    for (rows, 0..) |*g, i| g.* = .{ .top = @as(f32, @floatFromInt(i)) * h, .height = h, .kind = .workspace, .elements = &.{} };
    return rows;
}

test "unit: sidebar: visible range and row lookup are half-open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try uniformRows(arena.allocator(), 10, 30);
    try testing.expectEqual(vlist.Range{ .start = 0, .end = 4 }, vlist.visibleRange(rows, 0, 100));
    try testing.expectEqual(vlist.Range{ .start = 1, .end = 4 }, vlist.visibleRange(rows, 30, 90));
    try testing.expectEqual(vlist.Range{ .start = 0, .end = 2 }, vlist.visibleRange(rows, 29.5, 1));
    try testing.expectEqual(vlist.Range{ .start = 10, .end = 10 }, vlist.visibleRange(rows, 400, 100));
    try testing.expectEqual(@as(usize, 0), vlist.visibleRange(rows, 0, 0).len());
    try testing.expectEqual(vlist.Range{ .start = 0, .end = 2 }, vlist.visibleRange(rows, std.math.nan(f32), 40));
    try testing.expectEqual(@as(?usize, 0), vlist.rowAtY(rows, 0));
    try testing.expectEqual(@as(?usize, 1), vlist.rowAtY(rows, 30));
    try testing.expectEqual(@as(?usize, 0), vlist.rowAtY(rows, 29.999));
    try testing.expectEqual(@as(?usize, 9), vlist.rowAtY(rows, 299));
    try testing.expectEqual(@as(?usize, null), vlist.rowAtY(rows, 300));
    try testing.expectEqual(@as(?usize, null), vlist.rowAtY(rows, -0.1));
}

test "unit: sidebar: scroll clamps, keeps position on shrink, reveals rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try uniformRows(arena.allocator(), 40, 30);
    var s: vlist.Scroll = .{};
    s.resize(1200, 300);
    try testing.expect(s.scrollable());
    try testing.expect(s.scrollBy(100));
    try testing.expectEqual(@as(f32, 100), s.offset);
    // Closing a workspace below keeps the offset.
    s.resize(1170, 300);
    try testing.expectEqual(@as(f32, 100), s.offset);
    // Shrinking past the offset clamps to the new maximum.
    s.resize(350, 300);
    try testing.expectEqual(@as(f32, 50), s.offset);
    s.resize(200, 300);
    try testing.expectEqual(@as(f32, 0), s.offset);
    try testing.expect(!s.scrollable());
    try testing.expect(!s.scrollBy(std.math.nan(f32)));
    s.resize(std.math.inf(f32), -5);
    try testing.expectEqual(@as(f32, 0), s.content);

    s.resize(1200, 300);
    try testing.expect(s.ensureVisible(rows, 39));
    try testing.expectEqual(@as(f32, 900), s.offset);
    try testing.expect(!s.ensureVisible(rows, 35)); // already visible
    try testing.expect(s.ensureVisible(rows, 2));
    try testing.expectEqual(@as(f32, 60), s.offset);
    try testing.expect(!s.ensureVisible(rows, 99));
    try testing.expectEqual(@as(f32, 75), s.toContent(.{ .x = 0, .y = 15 }).y);
}

test "unit: sidebar: wheel deltas, page scroll and smooth steps" {
    try testing.expectEqual(@as(f32, -60), vlist.wheelOffsetDelta(120, 3, 20, 500));
    try testing.expectEqual(@as(f32, 120), vlist.wheelOffsetDelta(-240, 3, 20, 500));
    try testing.expectEqual(@as(f32, -15), vlist.wheelOffsetDelta(30, 3, 20, 500)); // hi-res
    try testing.expectEqual(@as(f32, -500), vlist.wheelOffsetDelta(120, vlist.wheel_page_scroll, 20, 500));
    try testing.expectEqual(@as(f32, 0), vlist.wheelOffsetDelta(120, 0, 20, 500));
    try testing.expectEqual(@as(f32, 0), vlist.wheelOffsetDelta(0, 3, 20, 500));

    const sm: vlist.SmoothScroll = .{ .target = 100 };
    var cur: f32 = 0;
    var steps: usize = 0;
    while (!sm.done(cur)) : (steps += 1) {
        const next = sm.step(cur, 16, 1.5);
        try testing.expect(next > cur and next <= 100);
        cur = next;
        try testing.expect(steps < 100);
    }
    try testing.expectEqual(@as(f32, 5), sm.step(5, 0, 1));
}

test "unit: sidebar: overlay thumb geometry and show-while-scrolling fade" {
    const track = geometry.Rect.xywh(236, 0, 4, 300);
    try testing.expect(vlist.thumbRect(track, .{ .content = 200, .viewport = 300 }, 20) == null);
    const top = vlist.thumbRect(track, .{ .offset = 0, .content = 1200, .viewport = 300 }, 20).?;
    try testing.expectApproxEqAbs(@as(f32, 75), top.height(), 1e-3);
    try testing.expectEqual(@as(f32, 0), top.top);
    const bottom = vlist.thumbRect(track, .{ .offset = 900, .content = 1200, .viewport = 300 }, 20).?;
    try testing.expectApproxEqAbs(@as(f32, 300), bottom.bottom, 1e-3);
    const tiny = vlist.thumbRect(track, .{ .offset = 0, .content = 1e7, .viewport = 300 }, 20).?;
    try testing.expectApproxEqAbs(@as(f32, 20), tiny.height(), 1e-3);

    var fade: vlist.IndicatorFade = .{};
    try testing.expectEqual(@as(f32, 0), fade.alpha(0));
    fade.poke(1000);
    try testing.expectEqual(@as(f32, 1), fade.alpha(1500));
    try testing.expectApproxEqAbs(@as(f32, 0.5), fade.alpha(1000 + 700 + 150), 1e-3);
    try testing.expectEqual(@as(f32, 0), fade.alpha(3000));
    try testing.expect(!fade.animating(3000));
    try testing.expectEqual(@as(f32, 1), fade.alpha(900)); // clock went backwards
}

test "unit: sidebar: keyboard focus mode moves, activates, renames and reorders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try uniformRows(arena.allocator(), 10, 30);
    rows[0].kind = .group_header;
    const vp: f32 = 90;
    try testing.expectEqual(vlist.Command{ .focus = 0 }, vlist.handleKey(rows, null, .down, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 9 }, vlist.handleKey(rows, null, .up, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 4 }, vlist.handleKey(rows, 3, .down, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 0 }, vlist.handleKey(rows, 0, .up, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 9 }, vlist.handleKey(rows, 9, .down, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 6 }, vlist.handleKey(rows, 3, .page_down, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 9 }, vlist.handleKey(rows, 8, .page_down, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 3 }, vlist.handleKey(rows, 6, .page_up, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 0 }, vlist.handleKey(rows, 1, .page_up, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 0 }, vlist.handleKey(rows, 5, .home, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 9 }, vlist.handleKey(rows, 5, .end, false, vp));
    try testing.expectEqual(vlist.Command{ .focus = 9 }, vlist.handleKey(rows, 42, .down, false, vp)); // stale focus
    try testing.expectEqual(vlist.Command{ .activate = 2 }, vlist.handleKey(rows, 2, .enter, false, vp));
    try testing.expectEqual(vlist.Command{ .rename = 2 }, vlist.handleKey(rows, 2, .f2, false, vp));
    try testing.expectEqual(vlist.Command.exit, vlist.handleKey(rows, 2, .escape, false, vp));
    try testing.expectEqual(vlist.Command.none, vlist.handleKey(rows, 2, .other, false, vp));
    try testing.expectEqual(vlist.Command.none, vlist.handleKey(rows, 42, .enter, false, vp));
    const up = vlist.handleKey(rows, 2, .up, true, vp);
    try testing.expect(up.reorder.index == 2 and up.reorder.up);
    try testing.expect(!vlist.handleKey(rows, 2, .down, true, vp).reorder.up);
    try testing.expectEqual(vlist.Command.none, vlist.handleKey(rows, 9, .down, true, vp));
    try testing.expectEqual(vlist.Command.none, vlist.handleKey(rows, 0, .down, true, vp)); // header
    try testing.expectEqual(vlist.Command.none, vlist.handleKey(rows, null, .up, true, vp));
}

test "unit: sidebar: selection lands on mouse-up and never after a drag" {
    var t: vlist.PressTracker = .{};
    t.press(2, .{ .x = 10, .y = 70 });
    try testing.expect(!t.move(.{ .x = 12, .y = 73 })); // within threshold
    try testing.expectEqual(vlist.PressTracker.Outcome{ .select = 2 }, t.release(2, null));
    try testing.expectEqual(vlist.PressTracker.Outcome.none, t.release(2, null)); // idle again

    t.press(2, .{ .x = 10, .y = 70 });
    try testing.expectEqual(vlist.PressTracker.Outcome.none, t.release(3, null)); // released elsewhere

    t.press(2, .{ .x = 10, .y = 70 });
    try testing.expect(t.move(.{ .x = 10, .y = 80 }));
    try testing.expect(t.dragging());
    try testing.expect(!t.move(.{ .x = 10, .y = 120 })); // already dragging
    const drop = t.release(4, 5);
    try testing.expect(drop.drop.row == 2 and drop.drop.to == 5);

    t.press(2, .{ .x = 10, .y = 70 });
    _ = t.move(.{ .x = 10, .y = 90 });
    try testing.expectEqual(vlist.PressTracker.Outcome.none, t.release(2, 3)); // same place
    t.press(2, .{ .x = 10, .y = 70 });
    _ = t.move(.{ .x = 10, .y = 90 });
    t.cancel(); // Esc
    try testing.expectEqual(vlist.PressTracker.Outcome.none, t.release(2, 0));
    t.press(null, .{});
    try testing.expectEqual(vlist.PressTracker.Outcome.none, t.release(null, null));
}

test "unit: sidebar: drop insertion line and edge auto-scroll" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try uniformRows(arena.allocator(), 4, 30);
    try testing.expectEqual(vlist.Insertion{ .index = 0, .line_y = 0 }, vlist.insertionAt(rows, -5));
    try testing.expectEqual(vlist.Insertion{ .index = 1, .line_y = 30 }, vlist.insertionAt(rows, 20));
    try testing.expectEqual(vlist.Insertion{ .index = 1, .line_y = 30 }, vlist.insertionAt(rows, 40));
    try testing.expectEqual(vlist.Insertion{ .index = 4, .line_y = 120 }, vlist.insertionAt(rows, 500));
    try testing.expectEqual(vlist.Insertion{ .index = 0, .line_y = 0 }, vlist.insertionAt(rows, std.math.nan(f32)));
    try testing.expectEqual(vlist.Insertion{ .index = 0, .line_y = 0 }, vlist.insertionAt(&.{}, 10));

    try testing.expectEqual(@as(f32, 0), vlist.autoScrollVelocity(150, 300, 24, 600));
    try testing.expectEqual(@as(f32, -600), vlist.autoScrollVelocity(-10, 300, 24, 600));
    try testing.expectApproxEqAbs(@as(f32, -300), vlist.autoScrollVelocity(12, 300, 24, 600), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300), vlist.autoScrollVelocity(288, 300, 24, 600), 1e-3);
    try testing.expectEqual(@as(f32, 0), vlist.autoScrollVelocity(5, 0, 24, 600));
}

test "unit: sidebar: ctrl and shift clicks build a multi-selection of workspaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try uniformRows(arena.allocator(), 6, 30);
    rows[3].kind = .group_header;
    var sel = [_]bool{false} ** 6;
    var anchor = vlist.applyClick(rows, &sel, null, 1, .{});
    try testing.expectEqualSlices(bool, &.{ false, true, false, false, false, false }, &sel);
    anchor = vlist.applyClick(rows, &sel, anchor, 4, .{ .shift = true });
    try testing.expectEqualSlices(bool, &.{ false, true, true, false, true, false }, &sel);
    try testing.expectEqual(@as(?usize, 1), anchor);
    anchor = vlist.applyClick(rows, &sel, anchor, 2, .{ .ctrl = true });
    try testing.expectEqualSlices(bool, &.{ false, true, false, false, true, false }, &sel);
    anchor = vlist.applyClick(rows, &sel, anchor, 3, .{}); // headers are not selectable
    try testing.expectEqual(@as(?usize, 2), anchor);
    anchor = vlist.applyClick(rows, &sel, anchor, 0, .{ .shift = true, .ctrl = true });
    try testing.expectEqualSlices(bool, &.{ true, true, true, false, true, false }, &sel);
    _ = vlist.applyClick(rows, &sel, anchor, 5, .{});
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true }, &sel);
}

test "unit: sidebar: wmux_proto uuid ids round-trip through row identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const id = try proto.uuid.Uuid.parse("3F2504E0-4F89-41D3-9A0C-0305E82C3301");
    const nodes = [_]model.Node{.{ .workspace = .{ .id = id } }};
    const rows = try model.build(arena.allocator(), .{ .nodes = &nodes });
    try testing.expect(id.eql(rows[0].id()));
    try testing.expectEqual(model.RowKind.workspace, rows[0].kind());
}
