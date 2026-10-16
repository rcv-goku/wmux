//! A Tab is one tab of a split-tree leaf (a cmux "surface"): the unit of
//! content shown in one tab bar slot. It is a heap-allocated,
//! reference-counted wrapper implementing the view protocol of
//! src/datastruct/split_tree.zig (ref/unref/eql). Content is either a
//! terminal Surface or a WebView2 BrowserPane. Formerly `Pane` (renamed
//! in W0-A2, ARCHITECTURE.md ADR-1.8).
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const BrowserPane = @import("../web/BrowserPane.zig");
const Surface = @import("../Surface.zig");
const w32 = @import("../platform/win32.zig");

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// What this tab displays.
content: Content,

pub const Content = union(enum) {
    terminal: *Surface,
    browser: *BrowserPane,
};

/// Per-tab status indicator shown in the session sidebar.
pub const TabStatus = enum { normal, bell, exited };

/// Allocate a tab wrapping a terminal surface and set the surface's
/// back-pointer. The caller owns the allocation until a SplitTree
/// ref()s the tab.
pub fn create(alloc: Allocator, surface_ptr: *Surface) Allocator.Error!*Tab {
    const tab = try alloc.create(Tab);
    tab.* = .{ .content = .{ .terminal = surface_ptr } };
    surface_ptr.tab = tab;
    return tab;
}

/// Allocate a tab wrapping a browser and set the browser's
/// back-pointer. Same ownership contract as create().
pub fn createBrowser(alloc: Allocator, browser: *BrowserPane) Allocator.Error!*Tab {
    const tab = try alloc.create(Tab);
    tab.* = .{ .content = .{ .browser = browser } };
    browser.tab = tab;
    return tab;
}

/// SplitTree view protocol: increment reference count.
pub fn ref(self: *Tab, alloc: Allocator) Allocator.Error!*Tab {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// What unref() must do after decrementing the count. Pure (decided by
/// unrefAction) so the rules are unit-testable; the actions themselves
/// are HWND/WebView2 calls.
const UnrefAction = enum { keep, hide_zombie, destroy };

/// The unref state machine. `remaining` is the post-decrement count.
/// A browser tab can outlive its trees while async WebView2 creation
/// holds an in-flight ref; if an unref took it out of every tab of its
/// window (tab closed mid-creation), its host HWND must hide so the
/// zombie can't keep painting, eating mouse input, or taking focus.
/// Transient unrefs during tree rebuilds (split/resize/equalize) leave
/// the tab findable in a tree and keep it untouched, as do all
/// non-final unrefs of terminal tabs.
fn unrefAction(
    remaining: u32,
    kind: std.meta.Tag(Content),
    in_a_tab: bool,
) UnrefAction {
    if (remaining == 0) return .destroy;
    return switch (kind) {
        .terminal => .keep,
        .browser => if (in_a_tab) .keep else .hide_zombie,
    };
}

/// SplitTree view protocol: decrement reference count. At zero the
/// content is torn down and the tab itself is freed.
pub fn unref(self: *Tab, alloc: Allocator) void {
    self.ref_count -= 1;
    const action = switch (self.content) {
        .terminal => unrefAction(self.ref_count, .terminal, true),
        .browser => |browser| unrefAction(
            self.ref_count,
            .browser,
            // Only consulted when refs remain (zero destroys either
            // way); the short-circuit keeps findLoc out of the
            // teardown path.
            self.ref_count > 0 and
                browser.parent_window.findLoc(self) != null,
        ),
    };
    switch (action) {
        .keep => {},
        .hide_zombie => {
            // unrefAction only returns this for browser content.
            const browser = self.content.browser;
            if (browser.host_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        },
        .destroy => {
            switch (self.content) {
                .terminal => |surface_ptr| {
                    if (surface_ptr.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                    surface_ptr.deinit();
                    alloc.destroy(surface_ptr);
                },
                // Closes the controller and destroys the host HWND
                // before the parent Window teardown, mirroring the WGL
                // ordering rule.
                .browser => |browser| browser.destroy(alloc),
            }
            alloc.destroy(self);
        },
    }
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const Tab, other: *const Tab) bool {
    return self == other;
}

/// The content's HWND, if it has one.
pub fn hwnd(self: *const Tab) ?w32.HWND {
    return switch (self.content) {
        .terminal => |surface_ptr| surface_ptr.hwnd,
        .browser => |browser| browser.host_hwnd,
    };
}

/// Give keyboard focus to the content.
pub fn focus(self: *const Tab) void {
    if (self.hwnd()) |h| _ = w32.SetFocus(h);
}

/// The terminal surface, or null for non-terminal content.
pub fn surface(self: *const Tab) ?*Surface {
    return switch (self.content) {
        .terminal => |surface_ptr| surface_ptr,
        .browser => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: pane unref destroys at zero regardless of kind" {
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .terminal, true));
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .terminal, false));
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .browser, true));
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .browser, false));
}

