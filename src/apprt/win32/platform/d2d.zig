//! Direct2D bindings (d2d1.h, d2d1_1.h) for the D2D sidebar, palette and
//! (W5) tab bars (ARCHITECTURE ADR-11): factories, HWND / DC / WIC-bitmap
//! render targets, brushes, stroke styles, geometries (rectangle, rounded
//! rectangle, ellipse, path + sink), layers, and the Direct2D 1.1 factory
//! and device context.
//!
//! Conventions (nested vtables, `// N:` slot indices, hidden struct-return
//! pointers, ownership, `Error`) are described in `com.zig`. Slot orders
//! follow the mingw-w64 `d2d1.h`/`d2d1_1.h` shipped with Zig and are pinned
//! by the tests at the bottom. Exotic Direct2D 1.1 slots (effects, color
//! contexts, command lists) are `PadFn` placeholders.
//!
//! Render target rules the gfx layer relies on (see `ui/gfx/target.zig`):
//! - Draw calls between BeginDraw/EndDraw return nothing; errors surface from
//!   EndDraw/Flush. `D2DERR_RECREATE_TARGET` (`error.RecreateTarget`) means
//!   the device is gone: release the target and everything created from it
//!   (brushes, bitmaps, layers) and recreate on the next paint. Factory
//!   resources (geometries, stroke styles) and DirectWrite objects survive.
//! - A render target created from an `ID2D1Factory1` also implements
//!   `ID2D1DeviceContext` (Windows 8+), which enables color fonts
//!   (`D2D1_DRAW_TEXT_OPTIONS.enable_color_font`) and `PushLayer(.., null)`.
//!
//! Self-contained: imports only `std`, `com.zig`, `dwrite.zig` and `wic.zig`.
const std = @import("std");
const com = @import("com.zig");
const dwrite = @import("dwrite.zig");
const wic = @import("wic.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const PadFn = com.PadFn;
const Error = com.Error;
const check = com.check;
const checkOut = com.checkOut;

// ─── Basic types (dcommon.h, d2dbasetypes.h) ────────────────────────────

pub const D2D1_TAG = u64;

pub const D2D1_COLOR_F = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,
};

pub const D2D1_POINT_2F = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const D2D1_POINT_2U = extern struct {
    x: u32 = 0,
    y: u32 = 0,
};

pub const D2D1_SIZE_F = extern struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const D2D1_SIZE_U = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const D2D1_RECT_F = extern struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
};

pub const D2D1_RECT_U = extern struct {
    left: u32 = 0,
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,
};

/// Row-vector affine matrix: `x' = x*m11 + y*m21 + dx`, `y' = x*m12 + y*m22 + dy`.
pub const D2D1_MATRIX_3X2_F = extern struct {
    m11: f32 = 1,
    m12: f32 = 0,
    m21: f32 = 0,
    m22: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    pub const identity: D2D1_MATRIX_3X2_F = .{};

    pub fn translation(x: f32, y: f32) D2D1_MATRIX_3X2_F {
        return .{ .dx = x, .dy = y };
    }

    pub fn scale(sx: f32, sy: f32, center: D2D1_POINT_2F) D2D1_MATRIX_3X2_F {
        return .{ .m11 = sx, .m22 = sy, .dx = center.x - sx * center.x, .dy = center.y - sy * center.y };
    }

    /// Rotation by `degrees` around `center`; positive is clockwise on
    /// screen (y down), as in D2D1MakeRotateMatrix.
    pub fn rotation(degrees: f32, center: D2D1_POINT_2F) D2D1_MATRIX_3X2_F {
        const rad = degrees * (std.math.pi / 180.0);
        const c = @cos(rad);
        const s = @sin(rad);
        return .{
            .m11 = c,
            .m12 = s,
            .m21 = -s,
            .m22 = c,
            .dx = center.x - center.x * c + center.y * s,
            .dy = center.y - center.x * s - center.y * c,
        };
    }

    /// `a` then `b` (`a * b` in row-vector convention).
    pub fn multiply(a: D2D1_MATRIX_3X2_F, b: D2D1_MATRIX_3X2_F) D2D1_MATRIX_3X2_F {
        return .{
            .m11 = a.m11 * b.m11 + a.m12 * b.m21,
            .m12 = a.m11 * b.m12 + a.m12 * b.m22,
            .m21 = a.m21 * b.m11 + a.m22 * b.m21,
            .m22 = a.m21 * b.m12 + a.m22 * b.m22,
            .dx = a.dx * b.m11 + a.dy * b.m21 + b.dx,
            .dy = a.dx * b.m12 + a.dy * b.m22 + b.dy,
        };
    }

    pub fn transformPoint(m: D2D1_MATRIX_3X2_F, p: D2D1_POINT_2F) D2D1_POINT_2F {
        return .{ .x = p.x * m.m11 + p.y * m.m21 + m.dx, .y = p.x * m.m12 + p.y * m.m22 + m.dy };
    }
};

pub const D2D1_ROUNDED_RECT = extern struct {
    rect: D2D1_RECT_F,
    radiusX: f32,
    radiusY: f32,
};

pub const D2D1_ELLIPSE = extern struct {
    point: D2D1_POINT_2F,
    radiusX: f32,
    radiusY: f32,
};

pub const D2D1_TRIANGLE = extern struct {
    point1: D2D1_POINT_2F,
    point2: D2D1_POINT_2F,
    point3: D2D1_POINT_2F,
};

pub const D2D1_BEZIER_SEGMENT = extern struct {
    point1: D2D1_POINT_2F,
    point2: D2D1_POINT_2F,
    point3: D2D1_POINT_2F,
};

pub const D2D1_QUADRATIC_BEZIER_SEGMENT = extern struct {
    point1: D2D1_POINT_2F,
    point2: D2D1_POINT_2F,
};

pub const D2D1_ARC_SEGMENT = extern struct {
    point: D2D1_POINT_2F,
    size: D2D1_SIZE_F,
    rotationAngle: f32 = 0,
    sweepDirection: D2D1_SWEEP_DIRECTION,
    arcSize: D2D1_ARC_SIZE,
};

/// The subset of DXGI_FORMAT used with Direct2D render targets and bitmaps.
pub const DXGI_FORMAT = enum(u32) {
    unknown = 0,
    r8g8b8a8_unorm = 28,
    a8_unorm = 65,
    b8g8r8a8_unorm = 87,
    b8g8r8x8_unorm = 88,
    _,
};

pub const D2D1_ALPHA_MODE = enum(u32) {
    unknown = 0,
    premultiplied = 1,
    straight = 2,
    ignore = 3,
};

pub const D2D1_PIXEL_FORMAT = extern struct {
    format: DXGI_FORMAT = .unknown,
    alphaMode: D2D1_ALPHA_MODE = .unknown,
};

// ─── Enums and flags (d2d1.h) ───────────────────────────────────────────

pub const D2D1_FACTORY_TYPE = enum(u32) { single_threaded = 0, multi_threaded = 1 };

pub const D2D1_DEBUG_LEVEL = enum(u32) { none = 0, @"error" = 1, warning = 2, information = 3 };

pub const D2D1_RENDER_TARGET_TYPE = enum(u32) { default = 0, software = 1, hardware = 2 };

pub const D2D1_RENDER_TARGET_USAGE = packed struct(u32) {
    force_bitmap_remoting: bool = false,
    gdi_compatible: bool = false,
    _reserved: u30 = 0,
};

pub const D2D1_FEATURE_LEVEL = enum(u32) {
    default = 0,
    /// D3D10_FEATURE_LEVEL_9_1
    level_9 = 0x9100,
    /// D3D10_FEATURE_LEVEL_10_0
    level_10 = 0xa000,
};

pub const D2D1_PRESENT_OPTIONS = packed struct(u32) {
    /// Keep the back buffer across presents (needed for partial redraws).
    retain_contents: bool = false,
    /// Present without waiting for vsync.
    immediately: bool = false,
    _reserved: u30 = 0,
};

pub const D2D1_WINDOW_STATE = packed struct(u32) {
    occluded: bool = false,
    _reserved: u31 = 0,
};

pub const D2D1_ANTIALIAS_MODE = enum(u32) { per_primitive = 0, aliased = 1 };

pub const D2D1_TEXT_ANTIALIAS_MODE = enum(u32) { default = 0, cleartype = 1, grayscale = 2, aliased = 3 };

pub const D2D1_DRAW_TEXT_OPTIONS = packed struct(u32) {
    /// Do not snap glyph baselines to pixels (smooth text animation).
    no_snap: bool = false,
    /// Clip text to the layout rectangle.
    clip: bool = false,
    /// Draw color glyphs (emoji); Windows 8.1+ device contexts only.
    enable_color_font: bool = false,
    disable_color_bitmap_snapping: bool = false,
    _reserved: u28 = 0,
};

pub const D2D1_CAP_STYLE = enum(u32) { flat = 0, square = 1, round = 2, triangle = 3 };

pub const D2D1_LINE_JOIN = enum(u32) { miter = 0, bevel = 1, round = 2, miter_or_bevel = 3 };

pub const D2D1_DASH_STYLE = enum(u32) { solid = 0, dash = 1, dot = 2, dash_dot = 3, dash_dot_dot = 4, custom = 5 };

pub const D2D1_FIGURE_BEGIN = enum(u32) { filled = 0, hollow = 1 };

pub const D2D1_FIGURE_END = enum(u32) { open = 0, closed = 1 };

pub const D2D1_FILL_MODE = enum(u32) { alternate = 0, winding = 1 };

pub const D2D1_PATH_SEGMENT = packed struct(u32) {
    force_unstroked: bool = false,
    force_round_line_join: bool = false,
    _reserved: u30 = 0,
};

pub const D2D1_SWEEP_DIRECTION = enum(u32) { counter_clockwise = 0, clockwise = 1 };

pub const D2D1_ARC_SIZE = enum(u32) { small = 0, large = 1 };

pub const D2D1_GEOMETRY_RELATION = enum(u32) { unknown = 0, disjoint = 1, is_contained = 2, contains = 3, overlap = 4 };

pub const D2D1_GEOMETRY_SIMPLIFICATION_OPTION = enum(u32) { cubics_and_lines = 0, lines = 1 };

pub const D2D1_COMBINE_MODE = enum(u32) { @"union" = 0, intersect = 1, xor = 2, exclude = 3 };

pub const D2D1_LAYER_OPTIONS = packed struct(u32) {
    initialize_for_cleartype: bool = false,
    _reserved: u31 = 0,
};

pub const D2D1_GAMMA = enum(u32) { gamma_2_2 = 0, gamma_1_0 = 1 };

pub const D2D1_EXTEND_MODE = enum(u32) { clamp = 0, wrap = 1, mirror = 2 };

pub const D2D1_BITMAP_INTERPOLATION_MODE = enum(u32) { nearest_neighbor = 0, linear = 1 };

pub const D2D1_OPACITY_MASK_CONTENT = enum(u32) { graphics = 0, text_natural = 1, text_gdi_compatible = 2 };

pub const D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS = packed struct(u32) {
    gdi_compatible: bool = false,
    _reserved: u31 = 0,
};

pub const D2D1_DC_INITIALIZE_MODE = enum(u32) { copy = 0, clear = 1 };

// Direct2D 1.1 (d2d1_1.h).
pub const D2D1_PRIMITIVE_BLEND = enum(u32) { source_over = 0, copy = 1, min = 2, add = 3, max = 4 };
pub const D2D1_UNIT_MODE = enum(u32) { dips = 0, pixels = 1 };
pub const D2D1_INTERPOLATION_MODE = enum(u32) {
    nearest_neighbor = 0,
    linear = 1,
    cubic = 2,
    multi_sample_linear = 3,
    anisotropic = 4,
    high_quality_cubic = 5,
};
pub const D2D1_COMPOSITE_MODE = enum(u32) {
    source_over = 0,
    destination_over = 1,
    source_in = 2,
    destination_in = 3,
    source_out = 4,
    destination_out = 5,
    source_atop = 6,
    destination_atop = 7,
    xor = 8,
    plus = 9,
    source_copy = 10,
    bounded_source_copy = 11,
    mask_invert = 12,
};
pub const D2D1_BUFFER_PRECISION = enum(u32) {
    unknown = 0,
    unorm_8bpc = 1,
    unorm_8bpc_srgb = 2,
    unorm_16bpc = 3,
    float_16bpc = 4,
    float_32bpc = 5,
};

// ─── Property structs ───────────────────────────────────────────────────

pub const D2D1_FACTORY_OPTIONS = extern struct {
    debugLevel: D2D1_DEBUG_LEVEL = .none,
};

pub const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: D2D1_RENDER_TARGET_TYPE = .default,
    pixelFormat: D2D1_PIXEL_FORMAT = .{},
    /// 0 = use the factory's desktop DPI.
    dpiX: f32 = 0,
    dpiY: f32 = 0,
    usage: D2D1_RENDER_TARGET_USAGE = .{},
    minLevel: D2D1_FEATURE_LEVEL = .default,
};

pub const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct {
    hwnd: com.HWND,
    /// 0x0 = the window's client size.
    pixelSize: D2D1_SIZE_U = .{},
    presentOptions: D2D1_PRESENT_OPTIONS = .{},
};

pub const D2D1_BRUSH_PROPERTIES = extern struct {
    opacity: f32 = 1,
    transform: D2D1_MATRIX_3X2_F = .{},
};

pub const D2D1_BITMAP_PROPERTIES = extern struct {
    pixelFormat: D2D1_PIXEL_FORMAT = .{},
    dpiX: f32 = 0,
    dpiY: f32 = 0,
};

pub const D2D1_BITMAP_BRUSH_PROPERTIES = extern struct {
    extendModeX: D2D1_EXTEND_MODE = .clamp,
    extendModeY: D2D1_EXTEND_MODE = .clamp,
    interpolationMode: D2D1_BITMAP_INTERPOLATION_MODE = .linear,
};

pub const D2D1_GRADIENT_STOP = extern struct {
    position: f32,
    color: D2D1_COLOR_F,
};

pub const D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES = extern struct {
    startPoint: D2D1_POINT_2F,
    endPoint: D2D1_POINT_2F,
};

