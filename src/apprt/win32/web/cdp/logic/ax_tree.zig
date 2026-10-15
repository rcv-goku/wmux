//! Parse CDP `Accessibility.getFullAXTree` and `DOM.getDocument` JSON into one
//! pure tree model shared by the snapshot renderer, the ref table and the
//! locators (W2-8, browser-cli-snapshot). Std-only: no Win32, no WebView2.
//!
//! Both parsers produce the same `Tree`: nodes in one arena-owned slice,
//! linked by indexes, with a computed role, accessible name, value, states and
//! (for DOM input) tag and attributes. `annotateFromDom` copies DOM tag and
//! attributes onto AX nodes by backendDOMNodeId so AX-sourced trees can serve
//! attribute locators and CSS scoping too.
//!
//! Traversals are iterative (explicit stacks) so hostile, deeply nested pages
//! cannot overflow the native stack.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeIndex = u32;

pub const Kind = enum { document, element, text, other };

/// Tri-state for `checked` and `pressed` (ARIA true/false/mixed).
pub const Tri = enum { off, on, mixed };

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const States = struct {
    focused: bool = false,
    focusable: bool = false,
    disabled: bool = false,
    required: bool = false,
    readonly: bool = false,
    selected: bool = false,
    checked: ?Tri = null,
    pressed: ?Tri = null,
    expanded: ?bool = null,
    level: ?u8 = null,
};

pub const Node = struct {
    kind: Kind = .element,
    /// Normalized role ("" when the node has no role worth reporting).
    role: []const u8 = "",
    /// Accessible name, raw (callers sanitize for output).
    name: []const u8 = "",
    value: []const u8 = "",
    description: []const u8 = "",
    /// Label text used by the `label` locator (form controls only).
    label: []const u8 = "",
    /// Character data for text nodes.
    text: []const u8 = "",
    /// Lowercase tag name for DOM elements ("" for AX-only nodes).
    tag: []const u8 = "",
    attrs: []const Attr = &.{},
    backend_id: ?i64 = null,
    frame_id: ?[]const u8 = null,
    parent: ?NodeIndex = null,
    children: []const NodeIndex = &.{},
    /// Transparent: never emitted itself, but its children are walked.
    ignored: bool = false,
    /// Not rendered: the whole subtree is skipped by walks.
    hidden: bool = false,
    /// onclick / cursor:pointer / tabindex hint (snapshot --cursor).
    clickable: bool = false,
    /// DOM shadow root (a `.document` node from `shadowRoots`): selectors
    /// and ids of the main document never reach inside it.
    shadow_root: bool = false,
    /// DOM element whose non-empty `id` occurs once in its document or
    /// shadow root, so `#id` selects exactly this element there.
    id_unique: bool = false,
    states: States = .{},

    /// Attribute lookup, ASCII case-insensitive on the name.
    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }

    pub fn hasAttr(self: *const Node, name: []const u8) bool {
        return self.attr(name) != null;
    }
};

pub const Source = enum { ax, dom };

pub const ParseError = error{ InvalidCdpJson, MissingNodes, OutOfMemory };

