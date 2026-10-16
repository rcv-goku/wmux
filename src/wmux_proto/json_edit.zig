//! Lossless JSON/JSONC span editor for `config set` and hook installers
//! (ADR-5.6, ADR-10.5). Edits splice the original text: only the replaced
//! value, the inserted member or the removed member changes; comments, key
//! order, blank lines, line endings and unrelated formatting survive.
//! Inserted members copy the indentation and `key: value` spacing of their
//! siblings. Paths are dotted (`sidebar.showPorts`) and split on every `.`,
//! so keys that contain a dot cannot be addressed (use `setPath` segments).

const std = @import("std");
const jsonc = @import("jsonc.zig");

const Node = jsonc.Node;
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    /// The source does not parse as JSONC (see the diagnostic).
    SyntaxError,
    /// Empty path, empty path segment, or a segment that is not UTF-8
    /// (segments become JSON keys).
    InvalidPath,
    /// The document root is not an object.
    RootNotObject,
    /// A path segment names an existing value that is neither an object nor null.
    PathConflict,
    /// The new value is not a single JSON value.
    InvalidValue,
};

/// Edited text (owned by the caller) and whether it differs from the input.
pub const Result = struct {
    text: []u8,
    changed: bool,
};

/// Splits a dotted path. The returned slice is owned by the caller; the
/// segments alias `path`.
pub fn splitPath(gpa: Allocator, path: []const u8) Error![]const []const u8 {
    if (path.len == 0) return error.InvalidPath;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (!validSegment(seg)) return error.InvalidPath;
        try list.append(gpa, seg);
    }
    return list.toOwnedSlice(gpa);
}

/// A segment is written as a JSON key, so it must be non-empty UTF-8. A
/// lone surrogate (WTF-8 from a Windows command line) is not UTF-8.
fn validSegment(seg: []const u8) bool {
    return seg.len > 0 and std.unicode.utf8ValidateSlice(seg);
}

/// Sets the value at dotted `path` to the JSON text `value_json`, creating
/// missing parent objects (and replacing a `null` parent).
pub fn set(gpa: Allocator, src: []const u8, path: []const u8, value_json: []const u8, diag: ?*jsonc.Diagnostic) Error!Result {
    const segs = try splitPath(gpa, path);
    defer gpa.free(segs);
    return setPath(gpa, src, segs, value_json, diag);
}

/// Removes the member at dotted `path` (every occurrence when the key
/// repeats). A missing path is not an error: `changed` is false.
pub fn remove(gpa: Allocator, src: []const u8, path: []const u8, diag: ?*jsonc.Diagnostic) Error!Result {
    const segs = try splitPath(gpa, path);
    defer gpa.free(segs);
    return removePath(gpa, src, segs, diag);
}

const Style = struct {
    nl: []const u8,
    unit: []const u8,
};

fn inferStyle(src: []const u8, root: ?*const Node) Style {
    const nl: []const u8 = if (std.mem.indexOf(u8, src, "\r\n") != null) "\r\n" else "\n";
    if (root) |r| switch (r.data) {
        .object => |members| if (members.len > 0 and jsonc.isFirstOnLine(src, members[0].key_start)) {
            const ind = jsonc.lineIndent(src, members[0].key_start);
            if (ind.len > 0) return .{ .nl = nl, .unit = ind };
        },
        else => {},
    };
    // First indented line with content.
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        var n: usize = 0;
        while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
        if (n > 0 and n < line.len and line[n] != '\r') return .{ .nl = nl, .unit = line[0..n] };
    }
    return .{ .nl = nl, .unit = "  " };
}

const Splice = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// Applies non-overlapping splices sorted by `start`.
fn applySplices(gpa: Allocator, src: []const u8, splices: []const Splice) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    for (splices) |s| {
        std.debug.assert(s.start >= at and s.end >= s.start);
        try out.appendSlice(gpa, src[at..s.start]);
        try out.appendSlice(gpa, s.text);
        at = s.end;
    }
    try out.appendSlice(gpa, src[at..]);
    return out.toOwnedSlice(gpa);
}

fn isScalar(n: *const Node) bool {
    return switch (n.data) {
        .array, .object => false,
        else => true,
    };
}

fn writeQuoted(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Error!void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, out);
    defer out.* = aw.toArrayList();
    std.json.Stringify.encodeJsonString(s, .{}, &aw.writer) catch return error.OutOfMemory;
}

