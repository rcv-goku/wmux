//! Settings spec manifest [frozen, merge=union] (ADR-1.4, ADR-5.2): one line
//! per feature spec file, sorted by feature id. A feature file contributes
//! `pub const specs = [_]Spec{ ... };`; `all` concatenates them in manifest
//! order and fails the build on a duplicate path, on a path that is both a
//! setting and a section, or on a malformed spec (`spec.checkComptime`).

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
        @setEvalBranchQuota(20_000_000);
        var count: usize = 0;
        for (mods) |m| {
            if (@hasDecl(m, "specs")) count += m.specs.len;
        }
        var list: [count]Spec = undefined;
        var n: usize = 0;
        for (mods) |m| {
            if (!@hasDecl(m, "specs")) continue;
            for (m.specs) |s| {
                checkComptime(s);
                list[n] = s;
                n += 1;
            }
        }
        for (list, 0..) |a, i| {
            for (list[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.path, b.path))
                    @compileError("duplicate settings path '" ++ a.path ++ "'");
                if (isStrictPrefix(a.path, b.path) or isStrictPrefix(b.path, a.path))
                    @compileError("settings paths '" ++ a.path ++ "' and '" ++ b.path ++ "': one is a section of the other");
            }
        }
        const final = list;
        return &final;
    }
}

fn isStrictPrefix(section: []const u8, path: []const u8) bool {
    return path.len > section.len and path[section.len] == '.' and std.mem.startsWith(u8, path, section);
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
