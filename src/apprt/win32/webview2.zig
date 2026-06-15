/// WebView2 COM interface definitions for embedding a browser pane on
/// Windows.
///
/// Each COM interface is an `extern struct` with a vtable pointer. The vtable
/// method order matches Microsoft's `WebView2.idl` (as shipped in the
/// Microsoft.Web.WebView2 NuGet package, verified against the MIDL-generated
/// `WebView2.h`) exactly: each interface inherits IUnknown's 3 methods
/// (QueryInterface, AddRef, Release) at indices 0-2, then its own methods in
/// IDL declaration order.
///
/// Methods we don't need are represented as padding entries in the vtable,
/// each with a comment naming the slot it stands in for.
///
/// This file is self-contained: it only depends on `std.os.windows` types
/// plus kernel32/ole32 imports declared locally, so it can be compiled
/// standalone (see webview2_scratch.zig) without the repo build graph.
///
/// WebView2 is loaded dynamically through WebView2Loader.dll which must be
/// shipped next to the executable; the WebView2 *runtime* (Evergreen) is
/// expected to be installed system-wide (it ships with Windows 11).
const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = windows.HRESULT;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const BOOL = windows.BOOL;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const GUID = windows.GUID;
pub const HWND = windows.HWND;
pub const HMODULE = windows.HMODULE;
pub const RECT = windows.RECT;
pub const LPWSTR = windows.LPWSTR;
pub const LPCWSTR = windows.LPCWSTR;

const PadFn = *const fn () callconv(.winapi) void;

// ─── GUIDs ──────────────────────────────────────────────────────────────
// All IIDs verified against the official WebView2.h from the
// Microsoft.Web.WebView2 NuGet package.

pub const IID_IUnknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");

// Consumed interfaces.
pub const IID_ICoreWebView2Environment = GUID.parse("{b96d755e-0319-4e92-a296-23436f46a1fc}");
pub const IID_ICoreWebView2Controller = GUID.parse("{4d00c0d1-9434-4eb6-8078-8697a560334f}");
pub const IID_ICoreWebView2 = GUID.parse("{76eceacb-0462-4d94-ac83-423a6793775e}");
pub const IID_ICoreWebView2NavigationCompletedEventArgs = GUID.parse("{30d68b7d-20d9-4752-a9ca-ec8448fbb5c1}");
pub const IID_ICoreWebView2AcceleratorKeyPressedEventArgs = GUID.parse("{9f760f8a-fb79-42be-9990-7b56900fa9c7}");
pub const IID_ICoreWebView2DevToolsProtocolEventReceiver = GUID.parse("{b32ca51a-8371-45e9-9317-af021d080367}");
pub const IID_ICoreWebView2DevToolsProtocolEventReceivedEventArgs = GUID.parse("{653c2959-bb3a-4377-8632-b58ada4e66c4}");

// Implemented (callback handler) interfaces.
pub const IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = GUID.parse("{4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d}");
pub const IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = GUID.parse("{6c4819f3-c9b7-4260-8127-c9f5bde7f68c}");
pub const IID_ICoreWebView2NavigationCompletedEventHandler = GUID.parse("{d33a35bf-1c49-4f98-93ab-006e0533fe1c}");
pub const IID_ICoreWebView2DocumentTitleChangedEventHandler = GUID.parse("{f5f2b923-953e-4042-9f95-f3a118e1afd4}");
pub const IID_ICoreWebView2ExecuteScriptCompletedHandler = GUID.parse("{49511172-cc67-4bca-9923-137112f4c4cc}");
pub const IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler = GUID.parse("{5c4889f0-5ef6-4c5a-952c-d8f1b92d0574}");
// NOTE: WebView2.h says 41a8 for Data3, not 42a8 as sometimes misquoted.
pub const IID_ICoreWebView2AcceleratorKeyPressedEventHandler = GUID.parse("{b29c7e28-fa79-41a8-8e44-65811c76dcb2}");
pub const IID_ICoreWebView2FocusChangedEventHandler = GUID.parse("{05ea24bd-6452-4926-9014-4b82b498135d}");
pub const IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler = GUID.parse("{e2fda4be-5456-406c-a261-3d452138362c}");

pub fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// ─── Enums / supporting types ───────────────────────────────────────────

/// EventRegistrationToken from eventtoken.h: returned by add_* event
/// registration methods and passed by value to the matching remove_*.
pub const EventRegistrationToken = extern struct {
    value: i64 = 0,
};

pub const COREWEBVIEW2_MOVE_FOCUS_REASON = enum(i32) {
    programmatic = 0,
    next = 1,
    previous = 2,
};

pub const COREWEBVIEW2_KEY_EVENT_KIND = enum(i32) {
    key_down = 0,
    key_up = 1,
    system_key_down = 2,
    system_key_up = 3,
};

/// COREWEBVIEW2_WEB_ERROR_STATUS: we only need pass-through of the raw
/// value for logging/decisions, so keep it as a plain integer.
pub const COREWEBVIEW2_WEB_ERROR_STATUS = i32;

pub const COREWEBVIEW2_PHYSICAL_KEY_STATUS = extern struct {
    RepeatCount: u32,
    ScanCode: u32,
    IsExtendedKey: BOOL,
    IsMenuKeyDown: BOOL,
    WasKeyDown: BOOL,
    IsKeyReleased: BOOL,
};

// ─── Loader ─────────────────────────────────────────────────────────────
// WebView2Loader.dll is loaded at runtime so that the binary starts fine on
// machines without the loader/runtime; callers gate on isRuntimeAvailable().

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: LPCWSTR,
    hFile: ?*anyopaque,
    dwFlags: u32,
) callconv(.winapi) ?HMODULE;

