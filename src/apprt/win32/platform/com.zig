//! COM and Win32 base layer for the Direct2D, DirectWrite and WIC bindings
//! (ARCHITECTURE ADR-11, §15.4 COM rules).
//!
//! Self-contained on purpose: this file imports only `std`, and the binding
//! files next to it (`d2d.zig`, `dwrite.zig`, `wic.zig`) import only `std`
//! and each other. They compile without the rest of the apprt and without
//! `platform/win32.zig`, so the few Win32 types they need are defined here.
//!
//! Conventions shared by every binding file in this directory (they follow
//! the hand-written style of `webview2.zig`):
//!
//! - A COM interface is an `extern struct { vtable: *const VTable }` with
//!   `pub const IID`. Its `VTable` lists slots in Windows SDK order. A derived
//!   interface embeds its parent's table as the first field `base`; because
//!   every slot is a pointer, the nested table is layout-identical to the
//!   flattened C vtable.
//! - Every slot carries a `// N: Name` comment with its absolute index. The
//!   orders were taken from the SDK headers (mingw-w64 copies shipped with
//!   Zig: d2d1.h, d2d1_1.h, dwrite.h, wincodec.h, objidlbase.h) and are pinned
//!   by the "vtable slots" tests in each file.
//! - C++ methods that return a struct by value (`GetSize`, `GetColor`, ...)
//!   follow the MSVC member-function ABI: the caller passes a hidden result
//!   pointer right after `this` and the callee returns that pointer. They are
//!   declared that way; the wrappers hide it.
//! - Wrappers return `Error!T`. `check` maps an HRESULT to an error and
//!   records the raw value in `last_failure` for logging.
//! - Ownership: a wrapper that hands out an interface pointer transfers one
//!   reference; release it with `release()` (or `com.release`). Borrowed
//!   pointers that outlive a callback must be AddRef'd (`com.addRef`).
const std = @import("std");
const windows = std.os.windows;

// ─── Win32 base types ───────────────────────────────────────────────────

pub const HRESULT = windows.HRESULT;
pub const BOOL = windows.BOOL;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const GUID = windows.GUID;
pub const IID = GUID;
pub const CLSID = GUID;
/// Same type as `std.os.windows.HWND` (and therefore `platform/win32.zig`).
pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HMONITOR = *opaque {};
pub const HBITMAP = *opaque {};
pub const HICON = *opaque {};
pub const HPALETTE = *opaque {};
pub const RECT = windows.RECT;
pub const POINT = windows.POINT;
pub const SIZE = extern struct { cx: i32, cy: i32 };
pub const WCHAR = u16;
pub const LPCWSTR = [*:0]const WCHAR;
pub const LPWSTR = [*:0]WCHAR;
pub const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };

/// Placeholder for vtable slots this binding does not call. Keeping the slot
/// (instead of truncating the table) preserves the indices of later slots.
pub const PadFn = *const fn () callconv(.winapi) void;

pub fn boolToWin(b: bool) BOOL {
    return if (b) TRUE else FALSE;
}

// ─── HRESULTs ───────────────────────────────────────────────────────────

fn hresult(comptime value: u32) HRESULT {
    return @bitCast(value);
}

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOTIMPL = hresult(0x80004001);
pub const E_NOINTERFACE = hresult(0x80004002);
pub const E_POINTER = hresult(0x80004003);
pub const E_ABORT = hresult(0x80004004);
pub const E_FAIL = hresult(0x80004005);
pub const E_UNEXPECTED = hresult(0x8000FFFF);
pub const E_ACCESSDENIED = hresult(0x80070005);
pub const E_HANDLE = hresult(0x80070006);
pub const E_OUTOFMEMORY = hresult(0x8007000E);
pub const E_INVALIDARG = hresult(0x80070057);
/// HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) / (ERROR_PATH_NOT_FOUND).
pub const E_FILE_NOT_FOUND = hresult(0x80070002);
pub const E_PATH_NOT_FOUND = hresult(0x80070003);
/// HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER).
pub const E_INSUFFICIENT_BUFFER = hresult(0x8007007A);
pub const RPC_E_CHANGED_MODE = hresult(0x80010106);
pub const CO_E_NOTINITIALIZED = hresult(0x800401F0);
pub const REGDB_E_CLASSNOTREG = hresult(0x80040154);