pub const D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES = extern struct {
    center: D2D1_POINT_2F,
    gradientOriginOffset: D2D1_POINT_2F,
    radiusX: f32,
    radiusY: f32,
};

pub const D2D1_STROKE_STYLE_PROPERTIES = extern struct {
    startCap: D2D1_CAP_STYLE = .flat,
    endCap: D2D1_CAP_STYLE = .flat,
    dashCap: D2D1_CAP_STYLE = .flat,
    lineJoin: D2D1_LINE_JOIN = .miter,
    miterLimit: f32 = 10,
    dashStyle: D2D1_DASH_STYLE = .solid,
    dashOffset: f32 = 0,
};

/// Infinite content bounds (D2D1::InfiniteRect()).
pub const infinite_rect: D2D1_RECT_F = .{
    .left = -std.math.floatMax(f32),
    .top = -std.math.floatMax(f32),
    .right = std.math.floatMax(f32),
    .bottom = std.math.floatMax(f32),
};

pub const D2D1_LAYER_PARAMETERS = extern struct {
    contentBounds: D2D1_RECT_F = infinite_rect,
    geometricMask: ?*ID2D1Geometry = null,
    maskAntialiasMode: D2D1_ANTIALIAS_MODE = .per_primitive,
    maskTransform: D2D1_MATRIX_3X2_F = .{},
    opacity: f32 = 1,
    opacityBrush: ?*ID2D1Brush = null,
    layerOptions: D2D1_LAYER_OPTIONS = .{},
};

pub const D2D1_DRAWING_STATE_DESCRIPTION = extern struct {
    antialiasMode: D2D1_ANTIALIAS_MODE = .per_primitive,
    textAntialiasMode: D2D1_TEXT_ANTIALIAS_MODE = .default,
    tag1: D2D1_TAG = 0,
    tag2: D2D1_TAG = 0,
    transform: D2D1_MATRIX_3X2_F = .{},
};

pub const D2D1_RENDERING_CONTROLS = extern struct {
    bufferPrecision: D2D1_BUFFER_PRECISION,
    tileSize: D2D1_SIZE_U,
};

// ─── Unbound interfaces ─────────────────────────────────────────────────

fn Unbound(comptime iid: []const u8) type {
    return extern struct {
        vtable: *const com.IUnknown.VTable,

        pub const IID = GUID.parse(iid);

        pub fn release(self: *@This()) void {
            com.release(self);
        }
    };
}

/// Direct2D 1.1 device (a D3D11 device wrapper); not used by wmux yet.
pub const ID2D1Device = Unbound("{47dd575d-ac05-4cdd-8049-9b02cd16f44c}");

// ─── ID2D1Resource / ID2D1Image / ID2D1Bitmap ───────────────────────────

pub const ID2D1Resource = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd90691-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetFactory(ID2D1Factory**)
        GetFactory: *const fn (*ID2D1Resource, *?*ID2D1Factory) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1Resource) void {
        com.release(self);
    }

    /// The factory that created this resource (carries a reference).
    pub fn getFactory(self: *ID2D1Resource) ?*ID2D1Factory {
        var out: ?*ID2D1Factory = null;
        self.vtable.GetFactory(self, &out);
        return out;
    }
};

pub const ID2D1Image = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{65019f75-8da2-497c-b32c-dfa34e48ede6}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
    };

    pub fn release(self: *ID2D1Image) void {
        com.release(self);
    }
};

pub const ID2D1Bitmap = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{a2296057-ea42-4099-983b-539fb6505426}");

    pub const VTable = extern struct {
        base: ID2D1Image.VTable,
        // 4: GetSize() -> D2D1_SIZE_F (hidden result pointer)
        GetSize: *const fn (*ID2D1Bitmap, *D2D1_SIZE_F) callconv(.winapi) *D2D1_SIZE_F,
        // 5: GetPixelSize() -> D2D1_SIZE_U (hidden result pointer)
        GetPixelSize: *const fn (*ID2D1Bitmap, *D2D1_SIZE_U) callconv(.winapi) *D2D1_SIZE_U,
        // 6: GetPixelFormat() -> D2D1_PIXEL_FORMAT (hidden result pointer)
        GetPixelFormat: *const fn (*ID2D1Bitmap, *D2D1_PIXEL_FORMAT) callconv(.winapi) *D2D1_PIXEL_FORMAT,
        // 7: GetDpi(FLOAT* dpiX, FLOAT* dpiY)
        GetDpi: *const fn (*ID2D1Bitmap, *f32, *f32) callconv(.winapi) void,
        // 8: CopyFromBitmap(const D2D1_POINT_2U* destPoint, ID2D1Bitmap*, const D2D1_RECT_U* srcRect)
        CopyFromBitmap: *const fn (*ID2D1Bitmap, ?*const D2D1_POINT_2U, *ID2D1Bitmap, ?*const D2D1_RECT_U) callconv(.winapi) HRESULT,
        // 9: CopyFromRenderTarget(const D2D1_POINT_2U* destPoint, ID2D1RenderTarget*, const D2D1_RECT_U* srcRect)
        CopyFromRenderTarget: *const fn (*ID2D1Bitmap, ?*const D2D1_POINT_2U, *ID2D1RenderTarget, ?*const D2D1_RECT_U) callconv(.winapi) HRESULT,
        // 10: CopyFromMemory(const D2D1_RECT_U* dstRect, const void* srcData, UINT32 pitch)
        CopyFromMemory: *const fn (*ID2D1Bitmap, ?*const D2D1_RECT_U, *const anyopaque, u32) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1Bitmap) void {
        com.release(self);
    }

    pub fn image(self: *ID2D1Bitmap) *ID2D1Image {
        return @ptrCast(self);
    }

    pub fn getSize(self: *ID2D1Bitmap) D2D1_SIZE_F {
        var out: D2D1_SIZE_F = undefined;
        _ = self.vtable.GetSize(self, &out);
        return out;
    }

    pub fn getPixelSize(self: *ID2D1Bitmap) D2D1_SIZE_U {
        var out: D2D1_SIZE_U = undefined;
        _ = self.vtable.GetPixelSize(self, &out);
        return out;
    }

    pub fn getPixelFormat(self: *ID2D1Bitmap) D2D1_PIXEL_FORMAT {
        var out: D2D1_PIXEL_FORMAT = undefined;
        _ = self.vtable.GetPixelFormat(self, &out);
        return out;
    }

    pub fn copyFromMemory(self: *ID2D1Bitmap, dst: ?*const D2D1_RECT_U, data: []const u8, pitch: u32) Error!void {
        try check(self.vtable.CopyFromMemory(self, dst, data.ptr, pitch));
    }
};

// ─── Brushes ────────────────────────────────────────────────────────────

pub const ID2D1Brush = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a8-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: SetOpacity(FLOAT)
        SetOpacity: *const fn (*ID2D1Brush, f32) callconv(.winapi) void,
        // 5: SetTransform(const D2D1_MATRIX_3X2_F*)
        SetTransform: *const fn (*ID2D1Brush, *const D2D1_MATRIX_3X2_F) callconv(.winapi) void,
        // 6: GetOpacity()
        GetOpacity: *const fn (*ID2D1Brush) callconv(.winapi) f32,
        // 7: GetTransform(D2D1_MATRIX_3X2_F*)
        GetTransform: *const fn (*ID2D1Brush, *D2D1_MATRIX_3X2_F) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1Brush) void {
        com.release(self);
    }

    pub fn setOpacity(self: *ID2D1Brush, opacity: f32) void {
        self.vtable.SetOpacity(self, opacity);
    }

    pub fn getOpacity(self: *ID2D1Brush) f32 {
        return self.vtable.GetOpacity(self);
    }

    pub fn setTransform(self: *ID2D1Brush, m: D2D1_MATRIX_3X2_F) void {
        self.vtable.SetTransform(self, &m);
    }
};

pub const ID2D1SolidColorBrush = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a9-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Brush.VTable,
        // 8: SetColor(const D2D1_COLOR_F*)
        SetColor: *const fn (*ID2D1SolidColorBrush, *const D2D1_COLOR_F) callconv(.winapi) void,
        // 9: GetColor() -> D2D1_COLOR_F (hidden result pointer)
        GetColor: *const fn (*ID2D1SolidColorBrush, *D2D1_COLOR_F) callconv(.winapi) *D2D1_COLOR_F,
    };

    pub fn release(self: *ID2D1SolidColorBrush) void {
        com.release(self);
    }

    pub fn brush(self: *ID2D1SolidColorBrush) *ID2D1Brush {
        return @ptrCast(self);
    }

    pub fn setColor(self: *ID2D1SolidColorBrush, color: D2D1_COLOR_F) void {
        self.vtable.SetColor(self, &color);
    }

    pub fn getColor(self: *ID2D1SolidColorBrush) D2D1_COLOR_F {
        var out: D2D1_COLOR_F = undefined;
        _ = self.vtable.GetColor(self, &out);
        return out;
    }
};

pub const ID2D1GradientStopCollection = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a7-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: GetGradientStopCount()
        GetGradientStopCount: *const fn (*ID2D1GradientStopCollection) callconv(.winapi) u32,
        // 5: GetGradientStops(D2D1_GRADIENT_STOP*, UINT32 count)
        GetGradientStops: *const fn (*ID2D1GradientStopCollection, [*]D2D1_GRADIENT_STOP, u32) callconv(.winapi) void,
        // 6: GetColorInterpolationGamma()
        GetColorInterpolationGamma: *const fn (*ID2D1GradientStopCollection) callconv(.winapi) D2D1_GAMMA,
        // 7: GetExtendMode()
        GetExtendMode: *const fn (*ID2D1GradientStopCollection) callconv(.winapi) D2D1_EXTEND_MODE,
    };

    pub fn release(self: *ID2D1GradientStopCollection) void {
        com.release(self);
    }
};

pub const ID2D1LinearGradientBrush = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906ab-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Brush.VTable,
        // 8: SetStartPoint(D2D1_POINT_2F)
        SetStartPoint: *const fn (*ID2D1LinearGradientBrush, D2D1_POINT_2F) callconv(.winapi) void,
        // 9: SetEndPoint(D2D1_POINT_2F)
        SetEndPoint: *const fn (*ID2D1LinearGradientBrush, D2D1_POINT_2F) callconv(.winapi) void,
        // 10: GetStartPoint() -> D2D1_POINT_2F (hidden result pointer)
        GetStartPoint: *const fn (*ID2D1LinearGradientBrush, *D2D1_POINT_2F) callconv(.winapi) *D2D1_POINT_2F,
        // 11: GetEndPoint() -> D2D1_POINT_2F (hidden result pointer)
        GetEndPoint: *const fn (*ID2D1LinearGradientBrush, *D2D1_POINT_2F) callconv(.winapi) *D2D1_POINT_2F,
        // 12: GetGradientStopCollection(ID2D1GradientStopCollection**)
        GetGradientStopCollection: *const fn (*ID2D1LinearGradientBrush, *?*ID2D1GradientStopCollection) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1LinearGradientBrush) void {
        com.release(self);
    }

    pub fn brush(self: *ID2D1LinearGradientBrush) *ID2D1Brush {
        return @ptrCast(self);
    }

    pub fn setStartPoint(self: *ID2D1LinearGradientBrush, p: D2D1_POINT_2F) void {
        self.vtable.SetStartPoint(self, p);
    }

    pub fn setEndPoint(self: *ID2D1LinearGradientBrush, p: D2D1_POINT_2F) void {
        self.vtable.SetEndPoint(self, p);
    }
};

pub const ID2D1RadialGradientBrush = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906ac-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Brush.VTable,
        // 8: SetCenter(D2D1_POINT_2F)
        SetCenter: *const fn (*ID2D1RadialGradientBrush, D2D1_POINT_2F) callconv(.winapi) void,
        // 9: SetGradientOriginOffset(D2D1_POINT_2F)
        SetGradientOriginOffset: *const fn (*ID2D1RadialGradientBrush, D2D1_POINT_2F) callconv(.winapi) void,
        // 10: SetRadiusX(FLOAT)
        SetRadiusX: *const fn (*ID2D1RadialGradientBrush, f32) callconv(.winapi) void,
        // 11: SetRadiusY(FLOAT)
        SetRadiusY: *const fn (*ID2D1RadialGradientBrush, f32) callconv(.winapi) void,
        // 12: GetCenter() -> D2D1_POINT_2F (hidden result pointer)
        GetCenter: *const fn (*ID2D1RadialGradientBrush, *D2D1_POINT_2F) callconv(.winapi) *D2D1_POINT_2F,
        // 13: GetGradientOriginOffset() -> D2D1_POINT_2F (hidden result pointer)
        GetGradientOriginOffset: *const fn (*ID2D1RadialGradientBrush, *D2D1_POINT_2F) callconv(.winapi) *D2D1_POINT_2F,
        // 14: GetRadiusX()
        GetRadiusX: *const fn (*ID2D1RadialGradientBrush) callconv(.winapi) f32,
        // 15: GetRadiusY()
        GetRadiusY: *const fn (*ID2D1RadialGradientBrush) callconv(.winapi) f32,
        // 16: GetGradientStopCollection(ID2D1GradientStopCollection**)
        GetGradientStopCollection: *const fn (*ID2D1RadialGradientBrush, *?*ID2D1GradientStopCollection) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1RadialGradientBrush) void {
        com.release(self);
    }

    pub fn brush(self: *ID2D1RadialGradientBrush) *ID2D1Brush {
        return @ptrCast(self);
    }
};

