//! wmux spike S1 (W0-D): unpackaged WinRT toasts for a Win32 app.
//!
//! Standalone prototype, NOT part of the wmux build. One source, two binaries:
//!   s1.exe  (console subsystem)  driver commands (register, show, history, ...)
//!   s1w.exe (windows subsystem)  protocol handler, COM LocalServer32, hidden server
//! It only ever uses AUMID "wmux.spike.s1", protocol "wmux-spike-s1" and
//! CLSID_SPIKE below. See README.md for build/run steps and S1-toasts.md for
//! the results.
//!
//! WinRT is called through hand-written ABI vtables (RoGetActivationFactory,
//! HSTRING, IInspectable). Every IID and vtable slot order was checked against
//! the Windows SDK 10.0.26100.0 headers (winrt/windows.ui.notifications.h,
//! winrt/windows.data.xml.dom.h, um/NotificationActivationCallback.h). The
//! parameterized IIDs are recomputed by `s1 selftest` and by `zig test`.
const std = @import("std");
const windows = std.os.windows;
const k32 = windows.kernel32;

const GUID = windows.GUID;
const HRESULT = windows.HRESULT;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;
const HWND = windows.HWND;
const HKEY = windows.HKEY;
const DWORD = windows.DWORD;
const LPCWSTR = [*:0]const u16;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// ─── Spike identity (never the real wmux values) ────────────────────────
const AUMID = "wmux.spike.s1";
const PROTOCOL = "wmux-spike-s1";
const CLSID_STR = "{F6731D70-24AA-4042-AAA9-4A386308A09B}";
const CLSID_SPIKE = GUID.parse(CLSID_STR);
const PIPE_NAME = "\\\\.\\pipe\\wmux-spike-s1-launch";
const KEY_AUMID = "Software\\Classes\\AppUserModelId\\" ++ AUMID;
const KEY_PROTO = "Software\\Classes\\" ++ PROTOCOL;
const KEY_CLSID = "Software\\Classes\\CLSID\\" ++ CLSID_STR;
const KEY_NOTIF_SETTINGS = "Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\" ++ AUMID;

// ─── HRESULTs and constants ─────────────────────────────────────────────
fn hrc(comptime x: u32) HRESULT {
    return @bitCast(x);
}
const S_OK: HRESULT = 0;
const E_NOINTERFACE = hrc(0x80004002);
const CLASS_E_NOAGGREGATION = hrc(0x80040110);

const HKCU: HKEY = @ptrFromInt(@as(usize, 0xFFFF_FFFF_8000_0001));
const HKCR: HKEY = @ptrFromInt(@as(usize, 0xFFFF_FFFF_8000_0000));
const REG_SZ: DWORD = 1;
const REG_DWORD: DWORD = 4;
const KEY_READ: DWORD = 0x20019;
const KEY_WRITE: DWORD = 0x20006;

const COINIT_MULTITHREADED: DWORD = 0x0;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
const CLSCTX_LOCAL_SERVER: DWORD = 0x4;
const REGCLS_MULTIPLEUSE: DWORD = 1;
const RO_INIT_MULTITHREADED: u32 = 1;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_APPEND_DATA: DWORD = 0x0004;
const FILE_SHARE_READ: DWORD = 1;
const FILE_SHARE_WRITE: DWORD = 2;
const OPEN_EXISTING: DWORD = 3;
const OPEN_ALWAYS: DWORD = 4;
const SECURITY_SQOS_PRESENT: DWORD = 0x00100000;
const SECURITY_IDENTIFICATION: DWORD = 0x00010000;
const PIPE_ACCESS_DUPLEX: DWORD = 3;
const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
const PIPE_TYPE_MESSAGE: DWORD = 4;
const PIPE_READMODE_MESSAGE: DWORD = 2;
const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 8;
const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
const ERROR_PIPE_BUSY: u16 = 231;
const ERROR_PIPE_CONNECTED: u16 = 535;
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const TH32CS_SNAPPROCESS: DWORD = 2;
const SPI_GETFOREGROUNDLOCKTIMEOUT: u32 = 0x2000;
const SEE_MASK_NOCLOSEPROCESS: u32 = 0x40;
const SEE_MASK_NOASYNC: u32 = 0x100;
const SEE_MASK_FLAG_NO_UI: u32 = 0x400;
const SW_SHOWNOACTIVATE: i32 = 4;
const ASSOCSTR_COMMAND: DWORD = 1;

