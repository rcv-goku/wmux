//! Shell bindings (ARCHITECTURE ADR-1.1 platform layer) for paths, the
//! open/explorer features and default-app lookup:
//!
//! - `knownFolderPath`: SHGetKnownFolderPath (LocalAppData, RoamingAppData,
//!   Profile) as UTF-8 (WTF-8 for unpaired surrogates); the PWSTR is always
//!   CoTaskMemFree'd.
//! - `shellExecute`: ShellExecuteExW with the `open`/`explore` verbs. It
//!   launches visible programs, so tests never call it.
//! - `revealInExplorer`: ILCreateFromPathW + SHOpenFolderAndSelectItems +
//!   ILFree (open the folder with the item selected). Also visible; never
//!   called by tests.
//! - `assocQueryString`: AssocQueryStringW for the default app of an
//!   extension or ProgID.
//!
//! Callers on the UI thread must remember G4 (no focus stealing): only user
//! gestures may reach `shellExecute`/`revealInExplorer`.
//!
//! The pure core (UTF-8 <-> UTF-16 conversion, separators, input validation,
//! buffer growth, error mapping) is tested on every OS; the Win32 wrappers are
//! only analyzed when referenced.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// Self-contained on purpose (no `com.zig` import): com.zig's HRESULT
// constants only compile where `c_long` is 32 bits, and the pure core below
// must be testable on Linux. On Windows these types are identical to
// com.zig's, so values pass between the two files unchanged.
pub const HRESULT = if (builtin.os.tag == .windows) windows.HRESULT else i32;
pub const GUID = windows.GUID;
pub const BOOL = windows.BOOL;
pub const HWND = windows.HWND;

fn hresult(comptime value: u32) HRESULT {
    return @bitCast(value);
}

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_POINTER = hresult(0x80004003);
pub const E_FAIL = hresult(0x80004005);
pub const E_ACCESSDENIED = hresult(0x80070005);
pub const E_OUTOFMEMORY = hresult(0x8007000E);
pub const E_INVALIDARG = hresult(0x80070057);
pub const E_FILE_NOT_FOUND = hresult(0x80070002);
pub const E_PATH_NOT_FOUND = hresult(0x80070003);
pub const E_INSUFFICIENT_BUFFER = hresult(0x8007007A);
pub const E_NO_ASSOCIATION = hresult(0x80070483);
pub const E_CANCELLED = hresult(0x800704C7);
pub const RPC_E_CHANGED_MODE = hresult(0x80010106);
pub const CO_E_NOTINITIALIZED = hresult(0x800401F0);

// ─── Errors ─────────────────────────────────────────────────────────────

/// Error names shared with `com.Error` mean the same thing.
pub const Error = error{
    /// Empty path, embedded NUL, or longer than `max_wide_len`.
    InvalidPath,
    /// Input is not valid UTF-8 (WTF-8).
    InvalidUtf8,
    /// No application is associated with the file type or verb.
    NoAssociation,
    /// The user cancelled (e.g. an elevation or "Open with" prompt).
    Cancelled,
    FileNotFound,
    AccessDenied,
    OutOfMemory,
    InvalidArg,
    BufferTooSmall,
    ComNotInitialized,
    Unexpected,
};

pub const ERROR_FILE_NOT_FOUND: u32 = 2;
pub const ERROR_PATH_NOT_FOUND: u32 = 3;
pub const ERROR_ACCESS_DENIED: u32 = 5;
pub const ERROR_NOT_ENOUGH_MEMORY: u32 = 8;
pub const ERROR_OUTOFMEMORY: u32 = 14;
pub const ERROR_INVALID_PARAMETER: u32 = 87;
pub const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
pub const ERROR_NO_ASSOCIATION: u32 = 1155;
pub const ERROR_CANCELLED: u32 = 1223;

/// HRESULT_FROM_WIN32.
pub fn hresultFromWin32(code: u32) HRESULT {
    if (code == 0) return S_OK;
    return @bitCast((code & 0xFFFF) | 0x8007_0000);
}

/// Raw error of the most recent failure on this thread (an HRESULT, or a
/// Win32 code converted with `hresultFromWin32`). Diagnostic only.
pub threadlocal var last_failure: HRESULT = S_OK;

/// Map a failed HRESULT; success codes are not valid input.
pub fn errorFromHresult(hr: HRESULT) Error {
    return switch (hr) {
        E_NO_ASSOCIATION => error.NoAssociation,
        E_CANCELLED => error.Cancelled,
        E_FILE_NOT_FOUND, E_PATH_NOT_FOUND => error.FileNotFound,
        E_ACCESSDENIED => error.AccessDenied,
        E_OUTOFMEMORY => error.OutOfMemory,
        E_INVALIDARG, E_POINTER => error.InvalidArg,
        E_INSUFFICIENT_BUFFER => error.BufferTooSmall,
        CO_E_NOTINITIALIZED => error.ComNotInitialized,
        else => error.Unexpected,
    };
}

