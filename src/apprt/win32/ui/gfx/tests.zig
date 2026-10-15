//! Tests for the gfx layer and the Direct2D / DirectWrite / WIC bindings
//! (W1-8a).
//!
//! Exact commands (repository root, PowerShell, Zig 0.15.2):
//!
//!   $Z = 'C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe'
//!   # pure logic only ("unit: gfx: ..."), std-only, no Windows APIs:
//!   & $Z test src/apprt/win32/ui/gfx/logic/tests.zig
//!   # everything: logic + binding layout pins + headless D2D/DWrite/WIC:
//!   & $Z build --build-file src/apprt/win32/ui/gfx/test_build.zig --cache-dir .zig-cache test
//!   #   select tests with "-Dtest-filter=<text>" (repeatable)
//!
//! Running `zig test` on this file directly cannot resolve
//! `../../platform/*.zig` (a module may not import outside its root file's
//! directory). `test_build.zig` therefore copies `ui/gfx/**` and the four
//! binding files into a generated tree with a root above both and links
//! -lc -ld2d1 -ldwrite -lwindowscodecs -lole32 -luser32 -lgdi32. W1-8
//! replaces it by importing this file from the app's test root.
//!
//! Headless tests ("gfx: headless: ...") draw into WIC bitmaps and a GDI DIB
//! section. The HWND test creates a popup that is never shown
//! (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW at -32000,-32000): nothing appears on
//! screen and focus is never taken.
const std = @import("std");
const testing = std.testing;
const gfx = @import("gfx.zig");
const com = gfx.com;
const d2d = gfx.d2d;
const dwrite = gfx.dwrite;
const wic = gfx.wic;

const Rect = gfx.Rect;
const Point = gfx.Point;
const Color = gfx.Color;
const TextStyle = gfx.TextStyle;
const W = std.unicode.utf8ToUtf16LeStringLiteral;

test {
    _ = @import("logic/tests.zig");
    _ = com;
    _ = d2d;
    _ = dwrite;
    _ = wic;
}

// ─── Compile-time and layout pins (no Windows calls) ────────────────────

test "unit: gfx: every gfx declaration type-checks" {
    std.testing.refAllDeclsRecursive(gfx);
}

test "unit: gfx: device-state HRESULTs match platform/com.zig" {
    const ds = gfx.device_state;
    try testing.expectEqual(com.D2DERR_RECREATE_TARGET, ds.D2DERR_RECREATE_TARGET);
    try testing.expectEqual(com.D2DERR_DISPLAY_STATE_INVALID, ds.D2DERR_DISPLAY_STATE_INVALID);
    try testing.expectEqual(com.D2DERR_NO_HARDWARE_DEVICE, ds.D2DERR_NO_HARDWARE_DEVICE);
    try testing.expectEqual(com.DXGI_ERROR_DEVICE_REMOVED, ds.DXGI_ERROR_DEVICE_REMOVED);
    try testing.expectEqual(com.DXGI_ERROR_DEVICE_HUNG, ds.DXGI_ERROR_DEVICE_HUNG);
    try testing.expectEqual(com.DXGI_ERROR_DEVICE_RESET, ds.DXGI_ERROR_DEVICE_RESET);
}

fn expectSameLayout(comptime A: type, comptime B: type, comptime names: []const [2][]const u8) !void {
    try testing.expectEqual(@sizeOf(B), @sizeOf(A));
    inline for (names) |n| try testing.expectEqual(@offsetOf(B, n[1]), @offsetOf(A, n[0]));
}

test "unit: gfx: logic types are layout-compatible with Direct2D and DirectWrite" {
    try expectSameLayout(gfx.Rect, d2d.D2D1_RECT_F, &.{ .{ "left", "left" }, .{ "top", "top" }, .{ "right", "right" }, .{ "bottom", "bottom" } });
    try expectSameLayout(gfx.Point, d2d.D2D1_POINT_2F, &.{ .{ "x", "x" }, .{ "y", "y" } });
    try expectSameLayout(gfx.Color, d2d.D2D1_COLOR_F, &.{ .{ "r", "r" }, .{ "g", "g" }, .{ "b", "b" }, .{ "a", "a" } });
    try expectSameLayout(gfx.PixelRect, com.RECT, &.{ .{ "left", "left" }, .{ "top", "top" }, .{ "right", "right" }, .{ "bottom", "bottom" } });

    const ts = gfx.text_style;
    inline for (@typeInfo(ts.FontWeight).@"enum".fields) |f|
        try testing.expectEqual(f.value, @intFromEnum(@field(dwrite.DWRITE_FONT_WEIGHT, f.name)));
    inline for (@typeInfo(ts.FontSlant).@"enum".fields) |f|
        try testing.expectEqual(f.value, @intFromEnum(@field(dwrite.DWRITE_FONT_STYLE, f.name)));
    inline for (@typeInfo(ts.FontStretch).@"enum".fields) |f|
        try testing.expectEqual(f.value, @intFromEnum(@field(dwrite.DWRITE_FONT_STRETCH, f.name)));
    inline for (@typeInfo(ts.HAlign).@"enum".fields) |f|
        try testing.expectEqual(f.value, @intFromEnum(@field(dwrite.DWRITE_TEXT_ALIGNMENT, f.name)));
    try testing.expectEqual(@intFromEnum(dwrite.DWRITE_PARAGRAPH_ALIGNMENT.near), @intFromEnum(ts.VAlign.top));
    try testing.expectEqual(@intFromEnum(dwrite.DWRITE_PARAGRAPH_ALIGNMENT.far), @intFromEnum(ts.VAlign.bottom));
    try testing.expectEqual(@intFromEnum(dwrite.DWRITE_PARAGRAPH_ALIGNMENT.center), @intFromEnum(ts.VAlign.center));
}

// ─── Headless fixtures ──────────────────────────────────────────────────

/// COM + a gfx context at a stable address (canvases and measurers keep
/// pointers into the context).
const Fixture = struct {
    com_scope: com.InitScope,
    ctx: gfx.Context,

    fn init(opts: gfx.context.Options) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(f);
        f.com_scope = try com.initThread(.single_threaded);
        errdefer f.com_scope.deinit();
        f.ctx = try gfx.Context.init(testing.allocator, opts);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.ctx.deinit();
        f.com_scope.deinit();
        testing.allocator.destroy(f);
    }
};

