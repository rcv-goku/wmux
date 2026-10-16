//! Legacy wmux-v1 JSON commands of the `browser` feature: open, navigate,
//! eval, snapshot, click, fill (`wmux +browser ...`). eval/snapshot/click/
//! fill answer asynchronously from the WebView2/CDP completion in
//! BrowserPane; their handlers only reply on a synchronous setup error.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-8
//! re-points them to the v2 `browser.*` methods (Appendix B.4).

const std = @import("std");

const App = @import("../../App.zig");
const BrowserPane = @import("../../BrowserPane.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");

const IpcError = targets.IpcError;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "open", .handler = &ipcOpen },
    .{ .cmd = "navigate", .handler = &ipcNavigate },
    .{ .cmd = "eval", .handler = &ipcEval },
    .{ .cmd = "snapshot", .handler = &ipcSnapshot, .read_only = true },
    .{ .cmd = "click", .handler = &ipcClick },
    .{ .cmd = "fill", .handler = &ipcFill },
};

/// Find a browser pane by its IPC id across all live windows, or the
/// most-recently-created browser pane (highest id) when `id` is null.
fn ipcFindBrowser(self: *App, id: ?u32) ?*BrowserPane {
    var best: ?*BrowserPane = null;
    for (self.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces[0..w.workspace_count]) |*ws| {
            var tree_it = ws.split_tree.iterator();
            while (tree_it.next()) |tree_entry| {
                const container = tree_entry.view;
                for (container.tabs[0..container.tab_count]) |tab_pane| {
                    const browser = switch (tab_pane.content) {
                        .browser => |b| b,
                        .terminal => continue,
                    };
                    if (id) |want| {
                        if (browser.ipc_id == want) return browser;
                    } else if (best == null or browser.ipc_id > best.?.ipc_id) {
                        best = browser;
                    }
                }
            }
        }
    }
    return best;
}

/// Read an optional u32 "id" field from the request args.
/// (Pure logic lives in legacy_json.zig so the protocol tests cover it.)
const ipcArgId = ipc.argId;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read an i64 field (the CDP backendNodeId `ref`) from the request args.
const ipcArgI64 = ipc.argI64;

/// open {url, [target: "split"|"tab"]} → create a browser pane in the
/// target window, navigate to url, reply with its assigned id.
fn ipcOpen(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const url = ipcArgString(req, "url") orelse return IpcError.MissingUrl;
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;

    const as_tab = if (ipcArgString(req, "target")) |t|
        std.mem.eql(u8, t, "tab")
    else
        false;

    if (as_tab) {
        try window.addBrowserTab();
    } else {
        try window.newBrowserSplit(.right);
    }

    // The just-created pane is the window's active pane.
    const pane = window.getActiveTab() orelse return IpcError.NoWindow;
    const browser = switch (pane.content) {
        .browser => |b| b,
        .terminal => return IpcError.NoWindow,
    };

    var url_w: [2049]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(url_w[0 .. url_w.len - 1], url) catch
        return IpcError.UrlTooLong;
    url_w[wlen] = 0;
    browser.navigateUrl(url_w[0..wlen :0]) catch {};

    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"id\":{d}}}", .{browser.ipc_id}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// navigate {[id], url} → navigate the addressed (or most-recent)
/// browser pane.
fn ipcNavigate(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const url = ipcArgString(req, "url") orelse return IpcError.MissingUrl;
    const browser = ipcFindBrowser(self, ipcArgId(req)) orelse return IpcError.UnknownId;

    var url_w: [2049]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(url_w[0 .. url_w.len - 1], url) catch
        return IpcError.UrlTooLong;
    url_w[wlen] = 0;
    browser.navigateUrl(url_w[0..wlen :0]) catch {};
    server.sendOk(req.id, null) catch {};
}

/// eval {[id], js} → run js in the addressed (or most-recent) browser
/// pane. The reply is sent asynchronously by the ExecuteScript
/// completion (BrowserPane.evalForIpc), so this returns without sending.
fn ipcEval(self: *App, req: *ipc.Request) anyerror!void {
    const js = ipcArgString(req, "js") orelse return IpcError.MissingScript;
    const browser = ipcFindBrowser(self, ipcArgId(req)) orelse return IpcError.UnknownId;

    const alloc = self.core_app.alloc;
    const js_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, js) catch
        return error.OutOfMemory;
    defer alloc.free(js_w);
    browser.evalForIpc(req.id, js_w);
}

/// snapshot {[id]} → walk the addressed (or most-recent) browser pane's
/// accessibility tree over CDP and reply with a compact [{ref,role,name}]
/// array. Answered asynchronously by the CDP completion chain.
fn ipcSnapshot(self: *App, req: *ipc.Request) anyerror!void {
    const browser = ipcFindBrowser(self, ipcArgId(req)) orelse return IpcError.UnknownId;
    browser.snapshotForIpc(req.id);
}

/// click {[id], ref} → click the element with backendNodeId `ref` in the
/// addressed (or most-recent) browser pane. Answered asynchronously.
fn ipcClick(self: *App, req: *ipc.Request) anyerror!void {
    const ref = ipcArgI64(req, "ref") orelse return IpcError.MissingRef;
    const browser = ipcFindBrowser(self, ipcArgId(req)) orelse return IpcError.UnknownId;
    browser.clickForIpc(req.id, ref);
}

/// fill {[id], ref, text} → focus the element with backendNodeId `ref`
/// and insert `text` in the addressed (or most-recent) browser pane.
/// Answered asynchronously.
fn ipcFill(self: *App, req: *ipc.Request) anyerror!void {
    const ref = ipcArgI64(req, "ref") orelse return IpcError.MissingRef;
    const text = ipcArgString(req, "text") orelse return IpcError.MissingText;
    const browser = ipcFindBrowser(self, ipcArgId(req)) orelse return IpcError.UnknownId;
    browser.fillForIpc(req.id, ref, text);
}