pub const ParseOptions = struct {
    /// Frame the nodes belong to (null = main frame).
    frame_id: ?[]const u8 = null,
    /// Page URL, kept on the tree for JSON output.
    url: []const u8 = "",
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []Node,
    root: NodeIndex,
    source: Source,
    title: []const u8 = "",
    url: []const u8 = "",

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Tree, idx: NodeIndex) *const Node {
        return &self.nodes[idx];
    }

    /// First node (document order) with this backend id; `frame_id` filters
    /// when non-null.
    pub fn findByBackendId(self: *const Tree, backend_id: i64, frame_id: ?[]const u8) ?NodeIndex {
        for (self.nodes, 0..) |n, i| {
            const id = n.backend_id orelse continue;
            if (id != backend_id) continue;
            if (frame_id) |f| {
                const nf = n.frame_id orelse continue;
                if (!std.mem.eql(u8, nf, f)) continue;
            }
            return @intCast(i);
        }
        return null;
    }

    /// Default snapshot scope: `<body>` for DOM trees, the root otherwise.
    pub fn bodyIndex(self: *const Tree) NodeIndex {
        if (self.source == .dom) {
            for (self.nodes, 0..) |n, i| {
                if (n.kind == .element and std.mem.eql(u8, n.tag, "body")) return @intCast(i);
            }
        }
        return self.root;
    }

    /// Is `idx` or any ancestor hidden?
    pub fn isHidden(self: *const Tree, idx: NodeIndex) bool {
        var cur: ?NodeIndex = idx;
        while (cur) |c| : (cur = self.nodes[c].parent) {
            if (self.nodes[c].hidden) return true;
        }
        return false;
    }

    /// Is `anc` an ancestor of (or equal to) `idx`?
    pub fn contains(self: *const Tree, anc: NodeIndex, idx: NodeIndex) bool {
        var cur: ?NodeIndex = idx;
        while (cur) |c| : (cur = self.nodes[c].parent) {
            if (c == anc) return true;
        }
        return false;
    }

    /// Visible nodes of the subtree at `scope` in document order (pre-order),
    /// including `scope` itself. Caller frees.
    pub fn preorder(self: *const Tree, gpa: Allocator, scope: NodeIndex) Allocator.Error![]NodeIndex {
        var out: std.ArrayList(NodeIndex) = .empty;
        errdefer out.deinit(gpa);
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, scope);
        while (stack.pop()) |idx| {
            const n = &self.nodes[idx];
            if (n.hidden) continue;
            try out.append(gpa, idx);
            var i = n.children.len;
            while (i > 0) {
                i -= 1;
                try stack.append(gpa, n.children[i]);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Visible text of the subtree, whitespace collapsed and trimmed, capped
    /// at `max_chars` code points (0 = unlimited). Image `alt` text counts
    /// when `include_alt` is set (accessible-name computation). Caller frees.
    pub fn innerText(self: *const Tree, gpa: Allocator, idx: NodeIndex, max_chars: usize, include_alt: bool) Allocator.Error![]u8 {
        var tc: TextCollector = .{ .max_chars = max_chars };
        errdefer tc.out.deinit(gpa);
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, idx);
        while (stack.pop()) |cur| {
            if (tc.full()) break;
            const n = &self.nodes[cur];
            if (n.hidden) continue;
            switch (n.kind) {
                .text => try tc.add(gpa, n.text),
                else => {
                    if (include_alt and std.mem.eql(u8, n.tag, "img")) {
                        if (n.attr("alt")) |alt| try tc.add(gpa, alt);
                    }
                    // Block-ish separation: a space between element children
                    // keeps "<li>a</li><li>b</li>" from reading as "ab".
                    if (cur != idx) try tc.add(gpa, " ");
                    var i = n.children.len;
                    while (i > 0) {
                        i -= 1;
                        try stack.append(gpa, n.children[i]);
                    }
                },
            }
        }
        return tc.finish(gpa);
    }

    /// Text of a subtree regardless of `hidden` (aria-labelledby targets and
    /// `<title>`, which lives in the non-rendered `<head>`), 120 chars max.
    pub fn innerTextIgnoringHidden(self: *const Tree, gpa: Allocator, idx: NodeIndex) Allocator.Error![]u8 {
        return innerTextIgnoringHiddenImpl(self, gpa, idx);
    }

    /// Copy DOM tag, attributes and clickability onto AX nodes sharing a
    /// backendDOMNodeId, and hide AX nodes whose DOM element is hidden.
    /// Strings are duplicated into this tree's arena.
    pub fn annotateFromDom(self: *Tree, dom: *const Tree) Allocator.Error!void {
        const a = self.arena.allocator();
        var map: std.AutoHashMapUnmanaged(i64, NodeIndex) = .empty;
        defer map.deinit(a);
        for (dom.nodes, 0..) |n, i| {
            if (n.kind != .element) continue;
            const id = n.backend_id orelse continue;
            const gop = try map.getOrPut(a, id);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        }
        for (self.nodes) |*n| {
            const id = n.backend_id orelse continue;
            const di = map.get(id) orelse continue;
            const d = &dom.nodes[di];
            n.tag = try a.dupe(u8, d.tag);
            const attrs = try a.alloc(Attr, d.attrs.len);
            for (d.attrs, attrs) |src, *dst| {
                dst.* = .{ .name = try a.dupe(u8, src.name), .value = try a.dupe(u8, src.value) };
            }
            n.attrs = attrs;
            if (d.clickable) n.clickable = true;
            if (dom.isHidden(di)) n.hidden = true;
            if (n.frame_id == null) {
                if (d.frame_id) |f| n.frame_id = try a.dupe(u8, f);
            }
        }
    }
};

/// Collapses whitespace runs to single spaces while appending, trims, caps.
const TextCollector = struct {
    out: std.ArrayList(u8) = .empty,
    max_chars: usize,
    chars: usize = 0,
    pending_space: bool = false,

    fn full(self: *const TextCollector) bool {
        return self.max_chars != 0 and self.chars >= self.max_chars;
    }

    fn add(self: *TextCollector, gpa: Allocator, s: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            if (self.full()) return;
            const c = s[i];
            if (isSpace(c)) {
                if (self.out.items.len > 0) self.pending_space = true;
                i += 1;
                continue;
            }
            if (self.pending_space) {
                try self.out.append(gpa, ' ');
                self.chars += 1;
                self.pending_space = false;
                if (self.full()) return;
            }
            const len = cpLen(s, i);
            try self.out.appendSlice(gpa, s[i .. i + len]);
            self.chars += 1;
            i += len;
        }
    }

    fn finish(self: *TextCollector, gpa: Allocator) Allocator.Error![]u8 {
        // A trailing space can only come from the cap landing right after one.
        while (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') {
            _ = self.out.pop();
        }
        return self.out.toOwnedSlice(gpa);
    }
};

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

/// Byte length of the code point starting at `s[i]`; malformed or truncated
/// sequences count as one byte so callers always make progress.
pub fn cpLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len) return 1;
    for (s[i + 1 .. i + n]) |b| {
        if (b & 0xC0 != 0x80) return 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Roles

/// Roles that `--interactive` keeps.
pub const interactive_roles = [_][]const u8{
    "button",   "link",      "textbox",  "checkbox",         "radio",
    "combobox", "listbox",   "menuitem", "menuitemcheckbox", "menuitemradio",
    "option",   "searchbox", "slider",   "spinbutton",       "switch",
    "tab",      "treeitem",
};

/// Content roles included in a full snapshot.
pub const content_roles = [_][]const u8{
    "heading",  "cell",    "gridcell", "columnheader", "rowheader",
    "listitem", "article", "region",   "main",         "navigation",
};

pub fn isInteractiveRole(role: []const u8) bool {
    if (std.mem.startsWith(u8, role, "menuitem")) return true;
    for (interactive_roles) |r| if (std.mem.eql(u8, r, role)) return true;
    return false;
}

pub fn isContentRole(role: []const u8) bool {
    for (content_roles) |r| if (std.mem.eql(u8, r, role)) return true;
    return false;
}

/// Roles whose name the `label` locator matches against.
pub fn isLabelableRole(role: []const u8) bool {
    const labelable = [_][]const u8{
        "textbox", "searchbox", "checkbox",   "radio",  "combobox",
        "listbox", "slider",    "spinbutton", "switch",
    };
    for (labelable) |r| if (std.mem.eql(u8, r, role)) return true;
    return false;
}

/// Roles named from their content (ARIA "name from: contents"). Containers
/// such as main, navigation or listitem are named only by their author, so
/// their whole subtree text never becomes a name.
pub fn isNameFromContentRole(role: []const u8) bool {
    const roles = [_][]const u8{
        "button",       "link",             "heading",       "cell",     "gridcell",
        "columnheader", "rowheader",        "option",        "tab",      "treeitem",
        "menuitem",     "menuitemcheckbox", "menuitemradio", "checkbox", "radio",
        "switch",       "generic",
    };
    for (roles) |r| if (std.mem.eql(u8, r, role)) return true;
    return false;
}

/// Map Chromium-internal AX role names to ARIA-style names.
pub fn normalizeAxRole(role: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "RootWebArea", "document" },
        .{ "WebArea", "document" },
        .{ "StaticText", "text" },
        .{ "MenuListOption", "option" },
        .{ "MenuListPopup", "listbox" },
        .{ "PopUpButton", "combobox" },
        .{ "ComboBoxMenuButton", "combobox" },
        .{ "ComboBoxGrouping", "combobox" },
        .{ "TextField", "textbox" },
        .{ "image", "img" },
        .{ "none", "" },
        .{ "presentation", "" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], role)) return m[1];
    return role;
}

