//! Saved layouts store model (core-saved-layouts): the layouts.json document
//! {layouts: [{name, description?, workspace}]}, case-insensitive name
//! lookup, save with replace confirmation, delete, and the `layout` CLI
//! output text ('OK layout=<name> unsupported=<n>', 'OK deleted=true', the
//! NAME/PANES/SURFACES/DESCRIPTION table, 'No saved layouts').
//!
//! Pure: file I/O, locking and atomic replace stay on the app side.

const std = @import("std");
const proto = @import("wmux_proto");
const layout_json = @import("layout_json.zig");

const jsonc = proto.jsonc;
const Allocator = std.mem.Allocator;
const Workspace = layout_json.Workspace;

/// Error codes of the `layout.*` methods and CLI (cmux names).
pub const code = struct {
    pub const duplicate_name = "duplicateName";
    pub const not_found = "notFound";
    pub const corrupt_file = "corruptFile";
};

/// Shown when the save prompt's name is blank.
pub const blank_name_message = "Enter a name before saving the layout.";
/// Title of the replace confirmation on a case-insensitive name collision.
pub const replace_title = "Replace Saved Layout?";
/// Palette row title prefix and subtitle.
pub const palette_title_prefix = "New Workspace from Layout: ";
pub const palette_subtitle = "Saved Layouts";
pub const no_layouts_text = "No saved layouts";
pub const table_header = "NAME\tPANES\tSURFACES\tDESCRIPTION";
pub const ok_deleted_text = "OK deleted=true";

/// Byte cap for layout names and descriptions (G6).
pub const max_name_bytes: usize = 256;
pub const max_description_bytes: usize = 4096;

pub const Error = error{ OutOfMemory, BlankName, DuplicateName, NotFound, CorruptFile };

/// Why a file is corrupt. Messages live in the caller's `arena`.
pub const Problems = struct {
    arena: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    pub fn init(arena: Allocator) Problems {
        return .{ .arena = arena };
    }

    fn add(self: ?*Problems, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const p = self orelse return;
        try p.items.append(p.arena, try std.fmt.allocPrint(p.arena, fmt, args));
    }
};

pub const SavedLayout = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    workspace: Workspace,
};

