//! Inline rename of a tab title, a workspace name or a workspace
//! description (ARCHITECTURE.md ADR-1.8 W0-A2 step 4). Moved out of
//! Window.zig in W0-A2.

const std = @import("std");

const Sidebar = @import("sidebar/legacy_gdi.zig");
const Window = @import("Window.zig");
const tabbar_paint = @import("tabbar/paint.zig");
const titles = @import("../model/logic/titles.zig");
const w32 = @import("../platform/win32.zig");

/// What an in-progress inline rename writes back to. `.tab` is an index
/// into the tabs of the active workspace's focused pane; `.workspace` is an index into
/// the window's workspaces; `.description` edits a workspace's description.
pub const RenameTarget = union(enum) {
    tab: usize,
    workspace: usize,
    description: usize,
};

/// Rename edit control child ID.
pub const RENAME_EDIT_ID: u16 = 300;

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    const ws = self.activeWorkspace();
    const container = ws.focusedPaneOrFirst() orelse return;
    const tab = container.tabAt(tab_idx) orelse return;
    // The tab's rect in the bar the pane shows (shared geometry). A pane
    // without a visible bar renames through a zero-size overlay, as the
    // never-painted cached rects did before W0-A2.
    const rect = tabbar_paint.tabRect(self, container, tab_idx) orelse
        w32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var buf: [256]u16 = undefined;
    const len = titles.toUtf16(&buf, tab.titleText());
    self.startRename(rect, buf[0..len], .{ .tab = tab_idx });
}

/// Start inline editing of a workspace name. Overlays the Edit control
/// on the workspace's sidebar row and pre-fills it with the current name
/// (empty when the workspace is unnamed — the user types a fresh name).
pub fn renameWorkspace(self: *Window, ws_idx: usize) void {
    // QuickTerminal is single-workspace with no sidebar chrome; it must
    // early-return from every workspace op (matches newWorkspace/
    // closeWorkspace/moveWorkspaceTo/selectWorkspace). Currently
    // unreachable for QT (sidebarWidth()==0 gates every caller), but the
    // guard keeps the invariant explicit against future direct callers.
    if (self.is_quick_terminal) return;
    if (ws_idx >= self.workspaces.items.len) return;
    const wsp = self.workspaces.items[ws_idx];
    const rect = Sidebar.itemRect(ws_idx, self.sidebarWidth(), self.sidebarItemHeight());
    var buf: [Window.Workspace.NAME_MAX_UNITS]u16 = undefined;
    const len = titles.toUtf16(&buf, wsp.name() orelse "");
    self.startRename(rect, buf[0..len], .{ .workspace = ws_idx });
}

/// Start inline editing of a workspace description. Overlays the Edit
/// control on the workspace's sidebar row (same as renameWorkspace but
/// targeting the description field and pre-filled with the current
/// description text, which is empty when no description has been set).
pub fn editWorkspaceDescription(self: *Window, ws_idx: usize) void {
    if (self.is_quick_terminal) return;
    if (ws_idx >= self.workspaces.items.len) return;
    const wsp = self.workspaces.items[ws_idx];
    const rect = Sidebar.itemRect(ws_idx, self.sidebarWidth(), self.sidebarItemHeight());
    var buf: [Window.Workspace.DESCRIPTION_MAX_UNITS]u16 = undefined;
    const len = titles.toUtf16(&buf, wsp.descriptionText());
    self.startRename(rect, buf[0..len], .{ .description = ws_idx });
}

/// Create the inline rename Edit overlay at `rect`, pre-filled with
/// `initial` (a UTF-16 slice), targeting `target`. Shared by tab and
/// workspace rename; finishRename routes the committed text per target.
pub fn startRename(self: *Window, rect: w32.RECT, initial: []const u16, target: RenameTarget) void {
    // Cancel any existing rename
    self.cancelTabRename();

    const hwnd = self.hwnd orelse return;

    // The source slice holds only the valid u16s; CreateWindowExW reads a
    // NUL-terminated wide string, so copy and NUL-terminate so the Edit
    // doesn't display garbage past the real text.
    var text_buf: [257]u16 = undefined;
    const tlen = @min(initial.len, 256);
    @memcpy(text_buf[0..tlen], initial[0..tlen]);
    text_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab/row.
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&text_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_target = target;
}

/// Apply the edit text to the rename target and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const target = self.rename_target;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    const gpa = self.app.core_app.alloc;
    if (wlen > 0) {
        const len: usize = @min(wlen, 255);
        switch (target) {
            .tab => |tab_idx| {
                if (self.activeWorkspace().focusedPaneOrFirst()) |rename_container| {
                    if (rename_container.tabAt(tab_idx)) |tab| {
                        if (std.unicode.wtf16LeToWtf8Alloc(gpa, wbuf[0..len])) |text| {
                            defer gpa.free(text);
                            tab.title.setCustom(gpa, text) catch {};
                        } else |_| {}
                        if (tab_idx == rename_container.selected) self.updateWindowTitle();
                    }
                }
            },
            .workspace => |ws_idx| {
                if (ws_idx < self.workspaces.items.len) {
                    self.workspaces.items[ws_idx].setNameUtf16(gpa, wbuf[0..wlen]) catch {};
                }
            },
            .description => |ws_idx| {
                if (ws_idx < self.workspaces.items.len) {
                    self.workspaces.items[ws_idx].setDescriptionUtf16(gpa, wbuf[0..wlen]) catch {};
                }
            },
        }
    } else {
        // Empty text: for description edits, clear the description
        // (allows the user to remove a description by blanking it).
        switch (target) {
            .description => |ws_idx| {
                if (ws_idx < self.workspaces.items.len) {
                    self.workspaces.items[ws_idx].setDescriptionUtf16(gpa, &.{}) catch {};
                }
            },
            else => {},
        }
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidateTabBar();
    self.invalidateSidebar();

    // Return focus to the active pane
    if (self.getActiveTab()) |p| p.focus();
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        if (self.getActiveTab()) |p| p.focus();
    }
}
