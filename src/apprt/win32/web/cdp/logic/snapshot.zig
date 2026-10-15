//! Render the cmux/agent-browser snapshot text from an `ax_tree.Tree`
//! (browser-cli-snapshot, browser-cli-snapshot-after).
//!
//! ```
//! - document "Sign in"
//! - main "" [ref=e1]
//!   - textbox "Email" [ref=e2]: me@example.com
//!   - checkbox "Remember me" [ref=e3] [checked]
//!   - button "Sign in" [ref=e4]
//! ```
//!
//! One line per included element, indented two spaces per included ancestor,
//! `- <role> "<name>" [ref=eN]`, then state flags and `: <value>` (both can be
//! turned off for the bare cmux format). Double quotes in names become single
//! quotes; names are whitespace-collapsed and capped at 120 code points. With
//! no elements the body is `- text "<240-char excerpt>"` or `- (empty)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ax = @import("ax_tree.zig");
const css = @import("css.zig");
const refs = @import("refs.zig");
const Tree = ax.Tree;
const NodeIndex = ax.NodeIndex;

pub const default_max_depth: u32 = 12;
pub const post_action_default_max_depth: u32 = 10;
pub const cursor_limit: usize = 256;
pub const name_max_chars: usize = 120;
pub const body_excerpt_chars: usize = 240;

pub const Options = struct {
    /// Keep only interactive roles.
    interactive: bool = false,
    /// Add onclick / cursor:pointer / tabindex elements as `generic`.
    cursor: bool = false,
    /// Drop unnamed non-interactive (structural) elements.
    compact: bool = false,
    /// Maximum nesting of emitted elements (0 = no elements).
    max_depth: u32 = default_max_depth,
    /// CSS selector or `@eN` ref scoping the walk (default: body / root).
    selector: ?[]const u8 = null,
    /// Append `[checked]`, `[level=2]`, … after the ref.
    states: bool = true,
    /// Append `: <value>` for elements with a value.
    values: bool = true,

    pub const ParamError = error{InvalidParams};

    /// `browser.snapshot` params {interactive, cursor, compact, max_depth,
    /// selector}. Wrong types or a negative depth -> InvalidParams.
    pub fn fromParams(params: std.json.ObjectMap) ParamError!Options {
        var o: Options = .{};
        o.interactive = try optBool(params, "interactive", false);
        o.cursor = try optBool(params, "cursor", false);
        o.compact = try optBool(params, "compact", false);
        o.max_depth = try optDepth(params, "max_depth", default_max_depth);
        o.selector = try optString(params, "selector");
        return o;
    }

    /// `snapshot_after` params of mutating actions: snapshot_interactive
    /// (default true), snapshot_compact (true), snapshot_cursor (false),
    /// snapshot_max_depth (10), snapshot_selector.
    pub fn fromPostActionParams(params: std.json.ObjectMap) ParamError!Options {
        var o: Options = .{};
        o.interactive = try optBool(params, "snapshot_interactive", true);
        o.compact = try optBool(params, "snapshot_compact", true);
        o.cursor = try optBool(params, "snapshot_cursor", false);
        o.max_depth = try optDepth(params, "snapshot_max_depth", post_action_default_max_depth);
        o.selector = try optString(params, "snapshot_selector");
        return o;
    }

    pub const ArgError = error{ UnknownFlag, MissingValue, InvalidNumber, UnexpectedArgument };

    /// CLI flags after `snapshot`: --interactive|-i, --cursor, --compact,
    /// --max-depth <n> | --max-depth=<n>, --selector <css> | --selector=<css>.
    /// Strings borrow from `args`.
    pub fn fromArgs(args: []const []const u8) ArgError!Options {
        var o: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--interactive") or std.mem.eql(u8, a, "-i")) {
                o.interactive = true;
            } else if (std.mem.eql(u8, a, "--cursor")) {
                o.cursor = true;
            } else if (std.mem.eql(u8, a, "--compact")) {
                o.compact = true;
            } else if (flagValue(args, &i, "--max-depth")) |v| {
                const val = v orelse return error.MissingValue;
                o.max_depth = std.fmt.parseInt(u32, val, 10) catch return error.InvalidNumber;
            } else if (flagValue(args, &i, "--selector")) |v| {
                const val = v orelse return error.MissingValue;
                if (val.len == 0) return error.MissingValue;
                o.selector = val;
            } else if (a.len > 1 and a[0] == '-') {
                return error.UnknownFlag;
            } else {
                return error.UnexpectedArgument;
            }
        }
        return o;
    }
};

