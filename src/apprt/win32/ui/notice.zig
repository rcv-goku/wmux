//! Non-modal notices (ARCHITECTURE.md ADR-5.3, ADR-8.9): the bar a window
//! shows for a settings parse error with its first three errors and
//! "Open", the one-time "keymap changed" notice with a link to the
//! presets, the crash-recovery notice of session restore. A notice never
//! takes focus (G4); `wmux.debug.notices` lists them (W1-4b).
//!
//! Stub written by the W1 kickoff interface commit (W1-IF) with the final
//! signatures, because W1-7a (session restore) raises notices in the same
//! plan sub-wave as W1-4a, which implements the notice UI and store; W1-5a
//! and W1-4b use it a sub-wave later. Until then `show` only logs the
//! notice (the e2e of W1-4a/W1-7a read STATE\logs\wmux.log) and nothing is
//! listed.

const std = @import("std");

const App = @import("../App.zig");

const log = std.log.scoped(.notice);

pub const Level = enum { info, warning, @"error" };

/// What the notice's button does.
pub const Action = struct {
    /// Button text (English, through ui/strings.zig `tr` in W7).
    label: []const u8,
    target: Target,

    pub const Target = union(enum) {
        /// Run a catalog action (`input/actions.zig`), e.g. a preset.
        action: []const u8,
        /// Open a URL or a file through `app/dialogs.openExternal`.
        open: []const u8,
    };
};

pub const Notice = struct {
    /// Stable id (`settings.parse_error`, `shortcuts.keymap_changed`,
    /// `session.crashed`): a later notice with the same id replaces it.
    id: []const u8,
    level: Level = .info,
    title: []const u8,
    body: []const u8 = "",
    action: ?Action = null,
};

/// Show `notice` in every window (UI thread); the strings are copied.
/// Stub: logs it (W1-4a).
pub fn show(app: *App, notice: Notice) void {
    _ = app;
    switch (notice.level) {
        .info => log.info("notice {s}: {s} {s}", .{ notice.id, notice.title, notice.body }),
        .warning => log.warn("notice {s}: {s} {s}", .{ notice.id, notice.title, notice.body }),
        .@"error" => log.err("notice {s}: {s} {s}", .{ notice.id, notice.title, notice.body }),
    }
}

/// Remove the notice `id` if it is shown. Stub: nothing is shown (W1-4a).
pub fn dismiss(app: *App, id: []const u8) void {
    _ = app;
    _ = id;
}

/// The notices shown now, oldest first, borrowed until the next `show` or
/// `dismiss` (UI thread). Stub: none (W1-4a).
pub fn list(app: *const App) []const Notice {
    _ = app;
    return &.{};
}

test "unit: ui: notice stub lists nothing until W1-4a" {
    // The stubs never dereference the app.
    const app: *App = @ptrFromInt(@alignOf(App));
    dismiss(app, "settings.parse_error");
    try std.testing.expectEqual(@as(usize, 0), list(app).len);
}
