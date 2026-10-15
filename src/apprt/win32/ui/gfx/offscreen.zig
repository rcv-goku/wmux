//! Offscreen rendering into a WIC bitmap (ARCHITECTURE ADR-11, ADR-12):
//! headless rendering for tests, and screenshots (`window.screenshot`,
//! debug snapshots) via pixel readback or PNG encoding.
//!
//! The target is a software Direct2D render target over a 32bpp
//! premultiplied BGRA (PBGRA) `IWICBitmap`; the bitmap survives `discard`,
//! only the render target and its resources are recreated. Needs COM on the
//! calling thread (WIC).
const std = @import("std");
const com = @import("../../platform/com.zig");
const d2d = @import("../../platform/d2d.zig");
const wic = @import("../../platform/wic.zig");
const geometry = @import("logic/geometry.zig");
const device_state = @import("logic/device_state.zig");
const canvas_mod = @import("canvas.zig");
const target_mod = @import("target.zig");
const utf16 = @import("logic/utf16_map.zig");
const Context = @import("context.zig").Context;

const Canvas = canvas_mod.Canvas;
const DeviceResources = canvas_mod.DeviceResources;

pub const Error = com.Error || std.mem.Allocator.Error;

pub const BitmapTarget = struct {
    ctx: *Context,
    bitmap: *wic.IWICBitmap,
    rt: ?*d2d.ID2D1RenderTarget = null,
    res: DeviceResources = .{},
    width: u32,
    height: u32,
    dpi: u32,
    unit: target_mod.Unit,
    generation: u32 = 0,
    in_draw: bool = false,

    /// A `width` x `height` pixel target. With `.dip` units the canvas draws
    /// in DIPs at `dpi` (e.g. 144 renders a 150% screenshot).
    pub fn init(ctx: *Context, width: u32, height: u32, dpi: u32, unit: target_mod.Unit) com.Error!BitmapTarget {
        if (width == 0 or height == 0) return error.InvalidArg;
        const factory = try ctx.wicFactory();
        const bitmap = try factory.createBitmap(width, height, &wic.GUID_WICPixelFormat32bppPBGRA, .cache_on_load);
        return .{ .ctx = ctx, .bitmap = bitmap, .width = width, .height = height, .dpi = if (dpi == 0) 96 else dpi, .unit = unit };
    }

    pub fn deinit(self: *BitmapTarget) void {
        self.res.release();
        com.releaseAndNull(&self.rt);
        self.bitmap.release();
        self.* = undefined;
    }

    /// Drop the render target and its resources (they are recreated by the
    /// next `begin`); exercises the same path as device loss.
    pub fn discard(self: *BitmapTarget) void {
        std.debug.assert(!self.in_draw);
        self.res.release();
        com.releaseAndNull(&self.rt);
        self.generation +%= 1;
    }

    fn ensure(self: *BitmapTarget) com.Error!*d2d.ID2D1RenderTarget {
        if (self.rt) |rt| return rt;
        const v: f32 = if (self.unit == .dip) @floatFromInt(self.dpi) else 96;
        const rt = try self.ctx.factory.createWicBitmapRenderTarget(self.bitmap, .{
            .type = .default,
            .pixelFormat = .{ .format = .b8g8r8a8_unorm, .alphaMode = .premultiplied },
            .dpiX = v,
            .dpiY = v,
        });
        errdefer rt.release();
        rt.setTextAntialiasMode(.grayscale);
        try self.res.ensure(rt);
        self.rt = rt;
        return rt;
    }

    pub fn begin(self: *BitmapTarget) com.Error!Canvas {
        std.debug.assert(!self.in_draw);
        const rt = try self.ensure();
        rt.beginDraw();
        self.in_draw = true;
        const s: f32 = if (self.unit == .dip) geometry.Dpi.init(self.dpi).scale() else 1;
        return Canvas.init(self.ctx, rt, &self.res, s);
    }

    pub fn end(self: *BitmapTarget, canvas: *Canvas) target_mod.EndResult {
        std.debug.assert(self.in_draw);
        self.in_draw = false;
        const rt = self.rt orelse return .failed;
        canvas.finish();
        const hr = rt.endDrawHresult();
        return switch (device_state.classify(hr)) {
            .ok => .presented,
            .recreate => blk: {
                self.discard();
                break :blk .recreate;
            },
            .failed => blk: {
                com.last_failure = hr;
                break :blk .failed;
            },
        };
    }

    /// Row stride of `copyPixels` output.
    pub fn stride(self: *const BitmapTarget) usize {
        return @as(usize, self.width) * 4;
    }

    /// Copy the pixels (premultiplied BGRA, top-down rows of `stride()`
    /// bytes) into `out` (at least `stride() * height` bytes). Not during a
    /// frame.
    pub fn copyPixels(self: *BitmapTarget, out: []u8) com.Error!void {
        std.debug.assert(!self.in_draw);
        const need = self.stride() * self.height;
        if (out.len < need) return error.BufferTooSmall;
        try self.bitmap.source().copyPixels(null, @intCast(self.stride()), out[0..need]);
    }

    pub fn readPixelsAlloc(self: *BitmapTarget, gpa: std.mem.Allocator) Error![]u8 {
        const out = try gpa.alloc(u8, self.stride() * self.height);
        errdefer gpa.free(out);
        try self.copyPixels(out);
        return out;
    }

    /// The image as a PNG file in memory (straight-alpha BGRA); caller frees.
    pub fn encodePngAlloc(self: *BitmapTarget, gpa: std.mem.Allocator) Error![]u8 {
        std.debug.assert(!self.in_draw);
        const factory = try self.ctx.wicFactory();
        const stream = try com.createMemoryStream();
        defer stream.release();
        try wic.encodePng(factory, self.bitmap.source(), stream);
        return stream.readAllAlloc(gpa, 256 * 1024 * 1024);
    }

    /// Write the image to `path` (UTF-8) as PNG.
    pub fn savePng(self: *BitmapTarget, gpa: std.mem.Allocator, path: []const u8) Error!void {
        std.debug.assert(!self.in_draw);
        const factory = try self.ctx.wicFactory();
        const path16 = try utf16.encodeLossyAllocZ(gpa, path);
        defer gpa.free(path16);
        const stream = try factory.createStream();
        defer stream.release();
        try stream.initializeFromFilename(path16.ptr, wic.GENERIC_WRITE);
        try wic.encodePng(factory, self.bitmap.source(), stream.stream());
    }
};
