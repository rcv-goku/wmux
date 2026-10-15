//! Windows Imaging Component bindings (wincodec.h): in-memory bitmaps that
//! Direct2D renders into (headless rendering, tests, screenshots), pixel
//! readback, format conversion, PNG encoding and image decoding.
//!
//! Conventions (nested vtables, `// N:` slot indices, ownership, `Error`) are
//! described in `com.zig`. Slot orders follow the flat widl vtables in the
//! mingw-w64 `wincodec.h` shipped with Zig and are pinned by the tests at the
//! bottom.
//!
//! The imaging factory is created with CoCreateInstance, so the calling
//! thread must have COM initialized (`com.initThread`).
//!
//! Self-contained: imports only `std` and `com.zig`.
const std = @import("std");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const PadFn = com.PadFn;
const Error = com.Error;
const check = com.check;
const checkOut = com.checkOut;

// ─── GUIDs ──────────────────────────────────────────────────────────────

/// Implements IWICImagingFactory on every supported Windows version.
pub const CLSID_WICImagingFactory = GUID.parse("{cacaf262-9370-4615-a13b-9f5539da4c0a}");
/// Windows 8+ factory (also implements IWICImagingFactory2).
pub const CLSID_WICImagingFactory2 = GUID.parse("{317d06e8-5f24-433d-bdf7-79ce68d8abc2}");

pub const WICPixelFormatGUID = GUID;
pub const GUID_WICPixelFormat32bppBGR = GUID.parse("{6fddc324-4e03-4bfe-b185-3d77768dc90e}");
pub const GUID_WICPixelFormat32bppBGRA = GUID.parse("{6fddc324-4e03-4bfe-b185-3d77768dc90f}");
/// Premultiplied BGRA: the format Direct2D renders into (DXGI_FORMAT_B8G8R8A8_UNORM
/// + D2D1_ALPHA_MODE_PREMULTIPLIED).
pub const GUID_WICPixelFormat32bppPBGRA = GUID.parse("{6fddc324-4e03-4bfe-b185-3d77768dc910}");
pub const GUID_WICPixelFormat32bppPRGBA = GUID.parse("{3cc4a650-a527-4d37-a916-3142c7ebedba}");

pub const GUID_ContainerFormatPng = GUID.parse("{1b7cfaf4-713f-473c-bbcd-6137425faeaf}");
pub const GUID_ContainerFormatBmp = GUID.parse("{0af1d87e-fcfe-4188-bdeb-a7906471cbe3}");

/// Access flags for IWICStream.InitializeFromFilename and
/// IWICImagingFactory.CreateDecoderFromFilename.
pub const GENERIC_READ: u32 = 0x80000000;
pub const GENERIC_WRITE: u32 = 0x40000000;

// ─── Enums and structs ──────────────────────────────────────────────────

pub const WICRect = extern struct {
    X: i32,
    Y: i32,
    Width: i32,
    Height: i32,
};

pub const WICBitmapCreateCacheOption = enum(u32) {
    no_cache = 0,
    cache_on_demand = 1,
    cache_on_load = 2,
};

pub const WICBitmapEncoderCacheOption = enum(u32) {
    in_memory = 0,
    temp_file = 1,
    no_cache = 2,
};

pub const WICBitmapLockFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    _reserved: u30 = 0,
};

pub const WICDecodeOptions = enum(u32) {
    metadata_cache_on_demand = 0,
    metadata_cache_on_load = 1,
};

pub const WICBitmapDitherType = enum(u32) {
    none = 0,
    ordered4x4 = 1,
    ordered8x8 = 2,
    ordered16x16 = 3,
    spiral4x4 = 4,
    spiral8x8 = 5,
    dual_spiral4x4 = 6,
    dual_spiral8x8 = 7,
    error_diffusion = 8,
    _,
};

pub const WICBitmapPaletteType = enum(u32) {
    custom = 0,
    median_cut = 1,
    fixed_bw = 2,
    _,
};

pub const WICBitmapAlphaChannelOption = enum(u32) {
    use_alpha = 0,
    use_premultiplied_alpha = 1,
    ignore_alpha = 2,
};

pub const WICBitmapInterpolationMode = enum(u32) {
    nearest_neighbor = 0,
    linear = 1,
    cubic = 2,
    fant = 3,
    high_quality_cubic = 4,
};

// ─── Unbound interfaces ─────────────────────────────────────────────────

/// An interface this file does not call beyond IUnknown; keeps pointers
/// typed and releasable.
fn Unbound(comptime iid: []const u8) type {
    return extern struct {
        vtable: *const com.IUnknown.VTable,

        pub const IID = GUID.parse(iid);

        pub fn release(self: *@This()) void {
            com.release(self);
        }
    };
}

