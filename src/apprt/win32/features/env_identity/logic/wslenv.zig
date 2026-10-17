//! WSLENV of a terminal (ARCHITECTURE.md ADR-3.9): the identity variables
//! must reach WSL processes started from a wmux terminal, so the inherited
//! `WSLENV` gets one `NAME/flags` entry per variable (the `CMUX_*` names,
//! then their `WMUX_*` twins, plus `CMUX_SOCKET_PASSWORD/u` when the app
//! exports one). `/u` forwards a value from Win32 into WSL only; `/up`
//! also translates the bundled CLI path into a `/mnt/<drive>/...` path.
//! The entry table and the merge live in `wmux_proto/env_names.zig` (shared
//! with the CLI); this file adds the terminal-side rules. Pure.

const std = @import("std");
const proto = @import("wmux_proto");

const env_names = proto.env_names;
const Allocator = std.mem.Allocator;

/// The entries every terminal appends, in order.
pub const entries = env_names.wslenv_entries;

/// `existing` (the inherited WSLENV, may be null or empty) with our
/// entries appended. Entries naming a variable the user already lists (with
/// any flags) are skipped, so a user's own flags win and nothing is listed
/// twice; the user's entries keep their order. Caller owns the result.
pub fn merge(gpa: Allocator, existing: ?[]const u8, with_password: bool) Allocator.Error![]u8 {
    return env_names.wslenvAppend(gpa, existing, with_password);
}

/// The variable name of a `NAME/flags` entry.
pub fn entryName(entry: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, entry, '/') orelse entry.len;
    return entry[0..slash];
}

/// True when the `:`-separated `list` names `name` (any flags).
pub fn lists(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |seg| {
        if (env_names.eqlEnvName(entryName(seg), name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: env_identity: WSLENV twin list names every CMUX_ id with its WMUX_ twin" {
    // Every WMUX_ twin of a forwarded CMUX_ variable is forwarded with the
    // same flags (CMUX_PANEL_ID and CMUX_TAB_ID have no twin, ADR-3.9).
    var cmux_count: usize = 0;
    for (entries) |e| {
        const name = entryName(e);
        if (!std.mem.startsWith(u8, name, "CMUX_")) continue;
        cmux_count += 1;
        const suffix = name["CMUX_".len..];
        if (std.mem.eql(u8, suffix, "PANEL_ID") or std.mem.eql(u8, suffix, "TAB_ID")) continue;
        var twin_buf: [64]u8 = undefined;
        const twin = try std.fmt.bufPrint(&twin_buf, "WMUX_{s}", .{suffix});
        var found = false;
        for (entries) |t| {
            if (std.mem.eql(u8, entryName(t), twin)) {
                found = true;
                try testing.expectEqualStrings(e[name.len..], t[twin.len..]);
            }
        }
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 9), cmux_count);
    // The identity ids a WSL shell needs.
    const want = [_][]const u8{
        "CMUX_WORKSPACE_ID/u",      "CMUX_SURFACE_ID/u", "CMUX_PANEL_ID/u",
        "CMUX_TAB_ID/u",            "CMUX_PANE_ID/u",    "CMUX_TERMINAL_LIFECYCLE_ID/u",
        "CMUX_SOCKET_PATH/u",       "TERM_PROGRAM/u",    "CMUX_BUNDLED_CLI_PATH/up",
        "WMUX_BUNDLED_CLI_PATH/up",
    };
    for (want) |w| {
        var found = false;
        for (entries) |e| found = found or std.mem.eql(u8, e, w);
        try testing.expect(found);
    }
}

test "unit: env_identity: WSLENV merge appends once and keeps the user's entries" {
    const gpa = testing.allocator;

    const fresh = try merge(gpa, null, false);
    defer gpa.free(fresh);
    try testing.expect(std.mem.startsWith(u8, fresh, "CMUX_WORKSPACE_ID/u:CMUX_SURFACE_ID/u:"));
    try testing.expect(lists(fresh, "WMUX_SURFACE_ID"));
    try testing.expect(!lists(fresh, "CMUX_SOCKET_PASSWORD"));
    try testing.expectEqual(entries.len, std.mem.count(u8, fresh, ":") + 1);

    // The user's entries stay first, in order, with their own flags; empty
    // segments are dropped; a name we forward is not listed twice.
    const merged = try merge(gpa, "FOO/p::CMUX_SURFACE_ID/l:BAR", true);
    defer gpa.free(merged);
    try testing.expect(std.mem.startsWith(u8, merged, "FOO/p:CMUX_SURFACE_ID/l:BAR:CMUX_WORKSPACE_ID/u:"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, merged, "CMUX_SURFACE_ID/"));
    try testing.expect(std.mem.endsWith(u8, merged, ":CMUX_SOCKET_PASSWORD/u"));

    // Merging twice changes nothing (a terminal started from a terminal).
    const again = try merge(gpa, merged, true);
    defer gpa.free(again);
    try testing.expectEqualStrings(merged, again);
}