extern "kernel32" fn LoadLibraryW(
    lpLibFileName: LPCWSTR,
) callconv(.winapi) ?HMODULE;

extern "kernel32" fn GetProcAddress(
    hModule: HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*anyopaque;

/// Frees strings returned through `LPWSTR*` out-params (browser version,
/// source URI, document title, ...). Exposed because callers of getSource
/// and friends own the returned buffer.
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

const LOAD_LIBRARY_SEARCH_APPLICATION_DIR: u32 = 0x0000_0200;

/// `GetAvailableCoreWebView2BrowserVersionString` export of
/// WebView2Loader.dll. The returned version string must be freed with
/// CoTaskMemFree.
pub const GetAvailableCoreWebView2BrowserVersionStringFn = *const fn (
    browser_executable_folder: ?LPCWSTR,
    version_info: *?LPWSTR,
) callconv(.winapi) HRESULT;

/// `CreateCoreWebView2EnvironmentWithOptions` export of WebView2Loader.dll.
/// `environment_options` is an ICoreWebView2EnvironmentOptions (we always
/// pass null); `environment_created_handler` is an
/// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler.
pub const CreateCoreWebView2EnvironmentWithOptionsFn = *const fn (
    browser_executable_folder: ?LPCWSTR,
    user_data_folder: ?LPCWSTR,
    environment_options: ?*anyopaque,
    environment_created_handler: *anyopaque,
) callconv(.winapi) HRESULT;

pub const Loader = struct {
    module: HMODULE,
    GetAvailableCoreWebView2BrowserVersionString: GetAvailableCoreWebView2BrowserVersionStringFn,
    CreateCoreWebView2EnvironmentWithOptions: CreateCoreWebView2EnvironmentWithOptionsFn,

    /// Kick off async creation of a WebView2 environment. `handler` must be
    /// a pointer to an instance of `EnvironmentCompletedHandler(Ctx)` (or
    /// any object implementing
    /// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler).
    pub fn createEnvironment(
        self: *const Loader,
        browser_executable_folder: ?LPCWSTR,
        user_data_folder: ?LPCWSTR,
        handler: anytype,
    ) !void {
        const hr = self.CreateCoreWebView2EnvironmentWithOptions(
            browser_executable_folder,
            user_data_folder,
            null,
            @ptrCast(handler),
        );
        if (hr != S_OK) return error.WebView2Error;
    }
};

var loader_global: ?Loader = null;
var loader_mutex: std.Thread.Mutex = .{};

/// Load WebView2Loader.dll (once; cached) and resolve the two exports we
/// use. The DLL is searched in the application directory first; if that
/// fails (e.g. a test exe run from a build cache directory with the DLL
/// sitting beside it in the cwd-resolved default search path), fall back to
/// a plain LoadLibraryW default search.
pub fn loadLoader() !*Loader {
    loader_mutex.lock();
    defer loader_mutex.unlock();
    if (loader_global) |*loader| return loader;

    const name = std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll");
    const module = LoadLibraryExW(name, null, LOAD_LIBRARY_SEARCH_APPLICATION_DIR) orelse
        LoadLibraryW(name) orelse
        return error.WebView2LoaderNotFound;

    const get_version = GetProcAddress(
        module,
        "GetAvailableCoreWebView2BrowserVersionString",
    ) orelse return error.WebView2LoaderInvalid;
    const create_env = GetProcAddress(
        module,
        "CreateCoreWebView2EnvironmentWithOptions",
    ) orelse return error.WebView2LoaderInvalid;

    loader_global = .{
        .module = module,
        .GetAvailableCoreWebView2BrowserVersionString = @ptrCast(get_version),
        .CreateCoreWebView2EnvironmentWithOptions = @ptrCast(create_env),
    };
    return &loader_global.?;
}

/// Returns true if both WebView2Loader.dll and an installed WebView2
/// runtime are available on this machine.
pub fn isRuntimeAvailable() bool {
    const loader = loadLoader() catch return false;
    var version: ?LPWSTR = null;
    const hr = loader.GetAvailableCoreWebView2BrowserVersionString(null, &version);
    if (hr != S_OK) return false;
    const v = version orelse return false;
    CoTaskMemFree(v);
    return true;
}

// ─── IUnknown ───────────────────────────────────────────────────────────

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // Index 0
        QueryInterface: *const fn (*const IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        // Index 1
        AddRef: *const fn (*const IUnknown) callconv(.winapi) u32,
        // Index 2
        Release: *const fn (*const IUnknown) callconv(.winapi) u32,
    };

    pub fn addRef(self: *IUnknown) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *IUnknown) void {
        _ = self.vtable.Release(self);
    }
};

// ─── ICoreWebView2Environment ───────────────────────────────────────────
// Inherits IUnknown. IDL order: CreateCoreWebView2Controller,
// CreateWebResourceResponse, get_BrowserVersionString,
// add_NewBrowserVersionAvailable, remove_NewBrowserVersionAvailable.