// Direct2D (d2derr.h).
pub const D2DERR_WRONG_STATE = hresult(0x88990001);
pub const D2DERR_NOT_INITIALIZED = hresult(0x88990002);
pub const D2DERR_UNSUPPORTED_OPERATION = hresult(0x88990003);
pub const D2DERR_SCREEN_ACCESS_DENIED = hresult(0x88990005);
pub const D2DERR_DISPLAY_STATE_INVALID = hresult(0x88990006);
pub const D2DERR_ZERO_VECTOR = hresult(0x88990007);
pub const D2DERR_INTERNAL_ERROR = hresult(0x88990008);
pub const D2DERR_DISPLAY_FORMAT_NOT_SUPPORTED = hresult(0x88990009);
pub const D2DERR_INVALID_CALL = hresult(0x8899000A);
pub const D2DERR_NO_HARDWARE_DEVICE = hresult(0x8899000B);
pub const D2DERR_RECREATE_TARGET = hresult(0x8899000C);
pub const D2DERR_MAX_TEXTURE_SIZE_EXCEEDED = hresult(0x8899000F);
pub const D2DERR_BAD_NUMBER = hresult(0x88990011);
pub const D2DERR_WRONG_FACTORY = hresult(0x88990012);
pub const D2DERR_LAYER_ALREADY_IN_USE = hresult(0x88990013);
pub const D2DERR_POP_CALL_DID_NOT_MATCH_PUSH = hresult(0x88990014);
pub const D2DERR_WRONG_RESOURCE_DOMAIN = hresult(0x88990015);
pub const D2DERR_PUSH_POP_UNBALANCED = hresult(0x88990016);
pub const D2DERR_RENDER_TARGET_HAS_LAYER_OR_CLIPRECT = hresult(0x88990017);
pub const D2DERR_TARGET_NOT_GDI_COMPATIBLE = hresult(0x8899001A);
pub const D2DERR_EXCEEDS_MAX_BITMAP_SIZE = hresult(0x8899001D);

// DXGI device loss (surfaced by hardware render targets at EndDraw/Flush).
pub const DXGI_ERROR_DEVICE_REMOVED = hresult(0x887A0005);
pub const DXGI_ERROR_DEVICE_HUNG = hresult(0x887A0006);
pub const DXGI_ERROR_DEVICE_RESET = hresult(0x887A0007);

// DirectWrite and WIC.
pub const DWRITE_E_NOFONT = hresult(0x88985002);
pub const DWRITE_E_FILENOTFOUND = hresult(0x88985003);
pub const WINCODEC_ERR_WRONGSTATE = hresult(0x88982F04);
pub const WINCODEC_ERR_NOTINITIALIZED = hresult(0x88982F0C);
pub const WINCODEC_ERR_ALREADYLOCKED = hresult(0x88982F0D);
pub const WINCODEC_ERR_COMPONENTNOTFOUND = hresult(0x88982F50);
pub const WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT = hresult(0x88982F80);
pub const WINCODEC_ERR_INSUFFICIENTBUFFER = hresult(0x88982F8C);

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

/// Errors produced by the binding wrappers. Only conditions a caller can act
/// on get their own name; everything else is `Unexpected` (see
/// `last_failure` for the raw HRESULT).
pub const Error = error{
    /// The render target lost its device (D2DERR_RECREATE_TARGET, DXGI device
    /// removed/reset/hung, invalid display state): discard device-dependent
    /// resources and recreate them on the next paint.
    RecreateTarget,
    /// No usable hardware device; retry with a software render target.
    NoHardwareDevice,
    OutOfMemory,
    InvalidArg,
    NoInterface,
    NotImplemented,
    AccessDenied,
    FileNotFound,
    BufferTooSmall,
    ClassNotRegistered,
    /// COM is not initialized on the calling thread (CoCreateInstance).
    ComNotInitialized,
    /// A call was made in the wrong state (e.g. EndDraw without BeginDraw,
    /// unbalanced push/pop, WIC bitmap already locked).
    WrongState,
    /// The requested font family or file does not exist.
    NoFont,
    UnsupportedPixelFormat,
    Unexpected,
};

