//! The choke point for everything the app shows or starts outside its own
//! windows (ARCHITECTURE.md ADR-12.3, Appendix G / AF-16): message boxes,
//! file dialogs, external launches (ShellExecute) and sounds. Nothing
//! else in the apprt calls MessageBoxW, IFileDialog, MessageBeep or
//! PlaySoundW. One ShellExecuteW exception remains outside this WP's
//! files: settings/legacy_config_files.zig (openConfigFile and
//! openConfigFolder, reached from the sidebar gear and the settings menu)
//! until W1-4 routes it through `openExternal`; the `.open_config` action
//! is already intercepted in test mode by app/perform_action.zig.
//!
//! In WMUX_TEST_MODE none of them reach the user (they would block
//! automation, open windows outside the instance's process tree, or make
//! noise):
//!
//! - message boxes return their default button at once (or the next
//!   answer queued by `wmux.debug.dialogs.answer`) and are recorded for
//!   `wmux.debug.dialogs.list` (W1-1a);
//! - file dialogs answer from WMUX_TEST_FILE_DIALOG (a path is the
//!   selection; unset, empty or "cancel" cancels);
//! - external launches append one JSON line to WMUX_TEST_EXTERNAL_SINK;
//! - sounds append one JSON line to WMUX_TEST_SOUND_SINK.
//!
//! Sink lines are written by a short worker thread so the UI thread never
//! waits on file I/O (G3); one mutex keeps lines whole.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const com = @import("../platform/com.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_dialogs);

// ---------------------------------------------------------------------------
// Message boxes
// ---------------------------------------------------------------------------

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
        const answer = takePresetAnswer() orelse defaultButtonId(flags);
        log.info("test mode: message box auto-answered with id={d}", .{answer});
        recordDialog(text, caption, flags, answer);
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
// Test-mode dialog log and preset answers (wmux.debug.dialogs.list/answer,
// W1-1a). Process-wide, guarded by one mutex; the message box path runs on
// the UI thread, the debug hooks too.
// ---------------------------------------------------------------------------

/// One auto-answered message box.
pub const DialogRecord = struct {
    kind: []const u8 = "message_box",
    caption: []const u8,
    text: []const u8,
    /// The MB_* flags.
    flags: u32,
    /// The button id returned (IDOK = 1, IDCANCEL = 2, IDYES = 6, ...).
    answer: i32,
    timestamp_ms: i64,
};

/// The most recent records kept (older ones are dropped).
pub const max_records = 256;

var records_mutex: std.Thread.Mutex = .{};
var records: std.ArrayList(DialogRecord) = .empty;
var presets: std.ArrayList(i32) = .empty;
/// Owns the record strings and both lists (page allocator: process-wide
/// test state, released by `resetTestRecords`).
const records_alloc = std.heap.page_allocator;

fn recordDialog(text: [*:0]const u16, caption: [*:0]const u16, flags: u32, answer: i32) void {
    const t = std.unicode.utf16LeToUtf8Alloc(records_alloc, std.mem.span(text)) catch return;
    const c = std.unicode.utf16LeToUtf8Alloc(records_alloc, std.mem.span(caption)) catch {
        records_alloc.free(t);
        return;
    };
    records_mutex.lock();
    defer records_mutex.unlock();
    if (records.items.len >= max_records) {
        const old = records.orderedRemove(0);
        records_alloc.free(old.text);
        records_alloc.free(old.caption);
    }
    records.append(records_alloc, .{
        .caption = c,
        .text = t,
        .flags = flags,
        .answer = answer,
        .timestamp_ms = std.time.milliTimestamp(),
    }) catch {
        records_alloc.free(t);
        records_alloc.free(c);
    };
}

fn takePresetAnswer() ?i32 {
    records_mutex.lock();
    defer records_mutex.unlock();
    if (presets.items.len == 0) return null;
    return presets.orderedRemove(0);
}

/// A copy of the auto-answered message boxes, oldest first, allocated in
/// `arena`.
pub fn testRecords(arena: Allocator) Allocator.Error![]DialogRecord {
    records_mutex.lock();
    defer records_mutex.unlock();
    const out = try arena.alloc(DialogRecord, records.items.len);
    for (records.items, out) |r, *o| {
        o.* = r;
        o.caption = try arena.dupe(u8, r.caption);
        o.text = try arena.dupe(u8, r.text);
    }
    return out;
}

/// Queue `answer` (a button id) for the next test-mode message box; the
/// default button answers again once the queue is empty. Returns the
/// queue length.
pub fn presetAnswer(answer: i32) Allocator.Error!usize {
    records_mutex.lock();
    defer records_mutex.unlock();
    try presets.append(records_alloc, answer);
    return presets.items.len;
}

