//! `cmux version` / `--version` / `-v` (cli-version-command): the CLI's own
//! summary, offline. Format `cmux <version> (<build>) [<short commit>]` with
//! the degraded forms `cmux <version>`, `cmux build <build>` and `cmux
//! version unknown`; the commit appears only when known. Build options may
//! carry `version`, `build` and `commit` (each optional).

const std = @import("std");
const build_options = @import("wmux_build_options");
const Brand = @import("brand.zig").Brand;

pub const Info = struct {
    version: ?[]const u8 = null,
    build: ?[]const u8 = null,
    commit: ?[]const u8 = null,
};

fn opt(comptime name: []const u8) ?[]const u8 {
    if (!@hasDecl(build_options, name)) return null;
    const v: []const u8 = @field(build_options, name);
    return if (v.len == 0) null else v;
}

/// What this binary was built with.
pub const compiled: Info = .{ .version = opt("version"), .build = opt("build"), .commit = opt("commit") };

/// Short commit: the first 7 characters of a hex hash, else as given.
fn shortCommit(c: []const u8) []const u8 {
    for (c) |ch| if (!std.ascii.isHex(ch)) return c;
    return c[0..@min(c.len, 7)];
}

/// The summary line without a newline.
pub fn writeSummary(w: *std.Io.Writer, brand: Brand, info: Info) std.Io.Writer.Error!void {
    try w.writeAll(brand.name());
    if (info.version) |v| {
        try w.print(" {s}", .{v});
        if (info.build) |b| try w.print(" ({s})", .{b});
    } else if (info.build) |b| {
        try w.print(" build {s}", .{b});
    } else {
        try w.writeAll(" version unknown");
    }
    if (info.commit) |c| try w.print(" [{s}]", .{shortCommit(c)});
}

pub fn summaryAlloc(gpa: std.mem.Allocator, brand: Brand, info: Info) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeSummary(&aw.writer, brand, info) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

fn expectSummary(want: []const u8, brand: Brand, info: Info) !void {
    const got = try summaryAlloc(testing.allocator, brand, info);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "unit: cli-version: summary and degraded forms" {
    try expectSummary("cmux 1.2.3 (456) [abcdef1]", .cmux, .{ .version = "1.2.3", .build = "456", .commit = "abcdef1234567890" });
    try expectSummary("cmux 1.2.3 (456)", .cmux, .{ .version = "1.2.3", .build = "456" });
    try expectSummary("wmux 1.2.3", .wmux, .{ .version = "1.2.3" });
    try expectSummary("cmux build 456", .cmux, .{ .build = "456" });
    try expectSummary("cmux version unknown", .cmux, .{});
    try expectSummary("cmux version unknown [dirty-tree]", .cmux, .{ .commit = "dirty-tree" });
    try expectSummary("cmux 1.0 [abc]", .cmux, .{ .version = "1.0", .commit = "abc" });
}

test "unit: cli-version: compiled summary matches cmux shape" {
    const got = try summaryAlloc(testing.allocator, .cmux, compiled);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "cmux "));
    try testing.expect(std.mem.indexOfScalar(u8, got, '\n') == null);
}
