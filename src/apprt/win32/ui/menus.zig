//! Context menus of the window (ARCHITECTURE.md ADR-1.6): the tab menu,
//! the workspace row menu, the sidebar gear menu, the backend picker and the
//! default-shell picker. Moved out of Window.zig in W0-A2.

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../../../os/main.zig");
const Pane = @import("../model/Pane.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const Window = @import("Window.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.win32);

// Context menu command IDs.
pub const TAB_CTX_CLOSE: usize = 9001;
pub const TAB_CTX_CLOSE_OTHERS: usize = 9002;
pub const TAB_CTX_CLOSE_RIGHT: usize = 9003;
pub const TAB_CTX_NEW_TAB: usize = 9004;

// Sidebar gear (settings) context menu command IDs.
pub const GEAR_CTX_OPEN_CONFIG: usize = 9201;
pub const GEAR_CTX_OPEN_FOLDER: usize = 9202;
pub const GEAR_CTX_RELOAD: usize = 9203;
// Opens a second popup that writes `command = <choice>` into the user
// config (the default-shell picker). 9410+ avoids every taken range
// (9001-9004/9101-9107/9201-9203/9300-9322/9400 close-pane).
pub const GEAR_CTX_SET_DEFAULT_SHELL: usize = 9410;

// Default-shell picker command IDs (the second popup opened by
// "Set default shell..."). Each writes the chosen program/argv to the
// `command` config key. Installed WSL distros are appended at
// DEFAULT_SHELL_DISTRO_BASE + index, capped below the next reserved ID.
pub const DEFAULT_SHELL_PWSH: usize = 9411;
pub const DEFAULT_SHELL_CMD: usize = 9412;
pub const DEFAULT_SHELL_DISTRO_BASE: usize = 9420;
pub const DEFAULT_SHELL_DISTRO_CAP: usize = 9450;

// Backend picker command IDs (right-click on the sidebar "+ New
// session" row or the tab bar "+" button opens it targeting a new
// tab; the surface context menu's "Split ... With..." entries open it
// targeting a split). Installed WSL distros are appended at
// NEW_SESSION_DISTRO_BASE + index; the Browser entry at 9320 caps the
// distro list so a pathological install count can't collide with it.
pub const NEW_SESSION_DEFAULT: usize = 9300;
pub const NEW_SESSION_PWSH: usize = 9301;
pub const NEW_SESSION_CMD: usize = 9302;
pub const NEW_SESSION_DISTRO_BASE: usize = 9310;
pub const NEW_SESSION_BROWSER: usize = 9320;

/// What a backend-picker menu ID resolves to. Pure mapping from the
/// TrackPopupMenu result (0 = dismissed) and the number of distro
/// entries that were appended; gaps in the ID space and distro IDs at
/// or past the count resolve to .none.
pub const PickerSelection = union(enum) {
    none,
    default,
    pwsh,
    cmd,
    distro: usize,
    browser,
};

pub fn pickerSelection(cmd_id: usize, distro_count: usize) PickerSelection {
    switch (cmd_id) {
        NEW_SESSION_DEFAULT => return .default,
        NEW_SESSION_PWSH => return .pwsh,
        NEW_SESSION_CMD => return .cmd,
        NEW_SESSION_BROWSER => return .browser,
        else => {},
    }
    if (cmd_id < NEW_SESSION_DISTRO_BASE) return .none;
    const idx = cmd_id - NEW_SESSION_DISTRO_BASE;
    if (idx >= distro_count) return .none;
    return .{ .distro = idx };
}

/// Menu label for a WSL distro row: the name, with " (default)"
/// appended for the distro wsl.exe launches without -d. Allocated;
/// caller frees.
pub fn distroMenuLabel(
    alloc: Allocator,
    name: []const u8,
    is_default: bool,
) Allocator.Error![]const u8 {
    return if (is_default)
        std.fmt.allocPrint(alloc, "{s} (default)", .{name})
    else
        alloc.dupe(u8, name);
}