// ---------------------------------------------------------------------------
// Accessibility.getFullAXTree

/// Accepts `{"nodes":[…]}`, the CDP response `{"id":…,"result":{"nodes":[…]}}`
/// or a bare `[…]` array of AXNode objects.
pub fn parseAxTree(gpa: Allocator, json: []const u8, opts: ParseOptions) ParseError!Tree {
    // Every allocation goes through `tree.arena`: copying an arena by value
    // and then allocating through the old copy loses track of the memory.
    var tree: Tree = .{ .arena = .init(gpa), .nodes = &.{}, .root = 0, .source = .ax };
    errdefer tree.arena.deinit();
    const a = tree.arena.allocator();

    const doc = try parseJson(gpa, a, json);
    const list = axNodeList(doc) orelse return error.MissingNodes;
    if (list.len == 0) return error.MissingNodes;

    const count = list.len;
    const nodes = try a.alloc(Node, count);
    for (nodes) |*n| n.* = .{};
    const frame = if (opts.frame_id) |f| try a.dupe(u8, f) else null;

    // nodeId -> index (first occurrence wins on duplicates).
    var ids: std.StringHashMapUnmanaged(NodeIndex) = .empty;
    for (list, 0..) |item, i| {
        if (item != .object) return error.InvalidCdpJson;
        const id = idString(a, item.object.get("nodeId")) orelse continue;
        const gop = try ids.getOrPut(a, id);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }

    // Link: a child is claimed by the first parent listing it; no self-links.
    const parent_of = try a.alloc(?NodeIndex, count);
    @memset(parent_of, null);
    for (list, 0..) |item, pi| {
        const kids = arrayField(item.object, "childIds") orelse continue;
        for (kids) |k| {
            const kid = idString(a, k) orelse continue;
            const ci = ids.get(kid) orelse continue;
            if (ci == pi or parent_of[ci] != null) continue;
            parent_of[ci] = @intCast(pi);
        }
    }
    // Root: the RootWebArea, else the first unclaimed node, else node 0. Its
    // parent link is cleared, which breaks any cycle running through it.
    var root: NodeIndex = 0;
    root: {
        for (list, 0..) |item, i| {
            const r = axValueString(a, item.object.get("role")) orelse continue;
            if (std.mem.eql(u8, r, "RootWebArea")) {
                root = @intCast(i);
                break :root;
            }
        }
        for (parent_of, 0..) |p, i| {
            if (p == null) {
                root = @intCast(i);
                break :root;
            }
        }
    }
    parent_of[root] = null;
    // Children in childIds order, each at most once.
    const added = try a.alloc(bool, count);
    @memset(added, false);
    for (list, 0..) |item, pi| {
        const kids = arrayField(item.object, "childIds") orelse continue;
        var out: std.ArrayList(NodeIndex) = .empty;
        for (kids) |k| {
            const kid = idString(a, k) orelse continue;
            const ci = ids.get(kid) orelse continue;
            if (parent_of[ci] != @as(?NodeIndex, @intCast(pi)) or added[ci]) continue;
            added[ci] = true;
            try out.append(a, ci);
        }
        nodes[pi].children = try out.toOwnedSlice(a);
    }

    var title: []const u8 = "";
    for (list, nodes, 0..) |item, *n, i| {
        const o = item.object;
        n.parent = parent_of[i];
        n.frame_id = frame;
        n.backend_id = intField(o, "backendDOMNodeId");
        n.ignored = boolField(o, "ignored") orelse false;
        const raw_role = axValueString(a, o.get("role")) orelse "";
        n.role = normalizeAxRole(raw_role);
        n.name = axValueString(a, o.get("name")) orelse "";
        n.value = axValueString(a, o.get("value")) orelse "";
        n.description = axValueString(a, o.get("description")) orelse "";
        if (std.mem.eql(u8, raw_role, "InlineTextBox")) {
            // Line-box fragments duplicate their StaticText parent.
            n.hidden = true;
            n.kind = .other;
        } else if (std.mem.eql(u8, n.role, "text")) {
            n.kind = .text;
            n.text = n.name;
        } else if (std.mem.eql(u8, n.role, "document")) {
            n.kind = .document;
            if (i == root or title.len == 0) title = n.name;
        }
        if (arrayField(o, "properties")) |props| applyAxProperties(n, props);
        if (isLabelableRole(n.role)) n.label = n.name;
        // A focusable generic is the AX-side equivalent of a tabindex/onclick
        // element for --cursor.
        if (n.states.focusable and !isInteractiveRole(n.role) and n.kind == .element) n.clickable = true;
    }
    if (nodes[root].kind == .document) title = nodes[root].name;

    tree.nodes = nodes;
    tree.root = root;
    tree.title = title;
    tree.url = try a.dupe(u8, opts.url);
    return tree;
}

