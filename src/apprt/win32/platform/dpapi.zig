//! DPAPI bindings (ARCHITECTURE ADR-3.8): CryptProtectData /
//! CryptUnprotectData in the current-user scope with
//! CRYPTPROTECT_UI_FORBIDDEN, for the socket capability secret and the
//! socket control password files under `STATE\run\`.
//!
//! Memory rules: every DPAPI output blob is LocalFree'd; plaintext that this
//! file owns (the LocalAlloc'd output of `unprotect`) is zeroed before it is
//! freed, and the copy handed to the caller must be released with
//! `freeSecret`, which zeroes it too. Ciphertext is not secret.
//!
//! The pure core (blob sizing, error mapping, wiping) is tested on every OS;
//! the crypt32 wrappers are only analyzed when referenced and run on Windows.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;

pub const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;
pub const CRYPTPROTECT_LOCAL_MACHINE: u32 = 0x4;

/// Flags wmux always uses: current-user scope (no LOCAL_MACHINE), never
/// show UI.
pub const protect_flags: u32 = CRYPTPROTECT_UI_FORBIDDEN;

pub const DATA_BLOB = extern struct {
    cbData: u32,
    pbData: ?[*]u8,
};

// Error codes CryptUnprotectData reports (winerror.h).
pub const ERROR_ACCESS_DENIED: u32 = 5;
pub const ERROR_NOT_ENOUGH_MEMORY: u32 = 8;
pub const ERROR_INVALID_DATA: u32 = 13;
pub const ERROR_OUTOFMEMORY: u32 = 14;
pub const ERROR_INVALID_PARAMETER: u32 = 87;
pub const NTE_BAD_DATA: u32 = 0x8009_0005;
pub const NTE_BAD_KEY_STATE: u32 = 0x8009_000B;

pub const Error = error{
    /// The encrypted payload or its MAC was modified, the blob was
    /// truncated, or it was protected with different (or no) entropy.
    InvalidData,
    /// The master key the blob names is unavailable: the profile is not
    /// loaded, or the blob belongs to another user (or its header was
    /// damaged).
    KeyUnavailable,
    /// Input longer than a DATA_BLOB can describe (4 GiB).
    TooLarge,
    AccessDenied,
    InvalidParameter,
    OutOfMemory,
    Unexpected,
};

/// Raw error of the most recent failure on this thread (diagnostic only).
pub threadlocal var last_error: u32 = 0;