/// The button id a `wmux.debug.dialogs.answer` name stands for ("ok",
/// "cancel", "abort", "retry", "ignore", "yes", "no", "try_again",
/// "continue"); null for anything else. Pure (unit-tested).
pub fn answerIdByName(name: []const u8) ?i32 {
    const table = [_]struct { []const u8, i32 }{
        .{ "ok", 1 },  .{ "cancel", 2 }, .{ "abort", 3 },      .{ "retry", 4 },     .{ "ignore", 5 },
        .{ "yes", 6 }, .{ "no", 7 },     .{ "try_again", 10 }, .{ "continue", 11 },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    return null;
}

/// Forget the records and preset answers (the control server stop).
pub fn resetTestRecords() void {
    records_mutex.lock();
    defer records_mutex.unlock();
    for (records.items) |r| {
        records_alloc.free(r.text);
        records_alloc.free(r.caption);
    }
    records.deinit(records_alloc);
    records = .empty;
    presets.deinit(records_alloc);
    presets = .empty;
}

// ---------------------------------------------------------------------------
// File dialogs (IFileOpenDialog / IFileSaveDialog)
// ---------------------------------------------------------------------------

pub const FileDialogKind = enum { open, save, pick_folder };

pub const FileDialogOptions = struct {
    kind: FileDialogKind = .open,
    /// Window title (UTF-8); the system default when null.
    title: ?[]const u8 = null,
    /// Initial file name of a save dialog (UTF-8).
    file_name: ?[]const u8 = null,
};

/// Show a file dialog owned by `owner` and return the chosen file-system
/// path (UTF-8, caller owns it), or null when cancelled or unavailable.
/// In WMUX_TEST_MODE no dialog is shown: the answer comes from
/// WMUX_TEST_FILE_DIALOG (testAnswer). Errors other than cancellation
/// are logged and count as cancelled.
pub fn fileDialog(app: *App, owner: ?w32.HWND, opts: FileDialogOptions) Allocator.Error!?[]u8 {
    const alloc = app.core_app.alloc;
    if (app.runtime_env.test_mode) {
        const answer = testAnswer(app.runtime_env.test_file_dialog);
        log.info("test mode: {s} file dialog answered {s}", .{ @tagName(opts.kind), if (answer == null) "cancel" else "with a path" });
        return if (answer) |path| try alloc.dupe(u8, path) else null;
    }
    app.modal.enter();
    defer app.modal.leave();
    return showFileDialog(alloc, owner, opts) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            log.warn("file dialog failed: {} hr=0x{x:0>8}", .{ err, @as(u32, @bitCast(last_hresult)) });
            return null;
        },
    };
}

/// The WMUX_TEST_FILE_DIALOG answer: null (cancel) for unset, blank or
/// "cancel" (ASCII case-insensitive); otherwise the trimmed path. Pure
/// (unit-tested).
pub fn testAnswer(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (v.len == 0 or std.ascii.eqlIgnoreCase(v, "cancel")) return null;
    return v;
}

const FOS_PICKFOLDERS: u32 = 0x20;
const FOS_FORCEFILESYSTEM: u32 = 0x40;
const SIGDN_FILESYSPATH: u32 = 0x80058000;
/// HRESULT_FROM_WIN32(ERROR_CANCELLED): the user closed the dialog.
const hr_cancelled: com.HRESULT = @bitCast(@as(u32, 0x800704C7));

var last_hresult: com.HRESULT = 0;

const CLSID_FileOpenDialog = com.GUID.parse("{DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}");
const CLSID_FileSaveDialog = com.GUID.parse("{C0B4E2F3-BA21-4773-8DBA-335EC946EB8B}");