/// ASCII case-insensitive comparison (non-ASCII bytes compare exactly).
pub fn namesEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Trims and caps a user-entered name; error.BlankName when nothing is left.
pub fn normalizeName(name: []const u8) error{BlankName}![]const u8 {
    const t = std.mem.trim(u8, name, " \t\r\n");
    if (t.len == 0) return error.BlankName;
    return proto.utf8.truncateUtf8(t, max_name_bytes);
}

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    layouts: std.ArrayList(SavedLayout) = .empty,

    pub fn init(gpa: Allocator) Store {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Loads layouts.json text. Empty or whitespace-only text is an empty
    /// store. A syntax or schema error gives error.CorruptFile; `problems`
    /// explains why.
    pub fn parse(gpa: Allocator, src: []const u8, problems: ?*Problems) Error!Store {
        var store: Store = .init(gpa);
        errdefer store.deinit();
        const a = store.arena.allocator();
        if (std.mem.trim(u8, src, " \t\r\n").len == 0) return store;
        var jd: jsonc.Diagnostic = .{};
        const root = jsonc.parseInto(a, src, .{}, &jd) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => {
                try Problems.add(problems, "{d}:{d}: {s}", .{ jd.pos.line, jd.pos.col, jd.message });
                return error.CorruptFile;
            },
        };
        const list = root.get("layouts") orelse {
            try Problems.add(problems, "missing 'layouts' array", .{});
            return error.CorruptFile;
        };
        const items = switch (list.data) {
            .array => |arr| arr,
            else => {
                try Problems.add(problems, "'layouts' must be an array", .{});
                return error.CorruptFile;
            },
        };
        for (items, 0..) |*item, i| {
            const entry = parseEntry(a, item, i, problems) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptFile => return error.CorruptFile,
            };
            if (store.indexOf(entry.name) != null) {
                try Problems.add(problems, "layouts[{d}]: duplicate name '{s}'", .{ i, entry.name });
                return error.CorruptFile;
            }
            try store.layouts.append(a, entry);
        }
        return store;
    }

    fn parseEntry(a: Allocator, item: *const jsonc.Node, i: usize, problems: ?*Problems) error{ OutOfMemory, CorruptFile }!SavedLayout {
        const name_raw = if (item.get("name")) |n| n.asString() else null;
        const name = normalizeName(name_raw orelse "") catch {
            try Problems.add(problems, "layouts[{d}]: missing or blank 'name'", .{i});
            return error.CorruptFile;
        };
        var description: ?[]const u8 = null;
        if (item.get("description")) |dv| switch (dv.data) {
            .null => {},
            .string => |s| description = s,
            else => {
                try Problems.add(problems, "layouts[{d}]: 'description' must be a string", .{i});
                return error.CorruptFile;
            },
        };
        const wsn = item.get("workspace") orelse {
            try Problems.add(problems, "layouts[{d}]: missing 'workspace'", .{i});
            return error.CorruptFile;
        };
        var ld: layout_json.Diagnostics = .init(a);
        const base = try std.fmt.allocPrint(a, "layouts[{d}].workspace", .{i});
        const ws = layout_json.parseWorkspace(a, wsn, base, &ld) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLayout => {
                for (ld.items.items) |it| {
                    if (it.severity == .err) try Problems.add(problems, "{s}: {s}", .{ it.path, it.message });
                }
                return error.CorruptFile;
            },
        };
        return .{ .name = name, .description = description, .workspace = ws };
    }

    pub fn indexOf(self: *const Store, name: []const u8) ?usize {
        const n = std.mem.trim(u8, name, " \t\r\n");
        for (self.layouts.items, 0..) |l, i| {
            if (namesEqual(l.name, n)) return i;
        }
        return null;
    }

    pub fn get(self: *const Store, name: []const u8) ?*const SavedLayout {
        const i = self.indexOf(name) orelse return null;
        return &self.layouts.items[i];
    }

    /// True when saving `name` needs the replace confirmation.
    pub fn needsReplaceConfirm(self: *const Store, name: []const u8) bool {
        return self.indexOf(name) != null;
    }

    /// Saves a deep copy of `ws`. A case-insensitive collision fails with
    /// error.DuplicateName unless `overwrite`, in which case the entry is
    /// replaced in place (keeping its position) under the new spelling.
    pub fn save(self: *Store, name: []const u8, description: ?[]const u8, ws: Workspace, overwrite: bool) Error!*const SavedLayout {
        const n = try normalizeName(name);
        const a = self.arena.allocator();
        const entry: SavedLayout = .{
            .name = try a.dupe(u8, n),
            .description = if (description) |d| try a.dupe(u8, proto.utf8.truncateUtf8(d, max_description_bytes)) else null,
            .workspace = try layout_json.cloneWorkspace(a, ws),
        };
        if (self.indexOf(n)) |i| {
            if (!overwrite) return error.DuplicateName;
            self.layouts.items[i] = entry;
            return &self.layouts.items[i];
        }
        try self.layouts.append(a, entry);
        return &self.layouts.items[self.layouts.items.len - 1];
    }

    pub fn delete(self: *Store, name: []const u8) error{NotFound}!void {
        const i = self.indexOf(name) orelse return error.NotFound;
        _ = self.layouts.orderedRemove(i);
    }

    /// layouts.json text (2-space indent, trailing newline).
    pub fn serializeAlloc(self: *const Store, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        self.writeJson(&jw) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn writeJson(self: *const Store, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        try jw.beginObject();
        try jw.objectField("layouts");
        try jw.beginArray();
        for (self.layouts.items) |l| try writeEntry(jw, l);
        try jw.endArray();
        try jw.endObject();
    }
};

/// One saved layout as JSON (`layout get` output and the file entry).
pub fn writeEntry(jw: *std.json.Stringify, l: SavedLayout) std.Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(l.name);
    if (l.description) |d| {
        try jw.objectField("description");
        try jw.write(d);
    }
    try jw.objectField("workspace");
    try layout_json.writeWorkspace(jw, l.workspace);
    try jw.endObject();
}

