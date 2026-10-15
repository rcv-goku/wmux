//! `browser find` locators and selector resolution over an `ax_tree.Tree`
//! (browser-cli-find, browser-element-refs).
//!
//! role/text/label/placeholder/alt/title/testid match case-insensitively by
//! substring unless `exact` (then: whitespace-normalized, case-sensitive
//! equality). first/last/nth take a CSS selector (native subset, see
//! css.zig). Hidden subtrees never match. `resolveSelector` is the shared
//! entry point for every verb that takes a selector: `eN`/`@eN` refs through
//! the ref table, everything else as CSS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ax = @import("ax_tree.zig");
const css = @import("css.zig");
const refs = @import("refs.zig");
const Tree = ax.Tree;
const NodeIndex = ax.NodeIndex;

pub const Kind = enum {
    role,
    text,
    label,
    placeholder,
    alt,
    title,
    testid,
    first,
    last,
    nth,

    /// Socket method suffix after `browser.find.`; also the CLI word.
    pub fn fromName(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
};

pub const Locator = struct {
    kind: Kind,
    /// Role, text to match, or CSS selector (first/last/nth).
    value: []const u8,
    /// Accessible-name filter (role only).
    name: ?[]const u8 = null,
    exact: bool = false,
    /// nth only: 0-based; negative counts from the end (-1 = last).
    index: i64 = 0,
};

pub const ParamError = error{ MissingParam, InvalidParams, EmptyValue };

/// Socket params for `browser.find.<kind>`: role {role, name?, exact},
/// text {text}, label {label}, placeholder {placeholder}, alt {alt},
/// title {title}, testid {testid}, first/last {selector}, nth {index,
/// selector}. Strings borrow from `params`.
pub fn fromParams(kind: Kind, params: std.json.ObjectMap) ParamError!Locator {
    var loc: Locator = .{ .kind = kind, .value = "" };
    loc.exact = switch (params.get("exact") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        .null => false,
        else => return error.InvalidParams,
    };
    switch (kind) {
        .first, .last, .nth => {
            loc.value = refs.selectorFromParams(params) orelse return error.MissingParam;
            if (kind == .nth) {
                const v = params.get("index") orelse return error.MissingParam;
                loc.index = switch (v) {
                    .integer => |i| i,
                    .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch return error.InvalidParams,
                    else => return error.InvalidParams,
                };
            }
        },
        else => {
            loc.value = try requiredString(params, @tagName(kind));
            if (kind == .role) {
                if (params.get("name")) |n| switch (n) {
                    .string => |s| loc.name = s,
                    .null => {},
                    else => return error.InvalidParams,
                };
            }
        },
    }
    return loc;
}

fn requiredString(params: std.json.ObjectMap, key: []const u8) ParamError![]const u8 {
    const v = params.get(key) orelse return error.MissingParam;
    if (v != .string) return error.InvalidParams;
    if (std.mem.trim(u8, v.string, " \t\r\n").len == 0) return error.EmptyValue;
    return v.string;
}

pub const ArgError = error{ MissingParam, UnknownFlag, MissingValue, InvalidNumber, UnexpectedArgument, EmptyValue, InvalidParams };

/// CLI words after `find`: `role <role> [--name <text>] [--exact]`,
/// `text|label|placeholder|alt|title|testid [--exact] <value>`,
/// `first|last [--selector <css>|<css>]`, `nth [--index <n>|<n>]
/// [--selector <css>|<css>]`. Strings borrow from `args`.
pub fn fromArgs(args: []const []const u8) ArgError!Locator {
    if (args.len == 0) return error.MissingParam;
    const kind = Kind.fromName(args[0]) orelse return error.InvalidParams;
    var loc: Locator = .{ .kind = kind, .value = "" };
    var positionals: [2]?[]const u8 = .{ null, null };
    var npos: usize = 0;
    var have_index = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--exact")) {
            if (kind == .first or kind == .last or kind == .nth) return error.UnknownFlag;
            loc.exact = true;
        } else if (flag(args, &i, "--name")) |v| {
            if (kind != .role) return error.UnknownFlag;
            loc.name = v orelse return error.MissingValue;
        } else if (flag(args, &i, "--selector")) |v| {
            if (kind != .first and kind != .last and kind != .nth) return error.UnknownFlag;
            loc.value = v orelse return error.MissingValue;
        } else if (flag(args, &i, "--index")) |v| {
            if (kind != .nth) return error.UnknownFlag;
            loc.index = std.fmt.parseInt(i64, v orelse return error.MissingValue, 10) catch return error.InvalidNumber;
            have_index = true;
        } else if (a.len > 1 and a[0] == '-' and !(kind == .nth and !have_index and isInt(a))) {
            return error.UnknownFlag;
        } else {
            if (npos >= positionals.len) return error.UnexpectedArgument;
            positionals[npos] = a;
            npos += 1;
        }
    }
    var p: usize = 0;
    if (kind == .nth and !have_index) {
        const s = positionals[p] orelse return error.MissingParam;
        loc.index = std.fmt.parseInt(i64, s, 10) catch return error.InvalidNumber;
        p += 1;
    }
    if (loc.value.len == 0) {
        loc.value = positionals[p] orelse return error.MissingParam;
        p += 1;
    }
    if (p < npos) return error.UnexpectedArgument;
    if (std.mem.trim(u8, loc.value, " \t\r\n").len == 0) return error.EmptyValue;
    return loc;
}

