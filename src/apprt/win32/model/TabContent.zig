//! What a tab displays (ARCHITECTURE.md §0.2, ADR-6.1) [frozen]: a
//! terminal surface, a WebView2 browser pane, a web panel (a bundled local
//! web app of one `PanelKind`, implemented by W1-6), or a placeholder (no
//! live content: the HWND-less tabs of the model tests' fake graphs, and
//! later hibernated or lazily restored tabs, W5).

const std = @import("std");

const BrowserPane = @import("../web/BrowserPane.zig");
const Surface = @import("../Surface.zig");
const WebPanel = @import("../web/WebPanel.zig");
const w32 = @import("../platform/win32.zig");

/// A rectangle in the parent window's client coordinates (physical pixels).
pub const Rect = w32.RECT;

/// The state of a tab without live content. Empty until hibernation
/// (W5) and lazy restore keep what is needed to bring the content back.
pub const Placeholder = struct {};

pub const TabContent = union(enum) {
    terminal: *Surface,
    browser: *BrowserPane,
    web: *WebPanel,
    placeholder: Placeholder,

    /// The content's top HWND, if it has one.
    pub fn hwnd(self: TabContent) ?w32.HWND {
        return switch (self) {
            .terminal => |s| s.hwnd,
            .browser => |b| b.host_hwnd,
            .web => |p| p.hwnd(),
            .placeholder => null,
        };
    }

    /// Move the content's HWND to `r` (the parent's client coordinates,
    /// physical pixels; at least 1x1) and repaint it; no-op without an HWND.
    /// Every variant moves `hwnd()` today (ruling D5): the terminal and the
    /// browser host resize their children on `WM_SIZE`; W1-6c may give the
    /// `.web` variant its own bounds handling.
    pub fn setBounds(self: TabContent, r: Rect) void {
        const h = self.hwnd() orelse return;
        const width = @max(r.right - r.left, 1);
        const height = @max(r.bottom - r.top, 1);
        _ = w32.MoveWindow(h, r.left, r.top, width, height, 1);
    }

    /// Show or hide the content's HWND (no-op without one).
    pub fn setVisible(self: TabContent, visible: bool) void {
        const h = self.hwnd() orelse return;
        _ = w32.ShowWindow(h, if (visible) w32.SW_SHOW else w32.SW_HIDE);
    }

    /// Give keyboard focus to the content (no-op without an HWND).
    pub fn focus(self: TabContent) void {
        if (self.hwnd()) |h| _ = w32.SetFocus(h);
    }

    /// The content kind as events and the session name it: `terminal`,
    /// `browser`, the web panel's kind id (`markdown`, ...), or
    /// `placeholder`.
    pub fn kindName(self: TabContent) []const u8 {
        return switch (self) {
            .terminal => "terminal",
            .browser => "browser",
            .web => |p| p.kind.id,
            .placeholder => "placeholder",
        };
    }

    /// Write the content's snapshot object (`wmux.debug.layout`, the
    /// session's per-tab content, ADR-6.1): today `{"kind": kindName()}` for
    /// every variant (ruling D5); the owners add their fields later.
    pub fn snapshot(self: TabContent, w: *std.json.Stringify) std.json.Stringify.Error!void {
        try w.beginObject();
        try w.objectField("kind");
        try w.write(self.kindName());
        try w.endObject();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: placeholder content has no HWND and names its kind" {
    const content: TabContent = .{ .placeholder = .{} };
    try testing.expectEqual(@as(?w32.HWND, null), content.hwnd());
    try testing.expectEqualStrings("placeholder", content.kindName());
    // Without an HWND, showing, hiding, moving and focusing do nothing.
    content.setVisible(true);
    content.setVisible(false);
    content.setBounds(.{ .left = 0, .top = 0, .right = 10, .bottom = 10 });
    content.focus();
}

test "unit: model: snapshot writes the content kind" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: std.json.Stringify = .{ .writer = &out.writer };
    const content: TabContent = .{ .placeholder = .{} };
    try content.snapshot(&w);
    try testing.expectEqualStrings("{\"kind\":\"placeholder\"}", out.written());
}