/// Matches `--name value` and `--name=value`. Returns null when `args[i]` is
/// another flag, `?null` when the value is missing.
fn flagValue(args: []const []const u8, i: *usize, comptime name: []const u8) ??[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, name)) {
        if (i.* + 1 >= args.len) return @as(?[]const u8, null);
        i.* += 1;
        return @as(?[]const u8, args[i.*]);
    }
    if (std.mem.startsWith(u8, a, name ++ "=")) return @as(?[]const u8, a[name.len + 1 ..]);
    return null;
}

fn optBool(p: std.json.ObjectMap, key: []const u8, default: bool) Options.ParamError!bool {
    const v = p.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        .null => default,
        else => error.InvalidParams,
    };
}

fn optDepth(p: std.json.ObjectMap, key: []const u8, default: u32) Options.ParamError!u32 {
    const v = p.get(key) orelse return default;
    return switch (v) {
        .null => default,
        .integer => |i| if (i < 0) error.InvalidParams else @intCast(@min(i, std.math.maxInt(u32))),
        .float => |f| if (f < 0 or @floor(f) != f) error.InvalidParams else @intFromFloat(@min(f, @as(f64, std.math.maxInt(u32)))),
        else => error.InvalidParams,
    };
}

fn optString(p: std.json.ObjectMap, key: []const u8) Options.ParamError!?[]const u8 {
    const v = p.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| if (std.mem.trim(u8, s, " \t\r\n").len == 0) null else s,
        else => error.InvalidParams,
    };
}

pub const Snapshot = struct {
    gpa: Allocator,
    /// The full snapshot text (no trailing newline).
    text: []u8,
    element_count: usize,

    pub fn deinit(self: *Snapshot) void {
        self.gpa.free(self.text);
        self.* = undefined;
    }
};

pub const RenderError = error{ ElementNotFound, RefNotFound, InvalidRef, InvalidSelector, UnsupportedSelector } || Allocator.Error;

/// Render the snapshot and replace `table`'s ref set with the emitted refs.
/// `gpa` owns the returned text and scratch memory only; the table copies
/// what it keeps into its own allocator, so `gpa` may be a request arena.
pub fn render(gpa: Allocator, tree: *const Tree, table: *refs.RefTable, opts: Options) RenderError!Snapshot {
    const scope = try resolveScope(gpa, tree, table, opts.selector);
    table.beginSnapshot();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    w.writeAll("- document \"") catch return error.OutOfMemory;
    try writeSanitized(gpa, w, tree.title, name_max_chars);
    w.writeByte('"') catch return error.OutOfMemory;

    // A ref scope can sit inside a container hidden since the ref was issued
    // (a closed dialog): nothing in it is visible, so nothing is listed.
    const scope_hidden = tree.isHidden(scope);
    const Item = struct { idx: NodeIndex, depth: u32 };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    if (!scope_hidden) try stack.append(gpa, .{ .idx = scope, .depth = 0 });
    var emitted: usize = 0;
    var cursor_emitted: usize = 0;
    const scope_is_page = opts.selector == null;

    while (stack.pop()) |item| {
        const n = tree.get(item.idx);
        if (n.hidden or n.kind == .text) continue;
        // The default scope (document/body) is a container, never a line.
        const skip_self = scope_is_page and item.idx == scope;
        var role: []const u8 = "";
        var cursor_generic = false;
        if (!skip_self and !n.ignored and n.kind == .element) {
            if (includeRole(n, opts)) {
                role = n.role;
            } else if (opts.cursor and n.clickable and cursor_emitted < cursor_limit and !ax.isInteractiveRole(n.role)) {
                role = "generic";
                cursor_generic = true;
            }
        }
        var child_depth = item.depth;
        if (role.len > 0) {
            if (item.depth >= opts.max_depth) continue; // nothing deeper fits either
            // Only printed generics count toward the cap.
            if (cursor_generic) cursor_emitted += 1;
            const name = try displayName(gpa, tree, item.idx, role);
            defer gpa.free(name);
            // `add` copies every string into the table's own allocator,
            // which may outlive `gpa` (a per-request arena).
            const path = try css.cssPath(gpa, tree, item.idx);
            defer if (path) |p| gpa.free(p);
            const id = try table.add(.{
                .backend_node_id = n.backend_id,
                .frame_id = n.frame_id,
                .role = role,
                .name = name,
                .css_path = path,
            });
            try writeLine(gpa, w, tree, item.idx, role, name, id, item.depth, opts);
            emitted += 1;
            child_depth = item.depth + 1;
        }
        var i = n.children.len;
        while (i > 0) {
            i -= 1;
            try stack.append(gpa, .{ .idx = n.children[i], .depth = child_depth });
        }
    }

    if (emitted == 0) {
        const body: []const u8 = if (scope_hidden) "" else try tree.innerText(gpa, scope, body_excerpt_chars, false);
        defer if (!scope_hidden) gpa.free(body);
        if (body.len > 0) {
            w.writeAll("\n- text \"") catch return error.OutOfMemory;
            try writeSanitized(gpa, w, body, body_excerpt_chars);
            w.writeByte('"') catch return error.OutOfMemory;
        } else {
            w.writeAll("\n- (empty)") catch return error.OutOfMemory;
        }
    }

    return .{ .gpa = gpa, .text = try aw.toOwnedSlice(), .element_count = emitted };
}