/// Values live in the tree arena; the scanner's nesting stack uses `gpa`
/// (an arena-backed scanner degrades badly on deeply nested input).
fn parseJson(gpa: Allocator, a: Allocator, json: []const u8) ParseError!std.json.Value {
    var scanner = std.json.Scanner.initCompleteInput(gpa, json);
    defer scanner.deinit();
    return std.json.parseFromTokenSourceLeaky(std.json.Value, a, &scanner, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCdpJson,
    };
}

fn axNodeList(doc: std.json.Value) ?[]const std.json.Value {
    switch (doc) {
        .array => |arr| return arr.items,
        .object => |o| {
            if (arrayField(o, "nodes")) |n| return n;
            if (o.get("result")) |r| if (r == .object) {
                if (arrayField(r.object, "nodes")) |n| return n;
            };
            return null;
        },
        else => return null,
    }
}

fn applyAxProperties(n: *Node, props: []const std.json.Value) void {
    for (props) |p| {
        if (p != .object) continue;
        const pname = switch (p.object.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const v = p.object.get("value") orelse continue;
        const inner: std.json.Value = if (v == .object) (v.object.get("value") orelse .null) else v;
        if (std.mem.eql(u8, pname, "focused")) {
            n.states.focused = truthy(inner);
        } else if (std.mem.eql(u8, pname, "focusable")) {
            n.states.focusable = truthy(inner);
        } else if (std.mem.eql(u8, pname, "disabled")) {
            n.states.disabled = truthy(inner);
        } else if (std.mem.eql(u8, pname, "required")) {
            n.states.required = truthy(inner);
        } else if (std.mem.eql(u8, pname, "readonly")) {
            n.states.readonly = truthy(inner);
        } else if (std.mem.eql(u8, pname, "selected")) {
            n.states.selected = truthy(inner);
        } else if (std.mem.eql(u8, pname, "checked")) {
            n.states.checked = tri(inner);
        } else if (std.mem.eql(u8, pname, "pressed")) {
            n.states.pressed = tri(inner);
        } else if (std.mem.eql(u8, pname, "expanded")) {
            n.states.expanded = truthy(inner);
        } else if (std.mem.eql(u8, pname, "level")) {
            n.states.level = levelOf(inner);
        } else if (std.mem.eql(u8, pname, "hidden")) {
            if (truthy(inner)) n.hidden = true;
        }
    }
}

fn truthy(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        .integer => |i| i != 0,
        else => false,
    };
}

fn tri(v: std.json.Value) ?Tri {
    return switch (v) {
        .bool => |b| if (b) .on else .off,
        .string => |s| if (std.mem.eql(u8, s, "true")) .on else if (std.mem.eql(u8, s, "mixed")) .mixed else if (std.mem.eql(u8, s, "false")) .off else null,
        else => null,
    };
}

fn levelOf(v: std.json.Value) ?u8 {
    const i: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| if (f >= 0 and f <= 255) @intFromFloat(f) else return null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return null,
        else => return null,
    };
    if (i < 1 or i > 255) return null;
    return @intCast(i);
}

/// CDP AXValue `{type, value}` (or a bare scalar) as a string.
fn axValueString(a: Allocator, v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    const inner: std.json.Value = if (val == .object) (val.object.get("value") orelse return null) else val;
    return scalarString(a, inner);
}

fn scalarString(a: Allocator, v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}) catch null,
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}) catch null,
        .bool => |b| if (b) "true" else "false",
        else => null,
    };
}

fn idString(a: Allocator, v: ?std.json.Value) ?[]const u8 {
    return scalarString(a, v orelse return null);
}

fn arrayField(o: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const v = o.get(key) orelse return null;
    return if (v == .array) v.array.items else null;
}

fn intField(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.0e15) @intFromFloat(f) else null,
        else => null,
    };
}

