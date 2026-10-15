//! DirectWrite bindings (dwrite.h) for the Direct2D sidebar, palette and tab
//! bars (ARCHITECTURE ADR-11): factory, system font collection, fonts and
//! families, text formats, and text layouts with metrics, hit testing and
//! trimming with an ellipsis sign.
//!
//! Conventions (nested vtables, `// N:` slot indices, ownership, `Error`) are
//! described in `com.zig`. Slot orders follow the flat widl vtables in the
//! mingw-w64 `dwrite.h` shipped with Zig and are pinned by the tests at the
//! bottom. Interfaces wmux does not call are declared with IUnknown-only
//! tables (`Unbound`) so their pointers stay typed.
//!
//! All positions and lengths are UTF-16 code units (DirectWrite's unit);
//! `ui/gfx/logic/utf16_map.zig` converts from UTF-8 byte offsets.
//!
//! Self-contained: imports only `std` and `com.zig`.
const std = @import("std");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const WCHAR = com.WCHAR;
const PadFn = com.PadFn;
const Error = com.Error;
const check = com.check;
const checkOut = com.checkOut;

// ─── Enums ──────────────────────────────────────────────────────────────

pub const DWRITE_FACTORY_TYPE = enum(u32) { shared = 0, isolated = 1 };

pub const DWRITE_FONT_WEIGHT = enum(u32) {
    thin = 100,
    extra_light = 200,
    light = 300,
    semi_light = 350,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    extra_black = 950,
    _,
};

pub const DWRITE_FONT_STYLE = enum(u32) { normal = 0, oblique = 1, italic = 2 };

pub const DWRITE_FONT_STRETCH = enum(u32) {
    undefined = 0,
    ultra_condensed = 1,
    extra_condensed = 2,
    condensed = 3,
    semi_condensed = 4,
    normal = 5,
    semi_expanded = 6,
    expanded = 7,
    extra_expanded = 8,
    ultra_expanded = 9,
};

pub const DWRITE_TEXT_ALIGNMENT = enum(u32) { leading = 0, trailing = 1, center = 2, justified = 3 };

pub const DWRITE_PARAGRAPH_ALIGNMENT = enum(u32) { near = 0, far = 1, center = 2 };

/// `emergency_break`, `whole_word` and `character` need Windows 8.1+.
pub const DWRITE_WORD_WRAPPING = enum(u32) {
    wrap = 0,
    no_wrap = 1,
    emergency_break = 2,
    whole_word = 3,
    character = 4,
};

pub const DWRITE_READING_DIRECTION = enum(u32) {
    left_to_right = 0,
    right_to_left = 1,
    top_to_bottom = 2,
    bottom_to_top = 3,
};

pub const DWRITE_FLOW_DIRECTION = enum(u32) {
    top_to_bottom = 0,
    bottom_to_top = 1,
    left_to_right = 2,
    right_to_left = 3,
};

pub const DWRITE_TRIMMING_GRANULARITY = enum(u32) { none = 0, character = 1, word = 2 };

pub const DWRITE_LINE_SPACING_METHOD = enum(u32) { default = 0, uniform = 1, proportional = 2 };

/// Declared in dcommon.h; shared with Direct2D.
pub const DWRITE_MEASURING_MODE = enum(u32) { natural = 0, gdi_classic = 1, gdi_natural = 2 };

pub const DWRITE_FONT_SIMULATIONS = packed struct(u32) {
    bold: bool = false,
    oblique: bool = false,
    _reserved: u30 = 0,
};

pub const DWRITE_BREAK_CONDITION = enum(u32) {
    neutral = 0,
    can_break = 1,
    may_not_break = 2,
    must_break = 3,
};

pub const DWRITE_PIXEL_GEOMETRY = enum(u32) { flat = 0, rgb = 1, bgr = 2 };

pub const DWRITE_RENDERING_MODE = enum(u32) {
    default = 0,
    aliased = 1,
    gdi_classic = 2,
    gdi_natural = 3,
    natural = 4,
    natural_symmetric = 5,
    outline = 6,
};

pub const DWRITE_INFORMATIONAL_STRING_ID = enum(u32) {
    none = 0,
    copyright_notice = 1,
    version_strings = 2,
    trademark = 3,
    manufacturer = 4,
    designer = 5,
    designer_url = 6,
    description = 7,
    font_vendor_url = 8,
    license_description = 9,
    license_info_url = 10,
    win32_family_names = 11,
    win32_subfamily_names = 12,
    typographic_family_names = 13,
    typographic_subfamily_names = 14,
    sample_text = 15,
    full_name = 16,
    postscript_name = 17,
    postscript_cid_name = 18,
    weight_stretch_style_family_name = 19,
    design_script_language_tag = 20,
    supported_script_language_tag = 21,
    _,
};

pub const DWRITE_FONT_FACE_TYPE = enum(u32) {
    cff = 0,
    truetype = 1,
    opentype_collection = 2,
    type1 = 3,
    vector = 4,
    bitmap = 5,
    unknown = 6,
    raw_cff = 7,
};

pub const DWRITE_NUMBER_SUBSTITUTION_METHOD = enum(u32) {
    from_culture = 0,
    contextual = 1,
    none = 2,
    national = 3,
    traditional = 4,
};

pub const DWRITE_TEXTURE_TYPE = enum(u32) { aliased_1x1 = 0, cleartype_3x1 = 1 };

// ─── Structs ────────────────────────────────────────────────────────────

pub const DWRITE_TRIMMING = extern struct {
    granularity: DWRITE_TRIMMING_GRANULARITY = .none,
    /// Code point that marks where trimming starts preserving text (e.g. '\\'
    /// keeps the file name of a path visible); 0 = none.
    delimiter: u32 = 0,
    delimiterCount: u32 = 0,
};

pub const DWRITE_TEXT_RANGE = extern struct {
    startPosition: u32,
    length: u32,

    /// The whole text (DirectWrite clamps the length).
    pub const all: DWRITE_TEXT_RANGE = .{ .startPosition = 0, .length = std.math.maxInt(u32) };
};

pub const DWRITE_TEXT_METRICS = extern struct {
    left: f32,
    top: f32,
    /// Width of the formatted text, ignoring trailing whitespace.
    width: f32,
    widthIncludingTrailingWhitespace: f32,
    height: f32,
    layoutWidth: f32,
    layoutHeight: f32,
    maxBidiReorderingDepth: u32,
    lineCount: u32,
};

pub const DWRITE_LINE_METRICS = extern struct {
    length: u32,
    trailingWhitespaceLength: u32,
    newlineLength: u32,
    height: f32,
    baseline: f32,
    isTrimmed: BOOL,
};

pub const DWRITE_CLUSTER_METRICS = extern struct {
    width: f32,
    length: u16,
    flags: Flags,

    pub const Flags = packed struct(u16) {
        canWrapLineAfter: bool,
        isWhitespace: bool,
        isNewline: bool,
        isSoftHyphen: bool,
        isRightToLeft: bool,
        padding: u11,
    };
};

pub const DWRITE_HIT_TEST_METRICS = extern struct {
    textPosition: u32,
    length: u32,
    left: f32,
    top: f32,
    width: f32,
    height: f32,
    bidiLevel: u32,
    isText: BOOL,
    isTrimmed: BOOL,
};

pub const DWRITE_OVERHANG_METRICS = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

pub const DWRITE_INLINE_OBJECT_METRICS = extern struct {
    width: f32,
    height: f32,
    baseline: f32,
    supportsSideways: BOOL,
};

pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: f32,
    ascenderOffset: f32,
};

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: ?*IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: ?[*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: u32,
};

pub const DWRITE_MATRIX = extern struct {
    m11: f32 = 1,
    m12: f32 = 0,
    m21: f32 = 0,
    m22: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,
};

pub const DWRITE_FONT_FEATURE = extern struct {
    /// OpenType feature tag, e.g. `fontFeatureTag("tnum")`.
    nameTag: u32,
    parameter: u32,
};

/// DWRITE_MAKE_OPENTYPE_TAG: four ASCII characters, first one in the low byte.
pub fn fontFeatureTag(comptime tag: *const [4]u8) u32 {
    return std.mem.readInt(u32, tag, .little);
}

/// GDI LOGFONTW (wingdi.h), used by IDWriteGdiInterop.
pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]WCHAR = [_]WCHAR{0} ** 32,
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

pub const IDWriteFontFileStream = Unbound("{6d4865fe-0ab8-4d91-8f62-5dd6be34a3e0}");
pub const IDWriteFontFileLoader = Unbound("{727cad4e-d6af-4c9e-8a08-d695b11caa49}");
pub const IDWriteFontFile = Unbound("{739d886a-cef5-47dc-8769-1a8b41bebbb0}");
pub const IDWriteFontCollectionLoader = Unbound("{cca920e4-52f0-492b-bfa8-29c72ee0a468}");
pub const IDWritePixelSnapping = Unbound("{eaf3a2da-ecf4-4d24-b644-b34f6842024b}");
/// Implemented by callers of IDWriteTextLayout::Draw (custom renderers).
pub const IDWriteTextRenderer = Unbound("{ef8a8135-5cc6-45fe-8825-c5a0724eb819}");
pub const IDWriteBitmapRenderTarget = Unbound("{5e5a32a3-8dff-4773-9ff6-0696eab77267}");
pub const IDWriteNumberSubstitution = Unbound("{14885cc9-bab0-4f90-b6ed-5c366a2cd03d}");
pub const IDWriteTextAnalyzer = Unbound("{b7e6163e-7f46-43b4-84b3-e4e6249c365d}");
pub const IDWriteGlyphRunAnalysis = Unbound("{7d97dbf7-e085-42d4-81e3-6a883bded118}");
/// Geometry sink for IDWriteFontFace::GetGlyphRunOutline (an
/// ID2D1SimplifiedGeometrySink is accepted here).
pub const IDWriteGeometrySink = Unbound("{2cd9069e-12e2-11dc-9fed-001143a055f9}");

