//! Legacy Ghostty keys as the settings layer's second layer (ARCHITECTURE.md
//! ADR-5.1 row 2): only keys **explicitly set** in the user's Ghostty
//! configuration count. Ghostty records every argument it parsed (files,
//! includes, CLI) as a replay step, and never one for a default, so the
//! steps are exactly the explicit keys. The mapping itself is
//! `wmux_proto/settings/resolve.zig` `legacy_ghostty_keys`.

const std = @import("std");
const proto = @import("wmux_proto");

const configpkg = @import("../../../config.zig");
const layers = @import("logic/layers.zig");

const Allocator = std.mem.Allocator;
const resolve = proto.settings.resolve;

/// The explicitly set legacy keys of `config`, in parse order (later
/// wins), as pairs whose strings live in `arena`. Conditional steps
/// (`theme = light:x,dark:y` expansions) are not legacy keys and are
/// skipped.
pub fn collect(arena: Allocator, config: *const configpkg.Config) Allocator.Error![]layers.GhosttyPair {
    var out: std.ArrayList(layers.GhosttyPair) = .empty;
    for (config._replay_steps.items) |step| {
        const arg: []const u8 = switch (step) {
            .arg => |a| a,
            else => continue,
        };
        const pair = layers.parseGhosttyArg(arg) orelse continue;
        if (resolve.legacyGhosttyKey(pair.key) == null) continue;
        try out.append(arena, .{ .key = try arena.dupe(u8, pair.key), .value = try arena.dupe(u8, pair.value) });
    }
    return out.toOwnedSlice(arena);
}

/// Order-sensitive fingerprint of collected pairs: the watcher reloads the
/// JSON layers only when the legacy layer changed.
pub fn fingerprint(pairs: []const layers.GhosttyPair) u64 {
    var h = std.hash.Wyhash.init(0x6c6567);
    for (pairs) |p| {
        h.update(p.key);
        h.update("=");
        h.update(p.value);
        h.update("\n");
    }
    return h.final();
}

test "unit: settings: legacy keys come from replay steps, never defaults" {
    const gpa = std.testing.allocator;
    var cfg = try configpkg.Config.default(gpa);
    defer cfg.deinit();
    // A default config has no replay steps for legacy keys.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try collect(a, &cfg)).len);

    // Explicit lines become pairs (Config.loadIter records replay steps).
    var it = LineIter{ .lines = &.{ "--window-sidebar-width=260", "--font-size=13", "--socket-control=off" } };
    try cfg.loadIter(gpa, &it);
    const pairs = try collect(a, &cfg);
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("window-sidebar-width", pairs[0].key);
    try std.testing.expectEqualStrings("260", pairs[0].value);
    try std.testing.expectEqualStrings("socket-control", pairs[1].key);
    try std.testing.expect(fingerprint(pairs) != fingerprint(pairs[0..1]));
}

const LineIter = struct {
    lines: []const [:0]const u8,
    i: usize = 0,

    pub fn next(self: *LineIter) ?[:0]const u8 {
        if (self.i >= self.lines.len) return null;
        defer self.i += 1;
        return self.lines[self.i];
    }
};