/// Map a Win32 error code (GetLastError after ShellExecuteExW).
pub fn errorFromWin32(code: u32) Error {
    return errorFromHresult(hresultFromWin32(code));
}

fn check(hr: HRESULT) Error!void {
    if (hr >= 0) return;
    last_failure = hr;
    return errorFromHresult(hr);
}

// ─── Pure core ──────────────────────────────────────────────────────────

/// Longest path or association key accepted, in UTF-16 units (the extended
/// path limit).
pub const max_wide_len: usize = 32767;

/// UTF-8 (WTF-8) to a NUL-terminated UTF-16 string for Win32. Rejects empty
/// input, embedded NULs and over-long input. Caller frees.
pub fn toWideZ(gpa: std.mem.Allocator, utf8: []const u8) Error![:0]u16 {
    if (utf8.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, utf8, 0) != null) return error.InvalidPath;
    // Each UTF-16 unit takes at least one byte; bail out before allocating.
    if (utf8.len > max_wide_len * 3) return error.InvalidPath;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, utf8) catch |err| return switch (err) {
        error.InvalidWtf8 => error.InvalidUtf8,
        error.OutOfMemory => error.OutOfMemory,
    };
    if (wide.len > max_wide_len) {
        gpa.free(wide);
        return error.InvalidPath;
    }
    return wide;
}

/// UTF-16 from Win32 to UTF-8 (WTF-8 keeps unpaired surrogates lossless).
/// Caller frees.
pub fn fromWide(gpa: std.mem.Allocator, wide: []const u16) error{OutOfMemory}![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(gpa, wide);
}

/// `fromWide` over a NUL-terminated PWSTR.
pub fn fromWideZ(gpa: std.mem.Allocator, wide: [*:0]const u16) error{OutOfMemory}![]u8 {
    return fromWide(gpa, std.mem.span(wide));
}

/// Replace `/` with `\` in place (ILCreateFromPathW wants backslashes).
pub fn toBackslashes(wide: []u16) void {
    for (wide) |*c| {
        if (c.* == '/') c.* = '\\';
    }
}

/// Growth policy for AssocQueryStringW output buffers (UTF-16 units incl.
/// the NUL): take the reported size when it is larger, else double; null
/// past `max_wide_len + 1`.
pub fn nextAssocCapacity(current: usize, reported: u32) ?usize {
    const limit = max_wide_len + 1;
    if (current >= limit) return null;
    const wanted = @max(@as(usize, reported), current *| 2, 64);
    return @min(wanted, limit);
}

// ─── Known folders, verbs, association strings ──────────────────────────

pub const KnownFolder = enum {
    /// `%LOCALAPPDATA%` (FOLDERID_LocalAppData).
    local_app_data,
    /// `%APPDATA%` (FOLDERID_RoamingAppData).
    roaming_app_data,
    /// `%USERPROFILE%` (FOLDERID_Profile).
    profile,

    pub fn id(self: KnownFolder) GUID {
        return switch (self) {
            .local_app_data => comptime GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}"),
            .roaming_app_data => comptime GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}"),
            .profile => comptime GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}"),
        };
    }
};

/// KNOWN_FOLDER_FLAG: no creation, no redirection tweaks.
pub const KF_FLAG_DEFAULT: u32 = 0;

pub const Verb = enum {
    /// Open a file with its default app, a URL with the browser, a folder
    /// in Explorer.
    open,
    /// Open a folder in an Explorer window with the folder pane.
    explore,

    pub fn wide(self: Verb) [:0]const u16 {
        return switch (self) {
            .open => std.unicode.utf8ToUtf16LeStringLiteral("open"),
            .explore => std.unicode.utf8ToUtf16LeStringLiteral("explore"),
        };
    }
};

/// ASSOCSTR values (shlwapi.h) wmux uses.
pub const AssocStr = enum(u32) {
    /// The command line of the verb.
    command = 1,
    /// The executable of the verb.
    executable = 2,
    /// "Text Document".
    friendly_doc_name = 3,
    /// "Notepad".
    friendly_app_name = 4,
};

pub const ASSOCF_NOTRUNCATE: u32 = 0x0000_0020;
pub const ASSOCF_INIT_IGNOREUNKNOWN: u32 = 0x0000_0400;
/// Unknown types fail with NoAssociation instead of naming "Open With".
pub const assoc_flags: u32 = ASSOCF_NOTRUNCATE | ASSOCF_INIT_IGNOREUNKNOWN;