/// Raw HRESULT of the most recent failed `check` on this thread. Diagnostic
/// only: log it next to the returned error.
pub threadlocal var last_failure: HRESULT = S_OK;

/// Map a failed HRESULT to an `Error`. Success codes are not valid input.
pub fn errorFromHresult(hr: HRESULT) Error {
    return switch (hr) {
        D2DERR_RECREATE_TARGET,
        DXGI_ERROR_DEVICE_REMOVED,
        DXGI_ERROR_DEVICE_RESET,
        DXGI_ERROR_DEVICE_HUNG,
        D2DERR_DISPLAY_STATE_INVALID,
        => error.RecreateTarget,
        D2DERR_NO_HARDWARE_DEVICE => error.NoHardwareDevice,
        E_OUTOFMEMORY => error.OutOfMemory,
        E_INVALIDARG, E_POINTER, D2DERR_BAD_NUMBER, D2DERR_ZERO_VECTOR => error.InvalidArg,
        E_NOINTERFACE => error.NoInterface,
        E_NOTIMPL, D2DERR_UNSUPPORTED_OPERATION => error.NotImplemented,
        E_ACCESSDENIED, D2DERR_SCREEN_ACCESS_DENIED => error.AccessDenied,
        E_FILE_NOT_FOUND, E_PATH_NOT_FOUND, DWRITE_E_FILENOTFOUND => error.FileNotFound,
        E_INSUFFICIENT_BUFFER, WINCODEC_ERR_INSUFFICIENTBUFFER => error.BufferTooSmall,
        REGDB_E_CLASSNOTREG, WINCODEC_ERR_COMPONENTNOTFOUND => error.ClassNotRegistered,
        CO_E_NOTINITIALIZED => error.ComNotInitialized,
        D2DERR_WRONG_STATE,
        D2DERR_NOT_INITIALIZED,
        D2DERR_PUSH_POP_UNBALANCED,
        D2DERR_POP_CALL_DID_NOT_MATCH_PUSH,
        D2DERR_LAYER_ALREADY_IN_USE,
        D2DERR_RENDER_TARGET_HAS_LAYER_OR_CLIPRECT,
        WINCODEC_ERR_WRONGSTATE,
        WINCODEC_ERR_NOTINITIALIZED,
        WINCODEC_ERR_ALREADYLOCKED,
        => error.WrongState,
        DWRITE_E_NOFONT => error.NoFont,
        WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT => error.UnsupportedPixelFormat,
        else => error.Unexpected,
    };
}

/// Return `error.X` for a failed HRESULT; success codes (including S_FALSE)
/// pass.
pub fn check(hr: HRESULT) Error!void {
    if (hr >= 0) return;
    last_failure = hr;
    return errorFromHresult(hr);
}

/// `check`, then unwrap a COM out-pointer that must be non-null on success.
pub fn checkOut(comptime T: type, hr: HRESULT, out: ?*T) Error!*T {
    try check(hr);
    return out orelse {
        last_failure = E_POINTER;
        return error.Unexpected;
    };
}

pub fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// ─── IUnknown and generic helpers ───────────────────────────────────────

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{00000000-0000-0000-C000-000000000046}");

    pub const VTable = extern struct {
        // 0: QueryInterface(REFIID, void**)
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        // 1: AddRef()
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        // 2: Release()
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };

    pub fn addRef(self: *IUnknown) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *IUnknown) void {
        _ = self.vtable.Release(self);
    }
};

