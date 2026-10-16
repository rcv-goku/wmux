//! Right sidebar modes (ARCHITECTURE.md ADR-11.6). A feature offers a mode
//! of the right sidebar host (files, find, sessions/vault, feed, custom
//! sidebars, the Dock, the legacy status strip) by declaring
//! `pub const right_sidebar_modes = @import("contrib.zig").modes;` (a
//! `[]const RightSidebarMode`) in its mod.zig; ui/contrib.zig aggregates
//! them.
//!
//! Written by W0-A3 so the registry can name the type. W1-8 owns
//! ui/right_sidebar/**: the mode bar and host that create the content.

const Window = @import("../Window.zig");
const WebHost = @import("../../web/WebHost.zig");

pub const RightSidebarMode = struct {
    /// Stable id (`wmux.status`, `files`, `custom:<name>`, ...).
    id: []const u8,
    title: []const u8,
    /// Icon name (ui/icons.zig, W1-8).
    icon: []const u8 = "",
    /// Position in the mode bar (lower first).
    order: u16 = 0,
    /// Create the mode's content for `window` when first shown.
    create: *const fn (window: *Window) anyerror!Content,
};

/// What a mode shows.
pub const Content = union(enum) {
    /// The legacy status strip (mode `wmux.status`, migrated by W1-8).
    legacy_strip,
    /// A web panel host.
    web: *WebHost,
    /// The native Dock (W5).
    dock,
};