pub const IWICPalette = Unbound("{00000040-a8f2-4877-ba0a-fd2b6645fb94}");
pub const IWICColorContext = Unbound("{3c613a02-34b2-44ea-9a7c-45aea9c6fd6d}");
pub const IWICColorTransform = Unbound("{b66f034f-d0e2-40ab-b436-6de39e321a94}");
pub const IWICComponentInfo = Unbound("{23bc3f0a-698b-4357-886b-f24d50671334}");
pub const IWICBitmapScaler = Unbound("{00000302-a8f2-4877-ba0a-fd2b6645fb94}");
pub const IWICBitmapClipper = Unbound("{e4fbcf03-223d-4e81-9333-d635556dd1b5}");
pub const IWICBitmapFlipRotator = Unbound("{5009834f-2d6a-41ce-9e1b-17c5aff7a782}");
pub const IWICFastMetadataEncoder = Unbound("{b84e2c09-78c9-4ac4-8bd3-524ae1663a2f}");
pub const IWICMetadataQueryReader = Unbound("{30989668-e1c9-4597-b395-458eedb808df}");
pub const IWICMetadataQueryWriter = Unbound("{a721791a-0def-4d06-bd91-2118bf1db10b}");
pub const IWICBitmapEncoderInfo = Unbound("{94c9b4ee-a09f-4f92-8a1e-4a9bce7e76fb}");
pub const IWICBitmapDecoderInfo = Unbound("{d8cd007f-d08f-4191-9bfc-236ea7f0e4b5}");
/// Encoder options bag returned by CreateNewFrame (pass it back or null).
pub const IPropertyBag2 = Unbound("{22f55882-280b-11d0-a8a9-00a0c90c2004}");
pub const IEnumUnknown = Unbound("{00000100-0000-0000-C000-000000000046}");

// ─── IWICBitmapSource ───────────────────────────────────────────────────

pub const IWICBitmapSource = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000120-a8f2-4877-ba0a-fd2b6645fb94}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetSize(UINT* width, UINT* height)
        GetSize: *const fn (*IWICBitmapSource, *u32, *u32) callconv(.winapi) HRESULT,
        // 4: GetPixelFormat(WICPixelFormatGUID*)
        GetPixelFormat: *const fn (*IWICBitmapSource, *WICPixelFormatGUID) callconv(.winapi) HRESULT,
        // 5: GetResolution(double* dpiX, double* dpiY)
        GetResolution: *const fn (*IWICBitmapSource, *f64, *f64) callconv(.winapi) HRESULT,
        // 6: CopyPalette(IWICPalette*)
        CopyPalette: *const fn (*IWICBitmapSource, *IWICPalette) callconv(.winapi) HRESULT,
        // 7: CopyPixels(const WICRect*, UINT stride, UINT bufferSize, BYTE* buffer)
        CopyPixels: *const fn (*IWICBitmapSource, ?*const WICRect, u32, u32, [*]u8) callconv(.winapi) HRESULT,
    };

    pub const Size = struct { width: u32, height: u32 };

    pub fn release(self: *IWICBitmapSource) void {
        com.release(self);
    }

    pub fn getSize(self: *IWICBitmapSource) Error!Size {
        var w: u32 = 0;
        var h: u32 = 0;
        try check(self.vtable.GetSize(self, &w, &h));
        return .{ .width = w, .height = h };
    }

    pub fn getPixelFormat(self: *IWICBitmapSource) Error!WICPixelFormatGUID {
        var g: WICPixelFormatGUID = undefined;
        try check(self.vtable.GetPixelFormat(self, &g));
        return g;
    }

    pub fn getResolution(self: *IWICBitmapSource) Error!struct { x: f64, y: f64 } {
        var x: f64 = 0;
        var y: f64 = 0;
        try check(self.vtable.GetResolution(self, &x, &y));
        return .{ .x = x, .y = y };
    }

    /// Copy pixels of `rect` (null = whole image) into `buf` with `stride`
    /// bytes per row.
    pub fn copyPixels(self: *IWICBitmapSource, rect: ?*const WICRect, stride: u32, buf: []u8) Error!void {
        const len = std.math.cast(u32, buf.len) orelse return error.InvalidArg;
        try check(self.vtable.CopyPixels(self, rect, stride, len, buf.ptr));
    }
};

// ─── IWICBitmap ─────────────────────────────────────────────────────────

pub const IWICBitmap = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000121-a8f2-4877-ba0a-fd2b6645fb94}");

    pub const VTable = extern struct {
        base: IWICBitmapSource.VTable,
        // 8: Lock(const WICRect*, DWORD flags, IWICBitmapLock**)
        Lock: *const fn (*IWICBitmap, ?*const WICRect, WICBitmapLockFlags, *?*IWICBitmapLock) callconv(.winapi) HRESULT,
        // 9: SetPalette(IWICPalette*)
        SetPalette: *const fn (*IWICBitmap, *IWICPalette) callconv(.winapi) HRESULT,
        // 10: SetResolution(double dpiX, double dpiY)
        SetResolution: *const fn (*IWICBitmap, f64, f64) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmap) void {
        com.release(self);
    }

    pub fn source(self: *IWICBitmap) *IWICBitmapSource {
        return @ptrCast(self);
    }

    /// Lock `rect` (null = whole bitmap) for direct access. Release the lock
    /// before rendering into or encoding the bitmap again.
    pub fn lock(self: *IWICBitmap, rect: ?*const WICRect, flags: WICBitmapLockFlags) Error!*IWICBitmapLock {
        var out: ?*IWICBitmapLock = null;
        return checkOut(IWICBitmapLock, self.vtable.Lock(self, rect, flags, &out), out);
    }

    pub fn setResolution(self: *IWICBitmap, dpi_x: f64, dpi_y: f64) Error!void {
        try check(self.vtable.SetResolution(self, dpi_x, dpi_y));
    }
};