// ─── IDWriteFactory ─────────────────────────────────────────────────────

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{b859ee5a-d838-4b5b-a2e8-1adc7d93db48}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetSystemFontCollection(IDWriteFontCollection**, BOOL checkForUpdates)
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(.winapi) HRESULT,
        // 4: CreateCustomFontCollection(IDWriteFontCollectionLoader*, const void* key, UINT32 keySize, IDWriteFontCollection**)
        CreateCustomFontCollection: *const fn (*IDWriteFactory, *IDWriteFontCollectionLoader, ?*const anyopaque, u32, *?*IDWriteFontCollection) callconv(.winapi) HRESULT,
        // 5: RegisterFontCollectionLoader(IDWriteFontCollectionLoader*)
        RegisterFontCollectionLoader: *const fn (*IDWriteFactory, *IDWriteFontCollectionLoader) callconv(.winapi) HRESULT,
        // 6: UnregisterFontCollectionLoader(IDWriteFontCollectionLoader*)
        UnregisterFontCollectionLoader: *const fn (*IDWriteFactory, *IDWriteFontCollectionLoader) callconv(.winapi) HRESULT,
        // 7: CreateFontFileReference(const WCHAR* path, const FILETIME* lastWriteTime, IDWriteFontFile**)
        CreateFontFileReference: *const fn (*IDWriteFactory, [*:0]const WCHAR, ?*const com.FILETIME, *?*IDWriteFontFile) callconv(.winapi) HRESULT,
        // 8: CreateCustomFontFileReference(const void* key, UINT32 keySize, IDWriteFontFileLoader*, IDWriteFontFile**)
        CreateCustomFontFileReference: *const fn (*IDWriteFactory, ?*const anyopaque, u32, *IDWriteFontFileLoader, *?*IDWriteFontFile) callconv(.winapi) HRESULT,
        // 9: CreateFontFace(DWRITE_FONT_FACE_TYPE, UINT32 numberOfFiles, IDWriteFontFile* const* fontFiles, UINT32 faceIndex, DWRITE_FONT_SIMULATIONS, IDWriteFontFace**)
        CreateFontFace: *const fn (*IDWriteFactory, DWRITE_FONT_FACE_TYPE, u32, [*]const *IDWriteFontFile, u32, DWRITE_FONT_SIMULATIONS, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
        // 10: CreateRenderingParams(IDWriteRenderingParams**)
        CreateRenderingParams: *const fn (*IDWriteFactory, *?*IDWriteRenderingParams) callconv(.winapi) HRESULT,
        // 11: CreateMonitorRenderingParams(HMONITOR, IDWriteRenderingParams**)
        CreateMonitorRenderingParams: *const fn (*IDWriteFactory, com.HMONITOR, *?*IDWriteRenderingParams) callconv(.winapi) HRESULT,
        // 12: CreateCustomRenderingParams(FLOAT gamma, FLOAT enhancedContrast, FLOAT clearTypeLevel, DWRITE_PIXEL_GEOMETRY, DWRITE_RENDERING_MODE, IDWriteRenderingParams**)
        CreateCustomRenderingParams: *const fn (*IDWriteFactory, f32, f32, f32, DWRITE_PIXEL_GEOMETRY, DWRITE_RENDERING_MODE, *?*IDWriteRenderingParams) callconv(.winapi) HRESULT,
        // 13: RegisterFontFileLoader(IDWriteFontFileLoader*)
        RegisterFontFileLoader: *const fn (*IDWriteFactory, *IDWriteFontFileLoader) callconv(.winapi) HRESULT,
        // 14: UnregisterFontFileLoader(IDWriteFontFileLoader*)
        UnregisterFontFileLoader: *const fn (*IDWriteFactory, *IDWriteFontFileLoader) callconv(.winapi) HRESULT,
        // 15: CreateTextFormat(const WCHAR* family, IDWriteFontCollection*, DWRITE_FONT_WEIGHT, DWRITE_FONT_STYLE, DWRITE_FONT_STRETCH, FLOAT size, const WCHAR* locale, IDWriteTextFormat**)
        CreateTextFormat: *const fn (*IDWriteFactory, [*:0]const WCHAR, ?*IDWriteFontCollection, DWRITE_FONT_WEIGHT, DWRITE_FONT_STYLE, DWRITE_FONT_STRETCH, f32, [*:0]const WCHAR, *?*IDWriteTextFormat) callconv(.winapi) HRESULT,
        // 16: CreateTypography(IDWriteTypography**)
        CreateTypography: *const fn (*IDWriteFactory, *?*IDWriteTypography) callconv(.winapi) HRESULT,
        // 17: GetGdiInterop(IDWriteGdiInterop**)
        GetGdiInterop: *const fn (*IDWriteFactory, *?*IDWriteGdiInterop) callconv(.winapi) HRESULT,
        // 18: CreateTextLayout(const WCHAR* string, UINT32 length, IDWriteTextFormat*, FLOAT maxWidth, FLOAT maxHeight, IDWriteTextLayout**)
        CreateTextLayout: *const fn (*IDWriteFactory, [*]const WCHAR, u32, *IDWriteTextFormat, f32, f32, *?*IDWriteTextLayout) callconv(.winapi) HRESULT,
        // 19: CreateGdiCompatibleTextLayout(const WCHAR*, UINT32, IDWriteTextFormat*, FLOAT layoutWidth, FLOAT layoutHeight, FLOAT pixelsPerDip, const DWRITE_MATRIX*, BOOL useGdiNatural, IDWriteTextLayout**)
        CreateGdiCompatibleTextLayout: *const fn (*IDWriteFactory, [*]const WCHAR, u32, *IDWriteTextFormat, f32, f32, f32, ?*const DWRITE_MATRIX, BOOL, *?*IDWriteTextLayout) callconv(.winapi) HRESULT,
        // 20: CreateEllipsisTrimmingSign(IDWriteTextFormat*, IDWriteInlineObject**)
        CreateEllipsisTrimmingSign: *const fn (*IDWriteFactory, *IDWriteTextFormat, *?*IDWriteInlineObject) callconv(.winapi) HRESULT,
        // 21: CreateTextAnalyzer(IDWriteTextAnalyzer**)
        CreateTextAnalyzer: *const fn (*IDWriteFactory, *?*IDWriteTextAnalyzer) callconv(.winapi) HRESULT,
        // 22: CreateNumberSubstitution(DWRITE_NUMBER_SUBSTITUTION_METHOD, const WCHAR* locale, BOOL ignoreUserOverride, IDWriteNumberSubstitution**)
        CreateNumberSubstitution: *const fn (*IDWriteFactory, DWRITE_NUMBER_SUBSTITUTION_METHOD, [*:0]const WCHAR, BOOL, *?*IDWriteNumberSubstitution) callconv(.winapi) HRESULT,
        // 23: CreateGlyphRunAnalysis(const DWRITE_GLYPH_RUN*, FLOAT pixelsPerDip, const DWRITE_MATRIX*, DWRITE_RENDERING_MODE, DWRITE_MEASURING_MODE, FLOAT baselineOriginX, FLOAT baselineOriginY, IDWriteGlyphRunAnalysis**)
        CreateGlyphRunAnalysis: *const fn (*IDWriteFactory, *const DWRITE_GLYPH_RUN, f32, ?*const DWRITE_MATRIX, DWRITE_RENDERING_MODE, DWRITE_MEASURING_MODE, f32, f32, *?*IDWriteGlyphRunAnalysis) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFactory) void {
        com.release(self);
    }

    pub fn getSystemFontCollection(self: *IDWriteFactory, check_for_updates: bool) Error!*IDWriteFontCollection {
        var out: ?*IDWriteFontCollection = null;
        return checkOut(IDWriteFontCollection, self.vtable.GetSystemFontCollection(self, &out, com.boolToWin(check_for_updates)), out);
    }

    /// `collection` null = system fonts. `size` is in DIPs.
    pub fn createTextFormat(
        self: *IDWriteFactory,
        family: [*:0]const WCHAR,
        collection: ?*IDWriteFontCollection,
        weight: DWRITE_FONT_WEIGHT,
        style: DWRITE_FONT_STYLE,
        stretch: DWRITE_FONT_STRETCH,
        size: f32,
        locale: [*:0]const WCHAR,
    ) Error!*IDWriteTextFormat {
        var out: ?*IDWriteTextFormat = null;
        return checkOut(IDWriteTextFormat, self.vtable.CreateTextFormat(self, family, collection, weight, style, stretch, size, locale, &out), out);
    }

    /// `text` is UTF-16 (need not be NUL-terminated).
    pub fn createTextLayout(
        self: *IDWriteFactory,
        text: []const WCHAR,
        format: *IDWriteTextFormat,
        max_width: f32,
        max_height: f32,
    ) Error!*IDWriteTextLayout {
        const len = std.math.cast(u32, text.len) orelse return error.InvalidArg;
        var out: ?*IDWriteTextLayout = null;
        return checkOut(IDWriteTextLayout, self.vtable.CreateTextLayout(self, text.ptr, len, format, max_width, max_height, &out), out);
    }

    pub fn createGdiCompatibleTextLayout(
        self: *IDWriteFactory,
        text: []const WCHAR,
        format: *IDWriteTextFormat,
        width: f32,
        height: f32,
        pixels_per_dip: f32,
        use_gdi_natural: bool,
    ) Error!*IDWriteTextLayout {
        const len = std.math.cast(u32, text.len) orelse return error.InvalidArg;
        var out: ?*IDWriteTextLayout = null;
        return checkOut(IDWriteTextLayout, self.vtable.CreateGdiCompatibleTextLayout(
            self,
            text.ptr,
            len,
            format,
            width,
            height,
            pixels_per_dip,
            null,
            com.boolToWin(use_gdi_natural),
            &out,
        ), out);
    }

    /// The "…" inline object used with `IDWriteTextFormat.setTrimming`; it
    /// draws with `format`'s font, so create one per format.
    pub fn createEllipsisTrimmingSign(self: *IDWriteFactory, format: *IDWriteTextFormat) Error!*IDWriteInlineObject {
        var out: ?*IDWriteInlineObject = null;
        return checkOut(IDWriteInlineObject, self.vtable.CreateEllipsisTrimmingSign(self, format, &out), out);
    }

    pub fn createTypography(self: *IDWriteFactory) Error!*IDWriteTypography {
        var out: ?*IDWriteTypography = null;
        return checkOut(IDWriteTypography, self.vtable.CreateTypography(self, &out), out);
    }

    pub fn createRenderingParams(self: *IDWriteFactory) Error!*IDWriteRenderingParams {
        var out: ?*IDWriteRenderingParams = null;
        return checkOut(IDWriteRenderingParams, self.vtable.CreateRenderingParams(self, &out), out);
    }

    pub fn createMonitorRenderingParams(self: *IDWriteFactory, monitor: com.HMONITOR) Error!*IDWriteRenderingParams {
        var out: ?*IDWriteRenderingParams = null;
        return checkOut(IDWriteRenderingParams, self.vtable.CreateMonitorRenderingParams(self, monitor, &out), out);
    }

    pub fn createCustomRenderingParams(
        self: *IDWriteFactory,
        gamma: f32,
        enhanced_contrast: f32,
        cleartype_level: f32,
        geometry: DWRITE_PIXEL_GEOMETRY,
        mode: DWRITE_RENDERING_MODE,
    ) Error!*IDWriteRenderingParams {
        var out: ?*IDWriteRenderingParams = null;
        return checkOut(IDWriteRenderingParams, self.vtable.CreateCustomRenderingParams(self, gamma, enhanced_contrast, cleartype_level, geometry, mode, &out), out);
    }

    pub fn getGdiInterop(self: *IDWriteFactory) Error!*IDWriteGdiInterop {
        var out: ?*IDWriteGdiInterop = null;
        return checkOut(IDWriteGdiInterop, self.vtable.GetGdiInterop(self, &out), out);
    }
};