pub const ICoreWebView2Environment = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Environment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Environment) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Environment) callconv(.winapi) u32,
        // Index 3: CreateCoreWebView2Controller(HWND, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*)
        CreateCoreWebView2Controller: *const fn (*const ICoreWebView2Environment, HWND, *anyopaque) callconv(.winapi) HRESULT,
        // Index 4: CreateWebResourceResponse (padding)
        _pad4: PadFn,
        // Index 5: get_BrowserVersionString(LPWSTR*)
        get_BrowserVersionString: *const fn (*const ICoreWebView2Environment, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: add_NewBrowserVersionAvailable (padding)
        _pad6: PadFn,
        // Index 7: remove_NewBrowserVersionAvailable (padding)
        _pad7: PadFn,
    };

    pub fn addRef(self: *ICoreWebView2Environment) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment) void {
        _ = self.vtable.Release(self);
    }

    /// Kick off async creation of a controller hosted in `parent`. `handler`
    /// must be a pointer to an instance of `ControllerCompletedHandler(Ctx)`.
    pub fn createController(self: *const ICoreWebView2Environment, parent: HWND, handler: anytype) !void {
        const hr = self.vtable.CreateCoreWebView2Controller(self, parent, @ptrCast(handler));
        if (hr != S_OK) return error.WebView2Error;
    }

    /// Returns the browser version string. Caller frees with CoTaskMemFree.
    pub fn getBrowserVersionString(self: *const ICoreWebView2Environment) !LPWSTR {
        var version: ?LPWSTR = null;
        const hr = self.vtable.get_BrowserVersionString(self, &version);
        if (hr != S_OK) return error.WebView2Error;
        return version orelse error.WebView2Error;
    }
};

// ─── ICoreWebView2Controller ────────────────────────────────────────────
// Inherits IUnknown. 23 own methods, indices 3-25, IDL order verified
// against WebView2.h.