pub const IWICBitmapLock = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000123-a8f2-4877-ba0a-fd2b6645fb94}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetSize(UINT* width, UINT* height)
        GetSize: *const fn (*IWICBitmapLock, *u32, *u32) callconv(.winapi) HRESULT,
        // 4: GetStride(UINT*)
        GetStride: *const fn (*IWICBitmapLock, *u32) callconv(.winapi) HRESULT,
        // 5: GetDataPointer(UINT* bufferSize, BYTE** data)
        GetDataPointer: *const fn (*IWICBitmapLock, *u32, *?[*]u8) callconv(.winapi) HRESULT,
        // 6: GetPixelFormat(WICPixelFormatGUID*)
        GetPixelFormat: *const fn (*IWICBitmapLock, *WICPixelFormatGUID) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmapLock) void {
        com.release(self);
    }

    pub fn getStride(self: *IWICBitmapLock) Error!u32 {
        var stride: u32 = 0;
        try check(self.vtable.GetStride(self, &stride));
        return stride;
    }

    /// The locked pixels; valid until the lock is released.
    pub fn getData(self: *IWICBitmapLock) Error![]u8 {
        var size: u32 = 0;
        var ptr: ?[*]u8 = null;
        try check(self.vtable.GetDataPointer(self, &size, &ptr));
        const p = ptr orelse return error.Unexpected;
        return p[0..size];
    }
};

// ─── IWICFormatConverter ────────────────────────────────────────────────

pub const IWICFormatConverter = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000301-a8f2-4877-ba0a-fd2b6645fb94}");

    pub const VTable = extern struct {
        base: IWICBitmapSource.VTable,
        // 8: Initialize(IWICBitmapSource*, REFWICPixelFormatGUID dstFormat, WICBitmapDitherType, IWICPalette*, double alphaThresholdPercent, WICBitmapPaletteType)
        Initialize: *const fn (*IWICFormatConverter, *IWICBitmapSource, *const WICPixelFormatGUID, WICBitmapDitherType, ?*IWICPalette, f64, WICBitmapPaletteType) callconv(.winapi) HRESULT,
        // 9: CanConvert(REFWICPixelFormatGUID src, REFWICPixelFormatGUID dst, BOOL*)
        CanConvert: *const fn (*IWICFormatConverter, *const WICPixelFormatGUID, *const WICPixelFormatGUID, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICFormatConverter) void {
        com.release(self);
    }

    pub fn source(self: *IWICFormatConverter) *IWICBitmapSource {
        return @ptrCast(self);
    }

    pub fn initialize(self: *IWICFormatConverter, src: *IWICBitmapSource, dst_format: *const WICPixelFormatGUID) Error!void {
        try check(self.vtable.Initialize(self, src, dst_format, .none, null, 0.0, .custom));
    }
};

// ─── Encoding ───────────────────────────────────────────────────────────

pub const IWICBitmapEncoder = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000103-a8f2-4877-ba0a-fd2b6645fb94}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: Initialize(IStream*, WICBitmapEncoderCacheOption)
        Initialize: *const fn (*IWICBitmapEncoder, *com.IStream, WICBitmapEncoderCacheOption) callconv(.winapi) HRESULT,
        // 4: GetContainerFormat(GUID*)
        GetContainerFormat: *const fn (*IWICBitmapEncoder, *GUID) callconv(.winapi) HRESULT,
        // 5: GetEncoderInfo(IWICBitmapEncoderInfo**)
        GetEncoderInfo: *const fn (*IWICBitmapEncoder, *?*IWICBitmapEncoderInfo) callconv(.winapi) HRESULT,
        // 6: SetColorContexts(UINT count, IWICColorContext**)
        SetColorContexts: *const fn (*IWICBitmapEncoder, u32, [*]const *IWICColorContext) callconv(.winapi) HRESULT,
        // 7: SetPalette(IWICPalette*)
        SetPalette: *const fn (*IWICBitmapEncoder, *IWICPalette) callconv(.winapi) HRESULT,
        // 8: SetThumbnail(IWICBitmapSource*)
        SetThumbnail: *const fn (*IWICBitmapEncoder, *IWICBitmapSource) callconv(.winapi) HRESULT,
        // 9: SetPreview(IWICBitmapSource*)
        SetPreview: *const fn (*IWICBitmapEncoder, *IWICBitmapSource) callconv(.winapi) HRESULT,
        // 10: CreateNewFrame(IWICBitmapFrameEncode**, IPropertyBag2** encoderOptions)
        CreateNewFrame: *const fn (*IWICBitmapEncoder, *?*IWICBitmapFrameEncode, ?*?*IPropertyBag2) callconv(.winapi) HRESULT,
        // 11: Commit()
        Commit: *const fn (*IWICBitmapEncoder) callconv(.winapi) HRESULT,
        // 12: GetMetadataQueryWriter(IWICMetadataQueryWriter**)
        GetMetadataQueryWriter: *const fn (*IWICBitmapEncoder, *?*IWICMetadataQueryWriter) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmapEncoder) void {
        com.release(self);
    }

    pub fn initialize(self: *IWICBitmapEncoder, stream: *com.IStream, cache: WICBitmapEncoderCacheOption) Error!void {
        try check(self.vtable.Initialize(self, stream, cache));
    }

    /// A new frame plus its encoder options bag (pass the bag to
    /// `IWICBitmapFrameEncode.initialize`, then release both).
    pub fn createNewFrame(self: *IWICBitmapEncoder) Error!struct { frame: *IWICBitmapFrameEncode, options: ?*IPropertyBag2 } {
        var frame: ?*IWICBitmapFrameEncode = null;
        var options: ?*IPropertyBag2 = null;
        const f = try checkOut(IWICBitmapFrameEncode, self.vtable.CreateNewFrame(self, &frame, &options), frame);
        return .{ .frame = f, .options = options };
    }

    pub fn commit(self: *IWICBitmapEncoder) Error!void {
        try check(self.vtable.Commit(self));
    }
};