fn assertInterfacePtr(comptime P: type) void {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("expected a single-item pointer to a COM interface, got " ++ @typeName(P));
    const T = info.pointer.child;
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "vtable"))
        @compileError(@typeName(T) ++ " is not a COM interface (no vtable field)");
}

/// View any interface pointer as IUnknown (every COM vtable starts with the
/// three IUnknown slots).
pub inline fn unknown(obj: anytype) *IUnknown {
    comptime assertInterfacePtr(@TypeOf(obj));
    return @ptrCast(obj);
}

/// AddRef `obj` and return it (for storing a borrowed pointer).
pub fn addRef(obj: anytype) @TypeOf(obj) {
    const u = unknown(obj);
    _ = u.vtable.AddRef(u);
    return obj;
}

/// Release one reference.
pub fn release(obj: anytype) void {
    const u = unknown(obj);
    _ = u.vtable.Release(u);
}

/// Release `slot.*` if set and clear it. `slot` is a `*?*Interface`.
pub fn releaseAndNull(slot: anytype) void {
    if (slot.*) |obj| {
        release(obj);
        slot.* = null;
    }
}

/// QueryInterface for `T` (uses `T.IID`). The result carries a reference.
pub fn queryInterface(comptime T: type, obj: anytype) Error!*T {
    const u = unknown(obj);
    var out: ?*anyopaque = null;
    try check(u.vtable.QueryInterface(u, &T.IID, &out));
    const p = out orelse return error.NoInterface;
    return @ptrCast(@alignCast(p));
}

/// QueryInterface for feature detection: null instead of an error.
pub fn tryQueryInterface(comptime T: type, obj: anytype) ?*T {
    return queryInterface(T, obj) catch null;
}

// ─── COM runtime (ole32) ────────────────────────────────────────────────

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*IUnknown,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CreateStreamOnHGlobal(
    hGlobal: ?*anyopaque,
    fDeleteOnRelease: BOOL,
    ppstm: *?*IStream,
) callconv(.winapi) HRESULT;

pub const COINIT_MULTITHREADED: u32 = 0x0;
pub const COINIT_APARTMENTTHREADED: u32 = 0x2;
pub const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
pub const CLSCTX_INPROC_SERVER: u32 = 0x1;

pub const Apartment = enum { single_threaded, multi_threaded };

/// Result of `initThread`; call `deinit` on the same thread when done.
pub const InitScope = struct {
    /// True when this scope owns a CoInitializeEx reference (S_OK/S_FALSE).
    needs_uninit: bool,

    pub fn deinit(self: InitScope) void {
        if (self.needs_uninit) CoUninitialize();
    }
};

/// Initialize COM on the calling thread. Direct2D and DirectWrite factories
/// do not need COM; WIC (`CoCreateInstance`) does. The wmux UI thread is
/// already an STA (WebView2), where this returns a scope that just balances
/// the extra reference. If the thread joined the other apartment model
/// (RPC_E_CHANGED_MODE), COM is still usable for the apartment-neutral WIC
/// factory and the returned scope does nothing on deinit.
pub fn initThread(apartment: Apartment) Error!InitScope {
    const flags: u32 = COINIT_DISABLE_OLE1DDE | switch (apartment) {
        .single_threaded => COINIT_APARTMENTTHREADED,
        .multi_threaded => COINIT_MULTITHREADED,
    };
    const hr = CoInitializeEx(null, flags);
    if (hr == RPC_E_CHANGED_MODE) return .{ .needs_uninit = false };
    try check(hr);
    return .{ .needs_uninit = true };
}

/// CoCreateInstance an in-process class and ask for interface `T`.
pub fn createInstance(comptime T: type, clsid: *const GUID) Error!*T {
    var out: ?*anyopaque = null;
    try check(CoCreateInstance(clsid, null, CLSCTX_INPROC_SERVER, &T.IID, &out));
    const p = out orelse return error.NoInterface;
    return @ptrCast(@alignCast(p));
}

