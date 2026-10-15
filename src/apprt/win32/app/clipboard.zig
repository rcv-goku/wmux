//! The only clipboard access point (ARCHITECTURE.md ADR-1.6, ADR-12.3):
//! CF_UNICODETEXT on the system clipboard, or, in WMUX_TEST_MODE, an
//! in-process fake so automation never reads or clobbers the user's
//! clipboard. The Win32 code is the former Surface.clipboardRequest /
//! Surface.setClipboard bodies, moved here in W0-A1.

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.win32);

pub const Clipboard = struct {
    alloc: Allocator = undefined,

    /// WMUX_TEST_MODE: keep the clipboard inside this process.
    fake: bool = false,

    /// The fake clipboard's text (UTF-8, owned by `alloc`), if any.
    fake_text: ?[]u8 = null,

    /// Called once from App.init.
    pub fn init(self: *Clipboard, alloc: Allocator, fake: bool) void {
        self.* = .{ .alloc = alloc, .fake = fake };
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.fake_text) |t| self.alloc.free(t);
        self.fake_text = null;
    }

    /// The clipboard's text as UTF-8, owned by `alloc`, or null when it
    /// holds no text or cannot be read (failures are logged). `owner` is
    /// the window that opens the clipboard.
    pub fn readText(self: *Clipboard, alloc: Allocator, owner: ?w32.HWND) ?[]u8 {
        if (self.fake) {
            const text = self.fake_text orelse return null;
            return alloc.dupe(u8, text) catch null;
        }

        if (w32.OpenClipboard(owner) == 0) {
            log.warn("OpenClipboard failed", .{});
            return null;
        }
        defer _ = w32.CloseClipboard();

        // Retrieve CF_UNICODETEXT (UTF-16LE, null-terminated).
        const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse {
            // No text on the clipboard.
            return null;
        };

        const ptr16 = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed", .{});
            return null;
        };
        defer _ = w32.GlobalUnlock(hglobal);

        // Reinterpret the byte pointer as a u16 pointer for UTF-16LE data.
        const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));

        // Find the null terminator to get the length in u16 code units.
        var wlen: usize = 0;
        while (wptr[wlen] != 0) wlen += 1;

        // Convert UTF-16LE to a UTF-8 slice owned by the allocator.
        return std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
            log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
            return null;
        };
    }

    /// Replace the clipboard's text with `text` (UTF-8). Only an encoding
    /// allocation failure is returned; Win32 failures are logged and the
    /// clipboard is left as it was. `owner` is the window that opens the
    /// clipboard.
    pub fn writeText(self: *Clipboard, alloc: Allocator, owner: ?w32.HWND, text: []const u8) !void {
        if (self.fake) {
            const copy = try self.alloc.dupe(u8, text);
            if (self.fake_text) |old| self.alloc.free(old);
            self.fake_text = copy;
            return;
        }

        // Convert UTF-8 to UTF-16LE.  Add 1 for the null terminator.
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
        defer alloc.free(utf16);

        // Size in bytes including the null terminator (u16 → 2 bytes each).
        const byte_size = (utf16.len + 1) * @sizeOf(u16);

        // Allocate a moveable global memory block.
        const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse {
            log.warn("GlobalAlloc failed for clipboard write", .{});
            return;
        };

        const dst_bytes = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed for clipboard write", .{});
            _ = w32.GlobalFree(hglobal);
            return;
        };

        // Copy the UTF-16LE data (including null terminator) into the block.
        const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
        @memcpy(dst16[0..utf16.len], utf16);
        dst16[utf16.len] = 0; // null terminator

        _ = w32.GlobalUnlock(hglobal);

        if (w32.OpenClipboard(owner) == 0) {
            log.warn("OpenClipboard failed for clipboard write", .{});
            _ = w32.GlobalFree(hglobal);
            return;
        }
        defer _ = w32.CloseClipboard();

        _ = w32.EmptyClipboard();

        // SetClipboardData takes ownership of hglobal on success.
        if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
            log.warn("SetClipboardData failed", .{});
            _ = w32.GlobalFree(hglobal);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: clipboard fake round-trips text in process" {
    const alloc = testing.allocator;
    var cb: Clipboard = .{};
    cb.init(alloc, true);
    defer cb.deinit();

    // Empty until written.
    try testing.expect(cb.readText(alloc, null) == null);

    try cb.writeText(alloc, null, "first");
    try cb.writeText(alloc, null, "héllo ✓");
    const got = cb.readText(alloc, null).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("héllo ✓", got);
}