pub const IWICBitmapFrameEncode = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000105-a8f2-4877-ba0a-fd2b6645fb94}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: Initialize(IPropertyBag2* encoderOptions)
        Initialize: *const fn (*IWICBitmapFrameEncode, ?*IPropertyBag2) callconv(.winapi) HRESULT,
        // 4: SetSize(UINT width, UINT height)
        SetSize: *const fn (*IWICBitmapFrameEncode, u32, u32) callconv(.winapi) HRESULT,
        // 5: SetResolution(double dpiX, double dpiY)
        SetResolution: *const fn (*IWICBitmapFrameEncode, f64, f64) callconv(.winapi) HRESULT,
        // 6: SetPixelFormat(WICPixelFormatGUID* in/out)
        SetPixelFormat: *const fn (*IWICBitmapFrameEncode, *WICPixelFormatGUID) callconv(.winapi) HRESULT,
        // 7: SetColorContexts(UINT count, IWICColorContext**)
        SetColorContexts: *const fn (*IWICBitmapFrameEncode, u32, [*]const *IWICColorContext) callconv(.winapi) HRESULT,
        // 8: SetPalette(IWICPalette*)
        SetPalette: *const fn (*IWICBitmapFrameEncode, *IWICPalette) callconv(.winapi) HRESULT,
        // 9: SetThumbnail(IWICBitmapSource*)
        SetThumbnail: *const fn (*IWICBitmapFrameEncode, *IWICBitmapSource) callconv(.winapi) HRESULT,
        // 10: WritePixels(UINT lineCount, UINT stride, UINT bufferSize, BYTE* pixels)
        WritePixels: *const fn (*IWICBitmapFrameEncode, u32, u32, u32, [*]const u8) callconv(.winapi) HRESULT,
        // 11: WriteSource(IWICBitmapSource*, WICRect*)
        WriteSource: *const fn (*IWICBitmapFrameEncode, *IWICBitmapSource, ?*WICRect) callconv(.winapi) HRESULT,
        // 12: Commit()
        Commit: *const fn (*IWICBitmapFrameEncode) callconv(.winapi) HRESULT,
        // 13: GetMetadataQueryWriter(IWICMetadataQueryWriter**)
        GetMetadataQueryWriter: *const fn (*IWICBitmapFrameEncode, *?*IWICMetadataQueryWriter) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmapFrameEncode) void {
        com.release(self);
    }

    pub fn initialize(self: *IWICBitmapFrameEncode, options: ?*IPropertyBag2) Error!void {
        try check(self.vtable.Initialize(self, options));
    }

    pub fn setSize(self: *IWICBitmapFrameEncode, width: u32, height: u32) Error!void {
        try check(self.vtable.SetSize(self, width, height));
    }

    pub fn setResolution(self: *IWICBitmapFrameEncode, dpi_x: f64, dpi_y: f64) Error!void {
        try check(self.vtable.SetResolution(self, dpi_x, dpi_y));
    }

    /// Request `format`; returns the format the encoder will actually write.
    pub fn setPixelFormat(self: *IWICBitmapFrameEncode, format: WICPixelFormatGUID) Error!WICPixelFormatGUID {
        var f = format;
        try check(self.vtable.SetPixelFormat(self, &f));
        return f;
    }

    pub fn writeSource(self: *IWICBitmapFrameEncode, src: *IWICBitmapSource) Error!void {
        try check(self.vtable.WriteSource(self, src, null));
    }

    pub fn writePixels(self: *IWICBitmapFrameEncode, line_count: u32, stride: u32, pixels: []const u8) Error!void {
        const len = std.math.cast(u32, pixels.len) orelse return error.InvalidArg;
        try check(self.vtable.WritePixels(self, line_count, stride, len, pixels.ptr));
    }

    pub fn commit(self: *IWICBitmapFrameEncode) Error!void {
        try check(self.vtable.Commit(self));
    }
};