fn boolField(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ---------------------------------------------------------------------------
// DOM.getDocument

/// Accepts `{"root":{…}}`, the CDP response `{"result":{"root":{…}}}` or a
/// bare DOM Node object. Use `depth:-1, pierce:true` so iframes
/// (`contentDocument`) and shadow roots are included.
///
/// Visibility is approximated from markup (no layout in this JSON): `hidden`,
/// `aria-hidden="true"`, inline `display:none`/`visibility:hidden`/
/// `opacity<=0.01`, `input[type=hidden]`, closed `<details>` bodies and
/// non-rendered tags are hidden.
pub fn parseDomDocument(gpa: Allocator, json: []const u8, opts: ParseOptions) ParseError!Tree {
    // All allocations go through `tree.arena` (see parseAxTree).
    var tree: Tree = .{ .arena = .init(gpa), .nodes = &.{}, .root = 0, .source = .dom };
    errdefer tree.arena.deinit();
    const a = tree.arena.allocator();

    const doc = try parseJson(gpa, a, json);
    const root_json = domRoot(doc) orelse return error.MissingNodes;

    var nodes: std.ArrayList(Node) = .empty;
    const Item = struct { json: std.json.ObjectMap, idx: NodeIndex, frame: ?[]const u8 };
    var queue: std.ArrayList(Item) = .empty;
    try nodes.append(a, .{ .frame_id = opts.frame_id });
    try queue.append(a, .{ .json = root_json, .idx = 0, .frame = if (opts.frame_id) |f| try a.dupe(u8, f) else null });

    // Breadth-first: when a node is processed its children get consecutive
    // placeholder slots, so the children slice is known up front.
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const item = queue.items[qi];
        const o = item.json;
        var n = &nodes.items[item.idx];
        n.frame_id = item.frame;
        n.backend_id = intField(o, "backendNodeId");
        const node_type = intField(o, "nodeType") orelse 1;
        switch (node_type) {
            1 => {
                n.kind = .element;
                const name = stringField(o, "localName") orelse stringField(o, "nodeName") orelse "";
                n.tag = try std.ascii.allocLowerString(a, name);
                n.attrs = try parseAttrs(a, o);
            },
            3, 4 => {
                n.kind = .text;
                n.text = stringField(o, "nodeValue") orelse "";
            },
            9, 11 => {
                n.kind = .document;
                // pierce:true reports shadow roots as DocumentFragments.
                n.shadow_root = node_type == 11;
            },
            else => {
                n.kind = .other;
                n.hidden = true;
            },
        }

        // Child order: shadow roots, light children, then an iframe's document.
        var kids: std.ArrayList(Item) = .empty;
        const child_frame = if (stringField(o, "frameId")) |f| (if (node_type == 1) f else item.frame) else item.frame;
        if (arrayField(o, "shadowRoots")) |srs| for (srs) |c| if (c == .object) try kids.append(a, .{ .json = c.object, .idx = 0, .frame = item.frame });
        if (arrayField(o, "children")) |cs| for (cs) |c| if (c == .object) try kids.append(a, .{ .json = c.object, .idx = 0, .frame = item.frame });
        if (o.get("contentDocument")) |cd| if (cd == .object) try kids.append(a, .{ .json = cd.object, .idx = 0, .frame = child_frame });

        const first: NodeIndex = @intCast(nodes.items.len);
        const child_idx = try a.alloc(NodeIndex, kids.items.len);
        for (kids.items, 0..) |*k, i| {
            k.idx = first + @as(NodeIndex, @intCast(i));
            child_idx[i] = k.idx;
            try nodes.append(a, .{ .parent = item.idx });
        }
        // `append` may have moved the buffer.
        n = &nodes.items[item.idx];
        n.children = child_idx;
        try queue.appendSlice(a, kids.items);
    }

    tree.nodes = nodes.items;
    tree.url = try a.dupe(u8, opts.url);
    try finishDom(gpa, &tree);
    if (tree.url.len == 0) {
        if (stringField(root_json, "documentURL")) |u| tree.url = u;
    }
    return tree;
}

fn domRoot(doc: std.json.Value) ?std.json.ObjectMap {
    if (doc != .object) return null;
    const o = doc.object;
    if (o.get("root")) |r| if (r == .object) return r.object;
    if (o.get("result")) |res| if (res == .object) {
        if (res.object.get("root")) |r| if (r == .object) return r.object;
    };
    if (o.get("nodeType") != null or o.get("nodeName") != null) return o;
    return null;
}

/// CDP flattens attributes as `[name, value, name, value, …]`.
fn parseAttrs(a: Allocator, o: std.json.ObjectMap) Allocator.Error![]const Attr {
    const flat = arrayField(o, "attributes") orelse return &.{};
    var out: std.ArrayList(Attr) = .empty;
    var i: usize = 0;
    while (i + 1 < flat.len) : (i += 2) {
        const k = if (flat[i] == .string) flat[i].string else continue;
        const v = if (flat[i + 1] == .string) flat[i + 1].string else "";
        try out.append(a, .{ .name = k, .value = v });
    }
    return out.toOwnedSlice(a);
}

const non_rendered_tags = [_][]const u8{
    "head", "script", "style", "noscript", "template", "meta", "link", "title", "base",
};

/// Element ids per document or shadow root: `getElementById`, `<label for>`
/// and `aria-labelledby` never resolve across an iframe or shadow boundary.
const IdIndex = struct {
    /// The document or shadow root each node belongs to.
    scope_of: []NodeIndex,
    map: std.HashMapUnmanaged(Key, Slot, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

    const Key = struct { scope: NodeIndex, id: []const u8 };
    const Slot = struct { first: NodeIndex, count: u32 };
    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            return std.hash.Wyhash.hash(k.scope, k.id);
        }
        pub fn eql(_: KeyContext, x: Key, y: Key) bool {
            return x.scope == y.scope and std.mem.eql(u8, x.id, y.id);
        }
    };

    /// `nodes` must be breadth-first (every parent before its children),
    /// as parseDomDocument builds them.
    fn init(gpa: Allocator, nodes: []const Node) Allocator.Error!IdIndex {
        const scope_of = try gpa.alloc(NodeIndex, nodes.len);
        for (nodes, 0..) |n, i| {
            const idx: NodeIndex = @intCast(i);
            scope_of[i] = if (n.kind == .document) idx else if (n.parent) |p| scope_of[p] else idx;
        }
        return .{ .scope_of = scope_of };
    }

    fn deinit(self: *IdIndex, gpa: Allocator) void {
        self.map.deinit(gpa);
        gpa.free(self.scope_of);
    }

    fn add(self: *IdIndex, gpa: Allocator, idx: NodeIndex, id: []const u8) Allocator.Error!void {
        const gop = try self.map.getOrPut(gpa, .{ .scope = self.scope_of[idx], .id = id });
        if (gop.found_existing) {
            gop.value_ptr.count +|= 1;
        } else {
            gop.value_ptr.* = .{ .first = idx, .count = 1 };
        }
    }

    /// First element (document order) with `id` in the scope of `from`.
    fn get(self: *const IdIndex, from: NodeIndex, id: []const u8) ?NodeIndex {
        const slot = self.map.get(.{ .scope = self.scope_of[from], .id = id }) orelse return null;
        return slot.first;
    }

    fn count(self: *const IdIndex, from: NodeIndex, id: []const u8) u32 {
        const slot = self.map.get(.{ .scope = self.scope_of[from], .id = id }) orelse return 0;
        return slot.count;
    }
};

