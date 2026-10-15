//! Message-loop interception for `App.run`: `preTranslate` runs for every
//! message before TranslateMessage/DispatchMessage and consumes the ones
//! wmux handles itself (the quick-terminal global hotkey, Enter/Escape/
//! arrows in popup edit controls, Ctrl+W inside WebView2, global
//! keybindings bubbled out of popup edits); `skipTranslate` keeps
//! TranslateMessage away from terminal surfaces.
//!
//! Moved verbatim from App.run in W0-A1 (ARCHITECTURE.md ADR-1.6). W1-5
//! inserts the KeyRouter call into preTranslate.

const std = @import("std");

const App = @import("../App.zig");
const BrowserPane = @import("../BrowserPane.zig");
const Surface = @import("../Surface.zig");
const w32 = @import("../platform/win32.zig");

/// Returns true when `msg` was consumed and must not be translated or
/// dispatched.
pub fn preTranslate(self: *App, msg: *w32.MSG) bool {
    // Handle global hotkey for quick terminal.
    if (msg.message == w32.WM_HOTKEY) {
        _ = self.performAction(
            .{ .app = {} },
            .toggle_quick_terminal,
            {},
        ) catch {};
        return true;
    }

    // Intercept keystrokes destined for popup edit controls so
    // Enter/Escape/Arrow keys can be handled by our code.
    if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
        const vk: u16 = @intCast(msg.wParam & 0xFFFF);

        // Check if this edit is a tab rename edit
        if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
            for (self.windows.items) |win| {
                if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                    if (vk == w32.VK_RETURN) {
                        win.finishTabRename();
                    } else {
                        win.cancelTabRename();
                    }
                    return true;
                }
            }
        }

        // Find the parent of this edit control and route by class:
        // terminal-class parents (surface + search/palette popups)
        // carry a *Surface in GWLP_USERDATA, browser-host parents a
        // *BrowserPane. The atom check gates the casts — without it
        // a key typed in the browser address bar would reinterpret
        // a *BrowserPane as *Surface.
        const parent = w32.GetParent(msg.hwnd.?);
        if (parent) |p| {
            const atom: u16 = @truncate(w32.GetClassLongW(p, w32.GCW_ATOM));
            const userdata = w32.GetWindowLongPtrW(p, w32.GWLP_USERDATA);
            if (userdata != 0 and atom != 0 and atom == self.browser_host_class_atom) {
                const browser: *BrowserPane = @ptrFromInt(@as(usize, @bitCast(userdata)));
                if (browser.address_edit != null and browser.address_edit.? == msg.hwnd) {
                    if (vk == w32.VK_RETURN) {
                        browser.navigateFromAddressBar();
                        return true;
                    }
                    if (vk == w32.VK_ESCAPE) {
                        browser.focusWebView();
                        return true;
                    }
                }
            }
            if (userdata != 0 and atom != 0 and atom == self.terminal_class_atom) {
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                if (surface.search_active and surface.search_edit == msg.hwnd) {
                    if (surface.handleSearchKey(vk)) return true;
                }
                if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                    if (surface.handlePaletteKey(vk)) return true;
                }
            }
        }

        // Ctrl+W inside WebView2 content: the AcceleratorKeyPressed
        // COM callback is unreliable on some WebView2 versions, so
        // intercept the key here in the message loop. Walk up the
        // parent chain from the focused HWND; if any ancestor is a
        // browser host, post the deferred close message to it.
        if (vk == 0x57 and w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0 and
            !(w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0))
        {
            const found_host = findBrowserHostAncestor(self, msg.hwnd.?);
            if (found_host) |host| {
                _ = w32.PostMessageW(host, BrowserPane.WM_BROWSER_CLOSE, 0, 0);
                return true;
            }
        }

        // Bubble global keybindings from popup edit controls (tab
        // rename, command palette, search) up to the surface so that
        // e.g. `Ctrl+Shift+P` while renaming actually toggles the
        // palette instead of being eaten by the Edit. Excludes
        // Ctrl-only A/C/V/X/Y/Z so standard text-edit shortcuts keep
        // working inside the popup.
        const ctrl_held = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
        const shift_held = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
        const route_key = ctrl_held and (shift_held or !isEditShortcutVk(vk));
        if (route_key) {
            const target_surface: ?*Surface = blk: {
                // Tab rename edit lives on the Window, not a surface.
                // Commit (not cancel) — matches standard Win32 inline
                // rename convention (Explorer, Edge): any action that
                // takes focus away saves the typed title.
                for (self.windows.items) |win| {
                    if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                        win.finishTabRename();
                        break :blk win.getActiveSurface();
                    }
                }
                // Palette/search edits are children of a
                // terminal-class popup HWND; only that class
                // carries a *Surface in GWLP_USERDATA.
                const pp = w32.GetParent(msg.hwnd.?) orelse break :blk null;
                const pp_atom: u16 = @truncate(w32.GetClassLongW(pp, w32.GCW_ATOM));
                if (pp_atom == 0 or pp_atom != self.terminal_class_atom) break :blk null;
                const ud = w32.GetWindowLongPtrW(pp, w32.GWLP_USERDATA);
                if (ud == 0) break :blk null;
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(ud)));
                if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                    surface.setCommandPaletteActive(false);
                    break :blk surface;
                }
                if (surface.search_active and surface.search_edit == msg.hwnd) {
                    surface.setSearchActive(false, &[_:0]u8{});
                    break :blk surface;
                }
                break :blk null;
            };
            if (target_surface) |s| {
                _ = s.handleKeyEvent(msg.wParam, msg.lParam, .press);
                return true;
            }
        }
    }
    return false;
}

/// Whether TranslateMessage must be skipped for `msg`.
pub fn skipTranslate(self: *const App, msg: *const w32.MSG) bool {
    // Skip TranslateMessage for keyboard events on terminal surface
    // windows: handleKeyEvent (and sendWin32InputEvent in Win32 input
    // mode) calls ToUnicode directly, and TranslateMessage's internal
    // ToUnicodeEx mutates the same per-queue dead-key state — racing
    // it broke dead-key composition on ABNT2 (`~`+`a` → `~a`). Edit
    // controls (search, palette, tab rename) still need it.
    return switch (msg.message) {
        w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
            const h = msg.hwnd orelse break :blk false;
            const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
            break :blk atom != 0 and atom == self.terminal_class_atom;
        },
        else => false,
    };
}

/// Ctrl-modified VKs that should remain with the focused Edit control
/// rather than bubbling to the surface as a keybinding. Select-all,
/// copy, paste, cut, redo, undo.
fn isEditShortcutVk(vk: u16) bool {
    return switch (vk) {
        'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
}

/// Walk up the parent chain from `hwnd` looking for a browser host
/// window (class atom == browser_host_class_atom). Returns the host
/// HWND if found, null otherwise. Stops after 16 levels to avoid
/// infinite loops on circular parent chains.
fn findBrowserHostAncestor(self: *const App, hwnd: w32.HWND) ?w32.HWND {
    if (self.browser_host_class_atom == 0) return null;
    var cur: ?w32.HWND = hwnd;
    var depth: u32 = 0;
    while (cur) |h| : (depth += 1) {
        if (depth > 16) break;
        const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
        if (atom != 0 and atom == self.browser_host_class_atom) return h;
        cur = w32.GetParent(h);
    }
    return null;
}