/// Formats `n` for insertion at indentation `base`. Objects (and arrays
/// holding containers) go multi-line when `multiline`; everything else is
/// written inline with `, ` and `: ` separators.
fn formatValue(out: *std.ArrayList(u8), gpa: Allocator, n: *const Node, base: []const u8, style: Style, multiline: bool) Error!void {
    switch (n.data) {
        .null => try out.appendSlice(gpa, "null"),
        .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .number => |raw| try out.appendSlice(gpa, raw),
        .string => |s| try writeQuoted(out, gpa, s),
        .array => |items| {
            if (items.len == 0) return out.appendSlice(gpa, "[]");
            var all_scalar = true;
            for (items) |*it| all_scalar = all_scalar and isScalar(it);
            if (!multiline or all_scalar) {
                try out.append(gpa, '[');
                for (items, 0..) |*it, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    try formatValue(out, gpa, it, base, style, false);
                }
                return out.append(gpa, ']');
            }
            const inner = try std.mem.concat(gpa, u8, &.{ base, style.unit });
            defer gpa.free(inner);
            try out.append(gpa, '[');
            for (items, 0..) |*it, i| {
                if (i > 0) try out.append(gpa, ',');
                try out.appendSlice(gpa, style.nl);
                try out.appendSlice(gpa, inner);
                try formatValue(out, gpa, it, inner, style, true);
            }
            try out.appendSlice(gpa, style.nl);
            try out.appendSlice(gpa, base);
            try out.append(gpa, ']');
        },
        .object => |members| {
            if (members.len == 0) return out.appendSlice(gpa, "{}");
            if (!multiline) {
                try out.append(gpa, '{');
                for (members, 0..) |*m, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    try writeQuoted(out, gpa, m.key);
                    try out.appendSlice(gpa, ": ");
                    try formatValue(out, gpa, &m.value, base, style, false);
                }
                return out.append(gpa, '}');
            }
            const inner = try std.mem.concat(gpa, u8, &.{ base, style.unit });
            defer gpa.free(inner);
            try out.append(gpa, '{');
            for (members, 0..) |*m, i| {
                if (i > 0) try out.append(gpa, ',');
                try out.appendSlice(gpa, style.nl);
                try out.appendSlice(gpa, inner);
                try writeQuoted(out, gpa, m.key);
                try out.appendSlice(gpa, ": ");
                try formatValue(out, gpa, &m.value, inner, style, true);
            }
            try out.appendSlice(gpa, style.nl);
            try out.appendSlice(gpa, base);
            try out.append(gpa, '}');
        },
    }
}

/// Wraps `value` in one single-member object per segment of `rest`.
fn wrap(arena: Allocator, value: Node, rest: []const []const u8) Error!Node {
    var cur = value;
    var i = rest.len;
    while (i > 0) {
        i -= 1;
        const members = try arena.alloc(jsonc.Member, 1);
        members[0] = .{ .key = rest[i], .key_start = 0, .key_end = 0, .value = cur };
        cur = .{ .start = 0, .end = 0, .data = .{ .object = members } };
    }
    return cur;
}

fn isBlank(s: []const u8) bool {
    for (s) |c| if (!(c == ' ' or c == '\t' or c == '\r' or c == '\n')) return false;
    return true;
}

/// Sets the value at `segments` (see `set`).
pub fn setPath(gpa: Allocator, src: []const u8, segments: []const []const u8, value_json: []const u8, diag: ?*jsonc.Diagnostic) Error!Result {
    if (segments.len == 0) return error.InvalidPath;
    for (segments) |s| if (!validSegment(s)) return error.InvalidPath;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = jsonc.parseInto(arena, value_json, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.InvalidValue,
    };

    // A file with nothing but whitespace and comments gets a fresh root object.
    var probe = jsonc.Tokenizer.init(src, true);
    if (probe.next()) |first| if (first.tag == .eof) {
        const style = inferStyle(src, null);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const bom_len: usize = if (std.mem.startsWith(u8, src, jsonc.utf8_bom)) jsonc.utf8_bom.len else 0;
        if (isBlank(src[bom_len..])) {
            // Keep a byte order mark, directly followed by the new root.
            try out.appendSlice(gpa, src[0..bom_len]);
        } else {
            try out.appendSlice(gpa, src);
            if (!std.mem.endsWith(u8, src, "\n")) try out.appendSlice(gpa, style.nl);
        }
        const root = try wrap(arena, value, segments);
        try formatValue(&out, gpa, &root, "", style, true);
        try out.appendSlice(gpa, style.nl);
        return .{ .text = try out.toOwnedSlice(gpa), .changed = true };
    };

    const root = jsonc.parseInto(arena, src, .{}, diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.SyntaxError,
    };
    if (root.data != .object) return error.RootNotObject;
    const style = inferStyle(src, &root);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var splices: [2]Splice = undefined;
    var n_splices: usize = 0;

    var cur: *const Node = &root;
    for (segments, 0..) |seg, i| {
        const last = i == segments.len - 1;
        const m = cur.getMember(seg) orelse {
            const nested = try wrap(arena, value, segments[i + 1 ..]);
            n_splices = try insertMember(gpa, &buf, src, style, cur, cur == &root, seg, &nested, &splices);
            break;
        };
        if (last or m.value.data == .null) {
            const nested = try wrap(arena, value, segments[i + 1 ..]);
            if (m.value.eql(&nested)) return .{ .text = try gpa.dupe(u8, src), .changed = false };
            const multiline = jsonc.isFirstOnLine(src, m.key_start);
            try formatValue(&buf, gpa, &nested, jsonc.lineIndent(src, m.key_start), style, multiline);
            splices[0] = .{ .start = m.value.start, .end = m.value.end, .text = buf.items };
            n_splices = 1;
            break;
        }
        if (m.value.data != .object) return error.PathConflict;
        cur = &m.value;
    }
    return .{ .text = try applySplices(gpa, src, splices[0..n_splices]), .changed = true };
}