// ─── IDWriteTextFormat ──────────────────────────────────────────────────

pub const IDWriteTextFormat = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{9c906818-31d7-4fd3-a151-7c5e225db55a}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: SetTextAlignment(DWRITE_TEXT_ALIGNMENT)
        SetTextAlignment: *const fn (*IDWriteTextFormat, DWRITE_TEXT_ALIGNMENT) callconv(.winapi) HRESULT,
        // 4: SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT)
        SetParagraphAlignment: *const fn (*IDWriteTextFormat, DWRITE_PARAGRAPH_ALIGNMENT) callconv(.winapi) HRESULT,
        // 5: SetWordWrapping(DWRITE_WORD_WRAPPING)
        SetWordWrapping: *const fn (*IDWriteTextFormat, DWRITE_WORD_WRAPPING) callconv(.winapi) HRESULT,
        // 6: SetReadingDirection(DWRITE_READING_DIRECTION)
        SetReadingDirection: *const fn (*IDWriteTextFormat, DWRITE_READING_DIRECTION) callconv(.winapi) HRESULT,
        // 7: SetFlowDirection(DWRITE_FLOW_DIRECTION)
        SetFlowDirection: *const fn (*IDWriteTextFormat, DWRITE_FLOW_DIRECTION) callconv(.winapi) HRESULT,
        // 8: SetIncrementalTabStop(FLOAT)
        SetIncrementalTabStop: *const fn (*IDWriteTextFormat, f32) callconv(.winapi) HRESULT,
        // 9: SetTrimming(const DWRITE_TRIMMING*, IDWriteInlineObject* trimmingSign)
        SetTrimming: *const fn (*IDWriteTextFormat, *const DWRITE_TRIMMING, ?*IDWriteInlineObject) callconv(.winapi) HRESULT,
        // 10: SetLineSpacing(DWRITE_LINE_SPACING_METHOD, FLOAT lineSpacing, FLOAT baseline)
        SetLineSpacing: *const fn (*IDWriteTextFormat, DWRITE_LINE_SPACING_METHOD, f32, f32) callconv(.winapi) HRESULT,
        // 11: GetTextAlignment()
        GetTextAlignment: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_TEXT_ALIGNMENT,
        // 12: GetParagraphAlignment()
        GetParagraphAlignment: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_PARAGRAPH_ALIGNMENT,
        // 13: GetWordWrapping()
        GetWordWrapping: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_WORD_WRAPPING,
        // 14: GetReadingDirection()
        GetReadingDirection: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_READING_DIRECTION,
        // 15: GetFlowDirection()
        GetFlowDirection: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_FLOW_DIRECTION,
        // 16: GetIncrementalTabStop()
        GetIncrementalTabStop: *const fn (*IDWriteTextFormat) callconv(.winapi) f32,
        // 17: GetTrimming(DWRITE_TRIMMING*, IDWriteInlineObject**)
        GetTrimming: *const fn (*IDWriteTextFormat, *DWRITE_TRIMMING, *?*IDWriteInlineObject) callconv(.winapi) HRESULT,
        // 18: GetLineSpacing(DWRITE_LINE_SPACING_METHOD*, FLOAT* lineSpacing, FLOAT* baseline)
        GetLineSpacing: *const fn (*IDWriteTextFormat, *DWRITE_LINE_SPACING_METHOD, *f32, *f32) callconv(.winapi) HRESULT,
        // 19: GetFontCollection(IDWriteFontCollection**)
        GetFontCollection: *const fn (*IDWriteTextFormat, *?*IDWriteFontCollection) callconv(.winapi) HRESULT,
        // 20: GetFontFamilyNameLength()
        GetFontFamilyNameLength: *const fn (*IDWriteTextFormat) callconv(.winapi) u32,
        // 21: GetFontFamilyName(WCHAR* name, UINT32 size)
        GetFontFamilyName: *const fn (*IDWriteTextFormat, [*]WCHAR, u32) callconv(.winapi) HRESULT,
        // 22: GetFontWeight()
        GetFontWeight: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_FONT_WEIGHT,
        // 23: GetFontStyle()
        GetFontStyle: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_FONT_STYLE,
        // 24: GetFontStretch()
        GetFontStretch: *const fn (*IDWriteTextFormat) callconv(.winapi) DWRITE_FONT_STRETCH,
        // 25: GetFontSize()
        GetFontSize: *const fn (*IDWriteTextFormat) callconv(.winapi) f32,
        // 26: GetLocaleNameLength()
        GetLocaleNameLength: *const fn (*IDWriteTextFormat) callconv(.winapi) u32,
        // 27: GetLocaleName(WCHAR* name, UINT32 size)
        GetLocaleName: *const fn (*IDWriteTextFormat, [*]WCHAR, u32) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteTextFormat) void {
        com.release(self);
    }

    pub fn setTextAlignment(self: *IDWriteTextFormat, v: DWRITE_TEXT_ALIGNMENT) Error!void {
        try check(self.vtable.SetTextAlignment(self, v));
    }

    pub fn setParagraphAlignment(self: *IDWriteTextFormat, v: DWRITE_PARAGRAPH_ALIGNMENT) Error!void {
        try check(self.vtable.SetParagraphAlignment(self, v));
    }

    pub fn setWordWrapping(self: *IDWriteTextFormat, v: DWRITE_WORD_WRAPPING) Error!void {
        try check(self.vtable.SetWordWrapping(self, v));
    }

    pub fn setReadingDirection(self: *IDWriteTextFormat, v: DWRITE_READING_DIRECTION) Error!void {
        try check(self.vtable.SetReadingDirection(self, v));
    }

    pub fn setFlowDirection(self: *IDWriteTextFormat, v: DWRITE_FLOW_DIRECTION) Error!void {
        try check(self.vtable.SetFlowDirection(self, v));
    }

    pub fn setIncrementalTabStop(self: *IDWriteTextFormat, v: f32) Error!void {
        try check(self.vtable.SetIncrementalTabStop(self, v));
    }

    /// `sign` null = trim without an ellipsis.
    pub fn setTrimming(self: *IDWriteTextFormat, trimming: DWRITE_TRIMMING, sign: ?*IDWriteInlineObject) Error!void {
        try check(self.vtable.SetTrimming(self, &trimming, sign));
    }

    pub fn setLineSpacing(self: *IDWriteTextFormat, method: DWRITE_LINE_SPACING_METHOD, line_spacing: f32, baseline: f32) Error!void {
        try check(self.vtable.SetLineSpacing(self, method, line_spacing, baseline));
    }

    pub fn getTextAlignment(self: *IDWriteTextFormat) DWRITE_TEXT_ALIGNMENT {
        return self.vtable.GetTextAlignment(self);
    }

    pub fn getParagraphAlignment(self: *IDWriteTextFormat) DWRITE_PARAGRAPH_ALIGNMENT {
        return self.vtable.GetParagraphAlignment(self);
    }

    pub fn getWordWrapping(self: *IDWriteTextFormat) DWRITE_WORD_WRAPPING {
        return self.vtable.GetWordWrapping(self);
    }

    pub fn getFontWeight(self: *IDWriteTextFormat) DWRITE_FONT_WEIGHT {
        return self.vtable.GetFontWeight(self);
    }

    pub fn getFontStyle(self: *IDWriteTextFormat) DWRITE_FONT_STYLE {
        return self.vtable.GetFontStyle(self);
    }

    pub fn getFontStretch(self: *IDWriteTextFormat) DWRITE_FONT_STRETCH {
        return self.vtable.GetFontStretch(self);
    }

    pub fn getFontSize(self: *IDWriteTextFormat) f32 {
        return self.vtable.GetFontSize(self);
    }

    /// Trimming options and the sign (the sign carries a reference, or null).
    pub fn getTrimming(self: *IDWriteTextFormat) Error!struct { trimming: DWRITE_TRIMMING, sign: ?*IDWriteInlineObject } {
        var t: DWRITE_TRIMMING = .{};
        var sign: ?*IDWriteInlineObject = null;
        try check(self.vtable.GetTrimming(self, &t, &sign));
        return .{ .trimming = t, .sign = sign };
    }

    pub fn getLineSpacing(self: *IDWriteTextFormat) Error!struct { method: DWRITE_LINE_SPACING_METHOD, spacing: f32, baseline: f32 } {
        var method: DWRITE_LINE_SPACING_METHOD = .default;
        var spacing: f32 = 0;
        var baseline: f32 = 0;
        try check(self.vtable.GetLineSpacing(self, &method, &spacing, &baseline));
        return .{ .method = method, .spacing = spacing, .baseline = baseline };
    }

    pub fn getFontCollection(self: *IDWriteTextFormat) Error!*IDWriteFontCollection {
        var out: ?*IDWriteFontCollection = null;
        return checkOut(IDWriteFontCollection, self.vtable.GetFontCollection(self, &out), out);
    }

    /// Family name into `buf` (UTF-16, NUL-terminated); returns the name
    /// without the terminator.
    pub fn getFontFamilyName(self: *IDWriteTextFormat, buf: []WCHAR) Error![]WCHAR {
        const len = self.vtable.GetFontFamilyNameLength(self);
        if (buf.len < @as(usize, len) + 1) return error.BufferTooSmall;
        try check(self.vtable.GetFontFamilyName(self, buf.ptr, @intCast(buf.len)));
        return buf[0..len];
    }
};