pub const ICoreWebView2Controller = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Controller, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Controller) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Controller) callconv(.winapi) u32,
        // Index 3: get_IsVisible(BOOL*)
        get_IsVisible: *const fn (*const ICoreWebView2Controller, *BOOL) callconv(.winapi) HRESULT,
        // Index 4: put_IsVisible(BOOL)
        put_IsVisible: *const fn (*const ICoreWebView2Controller, BOOL) callconv(.winapi) HRESULT,
        // Index 5: get_Bounds(RECT*)
        get_Bounds: *const fn (*const ICoreWebView2Controller, *RECT) callconv(.winapi) HRESULT,
        // Index 6: put_Bounds(RECT) — RECT passed by value.
        put_Bounds: *const fn (*const ICoreWebView2Controller, RECT) callconv(.winapi) HRESULT,
        // Index 7: get_ZoomFactor(double*)
        get_ZoomFactor: *const fn (*const ICoreWebView2Controller, *f64) callconv(.winapi) HRESULT,
        // Index 8: put_ZoomFactor(double)
        put_ZoomFactor: *const fn (*const ICoreWebView2Controller, f64) callconv(.winapi) HRESULT,
        // Index 9: add_ZoomFactorChanged (padding)
        _pad9: PadFn,
        // Index 10: remove_ZoomFactorChanged (padding)
        _pad10: PadFn,
        // Index 11: SetBoundsAndZoomFactor (padding)
        _pad11: PadFn,
        // Index 12: MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON)
        MoveFocus: *const fn (*const ICoreWebView2Controller, COREWEBVIEW2_MOVE_FOCUS_REASON) callconv(.winapi) HRESULT,
        // Index 13: add_MoveFocusRequested (padding)
        _pad13: PadFn,
        // Index 14: remove_MoveFocusRequested (padding)
        _pad14: PadFn,
        // Index 15: add_GotFocus(ICoreWebView2FocusChangedEventHandler*, EventRegistrationToken*)
        add_GotFocus: *const fn (*const ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 16: remove_GotFocus(EventRegistrationToken)
        remove_GotFocus: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 17: add_LostFocus (padding)
        _pad17: PadFn,
        // Index 18: remove_LostFocus (padding)
        _pad18: PadFn,
        // Index 19: add_AcceleratorKeyPressed(ICoreWebView2AcceleratorKeyPressedEventHandler*, EventRegistrationToken*)
        add_AcceleratorKeyPressed: *const fn (*const ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 20: remove_AcceleratorKeyPressed(EventRegistrationToken)
        remove_AcceleratorKeyPressed: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 21: get_ParentWindow (padding)
        _pad21: PadFn,
        // Index 22: put_ParentWindow (padding)
        _pad22: PadFn,
        // Index 23: NotifyParentWindowPositionChanged()
        NotifyParentWindowPositionChanged: *const fn (*const ICoreWebView2Controller) callconv(.winapi) HRESULT,
        // Index 24: Close()
        Close: *const fn (*const ICoreWebView2Controller) callconv(.winapi) HRESULT,
        // Index 25: get_CoreWebView2(ICoreWebView2**)
        get_CoreWebView2: *const fn (*const ICoreWebView2Controller, *?*ICoreWebView2) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Controller) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Controller) void {
        _ = self.vtable.Release(self);
    }

    pub fn getIsVisible(self: *const ICoreWebView2Controller) !bool {
        var visible: BOOL = FALSE;
        const hr = self.vtable.get_IsVisible(self, &visible);
        if (hr != S_OK) return error.WebView2Error;
        return visible != FALSE;
    }

    pub fn putIsVisible(self: *const ICoreWebView2Controller, visible: bool) !void {
        const hr = self.vtable.put_IsVisible(self, if (visible) TRUE else FALSE);
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn getBounds(self: *const ICoreWebView2Controller) !RECT {
        var bounds: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const hr = self.vtable.get_Bounds(self, &bounds);
        if (hr != S_OK) return error.WebView2Error;
        return bounds;
    }

    pub fn putBounds(self: *const ICoreWebView2Controller, bounds: RECT) !void {
        const hr = self.vtable.put_Bounds(self, bounds);
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn getZoomFactor(self: *const ICoreWebView2Controller) !f64 {
        var zoom: f64 = 0;
        const hr = self.vtable.get_ZoomFactor(self, &zoom);
        if (hr != S_OK) return error.WebView2Error;
        return zoom;
    }

    pub fn putZoomFactor(self: *const ICoreWebView2Controller, zoom: f64) !void {
        const hr = self.vtable.put_ZoomFactor(self, zoom);
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn moveFocus(self: *const ICoreWebView2Controller, reason: COREWEBVIEW2_MOVE_FOCUS_REASON) !void {
        const hr = self.vtable.MoveFocus(self, reason);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// `handler` must be a pointer to an instance of
    /// `FocusChangedEventHandler(Ctx)`.
    pub fn addGotFocus(self: *const ICoreWebView2Controller, handler: anytype) !EventRegistrationToken {
        var token: EventRegistrationToken = .{};
        const hr = self.vtable.add_GotFocus(self, @ptrCast(handler), &token);
        if (hr != S_OK) return error.WebView2Error;
        return token;
    }

    pub fn removeGotFocus(self: *const ICoreWebView2Controller, token: EventRegistrationToken) !void {
        const hr = self.vtable.remove_GotFocus(self, token);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// `handler` must be a pointer to an instance of
    /// `AcceleratorKeyPressedEventHandler(Ctx)`.
    pub fn addAcceleratorKeyPressed(self: *const ICoreWebView2Controller, handler: anytype) !EventRegistrationToken {
        var token: EventRegistrationToken = .{};
        const hr = self.vtable.add_AcceleratorKeyPressed(self, @ptrCast(handler), &token);
        if (hr != S_OK) return error.WebView2Error;
        return token;
    }

    pub fn removeAcceleratorKeyPressed(self: *const ICoreWebView2Controller, token: EventRegistrationToken) !void {
        const hr = self.vtable.remove_AcceleratorKeyPressed(self, token);
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn notifyParentWindowPositionChanged(self: *const ICoreWebView2Controller) !void {
        const hr = self.vtable.NotifyParentWindowPositionChanged(self);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// Close the controller and release its browser resources. Must be
    /// called before the final Release for prompt cleanup.
    pub fn close(self: *const ICoreWebView2Controller) !void {
        const hr = self.vtable.Close(self);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// Returns the ICoreWebView2. Caller owns a reference (release it).
    pub fn getCoreWebView2(self: *const ICoreWebView2Controller) !*ICoreWebView2 {
        var webview: ?*ICoreWebView2 = null;
        const hr = self.vtable.get_CoreWebView2(self, &webview);
        if (hr != S_OK) return error.WebView2Error;
        return webview orelse error.WebView2Error;
    }
};

// ─── ICoreWebView2 ──────────────────────────────────────────────────────
// Inherits IUnknown. 58 own methods, indices 3-60, IDL order verified
// against WebView2.h.

pub const ICoreWebView2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2) callconv(.winapi) u32,
        // Index 3: get_Settings (padding)
        _pad3: PadFn,
        // Index 4: get_Source(LPWSTR*)
        get_Source: *const fn (*const ICoreWebView2, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: Navigate(LPCWSTR)
        Navigate: *const fn (*const ICoreWebView2, LPCWSTR) callconv(.winapi) HRESULT,
        // Index 6: NavigateToString (padding)
        _pad6: PadFn,
        // Index 7: add_NavigationStarting (padding)
        _pad7: PadFn,
        // Index 8: remove_NavigationStarting (padding)
        _pad8: PadFn,
        // Index 9: add_ContentLoading (padding)
        _pad9: PadFn,
        // Index 10: remove_ContentLoading (padding)
        _pad10: PadFn,
        // Index 11: add_SourceChanged (padding)
        _pad11: PadFn,
        // Index 12: remove_SourceChanged (padding)
        _pad12: PadFn,
        // Index 13: add_HistoryChanged (padding)
        _pad13: PadFn,
        // Index 14: remove_HistoryChanged (padding)
        _pad14: PadFn,
        // Index 15: add_NavigationCompleted(ICoreWebView2NavigationCompletedEventHandler*, EventRegistrationToken*)
        add_NavigationCompleted: *const fn (*const ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 16: remove_NavigationCompleted(EventRegistrationToken)
        remove_NavigationCompleted: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 17: add_FrameNavigationStarting (padding)
        _pad17: PadFn,
        // Index 18: remove_FrameNavigationStarting (padding)
        _pad18: PadFn,
        // Index 19: add_FrameNavigationCompleted (padding)
        _pad19: PadFn,
        // Index 20: remove_FrameNavigationCompleted (padding)
        _pad20: PadFn,
        // Index 21: add_ScriptDialogOpening (padding)
        _pad21: PadFn,
        // Index 22: remove_ScriptDialogOpening (padding)
        _pad22: PadFn,
        // Index 23: add_PermissionRequested (padding)
        _pad23: PadFn,
        // Index 24: remove_PermissionRequested (padding)
        _pad24: PadFn,
        // Index 25: add_ProcessFailed (padding)
        _pad25: PadFn,
        // Index 26: remove_ProcessFailed (padding)
        _pad26: PadFn,
        // Index 27: AddScriptToExecuteOnDocumentCreated (padding)
        _pad27: PadFn,
        // Index 28: RemoveScriptToExecuteOnDocumentCreated (padding)
        _pad28: PadFn,
        // Index 29: ExecuteScript(LPCWSTR, ICoreWebView2ExecuteScriptCompletedHandler*)
        ExecuteScript: *const fn (*const ICoreWebView2, LPCWSTR, *anyopaque) callconv(.winapi) HRESULT,
        // Index 30: CapturePreview (padding)
        _pad30: PadFn,
        // Index 31: Reload()
        Reload: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 32: PostWebMessageAsJson (padding)
        _pad32: PadFn,
        // Index 33: PostWebMessageAsString (padding)
        _pad33: PadFn,
        // Index 34: add_WebMessageReceived (padding)
        _pad34: PadFn,
        // Index 35: remove_WebMessageReceived (padding)
        _pad35: PadFn,
        // Index 36: CallDevToolsProtocolMethod(LPCWSTR, LPCWSTR, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler*)
        CallDevToolsProtocolMethod: *const fn (*const ICoreWebView2, LPCWSTR, LPCWSTR, *anyopaque) callconv(.winapi) HRESULT,
        // Index 37: get_BrowserProcessId (padding)
        _pad37: PadFn,
        // Index 38: get_CanGoBack (padding)
        _pad38: PadFn,
        // Index 39: get_CanGoForward (padding)
        _pad39: PadFn,
        // Index 40: GoBack()
        GoBack: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 41: GoForward()
        GoForward: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 42: GetDevToolsProtocolEventReceiver(LPCWSTR, ICoreWebView2DevToolsProtocolEventReceiver**)
        GetDevToolsProtocolEventReceiver: *const fn (*const ICoreWebView2, LPCWSTR, *?*ICoreWebView2DevToolsProtocolEventReceiver) callconv(.winapi) HRESULT,
        // Index 43: Stop()
        Stop: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 44: add_NewWindowRequested (padding)
        _pad44: PadFn,
        // Index 45: remove_NewWindowRequested (padding)
        _pad45: PadFn,
        // Index 46: add_DocumentTitleChanged(ICoreWebView2DocumentTitleChangedEventHandler*, EventRegistrationToken*)
        add_DocumentTitleChanged: *const fn (*const ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 47: remove_DocumentTitleChanged(EventRegistrationToken)
        remove_DocumentTitleChanged: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 48: get_DocumentTitle(LPWSTR*)
        get_DocumentTitle: *const fn (*const ICoreWebView2, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 49: AddHostObjectToScript (padding)
        _pad49: PadFn,
        // Index 50: RemoveHostObjectFromScript (padding)
        _pad50: PadFn,
        // Index 51: OpenDevToolsWindow (padding)
        _pad51: PadFn,
        // Index 52: add_ContainsFullScreenElementChanged (padding)
        _pad52: PadFn,
        // Index 53: remove_ContainsFullScreenElementChanged (padding)
        _pad53: PadFn,
        // Index 54: get_ContainsFullScreenElement (padding)
        _pad54: PadFn,
        // Index 55: add_WebResourceRequested (padding)
        _pad55: PadFn,
        // Index 56: remove_WebResourceRequested (padding)
        _pad56: PadFn,
        // Index 57: AddWebResourceRequestedFilter (padding)
        _pad57: PadFn,
        // Index 58: RemoveWebResourceRequestedFilter (padding)
        _pad58: PadFn,
        // Index 59: add_WindowCloseRequested (padding)
        _pad59: PadFn,
        // Index 60: remove_WindowCloseRequested (padding)
        _pad60: PadFn,
    };

    pub fn addRef(self: *ICoreWebView2) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2) void {
        _ = self.vtable.Release(self);
    }

    /// Returns the current source URI. Caller frees with CoTaskMemFree.
    pub fn getSource(self: *const ICoreWebView2) !LPWSTR {
        var uri: ?LPWSTR = null;
        const hr = self.vtable.get_Source(self, &uri);
        if (hr != S_OK) return error.WebView2Error;
        return uri orelse error.WebView2Error;
    }

    pub fn navigate(self: *const ICoreWebView2, uri: LPCWSTR) !void {
        const hr = self.vtable.Navigate(self, uri);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// `handler` must be a pointer to an instance of
    /// `NavigationCompletedEventHandler(Ctx)`.
    pub fn addNavigationCompleted(self: *const ICoreWebView2, handler: anytype) !EventRegistrationToken {
        var token: EventRegistrationToken = .{};
        const hr = self.vtable.add_NavigationCompleted(self, @ptrCast(handler), &token);
        if (hr != S_OK) return error.WebView2Error;
        return token;
    }

    pub fn removeNavigationCompleted(self: *const ICoreWebView2, token: EventRegistrationToken) !void {
        const hr = self.vtable.remove_NavigationCompleted(self, token);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// `handler` must be a pointer to an instance of
    /// `ExecuteScriptCompletedHandler(Ctx)`. The result delivered to the
    /// handler is the JSON-encoded result of the script.
    pub fn executeScript(self: *const ICoreWebView2, javascript: LPCWSTR, handler: anytype) !void {
        const hr = self.vtable.ExecuteScript(self, javascript, @ptrCast(handler));
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn reload(self: *const ICoreWebView2) !void {
        const hr = self.vtable.Reload(self);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// `handler` must be a pointer to an instance of
    /// `CallDevToolsProtocolMethodCompletedHandler(Ctx)`.
    pub fn callDevToolsProtocolMethod(
        self: *const ICoreWebView2,
        method_name: LPCWSTR,
        parameters_as_json: LPCWSTR,
        handler: anytype,
    ) !void {
        const hr = self.vtable.CallDevToolsProtocolMethod(
            self,
            method_name,
            parameters_as_json,
            @ptrCast(handler),
        );
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn goBack(self: *const ICoreWebView2) !void {
        const hr = self.vtable.GoBack(self);
        if (hr != S_OK) return error.WebView2Error;
    }

    pub fn goForward(self: *const ICoreWebView2) !void {
        const hr = self.vtable.GoForward(self);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// Returns the receiver for a CDP event (e.g. "Log.entryAdded"). Caller
    /// owns a reference (release it).
    pub fn getDevToolsProtocolEventReceiver(
        self: *const ICoreWebView2,
        event_name: LPCWSTR,
    ) !*ICoreWebView2DevToolsProtocolEventReceiver {
        var receiver: ?*ICoreWebView2DevToolsProtocolEventReceiver = null;
        const hr = self.vtable.GetDevToolsProtocolEventReceiver(self, event_name, &receiver);
        if (hr != S_OK) return error.WebView2Error;
        return receiver orelse error.WebView2Error;
    }

    pub fn stop(self: *const ICoreWebView2) !void {
        const hr = self.vtable.Stop(self);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// `handler` must be a pointer to an instance of
    /// `DocumentTitleChangedEventHandler(Ctx)`.
    pub fn addDocumentTitleChanged(self: *const ICoreWebView2, handler: anytype) !EventRegistrationToken {
        var token: EventRegistrationToken = .{};
        const hr = self.vtable.add_DocumentTitleChanged(self, @ptrCast(handler), &token);
        if (hr != S_OK) return error.WebView2Error;
        return token;
    }

    pub fn removeDocumentTitleChanged(self: *const ICoreWebView2, token: EventRegistrationToken) !void {
        const hr = self.vtable.remove_DocumentTitleChanged(self, token);
        if (hr != S_OK) return error.WebView2Error;
    }

    /// Returns the document title. Caller frees with CoTaskMemFree.
    pub fn getDocumentTitle(self: *const ICoreWebView2) !LPWSTR {
        var title: ?LPWSTR = null;
        const hr = self.vtable.get_DocumentTitle(self, &title);
        if (hr != S_OK) return error.WebView2Error;
        return title orelse error.WebView2Error;
    }
};

// ─── ICoreWebView2NavigationCompletedEventArgs ──────────────────────────
// Inherits IUnknown. IDL order: get_IsSuccess, get_WebErrorStatus,
// get_NavigationId.

pub const ICoreWebView2NavigationCompletedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) u32,
        // Index 3: get_IsSuccess(BOOL*)
        get_IsSuccess: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 4: get_WebErrorStatus(COREWEBVIEW2_WEB_ERROR_STATUS*)
        get_WebErrorStatus: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *COREWEBVIEW2_WEB_ERROR_STATUS) callconv(.winapi) HRESULT,
        // Index 5: get_NavigationId (padding)
        _pad5: PadFn,
    };

    pub fn getIsSuccess(self: *const ICoreWebView2NavigationCompletedEventArgs) !bool {
        var success: BOOL = FALSE;
        const hr = self.vtable.get_IsSuccess(self, &success);
        if (hr != S_OK) return error.WebView2Error;
        return success != FALSE;
    }

    pub fn getWebErrorStatus(self: *const ICoreWebView2NavigationCompletedEventArgs) !COREWEBVIEW2_WEB_ERROR_STATUS {
        var status: COREWEBVIEW2_WEB_ERROR_STATUS = 0;
        const hr = self.vtable.get_WebErrorStatus(self, &status);
        if (hr != S_OK) return error.WebView2Error;
        return status;
    }
};

// ─── ICoreWebView2AcceleratorKeyPressedEventArgs ────────────────────────
// Inherits IUnknown. IDL order: get_KeyEventKind, get_VirtualKey,
// get_KeyEventLParam, get_PhysicalKeyStatus, get_Handled, put_Handled.

pub const ICoreWebView2AcceleratorKeyPressedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.winapi) u32,
        // Index 3: get_KeyEventKind(COREWEBVIEW2_KEY_EVENT_KIND*)
        get_KeyEventKind: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, *COREWEBVIEW2_KEY_EVENT_KIND) callconv(.winapi) HRESULT,
        // Index 4: get_VirtualKey(UINT*)
        get_VirtualKey: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, *u32) callconv(.winapi) HRESULT,
        // Index 5: get_KeyEventLParam(INT*)
        get_KeyEventLParam: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, *i32) callconv(.winapi) HRESULT,
        // Index 6: get_PhysicalKeyStatus(COREWEBVIEW2_PHYSICAL_KEY_STATUS*)
        get_PhysicalKeyStatus: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, *COREWEBVIEW2_PHYSICAL_KEY_STATUS) callconv(.winapi) HRESULT,
        // Index 7: get_Handled(BOOL*)
        get_Handled: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 8: put_Handled(BOOL)
        put_Handled: *const fn (*const ICoreWebView2AcceleratorKeyPressedEventArgs, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn getKeyEventKind(self: *const ICoreWebView2AcceleratorKeyPressedEventArgs) !COREWEBVIEW2_KEY_EVENT_KIND {
        var kind: COREWEBVIEW2_KEY_EVENT_KIND = .key_down;
        const hr = self.vtable.get_KeyEventKind(self, &kind);
        if (hr != S_OK) return error.WebView2Error;
        return kind;
    }

    pub fn getVirtualKey(self: *const ICoreWebView2AcceleratorKeyPressedEventArgs) !u32 {
        var vk: u32 = 0;
        const hr = self.vtable.get_VirtualKey(self, &vk);
        if (hr != S_OK) return error.WebView2Error;
        return vk;
    }

    pub fn getKeyEventLParam(self: *const ICoreWebView2AcceleratorKeyPressedEventArgs) !i32 {
        var lparam: i32 = 0;
        const hr = self.vtable.get_KeyEventLParam(self, &lparam);
        if (hr != S_OK) return error.WebView2Error;
        return lparam;
    }

    pub fn getPhysicalKeyStatus(self: *const ICoreWebView2AcceleratorKeyPressedEventArgs) !COREWEBVIEW2_PHYSICAL_KEY_STATUS {
        var status: COREWEBVIEW2_PHYSICAL_KEY_STATUS = std.mem.zeroes(COREWEBVIEW2_PHYSICAL_KEY_STATUS);
        const hr = self.vtable.get_PhysicalKeyStatus(self, &status);
        if (hr != S_OK) return error.WebView2Error;
        return status;
    }

    pub fn getHandled(self: *const ICoreWebView2AcceleratorKeyPressedEventArgs) !bool {
        var handled: BOOL = FALSE;
        const hr = self.vtable.get_Handled(self, &handled);
        if (hr != S_OK) return error.WebView2Error;
        return handled != FALSE;
    }

    pub fn putHandled(self: *const ICoreWebView2AcceleratorKeyPressedEventArgs, handled: bool) !void {
        const hr = self.vtable.put_Handled(self, if (handled) TRUE else FALSE);
        if (hr != S_OK) return error.WebView2Error;
    }
};

// ─── ICoreWebView2DevToolsProtocolEventReceiver ─────────────────────────
// Inherits IUnknown. IDL order: add_DevToolsProtocolEventReceived,
// remove_DevToolsProtocolEventReceived.

pub const ICoreWebView2DevToolsProtocolEventReceiver = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2DevToolsProtocolEventReceiver, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2DevToolsProtocolEventReceiver) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2DevToolsProtocolEventReceiver) callconv(.winapi) u32,
        // Index 3: add_DevToolsProtocolEventReceived(ICoreWebView2DevToolsProtocolEventReceivedEventHandler*, EventRegistrationToken*)
        add_DevToolsProtocolEventReceived: *const fn (*const ICoreWebView2DevToolsProtocolEventReceiver, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 4: remove_DevToolsProtocolEventReceived(EventRegistrationToken)
        remove_DevToolsProtocolEventReceived: *const fn (*const ICoreWebView2DevToolsProtocolEventReceiver, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2DevToolsProtocolEventReceiver) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2DevToolsProtocolEventReceiver) void {
        _ = self.vtable.Release(self);
    }

    /// `handler` must be a pointer to an instance of
    /// `DevToolsProtocolEventReceivedEventHandler(Ctx)`.
    pub fn addDevToolsProtocolEventReceived(
        self: *const ICoreWebView2DevToolsProtocolEventReceiver,
        handler: anytype,
    ) !EventRegistrationToken {
        var token: EventRegistrationToken = .{};
        const hr = self.vtable.add_DevToolsProtocolEventReceived(self, @ptrCast(handler), &token);
        if (hr != S_OK) return error.WebView2Error;
        return token;
    }

    pub fn removeDevToolsProtocolEventReceived(
        self: *const ICoreWebView2DevToolsProtocolEventReceiver,
        token: EventRegistrationToken,
    ) !void {
        const hr = self.vtable.remove_DevToolsProtocolEventReceived(self, token);
        if (hr != S_OK) return error.WebView2Error;
    }
};

// ─── ICoreWebView2DevToolsProtocolEventReceivedEventArgs ────────────────
// Inherits IUnknown. IDL order: get_ParameterObjectAsJson.

pub const ICoreWebView2DevToolsProtocolEventReceivedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2DevToolsProtocolEventReceivedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2DevToolsProtocolEventReceivedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2DevToolsProtocolEventReceivedEventArgs) callconv(.winapi) u32,
        // Index 3: get_ParameterObjectAsJson(LPWSTR*)
        get_ParameterObjectAsJson: *const fn (*const ICoreWebView2DevToolsProtocolEventReceivedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
    };

    /// Returns the event parameters as JSON. Caller frees with
    /// CoTaskMemFree.
    pub fn getParameterObjectAsJson(self: *const ICoreWebView2DevToolsProtocolEventReceivedEventArgs) !LPWSTR {
        var json: ?LPWSTR = null;
        const hr = self.vtable.get_ParameterObjectAsJson(self, &json);
        if (hr != S_OK) return error.WebView2Error;
        return json orelse error.WebView2Error;
    }
};

