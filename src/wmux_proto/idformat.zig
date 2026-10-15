//! Client-side `--id-format refs|uuids|both` output rewriting (ADR-2.5, ADR-4.7).
//!
//! JSON: the result is walked recursively. `refs` (default) drops `id` when
//! the same object has `ref`, `<p>_id` when it has `<p>_ref`, and `<p>_ids`
//! when it has `<p>_refs`. `uuids` drops the ref side of the same pairs.
//! `both` keeps everything. Text handles render as the ref, the UUID, or
//! `<ref> (<uuid>)`; surface refs print as `tab:N` in tab contexts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");

pub const Mode = enum {
    refs,
    uuids,
    both,

    pub const default: Mode = .refs;

    /// Exact value of `--id-format`; null → print `invalid_message`, exit 2.
    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

/// `--id-format must be one of: refs, uuids, both`
pub const invalid_message = errors.msg.invalid_id_format;

pub const Options = struct {
    /// Pair prefixes whose UUID side survives in `refs` mode (cmux: "some
    /// commands preserve bare ids for specific kinds"). Use `""` for the bare
    /// `id`/`ref` pair, `"surface"` for `surface_id`/`surface_ids`.
    preserve_ids: []const []const u8 = &.{},
};

/// Returns `v` rewritten for `mode`. Objects and arrays are copied into
/// `arena` (`v` is not modified); leaves are shared. `both` returns `v`.
pub fn apply(arena: Allocator, v: std.json.Value, mode: Mode, opts: Options) Allocator.Error!std.json.Value {
    if (mode == .both) return v;
    return walk(arena, v, mode, opts);
}

fn walk(arena: Allocator, v: std.json.Value, mode: Mode, opts: Options) Allocator.Error!std.json.Value {
    switch (v) {
        .object => |obj| {
            var out = std.json.ObjectMap.init(arena);
            try out.ensureTotalCapacity(obj.count());
            var it = obj.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (shouldDrop(&obj, key, mode, opts)) continue;
                out.putAssumeCapacity(key, try walk(arena, e.value_ptr.*, mode, opts));
            }
            return .{ .object = out };
        },
        .array => |arr| {
            var out = try std.json.Array.initCapacity(arena, arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try walk(arena, item, mode, opts));
            return .{ .array = out };
        },
        else => return v,
    }
}

const Side = enum { id, ref };

const Pair = struct {
    prefix: []const u8,
    side: Side,
    plural: bool,
};

/// Classifies `id`, `ref`, `<p>_id`, `<p>_ref`, `<p>_ids`, `<p>_refs`.
fn classify(key: []const u8) ?Pair {
    if (std.mem.eql(u8, key, "id")) return .{ .prefix = "", .side = .id, .plural = false };
    if (std.mem.eql(u8, key, "ref")) return .{ .prefix = "", .side = .ref, .plural = false };
    const suffixes = [_]struct { []const u8, Side, bool }{
        .{ "_ids", .id, true },
        .{ "_refs", .ref, true },
        .{ "_id", .id, false },
        .{ "_ref", .ref, false },
    };
    for (suffixes) |sfx| {
        if (key.len > sfx[0].len and std.mem.endsWith(u8, key, sfx[0]))
            return .{ .prefix = key[0 .. key.len - sfx[0].len], .side = sfx[1], .plural = sfx[2] };
    }
    return null;
}

fn counterpartPresent(obj: *const std.json.ObjectMap, p: Pair) bool {
    const other: Side = if (p.side == .id) .ref else .id;
    var buf: [256]u8 = undefined;
    const name = if (p.prefix.len == 0)
        (if (other == .id) "id" else "ref")
    else
        std.fmt.bufPrint(&buf, "{s}_{s}{s}", .{ p.prefix, @tagName(other), if (p.plural) "s" else "" }) catch return false;
    return obj.contains(name);
}

