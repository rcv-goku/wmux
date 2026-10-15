//! Render-target hosts for on-screen drawing (ARCHITECTURE ADR-11.1):
//!
//! - `HwndTarget`: an ID2D1HwndRenderTarget bound to a child HWND (the D2D
//!   sidebar, the right-sidebar mode bar, the palette list).
//! - `DcTarget`: an ID2D1DCRenderTarget drawing into a GDI DC (the W5 tab
//!   bars, inside the window's existing double-buffered paint).
//!
//! Both create the target lazily, keep device-dependent resources in a
//! `DeviceResources`, and recover from device loss: when EndDraw reports
//! D2DERR_RECREATE_TARGET (or a DXGI device-removed/reset code) the target
//! and its resources are released, `generation` increments, and `end`
//! returns `.recreate` so the caller invalidates the window; the next paint
//! creates a fresh target. Repeated losses or a missing GPU switch the host
//! to the software rasterizer (`logic/device_state.zig`).
//!
//! Window procedure contract (the caller owns the HWND):
//! - WM_PAINT: BeginPaint (or ValidateRect) yourself, then `begin`/`end`.
//!   `begin` returns null when nothing should be drawn (zero size, window
//!   occluded); still end the paint.
//! - WM_SIZE: `resize(width, height)` in device pixels.
//! - WM_DPICHANGED: `setDpi(dpi)` (and resize).
//! - `.recreate` from `end`: InvalidateRect the window.
const std = @import("std");
const com = @import("../../platform/com.zig");
const d2d = @import("../../platform/d2d.zig");
const geometry = @import("logic/geometry.zig");
const device_state = @import("logic/device_state.zig");
const canvas_mod = @import("canvas.zig");
const Context = @import("context.zig").Context;

const log = std.log.scoped(.gfx);

pub const Canvas = canvas_mod.Canvas;
pub const DeviceResources = canvas_mod.DeviceResources;

pub const Unit = enum {
    /// Render-target DPI = window DPI: draw in DIPs; Direct2D scales to
    /// device pixels. Layout and caches are DPI-independent.
    dip,
    /// Render-target DPI = 96: draw in device pixels (matches geometry
    /// already computed in pixels, e.g. the GDI chrome's).
    pixel,
};

pub const TargetOptions = struct {
    unit: Unit = .dip,
    text_antialias: d2d.D2D1_TEXT_ANTIALIAS_MODE = .default,
    /// Always use the software rasterizer (recommended for DC targets: no
    /// GPU readback into GDI).
    force_software: bool = false,
    /// HWND targets: present without waiting for vsync.
    present_immediately: bool = false,
    /// HWND targets: keep the back buffer between presents (only needed for
    /// partial redraws).
    retain_contents: bool = false,
};

pub const EndResult = enum {
    presented,
    /// The device was lost and the target discarded: invalidate and repaint.
    recreate,
    /// EndDraw failed for another reason (logged); the next paint retries.
    failed,
};

fn targetDpi(unit: Unit, dpi: u32) f32 {
    return switch (unit) {
        .dip => @floatFromInt(if (dpi == 0) 96 else dpi),
        .pixel => 96,
    };
}

fn canvasScale(unit: Unit, dpi: u32) f32 {
    return switch (unit) {
        .dip => geometry.Dpi.init(dpi).scale(),
        .pixel => 1,
    };
}

fn finishFrame(rt: *d2d.ID2D1RenderTarget, canvas: *Canvas, policy: *device_state.LossPolicy) EndResult {
    canvas.finish();
    const hr = rt.endDrawHresult();
    switch (device_state.classify(hr)) {
        .ok => {
            policy.onPresented();
            return .presented;
        },
        .recreate => {
            policy.onLost();
            log.info("Direct2D device lost (hr=0x{x}); recreating the render target", .{@as(u32, @bitCast(hr))});
            return .recreate;
        },
        .failed => {
            com.last_failure = hr;
            log.warn("EndDraw failed (hr=0x{x})", .{@as(u32, @bitCast(hr))});
            return .failed;
        },
    }
}

