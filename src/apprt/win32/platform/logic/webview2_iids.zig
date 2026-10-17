//! WebView2 SDK fixture table and the pure COM helpers behind
//! `platform/webview2.zig` (W1-6b, ADR-6.10). std-only, runs on any OS.
//!
//! `entries` holds, for every interface `webview2.zig` binds (consumed
//! interfaces, host-implemented callback handlers and IUnknown), the IID,
//! the parent interface, the total vtable slot count (inherited slots
//! included) and the own slot names in declaration order. It was parsed
//! from `build/native/include/WebView2.h` of the Microsoft.Web.WebView2
//! NuGet package, version `sdk_version` (nupkg SHA-512 from the nuget.org
//! catalog, base64:
//! HlGVwvyP/IWiXAU8K57Vmg59khY3DWMOxMnH4AHusFRy0/vDAjKItXUIVNXiXXaq4CLfSZyNUic1wOIlnPLsPQ==),
//! from the C `<Interface>Vtbl` structs, which list inherited slots first.
//! The header itself is not committed; to bind a new interface, add it to
//! the table from the same (or a newer) header and `webview2.zig` checks
//! its binding against the row at comptime.
const std = @import("std");

/// Microsoft.Web.WebView2 NuGet package the table was taken from.
pub const sdk_version = "1.0.4258.31";

/// `CORE_WEBVIEW_TARGET_PRODUCT_VERSION` of the same package
/// (WebView2EnvironmentOptions.h): the default
/// `TargetCompatibleBrowserVersion` a host-implemented
/// ICoreWebView2EnvironmentOptions reports.
pub const target_browser_version = "154.0.4258.31";

/// Every COM interface starts with IUnknown's QueryInterface, AddRef and
/// Release.
pub const iunknown_slot_count = 3;

// ─── GUID ───────────────────────────────────────────────────────────────

/// Same memory layout as the Win32 GUID (and `std.os.windows.GUID`), so a
/// pointer to one may be reinterpreted as the other.
pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub const zero: Guid = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = .{0} ** 8 };

    pub const ParseError = error{InvalidGuid};

    /// Parses `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, optionally wrapped in
    /// one pair of braces, hex digits in either case. Anything else
    /// (missing or misplaced dashes, stray characters, wrong length,
    /// unbalanced braces) is `error.InvalidGuid`.
    pub fn parse(text: []const u8) ParseError!Guid {
        var s = text;
        if (s.len == 38) {
            if (s[0] != '{' or s[37] != '}') return error.InvalidGuid;
            s = s[1..37];
        }
        if (s.len != 36) return error.InvalidGuid;
        for ([_]usize{ 8, 13, 18, 23 }) |i| {
            if (s[i] != '-') return error.InvalidGuid;
        }
        var g: Guid = undefined;
        g.data1 = try hexInt(u32, s[0..8]);
        g.data2 = try hexInt(u16, s[9..13]);
        g.data3 = try hexInt(u16, s[14..18]);
        g.data4[0] = try hexInt(u8, s[19..21]);
        g.data4[1] = try hexInt(u8, s[21..23]);
        for (0..6) |i| {
            g.data4[2 + i] = try hexInt(u8, s[24 + 2 * i ..][0..2]);
        }
        return g;
    }

    /// Comptime parse of a literal; a malformed literal is a compile error.
    pub fn comptimeParse(comptime text: []const u8) Guid {
        return comptime parse(text) catch @compileError("invalid GUID literal: " ++ text);
    }

    /// Lowercase `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (the WebView2.h
    /// spelling) into `buf`.
    pub fn bufPrint(self: Guid, buf: *[36]u8) []const u8 {
        const hex = "0123456789abcdef";
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.data1, .big);
        std.mem.writeInt(u16, bytes[4..6], self.data2, .big);
        std.mem.writeInt(u16, bytes[6..8], self.data3, .big);
        bytes[8..16].* = self.data4;
        var o: usize = 0;
        for (bytes, 0..) |b, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[o] = '-';
                o += 1;
            }
            buf[o] = hex[b >> 4];
            buf[o + 1] = hex[b & 0xf];
            o += 2;
        }
        return buf[0..36];
    }

    /// `{f}` formatting: the braced registry form `{xxxxxxxx-...}`.
    pub fn format(self: Guid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [36]u8 = undefined;
        try w.writeByte('{');
        try w.writeAll(self.bufPrint(&buf));
        try w.writeByte('}');
    }

    pub fn eql(a: Guid, b: Guid) bool {
        return a.data1 == b.data1 and a.data2 == b.data2 and a.data3 == b.data3 and
            std.mem.eql(u8, &a.data4, &b.data4);
    }
};

fn hexInt(comptime T: type, digits: []const u8) Guid.ParseError!T {
    var v: T = 0;
    for (digits) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidGuid,
        };
        v = (v << 4) | @as(T, @intCast(d));
    }
    return v;
}

// ─── Fixture table ──────────────────────────────────────────────────────

pub const Entry = struct {
    /// Interface name as in WebView2.h.
    name: []const u8,
    /// IID as in the header's MIDL_INTERFACE("...") (lowercase, no braces).
    iid: []const u8,
    /// Direct parent interface ("" for IUnknown itself).
    parent: []const u8,
    /// Total vtable slots, inherited ones included.
    slot_count: u16,
    /// Own slot names in declaration order; the first one is slot
    /// `slot_count - slots.len`.
    slots: []const []const u8,

    pub fn guid(self: *const Entry) Guid {
        return Guid.parse(self.iid) catch unreachable; // checked by the tests
    }

    /// Index of the first own slot.
    pub fn firstSlot(self: *const Entry) u16 {
        return self.slot_count - @as(u16, @intCast(self.slots.len));
    }
};

const by_name = blk: {
    @setEvalBranchQuota(1_000_000);
    var kvs: [entries.len]struct { []const u8, u16 } = undefined;
    for (entries, 0..) |e, i| kvs[i] = .{ e.name, i };
    break :blk std.StaticStringMap(u16).initComptime(kvs);
};

/// Row for an interface name, or null when it is not bound.
pub fn find(name: []const u8) ?*const Entry {
    const i = by_name.get(name) orelse return null;
    return &entries[i];
}

/// Name of vtable slot `index` of `name`, walking the parent chain;
/// null for unknown interfaces and out-of-range indexes.
pub fn slotName(name: []const u8, index: usize) ?[]const u8 {
    var e = find(name) orelse return null;
    if (index >= e.slot_count) return null;
    while (true) {
        const first = e.firstSlot();
        if (index >= first) return e.slots[index - first];
        e = find(e.parent) orelse return null;
    }
}

/// Maximum inheritance depth `chain` reports (ICoreWebView2_16 needs 17
/// plus IUnknown).
pub const max_chain = 32;

/// IIDs `name` answers QueryInterface for: itself, then every ancestor up
/// to and including IUnknown. Returns the filled prefix of `buf`, or null
/// for an unknown interface or a broken chain.
pub fn chain(name: []const u8, buf: *[max_chain]Guid) ?[]const Guid {
    var n: usize = 0;
    var cur = name;
    while (cur.len != 0) {
        const e = find(cur) orelse return null;
        if (n == buf.len) return null;
        buf[n] = e.guid();
        n += 1;
        cur = e.parent;
    }
    return buf[0..n];
}

/// Pure core of a host object's QueryInterface: true when `riid` is one
/// of the interfaces the object implements (which must list IUnknown,
/// `chain` does). The caller then AddRefs and hands out the pointer, or
/// writes null and returns E_NOINTERFACE.
pub fn qiMatches(riid: Guid, implemented: []const Guid) bool {
    for (implemented) |g| {
        if (g.eql(riid)) return true;
    }
    return false;
}