/// `gpa` holds scratch data that does not outlive the call.
fn finishDom(gpa: Allocator, tree: *Tree) Allocator.Error!void {
    const a = tree.arena.allocator();
    const nodes = tree.nodes;

    // Pass 1: visibility, clickability, title, id index.
    var ids: IdIndex = try .init(gpa, nodes);
    defer ids.deinit(gpa);
    for (nodes, 0..) |*n, i| {
        if (n.kind != .element) continue;
        for (non_rendered_tags) |t| {
            if (std.mem.eql(u8, n.tag, t)) n.hidden = true;
        }
        if (std.mem.eql(u8, n.tag, "title") and tree.title.len == 0) {
            tree.title = try tree.innerTextIgnoringHidden(a, @intCast(i));
        }
        if (n.hasAttr("hidden")) n.hidden = true;
        if (eqlAttr(n, "aria-hidden", "true")) n.hidden = true;
        if (std.mem.eql(u8, n.tag, "input") and eqlAttr(n, "type", "hidden")) n.hidden = true;
        if (n.attr("style")) |style| {
            const st = parseStyle(style);
            if (st.hidden) n.hidden = true;
            if (st.pointer) n.clickable = true;
        }
        if (n.hasAttr("onclick") or n.hasAttr("tabindex")) n.clickable = true;
        if (std.mem.eql(u8, n.tag, "details") and !n.hasAttr("open")) {
            var seen_summary = false;
            for (n.children) |c| {
                const cn = &nodes[c];
                if (!seen_summary and cn.kind == .element and std.mem.eql(u8, cn.tag, "summary")) {
                    seen_summary = true;
                    continue;
                }
                cn.hidden = true;
            }
        }
        if (n.attr("id")) |id| if (id.len > 0) try ids.add(gpa, @intCast(i), id);
    }

    // Pass 2: id uniqueness (CSS paths); <label for=…> and wrapping labels
    // -> control label text.
    const label_of = try gpa.alloc(?NodeIndex, nodes.len);
    defer gpa.free(label_of);
    @memset(label_of, null);
    var scratch: std.ArrayList(NodeIndex) = .empty;
    defer scratch.deinit(gpa);
    for (nodes, 0..) |*n, i| {
        if (n.kind != .element) continue;
        const ni: NodeIndex = @intCast(i);
        if (n.attr("id")) |id| n.id_unique = id.len > 0 and ids.count(ni, id) == 1;
        if (!std.mem.eql(u8, n.tag, "label")) continue;
        const control = if (n.attr("for")) |f| ids.get(ni, f) else try firstLabelable(tree, gpa, &scratch, ni);
        if (control) |ci| {
            if (label_of[ci] == null) label_of[ci] = ni;
        }
    }

    // Pass 3: roles, states, values, names.
    for (nodes, 0..) |*n, i| {
        if (n.kind != .element) continue;
        n.role = domRole(n);
        domStates(n);
        if (std.mem.eql(u8, n.tag, "summary") and n.states.expanded == null) {
            if (n.parent) |p| if (std.mem.eql(u8, nodes[p].tag, "details")) {
                n.states.expanded = nodes[p].hasAttr("open");
            };
        }
        if (n.role.len == 0 and !n.clickable) continue;
        const idx: NodeIndex = @intCast(i);
        n.value = try domValue(tree, idx);
        const label_text: []const u8 = if (label_of[i]) |li| try labelText(tree, li, idx) else "";
        n.name = try domName(tree, idx, &ids, label_text);
        if (isLabelableRole(n.role)) {
            n.label = if (n.attr("aria-label")) |al| al else if (label_text.len > 0) label_text else try labelledBy(tree, idx, &ids);
        }
    }
}

/// Label text without the text of the control it labels (wrapping labels).
fn labelText(tree: *Tree, label: NodeIndex, control: NodeIndex) Allocator.Error![]const u8 {
    const a = tree.arena.allocator();
    if (!tree.contains(label, control)) return tree.innerText(a, label, name_cap, true);
    const saved = tree.nodes[control].hidden;
    tree.nodes[control].hidden = true;
    defer tree.nodes[control].hidden = saved;
    return tree.innerText(a, label, name_cap, true);
}

const name_cap = 120;

fn eqlAttr(n: *const Node, name: []const u8, value: []const u8) bool {
    const v = n.attr(name) orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t\r\n"), value);
}

fn isLabelableTag(n: *const Node) bool {
    if (n.kind != .element) return false;
    const tags = [_][]const u8{ "input", "textarea", "select", "button", "meter", "output", "progress" };
    for (tags) |t| if (std.mem.eql(u8, n.tag, t)) return true;
    return false;
}

/// The control of a `<label>` without `for`: its first labelable descendant
/// in tree order, skipping hidden subtrees and nested documents. The label
/// itself may be hidden (`<label hidden>`, a closed `<details>` body).
/// `stack` is reusable scratch space; nothing is kept in the tree arena.
fn firstLabelable(tree: *const Tree, gpa: Allocator, stack: *std.ArrayList(NodeIndex), label: NodeIndex) Allocator.Error!?NodeIndex {
    stack.clearRetainingCapacity();
    try pushChildren(gpa, stack, tree.nodes[label].children);
    while (stack.pop()) |d| {
        const n = &tree.nodes[d];
        if (n.hidden or n.kind == .document) continue;
        if (isLabelableTag(n)) return d;
        try pushChildren(gpa, stack, n.children);
    }
    return null;
}