pub fn entryToJsonAlloc(gpa: Allocator, l: SavedLayout) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    writeEntry(&jw, l) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// 'OK layout=<name> unsupported=<count>'.
pub fn savedLineAlloc(gpa: Allocator, name: []const u8, unsupported: usize) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "OK layout={s} unsupported={d}", .{ name, unsupported });
}

/// Palette row title for a saved layout.
pub fn paletteTitleAlloc(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, palette_title_prefix ++ "{s}", .{name});
}

fn writeCell(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    // Tabs and line breaks would break the table's columns and rows.
    for (s) |c| try w.writeByte(switch (c) {
        '\t', '\r', '\n' => ' ',
        else => c,
    });
}

/// `layout list` text: the header plus one row per layout, or
/// 'No saved layouts'. Ends with a newline.
pub fn listTextAlloc(gpa: Allocator, store: *const Store) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeList(&aw.writer, store) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeList(w: *std.Io.Writer, store: *const Store) std.Io.Writer.Error!void {
    if (store.layouts.items.len == 0) {
        try w.writeAll(no_layouts_text ++ "\n");
        return;
    }
    try w.writeAll(table_header ++ "\n");
    for (store.layouts.items) |l| {
        try writeCell(w, l.name);
        try w.print("\t{d}\t{d}\t", .{ layout_json.countPanes(l.workspace.layout), layout_json.countSurfaces(l.workspace.layout) });
        try writeCell(w, l.description orelse "");
        try w.writeByte('\n');
    }
}

/// `layout list --json`: {"layouts":[{name, description, panes, surfaces}]}.
pub fn listJsonAlloc(gpa: Allocator, store: *const Store) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeListJson(&jw, store) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeListJson(jw: *std.json.Stringify, store: *const Store) std.Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("layouts");
    try jw.beginArray();
    for (store.layouts.items) |l| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(l.name);
        try jw.objectField("description");
        try jw.write(l.description);
        try jw.objectField("panes");
        try jw.write(layout_json.countPanes(l.workspace.layout));
        try jw.objectField("surfaces");
        try jw.write(layout_json.countSurfaces(l.workspace.layout));
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn sampleWorkspace(arena: Allocator) !Workspace {
    var d: layout_json.Diagnostics = .init(arena);
    return layout_json.parseWorkspaceText(arena,
        \\{"cwd":"/w","layout":{"direction":"horizontal","children":[
        \\  {"surfaces":[{"command":"vim"},{"type":"browser","url":"http://x"}]},
        \\  {"surfaces":[{}]}]}}
    , &d);
}

test "unit: layouts: store saves, finds case-insensitively, rejects duplicates and replaces" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const ws = try sampleWorkspace(ar.allocator());
    var st: Store = .init(testing.allocator);
    defer st.deinit();
    _ = try st.save("  Dev ", "main layout", ws, false);
    try testing.expectEqualStrings("Dev", st.get("dev").?.name);
    try testing.expect(st.needsReplaceConfirm("DEV"));
    try testing.expectError(error.DuplicateName, st.save("dEv", null, ws, false));
    _ = try st.save("other", null, .{}, false);
    _ = try st.save("dEv", null, .{}, true);
    try testing.expectEqual(@as(usize, 2), st.layouts.items.len);
    try testing.expectEqualStrings("dEv", st.layouts.items[0].name);
    try testing.expect(st.layouts.items[0].description == null);
    try testing.expectError(error.BlankName, st.save(" \t", null, ws, false));
}

test "unit: layouts: store deletes and reports notFound" {
    var st: Store = .init(testing.allocator);
    defer st.deinit();
    _ = try st.save("a", null, .{}, false);
    try st.delete("A");
    try testing.expectError(error.NotFound, st.delete("a"));
    try testing.expectEqual(@as(usize, 0), st.layouts.items.len);
}

