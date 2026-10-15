//! Device-independent Direct2D/DirectWrite state for one UI thread
//! (ARCHITECTURE ADR-11): the Direct2D factory (1.1 when available), the
//! DirectWrite text system, shared stroke styles and, on demand, the WIC
//! imaging factory. Render-target hosts (`target.zig`, `offscreen.zig`)
//! borrow it; everything here survives Direct2D device loss.
//!
//! Create one per UI thread and keep it at a stable address (hosts and the
//! text measurer hold pointers into it). Destroy it after its targets.
const std = @import("std");
const com = @import("../../platform/com.zig");
const d2d = @import("../../platform/d2d.zig");
const wic = @import("../../platform/wic.zig");
const text_mod = @import("text.zig");

const log = std.log.scoped(.gfx);

pub const Options = struct {
    /// Request the Direct2D debug layer (needs the "Graphics Tools" optional
    /// Windows feature; silently falls back when missing).
    debug_layer: bool = false,
    /// Use the Direct2D 1.0 factory even when 1.1 exists (exercises the
    /// fallback paths: no color fonts, explicit layer objects).
    force_d2d_1_0: bool = false,
    text: text_mod.TextSystem.Options = .{},
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    /// An ID2D1Factory1 when `d2d_1_1` (viewed through its base interface).
    factory: *d2d.ID2D1Factory,
    /// Render targets from this factory are ID2D1DeviceContexts: color
    /// fonts and null layers are available.
    d2d_1_1: bool,
    text: text_mod.TextSystem,
    /// Round caps and joins (spinners, progress arcs).
    round_caps: *d2d.ID2D1StrokeStyle,
    wic_factory: ?*wic.IWICImagingFactory = null,

    pub fn init(gpa: std.mem.Allocator, opts: Options) text_mod.Error!Context {
        const created = try createFactory(opts);
        errdefer created.factory.release();
        var text = try text_mod.TextSystem.init(gpa, opts.text);
        errdefer text.deinit();
        const round_caps = try created.factory.createStrokeStyle(.{
            .startCap = .round,
            .endCap = .round,
            .dashCap = .round,
            .lineJoin = .round,
        }, &.{});
        return .{
            .gpa = gpa,
            .factory = created.factory,
            .d2d_1_1 = created.is_1_1,
            .text = text,
            .round_caps = round_caps,
        };
    }

    pub fn deinit(self: *Context) void {
        com.releaseAndNull(&self.wic_factory);
        self.round_caps.release();
        self.text.deinit();
        self.factory.release();
        self.* = undefined;
    }

    /// The WIC imaging factory (created on first use; the calling thread
    /// must have COM initialized, which the wmux UI thread does).
    pub fn wicFactory(self: *Context) com.Error!*wic.IWICImagingFactory {
        if (self.wic_factory) |f| return f;
        const f = try wic.createImagingFactory();
        self.wic_factory = f;
        return f;
    }

    /// Re-read system metrics after WM_SETTINGCHANGE / WM_DISPLAYCHANGE.
    pub fn reloadSystemMetrics(self: *Context) void {
        self.factory.reloadSystemMetrics() catch |err| log.debug("ReloadSystemMetrics failed: {s}", .{@errorName(err)});
    }
};

const Created = struct { factory: *d2d.ID2D1Factory, is_1_1: bool };

fn createFactory(opts: Options) com.Error!Created {
    const levels: []const d2d.D2D1_DEBUG_LEVEL = if (opts.debug_layer) &.{ .information, .none } else &.{.none};
    var last: com.Error = error.Unexpected;
    for (levels) |level| {
        const options: d2d.D2D1_FACTORY_OPTIONS = .{ .debugLevel = level };
        if (!opts.force_d2d_1_0) {
            if (d2d.createFactory(d2d.ID2D1Factory1, .single_threaded, options)) |f1| {
                return .{ .factory = f1.factory(), .is_1_1 = true };
            } else |err| last = err;
        }
        if (d2d.createFactory(d2d.ID2D1Factory, .single_threaded, options)) |f| {
            return .{ .factory = f, .is_1_1 = false };
        } else |err| last = err;
        log.debug("D2D1CreateFactory (debug level {s}) failed: {s}", .{ @tagName(level), @errorName(last) });
    }
    return last;
}