fn shouldDrop(obj: *const std.json.ObjectMap, key: []const u8, mode: Mode, opts: Options) bool {
    const p = classify(key) orelse return false;
    const drop_side: Side = switch (mode) {
        .refs => .id,
        .uuids => .ref,
        .both => return false,
    };
    if (p.side != drop_side) return false;
    if (mode == .refs) {
        for (opts.preserve_ids) |keep| if (std.mem.eql(u8, keep, p.prefix)) return false;
    }
    return counterpartPresent(obj, p);
}

pub const HandleOptions = struct {
    /// Print surface refs as `tab:N`.
    tab_context: bool = false,
};

/// Writes one text handle: `refs` → ref, `uuids` → UUID, `both` →
/// `<ref> (<uuid>)`. A missing side falls back to the other; both missing
/// writes nothing.
pub fn writeHandle(w: *std.Io.Writer, mode: Mode, ref: ?[]const u8, uuid: ?[]const u8, opts: HandleOptions) std.Io.Writer.Error!void {
    switch (mode) {
        .refs => if (ref) |r| try writeRef(w, r, opts) else if (uuid) |u| try w.writeAll(u),
        .uuids => if (uuid) |u| try w.writeAll(u) else if (ref) |r| try writeRef(w, r, opts),
        .both => {
            if (ref) |r| {
                try writeRef(w, r, opts);
                if (uuid) |u| try w.print(" ({s})", .{u});
            } else if (uuid) |u| try w.writeAll(u);
        },
    }
}

/// Heap text of `writeHandle`.
pub fn handleTextAlloc(gpa: Allocator, mode: Mode, ref: ?[]const u8, uuid: ?[]const u8, opts: HandleOptions) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeHandle(&aw.writer, mode, ref, uuid, opts) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeRef(w: *std.Io.Writer, ref: []const u8, opts: HandleOptions) std.Io.Writer.Error!void {
    const surface = "surface:";
    if (opts.tab_context and std.mem.startsWith(u8, ref, surface)) {
        try w.writeAll("tab:");
        try w.writeAll(ref[surface.len..]);
    } else try w.writeAll(ref);
}

const testing = std.testing;

fn roundTrip(json: []const u8, mode: Mode, opts: Options) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const out = try apply(a, v, mode, opts);
    return std.json.Stringify.valueAlloc(testing.allocator, out, .{});
}

