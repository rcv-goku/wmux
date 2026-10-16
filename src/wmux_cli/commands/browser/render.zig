//! Text output of browser results (stable for scripts; SPEC.json
//! `browser-cli-*`). Page data (snapshots, values, titles) is written as
//! received, never rebranded; only authored hints name the program.

const std = @import("std");
const proto = @import("wmux_proto");
const idformat = proto.idformat;
const utf8 = proto.utf8;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Render = @import("plan.zig").Render;

pub const Options = struct {
    /// Program name for hints (`cmux`/`wmux`).
    prog: []const u8 = "cmux",
    id_format: idformat.Mode = .refs,
    /// The target surface as typed (snapshot hint).
    surface: ?[]const u8 = null,
};

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: std.json.Value, key: []const u8) ?i64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| if (@floor(x) == x and @abs(x) < 9e15) @intFromFloat(x) else null,
        else => null,
    };
}

fn boolean(v: std.json.Value, key: []const u8) ?bool {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

fn array(v: std.json.Value, key: []const u8) ?[]const std.json.Value {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .array => |a| a.items,
        else => null,
    };
}

/// Compact JSON.
fn writeCompact(w: *Writer, v: std.json.Value) Writer.Error!void {
    try std.json.Stringify.value(v, .{}, w);
}

/// A number without spurious decimals (`2`, not `2e0` or `2.0`).
fn writeNumber(w: *Writer, x: f64) Writer.Error!void {
    if (@floor(x) == x and @abs(x) < 9e15) return w.print("{d}", .{@as(i64, @intFromFloat(x))});
    try w.print("{d}", .{x});
}

/// Strings raw, numbers plainly, everything else as compact JSON.
pub fn writeValue(w: *Writer, v: std.json.Value) Writer.Error!void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |x| try writeNumber(w, x),
        .number_string => |s| try w.writeAll(s),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        else => try writeCompact(w, v),
    }
}

fn line(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeAll(s);
    if (s.len == 0 or s[s.len - 1] != '\n') try w.writeByte('\n');
}

/// `OK`, then the post-action snapshot or its error (stderr).
pub fn writeOk(arena: Allocator, w: *Writer, err: *Writer, result: std.json.Value) (Writer.Error || Allocator.Error)!void {
    try w.writeAll("OK\n");
    try writePostAction(arena, w, err, result);
}

/// One line of printable text (error output convention, ADR-4.7): page
/// text inside an error must not reach the terminal as control sequences.
fn writeSanitized(arena: Allocator, w: *Writer, s: []const u8, cap: usize) (Writer.Error || Allocator.Error)!void {
    const clean = try utf8.sanitizePrintableAlloc(arena, s);
    const t = utf8.truncateUtf8(clean, cap);
    try w.writeAll(t);
    if (t.len < clean.len) try w.writeAll("\u{2026}");
}

fn writePostAction(arena: Allocator, w: *Writer, err: *Writer, result: std.json.Value) (Writer.Error || Allocator.Error)!void {
    if (str(result, "post_action_snapshot")) |s| {
        if (s.len > 0) try line(w, s);
    } else if (field(result, "post_action_snapshot_error")) |e| {
        try err.writeAll("snapshot_after failed: ");
        try writeSanitized(arena, err, str(e, "code") orelse "error", 64);
        try err.writeAll(": ");
        try writeSanitized(arena, err, str(e, "message") orelse "(no message)", 4096);
        try err.writeByte('\n');
    }
}

/// `true`/`false` from a boolean field (other shapes print as JSON).
fn writeBoolField(w: *Writer, result: std.json.Value, key: []const u8) Writer.Error!void {
    if (field(result, key)) |f| try writeValue(w, f) else try w.writeAll("false");
    try w.writeByte('\n');
}

/// Snapshot text; an empty page also gets its URL, ready state and a hint.
fn writeSnapshot(w: *Writer, result: std.json.Value, opts: Options) Writer.Error!void {
    const text = str(result, "snapshot") orelse "- (empty)";
    try line(w, text);
    if (std.mem.indexOf(u8, text, "[ref=") != null) return;
    const url = str(result, "url") orelse "";
    try w.print("url: {s}\n", .{url});
    try w.print("ready_state: {s}\n", .{str(result, "ready_state") orelse "unknown"});
    if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) {
        try w.print("hint: run '{s} browser {s} get url' to verify navigation\n", .{ opts.prog, opts.surface orelse "<surface>" });
    }
}

