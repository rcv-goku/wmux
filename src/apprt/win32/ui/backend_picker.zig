//! The backend picker (ARCHITECTURE.md ADR-1.6, site `new_button`):
//! "Default" / "PowerShell" / "Command Prompt", each installed WSL
//! distribution (Windows Terminal style) and "Browser" (a WebView2 pane).
//! Opened by the tab bar "+▾", the sidebar "+ New workspace ▾" and the
//! terminal menu's "Split ... With..."; the pick opens as a new tab, as
//! the first tab of a new workspace, or as a split (Context.backend_target),
//! titled after the backend.

const std = @import("std");

const Pane = @import("../model/Pane.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const chrome = @import("chrome.zig");
const menus = @import("menus.zig");
const ops_pane = @import("../model/ops/pane.zig");
const ops_surface = @import("../model/ops/surface.zig");
const ops_window = @import("../model/ops/window.zig");

const log = std.log.scoped(.win32);

const Context = menus.Context;

/// Where a backend picked from the picker opens: a new tab in the active
/// workspace, the first tab of a brand-new workspace, or a split off the
/// active pane in the given direction.
pub const BackendTarget = union(enum) {
    new_tab,
    new_workspace,
    split: SplitTree(Pane).Split.Direction,
};

/// A picker row.
pub const PickerSelection = union(enum) {
    none,
    default,
    pwsh,
    cmd,
    distro: usize,
    browser,
};

pub const menu_items = [_]menus.MenuItem{
    .{ .site = .new_button, .group = 0, .order = 0, .title = "Default", .callback = pick, .arg = selectionArg(.default) },
    .{ .site = .new_button, .group = 0, .order = 1, .title = "PowerShell", .callback = pick, .arg = selectionArg(.pwsh) },
    .{ .site = .new_button, .group = 0, .order = 2, .title = "Command Prompt", .callback = pick, .arg = selectionArg(.cmd) },
    .{ .site = .new_button, .group = 2, .order = 0, .title = "Browser", .callback = pick, .arg = selectionArg(.browser) },
};

/// One row per installed WSL distribution, between the shells and
/// Browser (no cap: the rows no longer live in a reserved id range).
pub fn menuEntries(b: *menus.MenuBuilder) std.mem.Allocator.Error!void {
    if (b.site != .new_button) return;
    for (b.ctx.distros, 0..) |distro, i| {
        try b.addEntry(.{
            .group = 1,
            .order = @intCast(@min(i, std.math.maxInt(u16))),
            .title = try menus.distroMenuLabel(b.allocator(), distro.name, distro.is_default),
            .callback = pick,
            .arg = selectionArg(.{ .distro = i }),
        });
    }
}

/// Encode a selection as a menu item argument (distro index + 5).
pub fn selectionArg(selection: PickerSelection) usize {
    return switch (selection) {
        .none => 0,
        .default => 1,
        .pwsh => 2,
        .cmd => 3,
        .browser => 4,
        .distro => |i| i + 5,
    };
}

pub fn selectionFromArg(arg: usize) PickerSelection {
    return switch (arg) {
        0 => .none,
        1 => .default,
        2 => .pwsh,
        3 => .cmd,
        4 => .browser,
        else => .{ .distro = arg - 5 },
    };
}

/// The operation class the picker performs for a (selection, target)
/// pair: the decision half of the picker dispatch, kept pure so the full
/// selection x target table is unit-testable. `pick` only performs the
/// class chosen here.
pub const BackendDispatch = enum {
    /// Menu dismissed, or a stale selection: do nothing.
    dismiss,
    /// Browser pane as a new tab in the active workspace.
    browser_tab,
    /// Browser pane as the first tab of a brand-new workspace.
    browser_workspace,
    /// Browser pane as a split off the active pane.
    browser_split,
    /// Terminal (with the resolved argv/title) as a new tab.
    terminal_tab,
    /// Terminal as the first tab of a brand-new workspace.
    terminal_workspace,
    /// Terminal as a split off the active pane.
    terminal_split,
};

/// Map a picker selection and target to the operation class to perform.
/// Browser is a pane kind rather than a command, so it gets its own
/// classes; every terminal-backed selection (including the configured
/// default) shares the terminal classes.
pub fn backendDispatch(
    selection: PickerSelection,
    target: BackendTarget,
) BackendDispatch {
    return switch (selection) {
        .none => .dismiss,
        .browser => switch (target) {
            .new_tab => .browser_tab,
            .new_workspace => .browser_workspace,
            .split => .browser_split,
        },
        .default, .pwsh, .cmd, .distro => switch (target) {
            .new_tab => .terminal_tab,
            .new_workspace => .terminal_workspace,
            .split => .terminal_split,
        },
    };
}

/// Open the picked backend per the context's target.
fn pick(ctx: *Context, arg: usize) void {
    const self = ctx.window;
    const selection = selectionFromArg(arg);
    const target = ctx.backend_target;

    // Resolve the picked backend to an argv (null = the configured
    // default — explicit for splits, which otherwise inherit the
    // source pane's backend) and a tab title. Browser is a pane kind,
    // not a command: its dispatch arms below never read the backend.
    const Backend = struct {
        argv: ?[]const []const u8,
        title: ?[]const u8,
    };
    var distro_argv: [5][]const u8 = undefined;
    const backend: Backend = switch (selection) {
        // .none dispatches to .dismiss and .browser to the browser
        // classes, none of which reads the backend; null/null is the
        // same harmless value .default resolves to.
        .none, .browser, .default => .{ .argv = null, .title = null },
        .pwsh => .{
            .argv = if (menus.havePwsh()) &.{"pwsh.exe"} else &.{"powershell.exe"},
            .title = "PowerShell",
        },
        .cmd => .{ .argv = &.{"cmd.exe"}, .title = "cmd" },
        .distro => |idx| blk: {
            if (idx >= ctx.distros.len) return;
            const distro = ctx.distros[idx];
            distro_argv = .{ "wsl.exe", "--cd", "~", "-d", distro.name };
            break :blk .{ .argv = &distro_argv, .title = distro.name };
        },
    };

    // The *_split classes only arise from a .split target, so the
    // target.split accesses below are guaranteed by backendDispatch.
    switch (backendDispatch(selection, target)) {
        .dismiss => return,
        .browser_tab => ops_surface.addBrowserTab(self) catch |err| {
            log.err("failed to create browser tab: {}", .{err});
        },
        .browser_workspace => {
            const idx = ops_window.createAndSelectWorkspace(self) orelse return;
            ops_surface.addBrowserTab(self) catch |err| {
                // Same collapse-the-empty-workspace path as newWorkspace:
                // never show a 0-tab workspace.
                log.err("failed to create browser tab for new workspace: {}", .{err});
                ops_window.closeWorkspace(self, idx);
            };
            chrome.invalidateSidebar(self);
        },
        .browser_split => ops_pane.newBrowserSplit(self, target.split) catch |err| {
            log.err("failed to open browser split: {}", .{err});
        },
        .terminal_tab => _ = ops_surface.addTabWithCommand(self, backend.argv, backend.title) catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .terminal_workspace => {
            // Create-and-select FIRST so the picked backend becomes the
            // new workspace's first tab (a .default pick passes
            // null/null, identical to newWorkspace's plain addTab).
            const idx = ops_window.createAndSelectWorkspace(self) orelse return;
            _ = ops_surface.addTabWithCommand(self, backend.argv, backend.title) catch |err| {
                // Same collapse-the-empty-workspace path as newWorkspace:
                // never show a 0-tab workspace.
                log.err("failed to create first tab for new workspace: {}", .{err});
                ops_window.closeWorkspace(self, idx);
            };
            chrome.invalidateSidebar(self);
        },
        .terminal_split => ops_pane.newSplitWithCommand(self, target.split, backend.argv) catch |err| {
            log.err("failed to create split: {}", .{err});
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: ui: backend picker args round-trip every selection" {
    const selections = [_]PickerSelection{
        .none, .default, .pwsh, .cmd, .browser, .{ .distro = 0 }, .{ .distro = 63 },
    };
    for (selections) |selection| {
        try testing.expectEqual(selection, selectionFromArg(selectionArg(selection)));
    }
}

test "unit: backend dispatch maps every selection and target pair" {
    const selections = [_]PickerSelection{
        .none, .default, .pwsh, .cmd, .{ .distro = 0 }, .browser,
    };
    const targets = [_]BackendTarget{
        .new_tab, .new_workspace, .{ .split = .right },
    };
    // Rows follow `selections`, columns follow `targets`.
    const expected = [_][3]BackendDispatch{
        .{ .dismiss, .dismiss, .dismiss },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .browser_tab, .browser_workspace, .browser_split },
    };
    for (selections, expected) |sel, row| {
        for (targets, row) |tgt, want| {
            try testing.expectEqual(want, backendDispatch(sel, tgt));
        }
    }
}

test "unit: backend dispatch ignores split direction and distro index" {
    // The split payload picks WHERE the split goes, never WHAT class
    // of operation runs; same for which distro index was picked.
    const dirs = [_]SplitTree(Pane).Split.Direction{ .left, .right, .down, .up };
    for (dirs) |dir| {
        try testing.expectEqual(
            BackendDispatch.terminal_split,
            backendDispatch(.default, .{ .split = dir }),
        );
        try testing.expectEqual(
            BackendDispatch.browser_split,
            backendDispatch(.browser, .{ .split = dir }),
        );
    }
    try testing.expectEqual(
        BackendDispatch.terminal_workspace,
        backendDispatch(.{ .distro = 63 }, .new_workspace),
    );
}
