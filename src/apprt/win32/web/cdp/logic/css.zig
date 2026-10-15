//! Native CSS selector subset over `ax_tree.Tree` (snapshot `--selector`
//! scoping, `find first|last|nth`, element-not-found diagnostics).
//!
//! Supported: `*`, type, `#id`, `.class`, `[attr]`, `[attr=v]`, `^=`, `$=`,
//! `*=`, `~=`, `|=` (quoted or bare values, trailing ` i` flag), the
//! descendant (space) and child (`>`) combinators and `,` lists. Anything else
//! (pseudo-classes, `+`, `~`, namespaces) returns `error.UnsupportedSelector`
//! so the caller can fall back to `document.querySelectorAll` in the page.
//! Matching stays within one document: it never crosses a shadow root or an
//! iframe boundary, like the browser's own engine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ax = @import("ax_tree.zig");
const Tree = ax.Tree;
const NodeIndex = ax.NodeIndex;

pub const ParseError = error{ InvalidSelector, UnsupportedSelector, OutOfMemory };

pub const AttrOp = enum { exists, eq, prefix, suffix, contains, word, dash };

pub const AttrSel = struct {
    name: []const u8,
    op: AttrOp = .exists,
    value: []const u8 = "",
    case_insensitive: bool = false,
};

pub const Compound = struct {
    /// Lowercase tag, or null for `*`/omitted.
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    attrs: []const AttrSel = &.{},
};

pub const Combinator = enum { descendant, child };

/// `compounds[i]` is joined to `compounds[i+1]` by `combinators[i]`.
pub const Complex = struct {
    compounds: []const Compound,
    combinators: []const Combinator,
};

pub const Selector = struct {
    arena: std.heap.ArenaAllocator,
    alternatives: []const Complex,

    pub fn deinit(self: *Selector) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn matches(self: *const Selector, tree: *const Tree, idx: NodeIndex) bool {
        const n = tree.get(idx);
        if (n.kind != .element or n.tag.len == 0) return false;
        for (self.alternatives) |alt| {
            if (matchComplex(tree, idx, alt, alt.compounds.len - 1)) return true;
        }
        return false;
    }

    /// Matching visible elements under `scope` (excluding `scope` itself, like
    /// `querySelectorAll`) in document order. Caller frees.
    pub fn queryAll(self: *const Selector, gpa: Allocator, tree: *const Tree, scope: NodeIndex) Allocator.Error![]NodeIndex {
        const order = try tree.preorder(gpa, scope);
        defer gpa.free(order);
        var out: std.ArrayList(NodeIndex) = .empty;
        errdefer out.deinit(gpa);
        for (order) |idx| {
            if (idx == scope) continue;
            if (self.matches(tree, idx)) try out.append(gpa, idx);
        }
        return out.toOwnedSlice(gpa);
    }
};