/// Show the tab context menu at client coordinates (x, y). Shared by
/// the tab bar and the sidebar. If clicked_tab is null (empty area),
/// only "New Tab" is shown.
pub fn showTabContextMenu(self: *Window, clicked_tab: ?usize, x: i32, y: i32) void {
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        // Menu-construction reads only; never held across the modal
        // menu loop below (workspaces[] can shift while it pumps).
        const pre_container = self.activeWorkspace().focusedContainerOrFirst();
        const pre_tc = if (pre_container) |c| c.tab_count else 0;
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (pre_tc > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < pre_tc) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatched arbitrary messages: tabs may have
    // closed, workspaces may have shifted (closeWorkspace moves the
    // array under any held pointer), the window may be closing. Re-fetch
    // the active workspace and re-validate the clicked index before
    // acting; closeTabByIndex additionally bounds-checks each call.
    if (self.closing) return;
    const post_container = self.activeWorkspace().focusedContainerOrFirst();
    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                const tc = if (post_container) |c| c.tab_count else return;
                if (tab >= tc) return;
                var current = tab;
                var i: usize = tc;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = if (post_container) |c| c.tab_count else return;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            // Plain New Tab inherits the active pane's backend, same
            // as the tab bar "+" button.
            _ = self.addTabInherit() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}

// Workspace row context-menu command IDs (right-click a sidebar row).
// 9500+ avoids the tab/gear/picker ranges (9001-9450).
pub const WS_CTX_RENAME: usize = 9501;
pub const WS_CTX_CLOSE: usize = 9502;
pub const WS_CTX_NEW: usize = 9503;
pub const WS_CTX_DESCRIPTION: usize = 9504;

/// Show the workspace context menu for the workspace at `ws_idx` at
/// client coordinates (x, y): Rename / Close workspace / New workspace.
pub fn showWorkspaceContextMenu(self: *Window, ws_idx: usize, x: i32, y: i32) void {
    if (self.is_quick_terminal or ws_idx >= self.workspace_count) return;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_RENAME, std.unicode.utf8ToUtf16LeStringLiteral("Rename Workspace"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_DESCRIPTION, std.unicode.utf8ToUtf16LeStringLiteral("Edit Description"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Workspace"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_NEW, std.unicode.utf8ToUtf16LeStringLiteral("New Workspace"));

    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check before
    // acting (a workspace may have closed) and re-validate the index.
    if (self.closing or ws_idx >= self.workspace_count) return;
    switch (@as(usize, @intCast(cmd))) {
        WS_CTX_RENAME => self.renameWorkspace(ws_idx),
        WS_CTX_DESCRIPTION => self.editWorkspaceDescription(ws_idx),
        WS_CTX_CLOSE => self.closeWorkspace(ws_idx),
        WS_CTX_NEW => self.newWorkspace(),
        else => {},
    }
}

/// True if pwsh.exe (PowerShell 7+) is on the executable search path.
pub fn havePwsh() bool {
    var buf: [512]u16 = undefined;
    const n = w32.SearchPathW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe"),
        null,
        buf.len,
        &buf,
        null,
    );
    return n > 0 and n < buf.len;
}

/// Where a backend picked from showBackendMenu opens: a new tab in the
/// active workspace, the first tab of a brand-new workspace, or a
/// split off the active pane in the given direction.
pub const BackendTarget = union(enum) {
    new_tab,
    new_workspace,
    split: SplitTree(Pane).Split.Direction,
};

/// The operation class showBackendMenu performs for a (selection,
/// target) pair: the decision half of the picker dispatch, kept pure
/// so the full selection x target table is unit-testable. The
/// side-effectful half (the switch at the bottom of showBackendMenu)
/// only performs the class chosen here.
pub const BackendDispatch = enum {
    /// Menu dismissed, or a stale/foreign command ID: do nothing.
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

/// Map a backend-picker selection and target to the operation class to
/// perform. Browser is a pane kind rather than a command, so it gets
/// its own classes; every terminal-backed selection (including the
/// configured default) shares the terminal classes.
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

/// Show the backend picker at client coordinates (x, y): "Default" /
/// "PowerShell" / "Command Prompt", each installed WSL distribution
/// (Windows Terminal style), and "Browser" (a WebView2 pane). The
/// selection opens as a new tab, as the first tab of a new workspace,
/// or as a split per `target`; tabs are titled after the picked
/// backend.
pub fn showBackendMenu(self: *Window, x: i32, y: i32, target: BackendTarget) void {
    // Quick terminals exclude picker-created tabs/splits entirely.
    // They have no tab bar or sidebar, so the only QT-reachable call
    // site is the surface "Split ... With..." menu (grayed there too).
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_DEFAULT, std.unicode.utf8ToUtf16LeStringLiteral("Default"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_PWSH, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Enumerate installed distros at menu-open (a cheap registry read)
    // so new installs show up without restarting. Freed after the menu
    // closes; selections copy what they need. Capped to the ID space
    // below NEW_SESSION_BROWSER.
    const all_distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, all_distros);
    const distros = all_distros[0..@min(
        all_distros.len,
        NEW_SESSION_BROWSER - NEW_SESSION_DISTRO_BASE,
    )];

    if (distros.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        for (distros, 0..) |distro, i| {
            const label = distroMenuLabel(alloc, distro.name, distro.is_default) catch continue;
            defer alloc.free(label);

            const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label) catch continue;
            defer alloc.free(label_w);
            _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                NEW_SESSION_DISTRO_BASE + i,
                label_w.ptr,
            );
        }
    }

    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_BROWSER, std.unicode.utf8ToUtf16LeStringLiteral("Browser"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check
    // before acting.
    if (self.closing) return;

    // Resolve the picked backend to an argv (null = the configured
    // default — explicit for splits, which otherwise inherit the
    // source pane's backend) and a tab title. Browser is a pane kind,
    // not a command: its dispatch arms below never read the backend.
    const selection = pickerSelection(@intCast(cmd), distros.len);
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
            .argv = if (havePwsh()) &.{"pwsh.exe"} else &.{"powershell.exe"},
            .title = "PowerShell",
        },
        .cmd => .{ .argv = &.{"cmd.exe"}, .title = "cmd" },
        .distro => |idx| blk: {
            const distro = distros[idx];
            distro_argv = .{ "wsl.exe", "--cd", "~", "-d", distro.name };
            break :blk .{ .argv = &distro_argv, .title = distro.name };
        },
    };

    // The *_split classes only arise from a .split target, so the
    // target.split accesses below are guaranteed by backendDispatch.
    switch (backendDispatch(selection, target)) {
        .dismiss => return,
        .browser_tab => self.addBrowserTab() catch |err| {
            log.err("failed to create browser tab: {}", .{err});
        },
        .browser_workspace => {
            const idx = self.createAndSelectWorkspace() orelse return;
            self.addBrowserTab() catch |err| {
                // Same collapse-the-empty-slot path as newWorkspace:
                // never show a 0-tab workspace.
                log.err("failed to create browser tab for new workspace: {}", .{err});
                self.closeWorkspace(idx);
            };
            self.invalidateSidebar();
        },
        .browser_split => self.newBrowserSplit(target.split) catch |err| {
            log.err("failed to open browser split: {}", .{err});
        },
        .terminal_tab => _ = self.addTabWithCommand(backend.argv, backend.title) catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .terminal_workspace => {
            // Create-and-select FIRST so the picked backend becomes the
            // new workspace's first tab (a .default pick passes
            // null/null, identical to newWorkspace's plain addTab).
            const idx = self.createAndSelectWorkspace() orelse return;
            _ = self.addTabWithCommand(backend.argv, backend.title) catch |err| {
                // Same collapse-the-empty-slot path as newWorkspace:
                // never show a 0-tab workspace.
                log.err("failed to create first tab for new workspace: {}", .{err});
                self.closeWorkspace(idx);
            };
            self.invalidateSidebar();
        },
        .terminal_split => self.newSplitWithCommand(target.split, backend.argv) catch |err| {
            log.err("failed to create split: {}", .{err});
        },
    }
}