// ─── IDWriteTextLayout ──────────────────────────────────────────────────

pub const IDWriteTextLayout = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{53737037-6d14-410b-9bfe-0b182bb70961}");

    /// Inherits IDWriteTextFormat (slots 3-27). The per-range getters are
    /// overloads of the format getters in C++; here they live in this table
    /// under the same names and are wrapped as `get*At`.
    pub const VTable = extern struct {
        base: IDWriteTextFormat.VTable,
        // 28: SetMaxWidth(FLOAT)
        SetMaxWidth: *const fn (*IDWriteTextLayout, f32) callconv(.winapi) HRESULT,
        // 29: SetMaxHeight(FLOAT)
        SetMaxHeight: *const fn (*IDWriteTextLayout, f32) callconv(.winapi) HRESULT,
        // 30: SetFontCollection(IDWriteFontCollection*, DWRITE_TEXT_RANGE)
        SetFontCollection: *const fn (*IDWriteTextLayout, *IDWriteFontCollection, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 31: SetFontFamilyName(const WCHAR*, DWRITE_TEXT_RANGE)
        SetFontFamilyName: *const fn (*IDWriteTextLayout, [*:0]const WCHAR, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 32: SetFontWeight(DWRITE_FONT_WEIGHT, DWRITE_TEXT_RANGE)
        SetFontWeight: *const fn (*IDWriteTextLayout, DWRITE_FONT_WEIGHT, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 33: SetFontStyle(DWRITE_FONT_STYLE, DWRITE_TEXT_RANGE)
        SetFontStyle: *const fn (*IDWriteTextLayout, DWRITE_FONT_STYLE, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 34: SetFontStretch(DWRITE_FONT_STRETCH, DWRITE_TEXT_RANGE)
        SetFontStretch: *const fn (*IDWriteTextLayout, DWRITE_FONT_STRETCH, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 35: SetFontSize(FLOAT, DWRITE_TEXT_RANGE)
        SetFontSize: *const fn (*IDWriteTextLayout, f32, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 36: SetUnderline(BOOL, DWRITE_TEXT_RANGE)
        SetUnderline: *const fn (*IDWriteTextLayout, BOOL, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 37: SetStrikethrough(BOOL, DWRITE_TEXT_RANGE)
        SetStrikethrough: *const fn (*IDWriteTextLayout, BOOL, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 38: SetDrawingEffect(IUnknown* effect, DWRITE_TEXT_RANGE) — Direct2D draws a brush passed here
        SetDrawingEffect: *const fn (*IDWriteTextLayout, ?*com.IUnknown, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 39: SetInlineObject(IDWriteInlineObject*, DWRITE_TEXT_RANGE)
        SetInlineObject: *const fn (*IDWriteTextLayout, ?*IDWriteInlineObject, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 40: SetTypography(IDWriteTypography*, DWRITE_TEXT_RANGE)
        SetTypography: *const fn (*IDWriteTextLayout, ?*IDWriteTypography, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 41: SetLocaleName(const WCHAR*, DWRITE_TEXT_RANGE)
        SetLocaleName: *const fn (*IDWriteTextLayout, [*:0]const WCHAR, DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 42: GetMaxWidth()
        GetMaxWidth: *const fn (*IDWriteTextLayout) callconv(.winapi) f32,
        // 43: GetMaxHeight()
        GetMaxHeight: *const fn (*IDWriteTextLayout) callconv(.winapi) f32,
        // 44: GetFontCollection(UINT32 pos, IDWriteFontCollection**, DWRITE_TEXT_RANGE*)
        GetFontCollection: *const fn (*IDWriteTextLayout, u32, *?*IDWriteFontCollection, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 45: GetFontFamilyNameLength(UINT32 pos, UINT32* length, DWRITE_TEXT_RANGE*)
        GetFontFamilyNameLength: *const fn (*IDWriteTextLayout, u32, *u32, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 46: GetFontFamilyName(UINT32 pos, WCHAR* name, UINT32 size, DWRITE_TEXT_RANGE*)
        GetFontFamilyName: *const fn (*IDWriteTextLayout, u32, [*]WCHAR, u32, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 47: GetFontWeight(UINT32 pos, DWRITE_FONT_WEIGHT*, DWRITE_TEXT_RANGE*)
        GetFontWeight: *const fn (*IDWriteTextLayout, u32, *DWRITE_FONT_WEIGHT, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 48: GetFontStyle(UINT32 pos, DWRITE_FONT_STYLE*, DWRITE_TEXT_RANGE*)
        GetFontStyle: *const fn (*IDWriteTextLayout, u32, *DWRITE_FONT_STYLE, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 49: GetFontStretch(UINT32 pos, DWRITE_FONT_STRETCH*, DWRITE_TEXT_RANGE*)
        GetFontStretch: *const fn (*IDWriteTextLayout, u32, *DWRITE_FONT_STRETCH, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 50: GetFontSize(UINT32 pos, FLOAT*, DWRITE_TEXT_RANGE*)
        GetFontSize: *const fn (*IDWriteTextLayout, u32, *f32, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 51: GetUnderline(UINT32 pos, BOOL*, DWRITE_TEXT_RANGE*)
        GetUnderline: *const fn (*IDWriteTextLayout, u32, *BOOL, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 52: GetStrikethrough(UINT32 pos, BOOL*, DWRITE_TEXT_RANGE*)
        GetStrikethrough: *const fn (*IDWriteTextLayout, u32, *BOOL, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 53: GetDrawingEffect(UINT32 pos, IUnknown**, DWRITE_TEXT_RANGE*)
        GetDrawingEffect: *const fn (*IDWriteTextLayout, u32, *?*com.IUnknown, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 54: GetInlineObject(UINT32 pos, IDWriteInlineObject**, DWRITE_TEXT_RANGE*)
        GetInlineObject: *const fn (*IDWriteTextLayout, u32, *?*IDWriteInlineObject, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 55: GetTypography(UINT32 pos, IDWriteTypography**, DWRITE_TEXT_RANGE*)
        GetTypography: *const fn (*IDWriteTextLayout, u32, *?*IDWriteTypography, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 56: GetLocaleNameLength(UINT32 pos, UINT32* length, DWRITE_TEXT_RANGE*)
        GetLocaleNameLength: *const fn (*IDWriteTextLayout, u32, *u32, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 57: GetLocaleName(UINT32 pos, WCHAR* name, UINT32 size, DWRITE_TEXT_RANGE*)
        GetLocaleName: *const fn (*IDWriteTextLayout, u32, [*]WCHAR, u32, ?*DWRITE_TEXT_RANGE) callconv(.winapi) HRESULT,
        // 58: Draw(void* clientDrawingContext, IDWriteTextRenderer*, FLOAT originX, FLOAT originY)
        Draw: *const fn (*IDWriteTextLayout, ?*anyopaque, *IDWriteTextRenderer, f32, f32) callconv(.winapi) HRESULT,
        // 59: GetLineMetrics(DWRITE_LINE_METRICS*, UINT32 maxLineCount, UINT32* actualLineCount)
        GetLineMetrics: *const fn (*IDWriteTextLayout, ?[*]DWRITE_LINE_METRICS, u32, *u32) callconv(.winapi) HRESULT,
        // 60: GetMetrics(DWRITE_TEXT_METRICS*)
        GetMetrics: *const fn (*IDWriteTextLayout, *DWRITE_TEXT_METRICS) callconv(.winapi) HRESULT,
        // 61: GetOverhangMetrics(DWRITE_OVERHANG_METRICS*)
        GetOverhangMetrics: *const fn (*IDWriteTextLayout, *DWRITE_OVERHANG_METRICS) callconv(.winapi) HRESULT,
        // 62: GetClusterMetrics(DWRITE_CLUSTER_METRICS*, UINT32 maxClusterCount, UINT32* actualClusterCount)
        GetClusterMetrics: *const fn (*IDWriteTextLayout, ?[*]DWRITE_CLUSTER_METRICS, u32, *u32) callconv(.winapi) HRESULT,
        // 63: DetermineMinWidth(FLOAT* minWidth)
        DetermineMinWidth: *const fn (*IDWriteTextLayout, *f32) callconv(.winapi) HRESULT,
        // 64: HitTestPoint(FLOAT pointX, FLOAT pointY, BOOL* isTrailingHit, BOOL* isInside, DWRITE_HIT_TEST_METRICS*)
        HitTestPoint: *const fn (*IDWriteTextLayout, f32, f32, *BOOL, *BOOL, *DWRITE_HIT_TEST_METRICS) callconv(.winapi) HRESULT,
        // 65: HitTestTextPosition(UINT32 textPosition, BOOL isTrailingHit, FLOAT* pointX, FLOAT* pointY, DWRITE_HIT_TEST_METRICS*)
        HitTestTextPosition: *const fn (*IDWriteTextLayout, u32, BOOL, *f32, *f32, *DWRITE_HIT_TEST_METRICS) callconv(.winapi) HRESULT,
        // 66: HitTestTextRange(UINT32 textPosition, UINT32 textLength, FLOAT originX, FLOAT originY, DWRITE_HIT_TEST_METRICS*, UINT32 maxHitTestMetricsCount, UINT32* actualHitTestMetricsCount)
        HitTestTextRange: *const fn (*IDWriteTextLayout, u32, u32, f32, f32, ?[*]DWRITE_HIT_TEST_METRICS, u32, *u32) callconv(.winapi) HRESULT,
    };

    pub const PointHit = struct {
        metrics: DWRITE_HIT_TEST_METRICS,
        /// The point is on the trailing side of the hit cluster (the caret
        /// goes after it).
        is_trailing: bool,
        /// The point is inside the text (not beyond its bounds).
        is_inside: bool,
    };

    pub const PositionHit = struct {
        x: f32,
        y: f32,
        metrics: DWRITE_HIT_TEST_METRICS,
    };

    pub fn release(self: *IDWriteTextLayout) void {
        com.release(self);
    }

    /// The inherited IDWriteTextFormat interface (paragraph settings set on
    /// it apply to this layout only).
    pub fn format(self: *IDWriteTextLayout) *IDWriteTextFormat {
        return @ptrCast(self);
    }

    pub fn setTextAlignment(self: *IDWriteTextLayout, v: DWRITE_TEXT_ALIGNMENT) Error!void {
        return self.format().setTextAlignment(v);
    }

    pub fn setParagraphAlignment(self: *IDWriteTextLayout, v: DWRITE_PARAGRAPH_ALIGNMENT) Error!void {
        return self.format().setParagraphAlignment(v);
    }

    pub fn setWordWrapping(self: *IDWriteTextLayout, v: DWRITE_WORD_WRAPPING) Error!void {
        return self.format().setWordWrapping(v);
    }

    pub fn setReadingDirection(self: *IDWriteTextLayout, v: DWRITE_READING_DIRECTION) Error!void {
        return self.format().setReadingDirection(v);
    }

    pub fn setTrimming(self: *IDWriteTextLayout, trimming: DWRITE_TRIMMING, sign: ?*IDWriteInlineObject) Error!void {
        return self.format().setTrimming(trimming, sign);
    }

    pub fn setLineSpacing(self: *IDWriteTextLayout, method: DWRITE_LINE_SPACING_METHOD, line_spacing: f32, baseline: f32) Error!void {
        return self.format().setLineSpacing(method, line_spacing, baseline);
    }

    pub fn setMaxWidth(self: *IDWriteTextLayout, v: f32) Error!void {
        try check(self.vtable.SetMaxWidth(self, v));
    }

    pub fn setMaxHeight(self: *IDWriteTextLayout, v: f32) Error!void {
        try check(self.vtable.SetMaxHeight(self, v));
    }

    pub fn getMaxWidth(self: *IDWriteTextLayout) f32 {
        return self.vtable.GetMaxWidth(self);
    }

    pub fn getMaxHeight(self: *IDWriteTextLayout) f32 {
        return self.vtable.GetMaxHeight(self);
    }

    pub fn setFontFamilyName(self: *IDWriteTextLayout, name: [*:0]const WCHAR, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetFontFamilyName(self, name, range));
    }

    pub fn setFontWeight(self: *IDWriteTextLayout, v: DWRITE_FONT_WEIGHT, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetFontWeight(self, v, range));
    }

    pub fn setFontStyle(self: *IDWriteTextLayout, v: DWRITE_FONT_STYLE, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetFontStyle(self, v, range));
    }

    pub fn setFontStretch(self: *IDWriteTextLayout, v: DWRITE_FONT_STRETCH, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetFontStretch(self, v, range));
    }

    pub fn setFontSize(self: *IDWriteTextLayout, v: f32, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetFontSize(self, v, range));
    }

    pub fn setUnderline(self: *IDWriteTextLayout, on: bool, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetUnderline(self, com.boolToWin(on), range));
    }

    pub fn setStrikethrough(self: *IDWriteTextLayout, on: bool, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetStrikethrough(self, com.boolToWin(on), range));
    }

    /// Direct2D draws `effect` (an ID2D1Brush) as the foreground of `range`.
    pub fn setDrawingEffect(self: *IDWriteTextLayout, effect: ?*com.IUnknown, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetDrawingEffect(self, effect, range));
    }

    pub fn setInlineObject(self: *IDWriteTextLayout, object: ?*IDWriteInlineObject, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetInlineObject(self, object, range));
    }

    pub fn setTypography(self: *IDWriteTextLayout, typography: ?*IDWriteTypography, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetTypography(self, typography, range));
    }

    pub fn setLocaleName(self: *IDWriteTextLayout, locale: [*:0]const WCHAR, range: DWRITE_TEXT_RANGE) Error!void {
        try check(self.vtable.SetLocaleName(self, locale, range));
    }

    pub fn getFontSizeAt(self: *IDWriteTextLayout, position: u32) Error!struct { size: f32, range: DWRITE_TEXT_RANGE } {
        var size: f32 = 0;
        var range: DWRITE_TEXT_RANGE = .{ .startPosition = 0, .length = 0 };
        try check(self.vtable.GetFontSize(self, position, &size, &range));
        return .{ .size = size, .range = range };
    }

    pub fn getFontWeightAt(self: *IDWriteTextLayout, position: u32) Error!struct { weight: DWRITE_FONT_WEIGHT, range: DWRITE_TEXT_RANGE } {
        var weight: DWRITE_FONT_WEIGHT = .normal;
        var range: DWRITE_TEXT_RANGE = .{ .startPosition = 0, .length = 0 };
        try check(self.vtable.GetFontWeight(self, position, &weight, &range));
        return .{ .weight = weight, .range = range };
    }

    pub fn getUnderlineAt(self: *IDWriteTextLayout, position: u32) Error!bool {
        var v: BOOL = com.FALSE;
        try check(self.vtable.GetUnderline(self, position, &v, null));
        return v != com.FALSE;
    }

    pub fn getMetrics(self: *IDWriteTextLayout) Error!DWRITE_TEXT_METRICS {
        var m: DWRITE_TEXT_METRICS = undefined;
        try check(self.vtable.GetMetrics(self, &m));
        return m;
    }

    pub fn getOverhangMetrics(self: *IDWriteTextLayout) Error!DWRITE_OVERHANG_METRICS {
        var m: DWRITE_OVERHANG_METRICS = undefined;
        try check(self.vtable.GetOverhangMetrics(self, &m));
        return m;
    }

    /// Number of lines (cheap: queries with an empty buffer).
    pub fn getLineCount(self: *IDWriteTextLayout) Error!u32 {
        var count: u32 = 0;
        const hr = self.vtable.GetLineMetrics(self, null, 0, &count);
        if (hr == com.E_INSUFFICIENT_BUFFER or hr >= 0) return count;
        try check(hr);
        return count;
    }

    /// Line metrics into `buf`. Returns the filled prefix, or
    /// `error.BufferTooSmall` when the layout has more lines than `buf`
    /// (use `getLineCount` to size it).
    pub fn getLineMetrics(self: *IDWriteTextLayout, buf: []DWRITE_LINE_METRICS) Error![]DWRITE_LINE_METRICS {
        const cap = std.math.cast(u32, buf.len) orelse std.math.maxInt(u32);
        var count: u32 = 0;
        try check(self.vtable.GetLineMetrics(self, buf.ptr, cap, &count));
        return buf[0..count];
    }

    pub fn getClusterMetrics(self: *IDWriteTextLayout, buf: []DWRITE_CLUSTER_METRICS) Error![]DWRITE_CLUSTER_METRICS {
        const cap = std.math.cast(u32, buf.len) orelse std.math.maxInt(u32);
        var count: u32 = 0;
        try check(self.vtable.GetClusterMetrics(self, buf.ptr, cap, &count));
        return buf[0..count];
    }

    /// Smallest width the layout can wrap to without breaking words.
    pub fn determineMinWidth(self: *IDWriteTextLayout) Error!f32 {
        var w: f32 = 0;
        try check(self.vtable.DetermineMinWidth(self, &w));
        return w;
    }

    /// Point (layout-relative, DIPs) → text position.
    pub fn hitTestPoint(self: *IDWriteTextLayout, x: f32, y: f32) Error!PointHit {
        var trailing: BOOL = com.FALSE;
        var inside: BOOL = com.FALSE;
        var m: DWRITE_HIT_TEST_METRICS = undefined;
        try check(self.vtable.HitTestPoint(self, x, y, &trailing, &inside, &m));
        return .{ .metrics = m, .is_trailing = trailing != com.FALSE, .is_inside = inside != com.FALSE };
    }

    /// Text position → caret point (layout-relative).
    pub fn hitTestTextPosition(self: *IDWriteTextLayout, position: u32, trailing: bool) Error!PositionHit {
        var x: f32 = 0;
        var y: f32 = 0;
        var m: DWRITE_HIT_TEST_METRICS = undefined;
        try check(self.vtable.HitTestTextPosition(self, position, com.boolToWin(trailing), &x, &y, &m));
        return .{ .x = x, .y = y, .metrics = m };
    }

    /// Rectangles covering a text range (one per line/bidi run), offset by
    /// the origin. Returns the filled prefix of `buf` (`error.BufferTooSmall`
    /// when the range needs more rectangles).
    pub fn hitTestTextRange(
        self: *IDWriteTextLayout,
        position: u32,
        length: u32,
        origin_x: f32,
        origin_y: f32,
        buf: []DWRITE_HIT_TEST_METRICS,
    ) Error![]DWRITE_HIT_TEST_METRICS {
        const cap = std.math.cast(u32, buf.len) orelse std.math.maxInt(u32);
        var count: u32 = 0;
        try check(self.vtable.HitTestTextRange(self, position, length, origin_x, origin_y, buf.ptr, cap, &count));
        return buf[0..count];
    }
};

// ─── IDWriteInlineObject ────────────────────────────────────────────────

pub const IDWriteInlineObject = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{8339fde3-106f-47ab-8373-1c6295eb10b3}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: Draw(void* clientDrawingContext, IDWriteTextRenderer*, FLOAT originX, FLOAT originY, BOOL isSideways, BOOL isRightToLeft, IUnknown* clientDrawingEffect)
        Draw: *const fn (*IDWriteInlineObject, ?*anyopaque, *IDWriteTextRenderer, f32, f32, BOOL, BOOL, ?*com.IUnknown) callconv(.winapi) HRESULT,
        // 4: GetMetrics(DWRITE_INLINE_OBJECT_METRICS*)
        GetMetrics: *const fn (*IDWriteInlineObject, *DWRITE_INLINE_OBJECT_METRICS) callconv(.winapi) HRESULT,
        // 5: GetOverhangMetrics(DWRITE_OVERHANG_METRICS*)
        GetOverhangMetrics: *const fn (*IDWriteInlineObject, *DWRITE_OVERHANG_METRICS) callconv(.winapi) HRESULT,
        // 6: GetBreakConditions(DWRITE_BREAK_CONDITION* before, DWRITE_BREAK_CONDITION* after)
        GetBreakConditions: *const fn (*IDWriteInlineObject, *DWRITE_BREAK_CONDITION, *DWRITE_BREAK_CONDITION) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteInlineObject) void {
        com.release(self);
    }

    pub fn getMetrics(self: *IDWriteInlineObject) Error!DWRITE_INLINE_OBJECT_METRICS {
        var m: DWRITE_INLINE_OBJECT_METRICS = undefined;
        try check(self.vtable.GetMetrics(self, &m));
        return m;
    }
};

// ─── Fonts ──────────────────────────────────────────────────────────────

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{a84cee02-3eea-4eee-a827-87c1a02a0fcc}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetFontFamilyCount()
        GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
        // 4: GetFontFamily(UINT32 index, IDWriteFontFamily**)
        GetFontFamily: *const fn (*IDWriteFontCollection, u32, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        // 5: FindFamilyName(const WCHAR* name, UINT32* index, BOOL* exists)
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const WCHAR, *u32, *BOOL) callconv(.winapi) HRESULT,
        // 6: GetFontFromFontFace(IDWriteFontFace*, IDWriteFont**)
        GetFontFromFontFace: *const fn (*IDWriteFontCollection, *IDWriteFontFace, *?*IDWriteFont) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFontCollection) void {
        com.release(self);
    }

    pub fn getFontFamilyCount(self: *IDWriteFontCollection) u32 {
        return self.vtable.GetFontFamilyCount(self);
    }

    pub fn getFontFamily(self: *IDWriteFontCollection, index: u32) Error!*IDWriteFontFamily {
        var out: ?*IDWriteFontFamily = null;
        return checkOut(IDWriteFontFamily, self.vtable.GetFontFamily(self, index, &out), out);
    }

    /// Index of the family named `name` (case-insensitive), or null.
    pub fn findFamilyName(self: *IDWriteFontCollection, name: [*:0]const WCHAR) Error!?u32 {
        var index: u32 = 0;
        var exists: BOOL = com.FALSE;
        try check(self.vtable.FindFamilyName(self, name, &index, &exists));
        return if (exists != com.FALSE) index else null;
    }

    pub fn getFontFromFontFace(self: *IDWriteFontCollection, face: *IDWriteFontFace) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        return checkOut(IDWriteFont, self.vtable.GetFontFromFontFace(self, face, &out), out);
    }
};

pub const IDWriteFontList = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{1a0d8438-1d97-4ec1-aef9-a2fb86ed6acb}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetFontCollection(IDWriteFontCollection**)
        GetFontCollection: *const fn (*IDWriteFontList, *?*IDWriteFontCollection) callconv(.winapi) HRESULT,
        // 4: GetFontCount()
        GetFontCount: *const fn (*IDWriteFontList) callconv(.winapi) u32,
        // 5: GetFont(UINT32 index, IDWriteFont**)
        GetFont: *const fn (*IDWriteFontList, u32, *?*IDWriteFont) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFontList) void {
        com.release(self);
    }

    pub fn getFontCount(self: *IDWriteFontList) u32 {
        return self.vtable.GetFontCount(self);
    }

    pub fn getFont(self: *IDWriteFontList, index: u32) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        return checkOut(IDWriteFont, self.vtable.GetFont(self, index, &out), out);
    }
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{da20d8ef-812a-4c43-9802-62ec4abd7add}");

    pub const VTable = extern struct {
        base: IDWriteFontList.VTable,
        // 6: GetFamilyNames(IDWriteLocalizedStrings**)
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        // 7: GetFirstMatchingFont(DWRITE_FONT_WEIGHT, DWRITE_FONT_STRETCH, DWRITE_FONT_STYLE, IDWriteFont**)
        GetFirstMatchingFont: *const fn (*IDWriteFontFamily, DWRITE_FONT_WEIGHT, DWRITE_FONT_STRETCH, DWRITE_FONT_STYLE, *?*IDWriteFont) callconv(.winapi) HRESULT,
        // 8: GetMatchingFonts(DWRITE_FONT_WEIGHT, DWRITE_FONT_STRETCH, DWRITE_FONT_STYLE, IDWriteFontList**)
        GetMatchingFonts: *const fn (*IDWriteFontFamily, DWRITE_FONT_WEIGHT, DWRITE_FONT_STRETCH, DWRITE_FONT_STYLE, *?*IDWriteFontList) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFontFamily) void {
        com.release(self);
    }

    pub fn fontList(self: *IDWriteFontFamily) *IDWriteFontList {
        return @ptrCast(self);
    }

    pub fn getFamilyNames(self: *IDWriteFontFamily) Error!*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        return checkOut(IDWriteLocalizedStrings, self.vtable.GetFamilyNames(self, &out), out);
    }

    pub fn getFirstMatchingFont(
        self: *IDWriteFontFamily,
        weight: DWRITE_FONT_WEIGHT,
        stretch: DWRITE_FONT_STRETCH,
        style: DWRITE_FONT_STYLE,
    ) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        return checkOut(IDWriteFont, self.vtable.GetFirstMatchingFont(self, weight, stretch, style, &out), out);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{acd16696-8c14-4f5d-877e-fe3fc1d32737}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetFontFamily(IDWriteFontFamily**)
        GetFontFamily: *const fn (*IDWriteFont, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        // 4: GetWeight()
        GetWeight: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_WEIGHT,
        // 5: GetStretch()
        GetStretch: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_STRETCH,
        // 6: GetStyle()
        GetStyle: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_STYLE,
        // 7: IsSymbolFont()
        IsSymbolFont: *const fn (*IDWriteFont) callconv(.winapi) BOOL,
        // 8: GetFaceNames(IDWriteLocalizedStrings**)
        GetFaceNames: *const fn (*IDWriteFont, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        // 9: GetInformationalStrings(DWRITE_INFORMATIONAL_STRING_ID, IDWriteLocalizedStrings**, BOOL* exists)
        GetInformationalStrings: *const fn (*IDWriteFont, DWRITE_INFORMATIONAL_STRING_ID, *?*IDWriteLocalizedStrings, *BOOL) callconv(.winapi) HRESULT,
        // 10: GetSimulations()
        GetSimulations: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_SIMULATIONS,
        // 11: GetMetrics(DWRITE_FONT_METRICS*)
        GetMetrics: *const fn (*IDWriteFont, *DWRITE_FONT_METRICS) callconv(.winapi) void,
        // 12: HasCharacter(UINT32 unicodeValue, BOOL* exists)
        HasCharacter: *const fn (*IDWriteFont, u32, *BOOL) callconv(.winapi) HRESULT,
        // 13: CreateFontFace(IDWriteFontFace**)
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFont) void {
        com.release(self);
    }

    pub fn getWeight(self: *IDWriteFont) DWRITE_FONT_WEIGHT {
        return self.vtable.GetWeight(self);
    }

    pub fn getStyle(self: *IDWriteFont) DWRITE_FONT_STYLE {
        return self.vtable.GetStyle(self);
    }

    pub fn getStretch(self: *IDWriteFont) DWRITE_FONT_STRETCH {
        return self.vtable.GetStretch(self);
    }

    pub fn isSymbolFont(self: *IDWriteFont) bool {
        return self.vtable.IsSymbolFont(self) != com.FALSE;
    }

    pub fn getMetrics(self: *IDWriteFont) DWRITE_FONT_METRICS {
        var m: DWRITE_FONT_METRICS = undefined;
        self.vtable.GetMetrics(self, &m);
        return m;
    }

    /// Whether the font has a glyph for code point `cp` (no fallback).
    pub fn hasCharacter(self: *IDWriteFont, cp: u21) Error!bool {
        var exists: BOOL = com.FALSE;
        try check(self.vtable.HasCharacter(self, cp, &exists));
        return exists != com.FALSE;
    }

    pub fn getFontFamily(self: *IDWriteFont) Error!*IDWriteFontFamily {
        var out: ?*IDWriteFontFamily = null;
        return checkOut(IDWriteFontFamily, self.vtable.GetFontFamily(self, &out), out);
    }

    pub fn getFaceNames(self: *IDWriteFont) Error!*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        return checkOut(IDWriteLocalizedStrings, self.vtable.GetFaceNames(self, &out), out);
    }

    /// Informational strings (null when the font has none of that kind).
    pub fn getInformationalStrings(self: *IDWriteFont, id: DWRITE_INFORMATIONAL_STRING_ID) Error!?*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        var exists: BOOL = com.FALSE;
        try check(self.vtable.GetInformationalStrings(self, id, &out, &exists));
        return if (exists != com.FALSE) out else null;
    }

    pub fn createFontFace(self: *IDWriteFont) Error!*IDWriteFontFace {
        var out: ?*IDWriteFontFace = null;
        return checkOut(IDWriteFontFace, self.vtable.CreateFontFace(self, &out), out);
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{5f49804d-7024-4d43-bfa9-d25984f53849}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetType()
        GetType: *const fn (*IDWriteFontFace) callconv(.winapi) DWRITE_FONT_FACE_TYPE,
        // 4: GetFiles(UINT32* numberOfFiles, IDWriteFontFile** fontFiles)
        GetFiles: *const fn (*IDWriteFontFace, *u32, ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
        // 5: GetIndex()
        GetIndex: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
        // 6: GetSimulations()
        GetSimulations: *const fn (*IDWriteFontFace) callconv(.winapi) DWRITE_FONT_SIMULATIONS,
        // 7: IsSymbolFont()
        IsSymbolFont: *const fn (*IDWriteFontFace) callconv(.winapi) BOOL,
        // 8: GetMetrics(DWRITE_FONT_METRICS*)
        GetMetrics: *const fn (*IDWriteFontFace, *DWRITE_FONT_METRICS) callconv(.winapi) void,
        // 9: GetGlyphCount()
        GetGlyphCount: *const fn (*IDWriteFontFace) callconv(.winapi) u16,
        // 10: GetDesignGlyphMetrics(const UINT16* glyphIndices, UINT32 glyphCount, DWRITE_GLYPH_METRICS*, BOOL isSideways)
        GetDesignGlyphMetrics: *const fn (*IDWriteFontFace, [*]const u16, u32, [*]DWRITE_GLYPH_METRICS, BOOL) callconv(.winapi) HRESULT,
        // 11: GetGlyphIndices(const UINT32* codePoints, UINT32 codePointCount, UINT16* glyphIndices)
        GetGlyphIndices: *const fn (*IDWriteFontFace, [*]const u32, u32, [*]u16) callconv(.winapi) HRESULT,
        // 12: TryGetFontTable(UINT32 tag, const void** data, UINT32* size, void** context, BOOL* exists)
        TryGetFontTable: *const fn (*IDWriteFontFace, u32, *?*const anyopaque, *u32, *?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
        // 13: ReleaseFontTable(void* context)
        ReleaseFontTable: *const fn (*IDWriteFontFace, ?*anyopaque) callconv(.winapi) void,
        // 14: GetGlyphRunOutline(FLOAT emSize, const UINT16*, const FLOAT*, const DWRITE_GLYPH_OFFSET*, UINT32 glyphCount, BOOL isSideways, BOOL isRightToLeft, IDWriteGeometrySink*)
        GetGlyphRunOutline: *const fn (*IDWriteFontFace, f32, [*]const u16, ?[*]const f32, ?[*]const DWRITE_GLYPH_OFFSET, u32, BOOL, BOOL, *IDWriteGeometrySink) callconv(.winapi) HRESULT,
        // 15: GetRecommendedRenderingMode(FLOAT emSize, FLOAT pixelsPerDip, DWRITE_MEASURING_MODE, IDWriteRenderingParams*, DWRITE_RENDERING_MODE*)
        GetRecommendedRenderingMode: *const fn (*IDWriteFontFace, f32, f32, DWRITE_MEASURING_MODE, ?*IDWriteRenderingParams, *DWRITE_RENDERING_MODE) callconv(.winapi) HRESULT,
        // 16: GetGdiCompatibleMetrics(FLOAT emSize, FLOAT pixelsPerDip, const DWRITE_MATRIX*, DWRITE_FONT_METRICS*)
        GetGdiCompatibleMetrics: *const fn (*IDWriteFontFace, f32, f32, ?*const DWRITE_MATRIX, *DWRITE_FONT_METRICS) callconv(.winapi) HRESULT,
        // 17: GetGdiCompatibleGlyphMetrics(FLOAT emSize, FLOAT pixelsPerDip, const DWRITE_MATRIX*, BOOL useGdiNatural, const UINT16*, UINT32 glyphCount, DWRITE_GLYPH_METRICS*, BOOL isSideways)
        GetGdiCompatibleGlyphMetrics: *const fn (*IDWriteFontFace, f32, f32, ?*const DWRITE_MATRIX, BOOL, [*]const u16, u32, [*]DWRITE_GLYPH_METRICS, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFontFace) void {
        com.release(self);
    }

    pub fn getMetrics(self: *IDWriteFontFace) DWRITE_FONT_METRICS {
        var m: DWRITE_FONT_METRICS = undefined;
        self.vtable.GetMetrics(self, &m);
        return m;
    }

    pub fn getGlyphCount(self: *IDWriteFontFace) u16 {
        return self.vtable.GetGlyphCount(self);
    }

    /// Glyph index per code point (0 = missing glyph). `out.len` must equal
    /// `code_points.len`.
    pub fn getGlyphIndices(self: *IDWriteFontFace, code_points: []const u32, out: []u16) Error!void {
        if (out.len != code_points.len) return error.InvalidArg;
        const n = std.math.cast(u32, code_points.len) orelse return error.InvalidArg;
        try check(self.vtable.GetGlyphIndices(self, code_points.ptr, n, out.ptr));
    }
};

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{08256209-099a-4b34-b86d-c22b110e7771}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetCount()
        GetCount: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
        // 4: FindLocaleName(const WCHAR* localeName, UINT32* index, BOOL* exists)
        FindLocaleName: *const fn (*IDWriteLocalizedStrings, [*:0]const WCHAR, *u32, *BOOL) callconv(.winapi) HRESULT,
        // 5: GetLocaleNameLength(UINT32 index, UINT32* length)
        GetLocaleNameLength: *const fn (*IDWriteLocalizedStrings, u32, *u32) callconv(.winapi) HRESULT,
        // 6: GetLocaleName(UINT32 index, WCHAR* localeName, UINT32 size)
        GetLocaleName: *const fn (*IDWriteLocalizedStrings, u32, [*]WCHAR, u32) callconv(.winapi) HRESULT,
        // 7: GetStringLength(UINT32 index, UINT32* length)
        GetStringLength: *const fn (*IDWriteLocalizedStrings, u32, *u32) callconv(.winapi) HRESULT,
        // 8: GetString(UINT32 index, WCHAR* stringBuffer, UINT32 size)
        GetString: *const fn (*IDWriteLocalizedStrings, u32, [*]WCHAR, u32) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteLocalizedStrings) void {
        com.release(self);
    }

    pub fn getCount(self: *IDWriteLocalizedStrings) u32 {
        return self.vtable.GetCount(self);
    }

    pub fn findLocaleName(self: *IDWriteLocalizedStrings, locale: [*:0]const WCHAR) Error!?u32 {
        var index: u32 = 0;
        var exists: BOOL = com.FALSE;
        try check(self.vtable.FindLocaleName(self, locale, &index, &exists));
        return if (exists != com.FALSE) index else null;
    }

    /// String `index` into `buf` (NUL-terminated); returns it without the
    /// terminator.
    pub fn getString(self: *IDWriteLocalizedStrings, index: u32, buf: []WCHAR) Error![]WCHAR {
        var len: u32 = 0;
        try check(self.vtable.GetStringLength(self, index, &len));
        if (buf.len < @as(usize, len) + 1) return error.BufferTooSmall;
        try check(self.vtable.GetString(self, index, buf.ptr, @intCast(buf.len)));
        return buf[0..len];
    }
};

// ─── Rendering params, typography, GDI interop ─────────────────────────

pub const IDWriteRenderingParams = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2f0da53a-2add-47cd-82ee-d9ec34688e75}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: GetGamma()
        GetGamma: *const fn (*IDWriteRenderingParams) callconv(.winapi) f32,
        // 4: GetEnhancedContrast()
        GetEnhancedContrast: *const fn (*IDWriteRenderingParams) callconv(.winapi) f32,
        // 5: GetClearTypeLevel()
        GetClearTypeLevel: *const fn (*IDWriteRenderingParams) callconv(.winapi) f32,
        // 6: GetPixelGeometry()
        GetPixelGeometry: *const fn (*IDWriteRenderingParams) callconv(.winapi) DWRITE_PIXEL_GEOMETRY,
        // 7: GetRenderingMode()
        GetRenderingMode: *const fn (*IDWriteRenderingParams) callconv(.winapi) DWRITE_RENDERING_MODE,
    };

    pub fn release(self: *IDWriteRenderingParams) void {
        com.release(self);
    }
};

pub const IDWriteTypography = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{55f1112b-1dc2-4b3c-9541-f46894ed85b6}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: AddFontFeature(DWRITE_FONT_FEATURE)
        AddFontFeature: *const fn (*IDWriteTypography, DWRITE_FONT_FEATURE) callconv(.winapi) HRESULT,
        // 4: GetFontFeatureCount()
        GetFontFeatureCount: *const fn (*IDWriteTypography) callconv(.winapi) u32,
        // 5: GetFontFeature(UINT32 index, DWRITE_FONT_FEATURE*)
        GetFontFeature: *const fn (*IDWriteTypography, u32, *DWRITE_FONT_FEATURE) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteTypography) void {
        com.release(self);
    }

    pub fn addFontFeature(self: *IDWriteTypography, feature: DWRITE_FONT_FEATURE) Error!void {
        try check(self.vtable.AddFontFeature(self, feature));
    }
};

