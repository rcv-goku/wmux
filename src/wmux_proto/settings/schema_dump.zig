//! JSON Schema (draft 2020-12) export of the settings specs (ADR-5.6).
//! `zig build settings-schema` (src/build/WmuxSteps.zig) calls
//! `writeSchema` and writes docs/wmux/schema/wmux.schema.json. Output is
//! deterministic: root meta keys first, then the spec tree sorted by path
//! segment. Unknown keys are not forbidden (`additionalProperties` is left
//! open) because wmux treats them as warnings and cmux-only keys must keep
//! validating in editors.

const std = @import("std");
const jsonc = @import("../jsonc.zig");
const spec_mod = @import("spec.zig");
const manifest = @import("specs_manifest.zig");

const Spec = spec_mod.Spec;
const Allocator = std.mem.Allocator;

pub const draft_uri = "https://json-schema.org/draft/2020-12/schema";
/// `$id` of the wmux schema (also accepted as a `$schema` value in wmux.json).
pub const schema_id = "https://schema.wmux.example/wmux.schema.json";
/// Matches `spec.isColor`.
pub const color_pattern = "^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$";

pub const Error = std.Io.Writer.Error || Allocator.Error || error{PathConflict};

/// Writes the schema of every registered spec.
pub fn writeSchema(gpa: std.mem.Allocator, writer: *std.Io.Writer) !void {
    return writeSchemaFor(gpa, writer, manifest.all);
}

const Item = struct {
    spec: *const Spec,
    segs: []const []const u8,
};