/// IFileDialog (shobjidl_core.h), shared by the open and save dialogs;
/// only the slots used here are typed.
const IFileDialog = extern struct {
    vtable: *const VTable,

    /// IID_IFileDialog: both CLSID_FileOpenDialog and
    /// CLSID_FileSaveDialog implement it (their own interfaces only add
    /// trailing slots this file does not use).
    pub const IID = com.GUID.parse("{42F85136-DB7E-439C-85F1-E4075D135FC8}");

    const Pad = com.PadFn;
    pub const VTable = extern struct {
        base: com.IUnknown.VTable, // 0-2
        Show: *const fn (*IFileDialog, ?w32.HWND) callconv(.winapi) com.HRESULT, // 3 (IModalWindow)
        SetFileTypes: Pad, // 4
        SetFileTypeIndex: Pad, // 5
        GetFileTypeIndex: Pad, // 6
        Advise: Pad, // 7
        Unadvise: Pad, // 8
        SetOptions: *const fn (*IFileDialog, u32) callconv(.winapi) com.HRESULT, // 9
        GetOptions: *const fn (*IFileDialog, *u32) callconv(.winapi) com.HRESULT, // 10
        SetDefaultFolder: Pad, // 11
        SetFolder: Pad, // 12
        GetFolder: Pad, // 13
        GetCurrentSelection: Pad, // 14
        SetFileName: *const fn (*IFileDialog, [*:0]const u16) callconv(.winapi) com.HRESULT, // 15
        GetFileName: Pad, // 16
        SetTitle: *const fn (*IFileDialog, [*:0]const u16) callconv(.winapi) com.HRESULT, // 17
        SetOkButtonLabel: Pad, // 18
        SetFileNameLabel: Pad, // 19
        GetResult: *const fn (*IFileDialog, *?*IShellItem) callconv(.winapi) com.HRESULT, // 20
    };
};

/// IShellItem (shobjidl_core.h); only GetDisplayName is used.
const IShellItem = extern struct {
    vtable: *const VTable,

    pub const IID = com.GUID.parse("{43826D1E-E718-42EE-BC55-A1E261C37BFE}");

    pub const VTable = extern struct {
        base: com.IUnknown.VTable, // 0-2
        BindToHandler: com.PadFn, // 3
        GetParent: com.PadFn, // 4
        GetDisplayName: *const fn (*IShellItem, u32, *?[*:0]u16) callconv(.winapi) com.HRESULT, // 5
    };
};

fn check(hr: com.HRESULT) !void {
    if (hr == hr_cancelled) return error.Cancelled;
    if (hr < 0) {
        last_hresult = hr;
        return error.DialogFailed;
    }
}

fn showFileDialog(alloc: Allocator, owner: ?w32.HWND, opts: FileDialogOptions) !?[]u8 {
    const clsid = if (opts.kind == .save) &CLSID_FileSaveDialog else &CLSID_FileOpenDialog;
    const dialog = com.createInstance(IFileDialog, clsid) catch |err| {
        last_hresult = com.last_failure;
        return err;
    };
    defer com.release(dialog);

    var options: u32 = 0;
    try check(dialog.vtable.GetOptions(dialog, &options));
    options |= FOS_FORCEFILESYSTEM;
    if (opts.kind == .pick_folder) options |= FOS_PICKFOLDERS;
    try check(dialog.vtable.SetOptions(dialog, options));
    if (opts.title) |title| {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, title);
        defer alloc.free(w);
        try check(dialog.vtable.SetTitle(dialog, w));
    }
    if (opts.file_name) |name| {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
        defer alloc.free(w);
        try check(dialog.vtable.SetFileName(dialog, w));
    }

    check(dialog.vtable.Show(dialog, owner)) catch |err| switch (err) {
        error.Cancelled => return null,
        else => return err,
    };
    var item: ?*IShellItem = null;
    try check(dialog.vtable.GetResult(dialog, &item));
    const shell_item = item orelse return null;
    defer com.release(shell_item);
    var wpath: ?[*:0]u16 = null;
    try check(shell_item.vtable.GetDisplayName(shell_item, SIGDN_FILESYSPATH, &wpath));
    const p = wpath orelse return null;
    defer com.CoTaskMemFree(p);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(p));
}

// ---------------------------------------------------------------------------
// External launches (ShellExecute)
// ---------------------------------------------------------------------------

/// One WMUX_TEST_EXTERNAL_SINK line.
const ExternalRecord = struct {
    /// What asked for the launch: "open_url", "update_page", ...
    kind: []const u8,
    verb: []const u8,
    target: []const u8,
    timestamp_ms: i64,
};