// ─── Win32 externs not declared by std ──────────────────────────────────
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetTickCount() callconv(.winapi) DWORD;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
extern "kernel32" fn ConnectNamedPipe(h: HANDLE, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitNamedPipeW(name: LPCWSTR, ms: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetNamedPipeHandleState(h: HANDLE, mode: ?*DWORD, max: ?*DWORD, timeout: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(h: HANDLE, pid: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetNamedPipeClientProcessId(h: HANDLE, pid: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(sa: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Process32FirstW(snap: HANDLE, pe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(snap: HANDLE, pe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn ProcessIdToSessionId(pid: DWORD, session: *DWORD) callconv(.winapi) BOOL;

extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, pid: ?*DWORD) callconv(.winapi) DWORD;
extern "user32" fn AllowSetForegroundWindow(pid: DWORD) callconv(.winapi) BOOL;
extern "user32" fn GetLastInputInfo(plii: *LASTINPUTINFO) callconv(.winapi) BOOL;
extern "user32" fn SystemParametersInfoW(action: u32, param: u32, pv: ?*anyopaque, ini: u32) callconv(.winapi) BOOL;
// Foreground demo only (manual mode, opt-in): never used by automated runs.
extern "user32" fn CreateWindowExW(ex: DWORD, cls: LPCWSTR, title: LPCWSTR, style: DWORD, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: DWORD, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoRegisterClassObject(clsid: *const GUID, unk: *anyopaque, ctx: DWORD, flags: DWORD, cookie: *DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(cookie: DWORD) callconv(.winapi) HRESULT;

extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub: LPCWSTR, reserved: DWORD, class: ?LPCWSTR, options: DWORD, sam: DWORD, sa: ?*anyopaque, result: *HKEY, disposition: ?*DWORD) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(key: HKEY, name: ?LPCWSTR, reserved: DWORD, typ: DWORD, data: ?[*]const u8, cb: DWORD) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub: ?LPCWSTR) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteValueW(key: HKEY, name: ?LPCWSTR) callconv(.winapi) i32;

extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: LPCWSTR) callconv(.winapi) HRESULT;
extern "shell32" fn SHQueryUserNotificationState(state: *i32) callconv(.winapi) HRESULT;
extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
extern "shlwapi" fn AssocQueryStringW(flags: DWORD, str: DWORD, assoc: LPCWSTR, extra: ?LPCWSTR, out: ?[*]u16, cch: *DWORD) callconv(.winapi) HRESULT;

// WinRT runtime. Zig 0.15.2's mingw has x64 .def files for these API-set
// names (there is no runtimeobject.def / combase.def for x64).
const HSTRING = ?*opaque {};
const HSTRING_HEADER = extern struct { reserved: [3]usize }; // 24 bytes on x64
extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(init_type: u32) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoUninitialize() callconv(.winapi) void;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(class_id: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoActivateInstance(class_id: HSTRING, instance: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(src: ?[*]const u16, len: u32, out: *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateStringReference(src: [*:0]const u16, len: u32, header: *HSTRING_HEADER, out: *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(s: HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsGetStringRawBuffer(s: HSTRING, len: ?*u32) callconv(.winapi) ?[*]const u16;

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};
const LASTINPUTINFO = extern struct { cbSize: u32, dwTime: u32 };
const SHELLEXECUTEINFOW = extern struct {
    cbSize: DWORD,
    fMask: u32,
    hwnd: ?HWND = null,
    lpVerb: ?LPCWSTR = null,
    lpFile: ?LPCWSTR = null,
    lpParameters: ?LPCWSTR = null,
    lpDirectory: ?LPCWSTR = null,
    nShow: i32 = 0,
    hInstApp: ?*anyopaque = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?LPCWSTR = null,
    hkeyClass: ?HKEY = null,
    dwHotKey: DWORD = 0,
    hIconOrMonitor: ?HANDLE = null,
    hProcess: ?HANDLE = null,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: usize, lParam: isize, time: DWORD, pt_x: i32, pt_y: i32, lPrivate: DWORD };
const NOTIFICATION_USER_INPUT_DATA = extern struct { Key: LPCWSTR, Value: LPCWSTR };
const EventRegistrationToken = extern struct { value: i64 };

// ─── IIDs (SDK 10.0.26100.0) ────────────────────────────────────────────
const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
const IID_IClassFactory = GUID.parse("{00000001-0000-0000-C000-000000000046}");
const IID_IAgileObject = GUID.parse("{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}");
const IID_INotificationActivationCallback = GUID.parse("{53E31837-6600-4A81-9395-75CFFE746F94}");
const IID_IToastNotificationManagerStatics = GUID.parse("{50AC103F-D235-4598-BBEF-98FE4D1A3AD4}");
const IID_IToastNotificationManagerStatics2 = GUID.parse("{7AB93C52-0E48-4750-BA9D-1A4113981847}");
const IID_IToastNotificationFactory = GUID.parse("{04124B20-82C6-4229-B109-FD9ED4662B53}");
const IID_IToastNotification2 = GUID.parse("{9DFB9FD1-143A-490E-90BF-B9FBA7132DE7}");
const IID_IToastNotificationHistory2 = GUID.parse("{3BC3D253-2F31-4092-9129-8AD5ABF067DA}");
const IID_IToastActivatedEventArgs = GUID.parse("{E3BF92F3-C197-436F-8265-0625824F8DAC}");
const IID_IXmlDocument = GUID.parse("{F7F3A506-1E87-42D6-BCFB-B8C809FA5494}");
const IID_IXmlDocumentIO = GUID.parse("{6CD0E74E-EE65-4489-9EBF-CA43E87BA637}");
const IID_IXmlNodeSerializer = GUID.parse("{5CC5B382-E6DD-4991-ABEF-06D8D2E7BD0C}");
// Parameterized interfaces (pinterface IIDs; see pinterfaceIid / selftest).
const IID_TypedEventHandler_Toast_Object = GUID.parse("{AB54DE2D-97D9-5528-B6AD-105AFE156530}");
const IID_TypedEventHandler_Toast_Dismissed = GUID.parse("{61C2402F-0ED0-5A18-AB69-59F4AA99A368}");
const IID_TypedEventHandler_Toast_Failed = GUID.parse("{95E3E803-C969-5E3A-9753-EA2AD22A9A33}");
const IID_IVectorView_ToastNotification = GUID.parse("{A819F3DE-60AA-5159-8407-F0A7FB1F6832}");

const SIG_TOAST = "rc(Windows.UI.Notifications.ToastNotification;{997e2675-059e-4e60-8b06-1760917c8b80})";
const SIG_TYPED_HANDLER = "{9de1c534-6ae1-11e0-84e1-18a905bcc53f}";
const SIG_VECTOR_VIEW = "{bbe1fa4c-b0e3-4583-baef-1f1b2e483e56}";
const pinterface_cases = [_]struct { sig: []const u8, iid: GUID, name: []const u8 }{
    .{ .name = "TypedEventHandler<ToastNotification,Object>", .iid = IID_TypedEventHandler_Toast_Object, .sig = "pinterface(" ++ SIG_TYPED_HANDLER ++ ";" ++ SIG_TOAST ++ ";cinterface(IInspectable))" },
    .{ .name = "TypedEventHandler<ToastNotification,ToastDismissedEventArgs>", .iid = IID_TypedEventHandler_Toast_Dismissed, .sig = "pinterface(" ++ SIG_TYPED_HANDLER ++ ";" ++ SIG_TOAST ++ ";rc(Windows.UI.Notifications.ToastDismissedEventArgs;{3f89d935-d9cb-4538-a0f0-ffe7659938f8}))" },
    .{ .name = "TypedEventHandler<ToastNotification,ToastFailedEventArgs>", .iid = IID_TypedEventHandler_Toast_Failed, .sig = "pinterface(" ++ SIG_TYPED_HANDLER ++ ";" ++ SIG_TOAST ++ ";rc(Windows.UI.Notifications.ToastFailedEventArgs;{35176862-cfd4-44f8-ad64-f500fd896c3b}))" },
    .{ .name = "IVectorView<ToastNotification>", .iid = IID_IVectorView_ToastNotification, .sig = "pinterface(" ++ SIG_VECTOR_VIEW ++ ";" ++ SIG_TOAST ++ ")" },
};

/// WinRT parameterized-interface IID: UUIDv5-style SHA-1 over the namespace
/// {11f47ad5-7b73-42c0-abae-878b1e16adee} followed by the UTF-8 signature.
fn pinterfaceIid(sig: []const u8) GUID {
    const ns = [16]u8{ 0x11, 0xf4, 0x7a, 0xd5, 0x7b, 0x73, 0x42, 0xc0, 0xab, 0xae, 0x87, 0x8b, 0x1e, 0x16, 0xad, 0xee };
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(&ns);
    h.update(sig);
    var d: [20]u8 = undefined;
    h.final(&d);
    d[6] = (d[6] & 0x0f) | 0x50;
    d[8] = (d[8] & 0x3f) | 0x80;
    return .{
        .Data1 = std.mem.readInt(u32, d[0..4], .big),
        .Data2 = std.mem.readInt(u16, d[4..6], .big),
        .Data3 = std.mem.readInt(u16, d[6..8], .big),
        .Data4 = d[8..16].*,
    };
}

fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

test "pinterface IIDs match the SDK headers" {
    for (pinterface_cases) |c| {
        const got = pinterfaceIid(c.sig);
        try std.testing.expect(guidEql(&got, &c.iid));
    }
}

// ─── COM / WinRT interface plumbing ─────────────────────────────────────
const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
/// IInspectable = IUnknown + GetIids, GetRuntimeClassName, GetTrustLevel
/// (slots 3-5). Every WinRT interface below starts with these 6 slots.
const IInspectableVtbl = extern struct {
    unk: IUnknownVtbl,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,
};

fn Com(comptime V: type) type {
    return extern struct {
        vtbl: *const V,
        const Self = @This();
        fn unk(self: *Self) *const IUnknownVtbl {
            return @ptrCast(self.vtbl);
        }
        pub fn release(self: *Self) void {
            _ = self.unk().Release(self);
        }
        pub fn query(self: *Self, comptime T: type, iid: *const GUID) !*T {
            var out: ?*anyopaque = null;
            try check(self.unk().QueryInterface(self, iid, &out), "QueryInterface");
            return @ptrCast(@alignCast(out.?));
        }
    };
}

const IToastNotificationManagerStatics = Com(extern struct {
    base: IInspectableVtbl,
    CreateToastNotifier: *const fn (*anyopaque, *?*IToastNotifier) callconv(.winapi) HRESULT,
    CreateToastNotifierWithId: *const fn (*anyopaque, HSTRING, *?*IToastNotifier) callconv(.winapi) HRESULT,
    GetTemplateContent: *const anyopaque,
});
const IToastNotificationManagerStatics2 = Com(extern struct {
    base: IInspectableVtbl,
    get_History: *const fn (*anyopaque, *?*IToastNotificationHistory) callconv(.winapi) HRESULT,
});
const IToastNotifier = Com(extern struct {
    base: IInspectableVtbl,
    Show: *const fn (*anyopaque, *IToastNotification) callconv(.winapi) HRESULT,
    Hide: *const fn (*anyopaque, *IToastNotification) callconv(.winapi) HRESULT,
    get_Setting: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // AddToSchedule, RemoveFromSchedule, GetScheduledToastNotifications: unused
});
const IToastNotificationFactory = Com(extern struct {
    base: IInspectableVtbl,
    CreateToastNotification: *const fn (*anyopaque, *IXmlDocument, *?*IToastNotification) callconv(.winapi) HRESULT,
});
const IToastNotification = Com(extern struct {
    base: IInspectableVtbl,
    get_Content: *const fn (*anyopaque, *?*IXmlDocument) callconv(.winapi) HRESULT,
    put_ExpirationTime: *const anyopaque,
    get_ExpirationTime: *const anyopaque,
    add_Dismissed: *const fn (*anyopaque, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    remove_Dismissed: *const fn (*anyopaque, EventRegistrationToken) callconv(.winapi) HRESULT,
    add_Activated: *const fn (*anyopaque, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    remove_Activated: *const fn (*anyopaque, EventRegistrationToken) callconv(.winapi) HRESULT,
    add_Failed: *const fn (*anyopaque, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    remove_Failed: *const fn (*anyopaque, EventRegistrationToken) callconv(.winapi) HRESULT,
});
const IToastNotification2 = Com(extern struct {
    base: IInspectableVtbl,
    put_Tag: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    get_Tag: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
    put_Group: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    get_Group: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
    put_SuppressPopup: *const fn (*anyopaque, u8) callconv(.winapi) HRESULT,
    get_SuppressPopup: *const fn (*anyopaque, *u8) callconv(.winapi) HRESULT,
});
const IToastNotificationHistory = Com(extern struct {
    base: IInspectableVtbl,
    RemoveGroup: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    RemoveGroupWithId: *const fn (*anyopaque, HSTRING, HSTRING) callconv(.winapi) HRESULT,
    RemoveGroupedTagWithId: *const fn (*anyopaque, HSTRING, HSTRING, HSTRING) callconv(.winapi) HRESULT,
    RemoveGroupedTag: *const fn (*anyopaque, HSTRING, HSTRING) callconv(.winapi) HRESULT,
    Remove: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    Clear: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    ClearWithId: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
});
const IToastNotificationHistory2 = Com(extern struct {
    base: IInspectableVtbl,
    GetHistory: *const fn (*anyopaque, *?*IVectorViewToast) callconv(.winapi) HRESULT,
    GetHistoryWithId: *const fn (*anyopaque, HSTRING, *?*IVectorViewToast) callconv(.winapi) HRESULT,
});
const IVectorViewToast = Com(extern struct {
    base: IInspectableVtbl,
    GetAt: *const fn (*anyopaque, u32, *?*IToastNotification) callconv(.winapi) HRESULT,
    get_Size: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    // IndexOf, GetMany: unused
});
const IToastFailedEventArgs = Com(extern struct {
    base: IInspectableVtbl,
    get_ErrorCode: *const fn (*anyopaque, *HRESULT) callconv(.winapi) HRESULT,
});
const IToastDismissedEventArgs = Com(extern struct {
    base: IInspectableVtbl,
    get_Reason: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
});
const IToastActivatedEventArgs = Com(extern struct {
    base: IInspectableVtbl,
    get_Arguments: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
});
const IXmlDocument = Com(extern struct { base: IInspectableVtbl });
const IXmlDocumentIO = Com(extern struct {
    base: IInspectableVtbl,
    LoadXml: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    // LoadXmlWithSettings, SaveToFileAsync: unused
});
const IXmlNodeSerializer = Com(extern struct {
    base: IInspectableVtbl,
    GetXml: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
});
const IInspectable = Com(IInspectableVtbl);
/// Client view of the activator (IUnknown-based, not IInspectable).
const INotificationActivationCallback = Com(extern struct {
    unk: IUnknownVtbl,
    Activate: *const fn (*anyopaque, LPCWSTR, ?LPCWSTR, ?[*]const NOTIFICATION_USER_INPUT_DATA, u32) callconv(.winapi) HRESULT,
});

// ─── Logging (JSONL, one atomic append per line) ────────────────────────
const Hr = struct {
    v: HRESULT,
    pub fn jsonStringify(self: Hr, jws: *std.json.Stringify) !void {
        var b: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "0x{X:0>8}", .{@as(u32, @bitCast(self.v))}) catch unreachable;
        try jws.write(s);
    }
};
fn hx(v: HRESULT) Hr {
    return .{ .v = v };
}
const GuidStr = struct {
    buf: [38]u8,
    fn of(g: *const GUID) GuidStr {
        var s: GuidStr = undefined;
        _ = std.fmt.bufPrint(&s.buf, "{{{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}}}", .{
            g.Data1,    g.Data2,    g.Data3,    g.Data4[0], g.Data4[1], g.Data4[2],
            g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7],
        }) catch unreachable;
        return s;
    }
    pub fn jsonStringify(self: GuidStr, jws: *std.json.Stringify) !void {
        try jws.write(self.buf[0..]);
    }
};

const Log = struct {
    var file: ?HANDLE = null;
    var stdout: ?HANDLE = null;
    var mutex: std.Thread.Mutex = .{};
    var role: []const u8 = "?";
    var buf: [48 * 1024]u8 = undefined;

    fn init(r: []const u8) void {
        role = r;
        // Only the console driver echoes. A GUI-subsystem process launched by
        // the shell or COM may inherit std handle values it does not own
        // (observed: a handler spawned by the COM-launched server hung before
        // its first log line), so the handler/server roles log to file only.
        if (std.mem.eql(u8, r, "cli")) {
            if (k32.GetStdHandle(STD_OUTPUT_HANDLE)) |h| {
                if (h != windows.INVALID_HANDLE_VALUE) stdout = h;
            }
        }
        const path = logPath() catch return;
        const h = k32.CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_ALWAYS, 0, null);
        if (h != windows.INVALID_HANDLE_VALUE) file = h;
    }

    fn logPath() ![:0]const u16 {
        if (std.process.getEnvVarOwned(gpa, "S1_LOG")) |p| {
            return std.unicode.utf8ToUtf16LeAllocZ(gpa, p);
        } else |_| {}
        const dir = try std.fs.selfExeDirPathAlloc(gpa);
        const p = try std.fmt.allocPrint(gpa, "{s}\\s1-log.jsonl", .{dir});
        return std.unicode.utf8ToUtf16LeAllocZ(gpa, p);
    }

    fn ev(comptime name: []const u8, fields: anytype) void {
        mutex.lock();
        defer mutex.unlock();
        var w: std.Io.Writer = .fixed(&buf);
        writeLine(&w, name, fields) catch {
            w.end = @min(w.end, buf.len - 64);
            w.writeAll(",\"truncated\":true}\n") catch {};
        };
        const line = w.buffered();
        if (file) |f| _ = k32.WriteFile(f, line.ptr, @intCast(line.len), null, null);
        if (stdout) |o| _ = k32.WriteFile(o, line.ptr, @intCast(line.len), null, null);
    }

    fn writeLine(w: *std.Io.Writer, comptime name: []const u8, fields: anytype) !void {
        try w.print("{{\"t_us\":{d},\"pid\":{d},\"role\":\"{s}\",\"ev\":\"{s}\"", .{ std.time.microTimestamp(), GetCurrentProcessId(), role, name });
        inline for (std.meta.fields(@TypeOf(fields))) |f| {
            try w.print(",\"{s}\":", .{f.name});
            try std.json.Stringify.value(@field(fields, f.name), .{}, w);
        }
        try w.writeAll("}\n");
    }
};

const gpa = std.heap.smp_allocator; // thread-safe; the spike leaks small strings freely

fn check(h: HRESULT, comptime what: []const u8) !void {
    if (h < 0) {
        Log.ev("hresult_fail", .{ .call = what, .hr = hx(h) });
        return error.HResultFailed;
    }
}

/// UTF-16 → UTF-8 for logging (WTF-8 tolerant).
fn w8(w: []const u16) []const u8 {
    return std.unicode.wtf16LeToWtf8Alloc(gpa, w) catch "<conv-error>";
}
fn w8z(w: ?LPCWSTR) ?[]const u8 {
    const p = w orelse return null;
    return w8(std.mem.span(p));
}
fn hsToUtf8(h: HSTRING) []const u8 {
    var len: u32 = 0;
    const p = WindowsGetStringRawBuffer(h, &len) orelse return "";
    return w8(p[0..len]);
}

/// Owned HSTRING (WindowsCreateString copies the input).
const HS = struct {
    h: HSTRING = null,
    fn init(utf8: []const u8) !HS {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, utf8);
        defer gpa.free(w);
        var s: HS = .{};
        try check(WindowsCreateString(w.ptr, @intCast(w.len), &s.h), "WindowsCreateString");
        return s;
    }
    fn deinit(self: *HS) void {
        _ = WindowsDeleteString(self.h);
        self.h = null;
    }
};

/// RoGetActivationFactory with a fast-pass (reference) HSTRING for the
/// comptime class name: no allocation, header lives on this stack frame.
fn getFactory(comptime T: type, comptime class: []const u8, iid: *const GUID) !*T {
    const w = comptime L(class);
    var header: HSTRING_HEADER = undefined;
    var hs: HSTRING = null;
    try check(WindowsCreateStringReference(w, w.len, &header, &hs), "WindowsCreateStringReference");
    var out: ?*anyopaque = null;
    try check(RoGetActivationFactory(hs, iid, &out), "RoGetActivationFactory(" ++ class ++ ")");
    return @ptrCast(@alignCast(out.?));
}

fn activateInstance(comptime class: []const u8) !*IInspectable {
    const w = comptime L(class);
    var header: HSTRING_HEADER = undefined;
    var hs: HSTRING = null;
    try check(WindowsCreateStringReference(w, w.len, &header, &hs), "WindowsCreateStringReference");
    var out: ?*anyopaque = null;
    try check(RoActivateInstance(hs, &out), "RoActivateInstance(" ++ class ++ ")");
    return @ptrCast(@alignCast(out.?));
}

// ─── Small helpers ──────────────────────────────────────────────────────
fn nowUs() i64 {
    return std.time.microTimestamp();
}
fn lastErr() u16 {
    return @intFromEnum(k32.GetLastError());
}
fn uuid4(out: *[36]u8) void {
    var b: [16]u8 = undefined;
    std.crypto.random.bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(b, .upper);
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
}

const Probe = struct { ok: bool, err: u16 };
/// Non-destructive foreground-rights probe. AllowSetForegroundWindow fails
/// with ERROR_ACCESS_DENIED (5) unless the CALLING process may itself set the
/// foreground window (documented). Granting the right to ourselves changes
/// nothing visible; no window is ever activated by this call.
fn probeForeground() Probe {
    const ok = AllowSetForegroundWindow(GetCurrentProcessId()) != 0;
    return .{ .ok = ok, .err = if (ok) 0 else lastErr() };
}

const ProcInfo = struct { pid: DWORD = 0, parent: DWORD = 0, exe: []const u8 = "" };
fn procInfo(pid: DWORD) ProcInfo {
    const snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == windows.INVALID_HANDLE_VALUE) return .{ .pid = pid };
    defer windows.CloseHandle(snap);
    var pe: PROCESSENTRY32W = undefined;
    pe.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &pe) == 0) return .{ .pid = pid };
    while (true) {
        if (pe.th32ProcessID == pid) {
            const name = std.mem.sliceTo(&pe.szExeFile, 0);
            return .{ .pid = pid, .parent = pe.th32ParentProcessID, .exe = w8(name) };
        }
        if (Process32NextW(snap, &pe) == 0) break;
    }
    return .{ .pid = pid };
}
fn foregroundPid() DWORD {
    const fg = GetForegroundWindow() orelse return 0;
    var pid: DWORD = 0;
    _ = GetWindowThreadProcessId(fg, &pid);
    return pid;
}
fn idleMs() u32 {
    var li: LASTINPUTINFO = .{ .cbSize = @sizeOf(LASTINPUTINFO), .dwTime = 0 };
    if (GetLastInputInfo(&li) == 0) return 0;
    return GetTickCount() -% li.dwTime;
}

/// Focus safety: every spike process (except the opt-in manual foreground
/// demo) exits immediately if it ever owns the foreground window.
fn fgGuardThread() void {
    const me = GetCurrentProcessId();
    while (true) {
        if (foregroundPid() == me) {
            Log.ev("FOREGROUND_VIOLATION", .{ .fg_pid = me });
            k32.ExitProcess(99);
        }
        k32.Sleep(100);
    }
}
fn startFgGuard() void {
    const t = std.Thread.spawn(.{}, fgGuardThread, .{}) catch return;
    t.detach();
}

fn argValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}
fn hasFlag(args: []const [:0]const u8, name: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

// ─── Registry ───────────────────────────────────────────────────────────
fn regSetSz(comptime sub: []const u8, comptime name: ?[]const u8, value: []const u8) i32 {
    var key: HKEY = undefined;
    var st = RegCreateKeyExW(HKCU, L(sub), 0, null, 0, KEY_WRITE, null, &key, null);
    if (st != 0) {
        Log.ev("reg_create_fail", .{ .key = sub, .status = st });
        return st;
    }
    defer _ = windows.advapi32.RegCloseKey(key);
    const w = std.unicode.utf8ToUtf16LeAllocZ(gpa, value) catch return -1;
    const bytes: [*]const u8 = @ptrCast(w.ptr);
    const vname: ?LPCWSTR = if (name) |n| L(n) else null;
    st = RegSetValueExW(key, vname, 0, REG_SZ, bytes, @intCast((w.len + 1) * 2));
    Log.ev("reg_set", .{ .key = sub, .name = name orelse "(default)", .value = value, .status = st });
    return st;
}
fn regSetDword(comptime sub: []const u8, comptime name: []const u8, value: DWORD) i32 {
    var key: HKEY = undefined;
    var st = RegCreateKeyExW(HKCU, L(sub), 0, null, 0, KEY_WRITE, null, &key, null);
    if (st != 0) return st;
    defer _ = windows.advapi32.RegCloseKey(key);
    st = RegSetValueExW(key, L(name), 0, REG_DWORD, std.mem.asBytes(&value), 4);
    Log.ev("reg_set", .{ .key = sub, .name = name, .value_dword = value, .status = st });
    return st;
}
fn regDeleteTree(comptime sub: []const u8) i32 {
    const st = RegDeleteTreeW(HKCU, L(sub));
    // RegDeleteTreeW leaves the (now empty) key itself; delete it too.
    var parent_st: i32 = 0;
    if (st == 0) parent_st = deleteKeyItself(sub);
    Log.ev("reg_delete_tree", .{ .key = sub, .status = st, .delete_key_status = parent_st });
    return st;
}
extern "advapi32" fn RegDeleteKeyW(key: HKEY, sub: LPCWSTR) callconv(.winapi) i32;
fn deleteKeyItself(comptime sub: []const u8) i32 {
    return RegDeleteKeyW(HKCU, L(sub));
}
fn regExists(root: HKEY, comptime sub: []const u8) bool {
    var key: HKEY = undefined;
    if (windows.advapi32.RegOpenKeyExW(root, L(sub), 0, KEY_READ, &key) != 0) return false;
    _ = windows.advapi32.RegCloseKey(key);
    return true;
}
fn regReadSz(root: HKEY, comptime sub: []const u8, comptime name: ?[]const u8) ?[]const u8 {
    var key: HKEY = undefined;
    if (windows.advapi32.RegOpenKeyExW(root, L(sub), 0, KEY_READ, &key) != 0) return null;
    defer _ = windows.advapi32.RegCloseKey(key);
    var buf: [1024]u16 = undefined;
    var cb: DWORD = @sizeOf(@TypeOf(buf));
    var typ: DWORD = 0;
    const vname: LPCWSTR = if (name) |n| L(n) else L("");
    if (windows.advapi32.RegQueryValueExW(key, vname, null, &typ, @ptrCast(&buf), &cb) != 0) return null;
    const n = cb / 2;
    return w8(std.mem.sliceTo(buf[0..n], 0));
}
fn regReadDword(root: HKEY, comptime sub: []const u8, comptime name: []const u8) ?DWORD {
    var key: HKEY = undefined;
    if (windows.advapi32.RegOpenKeyExW(root, L(sub), 0, KEY_READ, &key) != 0) return null;
    defer _ = windows.advapi32.RegCloseKey(key);
    var v: DWORD = 0;
    var cb: DWORD = 4;
    var typ: DWORD = 0;
    if (windows.advapi32.RegQueryValueExW(key, L(name), null, &typ, @ptrCast(&v), &cb) != 0) return null;
    return v;
}

// ─── Toast helpers ──────────────────────────────────────────────────────
const setting_names = [_][]const u8{ "Enabled", "DisabledForApplication", "DisabledForUser", "DisabledByGroupPolicy", "DisabledByManifest" };
fn settingName(v: i32) []const u8 {
    return if (v >= 0 and v < setting_names.len) setting_names[@intCast(v)] else "unknown";
}

fn createNotifier(aumid: []const u8) !*IToastNotifier {
    const statics = try getFactory(IToastNotificationManagerStatics, "Windows.UI.Notifications.ToastNotificationManager", &IID_IToastNotificationManagerStatics);
    defer statics.release();
    var id = try HS.init(aumid);
    defer id.deinit();
    var out: ?*IToastNotifier = null;
    const h = statics.vtbl.CreateToastNotifierWithId(statics, id.h, &out);
    Log.ev("create_notifier", .{ .aumid = aumid, .hr = hx(h) });
    try check(h, "CreateToastNotifierWithId");
    return out.?;
}

fn readSetting(n: *IToastNotifier) ?i32 {
    var v: i32 = -1;
    const h = n.vtbl.get_Setting(n, &v);
    Log.ev("get_setting", .{ .hr = hx(h), .value = v, .name = if (h >= 0) settingName(v) else "error" });
    return if (h >= 0) v else null;
}

fn loadXml(xml: []const u8) !*IXmlDocument {
    const inst = try activateInstance("Windows.Data.Xml.Dom.XmlDocument");
    defer inst.release();
    const io = try inst.query(IXmlDocumentIO, &IID_IXmlDocumentIO);
    defer io.release();
    var s = try HS.init(xml);
    defer s.deinit();
    const h = io.vtbl.LoadXml(io, s.h);
    Log.ev("load_xml", .{ .hr = hx(h), .bytes = xml.len });
    try check(h, "LoadXml");
    return inst.query(IXmlDocument, &IID_IXmlDocument);
}

const History = struct {
    hist: *IToastNotificationHistory,
    hist2: *IToastNotificationHistory2,

    fn open() !History {
        const statics2 = try getFactory(IToastNotificationManagerStatics2, "Windows.UI.Notifications.ToastNotificationManager", &IID_IToastNotificationManagerStatics2);
        defer statics2.release();
        var hist: ?*IToastNotificationHistory = null;
        try check(statics2.vtbl.get_History(statics2, &hist), "get_History");
        const h2 = hist.?.query(IToastNotificationHistory2, &IID_IToastNotificationHistory2) catch |e| {
            hist.?.release();
            return e;
        };
        return .{ .hist = hist.?, .hist2 = h2 };
    }
    fn close(self: *History) void {
        self.hist2.release();
        self.hist.release();
    }

    const Item = struct { tag: []const u8, group: []const u8, tag_hr: Hr, group_hr: Hr, xml: ?[]const u8 };
    /// Snapshot of this AUMID's toasts in Action Center (GetHistoryWithId).
    /// Per-item getter failures are recorded, not fatal.
    fn list(self: *History, with_xml: bool) ![]Item {
        var id = try HS.init(AUMID);
        defer id.deinit();
        var view: ?*IVectorViewToast = null;
        try check(self.hist2.vtbl.GetHistoryWithId(self.hist2, id.h, &view), "GetHistoryWithId");
        defer view.?.release();
        var n: u32 = 0;
        try check(view.?.vtbl.get_Size(view.?, &n), "IVectorView.get_Size");
        const items = try gpa.alloc(Item, n);
        for (items, 0..) |*it, i| {
            var t: ?*IToastNotification = null;
            try check(view.?.vtbl.GetAt(view.?, @intCast(i), &t), "IVectorView.GetAt");
            defer t.?.release();
            const t2 = try t.?.query(IToastNotification2, &IID_IToastNotification2);
            defer t2.release();
            var tag: HSTRING = null;
            var group: HSTRING = null;
            const h_tag = t2.vtbl.get_Tag(t2, &tag);
            const h_group = t2.vtbl.get_Group(t2, &group);
            it.* = .{
                .tag = if (h_tag >= 0) hsToUtf8(tag) else "",
                .group = if (h_group >= 0) hsToUtf8(group) else "",
                .tag_hr = hx(h_tag),
                .group_hr = hx(h_group),
                .xml = null,
            };
            if (h_tag >= 0) _ = WindowsDeleteString(tag);
            if (h_group >= 0) _ = WindowsDeleteString(group);
            if (with_xml) it.xml = toastXml(t.?) catch null;
        }
        return items;
    }

    fn contains(self: *History, tag: []const u8) !struct { count: usize, found: bool } {
        const items = try self.list(false);
        var found = false;
        for (items) |it| {
            if (std.mem.eql(u8, it.tag, tag)) found = true;
        }
        return .{ .count = items.len, .found = found };
    }
};

fn toastXml(t: *IToastNotification) ![]const u8 {
    var doc: ?*IXmlDocument = null;
    try check(t.vtbl.get_Content(t, &doc), "get_Content");
    defer doc.?.release();
    const ser = try doc.?.query(IXmlNodeSerializer, &IID_IXmlNodeSerializer);
    defer ser.release();
    var s: HSTRING = null;
    try check(ser.vtbl.GetXml(ser, &s), "GetXml");
    defer _ = WindowsDeleteString(s);
    return hsToUtf8(s);
}

// ─── Toast event delegates (TypedEventHandler<ToastNotification, T>) ────
// WinRT delegates are IUnknown-based: QI/AddRef/Release + Invoke(sender, args).
// The platform invokes them on its own (MTA) threads; answering IAgileObject
// tells it no marshaling is needed. Static objects: refcount is not tracked.
const Delegate = extern struct {
    vtbl: *const DelegateVtbl,
    kind: u32,
    iid: *const GUID,
};
const DelegateVtbl = extern struct {
    QueryInterface: *const fn (*Delegate, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*Delegate) callconv(.winapi) u32,
    Release: *const fn (*Delegate) callconv(.winapi) u32,
    Invoke: *const fn (*Delegate, ?*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
};
const delegate_vtbl: DelegateVtbl = .{ .QueryInterface = dlgQI, .AddRef = dlgAddRef, .Release = dlgRelease, .Invoke = dlgInvoke };
var g_dlg_dismissed: Delegate = .{ .vtbl = &delegate_vtbl, .kind = 0, .iid = &IID_TypedEventHandler_Toast_Dismissed };
var g_dlg_activated: Delegate = .{ .vtbl = &delegate_vtbl, .kind = 1, .iid = &IID_TypedEventHandler_Toast_Object };
var g_dlg_failed: Delegate = .{ .vtbl = &delegate_vtbl, .kind = 2, .iid = &IID_TypedEventHandler_Toast_Failed };
var g_show_t0_us: i64 = 0;

fn dlgQI(self: *Delegate, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, self.iid) or guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_IAgileObject)) {
        out.* = self;
        return S_OK;
    }
    Log.ev("delegate_qi_miss", .{ .kind = self.kind, .iid = GuidStr.of(riid) });
    out.* = null;
    return E_NOINTERFACE;
}
fn dlgAddRef(_: *Delegate) callconv(.winapi) u32 {
    return 2;
}
fn dlgRelease(_: *Delegate) callconv(.winapi) u32 {
    return 1;
}
fn dlgInvoke(self: *Delegate, sender: ?*anyopaque, args: ?*anyopaque) callconv(.winapi) HRESULT {
    _ = sender;
    const dt_ms = @divTrunc(nowUs() - g_show_t0_us, 1000);
    switch (self.kind) {
        0 => {
            var reason: i32 = -1;
            if (args) |a| {
                const e: *IToastDismissedEventArgs = @ptrCast(@alignCast(a));
                _ = e.vtbl.get_Reason(e, &reason);
            }
            const names = [_][]const u8{ "UserCanceled", "ApplicationHidden", "TimedOut" };
            Log.ev("toast_dismissed", .{ .ms_after_show = dt_ms, .reason = reason, .reason_name = if (reason >= 0 and reason < 3) names[@intCast(reason)] else "?" });
        },
        1 => {
            var arg_s: []const u8 = "";
            if (args) |a| {
                const insp: *IInspectable = @ptrCast(@alignCast(a));
                if (insp.query(IToastActivatedEventArgs, &IID_IToastActivatedEventArgs)) |ae| {
                    defer ae.release();
                    var hs: HSTRING = null;
                    if (ae.vtbl.get_Arguments(ae, &hs) >= 0) {
                        arg_s = hsToUtf8(hs);
                        _ = WindowsDeleteString(hs);
                    }
                } else |_| {}
            }
            Log.ev("toast_activated_event", .{ .ms_after_show = dt_ms, .arguments = arg_s });
        },
        else => {
            var code: HRESULT = 0;
            if (args) |a| {
                const e: *IToastFailedEventArgs = @ptrCast(@alignCast(a));
                _ = e.vtbl.get_ErrorCode(e, &code);
            }
            Log.ev("toast_failed", .{ .ms_after_show = dt_ms, .error_code = hx(code) });
        },
    }
    return S_OK;
}

// ─── COM activator (INotificationActivationCallback) + class factory ────
const Activator = extern struct { vtbl: *const ActivatorVtbl };
const ActivatorVtbl = extern struct {
    QueryInterface: *const fn (*Activator, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*Activator) callconv(.winapi) u32,
    Release: *const fn (*Activator) callconv(.winapi) u32,
    Activate: *const fn (*Activator, LPCWSTR, ?LPCWSTR, ?[*]const NOTIFICATION_USER_INPUT_DATA, u32) callconv(.winapi) HRESULT,
};
const activator_vtbl: ActivatorVtbl = .{ .QueryInterface = actQI, .AddRef = actAddRef, .Release = actRelease, .Activate = actActivate };
var g_activator: Activator = .{ .vtbl = &activator_vtbl };

fn actQI(self: *Activator, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_INotificationActivationCallback)) {
        out.* = self;
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}
fn actAddRef(_: *Activator) callconv(.winapi) u32 {
    return 2;
}
fn actRelease(_: *Activator) callconv(.winapi) u32 {
    return 1;
}
fn actActivate(_: *Activator, aumid: LPCWSTR, invoked_args: ?LPCWSTR, data: ?[*]const NOTIFICATION_USER_INPUT_DATA, count: u32) callconv(.winapi) HRESULT {
    const probe = probeForeground();
    Log.ev("com_activate", .{
        .aumid = w8z(aumid),
        .args = w8z(invoked_args),
        .input_count = count,
        .fg_probe_ok = probe.ok,
        .fg_probe_err = probe.err,
        .fg_pid = foregroundPid(),
    });
    if (data) |d| {
        for (d[0..count]) |item| Log.ev("com_activate_input", .{ .key = w8z(item.Key), .value = w8z(item.Value) });
    }
    noteActivity();
    return S_OK;
}

const ClassFactory = extern struct { vtbl: *const ClassFactoryVtbl };
const ClassFactoryVtbl = extern struct {
    QueryInterface: *const fn (*ClassFactory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ClassFactory) callconv(.winapi) u32,
    Release: *const fn (*ClassFactory) callconv(.winapi) u32,
    CreateInstance: *const fn (*ClassFactory, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    LockServer: *const fn (*ClassFactory, BOOL) callconv(.winapi) HRESULT,
};
const factory_vtbl: ClassFactoryVtbl = .{ .QueryInterface = cfQI, .AddRef = cfAddRef, .Release = cfRelease, .CreateInstance = cfCreateInstance, .LockServer = cfLockServer };
var g_factory: ClassFactory = .{ .vtbl = &factory_vtbl };

fn cfQI(self: *ClassFactory, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_IClassFactory)) {
        out.* = self;
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}
fn cfAddRef(_: *ClassFactory) callconv(.winapi) u32 {
    return 2;
}
fn cfRelease(_: *ClassFactory) callconv(.winapi) u32 {
    return 1;
}
fn cfCreateInstance(_: *ClassFactory, outer: ?*anyopaque, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (outer != null) return CLASS_E_NOAGGREGATION;
    const h = actQI(&g_activator, riid, out);
    Log.ev("com_create_instance", .{ .iid = GuidStr.of(riid), .hr = hx(h) });
    noteActivity();
    return h;
}
fn cfLockServer(_: *ClassFactory, lock: BOOL) callconv(.winapi) HRESULT {
    Log.ev("com_lock_server", .{ .lock = lock });
    return S_OK;
}

// ─── Server (hidden; launch pipe + COM class object) ────────────────────
var g_last_activity_ms: i64 = 0;
var g_quit_event: ?HANDLE = null;
var g_foreground_demo = false;

fn noteActivity() void {
    @atomicStore(i64, &g_last_activity_ms, std.time.milliTimestamp(), .release);
}

fn cmdServer(args: []const [:0]const u8, cold: bool) !void {
    const me = procInfo(GetCurrentProcessId());
    const parent = procInfo(me.parent);
    Log.ev("server_start", .{
        .cold_com_launch = cold,
        .cmdline = w8z(GetCommandLineW()),
        .parent_pid = me.parent,
        .parent_exe = parent.exe,
        .fg_pid = foregroundPid(),
    });
    const idle_exit_ms: i64 = if (argValue(args, "--idle-exit-ms")) |v| std.fmt.parseInt(i64, v, 10) catch 180_000 else 180_000;
    g_foreground_demo = hasFlag(args, "--foreground-demo");
    if (!g_foreground_demo) startFgGuard();

    const h_aumid = SetCurrentProcessExplicitAppUserModelID(L(AUMID));
    const h_init = CoInitializeEx(null, COINIT_MULTITHREADED);
    var cookie: DWORD = 0;
    const h_reg = CoRegisterClassObject(&CLSID_SPIKE, &g_factory, CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie);
    Log.ev("server_com_ready", .{ .set_aumid_hr = hx(h_aumid), .coinit_hr = hx(h_init), .register_class_hr = hx(h_reg), .cookie = cookie, .pre_probe = probeForeground().ok });

    g_quit_event = CreateEventW(null, 1, 0, null);
    noteActivity();
    const t = try std.Thread.spawn(.{}, pipeServerThread, .{});
    t.detach();

    while (true) {
        if (k32.WaitForSingleObject(g_quit_event.?, 250) == 0) break;
        const idle = std.time.milliTimestamp() - @atomicLoad(i64, &g_last_activity_ms, .acquire);
        if (idle > idle_exit_ms) {
            Log.ev("server_idle_exit", .{ .idle_ms = idle });
            break;
        }
    }
    if (h_reg >= 0) _ = CoRevokeClassObject(cookie);
    CoUninitialize();
    Log.ev("server_exit", .{});
    k32.ExitProcess(0);
}

fn pipeServerThread() void {
    var first = true;
    while (true) {
        const mode: DWORD = PIPE_ACCESS_DUPLEX | (if (first) FILE_FLAG_FIRST_PIPE_INSTANCE else 0);
        const h = k32.CreateNamedPipeW(L(PIPE_NAME), mode, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_REJECT_REMOTE_CLIENTS, PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, null);
        if (h == windows.INVALID_HANDLE_VALUE) {
            Log.ev("pipe_create_fail", .{ .err = lastErr(), .first_instance = first });
            return; // another instance owns the launch pipe; COM still works
        }
        if (first) Log.ev("pipe_listening", .{ .name = PIPE_NAME });
        first = false;
        const connected = ConnectNamedPipe(h, null) != 0 or lastErr() == ERROR_PIPE_CONNECTED;
        if (connected) handlePipeClient(h);
        _ = k32.FlushFileBuffers(h);
        _ = DisconnectNamedPipe(h);
        windows.CloseHandle(h);
    }
}

fn pipeSend(h: HANDLE, msg: []const u8) bool {
    var n: DWORD = 0;
    return k32.WriteFile(h, msg.ptr, @intCast(msg.len), &n, null) != 0;
}
fn pipeRecv(h: HANDLE, buf: []u8) ?[]u8 {
    var n: DWORD = 0;
    if (k32.ReadFile(h, buf.ptr, @intCast(buf.len), &n, null) == 0) return null;
    return buf[0..n];
}

fn handlePipeClient(h: HANDLE) void {
    noteActivity();
    var client_pid: DWORD = 0;
    _ = GetNamedPipeClientProcessId(h, &client_pid);
    var buf: [4096]u8 = undefined;
    const m1 = pipeRecv(h, &buf) orelse return;
    if (std.mem.eql(u8, m1, "PING")) {
        var out: [64]u8 = undefined;
        _ = pipeSend(h, std.fmt.bufPrint(&out, "PONG {d}", .{GetCurrentProcessId()}) catch "PONG");
        return;
    }
    if (std.mem.eql(u8, m1, "QUIT")) {
        _ = pipeSend(h, "BYE");
        Log.ev("server_quit_requested", .{ .client_pid = client_pid });
        _ = SetEvent(g_quit_event.?);
        return;
    }
    if (std.mem.startsWith(u8, m1, "SPAWN ")) {
        // Negative control: this (rights-free) server launches the handler
        // itself. Must not block the pipe thread: the handler connects back.
        const uri = gpa.dupe(u8, m1["SPAWN ".len..]) catch return;
        _ = pipeSend(h, "SPAWNED");
        const t = std.Thread.spawn(.{}, spawnThread, .{uri}) catch return;
        t.detach();
        return;
    }
    if (!std.mem.startsWith(u8, m1, "HELLO")) return;
    // Round 1: measure our rights BEFORE the handler grants them.
    const pre = probeForeground();
    var out: [128]u8 = undefined;
    _ = pipeSend(h, std.fmt.bufPrint(&out, "READY {d} {d} {d}", .{ GetCurrentProcessId(), @intFromBool(pre.ok), pre.err }) catch "READY");
    // Round 2: the handler has called AllowSetForegroundWindow(our pid).
    var buf2: [4096]u8 = undefined;
    const m2 = pipeRecv(h, &buf2) orelse return;
    const t_recv = nowUs();
    const post = probeForeground();
    _ = pipeSend(h, std.fmt.bufPrint(&out, "ACK {d} {d}", .{ @intFromBool(post.ok), post.err }) catch "ACK");
    // m2 = "URI <grant_ok> <grant_err> <handler_self_ok> <handler_start_us> <uri>"
    var it = std.mem.splitScalar(u8, m2, ' ');
    _ = it.next();
    const grant_ok = it.next() orelse "?";
    const grant_err = it.next() orelse "?";
    const self_ok = it.next() orelse "?";
    const start_us = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
    const uri = it.rest();
    Log.ev("launch_received", .{
        .client_pid = client_pid,
        .uri = uri,
        .handler_self_probe_ok = self_ok,
        .handler_grant_ok = grant_ok,
        .handler_grant_err = grant_err,
        .server_pre_probe_ok = pre.ok,
        .server_pre_probe_err = pre.err,
        .server_post_probe_ok = post.ok,
        .server_post_probe_err = post.err,
        .handler_start_to_server_us = if (start_us > 0) t_recv - start_us else -1,
    });
    if (g_foreground_demo and post.ok) foregroundDemo();
}

fn spawnThread(uri: []const u8) void {
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    defer CoUninitialize();
    const r = shellOpenUri(uri);
    Log.ev("server_spawn_handler", .{ .ok = r.ok, .err = r.err, .shellexec_us = r.shellexec_us, .handler_exit_code = r.exit_code, .server_probe_at_spawn = r.probe_before.ok });
}

const ShellResult = struct { ok: bool, err: u16, shellexec_us: i64, total_us: i64, exit_code: DWORD, has_process: bool, probe_before: Probe };
/// ShellExecuteExW on a URI: no UI on error (never an "open with" dialog),
/// synchronous, returns the handler process so we can wait for it.
fn shellOpenUri(uri: []const u8) ShellResult {
    var r: ShellResult = .{ .ok = false, .err = 0, .shellexec_us = 0, .total_us = 0, .exit_code = 0xFFFF_FFFF, .has_process = false, .probe_before = probeForeground() };
    const uri_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, uri) catch return r;
    var sei: SHELLEXECUTEINFOW = .{
        .cbSize = @sizeOf(SHELLEXECUTEINFOW),
        .fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC,
        .lpVerb = L("open"),
        .lpFile = uri_w,
        .nShow = SW_SHOWNOACTIVATE,
    };
    const t0 = nowUs();
    r.ok = ShellExecuteExW(&sei) != 0;
    r.err = if (r.ok) 0 else lastErr();
    r.shellexec_us = nowUs() - t0;
    if (sei.hProcess) |p| {
        r.has_process = true;
        _ = k32.WaitForSingleObject(p, 15_000);
        _ = k32.GetExitCodeProcess(p, &r.exit_code);
        windows.CloseHandle(p);
    }
    r.total_us = nowUs() - t0;
    return r;
}

/// Manual mode only (--foreground-demo): show a small window and try to take
/// the foreground with the rights received from the handler.
fn foregroundDemo() void {
    const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
    const WS_VISIBLE: DWORD = 0x10000000;
    const hwnd = CreateWindowExW(0, L("STATIC"), L("wmux spike S1 - protocol activation took the foreground"), WS_OVERLAPPEDWINDOW | WS_VISIBLE, 200, 200, 640, 120, null, null, null, null) orelse return;
    const ok = SetForegroundWindow(hwnd) != 0;
    Log.ev("foreground_demo", .{ .set_foreground_ok = ok, .is_foreground = GetForegroundWindow() == hwnd });
    const t_end = std.time.milliTimestamp() + 4000;
    var msg: MSG = undefined;
    while (std.time.milliTimestamp() < t_end) {
        while (PeekMessageW(&msg, null, 0, 0, 1) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        k32.Sleep(20);
    }
    _ = DestroyWindow(hwnd);
}

// ─── Protocol handler (what wmux.exe "<uri>" does) ──────────────────────
fn pipeConnect(timeout_ms: u32) ?HANDLE {
    var waited: u32 = 0;
    while (true) {
        // SECURITY_IDENTIFICATION: a squatting server cannot impersonate us.
        const h = k32.CreateFileW(L(PIPE_NAME), GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, null);
        if (h != windows.INVALID_HANDLE_VALUE) {
            var mode: DWORD = PIPE_READMODE_MESSAGE;
            _ = SetNamedPipeHandleState(h, &mode, null, null);
            return h;
        }
        const err = lastErr();
        if (err == ERROR_PIPE_BUSY and waited < timeout_ms) {
            _ = WaitNamedPipeW(L(PIPE_NAME), 500);
            waited += 500;
            continue;
        }
        Log.ev("pipe_connect_fail", .{ .err = err });
        return null;
    }
}

fn cmdHandler(uri: []const u8) void {
    const t_start = nowUs();
    startFgGuard();
    const me = procInfo(GetCurrentProcessId());
    const parent = procInfo(me.parent);
    const fg_pid = foregroundPid();
    const self_probe = probeForeground();
    Log.ev("handler_start", .{
        .uri = uri,
        .parent_pid = me.parent,
        .parent_exe = parent.exe,
        .fg_pid = fg_pid,
        .fg_exe = procInfo(fg_pid).exe,
        .idle_ms = idleMs(),
        .self_probe_ok = self_probe.ok,
        .self_probe_err = self_probe.err,
    });
    const h = pipeConnect(2000) orelse {
        // wmux would become the app here and open the record after restore.
        Log.ev("handler_no_instance", .{});
        k32.ExitProcess(3);
    };
    defer windows.CloseHandle(h);
    var server_pid: DWORD = 0;
    _ = GetNamedPipeServerProcessId(h, &server_pid);
    var out: [4096]u8 = undefined;
    _ = pipeSend(h, std.fmt.bufPrint(&out, "HELLO {d}", .{GetCurrentProcessId()}) catch "HELLO");
    var buf: [256]u8 = undefined;
    const ready = pipeRecv(h, &buf) orelse "";
    const ready_copy = gpa.dupe(u8, ready) catch "";
    // Grant BEFORE the request is processed, so the server holds the right
    // while it handles the request (ADR-3.1 / 7.5).
    const grant_ok = AllowSetForegroundWindow(server_pid) != 0;
    const grant_err: u16 = if (grant_ok) 0 else lastErr();
    _ = pipeSend(h, std.fmt.bufPrint(&out, "URI {d} {d} {d} {d} {s}", .{ @intFromBool(grant_ok), grant_err, @intFromBool(self_probe.ok), t_start, uri }) catch "URI");
    var buf2: [256]u8 = undefined;
    const ack = pipeRecv(h, &buf2) orelse "";
    Log.ev("handler_done", .{
        .server_pid = server_pid,
        .ready = ready_copy,
        .grant_ok = grant_ok,
        .grant_err = grant_err,
        .ack = ack,
        .total_us = nowUs() - t_start,
    });
    k32.ExitProcess(0);
}

// ─── Driver commands ────────────────────────────────────────────────────
fn cmdEnv() void {
    var vi: windows.RTL_OSVERSIONINFOW = undefined;
    vi.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
    _ = windows.ntdll.RtlGetVersion(&vi);
    var quns: i32 = 0;
    const h_quns = SHQueryUserNotificationState(&quns);
    var lock_timeout: u32 = 0;
    _ = SystemParametersInfoW(SPI_GETFOREGROUNDLOCKTIMEOUT, 0, &lock_timeout, 0);
    var session: DWORD = 0;
    _ = ProcessIdToSessionId(GetCurrentProcessId(), &session);
    const fg = foregroundPid();
    const probe = probeForeground();
    Log.ev("env", .{
        .os = .{ vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber },
        .session = session,
        .quns = quns,
        .quns_hr = hx(h_quns),
        .foreground_lock_timeout_ms = lock_timeout,
        .idle_ms = idleMs(),
        .fg_pid = fg,
        .fg_exe = procInfo(fg).exe,
        .self_probe_ok = probe.ok,
        .self_probe_err = probe.err,
        .activation_callback_proxy_stub = regReadSz(HKCR, "Interface\\{53E31837-6600-4A81-9395-75CFFE746F94}\\ProxyStubClsid32", null),
        .toast_enabled_user = regReadDword(HKCU, "Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications", "ToastEnabled"),
        .policy_no_toast_hkcu = regReadDword(HKCU, "Software\\Policies\\Microsoft\\Windows\\CurrentVersion\\PushNotifications", "NoToastApplicationNotification"),
        .aumid_key = regExists(HKCU, KEY_AUMID),
        .protocol_key = regExists(HKCU, KEY_PROTO),
        .clsid_key = regExists(HKCU, KEY_CLSID),
        .notif_settings_key = regExists(HKCU, KEY_NOTIF_SETTINGS),
        .notif_settings_enabled = regReadDword(HKCU, KEY_NOTIF_SETTINGS, "Enabled"),
    });
}

fn cmdRegister(args: []const [:0]const u8) !void {
    const dir = try std.fs.selfExeDirPathAlloc(gpa);
    const s1w = try std.fmt.allocPrint(gpa, "{s}\\s1w.exe", .{dir});
    const icon = argValue(args, "--icon") orelse try std.fmt.allocPrint(gpa, "{s}\\s1-icon.png", .{dir});
    // AUMID registration (no Start-menu shortcut). CustomActivator ties the
    // AUMID to the COM activator for activationType="foreground" actions.
    _ = regSetSz(KEY_AUMID, "DisplayName", "wmux spike S1");
    _ = regSetSz(KEY_AUMID, "IconUri", icon);
    if (!hasFlag(args, "--no-activator")) _ = regSetSz(KEY_AUMID, "CustomActivator", CLSID_STR);
    // URL protocol: "<exe>" "%1" (same shape as ADR-7.5 for wmux.exe).
    _ = regSetSz(KEY_PROTO, null, "URL:wmux spike S1");
    _ = regSetSz(KEY_PROTO, "URL Protocol", "");
    _ = regSetSz(KEY_PROTO ++ "\\shell\\open\\command", null, try std.fmt.allocPrint(gpa, "\"{s}\" \"%1\"", .{s1w}));
    // Per-user COM LocalServer32 for the activator.
    if (!hasFlag(args, "--no-activator")) {
        _ = regSetSz(KEY_CLSID, null, "wmux spike S1 toast activator");
        _ = regSetSz(KEY_CLSID ++ "\\LocalServer32", null, try std.fmt.allocPrint(gpa, "\"{s}\" -ToastActivated", .{s1w}));
    }
}

fn cmdUnregister() void {
    if (RoInitialize(RO_INIT_MULTITHREADED) >= 0) {
        clearHistory();
        RoUninitialize();
    }
    _ = regDeleteTree(KEY_AUMID);
    _ = regDeleteTree(KEY_PROTO);
    _ = regDeleteTree(KEY_CLSID);
    _ = regDeleteTree(KEY_NOTIF_SETTINGS);
    cmdEnv();
}

fn clearHistory() void {
    var hist = History.open() catch return;
    defer hist.close();
    var id = HS.init(AUMID) catch return;
    defer id.deinit();
    const h = hist.hist.vtbl.ClearWithId(hist.hist, id.h);
    Log.ev("history_clear_with_id", .{ .hr = hx(h) });
}

fn cmdSetting(args: []const [:0]const u8) !void {
    try check(RoInitialize(RO_INIT_MULTITHREADED), "RoInitialize");
    defer RoUninitialize();
    const aumid = argValue(args, "--aumid") orelse AUMID;
    const n = try createNotifier(aumid);
    defer n.release();
    _ = readSetting(n);
}

fn cmdSetAppEnabled(args: []const [:0]const u8) void {
    // Per-app toggle as written by Settings > Notifications (spike AUMID only).
    const v = argValue(args, "--value") orelse "0";
    if (std.mem.eql(u8, v, "delete")) {
        var key: HKEY = undefined;
        if (windows.advapi32.RegOpenKeyExW(HKCU, L(KEY_NOTIF_SETTINGS), 0, KEY_WRITE, &key) == 0) {
            const st = RegDeleteValueW(key, L("Enabled"));
            _ = windows.advapi32.RegCloseKey(key);
            Log.ev("reg_delete_value", .{ .key = KEY_NOTIF_SETTINGS, .name = "Enabled", .status = st });
        }
        return;
    }
    _ = regSetDword(KEY_NOTIF_SETTINGS, "Enabled", std.fmt.parseInt(DWORD, v, 10) catch 0);
}

const xml_full =
    \\<toast launch="wmux-spike-s1://notification/open?id={s}&amp;ws={s}" activationType="protocol">
    \\<visual><binding template="ToastGeneric">
    \\<text>wmux spike test - safe to ignore</text>
    \\<text>{s}</text>
    \\</binding></visual>
    \\<actions>
    \\<input id="reply" type="text" placeHolderContent="spike reply"/>
    \\<action content="Reply" arguments="action=reply&amp;id={s}" activationType="foreground" hint-inputId="reply"/>
    \\<action content="Show" arguments="wmux-spike-s1://notification/open?id={s}&amp;button=show" activationType="protocol"/>
    \\</actions>
    \\<audio silent="true"/>
    \\</toast>
;
const xml_simple =
    \\<toast launch="wmux-spike-s1://notification/open?id={s}&amp;ws={s}" activationType="protocol">
    \\<visual><binding template="ToastGeneric">
    \\<text>wmux spike test - safe to ignore</text>
    \\<text>{s}</text>
    \\</binding></visual>
    \\<audio silent="true"/>
    \\</toast>
;

fn cmdShow(args: []const [:0]const u8) !void {
    const variant = argValue(args, "--variant") orelse "A";
    const wait_ms: i64 = std.fmt.parseInt(i64, argValue(args, "--wait-ms") orelse "12000", 10) catch 12000;
    const remove_after_ms: ?i64 = if (argValue(args, "--remove-after-ms")) |v| std.fmt.parseInt(i64, v, 10) catch null else null;
    const remove_mode = argValue(args, "--remove-mode") orelse "tag";
    const long_ids = hasFlag(args, "--long-ids");
    const suppress_popup = hasFlag(args, "--suppress-popup");
    const full = std.mem.eql(u8, variant, "A");
    startFgGuard();

    try check(RoInitialize(RO_INIT_MULTITHREADED), "RoInitialize");
    defer RoUninitialize();
    const notifier = try createNotifier(AUMID);
    defer notifier.release();
    _ = readSetting(notifier);

    var rec: [36]u8 = undefined;
    var ws: [36]u8 = undefined;
    uuid4(&rec);
    uuid4(&ws);
    // ADR-7.5: Tag = record UUID, Group = workspace UUID (36 chars each).
    // --long-ids: 64-char tag/group (documented maximum) for the limit test.
    const tag: []const u8 = if (long_ids) try std.fmt.allocPrint(gpa, "{s}-T{s}", .{ rec, rec[0..26] }) else &rec;
    const group: []const u8 = if (long_ids) try std.fmt.allocPrint(gpa, "{s}-G{s}", .{ ws, ws[0..26] }) else &ws;
    const label = try std.fmt.allocPrint(gpa, "S1-{s}", .{variant});
    const xml = if (full)
        try std.fmt.allocPrint(gpa, xml_full, .{ rec, ws, label, rec, rec })
    else
        try std.fmt.allocPrint(gpa, xml_simple, .{ rec, ws, label });

    const doc = try loadXml(xml);
    defer doc.release();
    const factory = try getFactory(IToastNotificationFactory, "Windows.UI.Notifications.ToastNotification", &IID_IToastNotificationFactory);
    defer factory.release();
    var toast_opt: ?*IToastNotification = null;
    try check(factory.vtbl.CreateToastNotification(factory, doc, &toast_opt), "CreateToastNotification");
    const toast = toast_opt.?;
    defer toast.release();
    const t2 = try toast.query(IToastNotification2, &IID_IToastNotification2);
    defer t2.release();

    if (long_ids) {
        // One character over the limit must be rejected before Show().
        const over = try std.fmt.allocPrint(gpa, "{s}X", .{tag});
        var hs_over = try HS.init(over);
        defer hs_over.deinit();
        Log.ev("put_tag_over_limit", .{ .len = over.len, .hr = hx(t2.vtbl.put_Tag(t2, hs_over.h)) });
        Log.ev("put_group_over_limit", .{ .len = over.len, .hr = hx(t2.vtbl.put_Group(t2, hs_over.h)) });
    }
    var hs_tag = try HS.init(tag);
    defer hs_tag.deinit();
    var hs_group = try HS.init(group);
    defer hs_group.deinit();
    const h_tag = t2.vtbl.put_Tag(t2, hs_tag.h);
    const h_group = t2.vtbl.put_Group(t2, hs_group.h);
    Log.ev("put_tag_group", .{ .tag = tag, .tag_len = tag.len, .tag_hr = hx(h_tag), .group = group, .group_len = group.len, .group_hr = hx(h_group) });
    try check(h_tag, "put_Tag");
    try check(h_group, "put_Group");
    if (suppress_popup) Log.ev("put_suppress_popup", .{ .hr = hx(t2.vtbl.put_SuppressPopup(t2, 1)) });

    var tok_d: EventRegistrationToken = .{ .value = 0 };
    var tok_a: EventRegistrationToken = .{ .value = 0 };
    var tok_f: EventRegistrationToken = .{ .value = 0 };
    Log.ev("subscribe", .{
        .dismissed_hr = hx(toast.vtbl.add_Dismissed(toast, &g_dlg_dismissed, &tok_d)),
        .activated_hr = hx(toast.vtbl.add_Activated(toast, &g_dlg_activated, &tok_a)),
        .failed_hr = hx(toast.vtbl.add_Failed(toast, &g_dlg_failed, &tok_f)),
    });

    var hist = try History.open();
    defer hist.close();
    const before = try hist.contains(tag);
    g_show_t0_us = nowUs();
    const h_show = notifier.vtbl.Show(notifier, toast);
    const show_us = nowUs() - g_show_t0_us;
    Log.ev("show", .{ .variant = variant, .hr = hx(h_show), .call_us = show_us, .history_count_before = before.count, .record_id = &rec });
    try check(h_show, "Show");

    // Poll Action Center history; log only state changes.
    var last_found = false;
    var removed_at_ms: ?i64 = null;
    var first_seen_ms: ?i64 = null;
    var gone_after_remove_ms: ?i64 = null;
    while (true) {
        const el_ms = @divTrunc(nowUs() - g_show_t0_us, 1000);
        if (el_ms > wait_ms) break;
        if (remove_after_ms) |ra| {
            if (removed_at_ms == null and el_ms >= ra) {
                var aumid_hs = try HS.init(AUMID);
                defer aumid_hs.deinit();
                const t_rm = nowUs();
                const h_rm = if (std.mem.eql(u8, remove_mode, "group"))
                    hist.hist.vtbl.RemoveGroupWithId(hist.hist, hs_group.h, aumid_hs.h)
                else
                    hist.hist.vtbl.RemoveGroupedTagWithId(hist.hist, hs_tag.h, hs_group.h, aumid_hs.h);
                removed_at_ms = el_ms;
                Log.ev("remove", .{ .mode = remove_mode, .hr = hx(h_rm), .call_us = nowUs() - t_rm, .at_ms = el_ms });
            }
        }
        const snap = try hist.contains(tag);
        if (snap.found != last_found) {
            Log.ev("history_change", .{ .found = snap.found, .count = snap.count, .ms_after_show = el_ms });
            if (snap.found and first_seen_ms == null) first_seen_ms = el_ms;
            if (!snap.found and removed_at_ms != null and gone_after_remove_ms == null) gone_after_remove_ms = el_ms - removed_at_ms.?;
            last_found = snap.found;
        }
        k32.Sleep(100);
    }
    const final = try hist.contains(tag);
    Log.ev("show_summary", .{
        .variant = variant,
        .tag = tag,
        .group = group,
        .first_seen_in_history_ms = first_seen_ms,
        .still_in_history_at_end = final.found,
        .history_count = final.count,
        .removed_at_ms = removed_at_ms,
        .gone_ms_after_remove = gone_after_remove_ms,
    });
    _ = toast.vtbl.remove_Dismissed(toast, tok_d);
    _ = toast.vtbl.remove_Activated(toast, tok_a);
    _ = toast.vtbl.remove_Failed(toast, tok_f);
}

fn cmdHistory() !void {
    try check(RoInitialize(RO_INIT_MULTITHREADED), "RoInitialize");
    defer RoUninitialize();
    var hist = try History.open();
    defer hist.close();
    const items = try hist.list(true);
    Log.ev("history", .{ .count = items.len });
    for (items, 0..) |it, i| {
        const xml = it.xml orelse "";
        Log.ev("history_item", .{ .index = i, .tag = it.tag, .tag_len = it.tag.len, .tag_hr = it.tag_hr, .group = it.group, .group_len = it.group.len, .group_hr = it.group_hr, .xml = xml[0..@min(xml.len, 600)] });
    }
}

fn cmdRemove(args: []const [:0]const u8) !void {
    try check(RoInitialize(RO_INIT_MULTITHREADED), "RoInitialize");
    defer RoUninitialize();
    var hist = try History.open();
    defer hist.close();
    var aumid_hs = try HS.init(AUMID);
    defer aumid_hs.deinit();
    var tag = try HS.init(argValue(args, "--tag") orelse "");
    defer tag.deinit();
    var group = try HS.init(argValue(args, "--group") orelse "");
    defer group.deinit();
    const mode = argValue(args, "--mode") orelse "tag-group";
    const t0 = nowUs();
    const h = if (std.mem.eql(u8, mode, "group"))
        hist.hist.vtbl.RemoveGroupWithId(hist.hist, group.h, aumid_hs.h)
    else if (std.mem.eql(u8, mode, "tag-only"))
        hist.hist.vtbl.Remove(hist.hist, tag.h) // no app id: uses the caller's identity
    else if (std.mem.eql(u8, mode, "clear"))
        hist.hist.vtbl.ClearWithId(hist.hist, aumid_hs.h)
    else
        hist.hist.vtbl.RemoveGroupedTagWithId(hist.hist, tag.h, group.h, aumid_hs.h);
    Log.ev("remove_cmd", .{ .mode = mode, .hr = hx(h), .call_us = nowUs() - t0 });
    const items = try hist.list(false);
    Log.ev("history_after_remove", .{ .count = items.len });
}

fn cmdSendUri(uri: []const u8) !void {
    startFgGuard();
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    defer CoUninitialize();
    // 1) Resolve the registered command without launching anything.
    var cmd_buf: [1024]u16 = undefined;
    var cch: DWORD = cmd_buf.len;
    const h_assoc = AssocQueryStringW(0, ASSOCSTR_COMMAND, L(PROTOCOL), L("open"), &cmd_buf, &cch);
    const cmd_s = if (h_assoc >= 0) w8(std.mem.sliceTo(&cmd_buf, 0)) else "";
    Log.ev("assoc_query", .{ .hr = hx(h_assoc), .command = cmd_s });
    if (h_assoc < 0) return error.ProtocolNotRegistered;
    // 2) Launch through the shell like a toast click does (minus the user's
    //    input event).
    const r = shellOpenUri(uri);
    Log.ev("send_uri", .{ .ok = r.ok, .err = r.err, .has_process = r.has_process, .shellexec_us = r.shellexec_us, .total_us = r.total_us, .handler_exit_code = r.exit_code, .driver_probe_ok = r.probe_before.ok });
}

/// Start the activator's LocalServer32 through COM (DcomLaunch), so the
/// server does NOT inherit foreground rights from this terminal's process tree.
fn cmdStartServer() !void {
    try check(CoInitializeEx(null, COINIT_MULTITHREADED), "CoInitializeEx");
    defer CoUninitialize();
    const t0 = nowUs();
    var out: ?*anyopaque = null;
    const h = CoCreateInstance(&CLSID_SPIKE, null, CLSCTX_LOCAL_SERVER, &IID_IUnknown, &out);
    Log.ev("start_server", .{ .hr = hx(h), .call_us = nowUs() - t0 });
    if (out) |p| {
        const u: *IInspectable = @ptrCast(@alignCast(p));
        u.release();
    }
}

fn cmdActivateSim(args: []const [:0]const u8) !void {
    startFgGuard();
    try check(CoInitializeEx(null, COINIT_MULTITHREADED), "CoInitializeEx");
    defer CoUninitialize();
    const t0 = nowUs();
    var out: ?*anyopaque = null;
    const h_create = CoCreateInstance(&CLSID_SPIKE, null, CLSCTX_LOCAL_SERVER, &IID_INotificationActivationCallback, &out);
    const t1 = nowUs();
    Log.ev("cocreate_activator", .{ .hr = hx(h_create), .call_us = t1 - t0 });
    try check(h_create, "CoCreateInstance");
    const cb: *INotificationActivationCallback = @ptrCast(@alignCast(out.?));
    defer cb.release();
    const args_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, argValue(args, "--args") orelse "action=reply&id=SIMULATED");
    const reply_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, argValue(args, "--reply") orelse "hello from activate-sim");
    const data = [_]NOTIFICATION_USER_INPUT_DATA{.{ .Key = L("reply"), .Value = reply_w }};
    // --grant: what a well-behaved COM client does to hand its foreground
    // right to the server before the call (IForegroundTransfer on the proxy).
    if (hasFlag(args, "--grant")) {
        Log.ev("co_allow_set_foreground", .{ .hr = hx(CoAllowSetForegroundWindow(cb, null)), .client_probe_ok = probeForeground().ok });
    }
    const t2 = nowUs();
    const h_act = cb.vtbl.Activate(cb, L(AUMID), args_w, &data, data.len);
    Log.ev("activate_call", .{ .hr = hx(h_act), .call_us = nowUs() - t2 });
}
extern "ole32" fn CoAllowSetForegroundWindow(unk: *anyopaque, reserved: ?*anyopaque) callconv(.winapi) HRESULT;

fn cmdPipeSimple(msg: []const u8) void {
    const h = pipeConnect(1000) orelse return;
    defer windows.CloseHandle(h);
    var server_pid: DWORD = 0;
    _ = GetNamedPipeServerProcessId(h, &server_pid);
    _ = pipeSend(h, msg);
    var buf: [128]u8 = undefined;
    Log.ev("pipe_reply", .{ .sent = msg, .reply = pipeRecv(h, &buf) orelse "", .server_pid = server_pid });
}

fn cmdSelftest() void {
    var all_ok = true;
    for (pinterface_cases) |c| {
        const got = pinterfaceIid(c.sig);
        const ok = guidEql(&got, &c.iid);
        all_ok = all_ok and ok;
        Log.ev("pinterface_iid", .{ .name = c.name, .computed = GuidStr.of(&got), .header = GuidStr.of(&c.iid), .match = ok });
    }
    Log.ev("struct_sizes", .{
        .SHELLEXECUTEINFOW = @sizeOf(SHELLEXECUTEINFOW),
        .PROCESSENTRY32W = @sizeOf(PROCESSENTRY32W),
        .HSTRING_HEADER = @sizeOf(HSTRING_HEADER),
        .MSG = @sizeOf(MSG),
        .NOTIFICATION_USER_INPUT_DATA = @sizeOf(NOTIFICATION_USER_INPUT_DATA),
        .all_iids_ok = all_ok,
    });
}

pub fn main() !void {
    const args = try std.process.argsAlloc(gpa);
    const cmd: []const u8 = if (args.len > 1) args[1] else "help";
    const is_uri = std.mem.startsWith(u8, cmd, PROTOCOL ++ ":");
    const is_com = std.mem.eql(u8, cmd, "-ToastActivated") or std.mem.eql(u8, cmd, "-Embedding") or std.mem.eql(u8, cmd, "/Embedding");
    Log.init(if (is_uri) "handler" else if (is_com or std.mem.eql(u8, cmd, "server")) "server" else "cli");

    if (is_uri) return cmdHandler(cmd);
    if (is_com) return cmdServer(args, true);
    if (std.mem.eql(u8, cmd, "server")) return cmdServer(args, false);
    if (std.mem.eql(u8, cmd, "env")) return cmdEnv();
    if (std.mem.eql(u8, cmd, "selftest")) return cmdSelftest();
    if (std.mem.eql(u8, cmd, "register")) return cmdRegister(args);
    if (std.mem.eql(u8, cmd, "unregister")) return cmdUnregister();
    if (std.mem.eql(u8, cmd, "setting")) return cmdSetting(args);
    if (std.mem.eql(u8, cmd, "set-app-enabled")) return cmdSetAppEnabled(args);
    if (std.mem.eql(u8, cmd, "show")) return cmdShow(args);
    if (std.mem.eql(u8, cmd, "history")) return cmdHistory();
    if (std.mem.eql(u8, cmd, "remove")) return cmdRemove(args);
    if (std.mem.eql(u8, cmd, "send-uri")) return cmdSendUri(if (args.len > 2) args[2] else PROTOCOL ++ "://notification/open?id=TEST");
    if (std.mem.eql(u8, cmd, "activate-sim")) return cmdActivateSim(args);
    if (std.mem.eql(u8, cmd, "start-server")) return cmdStartServer();
    if (std.mem.eql(u8, cmd, "spawn-via-server")) return cmdPipeSimple(try std.fmt.allocPrint(gpa, "SPAWN {s}", .{if (args.len > 2) args[2] else PROTOCOL ++ "://notification/open?id=SPAWNED"}));
    if (std.mem.eql(u8, cmd, "ping")) return cmdPipeSimple("PING");
    if (std.mem.eql(u8, cmd, "quit")) return cmdPipeSimple("QUIT");
    Log.ev("usage", .{ .commands = "env selftest register [--no-activator] unregister setting [--aumid X] set-app-enabled --value 0|1|delete show --variant A|B|C [--wait-ms N] [--long-ids] [--suppress-popup] [--remove-after-ms N --remove-mode tag|group] history remove --mode tag-group|group|tag-only|clear --tag T --group G send-uri <uri> start-server spawn-via-server <uri> activate-sim [--args S] [--reply T] [--grant] ping quit server [--idle-exit-ms N] [--foreground-demo]" });
}
