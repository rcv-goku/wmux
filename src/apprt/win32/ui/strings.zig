//! User-visible native strings (ARCHITECTURE.md §15.4): every native UI
//! string goes through `tr("feature.key", "English default")`; web panels
//! keep theirs in `src/web/<app>/strings.js`.
//!
//! Written by the W1 kickoff interface commit (W1-IF) so W1 WPs can route
//! their new strings through it from the start; the lookup is a no-op
//! (the English default) until W7-1 adds the JSON catalogs, the language
//! switch and the extraction check. Both arguments are comptime so the
//! extraction check can find every key and default literally.

/// The string for `key` in the current language; today `english`.
pub fn tr(comptime key: []const u8, comptime english: []const u8) []const u8 {
    comptime {
        if (key.len == 0) @compileError("ui/strings.zig: tr() needs a key");
    }
    return english;
}

test "unit: ui: tr returns the English default until W7-1" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Close tab", tr("tabbar.close", "Close tab"));
}
