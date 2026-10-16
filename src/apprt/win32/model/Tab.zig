//! A Tab is one tab of a pane (a cmux "surface"): the unit of content shown
//! in one tab bar slot (ARCHITECTURE.md §0.2, ADR-2.3). It is a
//! heap-allocated, reference-counted object (ref/unref/eql, the protocol of
//! src/datastruct/split_tree.zig): its pane holds one reference, and an
//! in-flight WebView2 creation holds another. It carries its title (user
//! override + automatic title), its content, and the legacy per-tab state
//! (status, attention, status text, progress, log, synchronized input)
//! that W0-A3 moves into feature ext state. Formerly `Pane` (renamed in
//! W0-A2, ADR-1.8), whose per-tab fields lived in parallel arrays of the
//! former PaneContainer.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const BrowserPane = @import("../web/BrowserPane.zig");
const Pane = @import("Pane.zig");
const Surface = @import("../Surface.zig");
const Title = @import("Title.zig");
const features_ext = @import("../features/ext.zig");
const handle_registry = @import("logic/handle_registry.zig");
const ids = @import("ids.zig");
const log_ring = @import("../features/status/log_ring.zig");
const w32 = @import("../platform/win32.zig");

pub const TabContent = @import("TabContent.zig").TabContent;

/// Per-tab status indicator shown in the session sidebar.
pub const TabStatus = enum { normal, bell, exited };

/// Maximum bytes of a per-tab status string (set-status). Inline, so
/// set-status never allocates; over-long text is byte truncated by the
/// setter (legacy behavior, W2-6 replaces it).
pub const MAX_STATUS_BYTES: usize = 96;

/// Reference count. Starts at 0; the owning pane takes the first ref.
ref_count: u32 = 0,

/// Identity (`surface_id`, `surface:N`; ADR-2), minted when the tab is
/// created and retired when it is destroyed.
handle: ids.Handle = ids.no_handle,

/// The registry `handle` is minted in (null while unregistered).
registry: ?*handle_registry.HandleRegistry = null,

/// The identity of the current terminal spawn (`CMUX_TERMINAL_LIFECYCLE_ID`),
/// new for every spawn; nil for non-terminal content.
lifecycle_id: ids.Uuid = ids.Uuid.nil,

/// The pane whose tab list holds this tab (null while detached: before
/// insertion, or after removal and before destruction).
pane: ?*Pane = null,

/// What this tab displays.
content: TabContent,

/// Displayed title: user rename over the automatic title.
title: Title = .{},

/// Pinned tabs (cmux pin); no behavior yet.
pinned: bool = false,

/// Last known working directory (filled from OSC 7 by W1-7); owned.
cwd: ?[]u8 = null,

/// Per-surface feature state (ADR-1.3).
ext: features_ext.TabExt = .{},

/// Legacy per-tab state (W0-A3 moves it to the status, notifications and
/// sync_input feature ext state).
legacy: Legacy = .{},

pub const Legacy = struct {
    /// Sidebar dot: bell/exited, cleared when the tab is selected.
    status: TabStatus = .normal,
    /// "Needs attention" aggregate of the content's Surface.attention.
    attention: bool = false,
    /// Orchestration status string (set-status), byte truncated.
    status_text: [MAX_STATUS_BYTES]u8 = undefined,
    status_text_len: u16 = 0,
    /// Progress percent (set-progress), 0..100, or null for none.
    progress: ?u8 = null,
    /// Ring log buffer (log).
    log: log_ring.LogRing = .{},
    /// Synchronized input flag.
    synchronized: bool = false,

    pub fn statusText(self: *const Legacy) []const u8 {
        return self.status_text[0..self.status_text_len];
    }

    /// Store the status text, byte-truncated to MAX_STATUS_BYTES (empty
    /// clears it).
    pub fn setStatusText(self: *Legacy, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, MAX_STATUS_BYTES));
        @memcpy(self.status_text[0..n], text[0..n]);
        self.status_text_len = n;
    }
};

/// Allocate a tab wrapping a terminal surface and set the surface's
/// back-pointer. The caller owns the allocation until a pane takes it.
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

/// Increment the reference count.
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
/// A browser tab can outlive its pane while async WebView2 creation
/// holds an in-flight ref; if an unref took it out of every pane of its
/// window (tab closed mid-creation), its host HWND must hide so the
/// zombie can't keep painting, eating mouse input, or taking focus.
/// Transient unrefs leave the tab findable in a pane and keep it
/// untouched, as do all non-final unrefs of terminal tabs.
fn unrefAction(
    remaining: u32,
    kind: std.meta.Tag(TabContent),
    in_a_tab: bool,
) UnrefAction {
    if (remaining == 0) return .destroy;
    return switch (kind) {
        .terminal, .placeholder => .keep,
        .browser => if (in_a_tab) .keep else .hide_zombie,
    };
}

/// Decrement the reference count. At zero the content is torn down and
/// the tab itself is freed.
pub fn unref(self: *Tab, alloc: Allocator) void {
    self.ref_count -= 1;
    const action = switch (self.content) {
        .terminal => unrefAction(self.ref_count, .terminal, true),
        .placeholder => unrefAction(self.ref_count, .placeholder, true),
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
            // The handle stops resolving before the content goes away.
            if (self.registry) |r| r.retire(self.handle.uuid);
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
                .placeholder => {},
            }
            self.title.deinit(alloc);
            if (self.cwd) |cwd| alloc.free(cwd);
            alloc.destroy(self);
        },
    }
}