pub const ID2D1BitmapBrush = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906aa-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Brush.VTable,
        // 8: SetExtendModeX(D2D1_EXTEND_MODE)
        SetExtendModeX: *const fn (*ID2D1BitmapBrush, D2D1_EXTEND_MODE) callconv(.winapi) void,
        // 9: SetExtendModeY(D2D1_EXTEND_MODE)
        SetExtendModeY: *const fn (*ID2D1BitmapBrush, D2D1_EXTEND_MODE) callconv(.winapi) void,
        // 10: SetInterpolationMode(D2D1_BITMAP_INTERPOLATION_MODE)
        SetInterpolationMode: *const fn (*ID2D1BitmapBrush, D2D1_BITMAP_INTERPOLATION_MODE) callconv(.winapi) void,
        // 11: SetBitmap(ID2D1Bitmap*)
        SetBitmap: *const fn (*ID2D1BitmapBrush, ?*ID2D1Bitmap) callconv(.winapi) void,
        // 12: GetExtendModeX()
        GetExtendModeX: *const fn (*ID2D1BitmapBrush) callconv(.winapi) D2D1_EXTEND_MODE,
        // 13: GetExtendModeY()
        GetExtendModeY: *const fn (*ID2D1BitmapBrush) callconv(.winapi) D2D1_EXTEND_MODE,
        // 14: GetInterpolationMode()
        GetInterpolationMode: *const fn (*ID2D1BitmapBrush) callconv(.winapi) D2D1_BITMAP_INTERPOLATION_MODE,
        // 15: GetBitmap(ID2D1Bitmap**)
        GetBitmap: *const fn (*ID2D1BitmapBrush, *?*ID2D1Bitmap) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1BitmapBrush) void {
        com.release(self);
    }

    pub fn brush(self: *ID2D1BitmapBrush) *ID2D1Brush {
        return @ptrCast(self);
    }
};

// ─── Stroke style, layer, drawing state ─────────────────────────────────

pub const ID2D1StrokeStyle = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd9069d-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: GetStartCap()
        GetStartCap: *const fn (*ID2D1StrokeStyle) callconv(.winapi) D2D1_CAP_STYLE,
        // 5: GetEndCap()
        GetEndCap: *const fn (*ID2D1StrokeStyle) callconv(.winapi) D2D1_CAP_STYLE,
        // 6: GetDashCap()
        GetDashCap: *const fn (*ID2D1StrokeStyle) callconv(.winapi) D2D1_CAP_STYLE,
        // 7: GetMiterLimit()
        GetMiterLimit: *const fn (*ID2D1StrokeStyle) callconv(.winapi) f32,
        // 8: GetLineJoin()
        GetLineJoin: *const fn (*ID2D1StrokeStyle) callconv(.winapi) D2D1_LINE_JOIN,
        // 9: GetDashOffset()
        GetDashOffset: *const fn (*ID2D1StrokeStyle) callconv(.winapi) f32,
        // 10: GetDashStyle()
        GetDashStyle: *const fn (*ID2D1StrokeStyle) callconv(.winapi) D2D1_DASH_STYLE,
        // 11: GetDashesCount()
        GetDashesCount: *const fn (*ID2D1StrokeStyle) callconv(.winapi) u32,
        // 12: GetDashes(FLOAT* dashes, UINT32 count)
        GetDashes: *const fn (*ID2D1StrokeStyle, [*]f32, u32) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1StrokeStyle) void {
        com.release(self);
    }

    pub fn getStartCap(self: *ID2D1StrokeStyle) D2D1_CAP_STYLE {
        return self.vtable.GetStartCap(self);
    }

    pub fn getEndCap(self: *ID2D1StrokeStyle) D2D1_CAP_STYLE {
        return self.vtable.GetEndCap(self);
    }
};

pub const ID2D1Layer = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd9069b-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: GetSize() -> D2D1_SIZE_F (hidden result pointer)
        GetSize: *const fn (*ID2D1Layer, *D2D1_SIZE_F) callconv(.winapi) *D2D1_SIZE_F,
    };

    pub fn release(self: *ID2D1Layer) void {
        com.release(self);
    }

    pub fn getSize(self: *ID2D1Layer) D2D1_SIZE_F {
        var out: D2D1_SIZE_F = undefined;
        _ = self.vtable.GetSize(self, &out);
        return out;
    }
};

pub const ID2D1DrawingStateBlock = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{28506e39-ebf6-46a1-bb47-fd85565ab957}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: GetDescription(D2D1_DRAWING_STATE_DESCRIPTION*)
        GetDescription: *const fn (*ID2D1DrawingStateBlock, *D2D1_DRAWING_STATE_DESCRIPTION) callconv(.winapi) void,
        // 5: SetDescription(const D2D1_DRAWING_STATE_DESCRIPTION*)
        SetDescription: *const fn (*ID2D1DrawingStateBlock, *const D2D1_DRAWING_STATE_DESCRIPTION) callconv(.winapi) void,
        // 6: SetTextRenderingParams(IDWriteRenderingParams*)
        SetTextRenderingParams: *const fn (*ID2D1DrawingStateBlock, ?*dwrite.IDWriteRenderingParams) callconv(.winapi) void,
        // 7: GetTextRenderingParams(IDWriteRenderingParams**)
        GetTextRenderingParams: *const fn (*ID2D1DrawingStateBlock, *?*dwrite.IDWriteRenderingParams) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1DrawingStateBlock) void {
        com.release(self);
    }
};

// ─── Geometries ─────────────────────────────────────────────────────────

pub const ID2D1Geometry = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a1-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: GetBounds(const D2D1_MATRIX_3X2_F* worldTransform, D2D1_RECT_F*)
        GetBounds: *const fn (*ID2D1Geometry, ?*const D2D1_MATRIX_3X2_F, *D2D1_RECT_F) callconv(.winapi) HRESULT,
        // 5: GetWidenedBounds(FLOAT strokeWidth, ID2D1StrokeStyle*, const D2D1_MATRIX_3X2_F*, FLOAT flatteningTolerance, D2D1_RECT_F*)
        GetWidenedBounds: *const fn (*ID2D1Geometry, f32, ?*ID2D1StrokeStyle, ?*const D2D1_MATRIX_3X2_F, f32, *D2D1_RECT_F) callconv(.winapi) HRESULT,
        // 6: StrokeContainsPoint(D2D1_POINT_2F, FLOAT strokeWidth, ID2D1StrokeStyle*, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, BOOL*)
        StrokeContainsPoint: *const fn (*ID2D1Geometry, D2D1_POINT_2F, f32, ?*ID2D1StrokeStyle, ?*const D2D1_MATRIX_3X2_F, f32, *BOOL) callconv(.winapi) HRESULT,
        // 7: FillContainsPoint(D2D1_POINT_2F, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, BOOL*)
        FillContainsPoint: *const fn (*ID2D1Geometry, D2D1_POINT_2F, ?*const D2D1_MATRIX_3X2_F, f32, *BOOL) callconv(.winapi) HRESULT,
        // 8: CompareWithGeometry(ID2D1Geometry*, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, D2D1_GEOMETRY_RELATION*)
        CompareWithGeometry: *const fn (*ID2D1Geometry, *ID2D1Geometry, ?*const D2D1_MATRIX_3X2_F, f32, *D2D1_GEOMETRY_RELATION) callconv(.winapi) HRESULT,
        // 9: Simplify(D2D1_GEOMETRY_SIMPLIFICATION_OPTION, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, ID2D1SimplifiedGeometrySink*)
        Simplify: *const fn (*ID2D1Geometry, D2D1_GEOMETRY_SIMPLIFICATION_OPTION, ?*const D2D1_MATRIX_3X2_F, f32, *ID2D1SimplifiedGeometrySink) callconv(.winapi) HRESULT,
        // 10: Tessellate(const D2D1_MATRIX_3X2_F*, FLOAT tolerance, ID2D1TessellationSink*)
        Tessellate: *const fn (*ID2D1Geometry, ?*const D2D1_MATRIX_3X2_F, f32, *ID2D1TessellationSink) callconv(.winapi) HRESULT,
        // 11: CombineWithGeometry(ID2D1Geometry*, D2D1_COMBINE_MODE, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, ID2D1SimplifiedGeometrySink*)
        CombineWithGeometry: *const fn (*ID2D1Geometry, *ID2D1Geometry, D2D1_COMBINE_MODE, ?*const D2D1_MATRIX_3X2_F, f32, *ID2D1SimplifiedGeometrySink) callconv(.winapi) HRESULT,
        // 12: Outline(const D2D1_MATRIX_3X2_F*, FLOAT tolerance, ID2D1SimplifiedGeometrySink*)
        Outline: *const fn (*ID2D1Geometry, ?*const D2D1_MATRIX_3X2_F, f32, *ID2D1SimplifiedGeometrySink) callconv(.winapi) HRESULT,
        // 13: ComputeArea(const D2D1_MATRIX_3X2_F*, FLOAT tolerance, FLOAT* area)
        ComputeArea: *const fn (*ID2D1Geometry, ?*const D2D1_MATRIX_3X2_F, f32, *f32) callconv(.winapi) HRESULT,
        // 14: ComputeLength(const D2D1_MATRIX_3X2_F*, FLOAT tolerance, FLOAT* length)
        ComputeLength: *const fn (*ID2D1Geometry, ?*const D2D1_MATRIX_3X2_F, f32, *f32) callconv(.winapi) HRESULT,
        // 15: ComputePointAtLength(FLOAT length, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, D2D1_POINT_2F* point, D2D1_POINT_2F* unitTangent)
        ComputePointAtLength: *const fn (*ID2D1Geometry, f32, ?*const D2D1_MATRIX_3X2_F, f32, ?*D2D1_POINT_2F, ?*D2D1_POINT_2F) callconv(.winapi) HRESULT,
        // 16: Widen(FLOAT strokeWidth, ID2D1StrokeStyle*, const D2D1_MATRIX_3X2_F*, FLOAT tolerance, ID2D1SimplifiedGeometrySink*)
        Widen: *const fn (*ID2D1Geometry, f32, ?*ID2D1StrokeStyle, ?*const D2D1_MATRIX_3X2_F, f32, *ID2D1SimplifiedGeometrySink) callconv(.winapi) HRESULT,
    };

    /// D2D1_DEFAULT_FLATTENING_TOLERANCE.
    pub const default_tolerance: f32 = 0.25;

    pub fn release(self: *ID2D1Geometry) void {
        com.release(self);
    }

    pub fn getBounds(self: *ID2D1Geometry, world: ?*const D2D1_MATRIX_3X2_F) Error!D2D1_RECT_F {
        var r: D2D1_RECT_F = .{};
        try check(self.vtable.GetBounds(self, world, &r));
        return r;
    }

    pub fn fillContainsPoint(self: *ID2D1Geometry, p: D2D1_POINT_2F, world: ?*const D2D1_MATRIX_3X2_F) Error!bool {
        var inside: BOOL = com.FALSE;
        try check(self.vtable.FillContainsPoint(self, p, world, default_tolerance, &inside));
        return inside != com.FALSE;
    }

    pub fn strokeContainsPoint(self: *ID2D1Geometry, p: D2D1_POINT_2F, stroke_width: f32, style: ?*ID2D1StrokeStyle) Error!bool {
        var inside: BOOL = com.FALSE;
        try check(self.vtable.StrokeContainsPoint(self, p, stroke_width, style, null, default_tolerance, &inside));
        return inside != com.FALSE;
    }

    pub fn computeArea(self: *ID2D1Geometry) Error!f32 {
        var area: f32 = 0;
        try check(self.vtable.ComputeArea(self, null, default_tolerance, &area));
        return area;
    }

    pub fn computeLength(self: *ID2D1Geometry) Error!f32 {
        var len: f32 = 0;
        try check(self.vtable.ComputeLength(self, null, default_tolerance, &len));
        return len;
    }
};

pub const ID2D1RectangleGeometry = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a2-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Geometry.VTable,
        // 17: GetRect(D2D1_RECT_F*)
        GetRect: *const fn (*ID2D1RectangleGeometry, *D2D1_RECT_F) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1RectangleGeometry) void {
        com.release(self);
    }

    pub fn geometry(self: *ID2D1RectangleGeometry) *ID2D1Geometry {
        return @ptrCast(self);
    }
};

pub const ID2D1RoundedRectangleGeometry = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a3-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Geometry.VTable,
        // 17: GetRoundedRect(D2D1_ROUNDED_RECT*)
        GetRoundedRect: *const fn (*ID2D1RoundedRectangleGeometry, *D2D1_ROUNDED_RECT) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1RoundedRectangleGeometry) void {
        com.release(self);
    }

    pub fn geometry(self: *ID2D1RoundedRectangleGeometry) *ID2D1Geometry {
        return @ptrCast(self);
    }

    pub fn getRoundedRect(self: *ID2D1RoundedRectangleGeometry) D2D1_ROUNDED_RECT {
        var out: D2D1_ROUNDED_RECT = undefined;
        self.vtable.GetRoundedRect(self, &out);
        return out;
    }
};

pub const ID2D1EllipseGeometry = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a4-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Geometry.VTable,
        // 17: GetEllipse(D2D1_ELLIPSE*)
        GetEllipse: *const fn (*ID2D1EllipseGeometry, *D2D1_ELLIPSE) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1EllipseGeometry) void {
        com.release(self);
    }

    pub fn geometry(self: *ID2D1EllipseGeometry) *ID2D1Geometry {
        return @ptrCast(self);
    }
};

pub const ID2D1GeometryGroup = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a6-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Geometry.VTable,
        // 17: GetFillMode()
        GetFillMode: *const fn (*ID2D1GeometryGroup) callconv(.winapi) D2D1_FILL_MODE,
        // 18: GetSourceGeometryCount()
        GetSourceGeometryCount: *const fn (*ID2D1GeometryGroup) callconv(.winapi) u32,
        // 19: GetSourceGeometries(ID2D1Geometry** geometries, UINT32 count)
        GetSourceGeometries: *const fn (*ID2D1GeometryGroup, [*]?*ID2D1Geometry, u32) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1GeometryGroup) void {
        com.release(self);
    }

    pub fn geometry(self: *ID2D1GeometryGroup) *ID2D1Geometry {
        return @ptrCast(self);
    }
};

pub const ID2D1TransformedGeometry = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906bb-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Geometry.VTable,
        // 17: GetSourceGeometry(ID2D1Geometry**)
        GetSourceGeometry: *const fn (*ID2D1TransformedGeometry, *?*ID2D1Geometry) callconv(.winapi) void,
        // 18: GetTransform(D2D1_MATRIX_3X2_F*)
        GetTransform: *const fn (*ID2D1TransformedGeometry, *D2D1_MATRIX_3X2_F) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1TransformedGeometry) void {
        com.release(self);
    }

    pub fn geometry(self: *ID2D1TransformedGeometry) *ID2D1Geometry {
        return @ptrCast(self);
    }
};

