//! Window placement persistence (ARCHITECTURE.md ADR-1.8 W0-A2 step 4):
//! save and restore the geometry of the main window through the pure
//! placement_state.zig format. Moved out of Window.zig in W0-A2.

const std = @import("std");

const App = @import("../App.zig");
const Window = @import("Window.zig");
const WindowState = @import("placement_state.zig");
const app_paths = @import("../app/paths.zig");
const w32 = @import("../platform/win32.zig");

/// Build the absolute path to the window-state file:
/// %LOCALAPPDATA%\ghostty\window-state, or <WMUX_STATE_DIR>\window-state
/// (app/paths.zig). Caller owns the returned slice. A WMUX_TEST_HIDDEN
/// instance has no window-state file (ADR-12.3: placement save and
/// restore are skipped), so savePlacement/restorePlacement are no-ops.
pub fn windowStatePath(app: *const App, alloc: std.mem.Allocator) ![]u8 {
    if (app.runtime_env.test_hidden) return error.HiddenTestInstance;
    return app_paths.windowStatePath(alloc, &app.runtime_env);
}

/// Capture the current window placement and persist it. Called on
/// WM_EXITSIZEMOVE (resize/move settle) and on close, so we never write
/// on every pixel of a drag.
///
/// We persist the window's *restored* rect (GetWindowPlacement's
/// rcNormalPosition) plus the maximized flag, so a maximized window still
/// remembers the underlying size it un-maximizes to. Coordinates are
/// physical pixels in workarea space (see WindowState.zig).
///
/// Only the main window participates: quick terminals manage their own
/// geometry, and additional windows would clobber each other. Errors
/// (missing dir, no permission) are swallowed — persistence is best
/// effort and must never affect normal operation.
pub fn savePlacement(self: *Window) void {
    if (self.is_quick_terminal) return;
    // Only the first window in the App's list owns the persisted state.
    // Additional session windows cascade and do not save (avoids two
    // windows fighting over one file).
    if (self.app.windows.items.len == 0 or self.app.windows.items[0] != self) return;
    const hwnd = self.hwnd orelse return;

    var wp: w32.WINDOWPLACEMENT = undefined;
    wp.length = @sizeOf(w32.WINDOWPLACEMENT);
    if (w32.GetWindowPlacement(hwnd, &wp) == 0) return;

    const r = wp.rcNormalPosition;
    const state: WindowState.State = .{
        .width = r.right - r.left,
        .height = r.bottom - r.top,
        .x = r.left,
        .y = r.top,
        // showCmd reflects the persisted (un-minimized) show state.
        // SW_SHOWMAXIMIZED (3) and SW_MAXIMIZE (3) both mean maximized.
        .maximized = wp.showCmd == w32.SW_SHOWMAXIMIZED,
    };

    // Reject a degenerate capture (e.g. a minimized window reporting a
    // tiny/zero normal rect during teardown) so we never clobber a
    // previously-good save with garbage.
    if (!state.validate()) return;

    // Serialize the state into a stack buffer on the UI thread (fast),
    // then hand the actual file I/O to a fire-and-forget worker thread
    // so we never block the UI on slow disks. The serialized text is
    // tiny (< 160 bytes) and fully self-contained.
    var serialize_buf: [160]u8 = undefined;
    const text = state.serialize(&serialize_buf) catch return;

    const alloc = self.app.core_app.alloc;
    const path = windowStatePath(self.app, alloc) catch return;

    const ctx = alloc.create(SavePlacementCtx) catch {
        alloc.free(path);
        return;
    };
    // Copy the serialized text into an owned buffer for the worker.
    const text_copy = alloc.dupe(u8, text) catch {
        alloc.free(path);
        alloc.destroy(ctx);
        return;
    };
    ctx.* = .{
        .alloc = alloc,
        .path = path,
        .text = text_copy,
    };

    const thread = std.Thread.spawn(.{}, savePlacementWorker, .{ctx}) catch {
        alloc.free(path);
        alloc.free(text_copy);
        alloc.destroy(ctx);
        return;
    };
    thread.detach();
    self.saved_placement_ok = true;
}

pub const SavePlacementCtx = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
};

/// Worker-thread entry for savePlacement: writes the already-serialized
/// state to disk. Fire-and-forget — the process is typically exiting
/// (WM_CLOSE) or the user just finished a drag (WM_EXITSIZEMOVE), so
/// there is nothing to signal back.
pub fn savePlacementWorker(ctx: *SavePlacementCtx) void {
    defer {
        ctx.alloc.free(ctx.path);
        ctx.alloc.free(ctx.text);
        ctx.alloc.destroy(ctx);
    }

    // Ensure the parent dir exists, then write atomically-ish via
    // truncate. The state is tiny so a partial write is implausible.
    if (std.fs.path.dirname(ctx.path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = std.fs.cwd().createFile(ctx.path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(ctx.text) catch return;
}

/// Read and validate the persisted window state, clamped onto the
/// current virtual screen so the restored window is always visible.
/// Returns null when there is no state, it is corrupt, or the env is
/// unavailable — callers then fall back to defaults. Best effort: any
/// error path yields null.
pub fn restorePlacement(self: *Window) ?WindowState.State {
    const alloc = self.app.core_app.alloc;
    const path = windowStatePath(self.app, alloc) catch return null;
    defer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    var state = WindowState.State.parse(buf[0..n]) orelse return null;

    // Clamp onto the current virtual screen (handles a removed monitor or
    // an off-screen saved position). Physical pixels throughout.
    const vx = w32.GetSystemMetrics(w32.SM_XVIRTUALSCREEN);
    const vy = w32.GetSystemMetrics(w32.SM_YVIRTUALSCREEN);
    const vw = w32.GetSystemMetrics(w32.SM_CXVIRTUALSCREEN);
    const vh = w32.GetSystemMetrics(w32.SM_CYVIRTUALSCREEN);
    // If the metrics are unavailable (0 span), skip clamping rather than
    // collapsing the window.
    if (vw > 0 and vh > 0) {
        const adjusted = WindowState.clampToVirtualScreen(
            .{ .x = state.x, .y = state.y, .width = state.width, .height = state.height },
            .{ .x = vx, .y = vy, .width = vw, .height = vh },
        );
        state.x = adjusted.x;
        state.y = adjusted.y;
        state.width = adjusted.width;
        state.height = adjusted.height;
    }

    return state;
}
