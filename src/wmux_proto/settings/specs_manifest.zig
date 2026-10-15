//! Settings spec manifest [frozen, merge=union] (ADR-1.4, ADR-5.2): one line
//! per feature spec file, sorted by feature id. A feature file contributes
//! `pub const specs = [_]Spec{ ... };`; `all` concatenates them in manifest
//! order and fails the build on a duplicate path, on a path that is both a
//! setting and a section, or on a malformed spec (`spec.checkComptime`).
//! The path check sorts a copy of the paths, so it stays O(n log n).

const std = @import("std");
const Spec = @import("spec.zig").Spec;
const checkComptime = @import("spec.zig").checkComptime;

pub const modules = .{
    @import("specs/a11y.zig"),
    @import("specs/about.zig"),
    @import("specs/agent_chat.zig"),
    @import("specs/agent_messages.zig"),
    @import("specs/agent_status.zig"),
    @import("specs/agents.zig"),
    @import("specs/auto_naming.zig"),
    @import("specs/automation.zig"),
    @import("specs/browser.zig"),
    @import("specs/browser_profiles.zig"),
    @import("specs/canvas.zig"),
    @import("specs/chrome.zig"),
    @import("specs/comments.zig"),
    @import("specs/context_menus.zig"),
    @import("specs/copy_mode.zig"),
    @import("specs/custom_actions.zig"),
    @import("specs/custom_sidebars.zig"),
    @import("specs/debug.zig"),
    @import("specs/deeplinks.zig"),
    @import("specs/diff.zig"),
    @import("specs/dnd.zig"),
    @import("specs/dock.zig"),
    @import("specs/env_identity.zig"),
    @import("specs/events.zig"),
    @import("specs/feed.zig"),
    @import("specs/file_preview.zig"),
    @import("specs/files_explorer.zig"),
    @import("specs/find.zig"),
    @import("specs/find_in_dir.zig"),
    @import("specs/focus_history.zig"),
    @import("specs/global_search.zig"),
    @import("specs/groups.zig"),
    @import("specs/hibernation.zig"),
    @import("specs/hints.zig"),
    @import("specs/history.zig"),
    @import("specs/i18n.zig"),
    @import("specs/image_paste.zig"),
    @import("specs/install_cli.zig"),
    @import("specs/keep_awake.zig"),
    @import("specs/layouts.zig"),
    @import("specs/markdown.zig"),
    @import("specs/meta.zig"),
    @import("specs/notifications.zig"),
    @import("specs/palette.zig"),
    @import("specs/panes_surfaces.zig"),
    @import("specs/policy.zig"),
    @import("specs/quick_terminal.zig"),
    @import("specs/remote.zig"),
    @import("specs/remote_tmux.zig"),
    @import("specs/resume.zig"),
    @import("specs/session.zig"),
    @import("specs/settings_ui.zig"),
    @import("specs/shortcuts.zig"),
    @import("specs/sleepy_mode.zig"),
    @import("specs/status.zig"),
    @import("specs/sync_input.zig"),
    @import("specs/system.zig"),
    @import("specs/task_manager.zig"),
    @import("specs/terminal_io.zig"),
    @import("specs/textbox.zig"),
    @import("specs/tmux_compat.zig"),
    @import("specs/toasts.zig"),
    @import("specs/todo.zig"),
    @import("specs/tray.zig"),
    @import("specs/updater.zig"),
    @import("specs/vault.zig"),
    @import("specs/windows.zig"),
    @import("specs/workspace_status.zig"),
    @import("specs/workspace_style.zig"),
    @import("specs/workspaces.zig"),
};

/// Every registered setting, in manifest order.
pub const all: []const Spec = aggregate(modules);

/// Concatenates the `specs` of `mods` and runs the comptime checks.
pub fn aggregate(comptime mods: anytype) []const Spec {
    comptime {
        // Sorting keeps the path check O(n log n): about 400 specs stay well
        // inside the registry quota of ARCHITECTURE section 0.4.
        @setEvalBranchQuota(1_000_000);
        var count: usize = 0;
        for (mods) |m| {
            if (@hasDecl(m, "specs")) count += m.specs.len;
        }
        var list: [count]Spec = undefined;
        var paths: [count][]const u8 = undefined;
        var n: usize = 0;
        for (mods) |m| {
            if (!@hasDecl(m, "specs")) continue;
            for (m.specs) |s| {
                checkComptime(s);
                list[n] = s;
                paths[n] = s.path;
                n += 1;
            }
        }
        if (firstClash(&paths)) |c| {
            if (std.mem.eql(u8, c[0], c[1])) @compileError("duplicate settings path '" ++ c[0] ++ "'");
            @compileError("settings paths '" ++ c[0] ++ "' and '" ++ c[1] ++ "': one is a section of the other");
        }
        const final = list;
        return &final;
    }
}