/// `OK surface=<ref> pane=<ref> placement=split|reuse|external`.
fn writeOpen(w: *Writer, result: std.json.Value, opts: Options) Writer.Error!void {
    try w.writeAll("OK surface=");
    try idformat.writeHandle(w, opts.id_format, str(result, "surface_ref"), str(result, "surface_id"), .{});
    try w.writeAll(" pane=");
    try idformat.writeHandle(w, opts.id_format, str(result, "pane_ref"), str(result, "pane_id"), .{});
    const strategy = str(result, "placement_strategy");
    const placement = if (boolean(result, "opened_externally") orelse false)
        "external"
    else if (strategy != null and std.mem.eql(u8, strategy.?, "external"))
        "external"
    else if (boolean(result, "created_split")) |s|
        (if (s) "split" else "reuse")
    else
        strategy orelse "split";
    try w.print(" placement={s}\n", .{placement});
}

fn writeEntries(w: *Writer, result: std.json.Value, key: []const u8, empty: []const u8, is_errors: bool) Writer.Error!void {
    const items = array(result, key) orelse &.{};
    if (items.len == 0) return line(w, empty);
    for (items) |e| {
        if (is_errors) {
            try w.writeAll("[error] ");
            try w.writeAll(str(e, "message") orelse "");
        } else {
            try w.print("[{s}] ", .{str(e, "level") orelse "log"});
            try w.writeAll(str(e, "text") orelse "");
        }
        try w.writeByte('\n');
    }
}

/// `No recent downloads.` or numbered records with indented details.
fn writeDownloads(w: *Writer, result: std.json.Value) Writer.Error!void {
    const items = array(result, "downloads") orelse &.{};
    if (items.len == 0) return w.writeAll("No recent downloads.\n");
    for (items, 1..) |d, n| {
        try w.print("{d}. {s} {s}\n", .{ n, str(d, "status") orelse "unknown", str(d, "filename") orelse "(unnamed)" });
        try w.print("   id: {s}\n", .{str(d, "download_id") orelse "(unavailable)"});
        const path = str(d, "path");
        try w.print("   path: {s}\n", .{path orelse "(unavailable)"});
        if (int(d, "bytes")) |b| try w.print("   bytes: {d}\n", .{b}) else try w.writeAll("   bytes: (unknown)\n");
        if (path != null) {
            if (boolean(d, "path_exists")) |e| try w.print("   path_exists: {}\n", .{e}) else try w.writeAll("   path_exists: (unknown)\n");
        }
    }
}

/// `<slug>\t<name>\t<id>` plus ` (last used, default)` markers.
fn writeProfileLine(w: *Writer, p: std.json.Value) Writer.Error!void {
    const name = str(p, "name") orelse "";
    try w.print("{s}\t{s}\t{s}", .{ str(p, "slug") orelse name, name, str(p, "id") orelse "" });
    const last = boolean(p, "last_used") orelse boolean(p, "is_last_used") orelse false;
    const default = boolean(p, "is_default") orelse boolean(p, "default") orelse false;
    if (last and default) try w.writeAll(" (last used, default)") else if (last) try w.writeAll(" (last used)") else if (default) try w.writeAll(" (default)");
}

fn profileOf(result: std.json.Value) std.json.Value {
    return field(result, "profile") orelse result;
}

fn profileName(result: std.json.Value, fallback: []const u8) []const u8 {
    return str(profileOf(result), "name") orelse str(result, "new_name") orelse fallback;
}

fn clearedCount(result: std.json.Value) i64 {
    if (int(result, "cleared_count")) |n| return n;
    if (int(result, "cleared")) |n| return n;
    if (array(result, "cleared")) |a| return @intCast(a.len);
    if (array(result, "profiles")) |a| return @intCast(a.len);
    return 1;
}

fn writeTabs(w: *Writer, result: std.json.Value, opts: Options) Writer.Error!void {
    const items = array(result, "tabs") orelse &.{};
    if (items.len == 0) return w.writeAll("No browser tabs\n");
    for (items) |t| {
        const focused = boolean(t, "focused") orelse false;
        try w.writeAll(if (focused) "* " else "  ");
        if (int(t, "index")) |i| try w.print("{d} ", .{i});
        try idformat.writeHandle(w, opts.id_format, str(t, "ref"), str(t, "id"), .{});
        try w.print("\t{s}\t{s}\n", .{ str(t, "title") orelse "", str(t, "url") orelse "" });
    }
}

