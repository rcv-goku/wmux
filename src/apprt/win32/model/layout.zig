//! Pane layout of a workspace split tree (ARCHITECTURE.md ADR-1.8 W0-A2
//! step 3). One pass computes the rect of every tree node, the leaf (pane)
//! rects and the divider geometry; pane layout, the attention rings, the
//! pane buttons, divider paint, divider hit-testing, divider drag and the
//! keyboard split resize all consume the same result, so they can never
//! disagree. Generic over the tree's view type so the unit tests run on a
//! plain test view (the real one is model/Pane.zig).
//!
//! Geometry (unchanged from the former per-consumer walks): a split at
//! ratio r over a node rect W wide puts its divider line at
//! x = left + trunc(r * W); the left child ends gap/2 before the line and
//! the right child starts (gap+1)/2 after it (vertical splits likewise on
//! y). Zoom is not applied here: callers lay out a zoomed pane over the
//! whole rect themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;

const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("../platform/win32.zig");

pub const Rect = w32.RECT;

/// Stack buffer size the UI passes to std.heap.stackFallback when it
/// computes a layout per message (paint, hit-test, layout): enough for
/// about fifty panes, so the common case never touches the heap; bigger
/// trees fall back to the heap (no cap, G7).
pub const stack_bytes: usize = 4096;

/// The gap between two sibling panes in pixels at `scale`; the divider
/// line sits inside it.
pub fn gapWidth(scale: f32) i32 {
    return @intFromFloat(@round(5.0 * scale));
}

/// The half-width of a divider's grab band in pixels at `scale`.
pub fn hitArea(scale: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(3.0 * scale))), 3);
}

/// The width of a painted divider line in pixels at `scale`.
pub fn lineWidth(scale: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(1.0 * scale))), 1);
}

/// The computed layout of a SplitTree(V).
pub fn Layout(comptime V: type) type {
    return struct {
        const Self = @This();
        const Tree = SplitTree(V);

        pub const Handle = Tree.Node.Handle;
        pub const SplitLayout = Tree.Split.Layout;

        pub const Leaf = struct {
            handle: Handle,
            view: *V,
            rect: Rect,
        };

        pub const Divider = struct {
            /// The split node.
            handle: Handle,
            layout: SplitLayout,
            /// The split node's own rect. Dragging this divider (or a
            /// keyboard resize of this split) is measured against it, not
            /// against the whole workspace (ui-model 8.1 #2).
            node_rect: Rect,
            /// The divider line: an x for a horizontal (left|right) split,
            /// a y for a vertical (top/bottom) one.
            pos: i32,

            /// Whether (x, y) is in this divider's grab band: `band` pixels
            /// on either side of the line, across the node rect (bounds
            /// inclusive).
            pub fn contains(self: Divider, x: i32, y: i32, band: i32) bool {
                const r = self.node_rect;
                return switch (self.layout) {
                    .horizontal => x >= self.pos - band and x <= self.pos + band and
                        y >= r.top and y <= r.bottom,
                    .vertical => y >= self.pos - band and y <= self.pos + band and
                        x >= r.left and x <= r.right,
                };
            }
        };

        /// The rect of every node, indexed by node handle.
        node_rects: []Rect,
        /// The parent split of every node (null for the root), indexed by
        /// node handle.
        parents: []?Handle,
        /// The leaves in depth-first order, left before right (the pane
        /// index order of Workspace.paneAt).
        leaves: []Leaf,
        /// The dividers in pre-order: a split before the splits inside it.
        dividers: []Divider,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.node_rects);
            gpa.free(self.parents);
            gpa.free(self.leaves);
            gpa.free(self.dividers);
            self.* = undefined;
        }

        /// The divider whose grab band contains (x, y) at `scale`. An outer
        /// split wins over the splits inside it.
        pub fn hitTest(self: *const Self, x: i32, y: i32, scale: f32) ?Divider {
            const band = hitArea(scale);
            for (self.dividers) |d| {
                if (d.contains(x, y, band)) return d;
            }
            return null;
        }

        /// The divider of split node `handle`, if it is one.
        pub fn divider(self: *const Self, handle: Handle) ?Divider {
            for (self.dividers) |d| {
                if (d.handle == handle) return d;
            }
            return null;
        }

        /// The leaf showing `view`, if any.
        pub fn leafOf(self: *const Self, view: *const V) ?Leaf {
            for (self.leaves) |leaf| {
                if (leaf.view == view) return leaf;
            }
            return null;
        }

        /// The nearest split above node `from` whose layout is `layout`:
        /// the split a keyboard resize in that direction moves (the same
        /// search as SplitTree.resize).
        pub fn parentSplit(self: *const Self, tree: *const Tree, from: Handle, layout: SplitLayout) ?Handle {
            if (from.idx() >= self.parents.len) return null;
            var current = self.parents[from.idx()];
            while (current) |h| : (current = self.parents[h.idx()]) {
                switch (tree.nodes[h.idx()]) {
                    .split => |s| if (s.layout == layout) return h,
                    .leaf => {},
                }
            }
            return null;
        }
    };
}