pub const ID2D1PathGeometry = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906a5-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Geometry.VTable,
        // 17: Open(ID2D1GeometrySink**)
        Open: *const fn (*ID2D1PathGeometry, *?*ID2D1GeometrySink) callconv(.winapi) HRESULT,
        // 18: Stream(ID2D1GeometrySink*)
        Stream: *const fn (*ID2D1PathGeometry, *ID2D1GeometrySink) callconv(.winapi) HRESULT,
        // 19: GetSegmentCount(UINT32*)
        GetSegmentCount: *const fn (*ID2D1PathGeometry, *u32) callconv(.winapi) HRESULT,
        // 20: GetFigureCount(UINT32*)
        GetFigureCount: *const fn (*ID2D1PathGeometry, *u32) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1PathGeometry) void {
        com.release(self);
    }

    pub fn geometry(self: *ID2D1PathGeometry) *ID2D1Geometry {
        return @ptrCast(self);
    }

    /// Open the (empty) path for writing. Fill it, then `close()` the sink
    /// and release it before drawing the geometry.
    pub fn open(self: *ID2D1PathGeometry) Error!*ID2D1GeometrySink {
        var out: ?*ID2D1GeometrySink = null;
        return checkOut(ID2D1GeometrySink, self.vtable.Open(self, &out), out);
    }

    pub fn getSegmentCount(self: *ID2D1PathGeometry) Error!u32 {
        var n: u32 = 0;
        try check(self.vtable.GetSegmentCount(self, &n));
        return n;
    }

    pub fn getFigureCount(self: *ID2D1PathGeometry) Error!u32 {
        var n: u32 = 0;
        try check(self.vtable.GetFigureCount(self, &n));
        return n;
    }
};

pub const ID2D1SimplifiedGeometrySink = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd9069e-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: SetFillMode(D2D1_FILL_MODE)
        SetFillMode: *const fn (*ID2D1SimplifiedGeometrySink, D2D1_FILL_MODE) callconv(.winapi) void,
        // 4: SetSegmentFlags(D2D1_PATH_SEGMENT)
        SetSegmentFlags: *const fn (*ID2D1SimplifiedGeometrySink, D2D1_PATH_SEGMENT) callconv(.winapi) void,
        // 5: BeginFigure(D2D1_POINT_2F startPoint, D2D1_FIGURE_BEGIN)
        BeginFigure: *const fn (*ID2D1SimplifiedGeometrySink, D2D1_POINT_2F, D2D1_FIGURE_BEGIN) callconv(.winapi) void,
        // 6: AddLines(const D2D1_POINT_2F* points, UINT32 count)
        AddLines: *const fn (*ID2D1SimplifiedGeometrySink, [*]const D2D1_POINT_2F, u32) callconv(.winapi) void,
        // 7: AddBeziers(const D2D1_BEZIER_SEGMENT* beziers, UINT32 count)
        AddBeziers: *const fn (*ID2D1SimplifiedGeometrySink, [*]const D2D1_BEZIER_SEGMENT, u32) callconv(.winapi) void,
        // 8: EndFigure(D2D1_FIGURE_END)
        EndFigure: *const fn (*ID2D1SimplifiedGeometrySink, D2D1_FIGURE_END) callconv(.winapi) void,
        // 9: Close()
        Close: *const fn (*ID2D1SimplifiedGeometrySink) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1SimplifiedGeometrySink) void {
        com.release(self);
    }
};

pub const ID2D1GeometrySink = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd9069f-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1SimplifiedGeometrySink.VTable,
        // 10: AddLine(D2D1_POINT_2F)
        AddLine: *const fn (*ID2D1GeometrySink, D2D1_POINT_2F) callconv(.winapi) void,
        // 11: AddBezier(const D2D1_BEZIER_SEGMENT*)
        AddBezier: *const fn (*ID2D1GeometrySink, *const D2D1_BEZIER_SEGMENT) callconv(.winapi) void,
        // 12: AddQuadraticBezier(const D2D1_QUADRATIC_BEZIER_SEGMENT*)
        AddQuadraticBezier: *const fn (*ID2D1GeometrySink, *const D2D1_QUADRATIC_BEZIER_SEGMENT) callconv(.winapi) void,
        // 13: AddQuadraticBeziers(const D2D1_QUADRATIC_BEZIER_SEGMENT*, UINT32 count)
        AddQuadraticBeziers: *const fn (*ID2D1GeometrySink, [*]const D2D1_QUADRATIC_BEZIER_SEGMENT, u32) callconv(.winapi) void,
        // 14: AddArc(const D2D1_ARC_SEGMENT*)
        AddArc: *const fn (*ID2D1GeometrySink, *const D2D1_ARC_SEGMENT) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1GeometrySink) void {
        com.release(self);
    }

    pub fn simplified(self: *ID2D1GeometrySink) *ID2D1SimplifiedGeometrySink {
        return @ptrCast(self);
    }

    pub fn setFillMode(self: *ID2D1GeometrySink, mode: D2D1_FILL_MODE) void {
        self.vtable.base.SetFillMode(self.simplified(), mode);
    }

    pub fn beginFigure(self: *ID2D1GeometrySink, start: D2D1_POINT_2F, begin: D2D1_FIGURE_BEGIN) void {
        self.vtable.base.BeginFigure(self.simplified(), start, begin);
    }

    pub fn addLines(self: *ID2D1GeometrySink, points: []const D2D1_POINT_2F) void {
        self.vtable.base.AddLines(self.simplified(), points.ptr, @intCast(points.len));
    }

    pub fn endFigure(self: *ID2D1GeometrySink, end: D2D1_FIGURE_END) void {
        self.vtable.base.EndFigure(self.simplified(), end);
    }

    /// Finish the path. Errors recorded while building surface here.
    pub fn close(self: *ID2D1GeometrySink) Error!void {
        try check(self.vtable.base.Close(self.simplified()));
    }

    pub fn addLine(self: *ID2D1GeometrySink, p: D2D1_POINT_2F) void {
        self.vtable.AddLine(self, p);
    }

    pub fn addBezier(self: *ID2D1GeometrySink, seg: D2D1_BEZIER_SEGMENT) void {
        self.vtable.AddBezier(self, &seg);
    }

    pub fn addQuadraticBezier(self: *ID2D1GeometrySink, seg: D2D1_QUADRATIC_BEZIER_SEGMENT) void {
        self.vtable.AddQuadraticBezier(self, &seg);
    }

    pub fn addArc(self: *ID2D1GeometrySink, arc: D2D1_ARC_SEGMENT) void {
        self.vtable.AddArc(self, &arc);
    }
};

pub const ID2D1TessellationSink = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906c1-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: AddTriangles(const D2D1_TRIANGLE*, UINT32 count)
        AddTriangles: *const fn (*ID2D1TessellationSink, [*]const D2D1_TRIANGLE, u32) callconv(.winapi) void,
        // 4: Close()
        Close: *const fn (*ID2D1TessellationSink) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1TessellationSink) void {
        com.release(self);
    }
};

pub const ID2D1Mesh = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd906c2-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: Open(ID2D1TessellationSink**)
        Open: *const fn (*ID2D1Mesh, *?*ID2D1TessellationSink) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1Mesh) void {
        com.release(self);
    }
};

// ─── ID2D1RenderTarget ──────────────────────────────────────────────────