/// Premultiplied BGRA pixels, top-down.
const Pixels = struct {
    data: []const u8,
    width: usize,

    fn at(self: Pixels, x: usize, y: usize) [4]u8 {
        const i = (y * self.width + x) * 4;
        return self.data[i..][0..4].*;
    }

    fn brightIn(self: Pixels, r: Rect, min_luma: u32) usize {
        var n: usize = 0;
        var y: usize = @intFromFloat(r.top);
        while (y < @as(usize, @intFromFloat(r.bottom))) : (y += 1) {
            var x: usize = @intFromFloat(r.left);
            while (x < @as(usize, @intFromFloat(r.right))) : (x += 1) {
                const p = self.at(x, y);
                const luma = (@as(u32, p[2]) * 299 + @as(u32, p[1]) * 587 + @as(u32, p[0]) * 114) / 1000;
                if (luma >= min_luma) n += 1;
            }
        }
        return n;
    }

    fn distinctColors(self: Pixels) !usize {
        var seen = std.AutoHashMap(u32, void).init(testing.allocator);
        defer seen.deinit();
        var i: usize = 0;
        while (i + 4 <= self.data.len) : (i += 4) try seen.put(std.mem.readInt(u32, self.data[i..][0..4], .little), {});
        return seen.count();
    }
};

/// Expected PBGRA bytes of an opaque or translucent color.
fn bgra(c: Color) [4]u8 {
    const v = c.premultiplied().toRgba8();
    return .{ v[2], v[1], v[0], v[3] };
}

fn expectQi(comptime T: type, obj: anytype) !void {
    const p = com.queryInterface(T, obj) catch |err| {
        std.log.scoped(.gfx).warn("QueryInterface({s}) failed: {s} hr=0x{x}", .{ @typeName(T), @errorName(err), @as(u32, @bitCast(com.last_failure)) });
        return err;
    };
    com.release(p);
}

// ─── Headless rendering ─────────────────────────────────────────────────

test "gfx: headless: WIC bitmap target renders shapes and text (pixels are not uniform)" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    var target = try gfx.BitmapTarget.init(&fx.ctx, 320, 120, 96, .dip);
    defer target.deinit();

    const bg = Color.hex(0x1E1E1E);
    const accent = Color.hex(0x3D8EF8);
    const track = Color.hex(0x3A3A3A);
    const fill = Color.hex(0x4EC9B0);
    const rule = Color.hex(0x808080);

    var canvas = try target.begin();
    canvas.clear(bg);
    canvas.fillRoundedRect(Rect.xywh(10, 10, 100, 40), 8, accent);
    const pl = canvas.pill("main", .{ .x = 120, .y = 14 }, 120, .{
        .background = Color.hex(0x2D5A27),
        .foreground = Color.white,
        .metrics = .{ .icon = 12 },
        .icon = 0xE8A7,
    });
    canvas.progressBar(Rect.xywh(10, 60, 200, 6), 0.6, track, fill);
    const title: TextStyle = .{ .size = 16, .weight = .semi_bold };
    canvas.text("wmux sidebar Ag", Rect.xywh(10, 74, 230, 30), &title, Color.white);
    canvas.hline(0, 320, 110, rule);
    canvas.spinner(.{ .x = 290, .y = 30 }, 10, 3, 0.25, Color.white);
    canvas.icon(0xE713, Rect.xywh(250, 62, 30, 30), 16, Color.white);
    const badge_style: TextStyle = .{ .size = 10, .weight = .bold };
    const badge = canvas.badge("7", 316, 96, 14, &badge_style, Color.hex(0xE84141), Color.white);
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));

    const data = try target.readPixelsAlloc(testing.allocator);
    defer testing.allocator.free(data);
    const px: Pixels = .{ .data = data, .width = 320 };

    // Not uniform: anti-aliased shapes and text produce many colors.
    try testing.expect(try px.distinctColors() > 32);
    // Solid interior and untouched background are exact.
    try testing.expectEqual(bgra(accent), px.at(60, 30));
    try testing.expectEqual(bgra(bg), px.at(315, 5));
    // Rounded corner: the corner pixel is not the fill color.
    try testing.expect(!std.mem.eql(u8, &bgra(accent), &px.at(10, 10)));
    // Progress: filled part, then the rest of the track.
    try testing.expectEqual(bgra(fill), px.at(100, 63));
    try testing.expectEqual(bgra(track), px.at(200, 63));
    // Crisp hairline: exactly device row 110.
    try testing.expectEqual(bgra(rule), px.at(160, 110));
    try testing.expectEqual(bgra(bg), px.at(160, 109));
    try testing.expectEqual(bgra(bg), px.at(160, 111));
    // Text, icon glyph, spinner and pill label put light pixels in their boxes.
    try testing.expect(px.brightIn(Rect.xywh(10, 74, 230, 30), 160) > 40);
    try testing.expect(px.brightIn(Rect.xywh(250, 62, 30, 30), 160) > 5);
    try testing.expect(px.brightIn(Rect.xywh(278, 18, 24, 24), 160) > 5);
    try testing.expect(px.brightIn(pl.text, 160) > 3);
    try testing.expect(pl.icon != null and !pl.truncated);
    try testing.expect(badge.width() >= 14 and badge.right == 316);
}

test "gfx: headless: DIP drawing lands on device pixels at 150%" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    var target = try gfx.BitmapTarget.init(&fx.ctx, 90, 60, 144, .dip);
    defer target.deinit();

    var canvas = try target.begin();
    try testing.expectEqual(@as(f32, 1.5), canvas.scale);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.5), canvas.hairline(), 1e-6);
    canvas.clear(Color.black);
    canvas.fillRect(Rect.xywh(10, 10, 20, 20), Color.white); // device pixels 15..45
    canvas.hline(0, 60, 30, Color.hex(0xFF0000)); // device row 45
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));

    const data = try target.readPixelsAlloc(testing.allocator);
    defer testing.allocator.free(data);
    const px: Pixels = .{ .data = data, .width = 90 };
    try testing.expectEqual(bgra(Color.white), px.at(15, 15));
    try testing.expectEqual(bgra(Color.white), px.at(44, 44));
    try testing.expectEqual(bgra(Color.black), px.at(14, 14));
    try testing.expectEqual(bgra(Color.black), px.at(46, 46));
    try testing.expectEqual(bgra(Color.hex(0xFF0000)), px.at(70, 45));
    try testing.expectEqual(bgra(Color.black), px.at(70, 44));
    try testing.expectEqual(bgra(Color.black), px.at(70, 46));
}