/// ShellExecuteW(`verb`, `target`) with SW_SHOW: open a URL, file or
/// folder in its default application. `kind` names the caller in the test
/// sink. In WMUX_TEST_MODE nothing is started (the launched application
/// would live outside the instance's process tree and show its own
/// window): one ExternalRecord line goes to WMUX_TEST_EXTERNAL_SINK
/// instead. Returns whether the launch was started (or recorded).
pub fn openExternal(app: *App, kind: []const u8, verb: []const u8, target: []const u8) bool {
    if (app.runtime_env.test_mode) {
        log.info("test mode: external {s} launch not started", .{kind});
        const sink = app.runtime_env.test_external_sink orelse return true;
        appendRecord(app.core_app.alloc, sink, ExternalRecord{
            .kind = kind,
            .verb = verb,
            .target = target,
            .timestamp_ms = std.time.milliTimestamp(),
        });
        return true;
    }
    const alloc = app.core_app.alloc;
    const wverb = std.unicode.utf8ToUtf16LeAllocZ(alloc, verb) catch return false;
    defer alloc.free(wverb);
    const wtarget = std.unicode.utf8ToUtf16LeAllocZ(alloc, target) catch return false;
    defer alloc.free(wtarget);
    // ShellExecuteW returns a value > 32 on success.
    const result = w32.ShellExecuteW(null, wverb, wtarget, null, null, w32.SW_SHOW);
    if (result <= 32) {
        log.warn("ShellExecuteW {s} failed code={d}", .{ kind, result });
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Sounds
// ---------------------------------------------------------------------------

/// One WMUX_TEST_SOUND_SINK line.
const SoundRecord = struct {
    /// "message_beep" or "play_sound".
    kind: []const u8,
    /// What asked for the sound: "bell", ...
    source: []const u8,
    /// MessageBeep type (MB_OK, MB_ICONHAND, 0xFFFFFFFF ...); null for
    /// PlaySound.
    type: ?u32 = null,
    /// PlaySound alias or file; null for MessageBeep.
    sound: ?[]const u8 = null,
    timestamp_ms: i64,
};

/// MessageBeep(`beep_type`). In WMUX_TEST_MODE no sound is played: one
/// SoundRecord line goes to WMUX_TEST_SOUND_SINK instead.
pub fn messageBeep(app: *App, source: []const u8, beep_type: u32) void {
    if (app.runtime_env.test_mode) {
        const sink = app.runtime_env.test_sound_sink orelse return;
        appendRecord(app.core_app.alloc, sink, SoundRecord{
            .kind = "message_beep",
            .source = source,
            .type = beep_type,
            .timestamp_ms = std.time.milliTimestamp(),
        });
        return;
    }
    _ = w32.MessageBeep(beep_type);
}

const SND_ASYNC: u32 = 0x0001;
const SND_NODEFAULT: u32 = 0x0002;
const SND_ALIAS: u32 = 0x00010000;
const SND_FILENAME: u32 = 0x00020000;

pub const SoundSource = enum { alias, file };

/// PlaySoundW of a system sound alias or a .wav file, asynchronously and
/// without the default-sound fallback. In WMUX_TEST_MODE no sound is
/// played: one SoundRecord line goes to WMUX_TEST_SOUND_SINK instead.
pub fn playSound(app: *App, source: []const u8, sound: []const u8, from: SoundSource) void {
    if (app.runtime_env.test_mode) {
        const sink = app.runtime_env.test_sound_sink orelse return;
        appendRecord(app.core_app.alloc, sink, SoundRecord{
            .kind = "play_sound",
            .source = source,
            .sound = sound,
            .timestamp_ms = std.time.milliTimestamp(),
        });
        return;
    }
    const alloc = app.core_app.alloc;
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, sound) catch return;
    defer alloc.free(w);
    const flags = SND_ASYNC | SND_NODEFAULT | (if (from == .alias) SND_ALIAS else SND_FILENAME);
    _ = w32.PlaySoundW(w, null, flags);
}

// ---------------------------------------------------------------------------
// Test sinks
// ---------------------------------------------------------------------------

/// Serializes the sink writer threads so lines never interleave.
var sink_mutex: std.Thread.Mutex = .{};

/// Serialize `record` as one JSON line and append it to `path` on a
/// short worker thread. Best effort: failures are logged and dropped.
fn appendRecord(alloc: Allocator, path: []const u8, record: anytype) void {
    const line = formatRecord(alloc, record) catch return;
    const ctx = alloc.create(SinkWrite) catch {
        alloc.free(line);
        return;
    };
    const owned_path = alloc.dupe(u8, path) catch {
        alloc.free(line);
        alloc.destroy(ctx);
        return;
    };
    ctx.* = .{ .alloc = alloc, .path = owned_path, .line = line };
    const thread = std.Thread.spawn(.{}, sinkWorker, .{ctx}) catch {
        ctx.deinit();
        return;
    };
    thread.detach();
}

/// `record` as JSON plus a newline. Caller owns the result. Pure
/// (unit-tested).
pub fn formatRecord(alloc: Allocator, record: anytype) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    std.json.Stringify.value(record, .{}, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const SinkWrite = struct {
    alloc: Allocator,
    path: []u8,
    line: []u8,

    fn deinit(self: *SinkWrite) void {
        const alloc = self.alloc;
        alloc.free(self.path);
        alloc.free(self.line);
        alloc.destroy(self);
    }
};

fn sinkWorker(ctx: *SinkWrite) void {
    defer ctx.deinit();
    sink_mutex.lock();
    defer sink_mutex.unlock();
    appendLine(ctx.path, ctx.line) catch |err| {
        log.warn("test sink append failed: {}", .{err});
    };
}

/// Append `line` to the file at `path`, creating it (and its directory).
pub fn appendLine(path: []const u8, line: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: dialogs default button for message box auto-answers" {
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

test "unit: app: dialogs file dialog test answers default to cancel" {
    try testing.expectEqual(@as(?[]const u8, null), testAnswer(null));
    try testing.expectEqual(@as(?[]const u8, null), testAnswer(""));
    try testing.expectEqual(@as(?[]const u8, null), testAnswer("  "));
    try testing.expectEqual(@as(?[]const u8, null), testAnswer("Cancel"));
    try testing.expectEqualStrings("C:\\tmp\\pick.txt", testAnswer(" C:\\tmp\\pick.txt ").?);
}

test "unit: app: dialogs sink records are single JSON lines" {
    const alloc = testing.allocator;
    const ext = try formatRecord(alloc, ExternalRecord{
        .kind = "open_url",
        .verb = "open",
        .target = "https://example.invalid/a\"b",
        .timestamp_ms = 5,
    });
    defer alloc.free(ext);
    try testing.expectEqualStrings(
        "{\"kind\":\"open_url\",\"verb\":\"open\",\"target\":\"https://example.invalid/a\\\"b\",\"timestamp_ms\":5}\n",
        ext,
    );
    const beep = try formatRecord(alloc, SoundRecord{
        .kind = "message_beep",
        .source = "bell",
        .type = 0xFFFFFFFF,
        .timestamp_ms = 7,
    });
    defer alloc.free(beep);
    try testing.expectEqualStrings(
        "{\"kind\":\"message_beep\",\"source\":\"bell\",\"type\":4294967295,\"sound\":null,\"timestamp_ms\":7}\n",
        beep,
    );
}

test "unit: app: dialogs sink writer appends lines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sub", "sink.jsonl" });
    defer alloc.free(path);

    try appendLine(path, "{\"a\":1}\n");
    try appendLine(path, "{\"a\":2}\n");
    const got = try std.fs.cwd().readFileAlloc(alloc, path, 1024);
    defer alloc.free(got);
    try testing.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", got);
}