/// Comptime `chain` for host objects: `[N]Guid` for `name` and all of its
/// ancestors. A name missing from the table is a compile error.
pub fn comptimeChain(comptime name: []const u8) []const Guid {
    return &struct {
        const value = blk: {
            var buf: [max_chain]Guid = undefined;
            const c = chain(name, &buf) orelse @compileError("not in the WebView2 fixture table: " ++ name);
            break :blk c[0..c.len].*;
        };
    }.value;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: platform: guid parses braced, bare and mixed-case forms" {
    const a = try Guid.parse("{76eceacb-0462-4d94-ac83-423a6793775e}");
    const b = try Guid.parse("76ECEACB-0462-4D94-AC83-423A6793775E");
    try testing.expect(a.eql(b));
    try testing.expectEqual(@as(u32, 0x76eceacb), a.data1);
    try testing.expectEqual(@as(u16, 0x0462), a.data2);
    try testing.expectEqual(@as(u16, 0x4d94), a.data3);
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e }, &a.data4);
}

test "unit: platform: guid rejects malformed input" {
    const bad = [_][]const u8{
        "",
        "{}",
        "76eceacb-0462-4d94-ac83-423a6793775",
        "76eceacb-0462-4d94-ac83-423a6793775e0",
        "{76eceacb-0462-4d94-ac83-423a6793775e",
        "76eceacb-0462-4d94-ac83-423a6793775e}",
        "(76eceacb-0462-4d94-ac83-423a6793775e)",
        "76eceacb04624d94ac83423a6793775e0000",
        "76eceacb-0462-4d94-ac83_423a6793775e",
        "76eceacg-0462-4d94-ac83-423a6793775e",
        "76eceacb-+462-4d94-ac83-423a6793775e",
        "76eceacb-0462-4d94-ac83-423a6793775\u{e9}",
        "{{76eceacb-0462-4d94-ac83-423a67937}}",
    };
    for (bad) |s| try testing.expectError(error.InvalidGuid, Guid.parse(s));
}

test "unit: platform: guid formats lowercase and round-trips" {
    const g = try Guid.parse("{B29C7E28-FA79-41A8-8E44-65811C76DCB2}");
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings("b29c7e28-fa79-41a8-8e44-65811c76dcb2", g.bufPrint(&buf));
    var out: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&out, "{f}", .{g});
    try testing.expectEqualStrings("{b29c7e28-fa79-41a8-8e44-65811c76dcb2}", s);
    try testing.expect((try Guid.parse(s)).eql(g));
    // Boundaries: all zeros and all ones.
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", Guid.zero.bufPrint(&buf));
    const ones = try Guid.parse("ffffffff-ffff-ffff-ffff-ffffffffffff");
    try testing.expectEqual(@as(u32, 0xffffffff), ones.data1);
    try testing.expectEqualStrings("ffffffff-ffff-ffff-ffff-ffffffffffff", ones.bufPrint(&buf));
}

test "unit: platform: guid layout matches the Win32 GUID" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Guid));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Guid, "data2"));
    try testing.expectEqual(@as(usize, 6), @offsetOf(Guid, "data3"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Guid, "data4"));
    const ct = comptime Guid.comptimeParse("{00000000-0000-0000-c000-000000000046}");
    try testing.expect(ct.eql(find("IUnknown").?.guid()));
}

test "unit: platform: every fixture IID is a canonical lowercase GUID" {
    var buf: [36]u8 = undefined;
    for (entries) |e| {
        const g = Guid.parse(e.iid) catch |err| {
            std.log.err("bad iid for {s}", .{e.name});
            return err;
        };
        try testing.expectEqualStrings(e.iid, g.bufPrint(&buf));
    }
}

test "unit: platform: fixture names and IIDs are unique" {
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
            try testing.expect(!a.guid().eql(b.guid()));
        }
    }
}

