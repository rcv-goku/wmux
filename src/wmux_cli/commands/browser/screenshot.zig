//! `browser screenshot [--out <path>]` output (SPEC.json
//! `browser-cli-screenshot`): `browser.screenshot` returns `{png_base64,
//! path, url}`. `--out` writes the PNG there (from the base64 data, else by
//! copying the app's file) and prints `OK <out>`; otherwise the app's file
//! URL (or path) is printed, and the PNG goes to a CLI temp file only when
//! the app gave no file. JSON omits `png_base64` once a file exists.

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const paths = proto.paths;
const command = @import("../../command.zig");
const Ctx = command.Ctx;
const output = @import("../../output.zig");
const plan_mod = @import("plan.zig");
const files = @import("files.zig");

/// Largest PNG the CLI copies from the app's file.
pub const max_png_bytes = 256 * 1024 * 1024;

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string and f.string.len > 0) f.string else null;
}

/// Decoded `png_base64`, null when absent; error.Invalid when malformed.
pub fn decodePng(arena: std.mem.Allocator, b64: ?[]const u8) !?[]u8 {
    const text = b64 orelse return null;
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(text) catch return error.Invalid;
    const buf = try arena.alloc(u8, n);
    dec.decode(buf, text) catch return error.Invalid;
    return buf;
}

/// `surface-<id8>-<ms>-<rand8>.png` with only [A-Za-z0-9] kept from the
/// handle. The random part keeps two captures in the same millisecond (or
/// from two CLI processes) from overwriting each other.
pub fn tempName(arena: std.mem.Allocator, surface: ?[]const u8, ms: i64, rand: u32) ![]const u8 {
    var id: [8]u8 = undefined;
    var n: usize = 0;
    for (surface orelse "") |ch| {
        if (n == id.len) break;
        if (std.ascii.isAlphanumeric(ch)) {
            id[n] = std.ascii.toLower(ch);
            n += 1;
        }
    }
    return std.fmt.allocPrint(arena, "surface-{s}-{d}-{x:0>8}.png", .{ if (n == 0) "unknown" else id[0..n], ms, rand });
}

pub fn finish(ctx: *Ctx, c: plan_mod.Call, result_in: std.json.Value, surface: ?[]const u8) !u8 {
    var result = result_in;
    const png = decodePng(ctx.arena, str(result, "png_base64")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.runtimeError("browser screenshot: the app returned invalid PNG data", .{}),
    };
    var shown: ?[]const u8 = null;
    if (c.out_path) |out| {
        const bytes = png orelse blk: {
            const src = str(result, "path") orelse return ctx.runtimeError("browser screenshot: the app returned no image", .{});
            break :blk ctx.platform.readFile(ctx.arena, src, max_png_bytes) orelse
                return ctx.runtimeError("browser screenshot: cannot read {s}", .{src});
        };
        if (!files.writer.write(out, bytes)) return ctx.runtimeError("browser screenshot: cannot write {s}", .{out});
        shown = out;
    } else if (str(result, "url") orelse str(result, "path")) |where| {
        shown = where;
    } else if (png) |bytes| {
        const tmp_root = ctx.env.first(&.{ "TEMP", "TMP", "TMPDIR" }) orelse ctx.platform.cwd(ctx.arena) orelse ".";
        // Wall-clock milliseconds (Platform.nowMs is monotonic per process).
        const name = try tempName(ctx.arena, surface, std.time.milliTimestamp(), std.crypto.random.int(u32));
        const path = try paths.join(ctx.arena, paths.Style.native, &.{ tmp_root, "wmux-browser-screenshots", name });
        if (!files.writer.write(path, bytes)) return ctx.runtimeError("browser screenshot: cannot write {s}", .{path});
        shown = path;
        if (result == .object) try result.object.put("path", .{ .string = path });
    } else return ctx.runtimeError("browser screenshot: the app returned no image", .{});

    if (ctx.json()) {
        if (result == .object) {
            _ = result.object.orderedRemove("png_base64");
            if (c.out_path) |out| try result.object.put("out", .{ .string = out });
        }
        try output.writeResult(ctx.arena, ctx.out, result, ctx.parsed.globals.id_format);
    } else try ctx.out.print("OK {s}\n", .{shown.?});
    return output.exit.ok;
}

test "unit: browser-cli: screenshot helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("\x89PNG", (try decodePng(a, "iVBORw==")).?);
    try std.testing.expectEqual(@as(?[]u8, null), try decodePng(a, null));
    try std.testing.expectError(error.Invalid, decodePng(a, "!!!"));
    try std.testing.expectEqualStrings("surface-0b6e5c1a-42-0000beef.png", try tempName(a, "0B6E5C1A-3F0D-4C4B", 42, 0xbeef));
    try std.testing.expectEqualStrings("surface-surface2-7-ffffffff.png", try tempName(a, "surface:2", 7, 0xffffffff));
    try std.testing.expectEqualStrings("surface-unknown-7-00000000.png", try tempName(a, null, 7, 0));
    try std.testing.expectEqualStrings("surface-unknown-7-00000001.png", try tempName(a, "\u{1F600}:-", 7, 1));
}