test "gfx: headless: clipping, opacity layers and indeterminate progress" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    var target = try gfx.BitmapTarget.init(&fx.ctx, 100, 60, 96, .dip);
    defer target.deinit();

    var canvas = try target.begin();
    canvas.clear(Color.black);
    // Axis-aligned clip: only the left half of the fill survives.
    canvas.pushClip(Rect.xywh(0, 0, 50, 20));
    canvas.fillRect(Rect.xywh(0, 0, 100, 20), Color.white);
    canvas.popClip();
    // Rounded clip: the corner stays black.
    try canvas.pushRoundedClip(Rect.xywh(0, 30, 40, 30), 12);
    canvas.fillRect(Rect.xywh(0, 30, 40, 30), Color.white);
    canvas.popLayer();
    // 50% opacity layer over black.
    try canvas.pushOpacity(0.5);
    canvas.fillRect(Rect.xywh(60, 30, 20, 20), Color.white);
    canvas.popLayer();
    canvas.indeterminateBar(Rect.xywh(50, 0, 50, 6), 0.5, Color.hex(0x333333), Color.hex(0x00FF00));
    try testing.expectEqual(@as(u16, 0), canvas.clip_depth);
    try testing.expectEqual(@as(u16, 0), canvas.layer_depth);
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));

    const data = try target.readPixelsAlloc(testing.allocator);
    defer testing.allocator.free(data);
    const px: Pixels = .{ .data = data, .width = 100 };
    try testing.expectEqual(bgra(Color.white), px.at(25, 10));
    try testing.expectEqual(bgra(Color.black), px.at(75, 10));
    try testing.expectEqual(bgra(Color.white), px.at(20, 45));
    try testing.expectEqual(bgra(Color.black), px.at(0, 30));
    const half = px.at(70, 40);
    try testing.expect(half[0] > 100 and half[0] < 156);
    // The sliding segment is in the middle of the track at phase 0.5.
    try testing.expectEqual(bgra(Color.hex(0x00FF00)), px.at(75, 3));
}

test "gfx: headless: interleaved clips and layers left open are popped in order" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    var target = try gfx.BitmapTarget.init(&fx.ctx, 20, 20, 96, .dip);
    defer target.deinit();

    var canvas = try target.begin();
    canvas.clear(Color.black);
    canvas.pushClip(Rect.xywh(0, 0, 20, 20));
    try canvas.pushOpacity(1);
    canvas.pushClip(Rect.xywh(0, 0, 10, 10));
    canvas.fillRect(Rect.xywh(0, 0, 20, 20), Color.white);
    try testing.expectEqual(@as(u8, 3), canvas.push_depth);
    // Left open on purpose: finish() must pop clip, layer, clip (in that
    // order) or EndDraw fails with D2DERR_POP_CALL_DID_NOT_MATCH_PUSH.
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));
    try testing.expectEqual(@as(u8, 0), canvas.push_depth);

    var pixels: [20 * 20 * 4]u8 = undefined;
    try target.copyPixels(&pixels);
    const px: Pixels = .{ .data = &pixels, .width = 20 };
    try testing.expectEqual(bgra(Color.white), px.at(5, 5));
    try testing.expectEqual(bgra(Color.black), px.at(15, 15));
}

test "gfx: headless: Direct2D 1.0 fallback draws layers and text" {
    const fx = try Fixture.init(.{ .force_d2d_1_0 = true });
    defer fx.deinit();
    try testing.expect(!fx.ctx.d2d_1_1);
    var target = try gfx.BitmapTarget.init(&fx.ctx, 120, 40, 96, .dip);
    defer target.deinit();

    var canvas = try target.begin();
    try testing.expect(!canvas.text_options.enable_color_font);
    canvas.clear(Color.black);
    try canvas.pushRoundedClip(Rect.xywh(0, 0, 40, 40), 20);
    canvas.fillRect(Rect.xywh(0, 0, 40, 40), Color.white);
    canvas.popLayer();
    const style: TextStyle = .{ .size = 14 };
    canvas.text("D2D 1.0", Rect.xywh(45, 5, 75, 30), &style, Color.white);
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));
    // Direct2D 1.0 needs explicit layer objects; one was created.
    try testing.expect(target.res.layers[0] != null);

    const data = try target.readPixelsAlloc(testing.allocator);
    defer testing.allocator.free(data);
    const px: Pixels = .{ .data = data, .width = 120 };
    try testing.expectEqual(bgra(Color.white), px.at(20, 20));
    try testing.expectEqual(bgra(Color.black), px.at(1, 1));
    try testing.expect(px.brightIn(Rect.xywh(45, 5, 75, 30), 160) > 10);
}

test "gfx: headless: color emoji render in color on Direct2D 1.1" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    if (!fx.ctx.d2d_1_1 or !fx.ctx.text.hasFamily("Segoe UI Emoji")) return error.SkipZigTest;
    var target = try gfx.BitmapTarget.init(&fx.ctx, 64, 64, 96, .dip);
    defer target.deinit();

    var canvas = try target.begin();
    try testing.expect(canvas.text_options.enable_color_font);
    canvas.clear(Color.black);
    const style: TextStyle = .{ .size = 40, .trim = .none };
    canvas.text("\u{1F600}", Rect.xywh(2, 2, 60, 60), &style, Color.white);
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));

    const data = try target.readPixelsAlloc(testing.allocator);
    defer testing.allocator.free(data);
    var chroma: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        const mx = @max(data[i], @max(data[i + 1], data[i + 2]));
        const mn = @min(data[i], @min(data[i + 1], data[i + 2]));
        if (mx - mn > 60) chroma += 1;
    }
    try testing.expect(chroma > 50);
}