/// Identity comparison.
pub fn eql(self: *const Tab, other: *const Tab) bool {
    return self == other;
}

/// The content's HWND, if it has one.
pub fn hwnd(self: *const Tab) ?w32.HWND {
    return self.content.hwnd();
}

/// Give keyboard focus to the content.
pub fn focus(self: *const Tab) void {
    if (self.hwnd()) |h| _ = w32.SetFocus(h);
}

/// The terminal surface, or null for non-terminal content.
pub fn surface(self: *const Tab) ?*Surface {
    return switch (self.content) {
        .terminal => |surface_ptr| surface_ptr,
        else => null,
    };
}

/// The displayed title (empty when none was ever set).
pub fn titleText(self: *const Tab) []const u8 {
    return self.title.text() orelse "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: tab unref destroys at zero regardless of kind" {
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .terminal, true));
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .terminal, false));
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .browser, true));
    try testing.expectEqual(UnrefAction.destroy, unrefAction(0, .browser, false));
}

test "unit: model: tab unref keeps live tabs that are still owned" {
    try testing.expectEqual(UnrefAction.keep, unrefAction(1, .terminal, true));
    try testing.expectEqual(UnrefAction.keep, unrefAction(1, .browser, true));
    try testing.expectEqual(UnrefAction.keep, unrefAction(3, .browser, true));
}

test "unit: model: tab unref hides only an orphaned browser" {
    // The in-flight WebView2 creation ref outliving every tab is the
    // zombie case; terminals never hide before destruction.
    try testing.expectEqual(UnrefAction.hide_zombie, unrefAction(1, .browser, false));
    try testing.expectEqual(UnrefAction.hide_zombie, unrefAction(2, .browser, false));
    try testing.expectEqual(UnrefAction.keep, unrefAction(1, .terminal, false));
}

test "unit: model: tab unref decision matrix is total" {
    // Every (remaining, kind, in_a_tab) cell as one explicit table —
    // the focused tests above pin the interesting cells, this one
    // guarantees no combination was left unasserted: zero destroys
    // unconditionally, live terminals (and placeholders) are always kept,
    // and a live browser is kept exactly while some pane still owns it.
    const Kind = std.meta.Tag(TabContent);
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
        .{ .remaining = 0, .kind = .placeholder, .in_a_tab = true, .want = .destroy },
        .{ .remaining = 0, .kind = .placeholder, .in_a_tab = false, .want = .destroy },
        .{ .remaining = 1, .kind = .terminal, .in_a_tab = true, .want = .keep },
        .{ .remaining = 1, .kind = .terminal, .in_a_tab = false, .want = .keep },
        .{ .remaining = 1, .kind = .browser, .in_a_tab = true, .want = .keep },
        .{ .remaining = 1, .kind = .browser, .in_a_tab = false, .want = .hide_zombie },
        .{ .remaining = 1, .kind = .placeholder, .in_a_tab = true, .want = .keep },
        .{ .remaining = 1, .kind = .placeholder, .in_a_tab = false, .want = .keep },
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

test "unit: model: tab ref counts up and returns self" {
    // No test calls unref(): analyzing it pulls the entire content
    // teardown graph (Surface.deinit -> renderer -> a comptime
    // apprt.gtk reference) into the test build, which then collects
    // gtk's refAllDecls test and fails on the absent GTK modules. The
    // unref decision rules are covered through unrefAction above.
    var tab: Tab = .{ .content = .placeholder };
    try testing.expectEqual(@as(u32, 0), tab.ref_count);
    const p = try tab.ref(testing.allocator);
    try testing.expectEqual(&tab, p);
    try testing.expectEqual(@as(u32, 1), tab.ref_count);
    _ = try tab.ref(testing.allocator);
    try testing.expectEqual(@as(u32, 2), tab.ref_count);
}

test "unit: model: tab eql is identity" {
    var a: Tab = .{ .content = .placeholder };
    var b: Tab = .{ .content = .placeholder };
    try testing.expect(a.eql(&a));
    try testing.expect(!a.eql(&b));
}

test "unit: model: tab legacy status text is byte truncated" {
    var l: Legacy = .{};
    try testing.expectEqualStrings("", l.statusText());
    l.setStatusText("running tests");
    try testing.expectEqualStrings("running tests", l.statusText());
    var long: [MAX_STATUS_BYTES + 10]u8 = undefined;
    @memset(&long, 'x');
    l.setStatusText(&long);
    try testing.expectEqual(MAX_STATUS_BYTES, l.statusText().len);
    l.setStatusText("");
    try testing.expectEqualStrings("", l.statusText());
}

test "unit: model: placeholder tabs have no HWND or surface" {
    const tab: Tab = .{ .content = .placeholder };
    try testing.expectEqual(@as(?w32.HWND, null), tab.hwnd());
    try testing.expectEqual(@as(?*Surface, null), tab.surface());
    try testing.expectEqualStrings("", tab.titleText());
}