fn writeImported(w: *Writer, result: std.json.Value) Writer.Error!void {
    const n = int(result, "imported") orelse int(result, "imported_count") orelse int(result, "cookies") orelse 0;
    const from = str(result, "browser") orelse str(result, "source_browser") orelse "browser";
    try w.print("Imported {d} cookies from {s}.\n", .{ n, from });
    if (int(result, "skipped")) |s| if (s > 0) try w.print("Skipped {d} cookies.\n", .{s});
    for (array(result, "warnings") orelse &.{}) |x| switch (x) {
        .string => |s| try w.print("Warning: {s}\n", .{s}),
        else => {},
    };
}

/// Text for `render` (everything but `screenshot`, which the run step
/// prints after placing the file).
pub fn write(arena: Allocator, w: *Writer, err: *Writer, render: Render, result: std.json.Value, opts: Options) (Writer.Error || Allocator.Error)!void {
    switch (render) {
        .ok, .screenshot => try writeOk(arena, w, err, result),
        .url => try line(w, str(result, "url") orelse ""),
        .focused => try writeBoolField(w, result, "focused"),
        .bool_value => try writeBoolField(w, result, "value"),
        .value => {
            for ([_][]const u8{ "value", "count", "url", "title" }) |k| {
                if (field(result, k)) |f| {
                    try writeValue(w, f);
                    try w.writeByte('\n');
                    return;
                }
            }
            try writeCompact(w, result);
            try w.writeByte('\n');
        },
        .snapshot => try writeSnapshot(w, result, opts),
        .eval => {
            if (field(result, "value")) |v| {
                try writeValue(w, v);
                try w.writeByte('\n');
            } else try w.writeAll("OK\n");
        },
        .open => try writeOpen(w, result, opts),
        .console => try writeEntries(w, result, "entries", "No console entries", false),
        .errors => try writeEntries(w, result, "errors", "No browser errors", true),
        .downloads => try writeDownloads(w, result),
        .profiles_list => {
            const items = array(result, "profiles") orelse &.{};
            if (items.len == 0) return w.writeAll("No browser profiles\n");
            for (items) |p| {
                try writeProfileLine(w, p);
                try w.writeByte('\n');
            }
        },
        .profile_created => {
            try w.writeAll("Created browser profile ");
            try writeProfileLine(w, profileOf(result));
            try w.writeByte('\n');
        },
        .profile_renamed => try w.print("Renamed browser profile to {s}.\n", .{profileName(result, "")}),
        .profiles_cleared => {
            const n = clearedCount(result);
            try w.print("Cleared {d} browser profile(s).\n", .{n});
        },
        .profile_deleted => try w.print("Deleted browser profile {s}.\n", .{profileName(result, str(result, "deleted") orelse "")}),
        .design_mode => try w.writeAll(if (boolean(result, "enabled") orelse false) "enabled\n" else "disabled\n"),
        .tabs => try writeTabs(w, result, opts),
        .imported => try writeImported(w, result),
        .json => try @import("../../output.zig").writeResult(arena, w, result, opts.id_format),
    }
}

const testing = std.testing;

fn renderAlloc(a: Allocator, render: Render, json: []const u8, opts: Options) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try write(a, &out.writer, &err.writer, render, v, opts);
    return std.mem.concat(a, u8, &.{ out.written(), err.written() });
}

test "unit: browser-cli: eval and value formatting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("2\n", try renderAlloc(a, .eval, "{\"value\":2.0}", .{}));
    try testing.expectEqualStrings("0.5\n", try renderAlloc(a, .eval, "{\"value\":0.5}", .{}));
    try testing.expectEqualStrings("My \"page\" \u{1F600}\n", try renderAlloc(a, .eval, "{\"value\":\"My \\\"page\\\" \u{1F600}\"}", .{}));
    try testing.expectEqualStrings("{\"a\":[1,true]}\n", try renderAlloc(a, .eval, "{\"value\":{\"a\":[1,true]}}", .{}));
    try testing.expectEqualStrings("OK\n", try renderAlloc(a, .eval, "{}", .{}));
    try testing.expectEqualStrings("null\n", try renderAlloc(a, .eval, "{\"value\":null}", .{}));
    try testing.expectEqualStrings("3\n", try renderAlloc(a, .value, "{\"count\":3}", .{}));
    try testing.expectEqualStrings("{\"x\":1,\"width\":2}\n", try renderAlloc(a, .value, "{\"value\":{\"x\":1,\"width\":2}}", .{}));
    try testing.expectEqualStrings("false\n", try renderAlloc(a, .bool_value, "{\"value\":false}", .{}));
    try testing.expectEqualStrings("true\n", try renderAlloc(a, .focused, "{\"focused\":true}", .{}));
    try testing.expectEqualStrings("\n", try renderAlloc(a, .url, "{}", .{}));
}