test "gfx: headless: discarding the target recreates device resources" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    var target = try gfx.BitmapTarget.init(&fx.ctx, 8, 8, 96, .dip);
    defer target.deinit();

    var c1 = try target.begin();
    c1.clear(Color.hex(0xFF0000));
    try testing.expectEqual(gfx.EndResult.presented, target.end(&c1));
    try testing.expect(target.res.brush != null);

    // Same path as D2DERR_RECREATE_TARGET: target and resources released.
    target.discard();
    try testing.expectEqual(@as(u32, 1), target.generation);
    try testing.expect(target.rt == null and target.res.brush == null);

    var c2 = try target.begin();
    c2.clear(Color.black);
    c2.fillRect(Rect.xywh(0, 0, 8, 8), Color.hex(0x0000FF));
    try testing.expectEqual(gfx.EndResult.presented, target.end(&c2));
    try testing.expect(target.rt != null and target.res.brush != null);

    var pixels: [8 * 8 * 4]u8 = undefined;
    try target.copyPixels(&pixels);
    try testing.expectEqual(bgra(Color.hex(0x0000FF)), (Pixels{ .data = &pixels, .width = 8 }).at(4, 4));
    try testing.expectError(error.BufferTooSmall, target.copyPixels(pixels[0..10]));
}

test "gfx: headless: PNG encoding round-trips through the WIC decoder and a file" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    var target = try gfx.BitmapTarget.init(&fx.ctx, 40, 20, 96, .dip);
    defer target.deinit();
    var canvas = try target.begin();
    canvas.clear(Color.hex(0x112233));
    canvas.fillRect(Rect.xywh(0, 0, 20, 20), Color.white.withAlpha(0.5));
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));

    const png = try target.encodePngAlloc(testing.allocator);
    defer testing.allocator.free(png);
    try testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));

    // Decode it back.
    const wf = try fx.ctx.wicFactory();
    const stream = try com.createMemoryStream();
    defer stream.release();
    try stream.writeAll(png);
    _ = try stream.seek(0, com.STREAM_SEEK_SET);
    const decoder = try wf.createDecoderFromStream(stream);
    defer decoder.release();
    try testing.expectEqual(@as(u32, 1), try decoder.getFrameCount());
    const frame = try decoder.getFrame(0);
    defer frame.release();
    const size = try frame.source().getSize();
    try testing.expectEqual(@as(u32, 40), size.width);
    try testing.expectEqual(@as(u32, 20), size.height);

    // Save to a file (in a temp dir that the test removes).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "shot.png" });
    defer testing.allocator.free(file_path);
    try target.savePng(testing.allocator, file_path);
    const stat = try tmp.dir.statFile("shot.png");
    try testing.expect(stat.size > 8);
}

// ─── Text ───────────────────────────────────────────────────────────────

test "gfx: headless: text measurement, trimming, line limits and caching" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const text = &fx.ctx.text;

    const single: TextStyle = .{ .size = 13 };
    const hello = text.measure("Hello", &single, gfx.text.unbounded);
    try testing.expect(hello.width > 10 and hello.width < 60);
    try testing.expect(hello.height > 10 and hello.height < 30);
    try testing.expect(hello.baseline > 0 and hello.baseline < hello.height);
    try testing.expectEqual(@as(u32, 1), hello.line_count);
    try testing.expect(!hello.truncated);
    try testing.expect(text.measure("Hello, world", &single, gfx.text.unbounded).width > hello.width);

    // Trimmed with an ellipsis inside the box.
    const sentence = "The quick brown fox jumps over the lazy dog";
    const trimmed = text.measure(sentence, &single, 80);
    try testing.expect(trimmed.truncated);
    try testing.expect(trimmed.width <= 80.5);
    // Without trimming the text overflows (still reported as truncated).
    var no_trim = single;
    no_trim.trim = .none;
    const overflow = text.measure(sentence, &no_trim, 80);
    try testing.expect(overflow.truncated and overflow.width > 80);

    // Two-line limit.
    var wrap: TextStyle = .{ .size = 13, .wrap = .word, .max_lines = 2 };
    const greek = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma";
    const two = text.measure(greek, &wrap, 120);
    try testing.expectEqual(@as(u32, 2), two.line_count);
    try testing.expect(two.truncated);
    try testing.expectApproxEqAbs(hello.height * 2, two.height, 1.5);
    // Without trimming the lines past the limit overflow the box (drawing
    // clips them) and still do not count, as with the fake measurer.
    var two_clip = wrap;
    two_clip.trim = .none;
    const clip2 = text.measure(greek, &two_clip, 120);
    try testing.expectEqual(@as(u32, 2), clip2.line_count);
    try testing.expect(clip2.truncated);
    try testing.expectApproxEqAbs(two.height, clip2.height, 0.5);
    const fake: gfx.FakeMeasurer = .{};
    try testing.expectEqual(clip2.line_count, fake.measure(greek, &two_clip, 120).line_count);
    // The limit also caps explicit line breaks of single-line text.
    const first_only: TextStyle = .{ .size = 13, .max_lines = 1 };
    const first = text.measure("first\nsecond\nthird", &first_only, 200);
    try testing.expectEqual(@as(u32, 1), first.line_count);
    try testing.expect(first.truncated);
    try testing.expectApproxEqAbs(hello.height, first.height, 1.5);
    wrap.max_lines = 0;
    const all = text.measure(greek, &wrap, 120);
    try testing.expect(all.line_count > 2 and !all.truncated);
    // A box one line tall keeps one visible line, trimmed or clipped.
    const boxed = try text.layout(greek, &wrap, 120, hello.height + 1);
    defer boxed.deinit();
    const boxed_ext = try boxed.extent();
    try testing.expectEqual(@as(u32, 1), boxed_ext.line_count);
    try testing.expect(boxed_ext.truncated);
    var clip_wrap = wrap;
    clip_wrap.trim = .none;
    const clipped = try text.layout(greek, &clip_wrap, 120, hello.height + 1);
    defer clipped.deinit();
    const clipped_ext = try clipped.extent();
    try testing.expectEqual(@as(u32, 1), clipped_ext.line_count);
    try testing.expect(clipped_ext.truncated);
    try testing.expectApproxEqAbs(hello.height, clipped_ext.height, 1.5);

    // No room at all truncates (the fake measurer agrees).
    try testing.expect(text.measure("Hello", &single, 0).truncated);
    try testing.expect(text.measure("Hello", &single, std.math.nan(f32)).truncated);

    // The measurer interface agrees with direct measurement.
    const via = text.measurer().measure("Hello", &single, gfx.text.unbounded);
    try testing.expectEqual(hello.width, via.width);

    // Measuring the same text again hits the layout cache.
    const hits = text.layouts.hits;
    _ = text.measure("Hello", &single, gfx.text.unbounded);
    try testing.expect(text.layouts.hits > hits);

    // Bad input never fails.
    try testing.expect(text.measure("a\xffb", &single, gfx.text.unbounded).width > 0);
    var zero = single;
    zero.size = 0;
    _ = text.measure("x", &zero, 100);
    try testing.expectError(error.InvalidArg, text.layout("x", &zero, 100, 100));
    // A non-finite line height is ignored instead of producing NaN extents.
    var bad_lh = single;
    bad_lh.line_height = std.math.inf(f32);
    try testing.expectApproxEqAbs(hello.height, text.measure("Hello", &bad_lh, gfx.text.unbounded).height, 0.01);
}