pub const ID2D1RenderTarget = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd90694-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1Resource.VTable,
        // 4: CreateBitmap(D2D1_SIZE_U, const void* srcData, UINT32 pitch, const D2D1_BITMAP_PROPERTIES*, ID2D1Bitmap**)
        CreateBitmap: *const fn (*ID2D1RenderTarget, D2D1_SIZE_U, ?*const anyopaque, u32, *const D2D1_BITMAP_PROPERTIES, *?*ID2D1Bitmap) callconv(.winapi) HRESULT,
        // 5: CreateBitmapFromWicBitmap(IWICBitmapSource*, const D2D1_BITMAP_PROPERTIES*, ID2D1Bitmap**)
        CreateBitmapFromWicBitmap: *const fn (*ID2D1RenderTarget, *wic.IWICBitmapSource, ?*const D2D1_BITMAP_PROPERTIES, *?*ID2D1Bitmap) callconv(.winapi) HRESULT,
        // 6: CreateSharedBitmap(REFIID, void* data, const D2D1_BITMAP_PROPERTIES*, ID2D1Bitmap**)
        CreateSharedBitmap: *const fn (*ID2D1RenderTarget, *const GUID, *anyopaque, ?*const D2D1_BITMAP_PROPERTIES, *?*ID2D1Bitmap) callconv(.winapi) HRESULT,
        // 7: CreateBitmapBrush(ID2D1Bitmap*, const D2D1_BITMAP_BRUSH_PROPERTIES*, const D2D1_BRUSH_PROPERTIES*, ID2D1BitmapBrush**)
        CreateBitmapBrush: *const fn (*ID2D1RenderTarget, *ID2D1Bitmap, ?*const D2D1_BITMAP_BRUSH_PROPERTIES, ?*const D2D1_BRUSH_PROPERTIES, *?*ID2D1BitmapBrush) callconv(.winapi) HRESULT,
        // 8: CreateSolidColorBrush(const D2D1_COLOR_F*, const D2D1_BRUSH_PROPERTIES*, ID2D1SolidColorBrush**)
        CreateSolidColorBrush: *const fn (*ID2D1RenderTarget, *const D2D1_COLOR_F, ?*const D2D1_BRUSH_PROPERTIES, *?*ID2D1SolidColorBrush) callconv(.winapi) HRESULT,
        // 9: CreateGradientStopCollection(const D2D1_GRADIENT_STOP*, UINT32 count, D2D1_GAMMA, D2D1_EXTEND_MODE, ID2D1GradientStopCollection**)
        CreateGradientStopCollection: *const fn (*ID2D1RenderTarget, [*]const D2D1_GRADIENT_STOP, u32, D2D1_GAMMA, D2D1_EXTEND_MODE, *?*ID2D1GradientStopCollection) callconv(.winapi) HRESULT,
        // 10: CreateLinearGradientBrush(const D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES*, const D2D1_BRUSH_PROPERTIES*, ID2D1GradientStopCollection*, ID2D1LinearGradientBrush**)
        CreateLinearGradientBrush: *const fn (*ID2D1RenderTarget, *const D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES, ?*const D2D1_BRUSH_PROPERTIES, *ID2D1GradientStopCollection, *?*ID2D1LinearGradientBrush) callconv(.winapi) HRESULT,
        // 11: CreateRadialGradientBrush(const D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES*, const D2D1_BRUSH_PROPERTIES*, ID2D1GradientStopCollection*, ID2D1RadialGradientBrush**)
        CreateRadialGradientBrush: *const fn (*ID2D1RenderTarget, *const D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES, ?*const D2D1_BRUSH_PROPERTIES, *ID2D1GradientStopCollection, *?*ID2D1RadialGradientBrush) callconv(.winapi) HRESULT,
        // 12: CreateCompatibleRenderTarget(const D2D1_SIZE_F*, const D2D1_SIZE_U*, const D2D1_PIXEL_FORMAT*, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS, ID2D1BitmapRenderTarget**)
        CreateCompatibleRenderTarget: *const fn (*ID2D1RenderTarget, ?*const D2D1_SIZE_F, ?*const D2D1_SIZE_U, ?*const D2D1_PIXEL_FORMAT, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS, *?*ID2D1BitmapRenderTarget) callconv(.winapi) HRESULT,
        // 13: CreateLayer(const D2D1_SIZE_F*, ID2D1Layer**)
        CreateLayer: *const fn (*ID2D1RenderTarget, ?*const D2D1_SIZE_F, *?*ID2D1Layer) callconv(.winapi) HRESULT,
        // 14: CreateMesh(ID2D1Mesh**)
        CreateMesh: *const fn (*ID2D1RenderTarget, *?*ID2D1Mesh) callconv(.winapi) HRESULT,
        // 15: DrawLine(D2D1_POINT_2F, D2D1_POINT_2F, ID2D1Brush*, FLOAT strokeWidth, ID2D1StrokeStyle*)
        DrawLine: *const fn (*ID2D1RenderTarget, D2D1_POINT_2F, D2D1_POINT_2F, *ID2D1Brush, f32, ?*ID2D1StrokeStyle) callconv(.winapi) void,
        // 16: DrawRectangle(const D2D1_RECT_F*, ID2D1Brush*, FLOAT strokeWidth, ID2D1StrokeStyle*)
        DrawRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, *ID2D1Brush, f32, ?*ID2D1StrokeStyle) callconv(.winapi) void,
        // 17: FillRectangle(const D2D1_RECT_F*, ID2D1Brush*)
        FillRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, *ID2D1Brush) callconv(.winapi) void,
        // 18: DrawRoundedRectangle(const D2D1_ROUNDED_RECT*, ID2D1Brush*, FLOAT strokeWidth, ID2D1StrokeStyle*)
        DrawRoundedRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_ROUNDED_RECT, *ID2D1Brush, f32, ?*ID2D1StrokeStyle) callconv(.winapi) void,
        // 19: FillRoundedRectangle(const D2D1_ROUNDED_RECT*, ID2D1Brush*)
        FillRoundedRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_ROUNDED_RECT, *ID2D1Brush) callconv(.winapi) void,
        // 20: DrawEllipse(const D2D1_ELLIPSE*, ID2D1Brush*, FLOAT strokeWidth, ID2D1StrokeStyle*)
        DrawEllipse: *const fn (*ID2D1RenderTarget, *const D2D1_ELLIPSE, *ID2D1Brush, f32, ?*ID2D1StrokeStyle) callconv(.winapi) void,
        // 21: FillEllipse(const D2D1_ELLIPSE*, ID2D1Brush*)
        FillEllipse: *const fn (*ID2D1RenderTarget, *const D2D1_ELLIPSE, *ID2D1Brush) callconv(.winapi) void,
        // 22: DrawGeometry(ID2D1Geometry*, ID2D1Brush*, FLOAT strokeWidth, ID2D1StrokeStyle*)
        DrawGeometry: *const fn (*ID2D1RenderTarget, *ID2D1Geometry, *ID2D1Brush, f32, ?*ID2D1StrokeStyle) callconv(.winapi) void,
        // 23: FillGeometry(ID2D1Geometry*, ID2D1Brush*, ID2D1Brush* opacityBrush)
        FillGeometry: *const fn (*ID2D1RenderTarget, *ID2D1Geometry, *ID2D1Brush, ?*ID2D1Brush) callconv(.winapi) void,
        // 24: FillMesh(ID2D1Mesh*, ID2D1Brush*)
        FillMesh: *const fn (*ID2D1RenderTarget, *ID2D1Mesh, *ID2D1Brush) callconv(.winapi) void,
        // 25: FillOpacityMask(ID2D1Bitmap*, ID2D1Brush*, D2D1_OPACITY_MASK_CONTENT, const D2D1_RECT_F* dst, const D2D1_RECT_F* src)
        FillOpacityMask: *const fn (*ID2D1RenderTarget, *ID2D1Bitmap, *ID2D1Brush, D2D1_OPACITY_MASK_CONTENT, ?*const D2D1_RECT_F, ?*const D2D1_RECT_F) callconv(.winapi) void,
        // 26: DrawBitmap(ID2D1Bitmap*, const D2D1_RECT_F* dst, FLOAT opacity, D2D1_BITMAP_INTERPOLATION_MODE, const D2D1_RECT_F* src)
        DrawBitmap: *const fn (*ID2D1RenderTarget, *ID2D1Bitmap, ?*const D2D1_RECT_F, f32, D2D1_BITMAP_INTERPOLATION_MODE, ?*const D2D1_RECT_F) callconv(.winapi) void,
        // 27: DrawText(const WCHAR*, UINT32 length, IDWriteTextFormat*, const D2D1_RECT_F* layoutRect, ID2D1Brush*, D2D1_DRAW_TEXT_OPTIONS, DWRITE_MEASURING_MODE)
        DrawText: *const fn (*ID2D1RenderTarget, [*]const u16, u32, *dwrite.IDWriteTextFormat, *const D2D1_RECT_F, *ID2D1Brush, D2D1_DRAW_TEXT_OPTIONS, dwrite.DWRITE_MEASURING_MODE) callconv(.winapi) void,
        // 28: DrawTextLayout(D2D1_POINT_2F origin, IDWriteTextLayout*, ID2D1Brush*, D2D1_DRAW_TEXT_OPTIONS)
        DrawTextLayout: *const fn (*ID2D1RenderTarget, D2D1_POINT_2F, *dwrite.IDWriteTextLayout, *ID2D1Brush, D2D1_DRAW_TEXT_OPTIONS) callconv(.winapi) void,
        // 29: DrawGlyphRun(D2D1_POINT_2F baselineOrigin, const DWRITE_GLYPH_RUN*, ID2D1Brush*, DWRITE_MEASURING_MODE)
        DrawGlyphRun: *const fn (*ID2D1RenderTarget, D2D1_POINT_2F, *const dwrite.DWRITE_GLYPH_RUN, *ID2D1Brush, dwrite.DWRITE_MEASURING_MODE) callconv(.winapi) void,
        // 30: SetTransform(const D2D1_MATRIX_3X2_F*)
        SetTransform: *const fn (*ID2D1RenderTarget, *const D2D1_MATRIX_3X2_F) callconv(.winapi) void,
        // 31: GetTransform(D2D1_MATRIX_3X2_F*)
        GetTransform: *const fn (*ID2D1RenderTarget, *D2D1_MATRIX_3X2_F) callconv(.winapi) void,
        // 32: SetAntialiasMode(D2D1_ANTIALIAS_MODE)
        SetAntialiasMode: *const fn (*ID2D1RenderTarget, D2D1_ANTIALIAS_MODE) callconv(.winapi) void,
        // 33: GetAntialiasMode()
        GetAntialiasMode: *const fn (*ID2D1RenderTarget) callconv(.winapi) D2D1_ANTIALIAS_MODE,
        // 34: SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE)
        SetTextAntialiasMode: *const fn (*ID2D1RenderTarget, D2D1_TEXT_ANTIALIAS_MODE) callconv(.winapi) void,
        // 35: GetTextAntialiasMode()
        GetTextAntialiasMode: *const fn (*ID2D1RenderTarget) callconv(.winapi) D2D1_TEXT_ANTIALIAS_MODE,
        // 36: SetTextRenderingParams(IDWriteRenderingParams*)
        SetTextRenderingParams: *const fn (*ID2D1RenderTarget, ?*dwrite.IDWriteRenderingParams) callconv(.winapi) void,
        // 37: GetTextRenderingParams(IDWriteRenderingParams**)
        GetTextRenderingParams: *const fn (*ID2D1RenderTarget, *?*dwrite.IDWriteRenderingParams) callconv(.winapi) void,
        // 38: SetTags(D2D1_TAG, D2D1_TAG)
        SetTags: *const fn (*ID2D1RenderTarget, D2D1_TAG, D2D1_TAG) callconv(.winapi) void,
        // 39: GetTags(D2D1_TAG*, D2D1_TAG*)
        GetTags: *const fn (*ID2D1RenderTarget, ?*D2D1_TAG, ?*D2D1_TAG) callconv(.winapi) void,
        // 40: PushLayer(const D2D1_LAYER_PARAMETERS*, ID2D1Layer*)
        PushLayer: *const fn (*ID2D1RenderTarget, *const D2D1_LAYER_PARAMETERS, ?*ID2D1Layer) callconv(.winapi) void,
        // 41: PopLayer()
        PopLayer: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        // 42: Flush(D2D1_TAG*, D2D1_TAG*)
        Flush: *const fn (*ID2D1RenderTarget, ?*D2D1_TAG, ?*D2D1_TAG) callconv(.winapi) HRESULT,
        // 43: SaveDrawingState(ID2D1DrawingStateBlock*)
        SaveDrawingState: *const fn (*ID2D1RenderTarget, *ID2D1DrawingStateBlock) callconv(.winapi) void,
        // 44: RestoreDrawingState(ID2D1DrawingStateBlock*)
        RestoreDrawingState: *const fn (*ID2D1RenderTarget, *ID2D1DrawingStateBlock) callconv(.winapi) void,
        // 45: PushAxisAlignedClip(const D2D1_RECT_F*, D2D1_ANTIALIAS_MODE)
        PushAxisAlignedClip: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, D2D1_ANTIALIAS_MODE) callconv(.winapi) void,
        // 46: PopAxisAlignedClip()
        PopAxisAlignedClip: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        // 47: Clear(const D2D1_COLOR_F*)
        Clear: *const fn (*ID2D1RenderTarget, ?*const D2D1_COLOR_F) callconv(.winapi) void,
        // 48: BeginDraw()
        BeginDraw: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        // 49: EndDraw(D2D1_TAG*, D2D1_TAG*)
        EndDraw: *const fn (*ID2D1RenderTarget, ?*D2D1_TAG, ?*D2D1_TAG) callconv(.winapi) HRESULT,
        // 50: GetPixelFormat() -> D2D1_PIXEL_FORMAT (hidden result pointer)
        GetPixelFormat: *const fn (*ID2D1RenderTarget, *D2D1_PIXEL_FORMAT) callconv(.winapi) *D2D1_PIXEL_FORMAT,
        // 51: SetDpi(FLOAT dpiX, FLOAT dpiY)
        SetDpi: *const fn (*ID2D1RenderTarget, f32, f32) callconv(.winapi) void,
        // 52: GetDpi(FLOAT* dpiX, FLOAT* dpiY)
        GetDpi: *const fn (*ID2D1RenderTarget, *f32, *f32) callconv(.winapi) void,
        // 53: GetSize() -> D2D1_SIZE_F (hidden result pointer)
        GetSize: *const fn (*ID2D1RenderTarget, *D2D1_SIZE_F) callconv(.winapi) *D2D1_SIZE_F,
        // 54: GetPixelSize() -> D2D1_SIZE_U (hidden result pointer)
        GetPixelSize: *const fn (*ID2D1RenderTarget, *D2D1_SIZE_U) callconv(.winapi) *D2D1_SIZE_U,
        // 55: GetMaximumBitmapSize()
        GetMaximumBitmapSize: *const fn (*ID2D1RenderTarget) callconv(.winapi) u32,
        // 56: IsSupported(const D2D1_RENDER_TARGET_PROPERTIES*)
        IsSupported: *const fn (*ID2D1RenderTarget, *const D2D1_RENDER_TARGET_PROPERTIES) callconv(.winapi) BOOL,
    };

    pub fn release(self: *ID2D1RenderTarget) void {
        com.release(self);
    }

    pub fn resource(self: *ID2D1RenderTarget) *ID2D1Resource {
        return @ptrCast(self);
    }

    pub fn createSolidColorBrush(self: *ID2D1RenderTarget, color: D2D1_COLOR_F, props: ?*const D2D1_BRUSH_PROPERTIES) Error!*ID2D1SolidColorBrush {
        var out: ?*ID2D1SolidColorBrush = null;
        return checkOut(ID2D1SolidColorBrush, self.vtable.CreateSolidColorBrush(self, &color, props, &out), out);
    }

    pub fn createGradientStopCollection(self: *ID2D1RenderTarget, stops: []const D2D1_GRADIENT_STOP, gamma: D2D1_GAMMA, extend: D2D1_EXTEND_MODE) Error!*ID2D1GradientStopCollection {
        const n = std.math.cast(u32, stops.len) orelse return error.InvalidArg;
        var out: ?*ID2D1GradientStopCollection = null;
        return checkOut(ID2D1GradientStopCollection, self.vtable.CreateGradientStopCollection(self, stops.ptr, n, gamma, extend, &out), out);
    }

    pub fn createLinearGradientBrush(
        self: *ID2D1RenderTarget,
        props: D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES,
        brush_props: ?*const D2D1_BRUSH_PROPERTIES,
        stops: *ID2D1GradientStopCollection,
    ) Error!*ID2D1LinearGradientBrush {
        var out: ?*ID2D1LinearGradientBrush = null;
        return checkOut(ID2D1LinearGradientBrush, self.vtable.CreateLinearGradientBrush(self, &props, brush_props, stops, &out), out);
    }

    /// A bitmap with the target's pixel format semantics; `data` may be
    /// null (uninitialized) or `pitch * height` bytes.
    pub fn createBitmap(self: *ID2D1RenderTarget, size: D2D1_SIZE_U, data: ?*const anyopaque, pitch: u32, props: D2D1_BITMAP_PROPERTIES) Error!*ID2D1Bitmap {
        var out: ?*ID2D1Bitmap = null;
        return checkOut(ID2D1Bitmap, self.vtable.CreateBitmap(self, size, data, pitch, &props, &out), out);
    }

    pub fn createBitmapFromWicBitmap(self: *ID2D1RenderTarget, src: *wic.IWICBitmapSource, props: ?*const D2D1_BITMAP_PROPERTIES) Error!*ID2D1Bitmap {
        var out: ?*ID2D1Bitmap = null;
        return checkOut(ID2D1Bitmap, self.vtable.CreateBitmapFromWicBitmap(self, src, props, &out), out);
    }

    /// An offscreen target sharing this target's device (`size` null = same
    /// size). Its bitmap can be drawn into this target.
    pub fn createCompatibleRenderTarget(self: *ID2D1RenderTarget, size: ?D2D1_SIZE_F) Error!*ID2D1BitmapRenderTarget {
        var out: ?*ID2D1BitmapRenderTarget = null;
        const size_ptr: ?*const D2D1_SIZE_F = if (size) |*s| s else null;
        return checkOut(ID2D1BitmapRenderTarget, self.vtable.CreateCompatibleRenderTarget(self, size_ptr, null, null, .{}, &out), out);
    }

    /// A layer object for PushLayer (only required on Direct2D 1.0; a 1.1
    /// device context accepts a null layer).
    pub fn createLayer(self: *ID2D1RenderTarget, size: ?D2D1_SIZE_F) Error!*ID2D1Layer {
        var out: ?*ID2D1Layer = null;
        const size_ptr: ?*const D2D1_SIZE_F = if (size) |*s| s else null;
        return checkOut(ID2D1Layer, self.vtable.CreateLayer(self, size_ptr, &out), out);
    }

    pub fn drawLine(self: *ID2D1RenderTarget, p0: D2D1_POINT_2F, p1: D2D1_POINT_2F, brush: *ID2D1Brush, stroke_width: f32, style: ?*ID2D1StrokeStyle) void {
        self.vtable.DrawLine(self, p0, p1, brush, stroke_width, style);
    }

    pub fn drawRectangle(self: *ID2D1RenderTarget, rect: D2D1_RECT_F, brush: *ID2D1Brush, stroke_width: f32, style: ?*ID2D1StrokeStyle) void {
        self.vtable.DrawRectangle(self, &rect, brush, stroke_width, style);
    }

    pub fn fillRectangle(self: *ID2D1RenderTarget, rect: D2D1_RECT_F, brush: *ID2D1Brush) void {
        self.vtable.FillRectangle(self, &rect, brush);
    }

    pub fn drawRoundedRectangle(self: *ID2D1RenderTarget, rr: D2D1_ROUNDED_RECT, brush: *ID2D1Brush, stroke_width: f32, style: ?*ID2D1StrokeStyle) void {
        self.vtable.DrawRoundedRectangle(self, &rr, brush, stroke_width, style);
    }

    pub fn fillRoundedRectangle(self: *ID2D1RenderTarget, rr: D2D1_ROUNDED_RECT, brush: *ID2D1Brush) void {
        self.vtable.FillRoundedRectangle(self, &rr, brush);
    }

    pub fn drawEllipse(self: *ID2D1RenderTarget, e: D2D1_ELLIPSE, brush: *ID2D1Brush, stroke_width: f32, style: ?*ID2D1StrokeStyle) void {
        self.vtable.DrawEllipse(self, &e, brush, stroke_width, style);
    }

    pub fn fillEllipse(self: *ID2D1RenderTarget, e: D2D1_ELLIPSE, brush: *ID2D1Brush) void {
        self.vtable.FillEllipse(self, &e, brush);
    }

    pub fn drawGeometry(self: *ID2D1RenderTarget, g: *ID2D1Geometry, brush: *ID2D1Brush, stroke_width: f32, style: ?*ID2D1StrokeStyle) void {
        self.vtable.DrawGeometry(self, g, brush, stroke_width, style);
    }

    pub fn fillGeometry(self: *ID2D1RenderTarget, g: *ID2D1Geometry, brush: *ID2D1Brush, opacity_brush: ?*ID2D1Brush) void {
        self.vtable.FillGeometry(self, g, brush, opacity_brush);
    }

    pub fn drawBitmap(self: *ID2D1RenderTarget, bitmap: *ID2D1Bitmap, dst: ?D2D1_RECT_F, opacity: f32, mode: D2D1_BITMAP_INTERPOLATION_MODE, src: ?D2D1_RECT_F) void {
        const dst_ptr: ?*const D2D1_RECT_F = if (dst) |*r| r else null;
        const src_ptr: ?*const D2D1_RECT_F = if (src) |*r| r else null;
        self.vtable.DrawBitmap(self, bitmap, dst_ptr, opacity, mode, src_ptr);
    }

    /// Lay out and draw UTF-16 `text` in one call (no layout caching).
    pub fn drawText(
        self: *ID2D1RenderTarget,
        text: []const u16,
        format: *dwrite.IDWriteTextFormat,
        rect: D2D1_RECT_F,
        brush: *ID2D1Brush,
        options: D2D1_DRAW_TEXT_OPTIONS,
    ) void {
        const len: u32 = std.math.cast(u32, text.len) orelse return;
        self.vtable.DrawText(self, text.ptr, len, format, &rect, brush, options, .natural);
    }

    pub fn drawTextLayout(self: *ID2D1RenderTarget, origin: D2D1_POINT_2F, layout: *dwrite.IDWriteTextLayout, brush: *ID2D1Brush, options: D2D1_DRAW_TEXT_OPTIONS) void {
        self.vtable.DrawTextLayout(self, origin, layout, brush, options);
    }

    pub fn setTransform(self: *ID2D1RenderTarget, m: D2D1_MATRIX_3X2_F) void {
        self.vtable.SetTransform(self, &m);
    }

    pub fn getTransform(self: *ID2D1RenderTarget) D2D1_MATRIX_3X2_F {
        var m: D2D1_MATRIX_3X2_F = .{};
        self.vtable.GetTransform(self, &m);
        return m;
    }

    pub fn setAntialiasMode(self: *ID2D1RenderTarget, mode: D2D1_ANTIALIAS_MODE) void {
        self.vtable.SetAntialiasMode(self, mode);
    }

    pub fn getAntialiasMode(self: *ID2D1RenderTarget) D2D1_ANTIALIAS_MODE {
        return self.vtable.GetAntialiasMode(self);
    }

    pub fn setTextAntialiasMode(self: *ID2D1RenderTarget, mode: D2D1_TEXT_ANTIALIAS_MODE) void {
        self.vtable.SetTextAntialiasMode(self, mode);
    }

    pub fn getTextAntialiasMode(self: *ID2D1RenderTarget) D2D1_TEXT_ANTIALIAS_MODE {
        return self.vtable.GetTextAntialiasMode(self);
    }

    pub fn setTextRenderingParams(self: *ID2D1RenderTarget, params: ?*dwrite.IDWriteRenderingParams) void {
        self.vtable.SetTextRenderingParams(self, params);
    }

    pub fn pushLayer(self: *ID2D1RenderTarget, params: D2D1_LAYER_PARAMETERS, layer: ?*ID2D1Layer) void {
        self.vtable.PushLayer(self, &params, layer);
    }

    pub fn popLayer(self: *ID2D1RenderTarget) void {
        self.vtable.PopLayer(self);
    }

    pub fn flush(self: *ID2D1RenderTarget) Error!void {
        try check(self.vtable.Flush(self, null, null));
    }

    pub fn pushAxisAlignedClip(self: *ID2D1RenderTarget, rect: D2D1_RECT_F, mode: D2D1_ANTIALIAS_MODE) void {
        self.vtable.PushAxisAlignedClip(self, &rect, mode);
    }

    pub fn popAxisAlignedClip(self: *ID2D1RenderTarget) void {
        self.vtable.PopAxisAlignedClip(self);
    }

    pub fn clear(self: *ID2D1RenderTarget, color: D2D1_COLOR_F) void {
        self.vtable.Clear(self, &color);
    }

    pub fn beginDraw(self: *ID2D1RenderTarget) void {
        self.vtable.BeginDraw(self);
    }

    /// EndDraw as an error (`error.RecreateTarget` on device loss).
    pub fn endDraw(self: *ID2D1RenderTarget) Error!void {
        try check(self.vtable.EndDraw(self, null, null));
    }

    /// EndDraw returning the raw HRESULT (for callers that classify it).
    pub fn endDrawHresult(self: *ID2D1RenderTarget) HRESULT {
        return self.vtable.EndDraw(self, null, null);
    }

    pub fn getPixelFormat(self: *ID2D1RenderTarget) D2D1_PIXEL_FORMAT {
        var out: D2D1_PIXEL_FORMAT = undefined;
        _ = self.vtable.GetPixelFormat(self, &out);
        return out;
    }

    /// Set the DPI used to map DIPs to pixels (96 = 1 DIP per pixel).
    pub fn setDpi(self: *ID2D1RenderTarget, dpi_x: f32, dpi_y: f32) void {
        self.vtable.SetDpi(self, dpi_x, dpi_y);
    }

    pub fn getDpi(self: *ID2D1RenderTarget) struct { x: f32, y: f32 } {
        var x: f32 = 0;
        var y: f32 = 0;
        self.vtable.GetDpi(self, &x, &y);
        return .{ .x = x, .y = y };
    }

    /// Size in DIPs.
    pub fn getSize(self: *ID2D1RenderTarget) D2D1_SIZE_F {
        var out: D2D1_SIZE_F = undefined;
        _ = self.vtable.GetSize(self, &out);
        return out;
    }

    /// Size in device pixels.
    pub fn getPixelSize(self: *ID2D1RenderTarget) D2D1_SIZE_U {
        var out: D2D1_SIZE_U = undefined;
        _ = self.vtable.GetPixelSize(self, &out);
        return out;
    }

    pub fn getMaximumBitmapSize(self: *ID2D1RenderTarget) u32 {
        return self.vtable.GetMaximumBitmapSize(self);
    }

    pub fn isSupported(self: *ID2D1RenderTarget, props: D2D1_RENDER_TARGET_PROPERTIES) bool {
        return self.vtable.IsSupported(self, &props) != com.FALSE;
    }
};

