//! `cmux guide` / `cmux --skill` (cli-guide-skill-command): the embedded
//! Markdown guide, printed before any socket discovery. `--json` returns
//! `{topic, format: "markdown", content}`; extra arguments are a usage
//! error. `--skill` is only recognized in command position (args.zig).

const std = @import("std");
const brand_mod = @import("brand.zig");
const Brand = brand_mod.Brand;

pub const text = @embedFile("help/guide.md");

pub const usage = "Usage: cmux guide | cmux --skill [--json]";

pub fn write(w: *std.Io.Writer, brand: Brand, json: bool) std.Io.Writer.Error!void {
    if (!json) return brand_mod.write(w, brand, text);
    var buf: [16 * 1024]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    brand_mod.write(&fw, brand, text) catch unreachable;
    try w.writeAll("{\n  \"topic\": ");
    try std.json.Stringify.encodeJsonString(brand.name(), .{}, w);
    try w.writeAll(",\n  \"format\": \"markdown\",\n  \"content\": ");
    try std.json.Stringify.encodeJsonString(fw.buffered(), .{}, w);
    try w.writeAll("\n}\n");
}

const testing = std.testing;

test "unit: cli-guide: text starts with the cmux heading and fits its buffer" {
    try testing.expect(std.mem.startsWith(u8, text, "# cmux guide\n"));
    try testing.expect(text.len < 16 * 1024);
}

test "unit: cli-guide: json form round-trips the content" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, .wmux, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("wmux", o.get("topic").?.string);
    try testing.expectEqualStrings("markdown", o.get("format").?.string);
    try testing.expect(std.mem.startsWith(u8, o.get("content").?.string, "# wmux guide\n"));
}