/// Show the settings (gear) context menu at client coordinates (x, y).
pub fn showGearContextMenu(self: *Window, x: i32, y: i32) void {
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_OPEN_CONFIG, std.unicode.utf8ToUtf16LeStringLiteral("Open config"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_OPEN_FOLDER, std.unicode.utf8ToUtf16LeStringLiteral("Open config folder"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_RELOAD, std.unicode.utf8ToUtf16LeStringLiteral("Reload config"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_SET_DEFAULT_SHELL, std.unicode.utf8ToUtf16LeStringLiteral("Set default shell..."));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check
    // before acting.
    if (self.closing) return;
    switch (@as(usize, @intCast(cmd))) {
        GEAR_CTX_OPEN_CONFIG => self.app.openConfigFile(),
        GEAR_CTX_OPEN_FOLDER => self.app.openConfigFolder(),
        // Same path as the reload_config keybind: core performAction
        // forwards to the apprt's .reload_config handler.
        GEAR_CTX_RELOAD => self.app.core_app.performAction(
            self.app,
            .reload_config,
        ) catch |err| {
            log.err("failed to reload config: {}", .{err});
        },
        // Open the default-shell picker anchored where the gear menu
        // was. A second popup keeps this off the modal stack of the
        // first (TrackPopupMenuEx has already returned).
        GEAR_CTX_SET_DEFAULT_SHELL => self.showDefaultShellMenu(x, y),
        else => {},
    }
}

/// Resolve a default-shell picker command ID and the distro count that
/// was shown to the config value to write (e.g. "pwsh.exe" or
/// "wsl.exe --cd ~ -d Ubuntu"), or null when the menu was dismissed or
/// the ID is out of range. Pure mapping so it can be unit-tested; the
/// distro value is written into `distro_buf` and the slice returned
/// points into it.
pub fn defaultShellValue(
    cmd_id: usize,
    distros: []const internal_os.wsl.Distro,
    distro_buf: []u8,
) ?[]const u8 {
    switch (cmd_id) {
        DEFAULT_SHELL_PWSH => return if (havePwsh()) "pwsh.exe" else "powershell.exe",
        DEFAULT_SHELL_CMD => return "cmd.exe",
        else => {},
    }
    if (cmd_id < DEFAULT_SHELL_DISTRO_BASE) return null;
    const idx = cmd_id - DEFAULT_SHELL_DISTRO_BASE;
    if (idx >= distros.len) return null;
    // wsl.exe needs the distro selected explicitly so the default shell
    // is deterministic regardless of the WSL default.
    return std.fmt.bufPrint(
        distro_buf,
        "wsl.exe --cd ~ -d {s}",
        .{distros[idx].name},
    ) catch null;
}

/// Show the default-shell picker at client coordinates (x, y):
/// "PowerShell" / "Command Prompt" / each installed WSL distribution.
/// The chosen backend is written to the `command` config key (via
/// App.setDefaultShell), which the default-tab path already honors, and
/// the config is reloaded so it takes effect for new tabs/splits.
pub fn showDefaultShellMenu(self: *Window, x: i32, y: i32) void {
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, DEFAULT_SHELL_PWSH, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, DEFAULT_SHELL_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Enumerate installed distros at menu-open (mirrors showBackendMenu).
    const all_distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, all_distros);
    const distros = all_distros[0..@min(
        all_distros.len,
        DEFAULT_SHELL_DISTRO_CAP - DEFAULT_SHELL_DISTRO_BASE,
    )];

    if (distros.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        for (distros, 0..) |distro, i| {
            const label = distroMenuLabel(alloc, distro.name, distro.is_default) catch continue;
            defer alloc.free(label);
            const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label) catch continue;
            defer alloc.free(label_w);
            _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                DEFAULT_SHELL_DISTRO_BASE + i,
                label_w.ptr,
            );
        }
    }

    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    if (self.closing) return;

    var distro_buf: [512]u8 = undefined;
    const value = defaultShellValue(@intCast(cmd), distros, &distro_buf) orelse return;
    self.app.setDefaultShell(value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: picker selection maps the fixed entries" {
    try testing.expectEqual(PickerSelection.default, pickerSelection(NEW_SESSION_DEFAULT, 0));
    try testing.expectEqual(PickerSelection.pwsh, pickerSelection(NEW_SESSION_PWSH, 0));
    try testing.expectEqual(PickerSelection.cmd, pickerSelection(NEW_SESSION_CMD, 0));
    try testing.expectEqual(PickerSelection.browser, pickerSelection(NEW_SESSION_BROWSER, 0));
}