/// Lay out `tree` over `rect` at `scale`. The result is owned by the
/// caller (deinit with the same allocator). An empty tree has no nodes.
pub fn compute(
    comptime V: type,
    gpa: Allocator,
    tree: *const SplitTree(V),
    rect: Rect,
    scale: f32,
) Allocator.Error!Layout(V) {
    const L = Layout(V);
    const n = tree.nodes.len;
    const node_rects = try gpa.alloc(Rect, n);
    errdefer gpa.free(node_rects);
    const parents = try gpa.alloc(?L.Handle, n);
    errdefer gpa.free(parents);
    @memset(parents, null);

    var leaf_count: usize = 0;
    for (tree.nodes) |node| switch (node) {
        .leaf => leaf_count += 1,
        .split => {},
    };
    const leaves = try gpa.alloc(L.Leaf, leaf_count);
    errdefer gpa.free(leaves);
    const dividers = try gpa.alloc(L.Divider, n - leaf_count);
    errdefer gpa.free(dividers);

    var result: L = .{
        .node_rects = node_rects,
        .parents = parents,
        .leaves = leaves,
        .dividers = dividers,
    };
    if (n == 0) return result;

    var walk: Walk(V) = .{ .tree = tree, .out = &result, .gap = gapWidth(scale) };
    walk.node(.root, rect, null);
    // Only reachable nodes are written; a well-formed tree reaches all.
    result.leaves = leaves[0..walk.leaf_n];
    result.dividers = dividers[0..walk.divider_n];
    return result;
}

fn Walk(comptime V: type) type {
    return struct {
        const Self = @This();
        const L = Layout(V);

        tree: *const SplitTree(V),
        out: *L,
        gap: i32,
        leaf_n: usize = 0,
        divider_n: usize = 0,

        fn node(self: *Self, handle: L.Handle, rect: Rect, parent: ?L.Handle) void {
            if (handle.idx() >= self.tree.nodes.len) return;
            self.out.node_rects[handle.idx()] = rect;
            self.out.parents[handle.idx()] = parent;
            switch (self.tree.nodes[handle.idx()]) {
                .leaf => |view| {
                    if (self.leaf_n >= self.out.leaves.len) return;
                    self.out.leaves[self.leaf_n] = .{ .handle = handle, .view = view, .rect = rect };
                    self.leaf_n += 1;
                },
                .split => |s| {
                    const ratio: f32 = @floatCast(s.ratio);
                    const before = @divTrunc(self.gap, 2);
                    const after = @divTrunc(self.gap + 1, 2);
                    var first = rect;
                    var second = rect;
                    const pos: i32 = switch (s.layout) {
                        .horizontal => pos: {
                            const total_w = rect.right - rect.left;
                            const x = rect.left + @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(total_w))));
                            first.right = x - before;
                            second.left = x + after;
                            break :pos x;
                        },
                        .vertical => pos: {
                            const total_h = rect.bottom - rect.top;
                            const y = rect.top + @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(total_h))));
                            first.bottom = y - before;
                            second.top = y + after;
                            break :pos y;
                        },
                    };
                    if (self.divider_n < self.out.dividers.len) {
                        self.out.dividers[self.divider_n] = .{
                            .handle = handle,
                            .layout = s.layout,
                            .node_rect = rect,
                            .pos = pos,
                        };
                        self.divider_n += 1;
                    }
                    self.node(s.left, first, handle);
                    self.node(s.right, second, handle);
                },
            }
        }
    };
}

/// The split ratio that puts the divider of a split over `node_rect` at
/// client coordinate (x, y), clamped to [0.1, 0.9] (divider drag).
pub fn dragRatio(layout: anytype, node_rect: Rect, x: i32, y: i32) f16 {
    const ratio: f32 = switch (layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(node_rect.right - node_rect.left, 1));
            const pos: f32 = @floatFromInt(x - node_rect.left);
            break :ratio pos / total;
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(node_rect.bottom - node_rect.top, 1));
            const pos: f32 = @floatFromInt(y - node_rect.top);
            break :ratio pos / total;
        },
    };
    return @floatCast(std.math.clamp(ratio, 0.1, 0.9));
}

