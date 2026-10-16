//! Command palette providers (ARCHITECTURE.md ADR-8.8). A feature adds
//! palette rows (workspace/surface switcher, recently closed, layouts,
//! settings toggles, custom actions, ...) by declaring
//! `pub const palette_providers = @import("contrib.zig").palette;` (a
//! `[]const PaletteProvider`) in its mod.zig; ui/contrib.zig aggregates
//! them.
//!
//! Written by W0-A3 so the registry can name the type. W2-7 owns
//! ui/palette/**: it defines the row model and the sink a provider fills,
//! and calls the providers when the palette opens.

const std = @import("std");

const App = @import("../../App.zig");
const Window = @import("../Window.zig");

pub const PaletteProvider = struct {
    /// Stable id (`workspaces`, `recently_closed`, `layouts`, ...).
    id: []const u8,
    /// Add this provider's rows for the palette opening over `ctx.window`
    /// (UI thread).
    collect: *const fn (ctx: *Context) anyerror!void,
};

/// What a provider sees when the palette opens.
pub const Context = struct {
    app: *App,
    window: ?*Window,
    /// Lives as long as the open palette.
    arena: std.mem.Allocator,
};