pub fn parse(gpa: Allocator, text: []const u8) ParseError!Selector {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p: Parser = .{ .a = arena.allocator(), .s = text };
    const alts = try p.selectorList();
    return .{ .arena = arena, .alternatives = alts };
}

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn skipWs(self: *Parser) bool {
        const start = self.i;
        while (self.peek()) |c| {
            if (!ax.isSpace(c)) break;
            self.i += 1;
        }
        return self.i != start;
    }

    fn selectorList(self: *Parser) ParseError![]const Complex {
        var alts: std.ArrayList(Complex) = .empty;
        while (true) {
            _ = self.skipWs();
            try alts.append(self.a, try self.complex());
            _ = self.skipWs();
            const c = self.peek() orelse break;
            if (c != ',') return error.InvalidSelector;
            self.i += 1;
        }
        return alts.toOwnedSlice(self.a);
    }

    fn complex(self: *Parser) ParseError!Complex {
        var compounds: std.ArrayList(Compound) = .empty;
        var combs: std.ArrayList(Combinator) = .empty;
        try compounds.append(self.a, try self.compound());
        while (true) {
            const had_ws = self.skipWs();
            const c = self.peek() orelse break;
            if (c == ',') break;
            var comb: Combinator = .descendant;
            if (c == '>') {
                comb = .child;
                self.i += 1;
                _ = self.skipWs();
            } else if (c == '+' or c == '~') {
                return error.UnsupportedSelector;
            } else if (!had_ws) {
                return error.InvalidSelector;
            }
            try combs.append(self.a, comb);
            try compounds.append(self.a, try self.compound());
        }
        return .{ .compounds = try compounds.toOwnedSlice(self.a), .combinators = try combs.toOwnedSlice(self.a) };
    }

    fn compound(self: *Parser) ParseError!Compound {
        var out: Compound = .{};
        var classes: std.ArrayList([]const u8) = .empty;
        var attrs: std.ArrayList(AttrSel) = .empty;
        var any = false;
        if (self.peek()) |c| {
            if (c == '*') {
                self.i += 1;
                any = true;
                if (self.peek() == '|') return error.UnsupportedSelector;
            } else if (isIdentStart(c)) {
                out.tag = try std.ascii.allocLowerString(self.a, try self.ident());
                any = true;
                if (self.peek() == '|') return error.UnsupportedSelector;
            }
        }
        while (self.peek()) |c| {
            switch (c) {
                '#' => {
                    self.i += 1;
                    if (out.id != null) {
                        // `#a#b` never matches one element; keep it parseable.
                        const second = try self.ident();
                        if (!std.mem.eql(u8, second, out.id.?)) out.id = "\x00";
                    } else out.id = try self.ident();
                },
                '.' => {
                    self.i += 1;
                    try classes.append(self.a, try self.ident());
                },
                '[' => {
                    self.i += 1;
                    try attrs.append(self.a, try self.attribute());
                },
                ':' => return error.UnsupportedSelector,
                else => break,
            }
            any = true;
        }
        if (!any) return error.InvalidSelector;
        out.classes = try classes.toOwnedSlice(self.a);
        out.attrs = try attrs.toOwnedSlice(self.a);
        return out;
    }

    fn attribute(self: *Parser) ParseError!AttrSel {
        _ = self.skipWs();
        var sel: AttrSel = .{ .name = try self.ident() };
        _ = self.skipWs();
        const c = self.peek() orelse return error.InvalidSelector;
        if (c == ']') {
            self.i += 1;
            return sel;
        }
        sel.op = switch (c) {
            '=' => .eq,
            '^' => .prefix,
            '$' => .suffix,
            '*' => .contains,
            '~' => .word,
            '|' => .dash,
            else => return error.InvalidSelector,
        };
        self.i += 1;
        if (sel.op != .eq) {
            if (self.peek() != '=') return error.InvalidSelector;
            self.i += 1;
        }
        _ = self.skipWs();
        const q = self.peek() orelse return error.InvalidSelector;
        if (q == '"' or q == '\'') {
            self.i += 1;
            var buf: std.ArrayList(u8) = .empty;
            while (true) {
                const ch = self.peek() orelse return error.InvalidSelector;
                self.i += 1;
                if (ch == q) break;
                if (ch == '\\') {
                    const esc = self.peek() orelse return error.InvalidSelector;
                    self.i += 1;
                    try buf.append(self.a, esc);
                    continue;
                }
                try buf.append(self.a, ch);
            }
            sel.value = try buf.toOwnedSlice(self.a);
        } else {
            sel.value = try self.ident();
        }
        _ = self.skipWs();
        if (self.peek()) |f| {
            if (f == 'i' or f == 'I') {
                sel.case_insensitive = true;
                self.i += 1;
                _ = self.skipWs();
            } else if (f == 's' or f == 'S') {
                self.i += 1;
                _ = self.skipWs();
            }
        }
        if (self.peek() != ']') return error.InvalidSelector;
        self.i += 1;
        return sel;
    }

    /// CSS identifier with backslash escapes of single characters.
    fn ident(self: *Parser) ParseError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        while (self.peek()) |c| {
            if (c == '\\') {
                self.i += 1;
                const esc = self.peek() orelse return error.InvalidSelector;
                if (std.ascii.isHex(esc)) return error.UnsupportedSelector;
                try buf.append(self.a, esc);
                self.i += 1;
                continue;
            }
            if (!isIdentChar(c)) break;
            try buf.append(self.a, c);
            self.i += 1;
        }
        if (buf.items.len == 0) return error.InvalidSelector;
        if (buf.items[0] >= '0' and buf.items[0] <= '9') return error.InvalidSelector;
        return buf.toOwnedSlice(self.a);
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-' or c >= 0x80 or c == '\\';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c >= 0x80;
}

fn matchComplex(tree: *const Tree, idx: NodeIndex, cx: Complex, ci: usize) bool {
    if (!matchCompound(tree.get(idx), cx.compounds[ci])) return false;
    if (ci == 0) return true;
    switch (cx.combinators[ci - 1]) {
        .child => {
            const p = parentElement(tree, idx) orelse return false;
            return matchComplex(tree, p, cx, ci - 1);
        },
        .descendant => {
            var cur = parentElement(tree, idx);
            while (cur) |p| : (cur = parentElement(tree, p)) {
                if (matchComplex(tree, p, cx, ci - 1)) return true;
            }
            return false;
        },
    }
}

/// Parent element within the same document (stops at document/shadow roots).
fn parentElement(tree: *const Tree, idx: NodeIndex) ?NodeIndex {
    const p = tree.get(idx).parent orelse return null;
    const pn = tree.get(p);
    if (pn.kind != .element or pn.tag.len == 0) return null;
    return p;
}