fn includeRole(n: *const ax.Node, opts: Options) bool {
    const role = n.role;
    if (role.len == 0) return false;
    if (ax.isInteractiveRole(role)) return true;
    if (opts.interactive) return false;
    if (!ax.isContentRole(role)) return false;
    if (opts.compact and std.mem.trim(u8, n.name, " \t\r\n").len == 0) return false;
    return true;
}

/// The node's name, or (cursor generics without one) its inner text.
fn displayName(gpa: Allocator, tree: *const Tree, idx: NodeIndex, role: []const u8) Allocator.Error![]u8 {
    const n = tree.get(idx);
    if (n.name.len > 0 or !std.mem.eql(u8, role, "generic")) return sanitize(gpa, n.name, name_max_chars);
    const t = try tree.innerText(gpa, idx, name_max_chars, true);
    defer gpa.free(t);
    return sanitize(gpa, t, name_max_chars);
}

fn writeLine(gpa: Allocator, w: *std.Io.Writer, tree: *const Tree, idx: NodeIndex, role: []const u8, name: []const u8, id: u32, depth: u32, opts: Options) Allocator.Error!void {
    const n = tree.get(idx);
    w.writeByte('\n') catch return error.OutOfMemory;
    writeIndent(w, @as(usize, depth) * 2) catch return error.OutOfMemory;
    w.print("- {s} \"{s}\" [ref=e{d}]", .{ role, name, id }) catch return error.OutOfMemory;
    if (opts.states) writeStates(w, n, role) catch return error.OutOfMemory;
    if (opts.values and n.value.len > 0 and showsValue(role)) {
        const v = try sanitize(gpa, n.value, name_max_chars);
        defer gpa.free(v);
        if (v.len > 0 and !std.mem.eql(u8, v, name)) w.print(": {s}", .{v}) catch return error.OutOfMemory;
    }
}

fn writeIndent(w: *std.Io.Writer, n: usize) std.Io.Writer.Error!void {
    const spaces = " " ** 64;
    var left = n;
    while (left > 0) {
        const k = @min(left, spaces.len);
        try w.writeAll(spaces[0..k]);
        left -= k;
    }
}

fn showsValue(role: []const u8) bool {
    const roles = [_][]const u8{ "textbox", "searchbox", "combobox", "slider", "spinbutton" };
    for (roles) |r| if (std.mem.eql(u8, r, role)) return true;
    return false;
}

fn writeStates(w: *std.Io.Writer, n: *const ax.Node, role: []const u8) std.Io.Writer.Error!void {
    const s = n.states;
    if (s.checked) |c| switch (c) {
        .on => try w.writeAll(" [checked]"),
        .mixed => try w.writeAll(" [checked=mixed]"),
        .off => {},
    };
    if (s.disabled) try w.writeAll(" [disabled]");
    if (s.expanded) |e| try w.writeAll(if (e) " [expanded]" else " [expanded=false]");
    if (s.level) |l| if (std.mem.eql(u8, role, "heading")) try w.print(" [level={d}]", .{l});
    if (s.pressed) |p| switch (p) {
        .on => try w.writeAll(" [pressed]"),
        .mixed => try w.writeAll(" [pressed=mixed]"),
        .off => {},
    };
    if (s.selected) try w.writeAll(" [selected]");
    if (s.required) try w.writeAll(" [required]");
    if (s.readonly) try w.writeAll(" [readonly]");
    if (s.focused) try w.writeAll(" [focused]");
}