pub const IDWriteGdiInterop = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{1edd9491-9853-4299-898f-6432983b6f3a}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        // 3: CreateFontFromLOGFONT(const LOGFONTW*, IDWriteFont**)
        CreateFontFromLOGFONT: *const fn (*IDWriteGdiInterop, *const LOGFONTW, *?*IDWriteFont) callconv(.winapi) HRESULT,
        // 4: ConvertFontToLOGFONT(IDWriteFont*, LOGFONTW*, BOOL* isSystemFont)
        ConvertFontToLOGFONT: *const fn (*IDWriteGdiInterop, *IDWriteFont, *LOGFONTW, *BOOL) callconv(.winapi) HRESULT,
        // 5: ConvertFontFaceToLOGFONT(IDWriteFontFace*, LOGFONTW*)
        ConvertFontFaceToLOGFONT: *const fn (*IDWriteGdiInterop, *IDWriteFontFace, *LOGFONTW) callconv(.winapi) HRESULT,
        // 6: CreateFontFaceFromHdc(HDC, IDWriteFontFace**)
        CreateFontFaceFromHdc: *const fn (*IDWriteGdiInterop, com.HDC, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
        // 7: CreateBitmapRenderTarget(HDC, UINT32 width, UINT32 height, IDWriteBitmapRenderTarget**)
        CreateBitmapRenderTarget: *const fn (*IDWriteGdiInterop, ?com.HDC, u32, u32, *?*IDWriteBitmapRenderTarget) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteGdiInterop) void {
        com.release(self);
    }

    /// The DirectWrite font matching a GDI LOGFONT (e.g. the tab bar's font).
    pub fn createFontFromLOGFONT(self: *IDWriteGdiInterop, logfont: *const LOGFONTW) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        return checkOut(IDWriteFont, self.vtable.CreateFontFromLOGFONT(self, logfont, &out), out);
    }
};

