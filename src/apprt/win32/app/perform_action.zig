//! The exhaustive switch over `apprt.Action`: Ghostty core → win32 apprt
//! action reactions. Every arm is a one-line delegation to the code that
//! owns the reaction: a Window/Surface method, a feature `api.zig`, a
//! layer module, or (for arms whose owner arrives in W0-A2/W1) one of the
//! private helpers below, which hold the original arm bodies verbatim.
//!
//! Moved out of `App.performAction` in W0-A1 (ARCHITECTURE.md ADR-1.6).
//! Later WPs re-point individual arms to their feature's `api.zig`
//! (e.g. `.pwd` → `features/meta/api.zig`, W1-7); nobody adds behavior
//! inline here.

const std = @import("std");

const apprt = @import("../../../apprt.zig");
const App = @import("../App.zig");
const Pane = @import("../model/Pane.zig");
const QuickTerminal = @import("../features/quick_terminal/QuickTerminal.zig");
const SessionState = @import("../features/session/legacy_v2.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../Surface.zig");
const Window = @import("../Window.zig");
const config_files = @import("../settings/legacy_config_files.zig");
const foreground = @import("foreground.zig");
const notifications = @import("../features/notifications/api.zig");
const updater = @import("../features/updater/legacy_check.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.win32);

/// Perform an apprt action (`App.performAction`). Every action is
/// acknowledged (returns true) whether or not it has a win32 reaction.
pub fn perform(
    app: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => quit(app),
        .new_window => newWindow(app, target),
        .set_title => if (rtSurface(target)) |s| s.setTitle(value.title),
        .ring_bell => notifications.onBell(app, target),
        .quit_timer => switch (value) {
            .start => app.startQuitTimer(),
            .stop => app.stopQuitTimer(),
        },
        .config_change => configChange(app, value),
        .toggle_fullscreen => if (rtSurface(target)) |s| s.toggleFullscreen(),
        .toggle_maximize => toggleMaximize(app, target),
        // Close the entire window (all tabs), not just one tab.
        .close_window => if (parentWindow(target)) |w| w.close(),
        .open_config => config_files.openConfigFile(app),
        .scrollbar => if (rtSurface(target)) |s| s.setScrollbar(value),
        .mouse_shape => if (rtSurface(target)) |s| s.setMouseShape(value),
        .open_url => openUrl(value),
        // The cursor shape change is handled separately by mouse_shape →
        // IDC_HAND. We could show the URL in a status bar or tooltip here
        // in the future.
        .mouse_over_link => {},
        .start_search => if (rtSurface(target)) |s| s.setSearchActive(true, value.needle),
        .end_search => if (rtSurface(target)) |s| s.setSearchActive(false, ""),
        // We could display the match count in the search bar in the future.
        .search_total, .search_selected => {},
        .desktop_notification => notifications.showDesktopNotification(app, target, value),
        .new_tab => newTab(target),
        .close_tab => if (rtSurface(target)) |s| s.parent_window.closeTabMode(value, s),
        .goto_tab => if (parentWindow(target)) |w| {
            _ = w.selectTab(value);
        },
        .set_tab_title => if (rtSurface(target)) |s| s.parent_window.onTabTitleChanged(s, value.title),
        .move_tab => if (parentWindow(target)) |w| w.moveTab(value.amount),
        .toggle_tab_overview => {},
        .toggle_sidebar => if (parentWindow(target)) |w| w.toggleSidebar(),
        .save_session => saveSession(app),
        .edit_workspace_description => if (parentWindow(target)) |w| w.editWorkspaceDescription(w.active_workspace),
        .toggle_right_sidebar => if (parentWindow(target)) |w| w.toggleRightSidebar(),
        .restore_session => restoreSession(app),
        .focus_right_sidebar => if (parentWindow(target)) |w| w.focusRightSidebar(),
        .initial_size => initialSize(app, target, value),
        .reload_config => config_files.reloadConfig(app, value.soft),
        .show_child_exited => notifications.onChildExited(app, target, value),
        .toggle_window_decorations => if (rtSurface(target)) |s| s.toggleWindowDecorations(),
        // Close all surfaces: the core tracks surfaces; iterate via quit.
        .close_all_windows => quit(app),
        .toggle_background_opacity => toggleBackgroundOpacity(app, target),
        // With no tab bar, each "tab" is a window: goto_window and
        // goto_tab behave the same. Just acknowledge.
        .goto_window => {},
        .reset_window_size => resetWindowSize(app, target),
        .copy_title_to_clipboard => copyTitleToClipboard(app, target),
        .render => render(target),

        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        .renderer_health,
        .key_sequence,
        .key_table,
        .pwd,
        .cell_size,
        .progress_report,
        .readonly,
        .selection_changed, // No accessibility consumer on Win32 yet
        // Platform-specific actions that don't apply on Windows:
        .secure_input, // macOS EnableSecureEventInput
        .undo, // macOS NSUndoManager
        .redo, // macOS NSUndoManager
        .show_gtk_inspector, // GTK-only
        .show_on_screen_keyboard, // GTK/mobile
        .inspector, // Not yet implemented (debug overlay)
        .render_inspector, // Not yet implemented (debug overlay)
        => {},

        .color_change => colorChange(app, value),
        .size_limit => sizeLimit(target, value),
        .toggle_visibility => toggleVisibility(app),
        .float_window => floatWindow(target, value),
        .command_finished => notifications.onCommandFinished(app, target, value),
        .mouse_visibility => mouseVisibility(target, value),
        .present_terminal => presentTerminal(app, target),
        .new_split => newSplit(target, value),
        .goto_split => if (parentWindow(target)) |w| w.gotoSplit(value),
        .swap_split => if (parentWindow(target)) |w| w.swapSplit(value),
        .resize_split => if (parentWindow(target)) |w| w.resizeSplit(value),
        .equalize_splits => if (parentWindow(target)) |w| w.equalizeSplits(),
        .select_layout => if (parentWindow(target)) |w| w.selectLayout(value),
        .toggle_split_zoom => if (parentWindow(target)) |w| w.toggleSplitZoom(),
        .toggle_synchronized_input => if (parentWindow(target)) |w| w.toggleSynchronizedInput(),
        .break_pane => if (rtSurface(target)) |s| if (s.tab) |tab| s.parent_window.breakPane(tab),
        .move_pane => if (rtSurface(target)) |s| if (s.tab) |tab| s.parent_window.movePaneToTab(tab, value),
        .prompt_title => promptTitle(target),
        .check_for_updates => updater.startUpdateCheck(app),
        .toggle_command_palette => if (rtSurface(target)) |s| s.setCommandPaletteActive(!s.palette_active),
        .toggle_quick_terminal => toggleQuickTerminal(app),
        .flash_pane => if (parentWindow(target)) |w| w.flashFocusedPane(),
        // Toggle the most recent notification's read state. Display
        // index 0 is the newest entry.
        .toggle_notification_unread => {
            _ = notifications.toggleNotifRead(app, 0);
        },
        .mark_oldest_unread_jump => {
            _ = notifications.markOldestUnreadAndJumpNext(app);
        },
    }
    return true;
}