fn segLess(_: void, a: Item, b: Item) bool {
    const n = @min(a.segs.len, b.segs.len);
    for (a.segs[0..n], b.segs[0..n]) |x, y| {
        switch (std.mem.order(u8, x, y)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return a.segs.len < b.segs.len;
}

/// Writes the schema of `specs` (pretty-printed, two-space indent, trailing
/// newline). `error.PathConflict` when a path is both a setting and a section.
pub fn writeSchemaFor(gpa: Allocator, writer: *std.Io.Writer, specs: []const Spec) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try arena.alloc(Item, specs.len);
    for (specs, items) |*s, *it| {
        var segs: std.ArrayList([]const u8) = .empty;
        var split = std.mem.splitScalar(u8, s.path, '.');
        while (split.next()) |seg| try segs.append(arena, seg);
        it.* = .{ .spec = s, .segs = try segs.toOwnedSlice(arena) };
    }
    std.sort.pdq(Item, items, {}, segLess);

    var jw: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("$schema");
    try jw.write(draft_uri);
    try jw.objectField("$id");
    try jw.write(schema_id);
    try jw.objectField("title");
    try jw.write("wmux settings");
    try jw.objectField("description");
    try jw.write("Settings for wmux.json and the shared cmux.json. Keys use cmux names; wmux-only keys live under \"wmux\".");
    try jw.objectField("type");
    try jw.write("object");
    try jw.objectField("properties");
    try jw.beginObject();
    try writeRootMeta(&jw);
    try writeProperties(arena, &jw, items, 0);
    try jw.endObject();
    try jw.endObject();
    try writer.writeByte('\n');
}

fn writeRootMeta(jw: *std.json.Stringify) Error!void {
    try jw.objectField("$schema");
    try jw.beginObject();
    try jw.objectField("description");
    try jw.write("Schema URL for editor completion (the wmux or the cmux schema).");
    try jw.objectField("type");
    try jw.write("string");
    try jw.endObject();

    try jw.objectField("schemaVersion");
    try jw.beginObject();
    try jw.objectField("description");
    try jw.write("Config format version; newer versions are read best effort.");
    try jw.objectField("type");
    try jw.write("integer");
    try jw.objectField("minimum");
    try jw.write(1);
    try jw.objectField("default");
    try jw.write(1);
    try jw.endObject();

    try jw.objectField("packs");
    try jw.beginObject();
    try jw.objectField("description");
    try jw.write("Pack files or directories applied beneath this file (values set here win). Relative entries start from this file's directory. A directory resolves to wmux.pack.json, then cmux.pack.json.");
    try jw.objectField("type");
    try jw.write("array");
    try jw.objectField("items");
    try jw.beginObject();
    try jw.objectField("oneOf");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("string");
    try jw.objectField("minLength");
    try jw.write(1);
    try jw.endObject();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("object");
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("path");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("string");
    try jw.objectField("minLength");
    try jw.write(1);
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("required");
    try jw.write(&[_][]const u8{"path"});
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.objectField("default");
    try jw.beginArray();
    try jw.endArray();
    try jw.endObject();
}

fn writeProperties(arena: Allocator, jw: *std.json.Stringify, items: []const Item, depth: usize) Error!void {
    var i: usize = 0;
    while (i < items.len) {
        const seg = items[i].segs[depth];
        var j = i + 1;
        while (j < items.len and std.mem.eql(u8, items[j].segs[depth], seg)) j += 1;
        const group = items[i..j];
        try jw.objectField(seg);
        if (group.len == 1 and group[0].segs.len == depth + 1) {
            try writeLeaf(arena, jw, group[0].spec);
        } else {
            for (group) |it| if (it.segs.len == depth + 1) return error.PathConflict;
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("object");
            try jw.objectField("properties");
            try jw.beginObject();
            try writeProperties(arena, jw, group, depth + 1);
            try jw.endObject();
            try jw.endObject();
        }
        i = j;
    }
}

fn writeLeaf(arena: Allocator, jw: *std.json.Stringify, s: *const Spec) Error!void {
    try jw.beginObject();
    try jw.objectField("title");
    try jw.write(s.label);
    if (s.doc.len > 0) {
        try jw.objectField("description");
        try jw.write(s.doc);
    }
    switch (s.ty) {
        .boolean => try typeField(jw, "boolean"),
        .integer => |r| {
            try typeField(jw, "integer");
            if (r.min != std.math.minInt(i64)) {
                try jw.objectField("minimum");
                try jw.write(r.min);
            }
            if (r.max != std.math.maxInt(i64)) {
                try jw.objectField("maximum");
                try jw.write(r.max);
            }
        },
        .number => |r| {
            try typeField(jw, "number");
            if (std.math.isFinite(r.min)) {
                try jw.objectField("minimum");
                try jw.print("{d}", .{r.min});
            }
            if (std.math.isFinite(r.max)) {
                try jw.objectField("maximum");
                try jw.print("{d}", .{r.max});
            }
        },
        .string => |rule| {
            try typeField(jw, "string");
            if (rule.pattern) |p| {
                try jw.objectField("pattern");
                try jw.write(p);
            }
        },
        .enumeration => |values| {
            try typeField(jw, "string");
            try jw.objectField("enum");
            try jw.write(values);
        },
        .color => {
            try typeField(jw, "string");
            try jw.objectField("pattern");
            try jw.write(color_pattern);
        },
        .path => {
            try typeField(jw, "string");
            try jw.objectField("x-wmux-kind");
            try jw.write("path");
        },
        .string_list => {
            try typeField(jw, "array");
            try jw.objectField("items");
            try jw.beginObject();
            try typeField(jw, "string");
            try jw.endObject();
        },
        .object => try typeField(jw, "object"),
        .strokes => {
            try jw.objectField("oneOf");
            try jw.beginArray();
            try jw.beginObject();
            try typeField(jw, "string");
            try jw.endObject();
            try jw.beginObject();
            try typeField(jw, "array");
            try jw.objectField("items");
            try jw.beginObject();
            try typeField(jw, "string");
            try jw.objectField("minLength");
            try jw.write(1);
            try jw.endObject();
            try jw.objectField("minItems");
            try jw.write(1);
            try jw.objectField("maxItems");
            try jw.write(2);
            try jw.endObject();
            try jw.endArray();
            try jw.objectField("x-wmux-kind");
            try jw.write("strokes");
        },
    }
    try jw.objectField("default");
    const default_node = jsonc.parseInto(arena, s.default, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => unreachable, // checked at comptime
    };
    try default_node.write(jw);

    try jw.objectField("x-cmux-scopes");
    try jw.write(switch (s.scope) {
        .global => &[_][]const u8{"global"},
        .project => &[_][]const u8{"project"},
        .both => &[_][]const u8{ "global", "project" },
    });
    try jw.objectField("x-wmux-section");
    try jw.write(s.section);
    if (s.keywords.len > 0) {
        try jw.objectField("x-wmux-keywords");
        try jw.write(s.keywords);
    }
    if (s.apply == .restart) {
        try jw.objectField("x-wmux-apply");
        try jw.write("restart");
    }
    if (s.ghostty_override) |g| {
        try jw.objectField("x-wmux-ghostty-override");
        try jw.write(g);
    }
    if (!s.policy_lockable) {
        try jw.objectField("x-wmux-policy-lockable");
        try jw.write(false);
    }
    if (s.palette_toggle) {
        try jw.objectField("x-wmux-palette-toggle");
        try jw.write(true);
    }
    try jw.endObject();
}

fn typeField(jw: *std.json.Stringify, t: []const u8) Error!void {
    try jw.objectField("type");
    try jw.write(t);
}

const testing = std.testing;
const fixtures = @import("validate.zig").test_fixture_specs;

fn dumpAlloc(specs: []const Spec) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try writeSchemaFor(testing.allocator, &aw.writer, specs);
    return aw.toOwnedSlice();
}