// ─── Handler factory ────────────────────────────────────────────────────
// Every WebView2 callback interface is IUnknown + a single Invoke method
// taking exactly two arguments, so one comptime factory covers all of them.

/// Produce a COM-callable handler object type implementing the callback
/// interface identified by `iid` whose Invoke takes `(Arg0, Arg1)`. The
/// object holds a `*Ctx` and a user callback `fn (*Ctx, Arg0, Arg1) void`,
/// has an atomic refcount, and destroys itself through the creating
/// allocator when the count reaches zero.
///
/// Because `vtable` is the first field of this extern struct, the COM
/// interface pointer is bit-identical to `*Self` (the @fieldParentPtr of
/// the vtable slot is the object itself), so the vtable impls take *Self
/// directly with no pointer adjustment.
pub fn Handler(
    comptime iid: GUID,
    comptime Ctx: type,
    comptime Arg0: type,
    comptime Arg1: type,
) type {
    return extern struct {
        const Self = @This();

        /// User callback type. Runs on the UI (STA) thread that pumped the
        /// message that triggered the event.
        pub const Callback = *const fn (ctx: *Ctx, arg0: Arg0, arg1: Arg1) void;

        pub const VTable = extern struct {
            // Index 0
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            // Index 1
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            // Index 2
            Release: *const fn (*Self) callconv(.winapi) u32,
            // Index 3
            Invoke: *const fn (*Self, Arg0, Arg1) callconv(.winapi) HRESULT,
        };

        vtable: *const VTable,
        ref_count: u32,
        ctx: *Ctx,
        /// Type-erased `Callback` (extern structs cannot hold Zig-callconv
        /// function pointers directly).
        callback: *const anyopaque,
        /// Type-erased std.mem.Allocator used to create (and destroy) this
        /// object.
        alloc_ptr: *anyopaque,
        alloc_vtable: *const anyopaque,

        const vtable_impl: VTable = .{
            .QueryInterface = implQueryInterface,
            .AddRef = implAddRef,
            .Release = implRelease,
            .Invoke = implInvoke,
        };

        /// Create a handler with refcount 1. Hand it to a WebView2 add_*/
        /// async method (which AddRefs it for as long as it needs it), then
        /// call `unref()` to drop your reference.
        pub fn create(alloc: std.mem.Allocator, ctx: *Ctx, callback: Callback) !*Self {
            const self = try alloc.create(Self);
            self.* = .{
                .vtable = &vtable_impl,
                .ref_count = 1,
                .ctx = ctx,
                .callback = @ptrCast(callback),
                .alloc_ptr = alloc.ptr,
                .alloc_vtable = @ptrCast(alloc.vtable),
            };
            return self;
        }

        /// Drop the creating reference (calls COM Release).
        pub fn unref(self: *Self) void {
            _ = implRelease(self);
        }

        fn allocator(self: *const Self) std.mem.Allocator {
            return .{
                .ptr = self.alloc_ptr,
                .vtable = @ptrCast(@alignCast(self.alloc_vtable)),
            };
        }

        fn implQueryInterface(self: *Self, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (guidEql(riid, &iid) or guidEql(riid, &IID_IUnknown)) {
                _ = implAddRef(self);
                out.* = self;
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }

        fn implAddRef(self: *Self) callconv(.winapi) u32 {
            return @atomicRmw(u32, &self.ref_count, .Add, 1, .monotonic) + 1;
        }

        fn implRelease(self: *Self) callconv(.winapi) u32 {
            const prev = @atomicRmw(u32, &self.ref_count, .Sub, 1, .acq_rel);
            if (prev == 1) {
                self.allocator().destroy(self);
                return 0;
            }
            return prev - 1;
        }

        fn implInvoke(self: *Self, arg0: Arg0, arg1: Arg1) callconv(.winapi) HRESULT {
            const cb: Callback = @ptrCast(@alignCast(self.callback));
            cb(self.ctx, arg0, arg1);
            return S_OK;
        }
    };
}

// ─── Handler instantiations ─────────────────────────────────────────────
// One per WebView2 callback interface we implement; each remains generic
// over the user context type. Invoke argument order/types verified against
// WebView2.h. Interface-pointer arguments are optional because failure
// completions deliver null (with the HRESULT carrying the error).

/// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler:
/// Invoke(HRESULT errorCode, ICoreWebView2Environment* result)
pub fn EnvironmentCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
        Ctx,
        HRESULT,
        ?*ICoreWebView2Environment,
    );
}