// ─── Decoding ───────────────────────────────────────────────────────────

pub const IWICBitmapDecoder = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{9edde9e7-8dee-47ea-99df-e6faf2ed44bf}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: QueryCapability(IStream*, DWORD* capability)
        QueryCapability: *const fn (*IWICBitmapDecoder, *com.IStream, *u32) callconv(.winapi) HRESULT,
        // 4: Initialize(IStream*, WICDecodeOptions)
        Initialize: *const fn (*IWICBitmapDecoder, *com.IStream, WICDecodeOptions) callconv(.winapi) HRESULT,
        // 5: GetContainerFormat(GUID*)
        GetContainerFormat: *const fn (*IWICBitmapDecoder, *GUID) callconv(.winapi) HRESULT,
        // 6: GetDecoderInfo(IWICBitmapDecoderInfo**)
        GetDecoderInfo: *const fn (*IWICBitmapDecoder, *?*IWICBitmapDecoderInfo) callconv(.winapi) HRESULT,
        // 7: CopyPalette(IWICPalette*)
        CopyPalette: *const fn (*IWICBitmapDecoder, *IWICPalette) callconv(.winapi) HRESULT,
        // 8: GetMetadataQueryReader(IWICMetadataQueryReader**)
        GetMetadataQueryReader: *const fn (*IWICBitmapDecoder, *?*IWICMetadataQueryReader) callconv(.winapi) HRESULT,
        // 9: GetPreview(IWICBitmapSource**)
        GetPreview: *const fn (*IWICBitmapDecoder, *?*IWICBitmapSource) callconv(.winapi) HRESULT,
        // 10: GetColorContexts(UINT count, IWICColorContext**, UINT* actualCount)
        GetColorContexts: *const fn (*IWICBitmapDecoder, u32, ?[*]?*IWICColorContext, *u32) callconv(.winapi) HRESULT,
        // 11: GetThumbnail(IWICBitmapSource**)
        GetThumbnail: *const fn (*IWICBitmapDecoder, *?*IWICBitmapSource) callconv(.winapi) HRESULT,
        // 12: GetFrameCount(UINT*)
        GetFrameCount: *const fn (*IWICBitmapDecoder, *u32) callconv(.winapi) HRESULT,
        // 13: GetFrame(UINT index, IWICBitmapFrameDecode**)
        GetFrame: *const fn (*IWICBitmapDecoder, u32, *?*IWICBitmapFrameDecode) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmapDecoder) void {
        com.release(self);
    }

    pub fn getFrameCount(self: *IWICBitmapDecoder) Error!u32 {
        var n: u32 = 0;
        try check(self.vtable.GetFrameCount(self, &n));
        return n;
    }

    pub fn getFrame(self: *IWICBitmapDecoder, index: u32) Error!*IWICBitmapFrameDecode {
        var out: ?*IWICBitmapFrameDecode = null;
        return checkOut(IWICBitmapFrameDecode, self.vtable.GetFrame(self, index, &out), out);
    }
};

pub const IWICBitmapFrameDecode = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{3b16811b-6a43-4ec9-a813-3d930c13b940}");

    pub const VTable = extern struct {
        base: IWICBitmapSource.VTable,
        // 8: GetMetadataQueryReader(IWICMetadataQueryReader**)
        GetMetadataQueryReader: *const fn (*IWICBitmapFrameDecode, *?*IWICMetadataQueryReader) callconv(.winapi) HRESULT,
        // 9: GetColorContexts(UINT count, IWICColorContext**, UINT* actualCount)
        GetColorContexts: *const fn (*IWICBitmapFrameDecode, u32, ?[*]?*IWICColorContext, *u32) callconv(.winapi) HRESULT,
        // 10: GetThumbnail(IWICBitmapSource**)
        GetThumbnail: *const fn (*IWICBitmapFrameDecode, *?*IWICBitmapSource) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICBitmapFrameDecode) void {
        com.release(self);
    }

    pub fn source(self: *IWICBitmapFrameDecode) *IWICBitmapSource {
        return @ptrCast(self);
    }
};

// ─── IWICStream ─────────────────────────────────────────────────────────