pub const HwndTarget = struct {
    ctx: *Context,
    hwnd: com.HWND,
    width: u32,
    height: u32,
    dpi: u32,
    opts: TargetOptions,
    rt: ?*d2d.ID2D1HwndRenderTarget = null,
    res: DeviceResources = .{},
    policy: device_state.LossPolicy = .{},
    /// Increments whenever device resources are discarded; callers caching
    /// their own device-dependent objects (bitmaps) compare it.
    generation: u32 = 0,
    in_draw: bool = false,

    /// No Direct2D work happens until the first `begin`.
    pub fn init(ctx: *Context, hwnd: com.HWND, width_px: u32, height_px: u32, dpi: u32, opts: TargetOptions) HwndTarget {
        var t: HwndTarget = .{ .ctx = ctx, .hwnd = hwnd, .width = width_px, .height = height_px, .dpi = if (dpi == 0) 96 else dpi, .opts = opts };
        if (opts.force_software) t.policy.onHardwareUnavailable();
        return t;
    }

    pub fn deinit(self: *HwndTarget) void {
        self.release();
        self.* = undefined;
    }

    /// Release the target and its resources (device loss, or to free GPU
    /// memory while hidden); the next `begin` recreates them.
    pub fn discard(self: *HwndTarget) void {
        std.debug.assert(!self.in_draw);
        self.release();
        self.generation +%= 1;
    }

    fn release(self: *HwndTarget) void {
        self.res.release();
        com.releaseAndNull(&self.rt);
    }

    pub fn resize(self: *HwndTarget, width_px: u32, height_px: u32) void {
        std.debug.assert(!self.in_draw);
        self.width = width_px;
        self.height = height_px;
        const rt = self.rt orelse return;
        if (width_px == 0 or height_px == 0) return;
        rt.resize(width_px, height_px) catch |err| {
            log.debug("HwndRenderTarget.Resize failed: {s}", .{@errorName(err)});
            self.discard();
        };
    }

    pub fn setDpi(self: *HwndTarget, dpi: u32) void {
        self.dpi = if (dpi == 0) 96 else dpi;
        if (self.rt) |rt| {
            const v = targetDpi(self.opts.unit, self.dpi);
            rt.renderTarget().setDpi(v, v);
        }
    }

    /// Device pixels per layout unit for the current DPI and unit.
    pub fn scale(self: *const HwndTarget) f32 {
        return canvasScale(self.opts.unit, self.dpi);
    }

    fn create(self: *HwndTarget, mode: device_state.RenderMode) com.Error!*d2d.ID2D1HwndRenderTarget {
        const v = targetDpi(self.opts.unit, self.dpi);
        return self.ctx.factory.createHwndRenderTarget(.{
            .type = if (mode == .software) .software else .default,
            .dpiX = v,
            .dpiY = v,
        }, .{
            .hwnd = self.hwnd,
            .pixelSize = .{ .width = self.width, .height = self.height },
            .presentOptions = .{ .immediately = self.opts.present_immediately, .retain_contents = self.opts.retain_contents },
        });
    }

    fn ensure(self: *HwndTarget) com.Error!*d2d.ID2D1HwndRenderTarget {
        if (self.rt) |rt| return rt;
        const rt = self.create(self.policy.mode) catch |err| blk: {
            if (self.policy.mode == .software or err == error.OutOfMemory) return err;
            log.info("hardware HWND render target unavailable ({s}); using software", .{@errorName(err)});
            self.policy.onHardwareUnavailable();
            break :blk try self.create(.software);
        };
        errdefer rt.release();
        rt.renderTarget().setTextAntialiasMode(self.opts.text_antialias);
        try self.res.ensure(rt.renderTarget());
        self.rt = rt;
        return rt;
    }

    /// Start a frame. Null when there is nothing to draw (zero size or the
    /// window is occluded/minimized).
    pub fn begin(self: *HwndTarget) com.Error!?Canvas {
        std.debug.assert(!self.in_draw);
        if (self.width == 0 or self.height == 0) return null;
        const rt = self.ensure() catch |err| {
            self.release();
            return err;
        };
        if (rt.isOccluded()) return null;
        const base = rt.renderTarget();
        base.beginDraw();
        self.in_draw = true;
        return Canvas.init(self.ctx, base, &self.res, self.scale());
    }

    /// Finish the frame started by `begin`.
    pub fn end(self: *HwndTarget, canvas: *Canvas) EndResult {
        std.debug.assert(self.in_draw);
        self.in_draw = false;
        const rt = self.rt orelse return .failed;
        const result = finishFrame(rt.renderTarget(), canvas, &self.policy);
        if (result == .recreate) self.discard();
        return result;
    }
};