pub const ID2D1BitmapRenderTarget = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2cd90695-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        // 57: GetBitmap(ID2D1Bitmap**)
        GetBitmap: *const fn (*ID2D1BitmapRenderTarget, *?*ID2D1Bitmap) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1BitmapRenderTarget) void {
        com.release(self);
    }

    pub fn renderTarget(self: *ID2D1BitmapRenderTarget) *ID2D1RenderTarget {
        return @ptrCast(self);
    }

    pub fn getBitmap(self: *ID2D1BitmapRenderTarget) Error!*ID2D1Bitmap {
        var out: ?*ID2D1Bitmap = null;
        return checkOut(ID2D1Bitmap, self.vtable.GetBitmap(self, &out), out);
    }
};

pub const ID2D1HwndRenderTarget = extern struct {
    vtable: *const VTable,

    /// Not in the mingw-w64 header; value from the Windows SDK d2d1.h.
    pub const IID = GUID.parse("{2cd90698-12e2-11dc-9fed-001143a055f9}");

    pub const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        // 57: CheckWindowState()
        CheckWindowState: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) D2D1_WINDOW_STATE,
        // 58: Resize(const D2D1_SIZE_U* pixelSize)
        Resize: *const fn (*ID2D1HwndRenderTarget, *const D2D1_SIZE_U) callconv(.winapi) HRESULT,
        // 59: GetHwnd()
        GetHwnd: *const fn (*ID2D1HwndRenderTarget) callconv(.winapi) ?com.HWND,
    };

    pub fn release(self: *ID2D1HwndRenderTarget) void {
        com.release(self);
    }

    pub fn renderTarget(self: *ID2D1HwndRenderTarget) *ID2D1RenderTarget {
        return @ptrCast(self);
    }

    /// True when the window is minimized, hidden or fully covered; skip
    /// drawing (EndDraw would discard the frame anyway).
    pub fn isOccluded(self: *ID2D1HwndRenderTarget) bool {
        return self.vtable.CheckWindowState(self).occluded;
    }

    /// Resize the swap chain to `width` x `height` device pixels.
    pub fn resize(self: *ID2D1HwndRenderTarget, width: u32, height: u32) Error!void {
        const size: D2D1_SIZE_U = .{ .width = width, .height = height };
        try check(self.vtable.Resize(self, &size));
    }

    pub fn getHwnd(self: *ID2D1HwndRenderTarget) ?com.HWND {
        return self.vtable.GetHwnd(self);
    }
};

pub const ID2D1DCRenderTarget = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{1c51bc64-de61-46fd-9899-63a5d8f03950}");

    pub const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        // 57: BindDC(HDC, const RECT* subRect)
        BindDC: *const fn (*ID2D1DCRenderTarget, com.HDC, *const com.RECT) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1DCRenderTarget) void {
        com.release(self);
    }

    pub fn renderTarget(self: *ID2D1DCRenderTarget) *ID2D1RenderTarget {
        return @ptrCast(self);
    }

    /// Bind to `hdc`, drawing into `rect` (device pixels). Rebind on every
    /// paint (and whenever the DC or rectangle changes), before BeginDraw.
    pub fn bindDC(self: *ID2D1DCRenderTarget, hdc: com.HDC, rect: com.RECT) Error!void {
        try check(self.vtable.BindDC(self, hdc, &rect));
    }
};

pub const ID2D1GdiInteropRenderTarget = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e0db51c3-6f77-4bae-b3d5-e47509b35838}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetDC(D2D1_DC_INITIALIZE_MODE, HDC*)
        GetDC: *const fn (*ID2D1GdiInteropRenderTarget, D2D1_DC_INITIALIZE_MODE, *?com.HDC) callconv(.winapi) HRESULT,
        // 4: ReleaseDC(const RECT* update)
        ReleaseDC: *const fn (*ID2D1GdiInteropRenderTarget, ?*const com.RECT) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1GdiInteropRenderTarget) void {
        com.release(self);
    }

    /// A GDI DC onto a target created with `usage.gdi_compatible` (between
    /// BeginDraw and EndDraw). Call `releaseDC` before any other D2D call.
    pub fn getDC(self: *ID2D1GdiInteropRenderTarget, mode: D2D1_DC_INITIALIZE_MODE) Error!com.HDC {
        var out: ?com.HDC = null;
        try check(self.vtable.GetDC(self, mode, &out));
        return out orelse error.Unexpected;
    }

    pub fn releaseDC(self: *ID2D1GdiInteropRenderTarget, update: ?*const com.RECT) Error!void {
        try check(self.vtable.ReleaseDC(self, update));
    }
};

// ─── ID2D1DeviceContext (Direct2D 1.1) ──────────────────────────────────