pub const SEE_MASK_NOASYNC: u32 = 0x0000_0100;
pub const SEE_MASK_FLAG_NO_UI: u32 = 0x0000_0400;
pub const SEE_MASK_UNICODE: u32 = 0x0000_4000;
/// Synchronous (the caller may be a short-lived worker thread) and no
/// error dialogs: errors come back as Zig errors.
pub const shell_execute_mask: u32 = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI | SEE_MASK_UNICODE;
pub const SW_SHOWNORMAL: i32 = 1;

pub const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
    fMask: u32 = 0,
    hwnd: ?HWND = null,
    lpVerb: ?[*:0]const u16 = null,
    lpFile: ?[*:0]const u16 = null,
    lpParameters: ?[*:0]const u16 = null,
    lpDirectory: ?[*:0]const u16 = null,
    nShow: i32 = 0,
    hInstApp: ?*anyopaque = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?[*:0]const u16 = null,
    hkeyClass: ?*anyopaque = null,
    dwHotKey: u32 = 0,
    hIconOrMonitor: ?*anyopaque = null,
    hProcess: ?*anyopaque = null,
};

/// Opaque shell item id list (shtypes.h ITEMIDLIST).
pub const ITEMIDLIST = opaque {};

// ─── shell32 / shlwapi / kernel32 ───────────────────────────────────────

extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(.winapi) HRESULT;
extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
extern "shell32" fn ILCreateFromPathW(path: [*:0]const u16) callconv(.winapi) ?*ITEMIDLIST;
extern "shell32" fn ILFree(pidl: ?*ITEMIDLIST) callconv(.winapi) void;
extern "shell32" fn SHOpenFolderAndSelectItems(
    folder: *const ITEMIDLIST,
    count: u32,
    items: ?[*]const *const ITEMIDLIST,
    flags: u32,
) callconv(.winapi) HRESULT;
extern "shlwapi" fn AssocQueryStringW(
    flags: u32,
    str: u32,
    assoc: [*:0]const u16,
    extra: ?[*:0]const u16,
    out: ?[*]u16,
    out_len: *u32,
) callconv(.winapi) HRESULT;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

const COINIT_APARTMENTTHREADED: u32 = 0x2;
const COINIT_DISABLE_OLE1DDE: u32 = 0x4;

/// Balanced CoInitializeEx(STA) for the shell calls that need COM. A thread
/// already in the MTA (RPC_E_CHANGED_MODE) keeps it and nothing is undone.
const ComScope = struct {
    needs_uninit: bool,

    fn init() Error!ComScope {
        const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        if (hr == RPC_E_CHANGED_MODE) return .{ .needs_uninit = false };
        try check(hr);
        return .{ .needs_uninit = true };
    }

    fn deinit(self: ComScope) void {
        if (self.needs_uninit) CoUninitialize();
    }
};

// ─── Wrappers ───────────────────────────────────────────────────────────

/// Absolute path of a known folder as UTF-8. Caller frees. Does not need
/// COM initialized.
pub fn knownFolderPath(gpa: std.mem.Allocator, folder: KnownFolder) Error![]u8 {
    var raw: ?[*:0]u16 = null;
    const rfid = folder.id();
    const hr = SHGetKnownFolderPath(&rfid, KF_FLAG_DEFAULT, null, &raw);
    // The PWSTR must be freed even when the call fails.
    defer CoTaskMemFree(raw);
    try check(hr);
    const p = raw orelse return error.Unexpected;
    return fromWideZ(gpa, p);
}

/// ShellExecuteExW(`verb`, `target`) with SW_SHOWNORMAL, synchronously and
/// without error UI. Visible by design: call only for user gestures.
pub fn shellExecute(gpa: std.mem.Allocator, verb: Verb, target: []const u8) Error!void {
    const file = try toWideZ(gpa, target);
    defer gpa.free(file);
    var info: SHELLEXECUTEINFOW = .{
        .fMask = shell_execute_mask,
        .lpVerb = verb.wide().ptr,
        .lpFile = file.ptr,
        .nShow = SW_SHOWNORMAL,
    };
    if (ShellExecuteExW(&info) == 0) {
        const code = GetLastError();
        last_failure = hresultFromWin32(code);
        return errorFromWin32(code);
    }
}