fn expectFormat(json: []const u8, mode: Mode, opts: Options, want: []const u8) !void {
    const got = try roundTrip(json, mode, opts);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const sample =
    \\{"workspaces":[{"id":"U1","ref":"workspace:1","index":0,"title":"api"},
    \\{"workspace_id":"U2","workspace_ref":"workspace:2","surface_ids":["S1"],"surface_refs":["surface:1"],
    \\"stable_surface_id":"S1","pane_id":"P1"}]}
;

test "unit: proto: idformat refs drops paired ids" {
    try expectFormat(sample, .refs, .{},
        \\{"workspaces":[{"ref":"workspace:1","index":0,"title":"api"},{"workspace_ref":"workspace:2","surface_refs":["surface:1"],"stable_surface_id":"S1","pane_id":"P1"}]}
    );
}

test "unit: proto: idformat uuids drops paired refs" {
    try expectFormat(sample, .uuids, .{},
        \\{"workspaces":[{"id":"U1","index":0,"title":"api"},{"workspace_id":"U2","surface_ids":["S1"],"stable_surface_id":"S1","pane_id":"P1"}]}
    );
}

test "unit: proto: idformat both keeps everything" {
    try expectFormat("{\"id\":\"U\",\"ref\":\"pane:1\"}", .both, .{}, "{\"id\":\"U\",\"ref\":\"pane:1\"}");
}

test "unit: proto: idformat preserves configured kinds" {
    try expectFormat("{\"id\":\"U\",\"ref\":\"r\",\"surface_id\":\"S\",\"surface_ref\":\"surface:1\",\"pane_id\":\"P\",\"pane_ref\":\"pane:1\"}", .refs, .{ .preserve_ids = &.{ "", "surface" } },
        \\{"id":"U","ref":"r","surface_id":"S","surface_ref":"surface:1","pane_ref":"pane:1"}
    );
}

test "unit: proto: idformat leaves unpaired and odd keys" {
    try expectFormat("{\"_id\":\"x\",\"_ref\":\"y\",\"ids\":[1],\"refs\":[2],\"id\":\"lone\"}", .refs, .{},
        \\{"_id":"x","_ref":"y","ids":[1],"refs":[2],"id":"lone"}
    );
    try expectFormat("{\"ref\":\"lone\"}", .uuids, .{}, "{\"ref\":\"lone\"}");
}

test "unit: proto: idformat walks nested arrays and scalars" {
    try expectFormat("[[{\"a\":{\"pane_id\":\"P\",\"pane_ref\":\"pane:2\"}}],3,\"s\",null,true]", .refs, .{},
        \\[[{"a":{"pane_ref":"pane:2"}}],3,"s",null,true]
    );
    try expectFormat("{}", .refs, .{}, "{}");
    try expectFormat("42", .uuids, .{}, "42");
}

test "unit: proto: idformat caller object and unicode values" {
    try expectFormat("{\"caller\":{\"surface_id\":\"S\",\"surface_ref\":\"surface:3\",\"title\":\"J\u{f6}rg \u{1F600}\"}}", .refs, .{}, "{\"caller\":{\"surface_ref\":\"surface:3\",\"title\":\"J\u{f6}rg \u{1F600}\"}}");
}

test "unit: proto: idformat mode parsing" {
    try testing.expectEqual(@as(?Mode, .refs), Mode.parse("refs"));
    try testing.expectEqual(@as(?Mode, .uuids), Mode.parse("uuids"));
    try testing.expectEqual(@as(?Mode, .both), Mode.parse("both"));
    try testing.expectEqual(@as(?Mode, null), Mode.parse("REFS"));
    try testing.expectEqual(@as(?Mode, null), Mode.parse(""));
    try testing.expectEqual(@as(?Mode, null), Mode.parse("uuid"));
    try testing.expectEqual(Mode.refs, Mode.default);
    try testing.expectEqualStrings("--id-format must be one of: refs, uuids, both", invalid_message);
}

test "unit: proto: idformat text handles" {
    const gpa = testing.allocator;
    const U = "9B690ABC-DEF0-4123-8456-789ABCDEF012";
    const cases = [_]struct { Mode, ?[]const u8, ?[]const u8, HandleOptions, []const u8 }{
        .{ .refs, "workspace:2", U, .{}, "workspace:2" },
        .{ .uuids, "workspace:2", U, .{}, U },
        .{ .both, "workspace:2", U, .{}, "workspace:2 (" ++ U ++ ")" },
        .{ .refs, "surface:4", U, .{ .tab_context = true }, "tab:4" },
        .{ .both, "surface:4", U, .{ .tab_context = true }, "tab:4 (" ++ U ++ ")" },
        .{ .refs, "pane:4", U, .{ .tab_context = true }, "pane:4" },
        .{ .refs, null, U, .{}, U },
        .{ .uuids, "pane:1", null, .{}, "pane:1" },
        .{ .both, null, U, .{}, U },
        .{ .both, "pane:1", null, .{}, "pane:1" },
        .{ .refs, null, null, .{}, "" },
    };
    for (cases) |c| {
        const s = try handleTextAlloc(gpa, c[0], c[1], c[2], c[3]);
        defer gpa.free(s);
        try testing.expectEqualStrings(c[4], s);
    }
}

test "unit: proto: idformat large list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var arr = std.json.Array.init(a);
    for (0..5000) |i| {
        var o = std.json.ObjectMap.init(a);
        try o.put("surface_id", .{ .string = "S" });
        try o.put("surface_ref", .{ .string = "surface:1" });
        try o.put("index", .{ .integer = @intCast(i) });
        try arr.append(.{ .object = o });
    }
    const out = try apply(a, .{ .array = arr }, .refs, .{});
    try testing.expectEqual(@as(usize, 5000), out.array.items.len);
    try testing.expect(!out.array.items[4999].object.contains("surface_id"));
    // The input is not modified.
    try testing.expect(arr.items[0].object.contains("surface_id"));
}