pub const ID2D1DeviceContext = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e8f7fe7a-191c-466d-ad95-975678bda998}");

    pub const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        // 57: CreateBitmap(D2D1_SIZE_U, const void*, UINT32 pitch, const D2D1_BITMAP_PROPERTIES1*, ID2D1Bitmap1**)
        _57: PadFn,
        // 58: CreateBitmapFromWicBitmap(IWICBitmapSource*, const D2D1_BITMAP_PROPERTIES1*, ID2D1Bitmap1**)
        _58: PadFn,
        // 59: CreateColorContext
        _59: PadFn,
        // 60: CreateColorContextFromFilename
        _60: PadFn,
        // 61: CreateColorContextFromWicColorContext
        _61: PadFn,
        // 62: CreateBitmapFromDxgiSurface
        _62: PadFn,
        // 63: CreateEffect
        _63: PadFn,
        // 64: CreateGradientStopCollection (1.1 overload)
        _64: PadFn,
        // 65: CreateImageBrush
        _65: PadFn,
        // 66: CreateBitmapBrush (1.1 overload)
        _66: PadFn,
        // 67: CreateCommandList
        _67: PadFn,
        // 68: IsDxgiFormatSupported(DXGI_FORMAT)
        IsDxgiFormatSupported: *const fn (*ID2D1DeviceContext, DXGI_FORMAT) callconv(.winapi) BOOL,
        // 69: IsBufferPrecisionSupported(D2D1_BUFFER_PRECISION)
        IsBufferPrecisionSupported: *const fn (*ID2D1DeviceContext, D2D1_BUFFER_PRECISION) callconv(.winapi) BOOL,
        // 70: GetImageLocalBounds(ID2D1Image*, D2D1_RECT_F*)
        GetImageLocalBounds: *const fn (*ID2D1DeviceContext, *ID2D1Image, *D2D1_RECT_F) callconv(.winapi) HRESULT,
        // 71: GetImageWorldBounds(ID2D1Image*, D2D1_RECT_F*)
        GetImageWorldBounds: *const fn (*ID2D1DeviceContext, *ID2D1Image, *D2D1_RECT_F) callconv(.winapi) HRESULT,
        // 72: GetGlyphRunWorldBounds(D2D1_POINT_2F, const DWRITE_GLYPH_RUN*, DWRITE_MEASURING_MODE, D2D1_RECT_F*)
        GetGlyphRunWorldBounds: *const fn (*ID2D1DeviceContext, D2D1_POINT_2F, *const dwrite.DWRITE_GLYPH_RUN, dwrite.DWRITE_MEASURING_MODE, *D2D1_RECT_F) callconv(.winapi) HRESULT,
        // 73: GetDevice(ID2D1Device**)
        GetDevice: *const fn (*ID2D1DeviceContext, *?*ID2D1Device) callconv(.winapi) void,
        // 74: SetTarget(ID2D1Image*)
        SetTarget: *const fn (*ID2D1DeviceContext, ?*ID2D1Image) callconv(.winapi) void,
        // 75: GetTarget(ID2D1Image**)
        GetTarget: *const fn (*ID2D1DeviceContext, *?*ID2D1Image) callconv(.winapi) void,
        // 76: SetRenderingControls(const D2D1_RENDERING_CONTROLS*)
        SetRenderingControls: *const fn (*ID2D1DeviceContext, *const D2D1_RENDERING_CONTROLS) callconv(.winapi) void,
        // 77: GetRenderingControls(D2D1_RENDERING_CONTROLS*)
        GetRenderingControls: *const fn (*ID2D1DeviceContext, *D2D1_RENDERING_CONTROLS) callconv(.winapi) void,
        // 78: SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND)
        SetPrimitiveBlend: *const fn (*ID2D1DeviceContext, D2D1_PRIMITIVE_BLEND) callconv(.winapi) void,
        // 79: GetPrimitiveBlend()
        GetPrimitiveBlend: *const fn (*ID2D1DeviceContext) callconv(.winapi) D2D1_PRIMITIVE_BLEND,
        // 80: SetUnitMode(D2D1_UNIT_MODE)
        SetUnitMode: *const fn (*ID2D1DeviceContext, D2D1_UNIT_MODE) callconv(.winapi) void,
        // 81: GetUnitMode()
        GetUnitMode: *const fn (*ID2D1DeviceContext) callconv(.winapi) D2D1_UNIT_MODE,
        // 82: DrawGlyphRun(D2D1_POINT_2F, const DWRITE_GLYPH_RUN*, const DWRITE_GLYPH_RUN_DESCRIPTION*, ID2D1Brush*, DWRITE_MEASURING_MODE)
        DrawGlyphRun: *const fn (*ID2D1DeviceContext, D2D1_POINT_2F, *const dwrite.DWRITE_GLYPH_RUN, ?*const anyopaque, *ID2D1Brush, dwrite.DWRITE_MEASURING_MODE) callconv(.winapi) void,
        // 83: DrawImage(ID2D1Image*, const D2D1_POINT_2F* targetOffset, const D2D1_RECT_F* imageRect, D2D1_INTERPOLATION_MODE, D2D1_COMPOSITE_MODE)
        DrawImage: *const fn (*ID2D1DeviceContext, *ID2D1Image, ?*const D2D1_POINT_2F, ?*const D2D1_RECT_F, D2D1_INTERPOLATION_MODE, D2D1_COMPOSITE_MODE) callconv(.winapi) void,
        // 84: DrawGdiMetafile
        _84: PadFn,
        // 85: DrawBitmap(ID2D1Bitmap*, const D2D1_RECT_F* dst, FLOAT opacity, D2D1_INTERPOLATION_MODE, const D2D1_RECT_F* src, const D2D1_MATRIX_4X4_F* perspective)
        DrawBitmap: *const fn (*ID2D1DeviceContext, *ID2D1Bitmap, ?*const D2D1_RECT_F, f32, D2D1_INTERPOLATION_MODE, ?*const D2D1_RECT_F, ?*const anyopaque) callconv(.winapi) void,
        // 86: PushLayer(const D2D1_LAYER_PARAMETERS1*, ID2D1Layer*)
        _86: PadFn,
        // 87: InvalidateEffectInputRectangle
        _87: PadFn,
        // 88: GetEffectInvalidRectangleCount
        _88: PadFn,
        // 89: GetEffectInvalidRectangles
        _89: PadFn,
        // 90: GetEffectRequiredInputRectangles
        _90: PadFn,
        // 91: FillOpacityMask(ID2D1Bitmap*, ID2D1Brush*, const D2D1_RECT_F* dst, const D2D1_RECT_F* src)
        FillOpacityMask: *const fn (*ID2D1DeviceContext, *ID2D1Bitmap, *ID2D1Brush, ?*const D2D1_RECT_F, ?*const D2D1_RECT_F) callconv(.winapi) void,
    };

    pub fn release(self: *ID2D1DeviceContext) void {
        com.release(self);
    }

    pub fn renderTarget(self: *ID2D1DeviceContext) *ID2D1RenderTarget {
        return @ptrCast(self);
    }

    pub fn setPrimitiveBlend(self: *ID2D1DeviceContext, blend: D2D1_PRIMITIVE_BLEND) void {
        self.vtable.SetPrimitiveBlend(self, blend);
    }

    pub fn getPrimitiveBlend(self: *ID2D1DeviceContext) D2D1_PRIMITIVE_BLEND {
        return self.vtable.GetPrimitiveBlend(self);
    }

    pub fn setUnitMode(self: *ID2D1DeviceContext, mode: D2D1_UNIT_MODE) void {
        self.vtable.SetUnitMode(self, mode);
    }

    pub fn getUnitMode(self: *ID2D1DeviceContext) D2D1_UNIT_MODE {
        return self.vtable.GetUnitMode(self);
    }

    pub fn isDxgiFormatSupported(self: *ID2D1DeviceContext, format: DXGI_FORMAT) bool {
        return self.vtable.IsDxgiFormatSupported(self, format) != com.FALSE;
    }

    /// DrawBitmap with the 1.1 interpolation modes (e.g. high-quality cubic
    /// for downscaled icons).
    pub fn drawBitmap(self: *ID2D1DeviceContext, bitmap: *ID2D1Bitmap, dst: ?D2D1_RECT_F, opacity: f32, mode: D2D1_INTERPOLATION_MODE, src: ?D2D1_RECT_F) void {
        const dst_ptr: ?*const D2D1_RECT_F = if (dst) |*r| r else null;
        const src_ptr: ?*const D2D1_RECT_F = if (src) |*r| r else null;
        self.vtable.DrawBitmap(self, bitmap, dst_ptr, opacity, mode, src_ptr, null);
    }
};

// ─── Factories ──────────────────────────────────────────────────────────

pub const ID2D1Factory = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{06152247-6f50-465a-9245-118bfd3b6007}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: ReloadSystemMetrics()
        ReloadSystemMetrics: *const fn (*ID2D1Factory) callconv(.winapi) HRESULT,
        // 4: GetDesktopDpi(FLOAT* dpiX, FLOAT* dpiY)
        GetDesktopDpi: *const fn (*ID2D1Factory, *f32, *f32) callconv(.winapi) void,
        // 5: CreateRectangleGeometry(const D2D1_RECT_F*, ID2D1RectangleGeometry**)
        CreateRectangleGeometry: *const fn (*ID2D1Factory, *const D2D1_RECT_F, *?*ID2D1RectangleGeometry) callconv(.winapi) HRESULT,
        // 6: CreateRoundedRectangleGeometry(const D2D1_ROUNDED_RECT*, ID2D1RoundedRectangleGeometry**)
        CreateRoundedRectangleGeometry: *const fn (*ID2D1Factory, *const D2D1_ROUNDED_RECT, *?*ID2D1RoundedRectangleGeometry) callconv(.winapi) HRESULT,
        // 7: CreateEllipseGeometry(const D2D1_ELLIPSE*, ID2D1EllipseGeometry**)
        CreateEllipseGeometry: *const fn (*ID2D1Factory, *const D2D1_ELLIPSE, *?*ID2D1EllipseGeometry) callconv(.winapi) HRESULT,
        // 8: CreateGeometryGroup(D2D1_FILL_MODE, ID2D1Geometry** geometries, UINT32 count, ID2D1GeometryGroup**)
        CreateGeometryGroup: *const fn (*ID2D1Factory, D2D1_FILL_MODE, [*]const *ID2D1Geometry, u32, *?*ID2D1GeometryGroup) callconv(.winapi) HRESULT,
        // 9: CreateTransformedGeometry(ID2D1Geometry*, const D2D1_MATRIX_3X2_F*, ID2D1TransformedGeometry**)
        CreateTransformedGeometry: *const fn (*ID2D1Factory, *ID2D1Geometry, *const D2D1_MATRIX_3X2_F, *?*ID2D1TransformedGeometry) callconv(.winapi) HRESULT,
        // 10: CreatePathGeometry(ID2D1PathGeometry**)
        CreatePathGeometry: *const fn (*ID2D1Factory, *?*ID2D1PathGeometry) callconv(.winapi) HRESULT,
        // 11: CreateStrokeStyle(const D2D1_STROKE_STYLE_PROPERTIES*, const FLOAT* dashes, UINT32 dashesCount, ID2D1StrokeStyle**)
        CreateStrokeStyle: *const fn (*ID2D1Factory, *const D2D1_STROKE_STYLE_PROPERTIES, ?[*]const f32, u32, *?*ID2D1StrokeStyle) callconv(.winapi) HRESULT,
        // 12: CreateDrawingStateBlock(const D2D1_DRAWING_STATE_DESCRIPTION*, IDWriteRenderingParams*, ID2D1DrawingStateBlock**)
        CreateDrawingStateBlock: *const fn (*ID2D1Factory, ?*const D2D1_DRAWING_STATE_DESCRIPTION, ?*dwrite.IDWriteRenderingParams, *?*ID2D1DrawingStateBlock) callconv(.winapi) HRESULT,
        // 13: CreateWicBitmapRenderTarget(IWICBitmap*, const D2D1_RENDER_TARGET_PROPERTIES*, ID2D1RenderTarget**)
        CreateWicBitmapRenderTarget: *const fn (*ID2D1Factory, *wic.IWICBitmap, *const D2D1_RENDER_TARGET_PROPERTIES, *?*ID2D1RenderTarget) callconv(.winapi) HRESULT,
        // 14: CreateHwndRenderTarget(const D2D1_RENDER_TARGET_PROPERTIES*, const D2D1_HWND_RENDER_TARGET_PROPERTIES*, ID2D1HwndRenderTarget**)
        CreateHwndRenderTarget: *const fn (*ID2D1Factory, *const D2D1_RENDER_TARGET_PROPERTIES, *const D2D1_HWND_RENDER_TARGET_PROPERTIES, *?*ID2D1HwndRenderTarget) callconv(.winapi) HRESULT,
        // 15: CreateDxgiSurfaceRenderTarget(IDXGISurface*, const D2D1_RENDER_TARGET_PROPERTIES*, ID2D1RenderTarget**)
        CreateDxgiSurfaceRenderTarget: *const fn (*ID2D1Factory, *anyopaque, *const D2D1_RENDER_TARGET_PROPERTIES, *?*ID2D1RenderTarget) callconv(.winapi) HRESULT,
        // 16: CreateDCRenderTarget(const D2D1_RENDER_TARGET_PROPERTIES*, ID2D1DCRenderTarget**)
        CreateDCRenderTarget: *const fn (*ID2D1Factory, *const D2D1_RENDER_TARGET_PROPERTIES, *?*ID2D1DCRenderTarget) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ID2D1Factory) void {
        com.release(self);
    }

    /// Re-read system DPI and metrics (after WM_SETTINGCHANGE/WM_DISPLAYCHANGE).
    pub fn reloadSystemMetrics(self: *ID2D1Factory) Error!void {
        try check(self.vtable.ReloadSystemMetrics(self));
    }

    pub fn createRectangleGeometry(self: *ID2D1Factory, rect: D2D1_RECT_F) Error!*ID2D1RectangleGeometry {
        var out: ?*ID2D1RectangleGeometry = null;
        return checkOut(ID2D1RectangleGeometry, self.vtable.CreateRectangleGeometry(self, &rect, &out), out);
    }

    pub fn createRoundedRectangleGeometry(self: *ID2D1Factory, rr: D2D1_ROUNDED_RECT) Error!*ID2D1RoundedRectangleGeometry {
        var out: ?*ID2D1RoundedRectangleGeometry = null;
        return checkOut(ID2D1RoundedRectangleGeometry, self.vtable.CreateRoundedRectangleGeometry(self, &rr, &out), out);
    }

    pub fn createEllipseGeometry(self: *ID2D1Factory, e: D2D1_ELLIPSE) Error!*ID2D1EllipseGeometry {
        var out: ?*ID2D1EllipseGeometry = null;
        return checkOut(ID2D1EllipseGeometry, self.vtable.CreateEllipseGeometry(self, &e, &out), out);
    }

    pub fn createGeometryGroup(self: *ID2D1Factory, mode: D2D1_FILL_MODE, geometries: []const *ID2D1Geometry) Error!*ID2D1GeometryGroup {
        const n = std.math.cast(u32, geometries.len) orelse return error.InvalidArg;
        var out: ?*ID2D1GeometryGroup = null;
        return checkOut(ID2D1GeometryGroup, self.vtable.CreateGeometryGroup(self, mode, geometries.ptr, n, &out), out);
    }

    pub fn createTransformedGeometry(self: *ID2D1Factory, src: *ID2D1Geometry, m: D2D1_MATRIX_3X2_F) Error!*ID2D1TransformedGeometry {
        var out: ?*ID2D1TransformedGeometry = null;
        return checkOut(ID2D1TransformedGeometry, self.vtable.CreateTransformedGeometry(self, src, &m, &out), out);
    }

    pub fn createPathGeometry(self: *ID2D1Factory) Error!*ID2D1PathGeometry {
        var out: ?*ID2D1PathGeometry = null;
        return checkOut(ID2D1PathGeometry, self.vtable.CreatePathGeometry(self, &out), out);
    }

    pub fn createStrokeStyle(self: *ID2D1Factory, props: D2D1_STROKE_STYLE_PROPERTIES, dashes: []const f32) Error!*ID2D1StrokeStyle {
        const n = std.math.cast(u32, dashes.len) orelse return error.InvalidArg;
        var out: ?*ID2D1StrokeStyle = null;
        const dash_ptr: ?[*]const f32 = if (n == 0) null else dashes.ptr;
        return checkOut(ID2D1StrokeStyle, self.vtable.CreateStrokeStyle(self, &props, dash_ptr, n, &out), out);
    }

    pub fn createDrawingStateBlock(self: *ID2D1Factory) Error!*ID2D1DrawingStateBlock {
        var out: ?*ID2D1DrawingStateBlock = null;
        return checkOut(ID2D1DrawingStateBlock, self.vtable.CreateDrawingStateBlock(self, null, null, &out), out);
    }

    /// A software render target drawing into `bitmap` (32bpp PBGRA).
    pub fn createWicBitmapRenderTarget(self: *ID2D1Factory, bitmap: *wic.IWICBitmap, props: D2D1_RENDER_TARGET_PROPERTIES) Error!*ID2D1RenderTarget {
        var out: ?*ID2D1RenderTarget = null;
        return checkOut(ID2D1RenderTarget, self.vtable.CreateWicBitmapRenderTarget(self, bitmap, &props, &out), out);
    }

    pub fn createHwndRenderTarget(self: *ID2D1Factory, props: D2D1_RENDER_TARGET_PROPERTIES, hwnd_props: D2D1_HWND_RENDER_TARGET_PROPERTIES) Error!*ID2D1HwndRenderTarget {
        var out: ?*ID2D1HwndRenderTarget = null;
        return checkOut(ID2D1HwndRenderTarget, self.vtable.CreateHwndRenderTarget(self, &props, &hwnd_props, &out), out);
    }

    /// A render target that draws onto a GDI DC (bind it with BindDC).
    /// The pixel format must be B8G8R8A8_UNORM with IGNORE or PREMULTIPLIED.
    pub fn createDCRenderTarget(self: *ID2D1Factory, props: D2D1_RENDER_TARGET_PROPERTIES) Error!*ID2D1DCRenderTarget {
        var out: ?*ID2D1DCRenderTarget = null;
        return checkOut(ID2D1DCRenderTarget, self.vtable.CreateDCRenderTarget(self, &props, &out), out);
    }
};