fn matchCompound(n: *const ax.Node, c: Compound) bool {
    if (c.tag) |t| if (!std.mem.eql(u8, n.tag, t)) return false;
    if (c.id) |id| {
        const v = n.attr("id") orelse return false;
        if (!std.mem.eql(u8, v, id)) return false;
    }
    if (c.classes.len > 0) {
        const cls = n.attr("class") orelse return false;
        for (c.classes) |want| if (!hasWord(cls, want, false)) return false;
    }
    for (c.attrs) |as| if (!matchAttr(n, as)) return false;
    return true;
}

fn matchAttr(n: *const ax.Node, as: AttrSel) bool {
    const v = n.attr(as.name) orelse return false;
    const ci = as.case_insensitive;
    return switch (as.op) {
        .exists => true,
        .eq => eq(v, as.value, ci),
        .prefix => as.value.len > 0 and v.len >= as.value.len and eq(v[0..as.value.len], as.value, ci),
        .suffix => as.value.len > 0 and v.len >= as.value.len and eq(v[v.len - as.value.len ..], as.value, ci),
        .contains => as.value.len > 0 and (if (ci) std.ascii.indexOfIgnoreCase(v, as.value) != null else std.mem.indexOf(u8, v, as.value) != null),
        .word => hasWord(v, as.value, ci),
        .dash => eq(v, as.value, ci) or (v.len > as.value.len and v[as.value.len] == '-' and eq(v[0..as.value.len], as.value, ci)),
    };
}

fn eq(a: []const u8, b: []const u8, ci: bool) bool {
    return if (ci) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn hasWord(list: []const u8, word: []const u8, ci: bool) bool {
    if (word.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |w| if (eq(w, word, ci)) return true;
    return false;
}

pub const max_path_steps = 64;

/// A CSS path that `document.querySelector` resolves to `idx` within its own
/// document: `#id` when the id is a plain identifier and unique in that
/// document, else `tag:nth-of-type(k)` steps from the document element.
/// Returns null for non-element or AX-only nodes and for elements nested
/// deeper than `max_path_steps` (resolve those by backendNodeId instead).
/// Caller frees.
pub fn cssPath(gpa: Allocator, tree: *const Tree, idx: NodeIndex) Allocator.Error!?[]u8 {
    const n = tree.get(idx);
    if (n.kind != .element or n.tag.len == 0) return null;
    const Step = struct { node: NodeIndex, kind: enum { id, tag, nth }, nth: usize = 0 };
    var steps: [max_path_steps]Step = undefined;
    var count: usize = 0;
    var cur: ?NodeIndex = idx;
    while (cur) |c| {
        if (count >= max_path_steps) return null;
        const cn = tree.get(c);
        if (cn.attr("id")) |id| {
            if (isPlainIdent(id) and idUniqueInDocument(tree, c, id)) {
                steps[count] = .{ .node = c, .kind = .id };
                count += 1;
                break;
            }
        }
        const parent = parentElement(tree, c) orelse {
            steps[count] = .{ .node = c, .kind = .tag };
            count += 1;
            break;
        };
        var nth: usize = 0;
        var total: usize = 0;
        for (tree.get(parent).children) |sib| {
            const sn = tree.get(sib);
            if (sn.kind != .element or !std.mem.eql(u8, sn.tag, cn.tag)) continue;
            total += 1;
            if (sib == c) nth = total;
        }
        steps[count] = if (total == 1) .{ .node = c, .kind = .tag } else .{ .node = c, .kind = .nth, .nth = nth };
        count += 1;
        cur = parent;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i = count;
    while (i > 0) {
        i -= 1;
        const st = steps[i];
        const sn = tree.get(st.node);
        switch (st.kind) {
            .id => try out.print(gpa, "#{s}", .{sn.attr("id").?}),
            .tag => try out.appendSlice(gpa, sn.tag),
            .nth => try out.print(gpa, "{s}:nth-of-type({d})", .{ sn.tag, st.nth }),
        }
        if (i > 0) try out.appendSlice(gpa, " > ");
    }
    return try out.toOwnedSlice(gpa);
}

fn isPlainIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn documentOf(tree: *const Tree, idx: NodeIndex) NodeIndex {
    var cur = idx;
    while (tree.get(cur).parent) |p| {
        if (tree.get(p).kind == .document) return p;
        cur = p;
    }
    return cur;
}

fn idUniqueInDocument(tree: *const Tree, idx: NodeIndex, id: []const u8) bool {
    const doc = documentOf(tree, idx);
    var found: usize = 0;
    for (tree.nodes, 0..) |n, i| {
        if (n.kind != .element) continue;
        const v = n.attr("id") orelse continue;
        if (!std.mem.eql(u8, v, id)) continue;
        if (documentOf(tree, @intCast(i)) != doc) continue;
        found += 1;
        if (found > 1) return false;
    }
    return found == 1;
}