/// ICoreWebView2CreateCoreWebView2ControllerCompletedHandler:
/// Invoke(HRESULT errorCode, ICoreWebView2Controller* result)
pub fn ControllerCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
        Ctx,
        HRESULT,
        ?*ICoreWebView2Controller,
    );
}

/// ICoreWebView2NavigationCompletedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args)
pub fn NavigationCompletedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2NavigationCompletedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2NavigationCompletedEventArgs,
    );
}

/// ICoreWebView2DocumentTitleChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args) — args is always null.
pub fn DocumentTitleChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2DocumentTitleChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2ExecuteScriptCompletedHandler:
/// Invoke(HRESULT errorCode, LPCWSTR resultObjectAsJson)
pub fn ExecuteScriptCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ExecuteScriptCompletedHandler,
        Ctx,
        HRESULT,
        ?LPCWSTR,
    );
}

/// ICoreWebView2CallDevToolsProtocolMethodCompletedHandler:
/// Invoke(HRESULT errorCode, LPCWSTR returnObjectAsJson)
pub fn CallDevToolsProtocolMethodCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
        Ctx,
        HRESULT,
        ?LPCWSTR,
    );
}

/// ICoreWebView2AcceleratorKeyPressedEventHandler:
/// Invoke(ICoreWebView2Controller* sender, ICoreWebView2AcceleratorKeyPressedEventArgs* args)
pub fn AcceleratorKeyPressedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2AcceleratorKeyPressedEventHandler,
        Ctx,
        ?*ICoreWebView2Controller,
        ?*ICoreWebView2AcceleratorKeyPressedEventArgs,
    );
}

/// ICoreWebView2FocusChangedEventHandler (used for both GotFocus and
/// LostFocus): Invoke(ICoreWebView2Controller* sender, IUnknown* args) —
/// args is always null.
pub fn FocusChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2FocusChangedEventHandler,
        Ctx,
        ?*ICoreWebView2Controller,
        ?*IUnknown,
    );
}

/// ICoreWebView2DevToolsProtocolEventReceivedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args)
pub fn DevToolsProtocolEventReceivedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2DevToolsProtocolEventReceivedEventArgs,
    );
}