fn isInt(s: []const u8) bool {
    _ = std.fmt.parseInt(i64, s, 10) catch return false;
    return true;
}

fn flag(args: []const []const u8, i: *usize, comptime name: []const u8) ??[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, name)) {
        if (i.* + 1 >= args.len) return @as(?[]const u8, null);
        i.* += 1;
        return @as(?[]const u8, args[i.*]);
    }
    if (std.mem.startsWith(u8, a, name ++ "=")) return @as(?[]const u8, a[name.len + 1 ..]);
    return null;
}

/// Case-insensitive (ASCII) substring, or whitespace-normalized equality when
/// `exact`. An empty needle matches only in non-exact mode.
pub fn matchText(haystack: []const u8, needle: []const u8, exact: bool) bool {
    if (exact) return normalizedEql(haystack, needle);
    const n = std.mem.trim(u8, needle, " \t\r\n");
    if (n.len == 0) return true;
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (!ax.isSpace(haystack[i]) and matchAt(haystack, i, n)) return true;
    }
    return false;
}

/// Case-insensitive match of `needle` at `h[start..]`, where any whitespace
/// run in the needle matches any non-empty whitespace run in the haystack.
fn matchAt(h: []const u8, start: usize, needle: []const u8) bool {
    var i = start;
    var j: usize = 0;
    while (j < needle.len) {
        if (ax.isSpace(needle[j])) {
            if (i >= h.len or !ax.isSpace(h[i])) return false;
            while (j < needle.len and ax.isSpace(needle[j])) j += 1;
            while (i < h.len and ax.isSpace(h[i])) i += 1;
            continue;
        }
        if (i >= h.len or std.ascii.toLower(h[i]) != std.ascii.toLower(needle[j])) return false;
        i += 1;
        j += 1;
    }
    return true;
}

fn normalizedEql(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, " \t\r\n\x0c");
    var ib = std.mem.tokenizeAny(u8, b, " \t\r\n\x0c");
    while (true) {
        const wa = ia.next();
        const wb = ib.next();
        if (wa == null and wb == null) return true;
        if (wa == null or wb == null) return false;
        if (!std.mem.eql(u8, wa.?, wb.?)) return false;
    }
}

pub const FindError = error{ InvalidSelector, UnsupportedSelector } || Allocator.Error;