test "unit: browser-cli: snapshot text, empty page hint and post-action output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("- document \"Login\"\n  - textbox \"Email\" [ref=e1]\n", try renderAlloc(a, .snapshot, "{\"snapshot\":\"- document \\\"Login\\\"\\n  - textbox \\\"Email\\\" [ref=e1]\"}", .{}));
    try testing.expectEqualStrings(
        "- document \"\"\n- (empty)\nurl: about:blank\nready_state: complete\nhint: run 'wmux browser surface:2 get url' to verify navigation\n",
        try renderAlloc(a, .snapshot, "{\"snapshot\":\"- document \\\"\\\"\\n- (empty)\",\"url\":\"about:blank\",\"ready_state\":\"complete\"}", .{ .prog = "wmux", .surface = "surface:2" }),
    );
    try testing.expectEqualStrings("OK\n- document \"x\"\n", try renderAlloc(a, .ok, "{\"post_action_snapshot\":\"- document \\\"x\\\"\"}", .{}));
    try testing.expectEqualStrings("OK\nsnapshot_after failed: js_error: boom\n", try renderAlloc(a, .ok, "{\"post_action_snapshot_error\":{\"code\":\"js_error\",\"message\":\"boom\"}}", .{}));
    // Page text in the error cannot smuggle terminal control sequences or
    // extra lines onto stderr (OSC 52, CSI, BEL, newlines, bidi overrides).
    try testing.expectEqualStrings(
        "OK\nsnapshot_after failed: js_error: boom]52;c;eA== [2Jnext\n",
        try renderAlloc(a, .ok, "{\"post_action_snapshot_error\":{\"code\":\"js_error\\u001b\",\"message\":\"boom\\u001b]52;c;eA==\\u0007\\n\\u001b[2J\\u202enext\"}}", .{}),
    );
    try testing.expectEqualStrings("OK\nsnapshot_after failed: error: (no message)\n", try renderAlloc(a, .ok, "{\"post_action_snapshot_error\":{\"code\":7}}", .{}));
}

test "unit: browser-cli: open placement line honors id-format" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = "{\"surface_id\":\"S-UUID\",\"surface_ref\":\"surface:5\",\"pane_id\":\"P-UUID\",\"pane_ref\":\"pane:2\",\"created_split\":true}";
    try testing.expectEqualStrings("OK surface=surface:5 pane=pane:2 placement=split\n", try renderAlloc(a, .open, r, .{}));
    try testing.expectEqualStrings("OK surface=S-UUID pane=P-UUID placement=split\n", try renderAlloc(a, .open, r, .{ .id_format = .uuids }));
    try testing.expectEqualStrings("OK surface=surface:5 pane=pane:2 placement=reuse\n", try renderAlloc(a, .open, "{\"surface_ref\":\"surface:5\",\"pane_ref\":\"pane:2\",\"created_split\":false}", .{}));
    try testing.expectEqualStrings("OK surface= pane= placement=external\n", try renderAlloc(a, .open, "{\"opened_externally\":true,\"placement_strategy\":\"external\"}", .{}));
}

test "unit: browser-cli: list renderers for empty and hostile data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("No console entries\n", try renderAlloc(a, .console, "{\"entries\":[]}", .{}));
    try testing.expectEqualStrings("No browser errors\n", try renderAlloc(a, .errors, "{}", .{}));
    try testing.expectEqualStrings("No recent downloads.\n", try renderAlloc(a, .downloads, "{\"downloads\":\"bogus\"}", .{}));
    try testing.expectEqualStrings("No browser profiles\n", try renderAlloc(a, .profiles_list, "[]", .{}));
    try testing.expectEqualStrings("No browser tabs\n", try renderAlloc(a, .tabs, "null", .{}));
    try testing.expectEqualStrings("[log] \n", try renderAlloc(a, .console, "{\"entries\":[{}]}", .{}));
    try testing.expectEqualStrings("disabled\n", try renderAlloc(a, .design_mode, "{\"enabled\":\"yes\"}", .{}));
    try testing.expectEqualStrings("Cleared 2 browser profile(s).\n", try renderAlloc(a, .profiles_cleared, "{\"cleared\":[{},{}]}", .{}));
}