pub fn errorFromWin32(code: u32) Error {
    return switch (code) {
        ERROR_INVALID_DATA, NTE_BAD_DATA => error.InvalidData,
        NTE_BAD_KEY_STATE => error.KeyUnavailable,
        ERROR_ACCESS_DENIED => error.AccessDenied,
        ERROR_INVALID_PARAMETER => error.InvalidParameter,
        ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// `cbData` for a slice of `len` bytes.
pub fn blobLen(len: usize) Error!u32 {
    return std.math.cast(u32, len) orelse error.TooLarge;
}

/// Backing byte for empty inputs, so `pbData` is never null.
var empty_byte: u8 = 0;

/// A read-only DATA_BLOB view of `bytes` (DPAPI never writes input blobs).
pub fn blobFromSlice(bytes: []const u8) Error!DATA_BLOB {
    const len = try blobLen(bytes.len);
    const p: [*]u8 = if (bytes.len == 0) @ptrCast(&empty_byte) else @constCast(bytes.ptr);
    return .{ .cbData = len, .pbData = p };
}

/// Zero `bytes` in a way the optimizer cannot remove.
pub fn wipe(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

/// Zero and free a plaintext returned by `unprotect`.
pub fn freeSecret(gpa: std.mem.Allocator, secret: []u8) void {
    wipe(secret);
    gpa.free(secret);
}

// ─── crypt32 / kernel32 ─────────────────────────────────────────────────

extern "crypt32" fn CryptProtectData(
    pDataIn: *const DATA_BLOB,
    szDataDescr: ?[*:0]const u16,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: u32,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) BOOL;
extern "crypt32" fn CryptUnprotectData(
    pDataIn: *const DATA_BLOB,
    ppszDataDescr: ?*?[*:0]u16,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: u32,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn lastError() Error {
    const code = GetLastError();
    last_error = code;
    return errorFromWin32(code);
}

fn outSlice(blob: DATA_BLOB) []u8 {
    const p = blob.pbData orelse return &.{};
    return p[0..blob.cbData];
}

/// Encrypt `plaintext` for the current user. `entropy`, when given, must be
/// passed again to `unprotect`. Caller frees the ciphertext with `gpa.free`.
pub fn protect(gpa: std.mem.Allocator, plaintext: []const u8, entropy: ?[]const u8) Error![]u8 {
    const in = try blobFromSlice(plaintext);
    const ent: ?DATA_BLOB = if (entropy) |e| try blobFromSlice(e) else null;
    var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (CryptProtectData(&in, null, if (ent) |*e| e else null, null, null, protect_flags, &out) == 0)
        return lastError();
    defer _ = LocalFree(out.pbData);
    return gpa.dupe(u8, outSlice(out));
}

/// Decrypt a `protect` result. Wrong or missing entropy, truncation or a
/// modified payload/MAC is `error.InvalidData`; a damaged header can also
/// fail with `KeyUnavailable`, `InvalidParameter` or `Unexpected`, so treat
/// every error as "cannot decrypt". Release the plaintext with `freeSecret`.
pub fn unprotect(gpa: std.mem.Allocator, ciphertext: []const u8, entropy: ?[]const u8) Error![]u8 {
    const in = try blobFromSlice(ciphertext);
    const ent: ?DATA_BLOB = if (entropy) |e| try blobFromSlice(e) else null;
    var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (CryptUnprotectData(&in, null, if (ent) |*e| e else null, null, null, protect_flags, &out) == 0)
        return lastError();
    const plain = outSlice(out);
    defer {
        wipe(plain);
        _ = LocalFree(out.pbData);
    }
    return gpa.dupe(u8, plain);
}

// ─── Tests (pure core; run on every OS) ─────────────────────────────────

test "unit: platform: dpapi flags are current-user and UI-forbidden" {
    try std.testing.expect(protect_flags & CRYPTPROTECT_UI_FORBIDDEN != 0);
    try std.testing.expect(protect_flags & CRYPTPROTECT_LOCAL_MACHINE == 0);
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 16), @sizeOf(DATA_BLOB));
}

test "unit: platform: dpapi blob sizing" {
    try std.testing.expectEqual(@as(u32, 0), try blobLen(0));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try blobLen(std.math.maxInt(u32)));
    if (@sizeOf(usize) > 4) {
        try std.testing.expectError(error.TooLarge, blobLen(@as(usize, std.math.maxInt(u32)) + 1));
        try std.testing.expectError(error.TooLarge, blobLen(std.math.maxInt(usize)));
    }
    // Empty input still has a non-null pointer; data is not copied.
    const empty = try blobFromSlice("");
    try std.testing.expectEqual(@as(u32, 0), empty.cbData);
    try std.testing.expect(empty.pbData != null);
    const text = "h\xc3\xa9llo \xf0\x9f\x94\x91";
    const b = try blobFromSlice(text);
    try std.testing.expectEqual(@as(u32, text.len), b.cbData);
    try std.testing.expectEqual(@intFromPtr(text.ptr), @intFromPtr(b.pbData.?));
}

test "unit: platform: dpapi error mapping" {
    try std.testing.expectEqual(error.InvalidData, errorFromWin32(ERROR_INVALID_DATA));
    try std.testing.expectEqual(error.InvalidData, errorFromWin32(NTE_BAD_DATA));
    try std.testing.expectEqual(error.KeyUnavailable, errorFromWin32(NTE_BAD_KEY_STATE));
    try std.testing.expectEqual(error.AccessDenied, errorFromWin32(ERROR_ACCESS_DENIED));
    try std.testing.expectEqual(error.InvalidParameter, errorFromWin32(ERROR_INVALID_PARAMETER));
    try std.testing.expectEqual(error.OutOfMemory, errorFromWin32(ERROR_OUTOFMEMORY));
    try std.testing.expectEqual(error.Unexpected, errorFromWin32(0));
}

test "unit: platform: dpapi wipe zeroes secrets" {
    var buf = [_]u8{ 's', 'e', 'c', 'r', 'e', 't', 0xff };
    wipe(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 7, &buf);
    wipe(buf[0..0]);
    const gpa = std.testing.allocator;
    freeSecret(gpa, try gpa.dupe(u8, "password"));
    freeSecret(gpa, try gpa.alloc(u8, 0));
}