/// The apprt surface a surface-targeted action addresses, or null for an
/// app-targeted action (which every surface-scoped arm ignores).
fn rtSurface(target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |core_surface| core_surface.rt_surface,
    };
}

/// The window owning the addressed surface, or null for an app target.
fn parentWindow(target: apprt.Target) ?*Window {
    const surface = rtSurface(target) orelse return null;
    return surface.parent_window;
}

// ---------------------------------------------------------------------------
// Arm bodies moved verbatim from App.performAction (W0-A1). W0-A2 and the
// W1/W2 owners re-home them (ui/Window.zig, features/windows, ...).
// ---------------------------------------------------------------------------

fn quit(self: *App) void {
    self.quit_requested = true;
    w32.PostQuitMessage(0);
}

fn newWindow(self: *App, target: apprt.Target) void {
    // Inherit opacity-toggle state from the parent window: if the
    // user toggled it to opaque via toggle_background_opacity, the
    // new window should start opaque too. Mirrors macOS behavior
    // from upstream e5c31e8b3 (#11583).
    const force_opaque: bool = switch (target) {
        .app => false,
        .surface => |cs| blk: {
            if (self.config.@"background-opacity" >= 1.0) break :blk false;
            const h = cs.rt_surface.parent_window.hwnd orelse break :blk false;
            const ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
            break :blk (ex & w32.WS_EX_LAYERED) == 0;
        },
    };

    const alloc = self.core_app.alloc;
    const window = alloc.create(Window) catch |err| {
        log.err("failed to allocate new window err={}", .{err});
        return;
    };
    window.init(self, .{ .force_opaque = force_opaque }) catch |err| {
        log.err("failed to init new window err={}", .{err});
        alloc.destroy(window);
        return;
    };
    self.windows.append(alloc, window) catch |err| {
        log.err("failed to track new window err={}", .{err});
        window.deinit();
        alloc.destroy(window);
        return;
    };
    _ = window.addTab() catch |err| {
        log.err("failed to add tab to new window err={}", .{err});
        return;
    };
}