pub const DcTarget = struct {
    ctx: *Context,
    dpi: u32,
    opts: TargetOptions,
    /// D2D1_ALPHA_MODE for the DC's pixels: `.ignore` for ordinary window
    /// DCs, `.premultiplied` for 32bpp DIB sections with alpha.
    alpha: d2d.D2D1_ALPHA_MODE,
    rt: ?*d2d.ID2D1DCRenderTarget = null,
    res: DeviceResources = .{},
    policy: device_state.LossPolicy = .{},
    generation: u32 = 0,
    in_draw: bool = false,

    pub fn init(ctx: *Context, dpi: u32, alpha: d2d.D2D1_ALPHA_MODE, opts: TargetOptions) DcTarget {
        var t: DcTarget = .{ .ctx = ctx, .dpi = if (dpi == 0) 96 else dpi, .opts = opts, .alpha = alpha };
        if (opts.force_software) t.policy.onHardwareUnavailable();
        return t;
    }

    pub fn deinit(self: *DcTarget) void {
        self.release();
        self.* = undefined;
    }

    pub fn discard(self: *DcTarget) void {
        std.debug.assert(!self.in_draw);
        self.release();
        self.generation +%= 1;
    }

    fn release(self: *DcTarget) void {
        self.res.release();
        com.releaseAndNull(&self.rt);
    }

    pub fn setDpi(self: *DcTarget, dpi: u32) void {
        self.dpi = if (dpi == 0) 96 else dpi;
        if (self.rt) |rt| {
            const v = targetDpi(self.opts.unit, self.dpi);
            rt.renderTarget().setDpi(v, v);
        }
    }

    pub fn scale(self: *const DcTarget) f32 {
        return canvasScale(self.opts.unit, self.dpi);
    }

    fn create(self: *DcTarget, mode: device_state.RenderMode) com.Error!*d2d.ID2D1DCRenderTarget {
        const v = targetDpi(self.opts.unit, self.dpi);
        return self.ctx.factory.createDCRenderTarget(.{
            .type = if (mode == .software) .software else .default,
            .pixelFormat = .{ .format = .b8g8r8a8_unorm, .alphaMode = self.alpha },
            .dpiX = v,
            .dpiY = v,
        });
    }

    fn ensure(self: *DcTarget) com.Error!*d2d.ID2D1DCRenderTarget {
        if (self.rt) |rt| return rt;
        const rt = self.create(self.policy.mode) catch |err| blk: {
            if (self.policy.mode == .software or err == error.OutOfMemory) return err;
            self.policy.onHardwareUnavailable();
            break :blk try self.create(.software);
        };
        errdefer rt.release();
        rt.renderTarget().setTextAntialiasMode(self.opts.text_antialias);
        try self.res.ensure(rt.renderTarget());
        self.rt = rt;
        return rt;
    }

    /// Bind to `hdc` (an HDC from any Win32 binding; e.g. the window's
    /// double-buffer DC) drawing into `rect` (device pixels of that DC) and
    /// start a frame. Null for an empty rect.
    pub fn begin(self: *DcTarget, hdc: *anyopaque, rect: geometry.PixelRect) com.Error!?Canvas {
        std.debug.assert(!self.in_draw);
        if (rect.isEmpty()) return null;
        const rt = self.ensure() catch |err| {
            self.release();
            return err;
        };
        rt.bindDC(@ptrCast(hdc), .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom }) catch |err| {
            if (err == error.RecreateTarget) self.discard();
            return err;
        };
        const base = rt.renderTarget();
        base.beginDraw();
        self.in_draw = true;
        return Canvas.init(self.ctx, base, &self.res, self.scale());
    }

    pub fn end(self: *DcTarget, canvas: *Canvas) EndResult {
        std.debug.assert(self.in_draw);
        self.in_draw = false;
        const rt = self.rt orelse return .failed;
        const result = finishFrame(rt.renderTarget(), canvas, &self.policy);
        if (result == .recreate) self.discard();
        return result;
    }
};