/// All matches under `scope` (null = whole tree) in document order. For
/// `nth`, `first` and `last` this is every CSS match (the pick happens in
/// `findOne`). Caller frees.
pub fn findAll(gpa: Allocator, tree: *const Tree, loc: Locator, scope: ?NodeIndex) FindError![]NodeIndex {
    const root = scope orelse tree.root;
    switch (loc.kind) {
        .first, .last, .nth => {
            var sel = try css.parse(gpa, loc.value);
            defer sel.deinit();
            return sel.queryAll(gpa, tree, root);
        },
        else => {},
    }
    const order = try tree.preorder(gpa, root);
    defer gpa.free(order);
    var out: std.ArrayList(NodeIndex) = .empty;
    errdefer out.deinit(gpa);
    for (order) |idx| {
        const n = tree.get(idx);
        if (n.kind != .element or n.ignored) continue;
        const hit = switch (loc.kind) {
            .role => std.ascii.eqlIgnoreCase(n.role, std.mem.trim(u8, loc.value, " \t\r\n")) and
                (if (loc.name) |nm| matchText(n.name, nm, loc.exact) else true),
            .text => try textHit(gpa, tree, idx, loc),
            .label => n.label.len > 0 and matchText(n.label, loc.value, loc.exact),
            .placeholder => attrHit(n, "placeholder", loc) or attrHit(n, "aria-placeholder", loc),
            .alt => attrHit(n, "alt", loc) or (n.tag.len == 0 and std.mem.eql(u8, n.role, "img") and matchText(n.name, loc.value, loc.exact)),
            .title => attrHit(n, "title", loc),
            .testid => attrHit(n, "data-testid", loc),
            .first, .last, .nth => unreachable,
        };
        if (hit) try out.append(gpa, idx);
    }
    return out.toOwnedSlice(gpa);
}

fn attrHit(n: *const ax.Node, name: []const u8, loc: Locator) bool {
    const v = n.attr(name) orelse return false;
    return matchText(v, loc.value, loc.exact);
}

/// Innermost element whose visible text matches: it matches and none of its
/// element children does.
fn textHit(gpa: Allocator, tree: *const Tree, idx: NodeIndex, loc: Locator) Allocator.Error!bool {
    if (!try subtreeTextMatches(gpa, tree, idx, loc)) return false;
    for (tree.get(idx).children) |c| {
        const cn = tree.get(c);
        if (cn.hidden or cn.kind == .text) continue;
        if (try subtreeTextMatches(gpa, tree, c, loc)) return false;
    }
    return true;
}

fn subtreeTextMatches(gpa: Allocator, tree: *const Tree, idx: NodeIndex, loc: Locator) Allocator.Error!bool {
    const t = try tree.innerText(gpa, idx, 0, false);
    defer gpa.free(t);
    return matchText(t, loc.value, loc.exact);
}

/// The single element a locator returns: the first match, or for `last` /
/// `nth` the picked one. null when nothing matches.
pub fn findOne(gpa: Allocator, tree: *const Tree, loc: Locator, scope: ?NodeIndex) FindError!?NodeIndex {
    const all = try findAll(gpa, tree, loc, scope);
    defer gpa.free(all);
    if (all.len == 0) return null;
    return switch (loc.kind) {
        .last => all[all.len - 1],
        .nth => blk: {
            const len: i64 = @intCast(all.len);
            const i = if (loc.index < 0) len + loc.index else loc.index;
            if (i < 0 or i >= len) break :blk null;
            break :blk all[@intCast(i)];
        },
        else => all[0],
    };
}

pub const ResolveError = error{ RefNotFound, InvalidRef, ElementNotFound, InvalidSelector, UnsupportedSelector } || Allocator.Error;