/// Computes the splices that add member `key: value` at the end of object
/// `obj`. Splice texts point into `buf`, which must not be reallocated
/// afterwards (all text is appended before slices are taken).
fn insertMember(
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    src: []const u8,
    style: Style,
    obj: *const Node,
    is_root: bool,
    key: []const u8,
    value: *const Node,
    splices: *[2]Splice,
) Error!usize {
    const members = obj.data.object;
    if (members.len == 0) {
        const base = jsonc.lineIndent(src, obj.start);
        const inner_src = src[obj.start + 1 .. obj.end - 1];
        const multiline = is_root or std.mem.indexOfScalar(u8, std.mem.trimRight(u8, src, " \t\r\n"), '\n') != null;
        if (!multiline) {
            try buf.append(gpa, '{');
            try writeQuoted(buf, gpa, key);
            try buf.appendSlice(gpa, ": ");
            try formatValue(buf, gpa, value, base, style, false);
            try buf.append(gpa, '}');
            splices[0] = .{ .start = obj.start, .end = obj.end, .text = buf.items };
            return 1;
        }
        const inner = try std.mem.concat(gpa, u8, &.{ base, style.unit });
        defer gpa.free(inner);
        const close = obj.end - 1;
        if (std.mem.indexOfScalar(u8, inner_src, '\n') == null) {
            // `{}` or `{ /* c */ }` on one line: rewrite the braces around the content.
            try buf.append(gpa, '{');
            try buf.appendSlice(gpa, std.mem.trimRight(u8, inner_src, " \t"));
            try buf.appendSlice(gpa, style.nl);
            try buf.appendSlice(gpa, inner);
            try writeQuoted(buf, gpa, key);
            try buf.appendSlice(gpa, ": ");
            try formatValue(buf, gpa, value, inner, style, true);
            try buf.appendSlice(gpa, style.nl);
            try buf.appendSlice(gpa, base);
            try buf.append(gpa, '}');
            splices[0] = .{ .start = obj.start, .end = obj.end, .text = buf.items };
            return 1;
        }
        // The object spans lines (it holds comments): add a line before `}`.
        const at_line_start = jsonc.isFirstOnLine(src, close);
        if (!at_line_start) try buf.appendSlice(gpa, style.nl);
        try buf.appendSlice(gpa, inner);
        try writeQuoted(buf, gpa, key);
        try buf.appendSlice(gpa, ": ");
        try formatValue(buf, gpa, value, inner, style, true);
        try buf.appendSlice(gpa, style.nl);
        if (!at_line_start) try buf.appendSlice(gpa, base);
        const pos = if (at_line_start) jsonc.lineStart(src, close) else close;
        splices[0] = .{ .start = pos, .end = pos, .text = buf.items };
        return 1;
    }

    const last = &members[members.len - 1];
    const between = src[last.key_end..last.value.start];
    const sep: []const u8 = if (std.mem.indexOfAny(u8, between, "\n/") == null) between else ": ";
    const after = jsonc.skipTrivia(src, last.value.end).end;
    const has_comma = after < src.len and src[after] == ',';
    const multiline = jsonc.isFirstOnLine(src, last.key_start);

    if (!multiline) {
        try buf.appendSlice(gpa, if (has_comma) " " else ", ");
        try writeQuoted(buf, gpa, key);
        try buf.appendSlice(gpa, sep);
        try formatValue(buf, gpa, value, jsonc.lineIndent(src, last.key_start), style, false);
        if (has_comma) try buf.append(gpa, ',');
        const pos = if (has_comma) after + 1 else last.value.end;
        splices[0] = .{ .start = pos, .end = pos, .text = buf.items };
        return 1;
    }

    const indent = jsonc.lineIndent(src, last.key_start);
    const p = if (has_comma) after + 1 else last.value.end;
    const q = jsonc.skipTriviaSameLine(src, p);
    // `buf` = "," (when needed) followed by the new line; both splices slice it.
    const comma_len: usize = if (has_comma) 0 else 1;
    if (!has_comma) try buf.append(gpa, ',');
    try buf.appendSlice(gpa, style.nl);
    try buf.appendSlice(gpa, indent);
    try writeQuoted(buf, gpa, key);
    try buf.appendSlice(gpa, sep);
    try formatValue(buf, gpa, value, indent, style, true);
    if (has_comma) try buf.append(gpa, ',');
    if (q < src.len and !jsonc.isLineBreakAt(src, q)) {
        // Something (usually the closing brace) follows on the same line.
        try buf.appendSlice(gpa, style.nl);
        try buf.appendSlice(gpa, jsonc.lineIndent(src, obj.start));
    }
    var n: usize = 0;
    if (!has_comma) {
        splices[n] = .{ .start = last.value.end, .end = last.value.end, .text = buf.items[0..comma_len] };
        n += 1;
    }
    splices[n] = .{ .start = q, .end = q, .text = buf.items[comma_len..] };
    return n + 1;
}