test "unit: pane unref keeps live panes that are still owned" {
    try testing.expectEqual(UnrefAction.keep, unrefAction(1, .terminal, true));
    try testing.expectEqual(UnrefAction.keep, unrefAction(1, .browser, true));
    try testing.expectEqual(UnrefAction.keep, unrefAction(3, .browser, true));
}

test "unit: pane unref hides only an orphaned browser" {
    // The in-flight WebView2 creation ref outliving every tab is the
    // zombie case; terminals never hide before destruction.
    try testing.expectEqual(UnrefAction.hide_zombie, unrefAction(1, .browser, false));
    try testing.expectEqual(UnrefAction.hide_zombie, unrefAction(2, .browser, false));
    try testing.expectEqual(UnrefAction.keep, unrefAction(1, .terminal, false));
}

test "unit: pane unref decision matrix is total" {
    // Every (remaining, kind, in_a_tab) cell as one explicit table —
    // the focused tests above pin the interesting cells, this one
    // guarantees no combination was left unasserted: zero destroys
    // unconditionally, live terminals are always kept, and a live
    // browser is kept exactly while some tree still owns it.
    const Kind = std.meta.Tag(Content);
    const cases = [_]struct {
        remaining: u32,
        kind: Kind,
        in_a_tab: bool,
        want: UnrefAction,
    }{
        .{ .remaining = 0, .kind = .terminal, .in_a_tab = true, .want = .destroy },
        .{ .remaining = 0, .kind = .terminal, .in_a_tab = false, .want = .destroy },
        .{ .remaining = 0, .kind = .browser, .in_a_tab = true, .want = .destroy },
        .{ .remaining = 0, .kind = .browser, .in_a_tab = false, .want = .destroy },
        .{ .remaining = 1, .kind = .terminal, .in_a_tab = true, .want = .keep },
        .{ .remaining = 1, .kind = .terminal, .in_a_tab = false, .want = .keep },
        .{ .remaining = 1, .kind = .browser, .in_a_tab = true, .want = .keep },
        .{ .remaining = 1, .kind = .browser, .in_a_tab = false, .want = .hide_zombie },
        .{ .remaining = 2, .kind = .terminal, .in_a_tab = true, .want = .keep },
        .{ .remaining = 2, .kind = .terminal, .in_a_tab = false, .want = .keep },
        .{ .remaining = 2, .kind = .browser, .in_a_tab = true, .want = .keep },
        .{ .remaining = 2, .kind = .browser, .in_a_tab = false, .want = .hide_zombie },
    };
    for (cases) |c| {
        try testing.expectEqual(
            c.want,
            unrefAction(c.remaining, c.kind, c.in_a_tab),
        );
    }
}

test "unit: pane ref counts up and returns self" {
    // No test calls unref(): analyzing it pulls the entire content
    // teardown graph (Surface.deinit -> renderer -> a comptime
    // apprt.gtk reference) into the test build, which then collects
    // gtk's refAllDecls test and fails on the absent GTK modules. The
    // unref decision rules are covered through unrefAction above.
    var tab: Tab = .{ .content = .{ .terminal = undefined } };
    try testing.expectEqual(@as(u32, 0), tab.ref_count);
    const p = try tab.ref(testing.allocator);
    try testing.expectEqual(&tab, p);
    try testing.expectEqual(@as(u32, 1), tab.ref_count);
    _ = try tab.ref(testing.allocator);
    try testing.expectEqual(@as(u32, 2), tab.ref_count);
}

test "unit: pane eql is identity" {
    var a: Tab = .{ .content = .{ .terminal = undefined } };
    var b: Tab = .{ .content = .{ .terminal = undefined } };
    try testing.expect(a.eql(&a));
    try testing.expect(!a.eql(&b));
}
