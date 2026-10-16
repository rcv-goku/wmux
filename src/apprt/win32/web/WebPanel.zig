//! A web panel: tab content showing a bundled local web app of one
//! `PanelKind` (markdown, diff, settings, ...; ARCHITECTURE.md ADR-6.1,
//! ADR-6.2). The third `TabContent` kind next to terminals and browser
//! panes.
//!
//! Stub written by W0-A3 with the ADR-6.2 fields and the entry points
//! model/TabContent.zig and model/Tab.zig dispatch to, so those frozen
//! files never change for web panels; W1-6 implements the bodies (it owns
//! web/**). Until then no web panel is ever created.

const WebPanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const PanelKind = @import("PanelKind.zig").PanelKind;
const Tab = @import("../model/Tab.zig");
const WebHost = @import("WebHost.zig");
const w32 = @import("../platform/win32.zig");

/// The tab showing this panel.
tab: *Tab,

/// What the panel shows.
kind: *const PanelKind,

/// The WebView2 host, created lazily on first show (ADR-6.9).
host: ?*WebHost = null,

/// The last `panel.state_changed` state (<= 64 KiB, owned), kept for the
/// session snapshot and reload after a renderer crash.
state_json: ?[]u8 = null,

/// The title the page set (`panel.set_title`, owned).
title: []u8 = &.{},

/// Per-kind native state owned by the kind's create/destroy.
kind_state: ?*anyopaque = null,

/// The host HWND, if the host exists.
pub fn hwnd(self: *const WebPanel) ?w32.HWND {
    const host = self.host orelse return null;
    return host.hwnd;
}

/// Follow a move of the top-level window (screen-positioned popups of the
/// host). Nothing to do until W1-6.
pub fn onParentWindowMoved(self: *WebPanel) void {
    _ = self;
}

/// Tear the panel down (the kind's destroy, the host, the strings) and
/// free it. Called by Tab.unref when the last reference goes.
pub fn destroy(self: *WebPanel, gpa: Allocator) void {
    if (self.kind.destroy) |kind_destroy| kind_destroy(self);
    if (self.state_json) |s| gpa.free(s);
    gpa.free(self.title);
    gpa.destroy(self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: web: a web panel without a host has no HWND" {
    const kind: PanelKind = .{ .id = "about", .app = "about", .title = PanelKind.noTitle, .allow = &.{}, .create = PanelKind.noCreate };
    var tab: Tab = .{ .content = .{ .placeholder = .{} } };
    const panel = try testing.allocator.create(WebPanel);
    panel.* = .{ .tab = &tab, .kind = &kind, .title = try testing.allocator.dupe(u8, "About") };
    try testing.expectEqual(@as(?w32.HWND, null), panel.hwnd());
    panel.onParentWindowMoved();
    panel.destroy(testing.allocator);
}