test "unit: picker selection maps distro ids by index" {
    try testing.expectEqual(PickerSelection{ .distro = 0 }, pickerSelection(NEW_SESSION_DISTRO_BASE, 3));
    try testing.expectEqual(PickerSelection{ .distro = 2 }, pickerSelection(NEW_SESSION_DISTRO_BASE + 2, 3));
    // At or past the appended count: stale or foreign ID, no action.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_DISTRO_BASE + 3, 3));
}

test "unit: picker selection ignores dismissal and unknown ids" {
    // TrackPopupMenu returns 0 when the menu is dismissed.
    try testing.expectEqual(PickerSelection.none, pickerSelection(0, 5));
    // Gaps in the ID space around the distro range.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_CMD + 1, 5));
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_DISTRO_BASE - 1, 5));
    // The Surface "Split ... With..." IDs (9321/9322) live above the
    // browser entry and must not resolve here.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_BROWSER + 1, 5));
}

test "unit: picker browser id can never be claimed by a distro" {
    // The call site caps the distro list below NEW_SESSION_BROWSER;
    // even an uncapped count must resolve 9320 to browser, with the
    // last representable distro index directly below it.
    try testing.expectEqual(PickerSelection.browser, pickerSelection(NEW_SESSION_BROWSER, 64));
    const cap = NEW_SESSION_BROWSER - NEW_SESSION_DISTRO_BASE;
    try testing.expectEqual(
        PickerSelection{ .distro = cap - 1 },
        pickerSelection(NEW_SESSION_BROWSER - 1, cap),
    );
}