/// Removes the member at `segments` (see `remove`).
pub fn removePath(gpa: Allocator, src: []const u8, segments: []const []const u8, diag: ?*jsonc.Diagnostic) Error!Result {
    if (segments.len == 0) return error.InvalidPath;
    for (segments) |s| if (!validSegment(s)) return error.InvalidPath;

    var text = try gpa.dupe(u8, src);
    errdefer gpa.free(text);
    var changed = false;
    while (true) {
        var probe = jsonc.Tokenizer.init(text, true);
        if (probe.next()) |first| if (first.tag == .eof) break;

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const root = jsonc.parseInto(arena_state.allocator(), text, .{}, diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return error.SyntaxError,
        };
        if (root.data != .object) return error.RootNotObject;

        const parent = root.getPath(segments[0 .. segments.len - 1]) orelse break;
        const members = switch (parent.data) {
            .object => |m| m,
            else => break,
        };
        const key = segments[segments.len - 1];
        var k = members.len;
        const idx = while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, members[k].key, key)) break k;
        } else break;

        var splices: [2]Splice = undefined;
        const n = removalSplices(text, parent, members, idx, &splices);
        const next = try applySplices(gpa, text, splices[0..n]);
        gpa.free(text);
        text = next;
        changed = true;
    }
    return .{ .text = text, .changed = changed };
}

fn removalSplices(src: []const u8, obj: *const Node, members: []const jsonc.Member, k: usize, splices: *[2]Splice) usize {
    const m = &members[k];
    const after = jsonc.skipTrivia(src, m.value.end).end;
    const has_comma = after < src.len and src[after] == ',';
    const member_end = if (has_comma) after + 1 else m.value.end;

    if (members.len == 1 and isBlank(src[obj.start + 1 .. m.key_start]) and isBlank(src[member_end .. obj.end - 1])) {
        splices[0] = .{ .start = obj.start, .end = obj.end, .text = "{}" };
        return 1;
    }

    var n: usize = 0;
    // A last member without its own comma takes the previous member's comma.
    if (!has_comma and k > 0) {
        const prev_comma = jsonc.skipTrivia(src, members[k - 1].value.end).end;
        if (prev_comma < src.len and src[prev_comma] == ',') {
            if (!jsonc.isFirstOnLine(src, m.key_start)) {
                splices[0] = .{ .start = prev_comma, .end = m.value.end, .text = "" };
                return 1;
            }
            splices[n] = .{ .start = prev_comma, .end = prev_comma + 1, .text = "" };
            n += 1;
        }
    }

    if (jsonc.isFirstOnLine(src, m.key_start)) {
        var start = jsonc.lineStart(src, m.key_start);
        const q = jsonc.skipTriviaSameLine(src, member_end);
        var end = q;
        if (jsonc.isLineBreakAt(src, q)) {
            end = q + @as(usize, if (src[q] == '\r') 2 else 1);
        } else if (q < src.len) {
            start = m.key_start;
        }
        splices[n] = .{ .start = start, .end = end, .text = "" };
        return n + 1;
    }

    var end = member_end;
    if (has_comma) {
        while (end < src.len and (src[end] == ' ' or src[end] == '\t')) end += 1;
    }
    splices[n] = .{ .start = m.key_start, .end = end, .text = "" };
    return n + 1;
}