/// Open the folder that contains `path` in Explorer with the item selected
/// (ILCreateFromPathW / SHOpenFolderAndSelectItems / ILFree). Initializes
/// COM on the calling thread for the duration (balanced). Visible by design.
pub fn revealInExplorer(gpa: std.mem.Allocator, path: []const u8) Error!void {
    const wide = try toWideZ(gpa, path);
    defer gpa.free(wide);
    toBackslashes(wide);
    const scope = try ComScope.init();
    defer scope.deinit();
    const pidl = ILCreateFromPathW(wide.ptr) orelse {
        last_failure = E_FILE_NOT_FOUND;
        return error.FileNotFound;
    };
    defer ILFree(pidl);
    try check(SHOpenFolderAndSelectItems(pidl, 0, null, 0));
}

/// AssocQueryStringW for `key` (an extension such as ".txt" or a ProgID)
/// and optional `verb` (null = default verb). Returns UTF-8; caller frees.
/// Unassociated types fail with `error.NoAssociation`.
pub fn assocQueryString(gpa: std.mem.Allocator, what: AssocStr, key: []const u8, verb: ?[]const u8) Error![]u8 {
    const key_w = try toWideZ(gpa, key);
    defer gpa.free(key_w);
    const verb_w: ?[:0]u16 = if (verb) |v| try toWideZ(gpa, v) else null;
    defer if (verb_w) |v| gpa.free(v);
    const extra: ?[*:0]const u16 = if (verb_w) |v| v.ptr else null;

    // Sizing call: S_FALSE with the needed length (incl. NUL).
    var reported: u32 = 0;
    try check(AssocQueryStringW(assoc_flags, @intFromEnum(what), key_w.ptr, extra, null, &reported));
    var capacity: usize = nextAssocCapacity(0, reported) orelse return error.BufferTooSmall;
    while (true) {
        const buf = try gpa.alloc(u16, capacity);
        defer gpa.free(buf);
        var len: u32 = @intCast(buf.len);
        const hr = AssocQueryStringW(assoc_flags, @intFromEnum(what), key_w.ptr, extra, buf.ptr, &len);
        if (hr == E_POINTER or hr == E_INSUFFICIENT_BUFFER) {
            capacity = nextAssocCapacity(capacity, len) orelse return error.BufferTooSmall;
            continue;
        }
        try check(hr);
        const text = std.mem.sliceTo(buf, 0);
        if (text.len == 0) return error.NoAssociation;
        return fromWide(gpa, text);
    }
}

// ─── Tests (pure core; run on every OS) ─────────────────────────────────

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "unit: platform: shell UTF-8 to UTF-16 conversion" {
    const gpa = std.testing.allocator;
    const ascii = try toWideZ(gpa, "C:\\Users\\me");
    defer gpa.free(ascii);
    try std.testing.expectEqualSlices(u16, L("C:\\Users\\me"), ascii);
    try std.testing.expectEqual(@as(u16, 0), ascii[ascii.len]);

    // BMP and astral code points (surrogate pair).
    const uni = try toWideZ(gpa, "C:\\Z\xc3\xbcrich\\\xf0\x9f\x93\x81");
    defer gpa.free(uni);
    try std.testing.expectEqualSlices(u16, L("C:\\Z\u{fc}rich\\\u{1F4C1}"), uni);
    const back = try fromWide(gpa, uni);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("C:\\Z\xc3\xbcrich\\\xf0\x9f\x93\x81", back);

    // Rejected inputs.
    try std.testing.expectError(error.InvalidPath, toWideZ(gpa, ""));
    try std.testing.expectError(error.InvalidPath, toWideZ(gpa, "a\x00b"));
    try std.testing.expectError(error.InvalidUtf8, toWideZ(gpa, "\xff\xfe"));
    try std.testing.expectError(error.InvalidUtf8, toWideZ(gpa, "abc\xc3"));
}

test "unit: platform: shell path length boundaries" {
    const gpa = std.testing.allocator;
    const max = try gpa.alloc(u8, max_wide_len);
    defer gpa.free(max);
    @memset(max, 'a');
    const ok = try toWideZ(gpa, max);
    defer gpa.free(ok);
    try std.testing.expectEqual(max_wide_len, ok.len);

    const over = try gpa.alloc(u8, max_wide_len + 1);
    defer gpa.free(over);
    @memset(over, 'a');
    try std.testing.expectError(error.InvalidPath, toWideZ(gpa, over));

    // Huge input is rejected before any allocation of its size.
    const huge = try gpa.alloc(u8, max_wide_len * 3 + 1);
    defer gpa.free(huge);
    @memset(huge, 'a');
    try std.testing.expectError(error.InvalidPath, toWideZ(gpa, huge));
}