/// Resolve a selector argument: `eN`/`@eN`/`ref=eN` through `table` (the
/// element must still be in `tree`), otherwise the first CSS match.
pub fn resolveSelector(gpa: Allocator, tree: *const Tree, table: *const refs.RefTable, selector: []const u8) ResolveError!NodeIndex {
    const sel = std.mem.trim(u8, selector, " \t\r\n");
    if (sel.len == 0) return error.InvalidSelector;
    if (refs.isRefToken(sel)) {
        const e = try table.lookup(sel);
        const bid = e.backend_node_id orelse return error.RefNotFound;
        return tree.findByBackendId(bid, e.frame_id) orelse error.RefNotFound;
    }
    if (sel[0] == '@') return error.InvalidRef;
    var parsed = try css.parse(gpa, sel);
    defer parsed.deinit();
    const matches = try parsed.queryAll(gpa, tree, tree.root);
    defer gpa.free(matches);
    if (matches.len == 0) return error.ElementNotFound;
    return matches[0];
}

/// Count of CSS matches and of those not hidden (diagnostics `match_count`
/// and `visible_match_count`). Hidden subtrees count toward `total`; like
/// `document.querySelectorAll(selector).length`, only the root's document
/// is searched (not iframe documents or shadow trees).
pub fn countMatches(gpa: Allocator, tree: *const Tree, selector: []const u8) FindError!struct { total: usize, visible: usize } {
    var parsed = try css.parse(gpa, selector);
    defer parsed.deinit();
    const Item = struct { idx: NodeIndex, hidden: bool };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .idx = tree.root, .hidden = tree.get(tree.root).hidden });
    var total: usize = 0;
    var visible: usize = 0;
    while (stack.pop()) |item| {
        if (parsed.matches(tree, item.idx)) {
            total += 1;
            if (!item.hidden) visible += 1;
        }
        for (tree.get(item.idx).children) |c| {
            const cn = tree.get(c);
            if (cn.kind == .document) continue;
            try stack.append(gpa, .{ .idx = c, .hidden = item.hidden or cn.hidden });
        }
    }
    return .{ .total = total, .visible = visible };
}

/// Give `idx` a ref in `table` (reusing an existing one). Returns the id.
pub fn register(gpa: Allocator, tree: *const Tree, table: *refs.RefTable, idx: NodeIndex) Allocator.Error!u32 {
    const n = tree.get(idx);
    const path = try css.cssPath(gpa, tree, idx);
    defer if (path) |p| gpa.free(p);
    return table.add(.{
        .backend_node_id = n.backend_id,
        .frame_id = n.frame_id,
        .role = n.role,
        .name = n.name,
        .css_path = path,
    });
}

/// `browser.find.*` result: {action, selector, element_ref, ref, tag, role,
/// name, text, backend_node_id?, frame_id?}. `selector` is the CSS path when
/// known, else the `@eN` token.
pub fn writeFindResult(gpa: Allocator, s: *std.json.Stringify, tree: *const Tree, table: *const refs.RefTable, idx: NodeIndex, ref_id: u32, action: []const u8) (std.Io.Writer.Error || Allocator.Error)!void {
    const n = tree.get(idx);
    var buf: [16]u8 = undefined;
    const ref = refs.formatRef(&buf, ref_id);
    var at_buf: [17]u8 = undefined;
    const at_ref = std.fmt.bufPrint(&at_buf, "@{s}", .{ref}) catch unreachable;
    const entry = table.lookupId(ref_id);
    const text = try tree.innerText(gpa, idx, 120, false);
    defer gpa.free(text);
    try s.beginObject();
    try s.objectField("action");
    try s.write(action);
    try s.objectField("selector");
    try s.write(if (entry) |e| (e.css_path orelse at_ref) else at_ref);
    try s.objectField("element_ref");
    try s.write(at_ref);
    try s.objectField("ref");
    try s.write(ref);
    try s.objectField("tag");
    try s.write(n.tag);
    try s.objectField("role");
    try s.write(n.role);
    try s.objectField("name");
    try s.write(n.name);
    try s.objectField("text");
    try s.write(text);
    if (n.backend_id) |b| {
        try s.objectField("backend_node_id");
        try s.write(b);
    }
    if (n.frame_id) |f| {
        try s.objectField("frame_id");
        try s.write(f);
    }
    try s.endObject();
}