/// Deep-merges the JSON object `patch_json` into the document: nested
/// objects merge key by key, other values replace, keys the patch does not
/// name keep their values (cmux `settingPresets` semantics). One result for
/// the whole patch.
pub fn merge(gpa: Allocator, src: []const u8, patch_json: []const u8, diag: ?*jsonc.Diagnostic) Error!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const patch = jsonc.parseInto(arena, patch_json, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.InvalidValue,
    };
    if (patch.data != .object) return error.InvalidValue;

    var state: MergeState = .{ .gpa = gpa, .text = try gpa.dupe(u8, src), .diag = diag };
    errdefer gpa.free(state.text);
    var prefix: std.ArrayList([]const u8) = .empty;
    defer prefix.deinit(gpa);
    try state.mergeAt(&prefix, &patch);
    return .{ .text = state.text, .changed = state.changed };
}

const MergeState = struct {
    gpa: Allocator,
    text: []u8,
    changed: bool = false,
    diag: ?*jsonc.Diagnostic,

    fn existingIsObject(self: *MergeState, segs: []const []const u8) Error!bool {
        var probe = jsonc.Tokenizer.init(self.text, true);
        if (probe.next()) |first| if (first.tag == .eof) return false;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const root = jsonc.parseInto(arena_state.allocator(), self.text, .{}, self.diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return error.SyntaxError,
        };
        const n = root.getPath(segs) orelse return false;
        return n.data == .object;
    }

    fn mergeAt(self: *MergeState, prefix: *std.ArrayList([]const u8), patch: *const Node) Error!void {
        for (patch.data.object) |*m| {
            try prefix.append(self.gpa, m.key);
            defer _ = prefix.pop();
            // An object merges into an existing object key by key; `{}` adds
            // no keys, so the existing section stays as it is.
            if (m.value.data == .object and try self.existingIsObject(prefix.items)) {
                try self.mergeAt(prefix, &m.value);
                continue;
            }
            const value_json = try m.value.toJsonAlloc(self.gpa);
            defer self.gpa.free(value_json);
            const r = try setPath(self.gpa, self.text, prefix.items, value_json, self.diag);
            self.gpa.free(self.text);
            self.text = r.text;
            self.changed = self.changed or r.changed;
        }
    }
};

const testing = std.testing;

fn expectSet(src: []const u8, path: []const u8, value: []const u8, expected: []const u8) !void {
    const r = try set(testing.allocator, src, path, value, null);
    defer testing.allocator.free(r.text);
    try testing.expectEqualStrings(expected, r.text);
    var doc = try jsonc.parse(testing.allocator, r.text, .{}, null);
    doc.deinit();
}

fn expectRemove(src: []const u8, path: []const u8, expected: []const u8) !void {
    const r = try remove(testing.allocator, src, path, null);
    defer testing.allocator.free(r.text);
    try testing.expectEqualStrings(expected, r.text);
}

test "unit: proto: json_edit replaces a value and keeps comments" {
    try expectSet(
        \\{
        \\  // Sidebar options
        \\  "sidebar": {
        \\    /* keep me */
        \\    "showPorts": true, // trailing note
        \\    "width": 200
        \\  }
        \\}
    , "sidebar.showPorts", "false",
        \\{
        \\  // Sidebar options
        \\  "sidebar": {
        \\    /* keep me */
        \\    "showPorts": false, // trailing note
        \\    "width": 200
        \\  }
        \\}
    );
}

test "unit: proto: json_edit inserts with sibling indentation" {
    try expectSet(
        \\{
        \\    "terminal": {
        \\        "scrollSpeed": 1
        \\    }
        \\}
    , "terminal.copyOnSelect", "true",
        \\{
        \\    "terminal": {
        \\        "scrollSpeed": 1,
        \\        "copyOnSelect": true
        \\    }
        \\}
    );
    try expectSet("{\n\t\"a\": 1\n}\n", "b.c", "[1, 2]", "{\n\t\"a\": 1,\n\t\"b\": {\n\t\t\"c\": [1, 2]\n\t}\n}\n");
}

test "unit: proto: json_edit keeps a same-line comment on its member" {
    try expectSet("{\n  \"a\": 1 // about a\n}", "b", "2", "{\n  \"a\": 1, // about a\n  \"b\": 2\n}");
}

test "unit: proto: json_edit keeps trailing-comma style" {
    try expectSet("{\n  \"a\": 1,\n}", "b", "\"x\"", "{\n  \"a\": 1,\n  \"b\": \"x\",\n}");
}

