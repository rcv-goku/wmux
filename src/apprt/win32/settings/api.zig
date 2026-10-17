//! Public API of the settings layer (ARCHITECTURE.md ADR-5): the
//! `cmux.json`/`wmux.json` layering, the typed snapshot, the watcher and
//! the Ghostty overlay. App.init calls `init` once the app struct exists
//! and before any window is created; App.terminate calls `deinit`.
//!
//! Stubs written by W0-A3 (pre-wiring); W1-4 implements the layer (it
//! owns settings/**). Until then the Ghostty configuration (`App.config`)
//! is the only configuration.
//!
//! `get` was added by the W1 kickoff interface commit (W1-IF) with its
//! final signature (ADR-5.2: "until W1-4 lands, `settings.get` returns
//! spec defaults, so W1 WPs can already declare and read their keys"):
//! W1-1a, W1-3 and W1-7a read their keys in the same plan sub-wave as
//! W1-4a, which replaces the body with a read of the current snapshot.

const std = @import("std");
const proto = @import("wmux_proto");

const App = @import("../App.zig");

const Spec = proto.settings.spec.Spec;
const specs_manifest = proto.settings.specs_manifest;

/// Load the settings layers and start the watcher. Nothing yet.
pub fn init(app: *App) !void {
    _ = app;
}

/// Stop the watcher and free the settings. Nothing yet.
pub fn deinit(app: *App) void {
    _ = app;
}

/// The Zig type `get` returns for the setting at `path` (a compile error
/// for an unknown path): `bool` for booleans, `i64` for integers, `f64`
/// for numbers, the string (without quotes) for strings, enumerations,
/// colors and paths, and the JSON text for string lists, objects and
/// strokes.
pub fn Value(comptime path: []const u8) type {
    return ValueIn(specs_manifest.all, path);
}

/// The effective value of the setting at `path` for `app` (UI thread;
/// worker threads take a snapshot reference, W1-4a). A path that no spec
/// declares is a compile error. Stub: the spec default (W1-4a).
pub fn get(app: *const App, comptime path: []const u8) Value(path) {
    _ = app;
    return comptime defaultIn(specs_manifest.all, path);
}

/// `Value` over an explicit spec list (tests, W1-4a).
pub fn ValueIn(comptime specs: []const Spec, comptime path: []const u8) type {
    const s = comptime findSpec(specs, path);
    return switch (s.ty) {
        .boolean => bool,
        .integer => i64,
        .number => f64,
        .string, .enumeration, .color, .path => []const u8,
        .string_list, .object, .strokes => []const u8,
    };
}

/// The default of the setting at `path` in `specs`, typed as `ValueIn`.
pub fn defaultIn(comptime specs: []const Spec, comptime path: []const u8) ValueIn(specs, path) {
    comptime {
        const s = findSpec(specs, path);
        const lit = std.mem.trim(u8, s.default, " \t\r\n");
        return switch (s.ty) {
            .boolean => std.mem.eql(u8, lit, "true"),
            .integer => std.fmt.parseInt(i64, lit, 10) catch @compileError("settings: integer default of '" ++ path ++ "'"),
            .number => std.fmt.parseFloat(f64, lit) catch @compileError("settings: number default of '" ++ path ++ "'"),
            .string, .enumeration, .color, .path => unquote(path, lit),
            .string_list, .object, .strokes => lit,
        };
    }
}

fn findSpec(comptime specs: []const Spec, comptime path: []const u8) Spec {
    comptime {
        @setEvalBranchQuota(100_000);
        for (specs) |s| {
            if (std.mem.eql(u8, s.path, path)) return s;
        }
        @compileError("settings: no spec declares '" ++ path ++ "' (wmux_proto/settings/specs/*.zig)");
    }
}

/// A JSON string literal without its quotes (spec defaults are validated
/// at comptime; escapes are not expected in string defaults).
fn unquote(comptime path: []const u8, comptime lit: []const u8) []const u8 {
    comptime {
        if (lit.len < 2 or lit[0] != '"' or lit[lit.len - 1] != '"')
            @compileError("settings: string default of '" ++ path ++ "' is not a JSON string");
        const inner = lit[1 .. lit.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') != null)
            @compileError("settings: escaped string default of '" ++ path ++ "' (extend unquote)");
        return inner;
    }
}

test "unit: settings: get returns spec defaults until the layer lands" {
    const specs = [_]Spec{
        .{ .path = "sidebar.showPorts", .ty = .boolean, .default = "true", .section = "sidebarAppearance", .label = "Show ports", .doc = "" },
        .{ .path = "wmux.sidebar.width", .ty = .{ .integer = .{ .min = 120, .max = 600 } }, .default = "220", .section = "sidebarAppearance", .label = "Width", .doc = "", .cmux_compat = false },
        .{ .path = "app.appearance", .ty = .{ .enumeration = &.{ "system", "light", "dark" } }, .default = "\"system\"", .section = "app", .label = "Theme", .doc = "" },
        .{ .path = "x.opacity", .ty = .{ .number = .{ .min = 0, .max = 1 } }, .default = "0.5", .section = "app", .label = "Opacity", .doc = "" },
        .{ .path = "x.list", .ty = .string_list, .default = "[\"a\"]", .section = "app", .label = "List", .doc = "" },
    };
    const testing = std.testing;
    try testing.expect(ValueIn(&specs, "sidebar.showPorts") == bool);
    try testing.expectEqual(true, comptime defaultIn(&specs, "sidebar.showPorts"));
    try testing.expectEqual(@as(i64, 220), comptime defaultIn(&specs, "wmux.sidebar.width"));
    try testing.expectEqualStrings("system", comptime defaultIn(&specs, "app.appearance"));
    try testing.expectEqual(@as(f64, 0.5), comptime defaultIn(&specs, "x.opacity"));
    try testing.expectEqualStrings("[\"a\"]", comptime defaultIn(&specs, "x.list"));
}