pub const ID2D1Factory1 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{bb12d362-daee-4b9a-aa1d-14ba401cfa1f}");

    pub const VTable = extern struct {
        base: ID2D1Factory.VTable,
        // 17: CreateDevice(IDXGIDevice*, ID2D1Device**)
        CreateDevice: *const fn (*ID2D1Factory1, *anyopaque, *?*ID2D1Device) callconv(.winapi) HRESULT,
        // 18: CreateStrokeStyle (1.1 overload, D2D1_STROKE_STYLE_PROPERTIES1)
        _18: PadFn,
        // 19: CreatePathGeometry (1.1 overload, ID2D1PathGeometry1)
        _19: PadFn,
        // 20: CreateDrawingStateBlock (1.1 overload)
        _20: PadFn,
        // 21: CreateGdiMetafile
        _21: PadFn,
        // 22: RegisterEffectFromStream
        _22: PadFn,
        // 23: RegisterEffectFromString
        _23: PadFn,
        // 24: UnregisterEffect
        _24: PadFn,
        // 25: GetRegisteredEffects
        _25: PadFn,
        // 26: GetEffectProperties
        _26: PadFn,
    };

    pub fn release(self: *ID2D1Factory1) void {
        com.release(self);
    }

    pub fn factory(self: *ID2D1Factory1) *ID2D1Factory {
        return @ptrCast(self);
    }
};

pub extern "d2d1" fn D2D1CreateFactory(
    factoryType: D2D1_FACTORY_TYPE,
    riid: *const GUID,
    pFactoryOptions: ?*const D2D1_FACTORY_OPTIONS,
    ppIFactory: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// Create a Direct2D factory exposing interface `T` (`ID2D1Factory` or
/// `ID2D1Factory1`). Single-threaded factories are cheaper; use one per UI
/// thread.
pub fn createFactory(comptime T: type, factory_type: D2D1_FACTORY_TYPE, options: D2D1_FACTORY_OPTIONS) Error!*T {
    var out: ?*anyopaque = null;
    try check(D2D1CreateFactory(factory_type, &T.IID, &options, &out));
    const p = out orelse return error.NoInterface;
    return @ptrCast(@alignCast(p));
}

// ─── Tests ──────────────────────────────────────────────────────────────

const slot = com.slotIndex;

test "unit: platform: d2d vtable slots match d2d1.h and d2d1_1.h" {
    const t = std.testing;
    const ptr = @sizeOf(usize);

    try t.expectEqual(@as(usize, 3), slot(ID2D1Resource.VTable, "GetFactory"));
    try t.expectEqual(@as(usize, 4 * ptr), @sizeOf(ID2D1Image.VTable));
    try t.expectEqual(@as(usize, 4), slot(ID2D1Bitmap.VTable, "GetSize"));
    try t.expectEqual(@as(usize, 10), slot(ID2D1Bitmap.VTable, "CopyFromMemory"));

    try t.expectEqual(@as(usize, 7), slot(ID2D1Brush.VTable, "GetTransform"));
    try t.expectEqual(@as(usize, 8), slot(ID2D1SolidColorBrush.VTable, "SetColor"));
    try t.expectEqual(@as(usize, 9), slot(ID2D1SolidColorBrush.VTable, "GetColor"));
    try t.expectEqual(@as(usize, 12), slot(ID2D1LinearGradientBrush.VTable, "GetGradientStopCollection"));
    try t.expectEqual(@as(usize, 16), slot(ID2D1RadialGradientBrush.VTable, "GetGradientStopCollection"));
    try t.expectEqual(@as(usize, 15), slot(ID2D1BitmapBrush.VTable, "GetBitmap"));
    try t.expectEqual(@as(usize, 7), slot(ID2D1GradientStopCollection.VTable, "GetExtendMode"));
    try t.expectEqual(@as(usize, 12), slot(ID2D1StrokeStyle.VTable, "GetDashes"));
    try t.expectEqual(@as(usize, 4), slot(ID2D1Layer.VTable, "GetSize"));
    try t.expectEqual(@as(usize, 7), slot(ID2D1DrawingStateBlock.VTable, "GetTextRenderingParams"));

    try t.expectEqual(@as(usize, 4), slot(ID2D1Geometry.VTable, "GetBounds"));
    try t.expectEqual(@as(usize, 16), slot(ID2D1Geometry.VTable, "Widen"));
    try t.expectEqual(@as(usize, 17), slot(ID2D1RectangleGeometry.VTable, "GetRect"));
    try t.expectEqual(@as(usize, 17), slot(ID2D1RoundedRectangleGeometry.VTable, "GetRoundedRect"));
    try t.expectEqual(@as(usize, 17), slot(ID2D1EllipseGeometry.VTable, "GetEllipse"));
    try t.expectEqual(@as(usize, 19), slot(ID2D1GeometryGroup.VTable, "GetSourceGeometries"));
    try t.expectEqual(@as(usize, 18), slot(ID2D1TransformedGeometry.VTable, "GetTransform"));
    try t.expectEqual(@as(usize, 17), slot(ID2D1PathGeometry.VTable, "Open"));
    try t.expectEqual(@as(usize, 20), slot(ID2D1PathGeometry.VTable, "GetFigureCount"));
    try t.expectEqual(@as(usize, 5), slot(ID2D1SimplifiedGeometrySink.VTable, "BeginFigure"));
    try t.expectEqual(@as(usize, 9), slot(ID2D1SimplifiedGeometrySink.VTable, "Close"));
    try t.expectEqual(@as(usize, 10), slot(ID2D1GeometrySink.VTable, "AddLine"));
    try t.expectEqual(@as(usize, 14), slot(ID2D1GeometrySink.VTable, "AddArc"));
    try t.expectEqual(@as(usize, 4), slot(ID2D1TessellationSink.VTable, "Close"));
    try t.expectEqual(@as(usize, 4), slot(ID2D1Mesh.VTable, "Open"));

    const RT = ID2D1RenderTarget.VTable;
    try t.expectEqual(@as(usize, 4), slot(RT, "CreateBitmap"));
    try t.expectEqual(@as(usize, 8), slot(RT, "CreateSolidColorBrush"));
    try t.expectEqual(@as(usize, 13), slot(RT, "CreateLayer"));
    try t.expectEqual(@as(usize, 15), slot(RT, "DrawLine"));
    try t.expectEqual(@as(usize, 17), slot(RT, "FillRectangle"));
    try t.expectEqual(@as(usize, 19), slot(RT, "FillRoundedRectangle"));
    try t.expectEqual(@as(usize, 22), slot(RT, "DrawGeometry"));
    try t.expectEqual(@as(usize, 27), slot(RT, "DrawText"));
    try t.expectEqual(@as(usize, 28), slot(RT, "DrawTextLayout"));
    try t.expectEqual(@as(usize, 30), slot(RT, "SetTransform"));
    try t.expectEqual(@as(usize, 34), slot(RT, "SetTextAntialiasMode"));
    try t.expectEqual(@as(usize, 40), slot(RT, "PushLayer"));
    try t.expectEqual(@as(usize, 42), slot(RT, "Flush"));
    try t.expectEqual(@as(usize, 45), slot(RT, "PushAxisAlignedClip"));
    try t.expectEqual(@as(usize, 47), slot(RT, "Clear"));
    try t.expectEqual(@as(usize, 48), slot(RT, "BeginDraw"));
    try t.expectEqual(@as(usize, 49), slot(RT, "EndDraw"));
    try t.expectEqual(@as(usize, 51), slot(RT, "SetDpi"));
    try t.expectEqual(@as(usize, 53), slot(RT, "GetSize"));
    try t.expectEqual(@as(usize, 56), slot(RT, "IsSupported"));
    try t.expectEqual(@as(usize, 57 * ptr), @sizeOf(RT));

    try t.expectEqual(@as(usize, 57), slot(ID2D1BitmapRenderTarget.VTable, "GetBitmap"));
    try t.expectEqual(@as(usize, 57), slot(ID2D1HwndRenderTarget.VTable, "CheckWindowState"));
    try t.expectEqual(@as(usize, 58), slot(ID2D1HwndRenderTarget.VTable, "Resize"));
    try t.expectEqual(@as(usize, 59), slot(ID2D1HwndRenderTarget.VTable, "GetHwnd"));
    try t.expectEqual(@as(usize, 57), slot(ID2D1DCRenderTarget.VTable, "BindDC"));
    try t.expectEqual(@as(usize, 4), slot(ID2D1GdiInteropRenderTarget.VTable, "ReleaseDC"));

    const DC = ID2D1DeviceContext.VTable;
    try t.expectEqual(@as(usize, 68), slot(DC, "IsDxgiFormatSupported"));
    try t.expectEqual(@as(usize, 73), slot(DC, "GetDevice"));
    try t.expectEqual(@as(usize, 78), slot(DC, "SetPrimitiveBlend"));
    try t.expectEqual(@as(usize, 80), slot(DC, "SetUnitMode"));
    try t.expectEqual(@as(usize, 83), slot(DC, "DrawImage"));
    try t.expectEqual(@as(usize, 85), slot(DC, "DrawBitmap"));
    try t.expectEqual(@as(usize, 91), slot(DC, "FillOpacityMask"));
    try t.expectEqual(@as(usize, 92 * ptr), @sizeOf(DC));

    try t.expectEqual(@as(usize, 6), slot(ID2D1Factory.VTable, "CreateRoundedRectangleGeometry"));
    try t.expectEqual(@as(usize, 10), slot(ID2D1Factory.VTable, "CreatePathGeometry"));
    try t.expectEqual(@as(usize, 13), slot(ID2D1Factory.VTable, "CreateWicBitmapRenderTarget"));
    try t.expectEqual(@as(usize, 14), slot(ID2D1Factory.VTable, "CreateHwndRenderTarget"));
    try t.expectEqual(@as(usize, 16), slot(ID2D1Factory.VTable, "CreateDCRenderTarget"));
    try t.expectEqual(@as(usize, 17 * ptr), @sizeOf(ID2D1Factory.VTable));
    try t.expectEqual(@as(usize, 17), slot(ID2D1Factory1.VTable, "CreateDevice"));
    try t.expectEqual(@as(usize, 27 * ptr), @sizeOf(ID2D1Factory1.VTable));
}

test "unit: platform: d2d struct layouts match d2d1.h" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 16), @sizeOf(D2D1_COLOR_F));
    try t.expectEqual(@as(usize, 24), @sizeOf(D2D1_MATRIX_3X2_F));
    try t.expectEqual(@as(usize, 24), @sizeOf(D2D1_ROUNDED_RECT));
    try t.expectEqual(@as(usize, 28), @sizeOf(D2D1_RENDER_TARGET_PROPERTIES));
    try t.expectEqual(@as(usize, 24), @sizeOf(D2D1_HWND_RENDER_TARGET_PROPERTIES));
    try t.expectEqual(@as(usize, 72), @sizeOf(D2D1_LAYER_PARAMETERS));
    try t.expectEqual(@as(usize, 16), @offsetOf(D2D1_LAYER_PARAMETERS, "geometricMask"));
    try t.expectEqual(@as(usize, 56), @offsetOf(D2D1_LAYER_PARAMETERS, "opacityBrush"));
    try t.expectEqual(@as(usize, 28), @sizeOf(D2D1_STROKE_STYLE_PROPERTIES));
    try t.expectEqual(@as(usize, 28), @sizeOf(D2D1_BRUSH_PROPERTIES));
    try t.expectEqual(@as(usize, 28), @sizeOf(D2D1_ARC_SEGMENT));
    try t.expectEqual(@as(usize, 48), @sizeOf(D2D1_DRAWING_STATE_DESCRIPTION));
    try t.expectEqual(@as(u32, 4), @as(u32, @bitCast(D2D1_DRAW_TEXT_OPTIONS{ .enable_color_font = true })));
    try t.expectEqual(@as(u32, 2), @as(u32, @bitCast(D2D1_RENDER_TARGET_USAGE{ .gdi_compatible = true })));
}

test "unit: platform: d2d matrix helpers" {
    const t = std.testing;
    const M = D2D1_MATRIX_3X2_F;
    const p: D2D1_POINT_2F = .{ .x = 3, .y = 4 };

    const moved = M.translation(10, -2).transformPoint(p);
    try t.expectEqual(@as(f32, 13), moved.x);
    try t.expectEqual(@as(f32, 2), moved.y);

    // 90 degrees clockwise around the origin maps +x to +y (y points down).
    const r = M.rotation(90, .{}).transformPoint(.{ .x = 1, .y = 0 });
    try t.expectApproxEqAbs(@as(f32, 0), r.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 1), r.y, 1e-5);

    // Rotation keeps its center fixed.
    const c: D2D1_POINT_2F = .{ .x = 5, .y = 7 };
    const fixed = M.rotation(37, c).transformPoint(c);
    try t.expectApproxEqAbs(c.x, fixed.x, 1e-4);
    try t.expectApproxEqAbs(c.y, fixed.y, 1e-4);

    // Scale about a center, then translate: multiply applies left first.
    const m = M.multiply(M.scale(2, 2, .{ .x = 1, .y = 1 }), M.translation(1, 0));
    const q = m.transformPoint(p);
    try t.expectEqual(@as(f32, 6), q.x);
    try t.expectEqual(@as(f32, 7), q.y);
}

test "unit: platform: d2d wrappers type-check" {
    std.testing.refAllDeclsRecursive(@This());
}