// ─── IStream (objidlbase.h) ─────────────────────────────────────────────

pub const STREAM_SEEK_SET: u32 = 0;
pub const STREAM_SEEK_CUR: u32 = 1;
pub const STREAM_SEEK_END: u32 = 2;
pub const STATFLAG_DEFAULT: u32 = 0;
pub const STATFLAG_NONAME: u32 = 1;

pub const STATSTG = extern struct {
    pwcsName: ?LPWSTR,
    type: u32,
    cbSize: u64,
    mtime: FILETIME,
    ctime: FILETIME,
    atime: FILETIME,
    grfMode: u32,
    grfLocksSupported: u32,
    clsid: CLSID,
    grfStateBits: u32,
    reserved: u32,
};

pub const ISequentialStream = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0c733a30-2a1c-11ce-ade5-00aa0044773d}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        // 3: Read(void* pv, ULONG cb, ULONG* pcbRead)
        Read: *const fn (*ISequentialStream, ?*anyopaque, u32, ?*u32) callconv(.winapi) HRESULT,
        // 4: Write(const void* pv, ULONG cb, ULONG* pcbWritten)
        Write: *const fn (*ISequentialStream, ?*const anyopaque, u32, ?*u32) callconv(.winapi) HRESULT,
    };
};

pub const IStream = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0000000c-0000-0000-C000-000000000046}");

    pub const VTable = extern struct {
        base: ISequentialStream.VTable,
        // 5: Seek(LARGE_INTEGER dlibMove, DWORD dwOrigin, ULARGE_INTEGER* plibNewPosition)
        Seek: *const fn (*IStream, i64, u32, ?*u64) callconv(.winapi) HRESULT,
        // 6: SetSize(ULARGE_INTEGER)
        SetSize: *const fn (*IStream, u64) callconv(.winapi) HRESULT,
        // 7: CopyTo(IStream*, ULARGE_INTEGER cb, ULARGE_INTEGER* pcbRead, ULARGE_INTEGER* pcbWritten)
        CopyTo: *const fn (*IStream, *IStream, u64, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        // 8: Commit(DWORD grfCommitFlags)
        Commit: *const fn (*IStream, u32) callconv(.winapi) HRESULT,
        // 9: Revert()
        Revert: *const fn (*IStream) callconv(.winapi) HRESULT,
        // 10: LockRegion(ULARGE_INTEGER libOffset, ULARGE_INTEGER cb, DWORD dwLockType)
        LockRegion: *const fn (*IStream, u64, u64, u32) callconv(.winapi) HRESULT,
        // 11: UnlockRegion(ULARGE_INTEGER libOffset, ULARGE_INTEGER cb, DWORD dwLockType)
        UnlockRegion: *const fn (*IStream, u64, u64, u32) callconv(.winapi) HRESULT,
        // 12: Stat(STATSTG*, DWORD grfStatFlag)
        Stat: *const fn (*IStream, *STATSTG, u32) callconv(.winapi) HRESULT,
        // 13: Clone(IStream**)
        Clone: *const fn (*IStream, *?*IStream) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IStream) void {
        const u = unknown(self);
        _ = u.vtable.Release(u);
    }

    fn sequential(self: *IStream) *ISequentialStream {
        return @ptrCast(self);
    }

    /// Read up to `buf.len` bytes; returns the number read (0 at the end).
    pub fn read(self: *IStream, buf: []u8) Error!usize {
        const len: u32 = std.math.cast(u32, buf.len) orelse std.math.maxInt(u32);
        var n: u32 = 0;
        try check(self.vtable.base.Read(self.sequential(), buf.ptr, len, &n));
        return n;
    }

    /// Write all of `bytes`.
    pub fn writeAll(self: *IStream, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            const len: u32 = std.math.cast(u32, rest.len) orelse std.math.maxInt(u32);
            var n: u32 = 0;
            try check(self.vtable.base.Write(self.sequential(), rest.ptr, len, &n));
            if (n == 0) return error.Unexpected;
            rest = rest[n..];
        }
    }

    /// Seek and return the new absolute position.
    pub fn seek(self: *IStream, offset: i64, origin: u32) Error!u64 {
        var pos: u64 = 0;
        try check(self.vtable.Seek(self, offset, origin, &pos));
        return pos;
    }

    /// Read the whole stream (from the start) into a new allocation.
    pub fn readAllAlloc(self: *IStream, gpa: std.mem.Allocator, max_bytes: usize) (Error || std.mem.Allocator.Error)![]u8 {
        const size = try self.seek(0, STREAM_SEEK_END);
        if (size > max_bytes) return error.BufferTooSmall;
        _ = try self.seek(0, STREAM_SEEK_SET);
        const out = try gpa.alloc(u8, @intCast(size));
        errdefer gpa.free(out);
        var filled: usize = 0;
        while (filled < out.len) {
            const n = try self.read(out[filled..]);
            if (n == 0) return error.Unexpected;
            filled += n;
        }
        return out;
    }
};