pub const IWICStream = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{135ff860-22b7-4ddf-b0f6-218f4f299a43}");

    pub const VTable = extern struct {
        base: com.IStream.VTable,
        // 14: InitializeFromIStream(IStream*)
        InitializeFromIStream: *const fn (*IWICStream, *com.IStream) callconv(.winapi) HRESULT,
        // 15: InitializeFromFilename(LPCWSTR, DWORD desiredAccess)
        InitializeFromFilename: *const fn (*IWICStream, com.LPCWSTR, u32) callconv(.winapi) HRESULT,
        // 16: InitializeFromMemory(BYTE* buffer, DWORD size)
        InitializeFromMemory: *const fn (*IWICStream, [*]u8, u32) callconv(.winapi) HRESULT,
        // 17: InitializeFromIStreamRegion(IStream*, ULARGE_INTEGER offset, ULARGE_INTEGER maxSize)
        InitializeFromIStreamRegion: *const fn (*IWICStream, *com.IStream, u64, u64) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICStream) void {
        com.release(self);
    }

    pub fn stream(self: *IWICStream) *com.IStream {
        return @ptrCast(self);
    }

    /// Open `path` (UTF-16, NUL-terminated) with GENERIC_READ/GENERIC_WRITE.
    pub fn initializeFromFilename(self: *IWICStream, path: com.LPCWSTR, access: u32) Error!void {
        try check(self.vtable.InitializeFromFilename(self, path, access));
    }

    /// Wrap a fixed caller-owned buffer.
    pub fn initializeFromMemory(self: *IWICStream, buf: []u8) Error!void {
        const len = std.math.cast(u32, buf.len) orelse return error.InvalidArg;
        try check(self.vtable.InitializeFromMemory(self, buf.ptr, len));
    }
};

// ─── IWICImagingFactory ─────────────────────────────────────────────────