fn isStrictPrefix(section: []const u8, path: []const u8) bool {
    return path.len > section.len and path[section.len] == '.' and std.mem.startsWith(u8, path, section);
}

/// Byte order with '.' below every other byte. Sorted this way, a path
/// sits directly before the paths of its own section ("a", "a.b", "a-b"),
/// so a duplicate or a setting/section pair always ends up adjacent.
fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x != y) return (if (x == '.') 0 else x) < (if (y == '.') 0 else y);
    }
    return a.len < b.len;
}

/// Sorts `paths` and returns the first duplicate or setting/section pair
/// (section first), or null.
fn firstClash(paths: [][]const u8) ?[2][]const u8 {
    std.sort.pdq([]const u8, paths, {}, pathLess);
    var i: usize = 1;
    while (i < paths.len) : (i += 1) {
        const a = paths[i - 1];
        const b = paths[i];
        if (std.mem.eql(u8, a, b) or isStrictPrefix(a, b)) return .{ a, b };
    }
    return null;
}

test {
    inline for (modules) |m| _ = m;
}

test "unit: settings: manifest aggregates feature specs" {
    const a = struct {
        pub const specs = [_]Spec{
            .{ .path = "sidebar.showPorts", .ty = .boolean, .default = "true", .section = "sidebarAppearance", .label = "Show ports", .doc = "" },
        };
    };
    const b = struct {};
    const c = struct {
        pub const specs = [_]Spec{
            .{ .path = "wmux.sidebar.width", .ty = .{ .integer = .{ .min = 120, .max = 600 } }, .default = "220", .section = "sidebarAppearance", .label = "Width", .doc = "", .cmux_compat = false },
            .{ .path = "app.appearance", .ty = .{ .enumeration = &.{ "system", "light", "dark" } }, .default = "\"system\"", .section = "app", .label = "Theme", .doc = "" },
        };
    };
    const agg = comptime aggregate(.{ a, b, c });
    try std.testing.expectEqual(@as(usize, 3), agg.len);
    try std.testing.expectEqualStrings("sidebar.showPorts", agg[0].path);
    try std.testing.expectEqualStrings("app.appearance", agg[2].path);
    try std.testing.expect(!isStrictPrefix("sidebar", "sidebarX.y"));
    try std.testing.expect(isStrictPrefix("sidebar", "sidebar.y"));
    // The real registry is consistent (checked at comptime by `all`).
    _ = all.len;
}

test "unit: settings: manifest path check finds duplicates and sections" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var dup = [_][]const u8{ "a.b", "x.y", "a.b" };
    try expectEqualStrings("a.b", firstClash(&dup).?[0]);
    try expectEqualStrings("a.b", firstClash(&dup).?[1]);
    // '$' and '-' sort below '.' in ASCII; they must not separate "a" from "a.b".
    var sec = [_][]const u8{ "a.b", "a-b.c", "a$.d", "a" };
    try expectEqualStrings("a", firstClash(&sec).?[0]);
    try expectEqualStrings("a.b", firstClash(&sec).?[1]);
    var deep = [_][]const u8{ "zz.q", "a.b.c", "a.bc", "a.b-x", "a.b" };
    try expectEqualStrings("a.b", firstClash(&deep).?[0]);
    try expectEqualStrings("a.b.c", firstClash(&deep).?[1]);
    var ok = [_][]const u8{ "a.b", "a-b.c", "ab.c", "a.c", "sidebar.x", "sidebarX.y", "$schema" };
    try std.testing.expect(firstClash(&ok) == null);
    var none = [_][]const u8{};
    try std.testing.expect(firstClash(&none) == null);
    var one = [_][]const u8{"a"};
    try std.testing.expect(firstClash(&one) == null);
}