/// The split ratio after moving the divider of a split over `node_rect`
/// by `delta_px` pixels (keyboard resize), clamped to [0, 1] like
/// SplitTree.resize.
pub fn resizedRatio(layout: anytype, node_rect: Rect, ratio: f16, delta_px: i32) f16 {
    const dim: f32 = @floatFromInt(@max(switch (layout) {
        .horizontal => node_rect.right - node_rect.left,
        .vertical => node_rect.bottom - node_rect.top,
    }, 1));
    const next = @as(f32, @floatCast(ratio)) + @as(f32, @floatFromInt(delta_px)) / dim;
    return @floatCast(std.math.clamp(next, 0, 1));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A reference-counted test view with identity (SplitTree views).
const TestView = struct {
    id: u8,
    refs: u32 = 0,

    pub fn ref(self: *TestView, gpa: Allocator) Allocator.Error!*TestView {
        _ = gpa;
        self.refs += 1;
        return self;
    }

    pub fn unref(self: *TestView, gpa: Allocator) void {
        _ = gpa;
        self.refs -= 1;
    }
};

const TestTree = SplitTree(TestView);
const TestLayout = Layout(TestView);

fn rectEq(want: Rect, got: Rect) !void {
    try testing.expectEqual(want.left, got.left);
    try testing.expectEqual(want.top, got.top);
    try testing.expectEqual(want.right, got.right);
    try testing.expectEqual(want.bottom, got.bottom);
}

/// Split `tree` at its root in `dir` with a single-leaf tree of `view`.
fn splitRoot(tree: *TestTree, view: *TestView, dir: TestTree.Split.Direction, at: TestTree.Node.Handle) !void {
    var insert = try TestTree.init(testing.allocator, view);
    defer insert.deinit();
    const next = try tree.split(testing.allocator, at, dir, 0.5, &insert);
    tree.deinit();
    tree.* = next;
}

fn findLeaf(tree: *const TestTree, view: *const TestView) TestTree.Node.Handle {
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view == view) return entry.handle;
    }
    unreachable;
}

const full: Rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 600 };

test "unit: model: layout of an empty tree has no nodes" {
    const tree: TestTree = .empty;
    var lay = try compute(TestView, testing.allocator, &tree, full, 1.0);
    defer lay.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), lay.leaves.len);
    try testing.expectEqual(@as(usize, 0), lay.dividers.len);
    try testing.expectEqual(@as(?TestLayout.Divider, null), lay.hitTest(500, 300, 1.0));
}

test "unit: model: layout of one pane covers the whole rect" {
    var a: TestView = .{ .id = 1 };
    var tree = try TestTree.init(testing.allocator, &a);
    defer tree.deinit();
    var lay = try compute(TestView, testing.allocator, &tree, full, 1.0);
    defer lay.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), lay.leaves.len);
    try testing.expectEqual(&a, lay.leaves[0].view);
    try rectEq(full, lay.leaves[0].rect);
    try testing.expectEqual(@as(usize, 0), lay.dividers.len);
}

test "unit: model: layout splits with the gap around the divider line" {
    var a: TestView = .{ .id = 1 };
    var b: TestView = .{ .id = 2 };
    var tree = try TestTree.init(testing.allocator, &a);
    defer tree.deinit();
    try splitRoot(&tree, &b, .right, .root);

    // scale 1: gap 5 = 2 before the line and 3 after it.
    var lay = try compute(TestView, testing.allocator, &tree, full, 1.0);
    defer lay.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), lay.leaves.len);
    try testing.expectEqual(&a, lay.leaves[0].view);
    try rectEq(.{ .left = 0, .top = 0, .right = 498, .bottom = 600 }, lay.leaves[0].rect);
    try testing.expectEqual(&b, lay.leaves[1].view);
    try rectEq(.{ .left = 503, .top = 0, .right = 1000, .bottom = 600 }, lay.leaves[1].rect);
    try testing.expectEqual(@as(usize, 1), lay.dividers.len);
    try testing.expectEqual(@as(i32, 500), lay.dividers[0].pos);
    try testing.expectEqual(TestLayout.SplitLayout.horizontal, lay.dividers[0].layout);
    try rectEq(full, lay.dividers[0].node_rect);

    // scale 2: gap 10, band 6.
    var lay2 = try compute(TestView, testing.allocator, &tree, full, 2.0);
    defer lay2.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 495), lay2.leaves[0].rect.right);
    try testing.expectEqual(@as(i32, 505), lay2.leaves[1].rect.left);
    try testing.expect(lay2.hitTest(506, 10, 2.0) != null);
    try testing.expect(lay2.hitTest(507, 10, 2.0) == null);
}