test "unit: settings: schema generation golden" {
    const specs = [_]Spec{
        fixtures[11], // automation.autoNamingAgent (pattern)
        fixtures[0], // app.appearance (enum)
        fixtures[3], // terminal.scrollSpeed (number, ghostty-free)
        fixtures[4], // terminal.copyOnSelect (ghostty override)
        fixtures[9], // notifications.hooks (object, both scopes)
        fixtures[14], // wmux.sidebar.width (integer)
        fixtures[15], // wmux.quickTerminal.hotkey (strokes)
        fixtures[7], // activePaneBorderColor (color)
        fixtures[12], // automation.claudeBinaryPath (path, not lockable)
        fixtures[6], // sidebar.showPorts (keywords)
        fixtures[10], // automation.socketControlMode (restart)
        fixtures[8], // browser.urlAllowlist (string list)
        fixtures[5], // fileEditor.wordWrap (palette toggle)
    };
    const out = try dumpAlloc(&specs);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(@embedFile("testdata/schema_golden.json"), out);
}

test "unit: settings: schema of all fixtures parses and lists every path" {
    const out = try dumpAlloc(&fixtures);
    defer testing.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;
    try testing.expect(props.get("$schema") != null);
    try testing.expect(props.get("schemaVersion") != null);
    try testing.expect(props.get("packs") != null);
    for (fixtures) |s| {
        var cur = props;
        var it = std.mem.splitScalar(u8, s.path, '.');
        var leaf: ?std.json.Value = null;
        while (it.next()) |seg| {
            const v = cur.get(seg) orelse return error.TestMissingPath;
            if (it.peek() == null) {
                leaf = v;
            } else cur = v.object.get("properties").?.object;
        }
        try testing.expectEqualStrings(s.label, leaf.?.object.get("title").?.string);
        try testing.expect(leaf.?.object.get("default") != null);
    }
}

test "unit: settings: schema of the real registry" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSchema(testing.allocator, &aw.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(draft_uri, parsed.value.object.get("$schema").?.string);
    try testing.expectEqualStrings(schema_id, parsed.value.object.get("$id").?.string);
}

test "unit: settings: schema rejects a path that is also a section" {
    const specs = [_]Spec{
        .{ .path = "a", .ty = .boolean, .default = "true", .section = "app", .label = "A", .doc = "" },
        .{ .path = "a.b", .ty = .boolean, .default = "true", .section = "app", .label = "B", .doc = "" },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(error.PathConflict, writeSchemaFor(testing.allocator, &aw.writer, &specs));
}

test "unit: settings: schema of no specs and unicode text" {
    const specs = [_]Spec{
        .{ .path = "wmux.i18n.locale", .ty = .{ .string = .{} }, .default = "\"日本語\"", .section = "windows", .label = "Langue \"préférée\"", .doc = "Ünïcödé\n", .cmux_compat = false },
    };
    const out = try dumpAlloc(&specs);
    defer testing.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const leaf = parsed.value.object.get("properties").?.object.get("wmux").?.object.get("properties").?.object
        .get("i18n").?.object.get("properties").?.object.get("locale").?.object;
    try testing.expectEqualStrings("日本語", leaf.get("default").?.string);
    try testing.expectEqualStrings("Langue \"préférée\"", leaf.get("title").?.string);

    const empty = try dumpAlloc(&.{});
    defer testing.allocator.free(empty);
    var p2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, empty, .{});
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 3), p2.value.object.get("properties").?.object.count());
}

test "unit: settings: schema color pattern agrees with the validator" {
    const validate = @import("validate.zig");
    for ([_][]const u8{ "#3B82F6", "#3b82f6cc", "#3B82F", "3B82F6", "#GGGGGG", "#3B82F6C", "", "#" }) |c| {
        try testing.expectEqual(spec_mod.isColor(c), try validate.patternMatches(testing.allocator, color_pattern, c));
    }
}