test "gfx: headless: text hit testing, carets and range rectangles" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const style: TextStyle = .{ .size = 14 };
    const l = try fx.ctx.text.layout("abcdef", &style, gfx.text.unbounded, gfx.text.unbounded);
    defer l.deinit();
    const ext = try l.extent();

    const first = try l.hitTest(.{ .x = 0.5, .y = 2 });
    try testing.expectEqual(@as(u32, 0), first.position);
    try testing.expect(first.inside and !first.trailing);
    const past = try l.hitTest(.{ .x = ext.width + 50, .y = 2 });
    try testing.expectEqual(@as(u32, 5), past.position);
    try testing.expect(!past.inside and past.trailing);

    try testing.expect((try l.caretPoint(3, false)).x > (try l.caretPoint(1, false)).x);
    var rects: [4]Rect = undefined;
    const r = try l.rangeRects(1, 3, .{ .x = 10, .y = 20 }, &rects);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expect(r[0].width() > 0 and r[0].left >= 10 and r[0].top >= 20);

    // UTF-8 byte offsets map to DirectWrite's UTF-16 positions.
    const s = "a\u{1F600}b";
    const e = try fx.ctx.text.layout(s, &style, gfx.text.unbounded, gfx.text.unbounded);
    defer e.deinit();
    const b_pos = gfx.utf16.utf16Offset(s, std.mem.indexOfScalar(u8, s, 'b').?);
    try testing.expectEqual(@as(usize, 3), b_pos);
    try testing.expect((try e.caretPoint(@intCast(b_pos), false)).x > (try e.caretPoint(1, false)).x);
}

test "gfx: headless: path trimming keeps the file name; decorations apply" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const path = "C:\\Users\\someone\\projects\\wmux\\src\\apprt\\main.zig";

    var keep_tail: TextStyle = .{ .size = 13, .trim_delimiter = '\\' };
    const tail = try fx.ctx.text.layout(path, &keep_tail, 150, gfx.text.unbounded);
    defer tail.deinit();
    const tail_ext = try tail.extent();
    try testing.expect(tail_ext.truncated and tail_ext.width <= 150.5);
    // The right end shows the file name.
    const end_hit = try tail.hitTest(.{ .x = tail_ext.width - 2, .y = 4 });
    try testing.expect(end_hit.position >= path.len - "main.zig".len);

    // Plain end trimming hides it instead.
    const plain_style: TextStyle = .{ .size = 13 };
    const plain = try fx.ctx.text.layout(path, &plain_style, 150, gfx.text.unbounded);
    defer plain.deinit();
    const plain_ext = try plain.extent();
    const plain_hit = try plain.hitTest(.{ .x = plain_ext.width - 2, .y = 4 });
    try testing.expect(plain_hit.position < path.len - "main.zig".len);

    var link: TextStyle = .{ .size = 13, .underline = true };
    const linked = try fx.ctx.text.layout("https://example.com", &link, gfx.text.unbounded, gfx.text.unbounded);
    defer linked.deinit();
    try testing.expect(try linked.raw.getUnderlineAt(0));
    try testing.expect(!try plain.raw.getUnderlineAt(0));
    link.underline = false;
    link.strikethrough = true;
    const done = try fx.ctx.text.layout("done item", &link, gfx.text.unbounded, gfx.text.unbounded);
    defer done.deinit();
    var strike: com.BOOL = com.FALSE;
    try com.check(done.raw.vtable.GetStrikethrough(done.raw, 0, &strike, null));
    try testing.expect(strike != com.FALSE);
}

test "gfx: headless: font family fallback lists resolve to installed families" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const text = &fx.ctx.text;
    try testing.expect(text.hasFamily("Segoe UI"));
    try testing.expect(!text.hasFamily("No Such Font 12345"));
    try testing.expectEqualSlices(u16, W("Segoe UI"), try text.resolveFamily("No Such Font 12345, Segoe UI"));
    try testing.expectEqualSlices(u16, W("No Such Font B"), try text.resolveFamily("No Such Font A, No Such Font B"));
    const icons = try text.resolveFamily(gfx.text_style.icon_family);
    try testing.expect(std.mem.eql(u16, icons, W("Segoe Fluent Icons")) or std.mem.eql(u16, icons, W("Segoe MDL2 Assets")));
    // Cached: the same slice comes back.
    try testing.expectEqual((try text.resolveFamily("No Such Font 12345, Segoe UI")).ptr, (try text.resolveFamily("No Such Font 12345, Segoe UI")).ptr);
    // Format cache: one format per font identity.
    const a: TextStyle = .{ .size = 12 };
    var b = a;
    b.h_align = .center;
    try testing.expectEqual(try text.format(&a), try text.format(&b));
    text.clearCaches();
    try testing.expectEqual(@as(usize, 0), text.layouts.count());
}