test "unit: model: layout of nested splits gives each divider its own node rect" {
    // a | (b / c): the right half is split top/bottom.
    var a: TestView = .{ .id = 1 };
    var b: TestView = .{ .id = 2 };
    var c: TestView = .{ .id = 3 };
    var tree = try TestTree.init(testing.allocator, &a);
    defer tree.deinit();
    try splitRoot(&tree, &b, .right, .root);
    try splitRoot(&tree, &c, .down, findLeaf(&tree, &b));

    var lay = try compute(TestView, testing.allocator, &tree, full, 1.0);
    defer lay.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), lay.leaves.len);
    try testing.expectEqual(@as(usize, 2), lay.dividers.len);

    // Pre-order: the outer (root) split first.
    const outer = lay.dividers[0];
    const inner = lay.dividers[1];
    try testing.expectEqual(TestLayout.SplitLayout.horizontal, outer.layout);
    try rectEq(full, outer.node_rect);
    try testing.expectEqual(TestLayout.SplitLayout.vertical, inner.layout);
    // The inner split covers only the right half, so its line is at the
    // middle of THAT rect.
    try rectEq(.{ .left = 503, .top = 0, .right = 1000, .bottom = 600 }, inner.node_rect);
    try testing.expectEqual(@as(i32, 300), inner.pos);

    // Leaves in depth-first order with the inner gap applied.
    try testing.expectEqual(&a, lay.leaves[0].view);
    try testing.expectEqual(&b, lay.leaves[1].view);
    try rectEq(.{ .left = 503, .top = 0, .right = 1000, .bottom = 298 }, lay.leaves[1].rect);
    try testing.expectEqual(&c, lay.leaves[2].view);
    try rectEq(.{ .left = 503, .top = 303, .right = 1000, .bottom = 600 }, lay.leaves[2].rect);

    // Hit-testing: the inner band lives only over the right half.
    try testing.expectEqual(inner.handle, lay.hitTest(700, 301, 1.0).?.handle);
    try testing.expect(lay.hitTest(200, 301, 1.0) == null);
    try testing.expectEqual(outer.handle, lay.hitTest(499, 301, 1.0).?.handle);

    // Parents and the keyboard-resize split search.
    try testing.expectEqual(outer.handle, lay.parentSplit(&tree, lay.leaves[0].handle, .horizontal).?);
    try testing.expectEqual(inner.handle, lay.parentSplit(&tree, lay.leaves[2].handle, .vertical).?);
    try testing.expectEqual(outer.handle, lay.parentSplit(&tree, lay.leaves[2].handle, .horizontal).?);
    try testing.expectEqual(@as(?TestLayout.Handle, null), lay.parentSplit(&tree, lay.leaves[0].handle, .vertical));
    try testing.expectEqual(inner.handle, lay.parents[lay.leafOf(&c).?.handle.idx()].?);
}

test "unit: model: divider drag measures against the dragged node rect" {
    // ui-model 8.1 #2: the inner divider of a | (b / c) spans y 0..600 of
    // the right half only; dragging it to y=150 means ratio 0.25 of that
    // node, wherever the node sits.
    const inner: Rect = .{ .left = 503, .top = 0, .right = 1000, .bottom = 600 };
    try testing.expectApproxEqAbs(@as(f32, 0.25), @as(f32, dragRatio(TestLayout.SplitLayout.vertical, inner, 700, 150)), 0.001);
    // A horizontal split nested at x=503: x=751 is half-way across it.
    try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, dragRatio(TestLayout.SplitLayout.horizontal, inner, 751, 0)), 0.01);
    // Clamped to [0.1, 0.9].
    try testing.expectApproxEqAbs(@as(f32, 0.1), @as(f32, dragRatio(TestLayout.SplitLayout.horizontal, inner, 0, 0)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.9), @as(f32, dragRatio(TestLayout.SplitLayout.vertical, inner, 0, 10_000)), 0.001);
}

test "unit: model: keyboard resize moves the divider by pixels of its own node" {
    const node: Rect = .{ .left = 503, .top = 0, .right = 1000, .bottom = 600 };
    // 60 px of a 600 px tall node is 0.1 of its ratio.
    try testing.expectApproxEqAbs(@as(f32, 0.6), @as(f32, resizedRatio(TestLayout.SplitLayout.vertical, node, 0.5, 60)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), @as(f32, resizedRatio(TestLayout.SplitLayout.vertical, node, 0.5, -60)), 0.001);
    // Clamped to [0, 1].
    try testing.expectApproxEqAbs(@as(f32, 1.0), @as(f32, resizedRatio(TestLayout.SplitLayout.horizontal, node, 0.9, 1000)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), @as(f32, resizedRatio(TestLayout.SplitLayout.horizontal, node, 0.1, -1000)), 0.001);
}