/// Push `kids` in reverse so they pop in document order.
fn pushChildren(gpa: Allocator, stack: *std.ArrayList(NodeIndex), kids: []const NodeIndex) Allocator.Error!void {
    var i = kids.len;
    while (i > 0) {
        i -= 1;
        try stack.append(gpa, kids[i]);
    }
}

const StyleFlags = struct { hidden: bool = false, pointer: bool = false };

/// Inline `style` attribute: only the declarations that affect visibility or
/// the --cursor heuristic.
pub fn parseStyle(style: []const u8) StyleFlags {
    var flags: StyleFlags = .{};
    var decls = std.mem.splitScalar(u8, style, ';');
    while (decls.next()) |decl| {
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const prop = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        var val = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        if (std.ascii.endsWithIgnoreCase(val, "!important")) val = std.mem.trim(u8, val[0 .. val.len - "!important".len], " \t");
        if (std.ascii.eqlIgnoreCase(prop, "display")) {
            if (std.ascii.eqlIgnoreCase(val, "none")) flags.hidden = true;
        } else if (std.ascii.eqlIgnoreCase(prop, "visibility")) {
            if (std.ascii.eqlIgnoreCase(val, "hidden") or std.ascii.eqlIgnoreCase(val, "collapse")) flags.hidden = true;
        } else if (std.ascii.eqlIgnoreCase(prop, "opacity")) {
            const op = parseOpacity(val) orelse continue;
            if (op <= 0.01) flags.hidden = true;
        } else if (std.ascii.eqlIgnoreCase(prop, "cursor")) {
            if (std.ascii.eqlIgnoreCase(val, "pointer")) flags.pointer = true;
        }
    }
    return flags;
}

fn parseOpacity(val: []const u8) ?f64 {
    if (val.len > 0 and val[val.len - 1] == '%') {
        const p = std.fmt.parseFloat(f64, val[0 .. val.len - 1]) catch return null;
        return p / 100.0;
    }
    return std.fmt.parseFloat(f64, val) catch null;
}

/// Explicit `role` (first token) or the implicit role of the tag.
pub fn domRole(n: *const Node) []const u8 {
    if (n.attr("role")) |r| {
        var it = std.mem.tokenizeAny(u8, r, " \t\r\n");
        if (it.next()) |tok| {
            if (std.ascii.eqlIgnoreCase(tok, "none") or std.ascii.eqlIgnoreCase(tok, "presentation")) return "";
            return lowerRole(tok);
        }
    }
    const t = n.tag;
    if (std.mem.eql(u8, t, "button")) return "button";
    if (std.mem.eql(u8, t, "a") or std.mem.eql(u8, t, "area")) return if (n.hasAttr("href")) "link" else "";
    if (std.mem.eql(u8, t, "input")) {
        const ty = n.attr("type") orelse "text";
        const types = [_]struct { []const u8, []const u8 }{
            .{ "checkbox", "checkbox" }, .{ "radio", "radio" },       .{ "button", "button" },
            .{ "submit", "button" },     .{ "reset", "button" },      .{ "image", "button" },
            .{ "range", "slider" },      .{ "number", "spinbutton" }, .{ "search", "searchbox" },
            .{ "hidden", "" },           .{ "file", "button" },       .{ "color", "" },
        };
        for (types) |m| if (std.ascii.eqlIgnoreCase(ty, m[0])) return m[1];
        return "textbox";
    }
    if (std.mem.eql(u8, t, "textarea")) return "textbox";
    if (std.mem.eql(u8, t, "select")) return "combobox";
    if (std.mem.eql(u8, t, "summary")) return "button";
    if (t.len == 2 and t[0] == 'h' and t[1] >= '1' and t[1] <= '6') return "heading";
    if (std.mem.eql(u8, t, "li")) return "listitem";
    if (std.mem.eql(u8, t, "option")) return "option";
    if (std.mem.eql(u8, t, "main")) return "main";
    if (std.mem.eql(u8, t, "nav")) return "navigation";
    if (std.mem.eql(u8, t, "article")) return "article";
    if (std.mem.eql(u8, t, "section")) return if (n.hasAttr("aria-label") or n.hasAttr("aria-labelledby")) "region" else "";
    if (std.mem.eql(u8, t, "td")) return "cell";
    if (std.mem.eql(u8, t, "th")) return if (eqlAttr(n, "scope", "row")) "rowheader" else "columnheader";
    if (std.mem.eql(u8, t, "img")) return if (eqlAttr(n, "alt", "")) "" else "img";
    return "";
}

/// Interned lowercase copy of known roles; unknown roles keep their spelling.
fn lowerRole(tok: []const u8) []const u8 {
    for (interactive_roles ++ content_roles ++ [_][]const u8{ "generic", "img", "dialog", "list", "table", "row", "grid", "tree", "menu", "menubar", "tablist", "tabpanel", "form", "banner", "contentinfo", "complementary", "search", "group", "toolbar" }) |r| {
        if (std.ascii.eqlIgnoreCase(r, tok)) return r;
    }
    return tok;
}

fn ariaTri(n: *const Node, name: []const u8) ?Tri {
    const v = n.attr(name) orelse return null;
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "true")) return .on;
    if (std.ascii.eqlIgnoreCase(t, "false")) return .off;
    if (std.ascii.eqlIgnoreCase(t, "mixed")) return .mixed;
    return null;
}