pub const IWICImagingFactory = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{ec5ec8a9-c395-4314-9c77-54d7a935ff70}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: CreateDecoderFromFilename(LPCWSTR, const GUID* vendor, DWORD access, WICDecodeOptions, IWICBitmapDecoder**)
        CreateDecoderFromFilename: *const fn (*IWICImagingFactory, com.LPCWSTR, ?*const GUID, u32, WICDecodeOptions, *?*IWICBitmapDecoder) callconv(.winapi) HRESULT,
        // 4: CreateDecoderFromStream(IStream*, const GUID* vendor, WICDecodeOptions, IWICBitmapDecoder**)
        CreateDecoderFromStream: *const fn (*IWICImagingFactory, *com.IStream, ?*const GUID, WICDecodeOptions, *?*IWICBitmapDecoder) callconv(.winapi) HRESULT,
        // 5: CreateDecoderFromFileHandle(ULONG_PTR file, const GUID* vendor, WICDecodeOptions, IWICBitmapDecoder**)
        CreateDecoderFromFileHandle: *const fn (*IWICImagingFactory, usize, ?*const GUID, WICDecodeOptions, *?*IWICBitmapDecoder) callconv(.winapi) HRESULT,
        // 6: CreateComponentInfo(REFCLSID, IWICComponentInfo**)
        CreateComponentInfo: *const fn (*IWICImagingFactory, *const GUID, *?*IWICComponentInfo) callconv(.winapi) HRESULT,
        // 7: CreateDecoder(REFGUID containerFormat, const GUID* vendor, IWICBitmapDecoder**)
        CreateDecoder: *const fn (*IWICImagingFactory, *const GUID, ?*const GUID, *?*IWICBitmapDecoder) callconv(.winapi) HRESULT,
        // 8: CreateEncoder(REFGUID containerFormat, const GUID* vendor, IWICBitmapEncoder**)
        CreateEncoder: *const fn (*IWICImagingFactory, *const GUID, ?*const GUID, *?*IWICBitmapEncoder) callconv(.winapi) HRESULT,
        // 9: CreatePalette(IWICPalette**)
        CreatePalette: *const fn (*IWICImagingFactory, *?*IWICPalette) callconv(.winapi) HRESULT,
        // 10: CreateFormatConverter(IWICFormatConverter**)
        CreateFormatConverter: *const fn (*IWICImagingFactory, *?*IWICFormatConverter) callconv(.winapi) HRESULT,
        // 11: CreateBitmapScaler(IWICBitmapScaler**)
        CreateBitmapScaler: *const fn (*IWICImagingFactory, *?*IWICBitmapScaler) callconv(.winapi) HRESULT,
        // 12: CreateBitmapClipper(IWICBitmapClipper**)
        CreateBitmapClipper: *const fn (*IWICImagingFactory, *?*IWICBitmapClipper) callconv(.winapi) HRESULT,
        // 13: CreateBitmapFlipRotator(IWICBitmapFlipRotator**)
        CreateBitmapFlipRotator: *const fn (*IWICImagingFactory, *?*IWICBitmapFlipRotator) callconv(.winapi) HRESULT,
        // 14: CreateStream(IWICStream**)
        CreateStream: *const fn (*IWICImagingFactory, *?*IWICStream) callconv(.winapi) HRESULT,
        // 15: CreateColorContext(IWICColorContext**)
        CreateColorContext: *const fn (*IWICImagingFactory, *?*IWICColorContext) callconv(.winapi) HRESULT,
        // 16: CreateColorTransformer(IWICColorTransform**)
        CreateColorTransformer: *const fn (*IWICImagingFactory, *?*IWICColorTransform) callconv(.winapi) HRESULT,
        // 17: CreateBitmap(UINT width, UINT height, REFWICPixelFormatGUID, WICBitmapCreateCacheOption, IWICBitmap**)
        CreateBitmap: *const fn (*IWICImagingFactory, u32, u32, *const WICPixelFormatGUID, WICBitmapCreateCacheOption, *?*IWICBitmap) callconv(.winapi) HRESULT,
        // 18: CreateBitmapFromSource(IWICBitmapSource*, WICBitmapCreateCacheOption, IWICBitmap**)
        CreateBitmapFromSource: *const fn (*IWICImagingFactory, *IWICBitmapSource, WICBitmapCreateCacheOption, *?*IWICBitmap) callconv(.winapi) HRESULT,
        // 19: CreateBitmapFromSourceRect(IWICBitmapSource*, UINT x, UINT y, UINT width, UINT height, IWICBitmap**)
        CreateBitmapFromSourceRect: *const fn (*IWICImagingFactory, *IWICBitmapSource, u32, u32, u32, u32, *?*IWICBitmap) callconv(.winapi) HRESULT,
        // 20: CreateBitmapFromMemory(UINT width, UINT height, REFWICPixelFormatGUID, UINT stride, UINT bufferSize, BYTE* buffer, IWICBitmap**)
        CreateBitmapFromMemory: *const fn (*IWICImagingFactory, u32, u32, *const WICPixelFormatGUID, u32, u32, [*]const u8, *?*IWICBitmap) callconv(.winapi) HRESULT,
        // 21: CreateBitmapFromHBITMAP(HBITMAP, HPALETTE, WICBitmapAlphaChannelOption, IWICBitmap**)
        CreateBitmapFromHBITMAP: *const fn (*IWICImagingFactory, com.HBITMAP, ?com.HPALETTE, WICBitmapAlphaChannelOption, *?*IWICBitmap) callconv(.winapi) HRESULT,
        // 22: CreateBitmapFromHICON(HICON, IWICBitmap**)
        CreateBitmapFromHICON: *const fn (*IWICImagingFactory, com.HICON, *?*IWICBitmap) callconv(.winapi) HRESULT,
        // 23: CreateComponentEnumerator(DWORD componentTypes, DWORD options, IEnumUnknown**)
        CreateComponentEnumerator: *const fn (*IWICImagingFactory, u32, u32, *?*IEnumUnknown) callconv(.winapi) HRESULT,
        // 24: CreateFastMetadataEncoderFromDecoder(IWICBitmapDecoder*, IWICFastMetadataEncoder**)
        CreateFastMetadataEncoderFromDecoder: *const fn (*IWICImagingFactory, *IWICBitmapDecoder, *?*IWICFastMetadataEncoder) callconv(.winapi) HRESULT,
        // 25: CreateFastMetadataEncoderFromFrameDecode(IWICBitmapFrameDecode*, IWICFastMetadataEncoder**)
        CreateFastMetadataEncoderFromFrameDecode: *const fn (*IWICImagingFactory, *IWICBitmapFrameDecode, *?*IWICFastMetadataEncoder) callconv(.winapi) HRESULT,
        // 26: CreateQueryWriter(REFGUID metadataFormat, const GUID* vendor, IWICMetadataQueryWriter**)
        CreateQueryWriter: *const fn (*IWICImagingFactory, *const GUID, ?*const GUID, *?*IWICMetadataQueryWriter) callconv(.winapi) HRESULT,
        // 27: CreateQueryWriterFromReader(IWICMetadataQueryReader*, const GUID* vendor, IWICMetadataQueryWriter**)
        CreateQueryWriterFromReader: *const fn (*IWICImagingFactory, *IWICMetadataQueryReader, ?*const GUID, *?*IWICMetadataQueryWriter) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IWICImagingFactory) void {
        com.release(self);
    }

    /// A zero-initialized bitmap owned by WIC (`.cache_on_load` allocates the
    /// pixels up front).
    pub fn createBitmap(
        self: *IWICImagingFactory,
        width: u32,
        height: u32,
        format: *const WICPixelFormatGUID,
        cache: WICBitmapCreateCacheOption,
    ) Error!*IWICBitmap {
        var out: ?*IWICBitmap = null;
        return checkOut(IWICBitmap, self.vtable.CreateBitmap(self, width, height, format, cache, &out), out);
    }

    /// A bitmap holding a copy of `pixels`.
    pub fn createBitmapFromMemory(
        self: *IWICImagingFactory,
        width: u32,
        height: u32,
        format: *const WICPixelFormatGUID,
        stride: u32,
        pixels: []const u8,
    ) Error!*IWICBitmap {
        const len = std.math.cast(u32, pixels.len) orelse return error.InvalidArg;
        var out: ?*IWICBitmap = null;
        return checkOut(IWICBitmap, self.vtable.CreateBitmapFromMemory(self, width, height, format, stride, len, pixels.ptr, &out), out);
    }

    pub fn createEncoder(self: *IWICImagingFactory, container: *const GUID) Error!*IWICBitmapEncoder {
        var out: ?*IWICBitmapEncoder = null;
        return checkOut(IWICBitmapEncoder, self.vtable.CreateEncoder(self, container, null, &out), out);
    }

    pub fn createFormatConverter(self: *IWICImagingFactory) Error!*IWICFormatConverter {
        var out: ?*IWICFormatConverter = null;
        return checkOut(IWICFormatConverter, self.vtable.CreateFormatConverter(self, &out), out);
    }

    pub fn createStream(self: *IWICImagingFactory) Error!*IWICStream {
        var out: ?*IWICStream = null;
        return checkOut(IWICStream, self.vtable.CreateStream(self, &out), out);
    }

    pub fn createDecoderFromStream(self: *IWICImagingFactory, stream: *com.IStream) Error!*IWICBitmapDecoder {
        var out: ?*IWICBitmapDecoder = null;
        return checkOut(IWICBitmapDecoder, self.vtable.CreateDecoderFromStream(self, stream, null, .metadata_cache_on_demand, &out), out);
    }

    pub fn createDecoderFromFilename(self: *IWICImagingFactory, path: com.LPCWSTR) Error!*IWICBitmapDecoder {
        var out: ?*IWICBitmapDecoder = null;
        return checkOut(IWICBitmapDecoder, self.vtable.CreateDecoderFromFilename(self, path, null, GENERIC_READ, .metadata_cache_on_demand, &out), out);
    }
};