test "unit: proto: json_edit copies key spacing and preserves CRLF" {
    try expectSet("{\r\n  \"a\":1\r\n}\r\n", "b.c", "true", "{\r\n  \"a\":1,\r\n  \"b\":{\r\n    \"c\": true\r\n  }\r\n}\r\n");
    try expectSet("{\r\n  \"a\": 1 // c\r\n}", "b", "2", "{\r\n  \"a\": 1, // c\r\n  \"b\": 2\r\n}");
    try expectRemove("{\r\n  \"a\": 1, // c\r\n  \"b\": 2 // d\r\n}", "b", "{\r\n  \"a\": 1 // c\r\n}");
}

test "unit: proto: json_edit edits inline objects inline" {
    try expectSet("{\"a\": 1}", "b", "{\"c\": [true, {\"d\": null}]}", "{\"a\": 1, \"b\": {\"c\": [true, {\"d\": null}]}}");
    try expectSet("{\"a\": {}}", "a.b", "1", "{\"a\": {\"b\": 1}}");
    try expectSet("{\"a\": 1, }", "b", "2", "{\"a\": 1, \"b\": 2, }");
}

test "unit: proto: json_edit fills empty and comment-only files" {
    try expectSet("", "app.appearance", "\"dark\"", "{\n  \"app\": {\n    \"appearance\": \"dark\"\n  }\n}\n");
    try expectSet("  \n", "a", "1", "{\n  \"a\": 1\n}\n");
    try expectSet("// my settings", "a", "1", "// my settings\n{\n  \"a\": 1\n}\n");
    try expectSet("{}", "a", "1", "{\n  \"a\": 1\n}");
    try expectSet("{\n}\n", "a", "1", "{\n  \"a\": 1\n}\n");
    try expectSet("{\n  // nothing yet\n}\n", "a", "1", "{\n  // nothing yet\n  \"a\": 1\n}\n");
    // A byte order mark survives, with no blank line after it.
    try expectSet("\xEF\xBB\xBF", "a", "1", "\xEF\xBB\xBF{\n  \"a\": 1\n}\n");
    try expectSet("\xEF\xBB\xBF\r\n", "a", "1", "\xEF\xBB\xBF{\r\n  \"a\": 1\r\n}\r\n");
    try expectSet("\xEF\xBB\xBF// c\n", "a", "1", "\xEF\xBB\xBF// c\n{\n  \"a\": 1\n}\n");
    try expectSet("\xEF\xBB\xBF{\"a\": 1}", "b", "2", "\xEF\xBB\xBF{\"a\": 1, \"b\": 2}");
}

test "unit: proto: json_edit nested empty object in a multi-line file" {
    try expectSet("{\n  \"sidebar\": {},\n  \"z\": 0\n}", "sidebar.showPorts", "false", "{\n  \"sidebar\": {\n    \"showPorts\": false\n  },\n  \"z\": 0\n}");
}

test "unit: proto: json_edit replaces a null parent and multi-line values" {
    try expectSet("{\n  \"a\": null\n}", "a.b", "1", "{\n  \"a\": {\n    \"b\": 1\n  }\n}");
    try expectSet("{\n  \"a\": 1\n}", "a", "{\"x\": {\"y\": [1, [2]]}}", "{\n  \"a\": {\n    \"x\": {\n      \"y\": [\n        1,\n        [2]\n      ]\n    }\n  }\n}");
}

test "unit: proto: json_edit reports unchanged values" {
    const src = "{\n  \"a\": 1.0, // c\n  \"b\": [1, 2]\n}";
    const r = try set(testing.allocator, src, "a", "1", null);
    defer testing.allocator.free(r.text);
    try testing.expect(!r.changed);
    try testing.expectEqualStrings(src, r.text);
    const r2 = try set(testing.allocator, src, "b", "[1,2]", null);
    defer testing.allocator.free(r2.text);
    try testing.expect(!r2.changed);
}

test "unit: proto: json_edit unicode keys and values" {
    try expectSet("{\n  \"名前\": \"é\"\n}", "名前", "\"日本語 😀\"", "{\n  \"名前\": \"日本語 😀\"\n}");
    try expectSet("{}", "a\"b", "\"\\u0001\"", "{\n  \"a\\\"b\": \"\\u0001\"\n}");
}

