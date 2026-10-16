//! The title of a tab or a workspace (ARCHITECTURE.md ADR-2.3): `custom` is
//! set by a user rename, `auto` by everything else (the initial title, the
//! shell's OSC 0/2, a browser document title, later auto-naming), and the
//! displayed text is `custom orelse auto`. Strings are heap-owned (G6) and
//! hold UTF-8, or WTF-8 when a rename typed an unpaired surrogate; every
//! setter caps the stored bytes at `max_bytes` on a code-point boundary.
const Title = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const titles = @import("logic/titles.zig");

/// Who set the displayed text last.
pub const Source = enum { auto, user, process, agent };

/// Byte cap of each stored string (callers apply their own, tighter caps).
pub const max_bytes: usize = 1024;

custom: ?[]u8 = null,
auto: ?[]u8 = null,
source: Source = .auto,

/// The displayed text: the user's rename when set, else the auto title.
pub fn text(self: *const Title) ?[]const u8 {
    return self.custom orelse self.auto;
}

/// Set the user rename (source = .user).
pub fn setCustom(self: *Title, gpa: Allocator, value: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, titles.capUtf8(value, max_bytes));
    if (self.custom) |old| gpa.free(old);
    self.custom = copy;
    self.source = .user;
}

/// Set the automatic title from `source`. Pass `clear_custom` to also drop
/// a user rename (the pre-ADR-2.3 behavior: the next shell title replaces
/// a rename; W0-A2 keeps it until "renames stick" ships, ui-model 8.1 #12).
pub fn setAuto(
    self: *Title,
    gpa: Allocator,
    value: []const u8,
    source: Source,
    clear_custom: bool,
) Allocator.Error!void {
    const copy = try gpa.dupe(u8, titles.capUtf8(value, max_bytes));
    if (self.auto) |old| gpa.free(old);
    self.auto = copy;
    if (clear_custom) self.clearCustom(gpa);
    if (self.custom == null) self.source = source;
}

/// Drop the user rename, if any.
pub fn clearCustom(self: *Title, gpa: Allocator) void {
    if (self.custom) |old| gpa.free(old);
    self.custom = null;
}

pub fn deinit(self: *Title, gpa: Allocator) void {
    if (self.custom) |s| gpa.free(s);
    if (self.auto) |s| gpa.free(s);
    self.* = .{};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: title custom wins over auto" {
    var t: Title = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), t.text());
    try t.setAuto(testing.allocator, "Ghostty", .auto, false);
    try testing.expectEqualStrings("Ghostty", t.text().?);
    try t.setCustom(testing.allocator, "build");
    try testing.expectEqualStrings("build", t.text().?);
    try testing.expectEqual(Source.user, t.source);
    // An auto update that keeps the rename leaves the display alone.
    try t.setAuto(testing.allocator, "vim", .process, false);
    try testing.expectEqualStrings("build", t.text().?);
    try testing.expectEqual(Source.user, t.source);
}

test "unit: model: title auto update can replace a rename" {
    var t: Title = .{};
    defer t.deinit(testing.allocator);
    try t.setCustom(testing.allocator, "mine");
    try t.setAuto(testing.allocator, "~/src", .process, true);
    try testing.expectEqualStrings("~/src", t.text().?);
    try testing.expectEqual(@as(?[]u8, null), t.custom);
    try testing.expectEqual(Source.process, t.source);
}

test "unit: model: title caps stored bytes on a code-point boundary" {
    var t: Title = .{};
    defer t.deinit(testing.allocator);
    var long: [max_bytes + 3]u8 = undefined;
    @memset(&long, 'a');
    // A 2-byte sequence straddling the cap is dropped whole.
    long[max_bytes - 1] = 0xC3;
    long[max_bytes] = 0xA9;
    try t.setAuto(testing.allocator, &long, .auto, false);
    try testing.expectEqual(max_bytes - 1, t.text().?.len);
}