fn domStates(n: *Node) void {
    const s = &n.states;
    s.disabled = n.hasAttr("disabled") or eqlAttr(n, "aria-disabled", "true");
    s.required = n.hasAttr("required") or eqlAttr(n, "aria-required", "true");
    s.readonly = n.hasAttr("readonly") or eqlAttr(n, "aria-readonly", "true");
    s.selected = eqlAttr(n, "aria-selected", "true") or (std.mem.eql(u8, n.tag, "option") and n.hasAttr("selected"));
    s.pressed = ariaTri(n, "aria-pressed");
    s.checked = ariaTri(n, "aria-checked");
    if (s.checked == null and std.mem.eql(u8, n.tag, "input") and
        (std.mem.eql(u8, n.role, "checkbox") or std.mem.eql(u8, n.role, "radio") or std.mem.eql(u8, n.role, "switch")))
    {
        s.checked = if (n.hasAttr("checked")) .on else .off;
    }
    if (ariaTri(n, "aria-expanded")) |e| s.expanded = e == .on;
    s.focusable = n.hasAttr("tabindex") or isInteractiveRole(n.role);
    if (std.mem.eql(u8, n.role, "heading")) {
        if (n.attr("aria-level")) |l| {
            s.level = std.fmt.parseInt(u8, std.mem.trim(u8, l, " "), 10) catch null;
        } else if (n.tag.len == 2 and n.tag[0] == 'h' and n.tag[1] >= '1' and n.tag[1] <= '6') {
            s.level = n.tag[1] - '0';
        }
    }
}

fn domValue(tree: *Tree, idx: NodeIndex) Allocator.Error![]const u8 {
    const a = tree.arena.allocator();
    const n = &tree.nodes[idx];
    if (std.mem.eql(u8, n.tag, "textarea")) return tree.innerText(a, idx, 0, false);
    if (std.mem.eql(u8, n.tag, "select")) {
        const order = try tree.preorder(a, idx);
        var first: ?NodeIndex = null;
        for (order) |d| {
            const dn = &tree.nodes[d];
            if (dn.kind != .element or !std.mem.eql(u8, dn.tag, "option")) continue;
            if (first == null) first = d;
            if (dn.hasAttr("selected")) return tree.innerText(a, d, 0, false);
        }
        return if (first) |f| tree.innerText(a, f, 0, false) else "";
    }
    if (std.mem.eql(u8, n.tag, "input")) {
        const r = n.role;
        if (std.mem.eql(u8, r, "textbox") or std.mem.eql(u8, r, "searchbox") or
            std.mem.eql(u8, r, "spinbutton") or std.mem.eql(u8, r, "slider") or std.mem.eql(u8, r, "combobox"))
        {
            return n.attr("value") orelse "";
        }
    }
    if (n.attr("aria-valuetext")) |v| return v;
    if (n.attr("aria-valuenow")) |v| return v;
    return "";
}

fn labelledBy(tree: *Tree, idx: NodeIndex, ids: *const IdIndex) Allocator.Error![]const u8 {
    const a = tree.arena.allocator();
    const refs = tree.nodes[idx].attr("aria-labelledby") orelse return "";
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, refs, " \t\r\n");
    while (it.next()) |id| {
        const target = ids.get(idx, id) orelse continue;
        // Referenced labels count even when hidden (ARIA), so read raw text.
        const t = try tree.innerTextIgnoringHidden(a, target);
        if (t.len == 0) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, t);
    }
    return out.toOwnedSlice(a);
}

/// Name order: aria-label, aria-labelledby, associated <label>, placeholder
/// (button-type inputs: value), alt (images), title, inner text (120 chars).
fn domName(tree: *Tree, idx: NodeIndex, ids: *const IdIndex, label_text: []const u8) Allocator.Error![]const u8 {
    const a = tree.arena.allocator();
    const n = &tree.nodes[idx];
    if (nonEmpty(n.attr("aria-label"))) |v| return v;
    const lb = try labelledBy(tree, idx, ids);
    if (lb.len > 0) return lb;
    if (label_text.len > 0) return label_text;
    const is_input = std.mem.eql(u8, n.tag, "input");
    if (is_input) {
        const ty = n.attr("type") orelse "text";
        if (std.ascii.eqlIgnoreCase(ty, "submit") or std.ascii.eqlIgnoreCase(ty, "reset") or std.ascii.eqlIgnoreCase(ty, "button")) {
            if (n.attr("value")) |v| return v;
            if (std.ascii.eqlIgnoreCase(ty, "submit")) return "Submit";
            if (std.ascii.eqlIgnoreCase(ty, "reset")) return "Reset";
        }
        if (std.ascii.eqlIgnoreCase(ty, "image")) if (nonEmpty(n.attr("alt"))) |v| return v;
    }
    if (nonEmpty(n.attr("placeholder"))) |v| return v;
    if (nonEmpty(n.attr("aria-placeholder"))) |v| return v;
    if (std.mem.eql(u8, n.tag, "img")) if (nonEmpty(n.attr("alt"))) |v| return v;
    if (nonEmpty(n.attr("title"))) |v| return v;
    if (is_input or std.mem.eql(u8, n.tag, "textarea") or std.mem.eql(u8, n.tag, "select")) return "";
    if (n.role.len > 0 and !isNameFromContentRole(n.role)) return "";
    return tree.innerText(a, idx, name_cap, true);
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (std.mem.trim(u8, s, " \t\r\n").len == 0) null else s;
}

fn innerTextIgnoringHiddenImpl(tree: *const Tree, gpa: Allocator, idx: NodeIndex) Allocator.Error![]u8 {
    var tc: TextCollector = .{ .max_chars = name_cap };
    errdefer tc.out.deinit(gpa);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, idx);
    while (stack.pop()) |cur| {
        if (tc.full()) break;
        const n = &tree.nodes[cur];
        if (n.kind == .text) {
            try tc.add(gpa, n.text);
            continue;
        }
        var i = n.children.len;
        while (i > 0) {
            i -= 1;
            try stack.append(gpa, n.children[i]);
        }
    }
    return tc.finish(gpa);
}