// ─── Factory creation ───────────────────────────────────────────────────

pub extern "dwrite" fn DWriteCreateFactory(
    factoryType: DWRITE_FACTORY_TYPE,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// Create a DirectWrite factory. Use `.shared` (one process-wide cache of
/// font data, shared with the rest of Windows) unless isolation is needed.
pub fn createFactory(factory_type: DWRITE_FACTORY_TYPE) Error!*IDWriteFactory {
    var out: ?*anyopaque = null;
    try check(DWriteCreateFactory(factory_type, &IDWriteFactory.IID, &out));
    const p = out orelse return error.NoInterface;
    return @ptrCast(@alignCast(p));
}

// ─── Tests ──────────────────────────────────────────────────────────────

const slot = com.slotIndex;

test "unit: platform: dwrite vtable slots match dwrite.h" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), slot(IDWriteFactory.VTable, "GetSystemFontCollection"));
    try t.expectEqual(@as(usize, 15), slot(IDWriteFactory.VTable, "CreateTextFormat"));
    try t.expectEqual(@as(usize, 18), slot(IDWriteFactory.VTable, "CreateTextLayout"));
    try t.expectEqual(@as(usize, 20), slot(IDWriteFactory.VTable, "CreateEllipsisTrimmingSign"));
    try t.expectEqual(@as(usize, 23), slot(IDWriteFactory.VTable, "CreateGlyphRunAnalysis"));
    try t.expectEqual(@as(usize, 24 * @sizeOf(usize)), @sizeOf(IDWriteFactory.VTable));

    try t.expectEqual(@as(usize, 3), slot(IDWriteTextFormat.VTable, "SetTextAlignment"));
    try t.expectEqual(@as(usize, 9), slot(IDWriteTextFormat.VTable, "SetTrimming"));
    try t.expectEqual(@as(usize, 17), slot(IDWriteTextFormat.VTable, "GetTrimming"));
    try t.expectEqual(@as(usize, 25), slot(IDWriteTextFormat.VTable, "GetFontSize"));
    try t.expectEqual(@as(usize, 27), slot(IDWriteTextFormat.VTable, "GetLocaleName"));
    try t.expectEqual(@as(usize, 28 * @sizeOf(usize)), @sizeOf(IDWriteTextFormat.VTable));

    try t.expectEqual(@as(usize, 28), slot(IDWriteTextLayout.VTable, "SetMaxWidth"));
    try t.expectEqual(@as(usize, 38), slot(IDWriteTextLayout.VTable, "SetDrawingEffect"));
    try t.expectEqual(@as(usize, 44), slot(IDWriteTextLayout.VTable, "GetFontCollection"));
    try t.expectEqual(@as(usize, 58), slot(IDWriteTextLayout.VTable, "Draw"));
    try t.expectEqual(@as(usize, 59), slot(IDWriteTextLayout.VTable, "GetLineMetrics"));
    try t.expectEqual(@as(usize, 60), slot(IDWriteTextLayout.VTable, "GetMetrics"));
    try t.expectEqual(@as(usize, 64), slot(IDWriteTextLayout.VTable, "HitTestPoint"));
    try t.expectEqual(@as(usize, 66), slot(IDWriteTextLayout.VTable, "HitTestTextRange"));
    try t.expectEqual(@as(usize, 67 * @sizeOf(usize)), @sizeOf(IDWriteTextLayout.VTable));

    try t.expectEqual(@as(usize, 6), slot(IDWriteInlineObject.VTable, "GetBreakConditions"));
    try t.expectEqual(@as(usize, 5), slot(IDWriteFontCollection.VTable, "FindFamilyName"));
    try t.expectEqual(@as(usize, 7 * @sizeOf(usize)), @sizeOf(IDWriteFontCollection.VTable));
    try t.expectEqual(@as(usize, 5), slot(IDWriteFontList.VTable, "GetFont"));
    try t.expectEqual(@as(usize, 7), slot(IDWriteFontFamily.VTable, "GetFirstMatchingFont"));
    try t.expectEqual(@as(usize, 9 * @sizeOf(usize)), @sizeOf(IDWriteFontFamily.VTable));
    try t.expectEqual(@as(usize, 12), slot(IDWriteFont.VTable, "HasCharacter"));
    try t.expectEqual(@as(usize, 14 * @sizeOf(usize)), @sizeOf(IDWriteFont.VTable));
    try t.expectEqual(@as(usize, 11), slot(IDWriteFontFace.VTable, "GetGlyphIndices"));
    try t.expectEqual(@as(usize, 18 * @sizeOf(usize)), @sizeOf(IDWriteFontFace.VTable));
    try t.expectEqual(@as(usize, 8), slot(IDWriteLocalizedStrings.VTable, "GetString"));
    try t.expectEqual(@as(usize, 7), slot(IDWriteRenderingParams.VTable, "GetRenderingMode"));
    try t.expectEqual(@as(usize, 5), slot(IDWriteTypography.VTable, "GetFontFeature"));
    try t.expectEqual(@as(usize, 7), slot(IDWriteGdiInterop.VTable, "CreateBitmapRenderTarget"));
}

test "unit: platform: dwrite struct layouts match dwrite.h" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 36), @sizeOf(DWRITE_TEXT_METRICS));
    try t.expectEqual(@as(usize, 24), @sizeOf(DWRITE_LINE_METRICS));
    try t.expectEqual(@as(usize, 8), @sizeOf(DWRITE_CLUSTER_METRICS));
    try t.expectEqual(@as(usize, 36), @sizeOf(DWRITE_HIT_TEST_METRICS));
    try t.expectEqual(@as(usize, 12), @sizeOf(DWRITE_TRIMMING));
    try t.expectEqual(@as(usize, 8), @sizeOf(DWRITE_TEXT_RANGE));
    try t.expectEqual(@as(usize, 20), @sizeOf(DWRITE_FONT_METRICS));
    try t.expectEqual(@as(usize, 48), @sizeOf(DWRITE_GLYPH_RUN));
    try t.expectEqual(@as(usize, 92), @sizeOf(LOGFONTW));
    try t.expectEqual(@as(u32, 0x6D756E74), fontFeatureTag("tnum"));
}

test "unit: platform: dwrite wrappers type-check" {
    std.testing.refAllDeclsRecursive(@This());
}
