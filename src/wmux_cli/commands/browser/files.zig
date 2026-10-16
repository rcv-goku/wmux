//! File writes for the browser family (`disable-browser`/`enable-browser`
//! settings edits, `screenshot --out`). `platform.zig` has no write entry
//! point, so the family owns this hook: native builds write through std.fs
//! (creating parent directories); tests install an in-memory writer.

const std = @import("std");

pub const WriteFn = *const fn (ctx: ?*anyopaque, path: []const u8, bytes: []const u8) bool;

pub const Writer = struct {
    ctx: ?*anyopaque = null,
    func: WriteFn = nativeWrite,

    pub fn write(self: Writer, path: []const u8, bytes: []const u8) bool {
        return self.func(self.ctx, path, bytes);
    }
};

/// The active writer (tests swap it and restore `.{}`).
pub var writer: Writer = .{};

fn nativeWrite(_: ?*anyopaque, path: []const u8, bytes: []const u8) bool {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return false;
    // Write a sibling temp file, then rename over the target (atomic on
    // NTFS and POSIX file systems).
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp-{d}", .{ path, std.crypto.random.int(u32) }) catch return false;
    std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = bytes }) catch return false;
    std.fs.cwd().rename(tmp, path) catch {
        std.fs.cwd().deleteFile(tmp) catch {};
        return false;
    };
    return true;
}

/// In-memory writer for tests: records every write; `fail` rejects them.
pub const Memory = struct {
    a: std.mem.Allocator,
    files: std.ArrayList(struct { path: []const u8, bytes: []const u8 }) = .empty,
    fail: bool = false,

    pub fn writer(self: *Memory) Writer {
        return .{ .ctx = self, .func = memWrite };
    }

    fn memWrite(ctx: ?*anyopaque, path: []const u8, bytes: []const u8) bool {
        const self: *Memory = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return false;
        const p = self.a.dupe(u8, path) catch return false;
        const b = self.a.dupe(u8, bytes) catch return false;
        self.files.append(self.a, .{ .path = p, .bytes = b }) catch return false;
        return true;
    }

    /// The last bytes written to `path`.
    pub fn get(self: *const Memory, path: []const u8) ?[]const u8 {
        var out: ?[]const u8 = null;
        for (self.files.items) |f| if (std.mem.eql(u8, f.path, path)) {
            out = f.bytes;
        };
        return out;
    }
};

test "unit: browser-cli: native writer creates directories and replaces files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "b", "f.json" });
    defer std.testing.allocator.free(path);
    try std.testing.expect(nativeWrite(null, path, "one"));
    try std.testing.expect(nativeWrite(null, path, "two \u{1F600}"));
    const got = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("two \u{1F600}", got);
}