/// A growable in-memory stream (CreateStreamOnHGlobal) that frees its memory
/// on the final Release.
pub fn createMemoryStream() Error!*IStream {
    var out: ?*IStream = null;
    return checkOut(IStream, CreateStreamOnHGlobal(null, TRUE, &out), out);
}

// ─── Tests ──────────────────────────────────────────────────────────────

/// Absolute vtable index of a direct field of `VTable` (inherited slots live
/// in `base` at offset 0, so a derived table's own slots continue after it).
pub fn slotIndex(comptime VTable: type, comptime name: []const u8) usize {
    return @offsetOf(VTable, name) / @sizeOf(usize);
}

test "unit: platform: com HRESULT mapping" {
    try std.testing.expect(succeeded(S_OK));
    try std.testing.expect(succeeded(S_FALSE));
    try std.testing.expect(failed(E_FAIL));
    try check(S_FALSE);
    try std.testing.expectError(error.RecreateTarget, check(D2DERR_RECREATE_TARGET));
    try std.testing.expectEqual(D2DERR_RECREATE_TARGET, last_failure);
    try std.testing.expectError(error.RecreateTarget, check(DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expectError(error.NoHardwareDevice, check(D2DERR_NO_HARDWARE_DEVICE));
    try std.testing.expectError(error.WrongState, check(D2DERR_WRONG_STATE));
    try std.testing.expectError(error.NoFont, check(DWRITE_E_NOFONT));
    try std.testing.expectError(error.Unexpected, check(E_FAIL));
    try std.testing.expectEqual(@as(u32, 0x8899000C), @as(u32, @bitCast(D2DERR_RECREATE_TARGET)));
}

test "unit: platform: com vtable slots match objidlbase.h" {
    try std.testing.expectEqual(@as(usize, 2), slotIndex(IUnknown.VTable, "Release"));
    try std.testing.expectEqual(@as(usize, 4), slotIndex(ISequentialStream.VTable, "Write"));
    try std.testing.expectEqual(@as(usize, 5), slotIndex(IStream.VTable, "Seek"));
    try std.testing.expectEqual(@as(usize, 13), slotIndex(IStream.VTable, "Clone"));
    try std.testing.expectEqual(@as(usize, 14 * @sizeOf(usize)), @sizeOf(IStream.VTable));
}

test "unit: platform: com GUID parsing" {
    const g = IUnknown.IID;
    try std.testing.expectEqual(@as(u32, 0), g.Data1);
    try std.testing.expectEqual(@as(u8, 0xC0), g.Data4[0]);
    try std.testing.expectEqual(@as(u8, 0x46), g.Data4[7]);
    try std.testing.expect(guidEql(&IUnknown.IID, &IUnknown.IID));
    try std.testing.expect(!guidEql(&IUnknown.IID, &IStream.IID));
}

test "unit: platform: com wrappers type-check" {
    std.testing.refAllDeclsRecursive(@This());
}