/// Create the imaging factory (needs COM on this thread).
pub fn createImagingFactory() Error!*IWICImagingFactory {
    return com.createInstance(IWICImagingFactory, &CLSID_WICImagingFactory);
}

/// Encode `src` as PNG (straight-alpha BGRA) into `stream`. Premultiplied
/// sources (Direct2D output) are converted first so translucent pixels keep
/// their colors.
pub fn encodePng(factory: *IWICImagingFactory, src: *IWICBitmapSource, stream: *com.IStream) Error!void {
    const size = try src.getSize();

    const converter = try factory.createFormatConverter();
    defer converter.release();
    try converter.initialize(src, &GUID_WICPixelFormat32bppBGRA);

    const encoder = try factory.createEncoder(&GUID_ContainerFormatPng);
    defer encoder.release();
    try encoder.initialize(stream, .no_cache);

    const created = try encoder.createNewFrame();
    defer created.frame.release();
    defer if (created.options) |o| o.release();
    try created.frame.initialize(created.options);
    try created.frame.setSize(size.width, size.height);
    _ = try created.frame.setPixelFormat(GUID_WICPixelFormat32bppBGRA);
    try created.frame.writeSource(converter.source());
    try created.frame.commit();
    try encoder.commit();
}

// ─── Tests ──────────────────────────────────────────────────────────────

const slot = com.slotIndex;

test "unit: platform: wic vtable slots match wincodec.h" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 7), slot(IWICBitmapSource.VTable, "CopyPixels"));
    try t.expectEqual(@as(usize, 8), slot(IWICBitmap.VTable, "Lock"));
    try t.expectEqual(@as(usize, 10), slot(IWICBitmap.VTable, "SetResolution"));
    try t.expectEqual(@as(usize, 11 * @sizeOf(usize)), @sizeOf(IWICBitmap.VTable));
    try t.expectEqual(@as(usize, 5), slot(IWICBitmapLock.VTable, "GetDataPointer"));
    try t.expectEqual(@as(usize, 9), slot(IWICFormatConverter.VTable, "CanConvert"));
    try t.expectEqual(@as(usize, 10), slot(IWICBitmapEncoder.VTable, "CreateNewFrame"));
    try t.expectEqual(@as(usize, 12), slot(IWICBitmapEncoder.VTable, "GetMetadataQueryWriter"));
    try t.expectEqual(@as(usize, 11), slot(IWICBitmapFrameEncode.VTable, "WriteSource"));
    try t.expectEqual(@as(usize, 13), slot(IWICBitmapFrameEncode.VTable, "GetMetadataQueryWriter"));
    try t.expectEqual(@as(usize, 13), slot(IWICBitmapDecoder.VTable, "GetFrame"));
    try t.expectEqual(@as(usize, 10), slot(IWICBitmapFrameDecode.VTable, "GetThumbnail"));
    try t.expectEqual(@as(usize, 15), slot(IWICStream.VTable, "InitializeFromFilename"));
    try t.expectEqual(@as(usize, 18 * @sizeOf(usize)), @sizeOf(IWICStream.VTable));
    try t.expectEqual(@as(usize, 10), slot(IWICImagingFactory.VTable, "CreateFormatConverter"));
    try t.expectEqual(@as(usize, 14), slot(IWICImagingFactory.VTable, "CreateStream"));
    try t.expectEqual(@as(usize, 17), slot(IWICImagingFactory.VTable, "CreateBitmap"));
    try t.expectEqual(@as(usize, 20), slot(IWICImagingFactory.VTable, "CreateBitmapFromMemory"));
    try t.expectEqual(@as(usize, 28 * @sizeOf(usize)), @sizeOf(IWICImagingFactory.VTable));
    try t.expectEqual(@as(usize, 16), @sizeOf(WICRect));
}

test "unit: platform: wic wrappers type-check" {
    std.testing.refAllDeclsRecursive(@This());
}
