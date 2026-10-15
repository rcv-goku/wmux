//! The quick terminal's system-wide hotkey: RegisterHotKey for the first
//! `global:` keybind bound to toggle_quick_terminal (the WM_HOTKEY is
//! consumed by app/message_loop.zig). Never registered in WMUX_TEST_MODE.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8).

const std = @import("std");

const App = @import("../../App.zig");
const w32 = @import("../../platform/win32.zig");

const log = std.log.scoped(.win32);

/// Register a system-wide hotkey for toggle_quick_terminal.
/// Scans keybinds for entries with the `global` flag.
pub fn registerGlobalHotkey(self: *App) void {
    // WMUX_TEST_MODE: never claim a system-wide hotkey (ARCHITECTURE.md
    // ADR-12.3).
    if (self.runtime_env.test_mode) return;
    var it = self.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leader => continue,
            .leaf => |l| l,
            .leaf_chained => continue,
        };
        if (!leaf.flags.global) continue;

        // Check if this binding is for toggle_quick_terminal.
        const is_quick_terminal = switch (leaf.action) {
            .toggle_quick_terminal => true,
            else => false,
        };
        if (!is_quick_terminal) continue;

        const trigger = entry.key_ptr.*;

        // Convert Ghostty mods to Win32 mods.
        var mods: u32 = w32.MOD_NOREPEAT;
        if (trigger.mods.ctrl) mods |= w32.MOD_CONTROL;
        if (trigger.mods.alt) mods |= w32.MOD_ALT;
        if (trigger.mods.shift) mods |= w32.MOD_SHIFT;
        if (trigger.mods.super) mods |= w32.MOD_WIN;

        // Convert Ghostty key to Win32 VK.
        const vk: ?u32 = switch (trigger.key) {
            .physical => |phys| keyToVk(phys),
            .unicode => |cp| blk: {
                // For ASCII characters, VK code = uppercase char.
                if (cp >= 'a' and cp <= 'z') break :blk @as(u32, cp - 'a' + 'A');
                if (cp >= '0' and cp <= '9') break :blk @as(u32, cp);
                break :blk null;
            },
            else => null,
        };

        if (vk) |vk_code| {
            if (w32.RegisterHotKey(null, 1, mods, vk_code) != 0) {
                self.global_hotkey_registered = true;
                log.info("registered global hotkey for quick terminal", .{});
            } else {
                log.warn("failed to register global hotkey (may be in use by another app)", .{});
            }
        } else {
            log.warn("unsupported key for global hotkey", .{});
        }
        break; // Only register the first matching binding.
    }
}

/// Map a Ghostty physical key to a Win32 virtual key code.
fn keyToVk(key: @import("../../../../input/key.zig").Key) ?u32 {
    return switch (key) {
        .key_a => 0x41,
        .key_b => 0x42,
        .key_c => 0x43,
        .key_d => 0x44,
        .key_e => 0x45,
        .key_f => 0x46,
        .key_g => 0x47,
        .key_h => 0x48,
        .key_i => 0x49,
        .key_j => 0x4A,
        .key_k => 0x4B,
        .key_l => 0x4C,
        .key_m => 0x4D,
        .key_n => 0x4E,
        .key_o => 0x4F,
        .key_p => 0x50,
        .key_q => 0x51,
        .key_r => 0x52,
        .key_s => 0x53,
        .key_t => 0x54,
        .key_u => 0x55,
        .key_v => 0x56,
        .key_w => 0x57,
        .key_x => 0x58,
        .key_y => 0x59,
        .key_z => 0x5A,
        .digit_0 => 0x30,
        .digit_1 => 0x31,
        .digit_2 => 0x32,
        .digit_3 => 0x33,
        .digit_4 => 0x34,
        .digit_5 => 0x35,
        .digit_6 => 0x36,
        .digit_7 => 0x37,
        .digit_8 => 0x38,
        .digit_9 => 0x39,
        .backquote => w32.VK_OEM_3,
        .minus => w32.VK_OEM_MINUS,
        .equal => w32.VK_OEM_PLUS,
        .bracket_left => w32.VK_OEM_4,
        .bracket_right => w32.VK_OEM_6,
        .backslash => w32.VK_OEM_5,
        .semicolon => w32.VK_OEM_1,
        .quote => w32.VK_OEM_7,
        .comma => w32.VK_OEM_COMMA,
        .period => w32.VK_OEM_PERIOD,
        .slash => w32.VK_OEM_2,
        .enter => w32.VK_RETURN,
        .tab => w32.VK_TAB,
        .space => w32.VK_SPACE,
        .backspace => w32.VK_BACK,
        .escape => w32.VK_ESCAPE,
        .f1 => w32.VK_F1,
        .f2 => w32.VK_F2,
        .f3 => w32.VK_F3,
        .f4 => w32.VK_F4,
        .f5 => w32.VK_F5,
        .f6 => w32.VK_F6,
        .f7 => w32.VK_F7,
        .f8 => w32.VK_F8,
        .f9 => w32.VK_F9,
        .f10 => w32.VK_F10,
        .f11 => w32.VK_F11,
        .f12 => w32.VK_F12,
        else => null,
    };
}

/// Release the hotkey registered by registerGlobalHotkey (App.terminate).
pub fn unregisterGlobalHotkey(self: *App) void {
    if (self.global_hotkey_registered) {
        _ = w32.UnregisterHotKey(null, 1);
        self.global_hotkey_registered = false;
    }
}