test "unit: proto: json_edit rejects bad input" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidPath, set(gpa, "{}", "", "1", null));
    try testing.expectError(error.InvalidPath, set(gpa, "{}", "a..b", "1", null));
    try testing.expectError(error.InvalidPath, set(gpa, "{}", ".a", "1", null));
    try testing.expectError(error.InvalidValue, set(gpa, "{}", "a", "nope", null));
    try testing.expectError(error.InvalidValue, set(gpa, "{}", "a", "1 2", null));
    try testing.expectError(error.RootNotObject, set(gpa, "[1]", "a", "1", null));
    try testing.expectError(error.PathConflict, set(gpa, "{\"a\": 1}", "a.b", "1", null));
    try testing.expectError(error.PathConflict, set(gpa, "{\"a\": [1]}", "a.b", "1", null));
    var diag: jsonc.Diagnostic = .{};
    try testing.expectError(error.SyntaxError, set(gpa, "{\n  \"a\": 1,,\n}", "b", "1", &diag));
    try testing.expectEqual(@as(u32, 2), diag.pos.line);
    try testing.expectEqual(@as(u32, 10), diag.pos.col);
    try testing.expectError(error.SyntaxError, remove(gpa, "{", "a", null));
}

test "unit: proto: json_edit refuses path segments that are not UTF-8" {
    const gpa = testing.allocator;
    // Written as a key, such a segment would leave a file that no longer parses.
    try testing.expectError(error.InvalidPath, set(gpa, "{}", "a\xffb", "1", null));
    try testing.expectError(error.InvalidPath, set(gpa, "{}", "x.\xED\xA0\x80", "1", null)); // lone surrogate
    try testing.expectError(error.InvalidPath, setPath(gpa, "{}", &.{ "ok", "\xc3" }, "1", null));
    try testing.expectError(error.InvalidPath, remove(gpa, "{\"a\": 1}", "\xff", null));
    try testing.expectError(error.InvalidPath, splitPath(gpa, "a.\xe6\x97"));
    // Valid multi-byte segments still work.
    try expectSet("{}", "設定.é", "true", "{\n  \"設定\": {\n    \"é\": true\n  }\n}");
}

test "unit: proto: json_edit removes members losslessly" {
    // Middle member: its whole line, including a trailing comment.
    try expectRemove("{\n  \"a\": 1,\n  \"b\": 2, // gone\n  \"c\": 3\n}", "b", "{\n  \"a\": 1,\n  \"c\": 3\n}");
    // Last member: the previous comma goes too; comments above stay.
    try expectRemove("{\n  \"a\": 1, // keep\n  // about b\n  \"b\": 2\n}", "b", "{\n  \"a\": 1 // keep\n  // about b\n}");
    // Only member collapses to {}.
    try expectRemove("{\n  \"s\": {\n    \"x\": true\n  }\n}", "s.x", "{\n  \"s\": {}\n}");
    // Only member next to a comment keeps the comment.
    try expectRemove("{\n  // c\n  \"x\": 1\n}", "x", "{\n  // c\n}");
    // Inline.
    try expectRemove("{\"a\": 1, \"b\": 2, \"c\": 3}", "b", "{\"a\": 1, \"c\": 3}");
    try expectRemove("{\"a\": 1, \"b\": 2}", "b", "{\"a\": 1}");
    try expectRemove("{\"a\": 1}", "a", "{}");
    // Duplicates all go.
    try expectRemove("{\n  \"a\": 1,\n  \"b\": 0,\n  \"a\": 2\n}", "a", "{\n  \"b\": 0\n}");
    // Trailing-comma style.
    try expectRemove("{\n  \"a\": 1,\n  \"b\": 2,\n}", "b", "{\n  \"a\": 1,\n}");
    // CRLF.
    try expectRemove("{\r\n  \"a\": 1,\r\n  \"b\": 2\r\n}\r\n", "a", "{\r\n  \"b\": 2\r\n}\r\n");
}

test "unit: proto: json_edit remove of a missing path is unchanged" {
    const src = "{\n  \"a\": {\"b\": 1}, // c\n  \"n\": 5\n}";
    for ([_][]const u8{ "x", "a.c", "n.x", "a.b.c" }) |p| {
        const r = try remove(testing.allocator, src, p, null);
        defer testing.allocator.free(r.text);
        try testing.expect(!r.changed);
        try testing.expectEqualStrings(src, r.text);
    }
    const r = try remove(testing.allocator, "", "a", null);
    defer testing.allocator.free(r.text);
    try testing.expect(!r.changed);
}

test "unit: proto: json_edit set then remove round-trips bytes" {
    const originals = [_][]const u8{
        "{\n  // header\n  \"a\": 1, /* x */\n  \"b\": {\n    \"c\": true // note\n  }\n}\n",
        "{\"a\": 1}",
        "{\r\n\t\"a\": [1, 2]\r\n}",
        "{\n  \"a\": 1,\n}",
    };
    for (originals) |src| {
        const r1 = try set(testing.allocator, src, "zNew", "{\"k\": [1, {\"q\": null}]}", null);
        defer testing.allocator.free(r1.text);
        try testing.expect(r1.changed);
        const r2 = try remove(testing.allocator, r1.text, "zNew", null);
        defer testing.allocator.free(r2.text);
        try testing.expectEqualStrings(src, r2.text);
    }
}