test "unit: platform: every vtable has the asserted slot count" {
    for (entries) |e| {
        if (e.parent.len == 0) {
            try testing.expectEqualStrings("IUnknown", e.name);
            try testing.expectEqual(@as(u16, iunknown_slot_count), e.slot_count);
            continue;
        }
        const p = find(e.parent) orelse {
            std.log.err("{s}: parent {s} not in table", .{ e.name, e.parent });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(p.slot_count + e.slots.len, e.slot_count);
        try testing.expect(e.slots.len > 0);
        // Callback handlers are IUnknown + Invoke.
        if (std.mem.endsWith(u8, e.name, "Handler")) {
            try testing.expectEqual(@as(u16, 4), e.slot_count);
            try testing.expectEqualStrings("Invoke", e.slots[0]);
        }
    }
}

test "unit: platform: fixture spot checks against WebView2.h" {
    const Spot = struct { []const u8, []const u8, u16 };
    const spots = [_]Spot{
        .{ "ICoreWebView2", "76eceacb-0462-4d94-ac83-423a6793775e", 61 },
        .{ "ICoreWebView2Controller", "4d00c0d1-9434-4eb6-8078-8697a560334f", 26 },
        .{ "ICoreWebView2Environment", "b96d755e-0319-4e92-a296-23436f46a1fc", 8 },
        .{ "ICoreWebView2AcceleratorKeyPressedEventHandler", "b29c7e28-fa79-41a8-8e44-65811c76dcb2", 4 },
        .{ "ICoreWebView2DevToolsProtocolEventReceivedEventHandler", "e2fda4be-5456-406c-a261-3d452138362c", 4 },
    };
    for (spots) |s| {
        const e = find(s[0]).?;
        try testing.expectEqualStrings(s[1], e.iid);
        try testing.expectEqual(s[2], e.slot_count);
    }
    try testing.expectEqualStrings("get_Settings", slotName("ICoreWebView2", 3).?);
    try testing.expectEqualStrings("remove_WindowCloseRequested", slotName("ICoreWebView2", 60).?);
    try testing.expectEqualStrings("get_CoreWebView2", slotName("ICoreWebView2Controller", 25).?);
}

test "unit: platform: the ADR-6.10 interface set is bound" {
    const required = [_][]const u8{
        "ICoreWebView2_2",                            "ICoreWebView2_3",                            "ICoreWebView2_4",
        "ICoreWebView2_5",                            "ICoreWebView2_7",                            "ICoreWebView2_8",
        "ICoreWebView2_9",                            "ICoreWebView2_10",                           "ICoreWebView2_11",
        "ICoreWebView2_12",                           "ICoreWebView2_13",                           "ICoreWebView2_14",
        "ICoreWebView2_15",                           "ICoreWebView2_16",                           "ICoreWebView2Controller2",
        "ICoreWebView2Controller3",                   "ICoreWebView2Controller4",                   "ICoreWebView2Settings",
        "ICoreWebView2Settings8",                     "ICoreWebView2Environment2",                  "ICoreWebView2Environment5",
        "ICoreWebView2Environment8",                  "ICoreWebView2Environment10",                 "ICoreWebView2ControllerOptions",
        "ICoreWebView2EnvironmentOptions",            "ICoreWebView2ProcessInfo",                   "ICoreWebView2BasicAuthenticationResponse",
        "ICoreWebView2DownloadOperation",             "ICoreWebView2CookieManager",                 "ICoreWebView2ContextMenuItem",
        "ICoreWebView2PermissionRequestedEventArgs",  "ICoreWebView2ScriptDialogOpeningEventArgs",  "ICoreWebView2NewWindowRequestedEventArgs",
        "ICoreWebView2WebResourceRequestedEventArgs", "ICoreWebView2ClientCertificate",             "ICoreWebView2ServerCertificateErrorDetectedEventArgs",
        "ICoreWebView2FaviconChangedEventHandler",    "ICoreWebView2BrowserProcessExitedEventArgs", "ICoreWebView2ProcessInfosChangedEventHandler",
    };
    for (required) |name| {
        if (find(name) == null) {
            std.log.err("missing {s}", .{name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(slotName("ICoreWebView2Settings8", 0) != null);
    try testing.expectEqualStrings("get_IsReputationCheckingRequired", find("ICoreWebView2Settings8").?.slots[0]);
    try testing.expectEqualStrings("add_BrowserProcessExited", find("ICoreWebView2Environment5").?.slots[0]);
}

test "unit: platform: slot names are unique within each full vtable" {
    for (entries) |e| {
        var i: usize = 0;
        while (i < e.slot_count) : (i += 1) {
            const a = slotName(e.name, i).?;
            var j: usize = i + 1;
            while (j < e.slot_count) : (j += 1) {
                try testing.expect(!std.mem.eql(u8, a, slotName(e.name, j).?));
            }
        }
    }
}

test "unit: platform: slotName boundaries and unknown names" {
    try testing.expectEqualStrings("QueryInterface", slotName("ICoreWebView2_16", 0).?);
    try testing.expectEqualStrings("Release", slotName("ICoreWebView2_16", 2).?);
    const e = find("ICoreWebView2_16").?;
    try testing.expectEqualStrings(e.slots[e.slots.len - 1], slotName("ICoreWebView2_16", e.slot_count - 1).?);
    try testing.expect(slotName("ICoreWebView2_16", e.slot_count) == null);
    try testing.expect(slotName("ICoreWebView2_16", std.math.maxInt(usize)) == null);
    try testing.expect(slotName("", 0) == null);
    try testing.expect(slotName("ICoreWebView2_99", 0) == null);
    try testing.expect(find("icorewebview2") == null);
    try testing.expect(find("ICoreWebView2\u{2603}") == null);
}

test "unit: platform: chain walks to IUnknown and drives the qi decision" {
    var buf: [max_chain]Guid = undefined;
    const c = chain("ICoreWebView2_16", &buf).?;
    try testing.expectEqual(@as(usize, 17), c.len);
    try testing.expect(c[0].eql(find("ICoreWebView2_16").?.guid()));
    try testing.expect(c[15].eql(find("ICoreWebView2").?.guid()));
    try testing.expect(c[16].eql(find("IUnknown").?.guid()));
    try testing.expect(chain("NoSuchInterface", &buf) == null);
    try testing.expectEqual(@as(usize, 1), chain("IUnknown", &buf).?.len);

    const opts = comptimeChain("ICoreWebView2EnvironmentOptions");
    try testing.expectEqual(@as(usize, 2), opts.len);
    try testing.expect(qiMatches(find("IUnknown").?.guid(), opts));
    try testing.expect(qiMatches(find("ICoreWebView2EnvironmentOptions").?.guid(), opts));
    try testing.expect(!qiMatches(find("ICoreWebView2").?.guid(), opts));
    try testing.expect(!qiMatches(Guid.zero, opts));
    try testing.expect(!qiMatches(Guid.zero, &.{}));
}

// ─── Fixture rows (parsed from WebView2.h, SDK 1.0.4258.31) ────────────

pub const entries = [_]Entry{
    .{ .name = "IUnknown", .iid = "00000000-0000-0000-c000-000000000046", .parent = "", .slot_count = 3, .slots = &.{ "QueryInterface", "AddRef", "Release" } },
    .{
        .name = "ICoreWebView2Environment",
        .iid = "b96d755e-0319-4e92-a296-23436f46a1fc",
        .parent = "IUnknown",
        .slot_count = 8,
        .slots = &.{
            "CreateCoreWebView2Controller",
            "CreateWebResourceResponse",
            "get_BrowserVersionString",
            "add_NewBrowserVersionAvailable",
            "remove_NewBrowserVersionAvailable",
        },
    },
    .{
        .name = "ICoreWebView2Controller",
        .iid = "4d00c0d1-9434-4eb6-8078-8697a560334f",
        .parent = "IUnknown",
        .slot_count = 26,
        .slots = &.{
            "get_IsVisible",
            "put_IsVisible",
            "get_Bounds",
            "put_Bounds",
            "get_ZoomFactor",
            "put_ZoomFactor",
            "add_ZoomFactorChanged",
            "remove_ZoomFactorChanged",
            "SetBoundsAndZoomFactor",
            "MoveFocus",
            "add_MoveFocusRequested",
            "remove_MoveFocusRequested",
            "add_GotFocus",
            "remove_GotFocus",
            "add_LostFocus",
            "remove_LostFocus",
            "add_AcceleratorKeyPressed",
            "remove_AcceleratorKeyPressed",
            "get_ParentWindow",
            "put_ParentWindow",
            "NotifyParentWindowPositionChanged",
            "Close",
            "get_CoreWebView2",
        },
    },
    .{
        .name = "ICoreWebView2",
        .iid = "76eceacb-0462-4d94-ac83-423a6793775e",
        .parent = "IUnknown",
        .slot_count = 61,
        .slots = &.{
            "get_Settings",
            "get_Source",
            "Navigate",
            "NavigateToString",
            "add_NavigationStarting",
            "remove_NavigationStarting",
            "add_ContentLoading",
            "remove_ContentLoading",
            "add_SourceChanged",
            "remove_SourceChanged",
            "add_HistoryChanged",
            "remove_HistoryChanged",
            "add_NavigationCompleted",
            "remove_NavigationCompleted",
            "add_FrameNavigationStarting",
            "remove_FrameNavigationStarting",
            "add_FrameNavigationCompleted",
            "remove_FrameNavigationCompleted",
            "add_ScriptDialogOpening",
            "remove_ScriptDialogOpening",
            "add_PermissionRequested",
            "remove_PermissionRequested",
            "add_ProcessFailed",
            "remove_ProcessFailed",
            "AddScriptToExecuteOnDocumentCreated",
            "RemoveScriptToExecuteOnDocumentCreated",
            "ExecuteScript",
            "CapturePreview",
            "Reload",
            "PostWebMessageAsJson",
            "PostWebMessageAsString",
            "add_WebMessageReceived",
            "remove_WebMessageReceived",
            "CallDevToolsProtocolMethod",
            "get_BrowserProcessId",
            "get_CanGoBack",
            "get_CanGoForward",
            "GoBack",
            "GoForward",
            "GetDevToolsProtocolEventReceiver",
            "Stop",
            "add_NewWindowRequested",
            "remove_NewWindowRequested",
            "add_DocumentTitleChanged",
            "remove_DocumentTitleChanged",
            "get_DocumentTitle",
            "AddHostObjectToScript",
            "RemoveHostObjectFromScript",
            "OpenDevToolsWindow",
            "add_ContainsFullScreenElementChanged",
            "remove_ContainsFullScreenElementChanged",
            "get_ContainsFullScreenElement",
            "add_WebResourceRequested",
            "remove_WebResourceRequested",
            "AddWebResourceRequestedFilter",
            "RemoveWebResourceRequestedFilter",
            "add_WindowCloseRequested",
            "remove_WindowCloseRequested",
        },
    },
    .{
        .name = "ICoreWebView2NavigationCompletedEventArgs",
        .iid = "30d68b7d-20d9-4752-a9ca-ec8448fbb5c1",
        .parent = "IUnknown",
        .slot_count = 6,
        .slots = &.{
            "get_IsSuccess",
            "get_WebErrorStatus",
            "get_NavigationId",
        },
    },
    .{
        .name = "ICoreWebView2AcceleratorKeyPressedEventArgs",
        .iid = "9f760f8a-fb79-42be-9990-7b56900fa9c7",
        .parent = "IUnknown",
        .slot_count = 9,
        .slots = &.{
            "get_KeyEventKind",
            "get_VirtualKey",
            "get_KeyEventLParam",
            "get_PhysicalKeyStatus",
            "get_Handled",
            "put_Handled",
        },
    },
    .{
        .name = "ICoreWebView2DevToolsProtocolEventReceiver",
        .iid = "b32ca51a-8371-45e9-9317-af021d080367",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "add_DevToolsProtocolEventReceived",
            "remove_DevToolsProtocolEventReceived",
        },
    },
    .{
        .name = "ICoreWebView2DevToolsProtocolEventReceivedEventArgs",
        .iid = "653c2959-bb3a-4377-8632-b58ada4e66c4",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "get_ParameterObjectAsJson",
        },
    },
    .{
        .name = "ICoreWebView2_2",
        .iid = "9e8f0cf8-e670-4b5e-b2bc-73e061e3184c",
        .parent = "ICoreWebView2",
        .slot_count = 68,
        .slots = &.{
            "add_WebResourceResponseReceived",
            "remove_WebResourceResponseReceived",
            "NavigateWithWebResourceRequest",
            "add_DOMContentLoaded",
            "remove_DOMContentLoaded",
            "get_CookieManager",
            "get_Environment",
        },
    },
    .{
        .name = "ICoreWebView2_3",
        .iid = "a0d6df20-3b92-416d-aa0c-437a9c727857",
        .parent = "ICoreWebView2_2",
        .slot_count = 73,
        .slots = &.{
            "TrySuspend",
            "Resume",
            "get_IsSuspended",
            "SetVirtualHostNameToFolderMapping",
            "ClearVirtualHostNameToFolderMapping",
        },
    },
    .{
        .name = "ICoreWebView2_4",
        .iid = "20d02d59-6df2-42dc-bd06-f98a694b1302",
        .parent = "ICoreWebView2_3",
        .slot_count = 77,
        .slots = &.{
            "add_FrameCreated",
            "remove_FrameCreated",
            "add_DownloadStarting",
            "remove_DownloadStarting",
        },
    },
    .{
        .name = "ICoreWebView2_5",
        .iid = "bedb11b8-d63c-11eb-b8bc-0242ac130003",
        .parent = "ICoreWebView2_4",
        .slot_count = 79,
        .slots = &.{
            "add_ClientCertificateRequested",
            "remove_ClientCertificateRequested",
        },
    },
    .{
        .name = "ICoreWebView2_6",
        .iid = "499aadac-d92c-4589-8a75-111bfc167795",
        .parent = "ICoreWebView2_5",
        .slot_count = 80,
        .slots = &.{
            "OpenTaskManagerWindow",
        },
    },
    .{
        .name = "ICoreWebView2_7",
        .iid = "79c24d83-09a3-45ae-9418-487f32a58740",
        .parent = "ICoreWebView2_6",
        .slot_count = 81,
        .slots = &.{
            "PrintToPdf",
        },
    },
    .{
        .name = "ICoreWebView2_8",
        .iid = "e9632730-6e1e-43ab-b7b8-7b2c9e62e094",
        .parent = "ICoreWebView2_7",
        .slot_count = 88,
        .slots = &.{
            "add_IsMutedChanged",
            "remove_IsMutedChanged",
            "get_IsMuted",
            "put_IsMuted",
            "add_IsDocumentPlayingAudioChanged",
            "remove_IsDocumentPlayingAudioChanged",
            "get_IsDocumentPlayingAudio",
        },
    },
    .{
        .name = "ICoreWebView2_9",
        .iid = "4d7b2eab-9fdc-468d-b998-a9260b5ed651",
        .parent = "ICoreWebView2_8",
        .slot_count = 97,
        .slots = &.{
            "add_IsDefaultDownloadDialogOpenChanged",
            "remove_IsDefaultDownloadDialogOpenChanged",
            "get_IsDefaultDownloadDialogOpen",
            "OpenDefaultDownloadDialog",
            "CloseDefaultDownloadDialog",
            "get_DefaultDownloadDialogCornerAlignment",
            "put_DefaultDownloadDialogCornerAlignment",
            "get_DefaultDownloadDialogMargin",
            "put_DefaultDownloadDialogMargin",
        },
    },
    .{
        .name = "ICoreWebView2_10",
        .iid = "b1690564-6f5a-4983-8e48-31d1143fecdb",
        .parent = "ICoreWebView2_9",
        .slot_count = 99,
        .slots = &.{
            "add_BasicAuthenticationRequested",
            "remove_BasicAuthenticationRequested",
        },
    },
    .{
        .name = "ICoreWebView2_11",
        .iid = "0be78e56-c193-4051-b943-23b460c08bdb",
        .parent = "ICoreWebView2_10",
        .slot_count = 102,
        .slots = &.{
            "CallDevToolsProtocolMethodForSession",
            "add_ContextMenuRequested",
            "remove_ContextMenuRequested",
        },
    },
    .{
        .name = "ICoreWebView2_12",
        .iid = "35d69927-bcfa-4566-9349-6b3e0d154cac",
        .parent = "ICoreWebView2_11",
        .slot_count = 105,
        .slots = &.{
            "add_StatusBarTextChanged",
            "remove_StatusBarTextChanged",
            "get_StatusBarText",
        },
    },
    .{
        .name = "ICoreWebView2_13",
        .iid = "f75f09a8-667e-4983-88d6-c8773f315e84",
        .parent = "ICoreWebView2_12",
        .slot_count = 106,
        .slots = &.{
            "get_Profile",
        },
    },
    .{
        .name = "ICoreWebView2_14",
        .iid = "6daa4f10-4a90-4753-8898-77c5df534165",
        .parent = "ICoreWebView2_13",
        .slot_count = 109,
        .slots = &.{
            "add_ServerCertificateErrorDetected",
            "remove_ServerCertificateErrorDetected",
            "ClearServerCertificateErrorActions",
        },
    },
    .{
        .name = "ICoreWebView2_15",
        .iid = "517b2d1d-7dae-4a66-a4f4-10352ffb9518",
        .parent = "ICoreWebView2_14",
        .slot_count = 113,
        .slots = &.{
            "add_FaviconChanged",
            "remove_FaviconChanged",
            "get_FaviconUri",
            "GetFavicon",
        },
    },
    .{
        .name = "ICoreWebView2_16",
        .iid = "0eb34dc9-9f91-41e1-8639-95cd5943906b",
        .parent = "ICoreWebView2_15",
        .slot_count = 116,
        .slots = &.{
            "Print",
            "ShowPrintUI",
            "PrintToPdfStream",
        },
    },
    .{
        .name = "ICoreWebView2Controller2",
        .iid = "c979903e-d4ca-4228-92eb-47ee3fa96eab",
        .parent = "ICoreWebView2Controller",
        .slot_count = 28,
        .slots = &.{
            "get_DefaultBackgroundColor",
            "put_DefaultBackgroundColor",
        },
    },
    .{
        .name = "ICoreWebView2Controller3",
        .iid = "f9614724-5d2b-41dc-aef7-73d62b51543b",
        .parent = "ICoreWebView2Controller2",
        .slot_count = 36,
        .slots = &.{
            "get_RasterizationScale",
            "put_RasterizationScale",
            "get_ShouldDetectMonitorScaleChanges",
            "put_ShouldDetectMonitorScaleChanges",
            "add_RasterizationScaleChanged",
            "remove_RasterizationScaleChanged",
            "get_BoundsMode",
            "put_BoundsMode",
        },
    },
    .{
        .name = "ICoreWebView2Controller4",
        .iid = "97d418d5-a426-4e49-a151-e1a10f327d9e",
        .parent = "ICoreWebView2Controller3",
        .slot_count = 38,
        .slots = &.{
            "get_AllowExternalDrop",
            "put_AllowExternalDrop",
        },
    },
    .{
        .name = "ICoreWebView2Settings",
        .iid = "e562e4f0-d7fa-43ac-8d71-c05150499f00",
        .parent = "IUnknown",
        .slot_count = 21,
        .slots = &.{
            "get_IsScriptEnabled",
            "put_IsScriptEnabled",
            "get_IsWebMessageEnabled",
            "put_IsWebMessageEnabled",
            "get_AreDefaultScriptDialogsEnabled",
            "put_AreDefaultScriptDialogsEnabled",
            "get_IsStatusBarEnabled",
            "put_IsStatusBarEnabled",
            "get_AreDevToolsEnabled",
            "put_AreDevToolsEnabled",
            "get_AreDefaultContextMenusEnabled",
            "put_AreDefaultContextMenusEnabled",
            "get_AreHostObjectsAllowed",
            "put_AreHostObjectsAllowed",
            "get_IsZoomControlEnabled",
            "put_IsZoomControlEnabled",
            "get_IsBuiltInErrorPageEnabled",
            "put_IsBuiltInErrorPageEnabled",
        },
    },
    .{
        .name = "ICoreWebView2Settings2",
        .iid = "ee9a0f68-f46c-4e32-ac23-ef8cac224d2a",
        .parent = "ICoreWebView2Settings",
        .slot_count = 23,
        .slots = &.{
            "get_UserAgent",
            "put_UserAgent",
        },
    },
    .{
        .name = "ICoreWebView2Settings3",
        .iid = "fdb5ab74-af33-4854-84f0-0a631deb5eba",
        .parent = "ICoreWebView2Settings2",
        .slot_count = 25,
        .slots = &.{
            "get_AreBrowserAcceleratorKeysEnabled",
            "put_AreBrowserAcceleratorKeysEnabled",
        },
    },
    .{
        .name = "ICoreWebView2Settings4",
        .iid = "cb56846c-4168-4d53-b04f-03b6d6796ff2",
        .parent = "ICoreWebView2Settings3",
        .slot_count = 29,
        .slots = &.{
            "get_IsPasswordAutosaveEnabled",
            "put_IsPasswordAutosaveEnabled",
            "get_IsGeneralAutofillEnabled",
            "put_IsGeneralAutofillEnabled",
        },
    },
    .{
        .name = "ICoreWebView2Settings5",
        .iid = "183e7052-1d03-43a0-ab99-98e043b66b39",
        .parent = "ICoreWebView2Settings4",
        .slot_count = 31,
        .slots = &.{
            "get_IsPinchZoomEnabled",
            "put_IsPinchZoomEnabled",
        },
    },
    .{
        .name = "ICoreWebView2Settings6",
        .iid = "11cb3acd-9bc8-43b8-83bf-f40753714f87",
        .parent = "ICoreWebView2Settings5",
        .slot_count = 33,
        .slots = &.{
            "get_IsSwipeNavigationEnabled",
            "put_IsSwipeNavigationEnabled",
        },
    },
    .{
        .name = "ICoreWebView2Settings7",
        .iid = "488dc902-35ef-42d2-bc7d-94b65c4bc49c",
        .parent = "ICoreWebView2Settings6",
        .slot_count = 35,
        .slots = &.{
            "get_HiddenPdfToolbarItems",
            "put_HiddenPdfToolbarItems",
        },
    },
    .{
        .name = "ICoreWebView2Settings8",
        .iid = "9e6b0e8f-86ad-4e81-8147-a9b5edb68650",
        .parent = "ICoreWebView2Settings7",
        .slot_count = 37,
        .slots = &.{
            "get_IsReputationCheckingRequired",
            "put_IsReputationCheckingRequired",
        },
    },
    .{
        .name = "ICoreWebView2Environment2",
        .iid = "41f3632b-5ef4-404f-ad82-2d606c5a9a21",
        .parent = "ICoreWebView2Environment",
        .slot_count = 9,
        .slots = &.{
            "CreateWebResourceRequest",
        },
    },
    .{
        .name = "ICoreWebView2Environment3",
        .iid = "80a22ae3-be7c-4ce2-afe1-5a50056cdeeb",
        .parent = "ICoreWebView2Environment2",
        .slot_count = 11,
        .slots = &.{
            "CreateCoreWebView2CompositionController",
            "CreateCoreWebView2PointerInfo",
        },
    },
    .{
        .name = "ICoreWebView2Environment4",
        .iid = "20944379-6dcf-41d6-a0a0-abc0fc50de0d",
        .parent = "ICoreWebView2Environment3",
        .slot_count = 12,
        .slots = &.{
            "GetAutomationProviderForWindow",
        },
    },
    .{
        .name = "ICoreWebView2Environment5",
        .iid = "319e423d-e0d7-4b8d-9254-ae9475de9b17",
        .parent = "ICoreWebView2Environment4",
        .slot_count = 14,
        .slots = &.{
            "add_BrowserProcessExited",
            "remove_BrowserProcessExited",
        },
    },
    .{
        .name = "ICoreWebView2Environment6",
        .iid = "e59ee362-acbd-4857-9a8e-d3644d9459a9",
        .parent = "ICoreWebView2Environment5",
        .slot_count = 15,
        .slots = &.{
            "CreatePrintSettings",
        },
    },
    .{
        .name = "ICoreWebView2Environment7",
        .iid = "43c22296-3bbd-43a4-9c00-5c0df6dd29a2",
        .parent = "ICoreWebView2Environment6",
        .slot_count = 16,
        .slots = &.{
            "get_UserDataFolder",
        },
    },
    .{
        .name = "ICoreWebView2Environment8",
        .iid = "d6eb91dd-c3d2-45e5-bd29-6dc2bc4de9cf",
        .parent = "ICoreWebView2Environment7",
        .slot_count = 19,
        .slots = &.{
            "add_ProcessInfosChanged",
            "remove_ProcessInfosChanged",
            "GetProcessInfos",
        },
    },
    .{
        .name = "ICoreWebView2Environment9",
        .iid = "f06f41bf-4b5a-49d8-b9f6-fa16cd29f274",
        .parent = "ICoreWebView2Environment8",
        .slot_count = 20,
        .slots = &.{
            "CreateContextMenuItem",
        },
    },
    .{
        .name = "ICoreWebView2Environment10",
        .iid = "ee0eb9df-6f12-46ce-b53f-3f47b9c928e0",
        .parent = "ICoreWebView2Environment9",
        .slot_count = 23,
        .slots = &.{
            "CreateCoreWebView2ControllerOptions",
            "CreateCoreWebView2ControllerWithOptions",
            "CreateCoreWebView2CompositionControllerWithOptions",
        },
    },
    .{
        .name = "ICoreWebView2ControllerOptions",
        .iid = "12aae616-8ccb-44ec-bcb3-eb1831881635",
        .parent = "IUnknown",
        .slot_count = 7,
        .slots = &.{
            "get_ProfileName",
            "put_ProfileName",
            "get_IsInPrivateModeEnabled",
            "put_IsInPrivateModeEnabled",
        },
    },
    .{
        .name = "ICoreWebView2EnvironmentOptions",
        .iid = "2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_AdditionalBrowserArguments",
            "put_AdditionalBrowserArguments",
            "get_Language",
            "put_Language",
            "get_TargetCompatibleBrowserVersion",
            "put_TargetCompatibleBrowserVersion",
            "get_AllowSingleSignOnUsingOSPrimaryAccount",
            "put_AllowSingleSignOnUsingOSPrimaryAccount",
        },
    },
    .{
        .name = "ICoreWebView2NavigationStartingEventArgs",
        .iid = "5b495469-e119-438a-9b18-7604f25f2e49",
        .parent = "IUnknown",
        .slot_count = 10,
        .slots = &.{
            "get_Uri",
            "get_IsUserInitiated",
            "get_IsRedirected",
            "get_RequestHeaders",
            "get_Cancel",
            "put_Cancel",
            "get_NavigationId",
        },
    },
    .{
        .name = "ICoreWebView2ContentLoadingEventArgs",
        .iid = "0c8a1275-9b6b-4901-87ad-70df25bafa6e",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_IsErrorPage",
            "get_NavigationId",
        },
    },
    .{
        .name = "ICoreWebView2SourceChangedEventArgs",
        .iid = "31e0e545-1dba-4266-8914-f63848a1f7d7",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "get_IsNewDocument",
        },
    },
    .{
        .name = "ICoreWebView2ProcessFailedEventArgs",
        .iid = "8155a9a4-1474-4a86-8cae-151b0fa6b8ca",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "get_ProcessFailedKind",
        },
    },
    .{
        .name = "ICoreWebView2WebMessageReceivedEventArgs",
        .iid = "0f99a40c-e962-4207-9e92-e3d542eff849",
        .parent = "IUnknown",
        .slot_count = 6,
        .slots = &.{
            "get_Source",
            "get_WebMessageAsJson",
            "TryGetWebMessageAsString",
        },
    },
    .{
        .name = "ICoreWebView2ScriptDialogOpeningEventArgs",
        .iid = "7390bb70-abe0-4843-9529-f143b31b03d6",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_Uri",
            "get_Kind",
            "get_Message",
            "Accept",
            "get_DefaultText",
            "get_ResultText",
            "put_ResultText",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2PermissionRequestedEventArgs",
        .iid = "973ae2ef-ff18-4894-8fb2-3c758f046810",
        .parent = "IUnknown",
        .slot_count = 9,
        .slots = &.{
            "get_Uri",
            "get_PermissionKind",
            "get_IsUserInitiated",
            "get_State",
            "put_State",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2NewWindowRequestedEventArgs",
        .iid = "34acb11c-fc37-4418-9132-f9c21d1eafb9",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_Uri",
            "put_NewWindow",
            "get_NewWindow",
            "put_Handled",
            "get_Handled",
            "get_IsUserInitiated",
            "GetDeferral",
            "get_WindowFeatures",
        },
    },
    .{
        .name = "ICoreWebView2WindowFeatures",
        .iid = "5eaf559f-b46e-4397-8860-e422f287ff1e",
        .parent = "IUnknown",
        .slot_count = 13,
        .slots = &.{
            "get_HasPosition",
            "get_HasSize",
            "get_Left",
            "get_Top",
            "get_Height",
            "get_Width",
            "get_ShouldDisplayMenuBar",
            "get_ShouldDisplayStatus",
            "get_ShouldDisplayToolbar",
            "get_ShouldDisplayScrollBars",
        },
    },
    .{
        .name = "ICoreWebView2WebResourceRequestedEventArgs",
        .iid = "453e667f-12c7-49d4-be6d-ddbe7956f57a",
        .parent = "IUnknown",
        .slot_count = 8,
        .slots = &.{
            "get_Request",
            "get_Response",
            "put_Response",
            "GetDeferral",
            "get_ResourceContext",
        },
    },
    .{
        .name = "ICoreWebView2WebResourceRequest",
        .iid = "97055cd4-512c-4264-8b5f-e3f446cea6a5",
        .parent = "IUnknown",
        .slot_count = 10,
        .slots = &.{
            "get_Uri",
            "put_Uri",
            "get_Method",
            "put_Method",
            "get_Content",
            "put_Content",
            "get_Headers",
        },
    },
    .{
        .name = "ICoreWebView2WebResourceResponse",
        .iid = "aafcc94f-fa27-48fd-97df-830ef75aaec9",
        .parent = "IUnknown",
        .slot_count = 10,
        .slots = &.{
            "get_Content",
            "put_Content",
            "get_Headers",
            "get_StatusCode",
            "put_StatusCode",
            "get_ReasonPhrase",
            "put_ReasonPhrase",
        },
    },
    .{
        .name = "ICoreWebView2HttpRequestHeaders",
        .iid = "e86cac0e-5523-465c-b536-8fb9fc8c8c60",
        .parent = "IUnknown",
        .slot_count = 9,
        .slots = &.{
            "GetHeader",
            "GetHeaders",
            "Contains",
            "SetHeader",
            "RemoveHeader",
            "GetIterator",
        },
    },
    .{
        .name = "ICoreWebView2HttpResponseHeaders",
        .iid = "03c5ff5a-9b45-4a88-881c-89a9f328619c",
        .parent = "IUnknown",
        .slot_count = 8,
        .slots = &.{
            "AppendHeader",
            "Contains",
            "GetHeader",
            "GetHeaders",
            "GetIterator",
        },
    },
    .{
        .name = "ICoreWebView2HttpHeadersCollectionIterator",
        .iid = "0702fc30-f43b-47bb-ab52-a42cb552ad9f",
        .parent = "IUnknown",
        .slot_count = 6,
        .slots = &.{
            "GetCurrentHeader",
            "get_HasCurrentHeader",
            "MoveNext",
        },
    },
    .{
        .name = "ICoreWebView2Deferral",
        .iid = "c10e7f7b-b585-46f0-a623-8befbf3e4ee0",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Complete",
        },
    },
    .{
        .name = "ICoreWebView2MoveFocusRequestedEventArgs",
        .iid = "2d6aa13b-3839-4a15-92fc-d88b3c0d9c9d",
        .parent = "IUnknown",
        .slot_count = 6,
        .slots = &.{
            "get_Reason",
            "get_Handled",
            "put_Handled",
        },
    },
    .{
        .name = "ICoreWebView2DOMContentLoadedEventArgs",
        .iid = "16b1e21a-c503-44f2-84c9-70aba5031283",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "get_NavigationId",
        },
    },
    .{
        .name = "ICoreWebView2CookieManager",
        .iid = "177cd9e7-b6f5-451a-94a0-5d7a3a4c4141",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "CreateCookie",
            "CopyCookie",
            "GetCookies",
            "AddOrUpdateCookie",
            "DeleteCookie",
            "DeleteCookies",
            "DeleteCookiesWithDomainAndPath",
            "DeleteAllCookies",
        },
    },
    .{
        .name = "ICoreWebView2Cookie",
        .iid = "ad26d6be-1486-43e6-bf87-a2034006ca21",
        .parent = "IUnknown",
        .slot_count = 17,
        .slots = &.{
            "get_Name",
            "get_Value",
            "put_Value",
            "get_Domain",
            "get_Path",
            "get_Expires",
            "put_Expires",
            "get_IsHttpOnly",
            "put_IsHttpOnly",
            "get_SameSite",
            "put_SameSite",
            "get_IsSecure",
            "put_IsSecure",
            "get_IsSession",
        },
    },
    .{
        .name = "ICoreWebView2CookieList",
        .iid = "f7f6f714-5d2a-43c6-9503-346ece02d186",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_Count",
            "GetValueAtIndex",
        },
    },
    .{
        .name = "ICoreWebView2DownloadStartingEventArgs",
        .iid = "e99bbe21-43e9-4544-a732-282764eafa60",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_DownloadOperation",
            "get_Cancel",
            "put_Cancel",
            "get_ResultFilePath",
            "put_ResultFilePath",
            "get_Handled",
            "put_Handled",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2DownloadOperation",
        .iid = "3d6b6cf2-afe1-44c7-a995-c65117714336",
        .parent = "IUnknown",
        .slot_count = 22,
        .slots = &.{
            "add_BytesReceivedChanged",
            "remove_BytesReceivedChanged",
            "add_EstimatedEndTimeChanged",
            "remove_EstimatedEndTimeChanged",
            "add_StateChanged",
            "remove_StateChanged",
            "get_Uri",
            "get_ContentDisposition",
            "get_MimeType",
            "get_TotalBytesToReceive",
            "get_BytesReceived",
            "get_EstimatedEndTime",
            "get_ResultFilePath",
            "get_State",
            "get_InterruptReason",
            "Cancel",
            "Pause",
            "Resume",
            "get_CanResume",
        },
    },
    .{
        .name = "ICoreWebView2FrameCreatedEventArgs",
        .iid = "4d6e7b5e-9baa-11eb-a8b3-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "get_Frame",
        },
    },
    .{
        .name = "ICoreWebView2Frame",
        .iid = "f1131a5e-9ba9-11eb-a8b3-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_Name",
            "add_NameChanged",
            "remove_NameChanged",
            "AddHostObjectToScriptWithOrigins",
            "RemoveHostObjectFromScript",
            "add_Destroyed",
            "remove_Destroyed",
            "IsDestroyed",
        },
    },
    .{
        .name = "ICoreWebView2ClientCertificateRequestedEventArgs",
        .iid = "bc59db28-bcc3-11eb-8529-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 15,
        .slots = &.{
            "get_Host",
            "get_Port",
            "get_IsProxy",
            "get_AllowedCertificateAuthorities",
            "get_MutuallyTrustedCertificates",
            "get_SelectedCertificate",
            "put_SelectedCertificate",
            "get_Cancel",
            "put_Cancel",
            "get_Handled",
            "put_Handled",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2ClientCertificateCollection",
        .iid = "ef5674d2-bcc3-11eb-8529-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_Count",
            "GetValueAtIndex",
        },
    },
    .{
        .name = "ICoreWebView2ClientCertificate",
        .iid = "e7188076-bcc3-11eb-8529-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 12,
        .slots = &.{
            "get_Subject",
            "get_Issuer",
            "get_ValidFrom",
            "get_ValidTo",
            "get_DerEncodedSerialNumber",
            "get_DisplayName",
            "ToPemEncoding",
            "get_PemEncodedIssuerCertificateChain",
            "get_Kind",
        },
    },
    .{
        .name = "ICoreWebView2StringCollection",
        .iid = "f41f3f8a-bcc3-11eb-8529-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_Count",
            "GetValueAtIndex",
        },
    },
    .{
        .name = "ICoreWebView2BasicAuthenticationRequestedEventArgs",
        .iid = "ef05516f-d897-4f9e-b672-d8e2307a3fb0",
        .parent = "IUnknown",
        .slot_count = 9,
        .slots = &.{
            "get_Uri",
            "get_Challenge",
            "get_Response",
            "get_Cancel",
            "put_Cancel",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2BasicAuthenticationResponse",
        .iid = "07023f7d-2d77-4d67-9040-6e7d428c6a40",
        .parent = "IUnknown",
        .slot_count = 7,
        .slots = &.{
            "get_UserName",
            "put_UserName",
            "get_Password",
            "put_Password",
        },
    },
    .{
        .name = "ICoreWebView2ContextMenuRequestedEventArgs",
        .iid = "a1d309ee-c03f-11eb-8529-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_MenuItems",
            "get_ContextMenuTarget",
            "get_Location",
            "put_SelectedCommandId",
            "get_SelectedCommandId",
            "put_Handled",
            "get_Handled",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2ContextMenuItemCollection",
        .iid = "f562a2f5-c415-45cf-b909-d4b7c1e276d3",
        .parent = "IUnknown",
        .slot_count = 7,
        .slots = &.{
            "get_Count",
            "GetValueAtIndex",
            "RemoveValueAtIndex",
            "InsertValueAtIndex",
        },
    },
    .{
        .name = "ICoreWebView2ContextMenuItem",
        .iid = "7aed49e3-a93f-497a-811c-749c6b6b6c65",
        .parent = "IUnknown",
        .slot_count = 16,
        .slots = &.{
            "get_Name",
            "get_Label",
            "get_CommandId",
            "get_ShortcutKeyDescription",
            "get_Icon",
            "get_Kind",
            "put_IsEnabled",
            "get_IsEnabled",
            "put_IsChecked",
            "get_IsChecked",
            "get_Children",
            "add_CustomItemSelected",
            "remove_CustomItemSelected",
        },
    },
    .{
        .name = "ICoreWebView2ContextMenuTarget",
        .iid = "b8611d99-eed6-4f3f-902c-a198502ad472",
        .parent = "IUnknown",
        .slot_count = 16,
        .slots = &.{
            "get_Kind",
            "get_IsEditable",
            "get_IsRequestedForMainFrame",
            "get_PageUri",
            "get_FrameUri",
            "get_HasLinkUri",
            "get_LinkUri",
            "get_HasLinkText",
            "get_LinkText",
            "get_HasSourceUri",
            "get_SourceUri",
            "get_HasSelection",
            "get_SelectionText",
        },
    },
    .{
        .name = "ICoreWebView2ServerCertificateErrorDetectedEventArgs",
        .iid = "012193ed-7c13-48ff-969d-a84c1f432a14",
        .parent = "IUnknown",
        .slot_count = 9,
        .slots = &.{
            "get_ErrorStatus",
            "get_RequestUri",
            "get_ServerCertificate",
            "get_Action",
            "put_Action",
            "GetDeferral",
        },
    },
    .{
        .name = "ICoreWebView2Certificate",
        .iid = "c5fb2fce-1cac-4aee-9c79-5ed0362eaae0",
        .parent = "IUnknown",
        .slot_count = 11,
        .slots = &.{
            "get_Subject",
            "get_Issuer",
            "get_ValidFrom",
            "get_ValidTo",
            "get_DerEncodedSerialNumber",
            "get_DisplayName",
            "ToPemEncoding",
            "get_PemEncodedIssuerCertificateChain",
        },
    },
    .{
        .name = "ICoreWebView2Profile",
        .iid = "79110ad3-cd5d-4373-8bc3-c60658f17a5f",
        .parent = "IUnknown",
        .slot_count = 10,
        .slots = &.{
            "get_ProfileName",
            "get_IsInPrivateModeEnabled",
            "get_ProfilePath",
            "get_DefaultDownloadFolderPath",
            "put_DefaultDownloadFolderPath",
            "get_PreferredColorScheme",
            "put_PreferredColorScheme",
        },
    },
    .{
        .name = "ICoreWebView2PrintSettings",
        .iid = "377f3721-c74e-48ca-8db1-df68e51d60e2",
        .parent = "IUnknown",
        .slot_count = 29,
        .slots = &.{
            "get_Orientation",
            "put_Orientation",
            "get_ScaleFactor",
            "put_ScaleFactor",
            "get_PageWidth",
            "put_PageWidth",
            "get_PageHeight",
            "put_PageHeight",
            "get_MarginTop",
            "put_MarginTop",
            "get_MarginBottom",
            "put_MarginBottom",
            "get_MarginLeft",
            "put_MarginLeft",
            "get_MarginRight",
            "put_MarginRight",
            "get_ShouldPrintBackgrounds",
            "put_ShouldPrintBackgrounds",
            "get_ShouldPrintSelectionOnly",
            "put_ShouldPrintSelectionOnly",
            "get_ShouldPrintHeaderAndFooter",
            "put_ShouldPrintHeaderAndFooter",
            "get_HeaderTitle",
            "put_HeaderTitle",
            "get_FooterUri",
            "put_FooterUri",
        },
    },
    .{
        .name = "ICoreWebView2BrowserProcessExitedEventArgs",
        .iid = "1f00663f-af8c-4782-9cdd-dd01c52e34cb",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_BrowserProcessExitKind",
            "get_BrowserProcessId",
        },
    },
    .{
        .name = "ICoreWebView2ProcessInfo",
        .iid = "84fa7612-3f3d-4fbf-889d-fad000492d72",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_ProcessId",
            "get_Kind",
        },
    },
    .{
        .name = "ICoreWebView2ProcessInfoCollection",
        .iid = "402b99cd-a0cc-4fa5-b7a5-51d86a1d2339",
        .parent = "IUnknown",
        .slot_count = 5,
        .slots = &.{
            "get_Count",
            "GetValueAtIndex",
        },
    },
    .{
        .name = "ICoreWebView2AcceleratorKeyPressedEventHandler",
        .iid = "b29c7e28-fa79-41a8-8e44-65811c76dcb2",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler",
        .iid = "b99369f3-9b11-47b5-bc6f-8e7895fcea17",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2BasicAuthenticationRequestedEventHandler",
        .iid = "58b4d6c2-18d4-497e-b39b-9a96533fa278",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2BrowserProcessExitedEventHandler",
        .iid = "fa504257-a216-4911-a860-fe8825712861",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2BytesReceivedChangedEventHandler",
        .iid = "828e8ab6-d94c-4264-9cef-5217170d6251",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2CallDevToolsProtocolMethodCompletedHandler",
        .iid = "5c4889f0-5ef6-4c5a-952c-d8f1b92d0574",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2CapturePreviewCompletedHandler",
        .iid = "697e05e9-3d8f-45fa-96f4-8ffe1ededaf5",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ClearServerCertificateErrorActionsCompletedHandler",
        .iid = "3b40aac6-acfe-4ffd-8211-f607b96e2d5b",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ClientCertificateRequestedEventHandler",
        .iid = "d7175ba2-bcc3-11eb-8529-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ContainsFullScreenElementChangedEventHandler",
        .iid = "e45d98b1-afef-45be-8baf-6c7728867f73",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ContentLoadingEventHandler",
        .iid = "364471e7-f2be-4910-bdba-d72077d51c4b",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ContextMenuRequestedEventHandler",
        .iid = "04d3fe1d-ab87-42fb-a898-da241d35b63c",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler",
        .iid = "02fab84b-1428-4fb7-ad45-1b2e64736184",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler",
        .iid = "6c4819f3-c9b7-4260-8127-c9f5bde7f68c",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler",
        .iid = "4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2CustomItemSelectedEventHandler",
        .iid = "49e1d0bc-fe9e-4481-b7c2-32324aa21998",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2DOMContentLoadedEventHandler",
        .iid = "4bac7e9c-199e-49ed-87ed-249303acf019",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2DevToolsProtocolEventReceivedEventHandler",
        .iid = "e2fda4be-5456-406c-a261-3d452138362c",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2DocumentTitleChangedEventHandler",
        .iid = "f5f2b923-953e-4042-9f95-f3a118e1afd4",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2DownloadStartingEventHandler",
        .iid = "efedc989-c396-41ca-83f7-07f845a55724",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2EstimatedEndTimeChangedEventHandler",
        .iid = "28f0d425-93fe-4e63-9f8d-2aeec6d3ba1e",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ExecuteScriptCompletedHandler",
        .iid = "49511172-cc67-4bca-9923-137112f4c4cc",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2FaviconChangedEventHandler",
        .iid = "2913da94-833d-4de0-8dca-900fc524a1a4",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2FocusChangedEventHandler",
        .iid = "05ea24bd-6452-4926-9014-4b82b498135d",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2FrameCreatedEventHandler",
        .iid = "38059770-9baa-11eb-a8b3-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2FrameDestroyedEventHandler",
        .iid = "59dd7b4c-9baa-11eb-a8b3-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2FrameNameChangedEventHandler",
        .iid = "435c7dc8-9baa-11eb-a8b3-0242ac130003",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2GetCookiesCompletedHandler",
        .iid = "5a4f5069-5c15-47c3-8646-f4de1c116670",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2GetFaviconCompletedHandler",
        .iid = "a2508329-7da8-49d7-8c05-fa125e4aee8d",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2HistoryChangedEventHandler",
        .iid = "c79a420c-efd9-4058-9295-3e8b4bcab645",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2IsDefaultDownloadDialogOpenChangedEventHandler",
        .iid = "3117da26-ae13-438d-bd46-edbeb2c4ce81",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2IsDocumentPlayingAudioChangedEventHandler",
        .iid = "5def109a-2f4b-49fa-b7f6-11c39e513328",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2IsMutedChangedEventHandler",
        .iid = "57d90347-cd0e-4952-a4a2-7483a2756f08",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2MoveFocusRequestedEventHandler",
        .iid = "69035451-6dc7-4cb8-9bce-b2bd70ad289f",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2NavigationCompletedEventHandler",
        .iid = "d33a35bf-1c49-4f98-93ab-006e0533fe1c",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2NavigationStartingEventHandler",
        .iid = "9adbe429-f36d-432b-9ddc-f8881fbd76e3",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2NewBrowserVersionAvailableEventHandler",
        .iid = "f9a2976e-d34e-44fc-adee-81b6b57ca914",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2NewWindowRequestedEventHandler",
        .iid = "d4c185fe-c81c-4989-97af-2d3fa7ab5651",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2PermissionRequestedEventHandler",
        .iid = "15e1c6a3-c72a-4df3-91d7-d097fbec6bfd",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2PrintCompletedHandler",
        .iid = "8fd80075-ed08-42db-8570-f5d14977461e",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2PrintToPdfCompletedHandler",
        .iid = "ccf1ef04-fd8e-4d5f-b2de-0983e41b8c36",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2PrintToPdfStreamCompletedHandler",
        .iid = "4c9f8229-8f93-444f-a711-2c0dfd6359d5",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ProcessFailedEventHandler",
        .iid = "79e0aea4-990b-42d9-aa1d-0fcc2e5bc7f1",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ProcessInfosChangedEventHandler",
        .iid = "f4af0c39-44b9-40e9-8b11-0484cfb9e0a1",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2RasterizationScaleChangedEventHandler",
        .iid = "9c98c8b1-ac53-427e-a345-3049b5524bbe",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ScriptDialogOpeningEventHandler",
        .iid = "ef381bf9-afa8-4e37-91c4-8ac48524bdfb",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ServerCertificateErrorDetectedEventHandler",
        .iid = "969b3a26-d85e-4795-8199-fef57344da22",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2SourceChangedEventHandler",
        .iid = "3c067f9f-5388-4772-8b48-79f7ef1ab37c",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2StateChangedEventHandler",
        .iid = "81336594-7ede-4ba9-bf71-acf0a95b58dd",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2StatusBarTextChangedEventHandler",
        .iid = "a5e3b0d0-10df-4156-bfad-3b43867acac6",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2TrySuspendCompletedHandler",
        .iid = "00f206a7-9d17-4605-91f6-4e8e4de192e3",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2WebMessageReceivedEventHandler",
        .iid = "57213f19-00e6-49fa-8e07-898ea01ecbd2",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2WebResourceRequestedEventHandler",
        .iid = "ab00b74c-15f1-4646-80e8-e76341d25d71",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2WebResourceResponseReceivedEventHandler",
        .iid = "7de9898a-24f5-40c3-a2de-d4f458e69828",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2WindowCloseRequestedEventHandler",
        .iid = "5c19e9e0-092f-486b-affa-ca8231913039",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
    .{
        .name = "ICoreWebView2ZoomFactorChangedEventHandler",
        .iid = "b52d71d6-c4df-4543-a90c-64a3e60f38cb",
        .parent = "IUnknown",
        .slot_count = 4,
        .slots = &.{
            "Invoke",
        },
    },
};