fn configChange(self: *App, value: apprt.Action.Value(.config_change)) void {
    // Update our stored config with the new one.
    if (value.config.clone(self.core_app.alloc)) |new_config| {
        self.config.deinit();
        self.config = new_config;

        // Recreate the background brush from the new config.
        if (self.bg_brush) |old_brush| {
            _ = w32.DeleteObject(@ptrCast(old_brush));
        }
        const bg = new_config.background;
        self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

        // Refresh DWM chrome (dark/light, caption color) on
        // every live window so a config reload that changes
        // the background color updates the title bar.
        for (self.windows.items) |w| w.onConfigChange();

        // Update quick terminal config.
        if (self.quick_terminal) |qt| {
            qt.onConfigChange(&self.config);
        }
    } else |err| {
        log.err("error updating app config err={}", .{err});
    }
}

fn toggleMaximize(self: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.parent_window.hwnd) |hwnd| {
                if (w32.IsZoomed(hwnd) != 0) {
                    foreground.showTopLevel(self, hwnd, w32.SW_RESTORE);
                } else {
                    foreground.showTopLevel(self, hwnd, w32.SW_MAXIMIZE);
                }
            }
        },
    }
}

fn openUrl(value: apprt.Action.Value(.open_url)) void {
    // Open a URL using ShellExecuteW — the native Windows way.
    // internal_os.open() uses std.process.Child which can hit
    // unreachable on Windows, so we use ShellExecuteW directly.
    var wbuf: [2048]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, value.url) catch return;
    if (wlen < wbuf.len) {
        wbuf[wlen] = 0;
        _ = w32.ShellExecuteW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("open"),
            @ptrCast(&wbuf),
            null,
            null,
            w32.SW_SHOW,
        );
    }
}

fn newTab(target: apprt.Target) void {
    // Add a new tab to the parent window of the focused surface.
    // Inherits the active pane's backend (keybind, command
    // palette, and surface context menu all land here).
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const parent = core_surface.rt_surface.parent_window;
            _ = parent.addTabInherit() catch |err| {
                log.err("failed to add new tab err={}", .{err});
            };
        },
    }
}

fn saveSession(self: *App) void {
    const alloc = self.core_app.alloc;
    if (self.windows.items.len > 0) {
        SessionState.save(alloc, self.windows.items[0]) catch |err| {
            log.err("session save failed: {}", .{err});
        };
    }
}

fn restoreSession(self: *App) void {
    const alloc = self.core_app.alloc;
    SessionState.restore(alloc, self) catch |err| {
        log.err("session restore failed: {}", .{err});
    };
}

fn initialSize(self: *App, target: apprt.Target, value: apprt.Action.Value(.initial_size)) void {
    // WMUX_TEST_HIDDEN windows keep their fixed hidden geometry.
    if (self.runtime_env.test_hidden) return;
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.parent_window.hwnd) |h| {
                // Convert client size to window size (accounts for
                // title bar, borders, scrollbar).
                var rect = w32.RECT{
                    .left = 0,
                    .top = 0,
                    .right = @intCast(value.width),
                    .bottom = @intCast(value.height),
                };
                _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                _ = w32.SetWindowPos(
                    h,
                    null,
                    0,
                    0,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                );
            }
        },
    }
}