test "unit: picker menu ids match the reserved registry" {
    // 9300-9302 shells, 9310-9319 distros, 9320 browser (see the menu
    // ID comment block); a change here collides with other menus.
    try testing.expectEqual(@as(usize, 9300), NEW_SESSION_DEFAULT);
    try testing.expectEqual(@as(usize, 9301), NEW_SESSION_PWSH);
    try testing.expectEqual(@as(usize, 9302), NEW_SESSION_CMD);
    try testing.expectEqual(@as(usize, 9310), NEW_SESSION_DISTRO_BASE);
    try testing.expectEqual(@as(usize, 9320), NEW_SESSION_BROWSER);
}

test "unit: distro menu label formats the default marker" {
    const alloc = testing.allocator;
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", false);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04", label);
    }
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", true);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04 (default)", label);
    }
}

test "unit: default-shell value maps the fixed shells" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{};

    // cmd is deterministic.
    try testing.expectEqualStrings(
        "cmd.exe",
        defaultShellValue(DEFAULT_SHELL_CMD, distros, &buf).?,
    );

    // pwsh resolves to one of the two PowerShell exes depending on
    // whether PowerShell 7 is installed on the test host.
    const pwsh = defaultShellValue(DEFAULT_SHELL_PWSH, distros, &buf).?;
    try testing.expect(
        std.mem.eql(u8, pwsh, "pwsh.exe") or
            std.mem.eql(u8, pwsh, "powershell.exe"),
    );
}

test "unit: default-shell value formats the distro argv" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
        .{ .name = "Debian", .guid = "{y}", .is_default = false, .version = 2 },
    };
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Ubuntu",
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE, distros, &buf).?,
    );
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Debian",
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE + 1, distros, &buf).?,
    );
}

test "unit: default-shell value ignores dismissal and out-of-range ids" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
    };
    // Dismissal (0) and ids in gaps / past the distro count.
    try testing.expectEqual(@as(?[]const u8, null), defaultShellValue(0, distros, &buf));
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE - 1, distros, &buf),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE + 1, distros, &buf),
    );
}

test "unit: default-shell menu ids match the reserved registry" {
    // 9410 set-default entry, 9411/9412 shells, 9420+ distros capped at
    // 9450 (see the menu ID comment block). A change here risks a
    // collision with another menu's IDs.
    try testing.expectEqual(@as(usize, 9410), GEAR_CTX_SET_DEFAULT_SHELL);
    try testing.expectEqual(@as(usize, 9411), DEFAULT_SHELL_PWSH);
    try testing.expectEqual(@as(usize, 9412), DEFAULT_SHELL_CMD);
    try testing.expectEqual(@as(usize, 9420), DEFAULT_SHELL_DISTRO_BASE);
    try testing.expectEqual(@as(usize, 9450), DEFAULT_SHELL_DISTRO_CAP);
}

test "unit: picker boundary ids 9319 and 9320 resolve by raw value" {
    // 9319 is the last distro slot and 9320 the browser entry; raw
    // numeric IDs so a constant edit that shifts the boundary fails
    // here even if the registry test is updated to match.
    try testing.expectEqual(PickerSelection{ .distro = 9 }, pickerSelection(9319, 10));
    try testing.expectEqual(PickerSelection.browser, pickerSelection(9320, 10));
    // One short of a full menu: 9319 is then a stale ID.
    try testing.expectEqual(PickerSelection.none, pickerSelection(9319, 9));
}

test "unit: default-shell distro ids at the reserved cap boundary" {
    var buf: [512]u8 = undefined;
    // The call site appends at most CAP - BASE distros, so the largest
    // menu ID ever generated is DISTRO_CAP - 1. With a list filled to
    // exactly that cap, the last in-range ID resolves and the cap ID
    // (and anything above) does not.
    const cap = DEFAULT_SHELL_DISTRO_CAP - DEFAULT_SHELL_DISTRO_BASE;
    var distros: [cap]internal_os.wsl.Distro = undefined;
    for (&distros) |*d| d.* = .{
        .name = "Edge",
        .guid = "{g}",
        .is_default = false,
        .version = 2,
    };
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Edge",
        defaultShellValue(DEFAULT_SHELL_DISTRO_CAP - 1, &distros, &buf).?,
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_CAP, &distros, &buf),
    );
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