test "gfx: headless: DirectWrite fonts, faces and localized names" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const fonts = fx.ctx.text.fonts;
    const index = (try fonts.findFamilyName(W("Segoe UI"))).?;
    const family = try fonts.getFontFamily(index);
    defer family.release();
    try testing.expect(family.fontList().getFontCount() > 0);
    const names = try family.getFamilyNames();
    defer names.release();
    var buf: [64]u16 = undefined;
    const en = (try names.findLocaleName(W("en-us"))) orelse 0;
    try testing.expectEqualSlices(u16, W("Segoe UI"), try names.getString(en, &buf));
    const font = try family.getFirstMatchingFont(.bold, .normal, .normal);
    defer font.release();
    try testing.expectEqual(dwrite.DWRITE_FONT_WEIGHT.bold, font.getWeight());
    try testing.expect(try font.hasCharacter('A'));
    try testing.expect(!try font.hasCharacter(0xE713)); // icon glyphs live in the icon font
    try testing.expect(font.getMetrics().designUnitsPerEm > 0);
    const face = try font.createFontFace();
    defer face.release();
    var glyphs: [2]u16 = undefined;
    try face.getGlyphIndices(&.{ 'A', 0x10FFFF }, &glyphs);
    try testing.expect(glyphs[0] != 0);
    try testing.expectEqual(@as(u16, 0), glyphs[1]);
    try testing.expect(face.getGlyphCount() > 100);
}

// ─── Platform targets ───────────────────────────────────────────────────

const win = struct {
    const HINSTANCE = *opaque {};
    const WNDPROC = *const fn (com.HWND, u32, usize, isize) callconv(.winapi) isize;

    const WNDCLASSEXW = extern struct {
        cbSize: u32 = @sizeOf(WNDCLASSEXW),
        style: u32 = 0,
        lpfnWndProc: WNDPROC,
        cbClsExtra: i32 = 0,
        cbWndExtra: i32 = 0,
        hInstance: ?HINSTANCE = null,
        hIcon: ?*anyopaque = null,
        hCursor: ?*anyopaque = null,
        hbrBackground: ?*anyopaque = null,
        lpszMenuName: ?[*:0]const u16 = null,
        lpszClassName: [*:0]const u16,
        hIconSm: ?*anyopaque = null,
    };

    const BITMAPINFOHEADER = extern struct {
        biSize: u32 = @sizeOf(BITMAPINFOHEADER),
        biWidth: i32,
        biHeight: i32,
        biPlanes: u16 = 1,
        biBitCount: u16 = 32,
        biCompression: u32 = 0, // BI_RGB
        biSizeImage: u32 = 0,
        biXPelsPerMeter: i32 = 0,
        biYPelsPerMeter: i32 = 0,
        biClrUsed: u32 = 0,
        biClrImportant: u32 = 0,
    };

    const BITMAPINFO = extern struct {
        bmiHeader: BITMAPINFOHEADER,
        bmiColors: [1]u32 = .{0},
    };

    const WS_POPUP: u32 = 0x80000000;
    const WS_EX_TOOLWINDOW: u32 = 0x00000080;
    const WS_EX_NOACTIVATE: u32 = 0x08000000;

    extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn UnregisterClassW([*:0]const u16, ?HINSTANCE) callconv(.winapi) com.BOOL;
    extern "user32" fn CreateWindowExW(u32, [*:0]const u16, ?[*:0]const u16, u32, i32, i32, i32, i32, ?com.HWND, ?*anyopaque, ?HINSTANCE, ?*anyopaque) callconv(.winapi) ?com.HWND;
    extern "user32" fn DestroyWindow(com.HWND) callconv(.winapi) com.BOOL;
    extern "user32" fn DefWindowProcW(com.HWND, u32, usize, isize) callconv(.winapi) isize;
    extern "user32" fn IsWindowVisible(com.HWND) callconv(.winapi) com.BOOL;
    extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
    extern "gdi32" fn CreateCompatibleDC(?com.HDC) callconv(.winapi) ?com.HDC;
    extern "gdi32" fn CreateDIBSection(?com.HDC, *const BITMAPINFO, u32, *?[*]u8, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn SelectObject(com.HDC, *anyopaque) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) com.BOOL;
    extern "gdi32" fn DeleteDC(com.HDC) callconv(.winapi) com.BOOL;
    extern "gdi32" fn GdiFlush() callconv(.winapi) com.BOOL;

    fn wndProc(hwnd: com.HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
};

test "gfx: headless: DC render target draws into a GDI DIB section" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();

    const dc = win.CreateCompatibleDC(null) orelse return error.SkipZigTest;
    defer _ = win.DeleteDC(dc);
    var bits: ?[*]u8 = null;
    const bmi: win.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = 64, .biHeight = -32 } }; // top-down
    const dib = win.CreateDIBSection(dc, &bmi, 0, &bits, null, 0) orelse return error.SkipZigTest;
    defer _ = win.DeleteObject(dib);
    const old = win.SelectObject(dc, dib);
    defer if (old) |o| {
        _ = win.SelectObject(dc, o);
    };

    var target = gfx.DcTarget.init(&fx.ctx, 96, .ignore, .{ .force_software = true });
    defer target.deinit();
    var canvas = (try target.begin(@ptrCast(dc), .{ .left = 0, .top = 0, .right = 64, .bottom = 32 })).?;
    canvas.clear(Color.hex(0x204080));
    canvas.fillRect(Rect.xywh(32, 0, 32, 32), Color.hex(0xFFCC00));
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));
    _ = win.GdiFlush();

    const px: Pixels = .{ .data = bits.?[0 .. 64 * 32 * 4], .width = 64 };
    // GDI DIB pixels are BGRx; compare color channels only.
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x40, 0x20 }, px.at(10, 10)[0..3]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xCC, 0xFF }, px.at(40, 10)[0..3]);
    // Empty rectangles draw nothing.
    try testing.expect((try target.begin(@ptrCast(dc), .{})) == null);
}