fn toggleBackgroundOpacity(self: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.parent_window.hwnd) |h| {
                const current_ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                if (current_ex & w32.WS_EX_LAYERED != 0) {
                    // Remove layered style (restore full opacity)
                    _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex & ~w32.WS_EX_LAYERED);
                } else {
                    // Apply opacity from config
                    _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
                    const alpha: u8 = @intFromFloat(@round(self.config.@"background-opacity" * 255.0));
                    _ = w32.SetLayeredWindowAttributes(h, 0, alpha, w32.LWA_ALPHA);
                }
            }
        },
    }
}

fn resetWindowSize(self: *App, target: apprt.Target) void {
    // WMUX_TEST_HIDDEN windows keep their fixed hidden geometry.
    if (self.runtime_env.test_hidden) return;
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.parent_window.hwnd) |h| {
                // Reset to default 800x600
                var rect = w32.RECT{
                    .left = 0,
                    .top = 0,
                    .right = 800,
                    .bottom = 600,
                };
                _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                _ = w32.SetWindowPos(
                    h,
                    null,
                    0,
                    0,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                );
            }
        },
    }
}

fn copyTitleToClipboard(self: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.parent_window.hwnd) |h| {
                // Get the window title and put it on the clipboard
                var wbuf: [512]u16 = undefined;
                const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, @intCast(wbuf.len)));
                if (wlen > 0) {
                    var utf8_buf: [1024]u8 = undefined;
                    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;
                    if (utf8_len > 0) {
                        // Copy to clipboard via the core surface
                        const alloc = self.core_app.alloc;
                        const text = alloc.dupeZ(u8, utf8_buf[0..utf8_len]) catch return;
                        defer alloc.free(text);
                        core_surface.rt_surface.setClipboard(
                            .standard,
                            &.{.{ .mime = "text/plain", .data = text }},
                            false,
                        ) catch {};
                    }
                }
            }
        },
    }
}

fn render(target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.core_surface_ready) {
                core_surface.rt_surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
        },
    }
}

fn colorChange(self: *App, value: apprt.Action.Value(.color_change)) void {
    // Track terminal background color changes (OSC 10/11) so the
    // class background brush matches. The renderer paints the
    // client area via OpenGL — the brush only affects the brief
    // flash on resize before the renderer catches up.
    if (value.kind != .background) return;
    if (self.bg_brush) |old_brush| {
        _ = w32.DeleteObject(@ptrCast(old_brush));
    }
    self.bg_brush = w32.CreateSolidBrush(w32.RGB(value.r, value.g, value.b));
    // SetClassLongPtrW propagates the new brush to all existing
    // windows of the class, not just future ones.
    for (self.windows.items) |w| {
        if (w.hwnd) |h| {
            if (self.bg_brush) |b| {
                _ = w32.SetClassLongPtrW(
                    h,
                    w32.GCLP_HBRBACKGROUND,
                    @intCast(@intFromPtr(b)),
                );
            }
        }
    }
}

fn sizeLimit(target: apprt.Target, value: apprt.Action.Value(.size_limit)) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const win = core_surface.rt_surface.parent_window;
            win.min_track_w = @intCast(value.min_width);
            win.min_track_h = @intCast(value.min_height);
            win.max_track_w = @intCast(value.max_width);
            win.max_track_h = @intCast(value.max_height);
        },
    }
}

fn toggleVisibility(self: *App) void {
    // Hide all visible top-level Ghostty windows; if any are
    // already hidden, show + restore them. Equivalent to macOS
    // NSApp hide / show.
    var any_visible = false;
    for (self.windows.items) |w| {
        if (w.hwnd) |h| {
            if (w32.IsWindowVisible_(h) != 0) {
                any_visible = true;
                break;
            }
        }
    }
    for (self.windows.items) |w| {
        if (w.hwnd) |h| {
            if (any_visible) {
                _ = w32.ShowWindow(h, w32.SW_HIDE);
            } else {
                _ = w32.ShowWindow(h, w32.SW_SHOWNOACTIVATE);
            }
        }
    }
    // The quick terminal manages its own visibility separately.
}