test "unit: layouts: store round-trips layouts.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const ws = try sampleWorkspace(ar.allocator());
    var st: Store = .init(testing.allocator);
    defer st.deinit();
    _ = try st.save("dev", "Ünïcode ✓", ws, false);
    _ = try st.save("blank", null, .{}, false);
    const text = try st.serializeAlloc(testing.allocator);
    defer testing.allocator.free(text);
    var st2 = try Store.parse(testing.allocator, text, null);
    defer st2.deinit();
    const text2 = try st2.serializeAlloc(testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
    try testing.expectEqualStrings("Ünïcode ✓", st2.get("DEV").?.description.?);
}

test "unit: layouts: empty file is an empty store and garbage is corruptFile" {
    var st = try Store.parse(testing.allocator, " \n", null);
    defer st.deinit();
    try testing.expectEqual(@as(usize, 0), st.layouts.items.len);

    const bad = [_][]const u8{
        "{",
        "[]",
        "{\"layouts\":{}}",
        "{\"layouts\":[{\"workspace\":{}}]}",
        "{\"layouts\":[{\"name\":\"  \",\"workspace\":{}}]}",
        "{\"layouts\":[{\"name\":\"a\"}]}",
        "{\"layouts\":[{\"name\":\"a\",\"description\":3,\"workspace\":{}}]}",
        "{\"layouts\":[{\"name\":\"a\",\"workspace\":{\"layout\":{\"surfaces\":[]}}}]}",
        "{\"layouts\":[{\"name\":\"a\",\"workspace\":{}},{\"name\":\"A\",\"workspace\":{}}]}",
    };
    for (bad) |src| {
        var ar: std.heap.ArenaAllocator = .init(testing.allocator);
        defer ar.deinit();
        var problems: Problems = .init(ar.allocator());
        try testing.expectError(error.CorruptFile, Store.parse(testing.allocator, src, &problems));
        try testing.expect(problems.items.items.len >= 1);
    }
}

test "unit: layouts: corrupt-file diagnostics explain the problem" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    var problems: Problems = .init(ar.allocator());
    try testing.expectError(error.CorruptFile, Store.parse(testing.allocator, "{\"layouts\":[{\"name\":\"a\",\"workspace\":{\"layout\":{\"surfaces\":[]}}}]}", &problems));
    try testing.expectEqual(@as(usize, 1), problems.items.items.len);
    try testing.expect(std.mem.indexOf(u8, problems.items.items[0], "layouts[0].workspace.layout.surfaces") != null);
}

test "unit: layouts: list text, list json and CLI lines" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var st: Store = .init(testing.allocator);
    defer st.deinit();
    try testing.expectEqualStrings("No saved layouts\n", try listTextAlloc(a, &st));
    _ = try st.save("dev", "two\tpanes\nhere", try sampleWorkspace(a), false);
    _ = try st.save("solo", null, .{}, false);
    try testing.expectEqualStrings(
        "NAME\tPANES\tSURFACES\tDESCRIPTION\ndev\t2\t3\ttwo panes here\nsolo\t1\t1\t\n",
        try listTextAlloc(a, &st),
    );
    try testing.expectEqualStrings(
        \\{"layouts":[{"name":"dev","description":"two\tpanes\nhere","panes":2,"surfaces":3},{"name":"solo","description":null,"panes":1,"surfaces":1}]}
    , try listJsonAlloc(a, &st));
    try testing.expectEqualStrings("OK layout=dev unsupported=2", try savedLineAlloc(a, "dev", 2));
    try testing.expectEqualStrings("New Workspace from Layout: dev", try paletteTitleAlloc(a, "dev"));
    const got = try entryToJsonAlloc(a, st.get("solo").?.*);
    try testing.expect(std.mem.indexOf(u8, got, "\"name\": \"solo\"") != null);
}

test "unit: layouts: names are trimmed and capped on a code point boundary" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var long: std.ArrayList(u8) = .empty;
    for (0..200) |_| try long.appendSlice(a, "é");
    const n = try normalizeName(long.items);
    try testing.expect(n.len <= max_name_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(n));
    try testing.expectError(error.BlankName, normalizeName(""));
}