/// Collapse whitespace (including control characters), trim, replace `"`
/// with `'`, cap at `max_chars` code points. Caller frees.
pub fn sanitize(gpa: Allocator, s: []const u8, max_chars: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chars: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < s.len and chars < max_chars) {
        const c = s[i];
        if (ax.isSpace(c) or c < 0x20 or c == 0x7f) {
            if (out.items.len > 0) pending_space = true;
            i += 1;
            continue;
        }
        if (pending_space) {
            try out.append(gpa, ' ');
            chars += 1;
            pending_space = false;
            if (chars >= max_chars) break;
        }
        const len = ax.cpLen(s, i);
        if (c == '"') {
            try out.append(gpa, '\'');
        } else if (len == 1 and c >= 0x80) {
            // Malformed UTF-8 byte: U+FFFD keeps the output valid.
            try out.appendSlice(gpa, "\u{FFFD}");
        } else {
            try out.appendSlice(gpa, s[i .. i + len]);
        }
        chars += 1;
        i += len;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

fn writeSanitized(gpa: Allocator, w: *std.Io.Writer, s: []const u8, max_chars: usize) Allocator.Error!void {
    const t = try sanitize(gpa, s, max_chars);
    defer gpa.free(t);
    w.writeAll(t) catch return error.OutOfMemory;
}

/// Snapshot scope: the default page scope, an `@eN` ref, or the first CSS
/// match in document order.
pub fn resolveScope(gpa: Allocator, tree: *const Tree, table: *const refs.RefTable, selector: ?[]const u8) RenderError!NodeIndex {
    const sel = selector orelse return tree.bodyIndex();
    if (refs.isRefToken(sel)) {
        const e = try table.lookup(sel);
        const bid = e.backend_node_id orelse return error.RefNotFound;
        return tree.findByBackendId(bid, e.frame_id) orelse error.RefNotFound;
    }
    var parsed = try css.parse(gpa, sel);
    defer parsed.deinit();
    const matches = try parsed.queryAll(gpa, tree, tree.root);
    defer gpa.free(matches);
    if (matches.len == 0) return error.ElementNotFound;
    return matches[0];
}

pub const PageInfo = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    ready_state: []const u8 = "",
    /// Page text (defaults to the tree's body text when null).
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
};

/// `browser.snapshot` result: {snapshot, title, url, ready_state,
/// refs:{eN:{role,name}}, page:{title,url,ready_state,text,html}}.
pub fn writeJson(gpa: Allocator, s: *std.json.Stringify, snap: *const Snapshot, tree: *const Tree, table: *const refs.RefTable, page: PageInfo) (std.Io.Writer.Error || Allocator.Error)!void {
    const title = if (page.title.len > 0) page.title else tree.title;
    const url = if (page.url.len > 0) page.url else tree.url;
    try s.beginObject();
    try s.objectField("snapshot");
    try s.write(snap.text);
    try s.objectField("title");
    try s.write(title);
    try s.objectField("url");
    try s.write(url);
    try s.objectField("ready_state");
    try s.write(page.ready_state);
    try s.objectField("refs");
    try table.writeJson(s);
    try s.objectField("page");
    try s.beginObject();
    try s.objectField("title");
    try s.write(title);
    try s.objectField("url");
    try s.write(url);
    try s.objectField("ready_state");
    try s.write(page.ready_state);
    try s.objectField("text");
    if (page.text) |t| {
        try s.write(t);
    } else {
        const t = try tree.innerText(gpa, tree.bodyIndex(), 0, false);
        defer gpa.free(t);
        try s.write(t);
    }
    try s.objectField("html");
    try s.write(page.html orelse "");
    try s.endObject();
    try s.endObject();
}

/// Lines the CLI appends to an empty snapshot: `url: …`, `ready_state: …`
/// and, for an empty or about:blank URL, the navigation hint naming
/// `surface` (the handle the user typed, e.g. `surface:2`).
pub fn writeEmptyHints(w: *std.Io.Writer, surface: []const u8, url: []const u8, ready_state: []const u8) std.Io.Writer.Error!void {
    try w.print("url: {s}\nready_state: {s}\n", .{ url, ready_state });
    const u = std.mem.trim(u8, url, " \t\r\n");
    if (u.len == 0 or std.mem.eql(u8, u, "about:blank")) {
        try w.print("hint: run 'cmux browser {s} get url' to verify navigation\n", .{surface});
    }
}

/// First `max_lines` lines of a snapshot (diagnostics `snapshot_excerpt`).
pub fn excerpt(text: []const u8, max_lines: usize) []const u8 {
    if (max_lines == 0) return text[0..0];
    var lines: usize = 0;
    for (text, 0..) |c, i| {
        if (c != '\n') continue;
        lines += 1;
        if (lines >= max_lines) return text[0..i];
    }
    return text;
}