fn floatWindow(target: apprt.Target, value: apprt.Action.Value(.float_window)) void {
    // Toggle WS_EX_TOPMOST so the window stays above non-topmost
    // windows. Equivalent to macOS NSWindow.level = .floating.
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return;
            const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
            const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
            const want: bool = switch (value) {
                .on => true,
                .off => false,
                .toggle => !is_topmost,
            };
            if (want == is_topmost) return;
            const insert_after = if (want) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
            _ = w32.SetWindowPos(
                win_hwnd,
                insert_after,
                0,
                0,
                0,
                0,
                w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
            );
        },
    }
}

fn mouseVisibility(target: apprt.Target, value: apprt.Action.Value(.mouse_visibility)) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const visible = value == .visible;
            core_surface.rt_surface.mouse_visible = visible;
            // Force the next WM_SETCURSOR to apply the new state
            // by issuing SetCursor immediately if the cursor is
            // currently in our client area.
            if (!visible) {
                _ = w32.SetCursor(null);
            } else if (core_surface.rt_surface.current_cursor) |c| {
                _ = w32.SetCursor(c);
            }
        },
    }
}

fn presentTerminal(self: *App, target: apprt.Target) void {
    // Raise the window containing the target surface and select
    // its tab. Restores from minimized/iconic state if necessary.
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const win = core_surface.rt_surface.parent_window;
            if (win.hwnd) |hwnd| {
                // Only un-minimize: SW_RESTORE on a *maximized*
                // window un-maximizes it to the restored rect, so a
                // notification click would shrink/resize a maximized
                // window. Gate on IsIconic so a maximized or normal
                // window keeps its size/maximized state untouched.
                if (w32.IsIconic(hwnd) != 0) foreground.showTopLevel(self, hwnd, w32.SW_RESTORE);
                // Only move OS foreground when we already own it;
                // never yank the user out of another app (the
                // critical OS-foreground gate, applied to every
                // raise path).
                foreground.forceForegroundWindow(self, hwnd);
                // Make sure the workspace AND tab containing this
                // surface are active: select the workspace first
                // (it re-lays out for the new tab count), then the
                // tab within it. Order matters.
                if (win.findLocOfSurface(core_surface.rt_surface)) |loc| {
                    win.selectWorkspace(win.workspaceIndex(loc.ws));
                    loc.ws.focused_container = loc.container;
                    if (loc.tab != loc.container.active_tab) win.selectTabIndex(loc.tab);
                }
                // Focus the surface's child HWND.
                if (core_surface.rt_surface.hwnd) |sh| {
                    _ = w32.SetFocus(sh);
                }
            }
        },
    }
}

fn newSplit(target: apprt.Target, value: apprt.Action.Value(.new_split)) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            const dir: SplitTree(Pane).Split.Direction = switch (value) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            };
            core_surface.rt_surface.parent_window.newSplit(dir) catch |err| {
                log.err("failed to create split: {}", .{err});
            };
        },
    }
}

fn promptTitle(target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            // Both .tab and .surface trigger inline rename on the
            // current tab. On Win32 there's no separate surface title
            // UI — the tab title IS the surface identity.
            const pw = core_surface.rt_surface.parent_window;
            const rename_container = pw.activeWorkspace().focusedContainerOrFirst() orelse return;
            pw.startTabRename(rename_container.active_tab);
        },
    }
}

fn toggleQuickTerminal(self: *App) void {
    if (self.quick_terminal) |qt| {
        qt.toggle();
    } else {
        const qt = QuickTerminal.init(self) catch |err| {
            log.err("failed to create quick terminal: {}", .{err});
            return;
        };
        self.quick_terminal = qt;
        qt.toggle();
    }
}