test "unit: proto: json_edit random edit sequences keep comments and content" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const sections = [_][]const u8{ "app", "sidebar", "terminal" };
    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    var model: [sections.len][keys.len]?i64 = .{.{null} ** keys.len} ** sections.len;
    var text = try gpa.dupe(u8, "{\n  // top comment\n  \"keep\": \"me\" /* inline */\n}\n");
    defer gpa.free(text);
    for (0..400) |_| {
        const si = rnd.uintLessThan(usize, sections.len);
        const ki = rnd.uintLessThan(usize, keys.len);
        const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ sections[si], keys[ki] });
        defer gpa.free(path);
        const r = if (rnd.boolean()) blk: {
            const v = rnd.intRangeAtMost(i64, -1000, 1000);
            const vs = try std.fmt.allocPrint(gpa, "{d}", .{v});
            defer gpa.free(vs);
            model[si][ki] = v;
            break :blk try set(gpa, text, path, vs, null);
        } else blk: {
            model[si][ki] = null;
            break :blk try remove(gpa, text, path, null);
        };
        gpa.free(text);
        text = r.text;
        var doc = try jsonc.parse(gpa, text, .{ .allow_trailing_commas = false }, null);
        defer doc.deinit();
        for (sections, 0..) |s, a| for (keys, 0..) |k, b| {
            const got = if (doc.root.get(s)) |sec| sec.get(k) else null;
            if (model[a][b]) |v| {
                try testing.expectEqual(v, got.?.asInt().?);
            } else try testing.expect(got == null);
        };
        try testing.expect(std.mem.indexOf(u8, text, "// top comment\n") != null);
        try testing.expect(std.mem.indexOf(u8, text, "/* inline */") != null);
        try testing.expectEqualStrings("me", doc.root.get("keep").?.asString().?);
    }
}

test "unit: proto: json_edit merge applies a preset key by key" {
    const src =
        \\{
        \\  // mine
        \\  "sidebar": {
        \\    "showPorts": true,
        \\    "width": 220
        \\  },
        \\  "app": {"appearance": "dark"}
        \\}
    ;
    const r = try merge(testing.allocator, src, "{\"sidebar\": {\"showPorts\": false, \"showLog\": false}, \"app\": \"x\", \"new\": {\"a\": 1}}", null);
    defer testing.allocator.free(r.text);
    try testing.expect(r.changed);
    try testing.expectEqualStrings(
        \\{
        \\  // mine
        \\  "sidebar": {
        \\    "showPorts": false,
        \\    "width": 220,
        \\    "showLog": false
        \\  },
        \\  "app": "x",
        \\  "new": {
        \\    "a": 1
        \\  }
        \\}
    , r.text);
    try testing.expectError(error.InvalidValue, merge(testing.allocator, src, "[1]", null));
    const same = try merge(testing.allocator, src, "{\"sidebar\": {\"width\": 220}}", null);
    defer testing.allocator.free(same.text);
    try testing.expect(!same.changed);
}

test "unit: proto: json_edit merge of an empty object keeps the section" {
    const gpa = testing.allocator;
    const src = "{\n  \"sidebar\": {\n    \"showPorts\": true,\n    \"width\": 220\n  }\n}";
    // Key-by-key merge: `{}` names no keys, so none change.
    for ([_][]const u8{ "{\"sidebar\": {}}", "{}", "{\"sidebar\": {\"x\": {}}, \"sidebar\": {}}" }) |patch| {
        const r = try merge(gpa, src, patch, null);
        defer gpa.free(r.text);
        if (std.mem.indexOf(u8, patch, "\"x\"") != null) {
            try testing.expectEqualStrings("{\n  \"sidebar\": {\n    \"showPorts\": true,\n    \"width\": 220,\n    \"x\": {}\n  }\n}", r.text);
        } else {
            try testing.expect(!r.changed);
            try testing.expectEqualStrings(src, r.text);
        }
    }
    // A missing section is still created, and a scalar is still replaced.
    const added = try merge(gpa, "{\n  \"a\": 1\n}", "{\"a\": {}, \"b\": {}}", null);
    defer gpa.free(added.text);
    try testing.expectEqualStrings("{\n  \"a\": {},\n  \"b\": {}\n}", added.text);
}