test "gfx: headless: HWND render target on a never-shown window" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();

    const hinst = win.GetModuleHandleW(null);
    const class = W("WmuxGfxTestHidden");
    const wc: win.WNDCLASSEXW = .{ .lpfnWndProc = win.wndProc, .hInstance = hinst, .lpszClassName = class };
    if (win.RegisterClassExW(&wc) == 0) return error.SkipZigTest;
    defer _ = win.UnregisterClassW(class, hinst);
    // Never shown, never activatable, off-screen.
    const hwnd = win.CreateWindowExW(
        win.WS_EX_NOACTIVATE | win.WS_EX_TOOLWINDOW,
        class,
        null,
        win.WS_POPUP,
        -32000,
        -32000,
        200,
        100,
        null,
        null,
        hinst,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = win.DestroyWindow(hwnd);
    try testing.expect(win.IsWindowVisible(hwnd) == com.FALSE);

    var target = gfx.HwndTarget.init(&fx.ctx, hwnd, 200, 100, 96, .{});
    defer target.deinit();
    // A never-shown window is not reported as occluded, so a full frame
    // runs (presenting to a hidden window shows nothing).
    if (try target.begin()) |c| {
        var canvas = c;
        canvas.clear(Color.hex(0x1E1E1E));
        canvas.fillPill(Rect.xywh(10, 10, 80, 20), Color.hex(0x3D8EF8));
        try testing.expect(target.end(&canvas) != .failed);
    }
    const rt = target.rt orelse return error.TestUnexpectedResult;

    // IID from the Windows SDK (absent from the mingw header): QI must work.
    try expectQi(d2d.ID2D1HwndRenderTarget, rt);
    try expectQi(d2d.ID2D1RenderTarget, rt);
    try testing.expectEqual(hwnd, rt.getHwnd().?);
    var px = rt.renderTarget().getPixelSize();
    try testing.expectEqual(@as(u32, 200), px.width);
    try testing.expectEqual(@as(u32, 100), px.height);

    target.resize(300, 150);
    px = rt.renderTarget().getPixelSize();
    try testing.expectEqual(@as(u32, 300), px.width);
    try testing.expectEqual(@as(u32, 150), px.height);

    target.setDpi(144);
    const dpi = rt.renderTarget().getDpi();
    try testing.expectEqual(@as(f32, 144), dpi.x);
    const dips = rt.renderTarget().getSize();
    try testing.expectApproxEqAbs(@as(f32, 200), dips.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 100), dips.height, 1e-3);
    try testing.expectEqual(@as(f32, 1.5), target.scale());

    // A raw frame still completes on the hidden window.
    const base = rt.renderTarget();
    base.beginDraw();
    base.clear(.{ .r = 0, .g = 0, .b = 0 });
    try testing.expect(gfx.device_state.classify(base.endDrawHresult()) != .failed);

    target.discard();
    try testing.expect(target.rt == null);
    try testing.expectEqual(@as(u32, 1), target.generation);
    // Zero size: nothing to draw, no target needed.
    target.resize(0, 0);
    try testing.expect((try target.begin()) == null);
    try testing.expect(target.rt == null);
}

// ─── Binding checks against live objects ────────────────────────────────

test "gfx: headless: QueryInterface succeeds for the declared IIDs" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const factory = fx.ctx.factory;
    try expectQi(d2d.ID2D1Factory, factory);
    if (fx.ctx.d2d_1_1) try expectQi(d2d.ID2D1Factory1, factory);

    var target = try gfx.BitmapTarget.init(&fx.ctx, 16, 16, 96, .dip);
    defer target.deinit();
    var canvas = try target.begin();
    const rt = canvas.rt;
    try expectQi(d2d.ID2D1RenderTarget, rt);
    try expectQi(d2d.ID2D1Resource, rt);
    if (fx.ctx.d2d_1_1) {
        try expectQi(d2d.ID2D1DeviceContext, rt);
        const dc = try com.queryInterface(d2d.ID2D1DeviceContext, rt);
        defer dc.release();
        try testing.expectEqual(d2d.D2D1_UNIT_MODE.dips, dc.getUnitMode());
        try testing.expect(dc.isDxgiFormatSupported(.b8g8r8a8_unorm));
        try testing.expectEqual(d2d.D2D1_PRIMITIVE_BLEND.source_over, dc.getPrimitiveBlend());
    }
    try expectQi(d2d.ID2D1GdiInteropRenderTarget, rt);
    const brush = target.res.brush.?;
    try expectQi(d2d.ID2D1SolidColorBrush, brush);
    try expectQi(d2d.ID2D1Brush, brush);
    // Hidden struct-return methods.
    brush.setColor(.{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 });
    const got = brush.getColor();
    try testing.expectEqual(@as(f32, 0.5), got.g);
    try testing.expectEqual(@as(f32, 0.75), got.b);
    const fmt = rt.getPixelFormat();
    try testing.expectEqual(d2d.DXGI_FORMAT.b8g8r8a8_unorm, fmt.format);
    try testing.expectEqual(d2d.D2D1_ALPHA_MODE.premultiplied, fmt.alphaMode);
    try testing.expectEqual(@as(f32, 16), rt.getSize().width);
    try testing.expect(rt.getMaximumBitmapSize() >= 4096);

    const layer = try rt.createLayer(null);
    defer layer.release();
    try expectQi(d2d.ID2D1Layer, layer);
    const bmp = try rt.createBitmap(.{ .width = 4, .height = 4 }, null, 0, .{ .pixelFormat = .{ .format = .b8g8r8a8_unorm, .alphaMode = .premultiplied } });
    defer bmp.release();
    try expectQi(d2d.ID2D1Bitmap, bmp);
    try expectQi(d2d.ID2D1Image, bmp);
    try testing.expectEqual(@as(u32, 4), bmp.getPixelSize().width);
    const compat = try rt.createCompatibleRenderTarget(.{ .width = 8, .height = 8 });
    defer compat.release();
    try expectQi(d2d.ID2D1BitmapRenderTarget, compat);
    const stops = [_]d2d.D2D1_GRADIENT_STOP{ .{ .position = 0, .color = .{ .r = 0, .g = 0, .b = 0 } }, .{ .position = 1, .color = .{ .r = 1, .g = 1, .b = 1 } } };
    const collection = try rt.createGradientStopCollection(&stops, .gamma_2_2, .clamp);
    defer collection.release();
    try expectQi(d2d.ID2D1GradientStopCollection, collection);
    const linear = try rt.createLinearGradientBrush(.{ .startPoint = .{}, .endPoint = .{ .x = 16 } }, null, collection);
    defer linear.release();
    try expectQi(d2d.ID2D1LinearGradientBrush, linear);
    canvas.fillRect(Rect.xywh(0, 0, 16, 16), Color.black);
    try testing.expectEqual(gfx.EndResult.presented, target.end(&canvas));

    try expectQi(d2d.ID2D1StrokeStyle, fx.ctx.round_caps);
    try testing.expectEqual(d2d.D2D1_CAP_STYLE.round, fx.ctx.round_caps.getStartCap());
    const block = try factory.createDrawingStateBlock();
    defer block.release();
    try expectQi(d2d.ID2D1DrawingStateBlock, block);

    // DirectWrite.
    const text = &fx.ctx.text;
    try expectQi(dwrite.IDWriteFactory, text.factory);
    try expectQi(dwrite.IDWriteFontCollection, text.fonts);
    const style: TextStyle = .{};
    const format = try text.format(&style);
    try expectQi(dwrite.IDWriteTextFormat, format);
    const l = try text.layout("x", &style, 100, 100);
    defer l.deinit();
    try expectQi(dwrite.IDWriteTextLayout, l.raw);
    try expectQi(dwrite.IDWriteTextFormat, l.raw);
    const sign = try text.factory.createEllipsisTrimmingSign(format);
    defer sign.release();
    try expectQi(dwrite.IDWriteInlineObject, sign);
    try testing.expect((try sign.getMetrics()).width > 0);
    const typo = try text.factory.createTypography();
    defer typo.release();
    try expectQi(dwrite.IDWriteTypography, typo);
    try typo.addFontFeature(.{ .nameTag = dwrite.fontFeatureTag("tnum"), .parameter = 1 });
    const params = try text.factory.createRenderingParams();
    defer params.release();
    try expectQi(dwrite.IDWriteRenderingParams, params);
    const interop = try text.factory.getGdiInterop();
    defer interop.release();
    try expectQi(dwrite.IDWriteGdiInterop, interop);
    const family = try text.fonts.getFontFamily(0);
    defer family.release();
    try expectQi(dwrite.IDWriteFontFamily, family);
    try expectQi(dwrite.IDWriteFontList, family);
    const font = try family.fontList().getFont(0);
    defer font.release();
    try expectQi(dwrite.IDWriteFont, font);
    const face = try font.createFontFace();
    defer face.release();
    try expectQi(dwrite.IDWriteFontFace, face);
    const names = try family.getFamilyNames();
    defer names.release();
    try expectQi(dwrite.IDWriteLocalizedStrings, names);

    // WIC.
    const wf = try fx.ctx.wicFactory();
    try expectQi(wic.IWICImagingFactory, wf);
    try expectQi(wic.IWICBitmap, target.bitmap);
    try expectQi(wic.IWICBitmapSource, target.bitmap);
    const lock = try target.bitmap.lock(null, .{ .read = true });
    try expectQi(wic.IWICBitmapLock, lock);
    try testing.expectEqual(@as(u32, 16 * 4), try lock.getStride());
    try testing.expectEqual(@as(usize, 16 * 16 * 4), (try lock.getData()).len);
    lock.release();
    const stream = try wf.createStream();
    defer stream.release();
    try expectQi(wic.IWICStream, stream);
    try expectQi(com.IStream, stream);
    const encoder = try wf.createEncoder(&wic.GUID_ContainerFormatPng);
    defer encoder.release();
    try expectQi(wic.IWICBitmapEncoder, encoder);
    const converter = try wf.createFormatConverter();
    defer converter.release();
    try expectQi(wic.IWICFormatConverter, converter);
}

