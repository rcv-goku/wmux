//! Web panel kinds (ARCHITECTURE.md ADR-6.2). A feature registers the
//! panels it offers in `features/<id>/panels.zig`, declared in its mod.zig
//! as `pub const panel_kinds = @import("panels.zig").kinds;` (a
//! `[]const *const PanelKind`); ui/contrib.zig aggregates them.
//!
//! Written by W0-A3 with the ADR-6.2 fields so ui/contrib.zig can name
//! the type; W1-6 owns this file and the panel framework behind it.

const std = @import("std");

/// The web panel a kind drives (web/WebPanel.zig).
pub const WebPanel = @import("WebPanel.zig");
const rpc = @import("../rpc/types.zig");

pub const PanelKind = struct {
    /// Kind id (`markdown`), the `kind` of events and the session file.
    id: [:0]const u8,
    /// Asset directory under SHARE\wmux\web\ (usually the id).
    app: [:0]const u8,
    title: *const fn (panel: *WebPanel) []const u8,
    /// Bridge-callable methods (exact names or `prefix.*`); `panel.*` is
    /// implicit.
    allow: []const []const u8,
    /// Event categories pushed to the page.
    events: []const []const u8 = &.{},
    file_access: enum { none, own_file_dir, workspace_root } = .none,
    network: enum { none, consent_remote_images } = .none,
    placements: struct { tab: bool = true, right_sidebar: bool = false, popup: bool = false, window: bool = false } = .{},
    singleton: enum { none, workspace, window, app } = .none,
    create: *const fn (panel: *WebPanel, params: std.json.Value) anyerror!void,
    destroy: ?*const fn (panel: *WebPanel) void = null,
    /// Session snapshot and recently-closed record.
    snapshot: ?*const fn (panel: *WebPanel, w: *std.json.Stringify) anyerror!void = null,
    restore: ?*const fn (panel: *WebPanel, v: std.json.Value) anyerror!void = null,
    /// `panel.<kind>.*` bridge messages; false = unhandled.
    on_message: ?*const fn (panel: *WebPanel, ctx: *rpc.Ctx) rpc.Error!bool = null,
    /// `surface.read_selection`.
    read_selection: ?*const fn (panel: *WebPanel, ctx: *rpc.Ctx) rpc.Error!void = null,
    is_dirty: ?*const fn (panel: *WebPanel) bool = null,
    /// Action ids whose bare keys the page implements (diff j/k, ...).
    page_keymap: []const []const u8 = &.{},
    suspend_after_ms: u32 = 300_000,

    /// A `title` for kinds whose title comes from the page only.
    pub fn noTitle(panel: *WebPanel) []const u8 {
        return panel.title;
    }

    /// A `create` that needs no native setup.
    pub fn noCreate(panel: *WebPanel, params: std.json.Value) anyerror!void {
        _ = panel;
        _ = params;
    }
};