test "unit: platform: shell WTF-16 output keeps unpaired surrogates" {
    const gpa = std.testing.allocator;
    const lone = [_:0]u16{ 'x', 0xD800, 'y' };
    const s = try fromWideZ(gpa, &lone);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("x\xed\xa0\x80y", s);
    // And it round-trips back to the same units.
    const w = try toWideZ(gpa, s);
    defer gpa.free(w);
    try std.testing.expectEqualSlices(u16, &lone, w);
    const empty = try fromWide(gpa, &.{});
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "unit: platform: shell separators" {
    var buf = L("C:/a/b\\c/").*;
    toBackslashes(&buf);
    try std.testing.expectEqualSlices(u16, L("C:\\a\\b\\c\\"), &buf);
    toBackslashes(buf[0..0]);
}

test "unit: platform: shell known folder ids match KnownFolders.h" {
    const lad = KnownFolder.local_app_data.id();
    try std.testing.expectEqual(@as(u32, 0xF1B32785), lad.Data1);
    try std.testing.expectEqual(@as(u16, 0x6FBA), lad.Data2);
    try std.testing.expectEqual(@as(u16, 0x4FCF), lad.Data3);
    try std.testing.expectEqualSlices(u8, &.{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 }, &lad.Data4);
    try std.testing.expectEqual(@as(u32, 0x3EB685DB), KnownFolder.roaming_app_data.id().Data1);
    try std.testing.expectEqual(@as(u32, 0x5E6C858F), KnownFolder.profile.id().Data1);
    // All distinct.
    const all = [_]KnownFolder{ .local_app_data, .roaming_app_data, .profile };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| {
        try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&a.id()), std.mem.asBytes(&b.id())));
    };
}

test "unit: platform: shell verbs, flags and struct layout" {
    try std.testing.expectEqualSlices(u16, L("open"), Verb.open.wide());
    try std.testing.expectEqualSlices(u16, L("explore"), Verb.explore.wide());
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(AssocStr.executable));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(AssocStr.friendly_app_name));
    try std.testing.expectEqual(@as(u32, 0x420), assoc_flags);
    try std.testing.expectEqual(@as(u32, 0x4500), shell_execute_mask);
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 112), @sizeOf(SHELLEXECUTEINFOW));
        try std.testing.expectEqual(@as(usize, 48), @offsetOf(SHELLEXECUTEINFOW, "nShow"));
        try std.testing.expectEqual(@as(usize, 104), @offsetOf(SHELLEXECUTEINFOW, "hProcess"));
    }
    const info: SHELLEXECUTEINFOW = .{};
    try std.testing.expectEqual(@as(u32, @sizeOf(SHELLEXECUTEINFOW)), info.cbSize);
}

test "unit: platform: shell error mapping" {
    try std.testing.expectEqual(@as(HRESULT, @bitCast(@as(u32, 0x80070483))), E_NO_ASSOCIATION);
    try std.testing.expectEqual(S_OK, hresultFromWin32(0));
    try std.testing.expectEqual(E_FILE_NOT_FOUND, hresultFromWin32(ERROR_FILE_NOT_FOUND));
    try std.testing.expectEqual(error.NoAssociation, errorFromWin32(ERROR_NO_ASSOCIATION));
    try std.testing.expectEqual(error.Cancelled, errorFromWin32(ERROR_CANCELLED));
    try std.testing.expectEqual(error.FileNotFound, errorFromWin32(ERROR_FILE_NOT_FOUND));
    try std.testing.expectEqual(error.FileNotFound, errorFromWin32(ERROR_PATH_NOT_FOUND));
    try std.testing.expectEqual(error.AccessDenied, errorFromWin32(ERROR_ACCESS_DENIED));
    try std.testing.expectEqual(error.OutOfMemory, errorFromWin32(ERROR_OUTOFMEMORY));
    try std.testing.expectEqual(error.InvalidArg, errorFromWin32(ERROR_INVALID_PARAMETER));
    try std.testing.expectEqual(error.BufferTooSmall, errorFromHresult(E_INSUFFICIENT_BUFFER));
    try std.testing.expectEqual(error.Unexpected, errorFromHresult(E_FAIL));
}

test "unit: platform: shell association buffer growth" {
    try std.testing.expectEqual(@as(?usize, 64), nextAssocCapacity(0, 0));
    try std.testing.expectEqual(@as(?usize, 300), nextAssocCapacity(0, 300));
    try std.testing.expectEqual(@as(?usize, 600), nextAssocCapacity(300, 10));
    try std.testing.expectEqual(@as(?usize, max_wide_len + 1), nextAssocCapacity(64, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(?usize, null), nextAssocCapacity(max_wide_len + 1, 5));
}