test "gfx: headless: geometry wrappers pass structs by value correctly" {
    const fx = try Fixture.init(.{});
    defer fx.deinit();
    const factory = fx.ctx.factory;

    const rr = try factory.createRoundedRectangleGeometry(.{ .rect = .{ .left = 0, .top = 0, .right = 40, .bottom = 20 }, .radiusX = 5, .radiusY = 5 });
    defer rr.release();
    try expectQi(d2d.ID2D1RoundedRectangleGeometry, rr);
    try expectQi(d2d.ID2D1Geometry, rr);
    const g = rr.geometry();
    const bounds = try g.getBounds(null);
    try testing.expectApproxEqAbs(@as(f32, 40), bounds.right, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 20), bounds.bottom, 1e-3);
    try testing.expect(try g.fillContainsPoint(.{ .x = 20, .y = 10 }, null));
    try testing.expect(!try g.fillContainsPoint(.{ .x = 0.3, .y = 0.3 }, null));
    try testing.expect(!try g.fillContainsPoint(.{ .x = 60, .y = 10 }, null));
    // 40*20 minus the four corner cut-outs, (4 - pi) * r^2; Direct2D
    // flattens the arcs at the default 0.25 tolerance, so it reads a bit low.
    try testing.expectApproxEqRel(@as(f32, 800 - (4 - std.math.pi) * 25), try g.computeArea(), 0.03);
    try testing.expectEqual(@as(f32, 5), rr.getRoundedRect().radiusX);

    // A triangle path: area, figure and segment counts.
    const path = try factory.createPathGeometry();
    defer path.release();
    try expectQi(d2d.ID2D1PathGeometry, path);
    const sink = try path.open();
    try expectQi(d2d.ID2D1GeometrySink, sink);
    sink.setFillMode(.winding);
    sink.beginFigure(.{ .x = 0, .y = 0 }, .filled);
    sink.addLines(&.{ .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 10 } });
    sink.endFigure(.closed);
    try sink.close();
    sink.release();
    try testing.expectApproxEqAbs(@as(f32, 50), try path.geometry().computeArea(), 1e-2);
    try testing.expectEqual(@as(u32, 1), try path.getFigureCount());
    // Two explicit lines plus the segment that closes the figure.
    try testing.expectEqual(@as(u32, 3), try path.getSegmentCount());
    try testing.expect(try path.geometry().strokeContainsPoint(.{ .x = 5, .y = 0 }, 2, null));

    const ellipse = try factory.createEllipseGeometry(.{ .point = .{ .x = 10, .y = 10 }, .radiusX = 10, .radiusY = 10 });
    defer ellipse.release();
    try testing.expectApproxEqRel(@as(f32, std.math.pi * 100), try ellipse.geometry().computeArea(), 0.03);
    const rect = try factory.createRectangleGeometry(.{ .left = 0, .top = 0, .right = 2, .bottom = 3 });
    defer rect.release();
    const moved = try factory.createTransformedGeometry(rect.geometry(), d2d.D2D1_MATRIX_3X2_F.translation(10, 0));
    defer moved.release();
    try testing.expectApproxEqAbs(@as(f32, 12), (try moved.geometry().getBounds(null)).right, 1e-3);
    const group = try factory.createGeometryGroup(.alternate, &.{ rect.geometry(), ellipse.geometry() });
    defer group.release();
    try expectQi(d2d.ID2D1GeometryGroup, group);
}