test "unit: app: dialogs IFileDialog vtable slots" {
    try testing.expectEqual(@as(usize, 3), @offsetOf(IFileDialog.VTable, "Show") / @sizeOf(usize));
    try testing.expectEqual(@as(usize, 9), @offsetOf(IFileDialog.VTable, "SetOptions") / @sizeOf(usize));
    try testing.expectEqual(@as(usize, 15), @offsetOf(IFileDialog.VTable, "SetFileName") / @sizeOf(usize));
    try testing.expectEqual(@as(usize, 17), @offsetOf(IFileDialog.VTable, "SetTitle") / @sizeOf(usize));
    try testing.expectEqual(@as(usize, 20), @offsetOf(IFileDialog.VTable, "GetResult") / @sizeOf(usize));
    try testing.expectEqual(@as(usize, 5), @offsetOf(IShellItem.VTable, "GetDisplayName") / @sizeOf(usize));
}

test "unit: app: dialogs test answers by name and the preset queue" {
    try testing.expectEqual(@as(?i32, 1), answerIdByName("OK"));
    try testing.expectEqual(@as(?i32, 7), answerIdByName("no"));
    try testing.expectEqual(@as(?i32, 10), answerIdByName("try_again"));
    try testing.expectEqual(@as(?i32, null), answerIdByName("maybe"));
    defer resetTestRecords();
    try testing.expectEqual(@as(usize, 1), try presetAnswer(6));
    try testing.expectEqual(@as(usize, 2), try presetAnswer(2));
    try testing.expectEqual(@as(?i32, 6), takePresetAnswer());
    try testing.expectEqual(@as(?i32, 2), takePresetAnswer());
    try testing.expectEqual(@as(?i32, null), takePresetAnswer());
    recordDialog(std.unicode.utf8ToUtf16LeStringLiteral("Close?"), std.unicode.utf8ToUtf16LeStringLiteral("wmux"), 1, 2);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const list = try testRecords(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("Close?", list[0].text);
    try testing.expectEqualStrings("wmux", list[0].caption);
    try testing.expectEqual(@as(i32, 2), list[0].answer);
}
