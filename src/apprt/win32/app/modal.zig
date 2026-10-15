//! Modal-loop accounting and the MessageBox choke point (ARCHITECTURE.md
//! ADR-1.6, ADR-12.3). `app.modal.enter()`/`leave()` bracket every modal
//! loop (TrackPopupMenuEx, MessageBox, DoDragDrop, WM_ENTERSIZEMOVE ...
//! WM_EXITSIZEMOVE); from W1-1 on the RPC dispatcher holds mutating
//! UI-lane requests while `depth > 0`. W0-A1 brackets the MessageBox
//! calls; the menus and the size/move loop are bracketed when W0-A2 moves
//! them into ui/ (MenuBuilder).
//!
//! In WMUX_TEST_MODE no message box is shown (it would block automation
//! and play a sound): `messageBox` answers with the dialog's default
//! button and logs it.

const std = @import("std");

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_modal);

pub const Modal = struct {
    /// Number of modal loops currently running on the UI thread.
    depth: u32 = 0,

    pub fn enter(self: *Modal) void {
        self.depth += 1;
    }

    pub fn leave(self: *Modal) void {
        std.debug.assert(self.depth > 0);
        self.depth -|= 1;
    }

    pub fn active(self: *const Modal) bool {
        return self.depth > 0;
    }
};

/// MessageBoxW inside an `app.modal` bracket. In WMUX_TEST_MODE the box
/// is not shown: the id of its default button is returned at once.
pub fn messageBox(
    app: *App,
    owner: ?w32.HWND,
    text: [*:0]const u16,
    caption: [*:0]const u16,
    flags: u32,
) i32 {
    if (app.runtime_env.test_mode) {
        const answer = defaultButtonId(flags);
        log.info("test mode: message box auto-answered with id={d}", .{answer});
        return answer;
    }
    app.modal.enter();
    defer app.modal.leave();
    return w32.MessageBoxW(owner, text, caption, flags);
}

/// The id MessageBox returns when its default button is pressed, for the
/// button set (MB_OK ... MB_CANCELTRYCONTINUE) and MB_DEFBUTTONn in
/// `flags`. An out-of-range MB_DEFBUTTONn selects the first button, like
/// Windows does. Pure (unit-tested).
pub fn defaultButtonId(flags: u32) i32 {
    const IDOK = 1;
    const IDCANCEL = 2;
    const IDABORT = 3;
    const IDRETRY = 4;
    const IDIGNORE = 5;
    const IDYES = 6;
    const IDNO = 7;
    const IDTRYAGAIN = 10;
    const IDCONTINUE = 11;
    const buttons: []const i32 = switch (flags & 0xF) {
        0x0 => &.{IDOK}, // MB_OK
        0x1 => &.{ IDOK, IDCANCEL }, // MB_OKCANCEL
        0x2 => &.{ IDABORT, IDRETRY, IDIGNORE }, // MB_ABORTRETRYIGNORE
        0x3 => &.{ IDYES, IDNO, IDCANCEL }, // MB_YESNOCANCEL
        0x4 => &.{ IDYES, IDNO }, // MB_YESNO
        0x5 => &.{ IDRETRY, IDCANCEL }, // MB_RETRYCANCEL
        0x6 => &.{ IDCANCEL, IDTRYAGAIN, IDCONTINUE }, // MB_CANCELTRYCONTINUE
        else => &.{IDOK},
    };
    const index: usize = (flags >> 8) & 0xF; // MB_DEFBUTTON1..4 = 0x000..0x300
    return if (index < buttons.len) buttons[index] else buttons[0];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: modal default button for message box auto-answers" {
    // MB_OK → IDOK.
    try testing.expectEqual(@as(i32, w32.IDOK), defaultButtonId(w32.MB_ICONWARNING));
    // The close-surface confirm: MB_OKCANCEL | MB_DEFBUTTON2 → IDCANCEL.
    try testing.expectEqual(
        @as(i32, w32.IDCANCEL),
        defaultButtonId(w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2),
    );
    // MB_YESNO defaults to Yes; DEFBUTTON2 picks No (7).
    try testing.expectEqual(@as(i32, w32.IDYES), defaultButtonId(w32.MB_YESNO));
    try testing.expectEqual(@as(i32, 7), defaultButtonId(w32.MB_YESNO | w32.MB_DEFBUTTON2));
    // An out-of-range default button falls back to the first button.
    try testing.expectEqual(@as(i32, w32.IDOK), defaultButtonId(w32.MB_OKCANCEL | 0x300));
}

test "unit: app: modal depth brackets nest" {
    var m: Modal = .{};
    try testing.expect(!m.active());
    m.enter();
    m.enter();
    try testing.expect(m.active());
    m.leave();
    try testing.expect(m.active());
    m.leave();
    try testing.expect(!m.active());
}
