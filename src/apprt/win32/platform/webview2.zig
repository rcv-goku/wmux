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
/// SDK: Microsoft.Web.WebView2 NuGet package 1.0.4258.31 (WebView2.h).
/// Every IID, parent and slot order below is checked at comptime against
/// the fixture table parsed from that header (`logic/webview2_iids.zig`):
/// see `verifyBindings` at the end of this file. Interfaces that extend
/// another one (ICoreWebView2_2 : ICoreWebView2, ...) embed the parent
/// vtable as their first field `base`, so inherited slots come first and
/// own slots keep the header's indices; `asBase()` views the object as its
/// parent to call inherited methods.
///
/// Completed once by W1-6b (ADR-6.10) and frozen afterwards: later needs
/// go through a CCR. Interface pointers of types this file does not bind
/// are `?*anyopaque` (the slot comment names the C type).
///
/// COM rules for callers:
/// - Pointers returned through out-params (get_*, qi) are owned: release
///   them.
/// - Pointers passed into a callback (sender, args) are borrowed for the
///   duration of the callback. AddRef (`retain`) any borrowed interface
///   that outlives the callback, and release it later.
/// - `qi(T, obj)` returns an owned `*T` or null when the runtime does not
///   implement T (older runtime: newer ICoreWebView2_N are optional).
///
/// This file is self-contained: it only depends on `std.os.windows` types,
/// kernel32/ole32 imports declared locally and the std-only sibling
/// `logic/webview2_iids.zig`, so it can be compiled standalone without the
/// repo build graph.
///
/// WebView2 is loaded dynamically through WebView2Loader.dll which must be
/// shipped next to the executable; the WebView2 *runtime* (Evergreen) is
/// expected to be installed system-wide (it ships with Windows 11).
const std = @import("std");
const windows = std.os.windows;
const builtin = @import("builtin");
const iids = @import("logic/webview2_iids.zig");

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
pub const POINT = windows.POINT;
pub const HANDLE = windows.HANDLE;

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

// Implemented (callback handler) interfaces bound by W1-6b; one Handler
// factory per IID at the end of this file.
pub const IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler = GUID.parse("{b99369f3-9b11-47b5-bc6f-8e7895fcea17}");
pub const IID_ICoreWebView2BasicAuthenticationRequestedEventHandler = GUID.parse("{58b4d6c2-18d4-497e-b39b-9a96533fa278}");
pub const IID_ICoreWebView2BrowserProcessExitedEventHandler = GUID.parse("{fa504257-a216-4911-a860-fe8825712861}");
pub const IID_ICoreWebView2BytesReceivedChangedEventHandler = GUID.parse("{828e8ab6-d94c-4264-9cef-5217170d6251}");
pub const IID_ICoreWebView2CapturePreviewCompletedHandler = GUID.parse("{697e05e9-3d8f-45fa-96f4-8ffe1ededaf5}");
pub const IID_ICoreWebView2ClearServerCertificateErrorActionsCompletedHandler = GUID.parse("{3b40aac6-acfe-4ffd-8211-f607b96e2d5b}");
pub const IID_ICoreWebView2ClientCertificateRequestedEventHandler = GUID.parse("{d7175ba2-bcc3-11eb-8529-0242ac130003}");
pub const IID_ICoreWebView2ContainsFullScreenElementChangedEventHandler = GUID.parse("{e45d98b1-afef-45be-8baf-6c7728867f73}");
pub const IID_ICoreWebView2ContentLoadingEventHandler = GUID.parse("{364471e7-f2be-4910-bdba-d72077d51c4b}");
pub const IID_ICoreWebView2ContextMenuRequestedEventHandler = GUID.parse("{04d3fe1d-ab87-42fb-a898-da241d35b63c}");
pub const IID_ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler = GUID.parse("{02fab84b-1428-4fb7-ad45-1b2e64736184}");
pub const IID_ICoreWebView2CustomItemSelectedEventHandler = GUID.parse("{49e1d0bc-fe9e-4481-b7c2-32324aa21998}");
pub const IID_ICoreWebView2DOMContentLoadedEventHandler = GUID.parse("{4bac7e9c-199e-49ed-87ed-249303acf019}");
pub const IID_ICoreWebView2DownloadStartingEventHandler = GUID.parse("{efedc989-c396-41ca-83f7-07f845a55724}");
pub const IID_ICoreWebView2EstimatedEndTimeChangedEventHandler = GUID.parse("{28f0d425-93fe-4e63-9f8d-2aeec6d3ba1e}");
pub const IID_ICoreWebView2FaviconChangedEventHandler = GUID.parse("{2913da94-833d-4de0-8dca-900fc524a1a4}");
pub const IID_ICoreWebView2FrameCreatedEventHandler = GUID.parse("{38059770-9baa-11eb-a8b3-0242ac130003}");
pub const IID_ICoreWebView2FrameDestroyedEventHandler = GUID.parse("{59dd7b4c-9baa-11eb-a8b3-0242ac130003}");
pub const IID_ICoreWebView2FrameNameChangedEventHandler = GUID.parse("{435c7dc8-9baa-11eb-a8b3-0242ac130003}");
pub const IID_ICoreWebView2GetCookiesCompletedHandler = GUID.parse("{5a4f5069-5c15-47c3-8646-f4de1c116670}");
pub const IID_ICoreWebView2GetFaviconCompletedHandler = GUID.parse("{a2508329-7da8-49d7-8c05-fa125e4aee8d}");
pub const IID_ICoreWebView2HistoryChangedEventHandler = GUID.parse("{c79a420c-efd9-4058-9295-3e8b4bcab645}");
pub const IID_ICoreWebView2IsDefaultDownloadDialogOpenChangedEventHandler = GUID.parse("{3117da26-ae13-438d-bd46-edbeb2c4ce81}");
pub const IID_ICoreWebView2IsDocumentPlayingAudioChangedEventHandler = GUID.parse("{5def109a-2f4b-49fa-b7f6-11c39e513328}");
pub const IID_ICoreWebView2IsMutedChangedEventHandler = GUID.parse("{57d90347-cd0e-4952-a4a2-7483a2756f08}");
pub const IID_ICoreWebView2MoveFocusRequestedEventHandler = GUID.parse("{69035451-6dc7-4cb8-9bce-b2bd70ad289f}");
pub const IID_ICoreWebView2NavigationStartingEventHandler = GUID.parse("{9adbe429-f36d-432b-9ddc-f8881fbd76e3}");
pub const IID_ICoreWebView2NewBrowserVersionAvailableEventHandler = GUID.parse("{f9a2976e-d34e-44fc-adee-81b6b57ca914}");
pub const IID_ICoreWebView2NewWindowRequestedEventHandler = GUID.parse("{d4c185fe-c81c-4989-97af-2d3fa7ab5651}");
pub const IID_ICoreWebView2PermissionRequestedEventHandler = GUID.parse("{15e1c6a3-c72a-4df3-91d7-d097fbec6bfd}");
pub const IID_ICoreWebView2PrintCompletedHandler = GUID.parse("{8fd80075-ed08-42db-8570-f5d14977461e}");
pub const IID_ICoreWebView2PrintToPdfCompletedHandler = GUID.parse("{ccf1ef04-fd8e-4d5f-b2de-0983e41b8c36}");
pub const IID_ICoreWebView2PrintToPdfStreamCompletedHandler = GUID.parse("{4c9f8229-8f93-444f-a711-2c0dfd6359d5}");
pub const IID_ICoreWebView2ProcessFailedEventHandler = GUID.parse("{79e0aea4-990b-42d9-aa1d-0fcc2e5bc7f1}");
pub const IID_ICoreWebView2ProcessInfosChangedEventHandler = GUID.parse("{f4af0c39-44b9-40e9-8b11-0484cfb9e0a1}");
pub const IID_ICoreWebView2RasterizationScaleChangedEventHandler = GUID.parse("{9c98c8b1-ac53-427e-a345-3049b5524bbe}");
pub const IID_ICoreWebView2ScriptDialogOpeningEventHandler = GUID.parse("{ef381bf9-afa8-4e37-91c4-8ac48524bdfb}");
pub const IID_ICoreWebView2ServerCertificateErrorDetectedEventHandler = GUID.parse("{969b3a26-d85e-4795-8199-fef57344da22}");
pub const IID_ICoreWebView2SourceChangedEventHandler = GUID.parse("{3c067f9f-5388-4772-8b48-79f7ef1ab37c}");
pub const IID_ICoreWebView2StateChangedEventHandler = GUID.parse("{81336594-7ede-4ba9-bf71-acf0a95b58dd}");
pub const IID_ICoreWebView2StatusBarTextChangedEventHandler = GUID.parse("{a5e3b0d0-10df-4156-bfad-3b43867acac6}");
pub const IID_ICoreWebView2TrySuspendCompletedHandler = GUID.parse("{00f206a7-9d17-4605-91f6-4e8e4de192e3}");
pub const IID_ICoreWebView2WebMessageReceivedEventHandler = GUID.parse("{57213f19-00e6-49fa-8e07-898ea01ecbd2}");
pub const IID_ICoreWebView2WebResourceRequestedEventHandler = GUID.parse("{ab00b74c-15f1-4646-80e8-e76341d25d71}");
pub const IID_ICoreWebView2WebResourceResponseReceivedEventHandler = GUID.parse("{7de9898a-24f5-40c3-a2de-d4f458e69828}");
pub const IID_ICoreWebView2WindowCloseRequestedEventHandler = GUID.parse("{5c19e9e0-092f-486b-affa-ca8231913039}");
pub const IID_ICoreWebView2ZoomFactorChangedEventHandler = GUID.parse("{b52d71d6-c4df-4543-a90c-64a3e60f38cb}");

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

pub const COREWEBVIEW2_COLOR = extern struct {
    A: u8,
    R: u8,
    G: u8,
    B: u8,
};

pub const COREWEBVIEW2_PHYSICAL_KEY_STATUS = extern struct {
    RepeatCount: u32,
    ScanCode: u32,
    IsExtendedKey: BOOL,
    IsMenuKeyDown: BOOL,
    WasKeyDown: BOOL,
    IsKeyReleased: BOOL,
};

/// COREWEBVIEW2_* enums used by the bound slots, passed through as their
/// raw 32-bit values (MIDL enums are `int`); see WebView2.h for the members.
pub const COREWEBVIEW2_BOUNDS_MODE = i32;
pub const COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND = i32;
pub const COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT = i32;
pub const COREWEBVIEW2_CLIENT_CERTIFICATE_KIND = i32;
pub const COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND = i32;
pub const COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND = i32;
pub const COREWEBVIEW2_COOKIE_SAME_SITE_KIND = i32;
pub const COREWEBVIEW2_DEFAULT_DOWNLOAD_DIALOG_CORNER_ALIGNMENT = i32;
pub const COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON = i32;
pub const COREWEBVIEW2_DOWNLOAD_STATE = i32;
pub const COREWEBVIEW2_FAVICON_IMAGE_FORMAT = i32;
pub const COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND = i32;
pub const COREWEBVIEW2_PDF_TOOLBAR_ITEMS = i32;
pub const COREWEBVIEW2_PERMISSION_KIND = i32;
pub const COREWEBVIEW2_PERMISSION_STATE = i32;
pub const COREWEBVIEW2_PREFERRED_COLOR_SCHEME = i32;
pub const COREWEBVIEW2_PRINT_DIALOG_KIND = i32;
pub const COREWEBVIEW2_PRINT_ORIENTATION = i32;
pub const COREWEBVIEW2_PRINT_STATUS = i32;
pub const COREWEBVIEW2_PROCESS_FAILED_KIND = i32;
pub const COREWEBVIEW2_PROCESS_KIND = i32;
pub const COREWEBVIEW2_SCRIPT_DIALOG_KIND = i32;
pub const COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION = i32;
pub const COREWEBVIEW2_WEB_RESOURCE_CONTEXT = i32;

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

    /// `createEnvironment` with an ICoreWebView2EnvironmentOptions (usually
    /// `EnvironmentOptions.interface()`; the loader AddRefs it as needed,
    /// so the caller may `unref()` its own reference right after).
    pub fn createEnvironmentWithOptions(
        self: *const Loader,
        browser_executable_folder: ?LPCWSTR,
        user_data_folder: ?LPCWSTR,
        options: ?*ICoreWebView2EnvironmentOptions,
        handler: anytype,
    ) !void {
        const hr = self.CreateCoreWebView2EnvironmentWithOptions(
            browser_executable_folder,
            user_data_folder,
            @ptrCast(options),
            @ptrCast(handler),
        );
        if (hr != S_OK) return error.WebView2Error;
    }

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

    pub const IID = IID_IUnknown;

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

// ─── Generic COM helpers ────────────────────────────────────────────────

/// AddRef through IUnknown (slot 1) for any bound interface pointer.
pub fn comAddRef(obj: anytype) void {
    const unk: *IUnknown = @ptrCast(@alignCast(obj));
    _ = unk.vtable.AddRef(unk);
}

/// Release through IUnknown (slot 2) for any bound interface pointer.
pub fn comRelease(obj: anytype) void {
    const unk: *IUnknown = @ptrCast(@alignCast(obj));
    _ = unk.vtable.Release(unk);
}

/// AddRef a borrowed interface (a callback's sender or args) that must
/// outlive the callback; returns it for `self.kept = retain(args)`.
pub fn retain(obj: anytype) @TypeOf(obj) {
    comAddRef(obj);
    return obj;
}

/// QueryInterface `obj` (any bound interface pointer) for `T` using
/// `T.IID`. Returns an owned reference (release it) or null when the
/// object does not implement T, e.g. `qi(ICoreWebView2_13, webview)` on a
/// runtime older than the Profile API.
pub fn qi(comptime T: type, obj: anytype) ?*T {
    const unk: *IUnknown = @ptrCast(@alignCast(obj));
    var out: ?*anyopaque = null;
    const hr = unk.vtable.QueryInterface(unk, &T.IID, &out);
    if (hr != S_OK) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

// ─── ICoreWebView2Environment ───────────────────────────────────────────
// Inherits IUnknown. IDL order: CreateCoreWebView2Controller,
// CreateWebResourceResponse, get_BrowserVersionString,
// add_NewBrowserVersionAvailable, remove_NewBrowserVersionAvailable.

pub const ICoreWebView2Environment = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ICoreWebView2Environment;

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Environment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Environment) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Environment) callconv(.winapi) u32,
        // Index 3: CreateCoreWebView2Controller(HWND, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*)
        CreateCoreWebView2Controller: *const fn (*const ICoreWebView2Environment, HWND, *anyopaque) callconv(.winapi) HRESULT,
        // Index 4: CreateWebResourceResponse(IStream*, int, LPCWSTR, LPCWSTR, ICoreWebView2WebResourceResponse**)
        CreateWebResourceResponse: *const fn (*const ICoreWebView2Environment, ?*anyopaque, i32, ?LPCWSTR, ?LPCWSTR, *?*ICoreWebView2WebResourceResponse) callconv(.winapi) HRESULT,
        // Index 5: get_BrowserVersionString(LPWSTR*)
        get_BrowserVersionString: *const fn (*const ICoreWebView2Environment, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: add_NewBrowserVersionAvailable(ICoreWebView2NewBrowserVersionAvailableEventHandler*, EventRegistrationToken*)
        add_NewBrowserVersionAvailable: *const fn (*const ICoreWebView2Environment, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 7: remove_NewBrowserVersionAvailable(EventRegistrationToken)
        remove_NewBrowserVersionAvailable: *const fn (*const ICoreWebView2Environment, EventRegistrationToken) callconv(.winapi) HRESULT,
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

    pub const IID = IID_ICoreWebView2Controller;

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
        // Index 9: add_ZoomFactorChanged(ICoreWebView2ZoomFactorChangedEventHandler*, EventRegistrationToken*)
        add_ZoomFactorChanged: *const fn (*const ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 10: remove_ZoomFactorChanged(EventRegistrationToken)
        remove_ZoomFactorChanged: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 11: SetBoundsAndZoomFactor(RECT, double)
        SetBoundsAndZoomFactor: *const fn (*const ICoreWebView2Controller, RECT, f64) callconv(.winapi) HRESULT,
        // Index 12: MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON)
        MoveFocus: *const fn (*const ICoreWebView2Controller, COREWEBVIEW2_MOVE_FOCUS_REASON) callconv(.winapi) HRESULT,
        // Index 13: add_MoveFocusRequested(ICoreWebView2MoveFocusRequestedEventHandler*, EventRegistrationToken*)
        add_MoveFocusRequested: *const fn (*const ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 14: remove_MoveFocusRequested(EventRegistrationToken)
        remove_MoveFocusRequested: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 15: add_GotFocus(ICoreWebView2FocusChangedEventHandler*, EventRegistrationToken*)
        add_GotFocus: *const fn (*const ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 16: remove_GotFocus(EventRegistrationToken)
        remove_GotFocus: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 17: add_LostFocus(ICoreWebView2FocusChangedEventHandler*, EventRegistrationToken*)
        add_LostFocus: *const fn (*const ICoreWebView2Controller, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 18: remove_LostFocus(EventRegistrationToken)
        remove_LostFocus: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 19: add_AcceleratorKeyPressed(ICoreWebView2AcceleratorKeyPressedEventHandler*, EventRegistrationToken*)
        add_AcceleratorKeyPressed: *const fn (*const ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 20: remove_AcceleratorKeyPressed(EventRegistrationToken)
        remove_AcceleratorKeyPressed: *const fn (*const ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 21: get_ParentWindow(HWND*)
        get_ParentWindow: *const fn (*const ICoreWebView2Controller, *?HWND) callconv(.winapi) HRESULT,
        // Index 22: put_ParentWindow(HWND)
        put_ParentWindow: *const fn (*const ICoreWebView2Controller, HWND) callconv(.winapi) HRESULT,
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

    pub const IID = IID_ICoreWebView2;

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2) callconv(.winapi) u32,
        // Index 3: get_Settings(ICoreWebView2Settings**)
        get_Settings: *const fn (*const ICoreWebView2, *?*ICoreWebView2Settings) callconv(.winapi) HRESULT,
        // Index 4: get_Source(LPWSTR*)
        get_Source: *const fn (*const ICoreWebView2, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: Navigate(LPCWSTR)
        Navigate: *const fn (*const ICoreWebView2, LPCWSTR) callconv(.winapi) HRESULT,
        // Index 6: NavigateToString(LPCWSTR)
        NavigateToString: *const fn (*const ICoreWebView2, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 7: add_NavigationStarting(ICoreWebView2NavigationStartingEventHandler*, EventRegistrationToken*)
        add_NavigationStarting: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 8: remove_NavigationStarting(EventRegistrationToken)
        remove_NavigationStarting: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 9: add_ContentLoading(ICoreWebView2ContentLoadingEventHandler*, EventRegistrationToken*)
        add_ContentLoading: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 10: remove_ContentLoading(EventRegistrationToken)
        remove_ContentLoading: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 11: add_SourceChanged(ICoreWebView2SourceChangedEventHandler*, EventRegistrationToken*)
        add_SourceChanged: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 12: remove_SourceChanged(EventRegistrationToken)
        remove_SourceChanged: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 13: add_HistoryChanged(ICoreWebView2HistoryChangedEventHandler*, EventRegistrationToken*)
        add_HistoryChanged: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 14: remove_HistoryChanged(EventRegistrationToken)
        remove_HistoryChanged: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 15: add_NavigationCompleted(ICoreWebView2NavigationCompletedEventHandler*, EventRegistrationToken*)
        add_NavigationCompleted: *const fn (*const ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 16: remove_NavigationCompleted(EventRegistrationToken)
        remove_NavigationCompleted: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 17: add_FrameNavigationStarting(ICoreWebView2NavigationStartingEventHandler*, EventRegistrationToken*)
        add_FrameNavigationStarting: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 18: remove_FrameNavigationStarting(EventRegistrationToken)
        remove_FrameNavigationStarting: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 19: add_FrameNavigationCompleted(ICoreWebView2NavigationCompletedEventHandler*, EventRegistrationToken*)
        add_FrameNavigationCompleted: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 20: remove_FrameNavigationCompleted(EventRegistrationToken)
        remove_FrameNavigationCompleted: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 21: add_ScriptDialogOpening(ICoreWebView2ScriptDialogOpeningEventHandler*, EventRegistrationToken*)
        add_ScriptDialogOpening: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 22: remove_ScriptDialogOpening(EventRegistrationToken)
        remove_ScriptDialogOpening: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 23: add_PermissionRequested(ICoreWebView2PermissionRequestedEventHandler*, EventRegistrationToken*)
        add_PermissionRequested: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 24: remove_PermissionRequested(EventRegistrationToken)
        remove_PermissionRequested: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 25: add_ProcessFailed(ICoreWebView2ProcessFailedEventHandler*, EventRegistrationToken*)
        add_ProcessFailed: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 26: remove_ProcessFailed(EventRegistrationToken)
        remove_ProcessFailed: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 27: AddScriptToExecuteOnDocumentCreated(LPCWSTR, ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler*)
        AddScriptToExecuteOnDocumentCreated: *const fn (*const ICoreWebView2, ?LPCWSTR, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 28: RemoveScriptToExecuteOnDocumentCreated(LPCWSTR)
        RemoveScriptToExecuteOnDocumentCreated: *const fn (*const ICoreWebView2, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 29: ExecuteScript(LPCWSTR, ICoreWebView2ExecuteScriptCompletedHandler*)
        ExecuteScript: *const fn (*const ICoreWebView2, LPCWSTR, *anyopaque) callconv(.winapi) HRESULT,
        // Index 30: CapturePreview(COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT, IStream*, ICoreWebView2CapturePreviewCompletedHandler*)
        CapturePreview: *const fn (*const ICoreWebView2, COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT, ?*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 31: Reload()
        Reload: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 32: PostWebMessageAsJson(LPCWSTR)
        PostWebMessageAsJson: *const fn (*const ICoreWebView2, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 33: PostWebMessageAsString(LPCWSTR)
        PostWebMessageAsString: *const fn (*const ICoreWebView2, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 34: add_WebMessageReceived(ICoreWebView2WebMessageReceivedEventHandler*, EventRegistrationToken*)
        add_WebMessageReceived: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 35: remove_WebMessageReceived(EventRegistrationToken)
        remove_WebMessageReceived: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 36: CallDevToolsProtocolMethod(LPCWSTR, LPCWSTR, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler*)
        CallDevToolsProtocolMethod: *const fn (*const ICoreWebView2, LPCWSTR, LPCWSTR, *anyopaque) callconv(.winapi) HRESULT,
        // Index 37: get_BrowserProcessId(UINT32*)
        get_BrowserProcessId: *const fn (*const ICoreWebView2, *u32) callconv(.winapi) HRESULT,
        // Index 38: get_CanGoBack(BOOL*)
        get_CanGoBack: *const fn (*const ICoreWebView2, *BOOL) callconv(.winapi) HRESULT,
        // Index 39: get_CanGoForward(BOOL*)
        get_CanGoForward: *const fn (*const ICoreWebView2, *BOOL) callconv(.winapi) HRESULT,
        // Index 40: GoBack()
        GoBack: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 41: GoForward()
        GoForward: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 42: GetDevToolsProtocolEventReceiver(LPCWSTR, ICoreWebView2DevToolsProtocolEventReceiver**)
        GetDevToolsProtocolEventReceiver: *const fn (*const ICoreWebView2, LPCWSTR, *?*ICoreWebView2DevToolsProtocolEventReceiver) callconv(.winapi) HRESULT,
        // Index 43: Stop()
        Stop: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 44: add_NewWindowRequested(ICoreWebView2NewWindowRequestedEventHandler*, EventRegistrationToken*)
        add_NewWindowRequested: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 45: remove_NewWindowRequested(EventRegistrationToken)
        remove_NewWindowRequested: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 46: add_DocumentTitleChanged(ICoreWebView2DocumentTitleChangedEventHandler*, EventRegistrationToken*)
        add_DocumentTitleChanged: *const fn (*const ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 47: remove_DocumentTitleChanged(EventRegistrationToken)
        remove_DocumentTitleChanged: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 48: get_DocumentTitle(LPWSTR*)
        get_DocumentTitle: *const fn (*const ICoreWebView2, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 49: AddHostObjectToScript(LPCWSTR, VARIANT*)
        AddHostObjectToScript: *const fn (*const ICoreWebView2, ?LPCWSTR, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 50: RemoveHostObjectFromScript(LPCWSTR)
        RemoveHostObjectFromScript: *const fn (*const ICoreWebView2, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 51: OpenDevToolsWindow()
        OpenDevToolsWindow: *const fn (*const ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 52: add_ContainsFullScreenElementChanged(ICoreWebView2ContainsFullScreenElementChangedEventHandler*, EventRegistrationToken*)
        add_ContainsFullScreenElementChanged: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 53: remove_ContainsFullScreenElementChanged(EventRegistrationToken)
        remove_ContainsFullScreenElementChanged: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 54: get_ContainsFullScreenElement(BOOL*)
        get_ContainsFullScreenElement: *const fn (*const ICoreWebView2, *BOOL) callconv(.winapi) HRESULT,
        // Index 55: add_WebResourceRequested(ICoreWebView2WebResourceRequestedEventHandler*, EventRegistrationToken*)
        add_WebResourceRequested: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 56: remove_WebResourceRequested(EventRegistrationToken)
        remove_WebResourceRequested: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 57: AddWebResourceRequestedFilter(LPCWSTR, COREWEBVIEW2_WEB_RESOURCE_CONTEXT)
        AddWebResourceRequestedFilter: *const fn (*const ICoreWebView2, ?LPCWSTR, COREWEBVIEW2_WEB_RESOURCE_CONTEXT) callconv(.winapi) HRESULT,
        // Index 58: RemoveWebResourceRequestedFilter(LPCWSTR, COREWEBVIEW2_WEB_RESOURCE_CONTEXT)
        RemoveWebResourceRequestedFilter: *const fn (*const ICoreWebView2, ?LPCWSTR, COREWEBVIEW2_WEB_RESOURCE_CONTEXT) callconv(.winapi) HRESULT,
        // Index 59: add_WindowCloseRequested(ICoreWebView2WindowCloseRequestedEventHandler*, EventRegistrationToken*)
        add_WindowCloseRequested: *const fn (*const ICoreWebView2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 60: remove_WindowCloseRequested(EventRegistrationToken)
        remove_WindowCloseRequested: *const fn (*const ICoreWebView2, EventRegistrationToken) callconv(.winapi) HRESULT,
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

    pub const IID = IID_ICoreWebView2NavigationCompletedEventArgs;

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) u32,
        // Index 3: get_IsSuccess(BOOL*)
        get_IsSuccess: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 4: get_WebErrorStatus(COREWEBVIEW2_WEB_ERROR_STATUS*)
        get_WebErrorStatus: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *COREWEBVIEW2_WEB_ERROR_STATUS) callconv(.winapi) HRESULT,
        // Index 5: get_NavigationId(UINT64*)
        get_NavigationId: *const fn (*const ICoreWebView2NavigationCompletedEventArgs, *u64) callconv(.winapi) HRESULT,
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

    pub const IID = IID_ICoreWebView2AcceleratorKeyPressedEventArgs;

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

    pub const IID = IID_ICoreWebView2DevToolsProtocolEventReceiver;

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

    pub const IID = IID_ICoreWebView2DevToolsProtocolEventReceivedEventArgs;

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

// ─── ICoreWebView2_2 ────────────────────────────────────────────────────
// Inherits ICoreWebView2 (slots 0-60); own slots 61-67.

pub const ICoreWebView2_2 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{9e8f0cf8-e670-4b5e-b2bc-73e061e3184c}");
    pub const Parent = ICoreWebView2;

    pub const VTable = extern struct {
        // ICoreWebView2 (indices 0-60)
        base: ICoreWebView2.VTable,
        // Index 61: add_WebResourceResponseReceived(ICoreWebView2WebResourceResponseReceivedEventHandler*, EventRegistrationToken*)
        add_WebResourceResponseReceived: *const fn (*const ICoreWebView2_2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 62: remove_WebResourceResponseReceived(EventRegistrationToken)
        remove_WebResourceResponseReceived: *const fn (*const ICoreWebView2_2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 63: NavigateWithWebResourceRequest(ICoreWebView2WebResourceRequest*)
        NavigateWithWebResourceRequest: *const fn (*const ICoreWebView2_2, ?*ICoreWebView2WebResourceRequest) callconv(.winapi) HRESULT,
        // Index 64: add_DOMContentLoaded(ICoreWebView2DOMContentLoadedEventHandler*, EventRegistrationToken*)
        add_DOMContentLoaded: *const fn (*const ICoreWebView2_2, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 65: remove_DOMContentLoaded(EventRegistrationToken)
        remove_DOMContentLoaded: *const fn (*const ICoreWebView2_2, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 66: get_CookieManager(ICoreWebView2CookieManager**)
        get_CookieManager: *const fn (*const ICoreWebView2_2, *?*ICoreWebView2CookieManager) callconv(.winapi) HRESULT,
        // Index 67: get_Environment(ICoreWebView2Environment**)
        get_Environment: *const fn (*const ICoreWebView2_2, *?*ICoreWebView2Environment) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_2) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_2) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_2) *ICoreWebView2 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_3 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_2 (slots 0-67); own slots 68-72.

pub const ICoreWebView2_3 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{a0d6df20-3b92-416d-aa0c-437a9c727857}");
    pub const Parent = ICoreWebView2_2;

    pub const VTable = extern struct {
        // ICoreWebView2_2 (indices 0-67)
        base: ICoreWebView2_2.VTable,
        // Index 68: TrySuspend(ICoreWebView2TrySuspendCompletedHandler*)
        TrySuspend: *const fn (*const ICoreWebView2_3, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 69: Resume()
        Resume: *const fn (*const ICoreWebView2_3) callconv(.winapi) HRESULT,
        // Index 70: get_IsSuspended(BOOL*)
        get_IsSuspended: *const fn (*const ICoreWebView2_3, *BOOL) callconv(.winapi) HRESULT,
        // Index 71: SetVirtualHostNameToFolderMapping(LPCWSTR, LPCWSTR, COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND)
        SetVirtualHostNameToFolderMapping: *const fn (*const ICoreWebView2_3, ?LPCWSTR, ?LPCWSTR, COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND) callconv(.winapi) HRESULT,
        // Index 72: ClearVirtualHostNameToFolderMapping(LPCWSTR)
        ClearVirtualHostNameToFolderMapping: *const fn (*const ICoreWebView2_3, ?LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_3) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_3) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_3) *ICoreWebView2_2 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_4 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_3 (slots 0-72); own slots 73-76.

pub const ICoreWebView2_4 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{20d02d59-6df2-42dc-bd06-f98a694b1302}");
    pub const Parent = ICoreWebView2_3;

    pub const VTable = extern struct {
        // ICoreWebView2_3 (indices 0-72)
        base: ICoreWebView2_3.VTable,
        // Index 73: add_FrameCreated(ICoreWebView2FrameCreatedEventHandler*, EventRegistrationToken*)
        add_FrameCreated: *const fn (*const ICoreWebView2_4, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 74: remove_FrameCreated(EventRegistrationToken)
        remove_FrameCreated: *const fn (*const ICoreWebView2_4, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 75: add_DownloadStarting(ICoreWebView2DownloadStartingEventHandler*, EventRegistrationToken*)
        add_DownloadStarting: *const fn (*const ICoreWebView2_4, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 76: remove_DownloadStarting(EventRegistrationToken)
        remove_DownloadStarting: *const fn (*const ICoreWebView2_4, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_4) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_4) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_4) *ICoreWebView2_3 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_5 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_4 (slots 0-76); own slots 77-78.

pub const ICoreWebView2_5 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{bedb11b8-d63c-11eb-b8bc-0242ac130003}");
    pub const Parent = ICoreWebView2_4;

    pub const VTable = extern struct {
        // ICoreWebView2_4 (indices 0-76)
        base: ICoreWebView2_4.VTable,
        // Index 77: add_ClientCertificateRequested(ICoreWebView2ClientCertificateRequestedEventHandler*, EventRegistrationToken*)
        add_ClientCertificateRequested: *const fn (*const ICoreWebView2_5, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 78: remove_ClientCertificateRequested(EventRegistrationToken)
        remove_ClientCertificateRequested: *const fn (*const ICoreWebView2_5, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_5) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_5) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_5) *ICoreWebView2_4 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_6 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_5 (slots 0-78); own slots 79-79.

pub const ICoreWebView2_6 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{499aadac-d92c-4589-8a75-111bfc167795}");
    pub const Parent = ICoreWebView2_5;

    pub const VTable = extern struct {
        // ICoreWebView2_5 (indices 0-78)
        base: ICoreWebView2_5.VTable,
        // Index 79: OpenTaskManagerWindow()
        OpenTaskManagerWindow: *const fn (*const ICoreWebView2_6) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_6) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_6) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_6) *ICoreWebView2_5 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_7 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_6 (slots 0-79); own slots 80-80.

pub const ICoreWebView2_7 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{79c24d83-09a3-45ae-9418-487f32a58740}");
    pub const Parent = ICoreWebView2_6;

    pub const VTable = extern struct {
        // ICoreWebView2_6 (indices 0-79)
        base: ICoreWebView2_6.VTable,
        // Index 80: PrintToPdf(LPCWSTR, ICoreWebView2PrintSettings*, ICoreWebView2PrintToPdfCompletedHandler*)
        PrintToPdf: *const fn (*const ICoreWebView2_7, ?LPCWSTR, ?*ICoreWebView2PrintSettings, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_7) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_7) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_7) *ICoreWebView2_6 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_8 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_7 (slots 0-80); own slots 81-87.

pub const ICoreWebView2_8 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e9632730-6e1e-43ab-b7b8-7b2c9e62e094}");
    pub const Parent = ICoreWebView2_7;

    pub const VTable = extern struct {
        // ICoreWebView2_7 (indices 0-80)
        base: ICoreWebView2_7.VTable,
        // Index 81: add_IsMutedChanged(ICoreWebView2IsMutedChangedEventHandler*, EventRegistrationToken*)
        add_IsMutedChanged: *const fn (*const ICoreWebView2_8, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 82: remove_IsMutedChanged(EventRegistrationToken)
        remove_IsMutedChanged: *const fn (*const ICoreWebView2_8, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 83: get_IsMuted(BOOL*)
        get_IsMuted: *const fn (*const ICoreWebView2_8, *BOOL) callconv(.winapi) HRESULT,
        // Index 84: put_IsMuted(BOOL)
        put_IsMuted: *const fn (*const ICoreWebView2_8, BOOL) callconv(.winapi) HRESULT,
        // Index 85: add_IsDocumentPlayingAudioChanged(ICoreWebView2IsDocumentPlayingAudioChangedEventHandler*, EventRegistrationToken*)
        add_IsDocumentPlayingAudioChanged: *const fn (*const ICoreWebView2_8, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 86: remove_IsDocumentPlayingAudioChanged(EventRegistrationToken)
        remove_IsDocumentPlayingAudioChanged: *const fn (*const ICoreWebView2_8, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 87: get_IsDocumentPlayingAudio(BOOL*)
        get_IsDocumentPlayingAudio: *const fn (*const ICoreWebView2_8, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_8) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_8) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_8) *ICoreWebView2_7 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_9 ────────────────────────────────────────────────────
// Inherits ICoreWebView2_8 (slots 0-87); own slots 88-96.

pub const ICoreWebView2_9 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{4d7b2eab-9fdc-468d-b998-a9260b5ed651}");
    pub const Parent = ICoreWebView2_8;

    pub const VTable = extern struct {
        // ICoreWebView2_8 (indices 0-87)
        base: ICoreWebView2_8.VTable,
        // Index 88: add_IsDefaultDownloadDialogOpenChanged(ICoreWebView2IsDefaultDownloadDialogOpenChangedEventHandler*, EventRegistrationToken*)
        add_IsDefaultDownloadDialogOpenChanged: *const fn (*const ICoreWebView2_9, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 89: remove_IsDefaultDownloadDialogOpenChanged(EventRegistrationToken)
        remove_IsDefaultDownloadDialogOpenChanged: *const fn (*const ICoreWebView2_9, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 90: get_IsDefaultDownloadDialogOpen(BOOL*)
        get_IsDefaultDownloadDialogOpen: *const fn (*const ICoreWebView2_9, *BOOL) callconv(.winapi) HRESULT,
        // Index 91: OpenDefaultDownloadDialog()
        OpenDefaultDownloadDialog: *const fn (*const ICoreWebView2_9) callconv(.winapi) HRESULT,
        // Index 92: CloseDefaultDownloadDialog()
        CloseDefaultDownloadDialog: *const fn (*const ICoreWebView2_9) callconv(.winapi) HRESULT,
        // Index 93: get_DefaultDownloadDialogCornerAlignment(COREWEBVIEW2_DEFAULT_DOWNLOAD_DIALOG_CORNER_ALIGNMENT*)
        get_DefaultDownloadDialogCornerAlignment: *const fn (*const ICoreWebView2_9, *COREWEBVIEW2_DEFAULT_DOWNLOAD_DIALOG_CORNER_ALIGNMENT) callconv(.winapi) HRESULT,
        // Index 94: put_DefaultDownloadDialogCornerAlignment(COREWEBVIEW2_DEFAULT_DOWNLOAD_DIALOG_CORNER_ALIGNMENT)
        put_DefaultDownloadDialogCornerAlignment: *const fn (*const ICoreWebView2_9, COREWEBVIEW2_DEFAULT_DOWNLOAD_DIALOG_CORNER_ALIGNMENT) callconv(.winapi) HRESULT,
        // Index 95: get_DefaultDownloadDialogMargin(POINT*)
        get_DefaultDownloadDialogMargin: *const fn (*const ICoreWebView2_9, *POINT) callconv(.winapi) HRESULT,
        // Index 96: put_DefaultDownloadDialogMargin(POINT)
        put_DefaultDownloadDialogMargin: *const fn (*const ICoreWebView2_9, POINT) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_9) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_9) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_9) *ICoreWebView2_8 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_10 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_9 (slots 0-96); own slots 97-98.

pub const ICoreWebView2_10 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{b1690564-6f5a-4983-8e48-31d1143fecdb}");
    pub const Parent = ICoreWebView2_9;

    pub const VTable = extern struct {
        // ICoreWebView2_9 (indices 0-96)
        base: ICoreWebView2_9.VTable,
        // Index 97: add_BasicAuthenticationRequested(ICoreWebView2BasicAuthenticationRequestedEventHandler*, EventRegistrationToken*)
        add_BasicAuthenticationRequested: *const fn (*const ICoreWebView2_10, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 98: remove_BasicAuthenticationRequested(EventRegistrationToken)
        remove_BasicAuthenticationRequested: *const fn (*const ICoreWebView2_10, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_10) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_10) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_10) *ICoreWebView2_9 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_11 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_10 (slots 0-98); own slots 99-101.

pub const ICoreWebView2_11 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0be78e56-c193-4051-b943-23b460c08bdb}");
    pub const Parent = ICoreWebView2_10;

    pub const VTable = extern struct {
        // ICoreWebView2_10 (indices 0-98)
        base: ICoreWebView2_10.VTable,
        // Index 99: CallDevToolsProtocolMethodForSession(LPCWSTR, LPCWSTR, LPCWSTR, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler*)
        CallDevToolsProtocolMethodForSession: *const fn (*const ICoreWebView2_11, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 100: add_ContextMenuRequested(ICoreWebView2ContextMenuRequestedEventHandler*, EventRegistrationToken*)
        add_ContextMenuRequested: *const fn (*const ICoreWebView2_11, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 101: remove_ContextMenuRequested(EventRegistrationToken)
        remove_ContextMenuRequested: *const fn (*const ICoreWebView2_11, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_11) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_11) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_11) *ICoreWebView2_10 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_12 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_11 (slots 0-101); own slots 102-104.

pub const ICoreWebView2_12 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{35d69927-bcfa-4566-9349-6b3e0d154cac}");
    pub const Parent = ICoreWebView2_11;

    pub const VTable = extern struct {
        // ICoreWebView2_11 (indices 0-101)
        base: ICoreWebView2_11.VTable,
        // Index 102: add_StatusBarTextChanged(ICoreWebView2StatusBarTextChangedEventHandler*, EventRegistrationToken*)
        add_StatusBarTextChanged: *const fn (*const ICoreWebView2_12, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 103: remove_StatusBarTextChanged(EventRegistrationToken)
        remove_StatusBarTextChanged: *const fn (*const ICoreWebView2_12, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 104: get_StatusBarText(LPWSTR*)
        get_StatusBarText: *const fn (*const ICoreWebView2_12, *?LPWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_12) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_12) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_12) *ICoreWebView2_11 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_13 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_12 (slots 0-104); own slots 105-105.

pub const ICoreWebView2_13 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f75f09a8-667e-4983-88d6-c8773f315e84}");
    pub const Parent = ICoreWebView2_12;

    pub const VTable = extern struct {
        // ICoreWebView2_12 (indices 0-104)
        base: ICoreWebView2_12.VTable,
        // Index 105: get_Profile(ICoreWebView2Profile**)
        get_Profile: *const fn (*const ICoreWebView2_13, *?*ICoreWebView2Profile) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_13) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_13) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_13) *ICoreWebView2_12 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_14 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_13 (slots 0-105); own slots 106-108.

pub const ICoreWebView2_14 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{6daa4f10-4a90-4753-8898-77c5df534165}");
    pub const Parent = ICoreWebView2_13;

    pub const VTable = extern struct {
        // ICoreWebView2_13 (indices 0-105)
        base: ICoreWebView2_13.VTable,
        // Index 106: add_ServerCertificateErrorDetected(ICoreWebView2ServerCertificateErrorDetectedEventHandler*, EventRegistrationToken*)
        add_ServerCertificateErrorDetected: *const fn (*const ICoreWebView2_14, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 107: remove_ServerCertificateErrorDetected(EventRegistrationToken)
        remove_ServerCertificateErrorDetected: *const fn (*const ICoreWebView2_14, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 108: ClearServerCertificateErrorActions(ICoreWebView2ClearServerCertificateErrorActionsCompletedHandler*)
        ClearServerCertificateErrorActions: *const fn (*const ICoreWebView2_14, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_14) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_14) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_14) *ICoreWebView2_13 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_15 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_14 (slots 0-108); own slots 109-112.

pub const ICoreWebView2_15 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{517b2d1d-7dae-4a66-a4f4-10352ffb9518}");
    pub const Parent = ICoreWebView2_14;

    pub const VTable = extern struct {
        // ICoreWebView2_14 (indices 0-108)
        base: ICoreWebView2_14.VTable,
        // Index 109: add_FaviconChanged(ICoreWebView2FaviconChangedEventHandler*, EventRegistrationToken*)
        add_FaviconChanged: *const fn (*const ICoreWebView2_15, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 110: remove_FaviconChanged(EventRegistrationToken)
        remove_FaviconChanged: *const fn (*const ICoreWebView2_15, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 111: get_FaviconUri(LPWSTR*)
        get_FaviconUri: *const fn (*const ICoreWebView2_15, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 112: GetFavicon(COREWEBVIEW2_FAVICON_IMAGE_FORMAT, ICoreWebView2GetFaviconCompletedHandler*)
        GetFavicon: *const fn (*const ICoreWebView2_15, COREWEBVIEW2_FAVICON_IMAGE_FORMAT, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_15) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_15) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_15) *ICoreWebView2_14 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2_16 ───────────────────────────────────────────────────
// Inherits ICoreWebView2_15 (slots 0-112); own slots 113-115.

pub const ICoreWebView2_16 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0eb34dc9-9f91-41e1-8639-95cd5943906b}");
    pub const Parent = ICoreWebView2_15;

    pub const VTable = extern struct {
        // ICoreWebView2_15 (indices 0-112)
        base: ICoreWebView2_15.VTable,
        // Index 113: Print(ICoreWebView2PrintSettings*, ICoreWebView2PrintCompletedHandler*)
        Print: *const fn (*const ICoreWebView2_16, ?*ICoreWebView2PrintSettings, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 114: ShowPrintUI(COREWEBVIEW2_PRINT_DIALOG_KIND)
        ShowPrintUI: *const fn (*const ICoreWebView2_16, COREWEBVIEW2_PRINT_DIALOG_KIND) callconv(.winapi) HRESULT,
        // Index 115: PrintToPdfStream(ICoreWebView2PrintSettings*, ICoreWebView2PrintToPdfStreamCompletedHandler*)
        PrintToPdfStream: *const fn (*const ICoreWebView2_16, ?*ICoreWebView2PrintSettings, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2_16) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2_16) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2_16) *ICoreWebView2_15 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Controller2 ───────────────────────────────────────────
// Inherits ICoreWebView2Controller (slots 0-25); own slots 26-27.

pub const ICoreWebView2Controller2 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{c979903e-d4ca-4228-92eb-47ee3fa96eab}");
    pub const Parent = ICoreWebView2Controller;

    pub const VTable = extern struct {
        // ICoreWebView2Controller (indices 0-25)
        base: ICoreWebView2Controller.VTable,
        // Index 26: get_DefaultBackgroundColor(COREWEBVIEW2_COLOR*)
        get_DefaultBackgroundColor: *const fn (*const ICoreWebView2Controller2, *COREWEBVIEW2_COLOR) callconv(.winapi) HRESULT,
        // Index 27: put_DefaultBackgroundColor(COREWEBVIEW2_COLOR)
        put_DefaultBackgroundColor: *const fn (*const ICoreWebView2Controller2, COREWEBVIEW2_COLOR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Controller2) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Controller2) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Controller2) *ICoreWebView2Controller {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Controller3 ───────────────────────────────────────────
// Inherits ICoreWebView2Controller2 (slots 0-27); own slots 28-35.

pub const ICoreWebView2Controller3 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f9614724-5d2b-41dc-aef7-73d62b51543b}");
    pub const Parent = ICoreWebView2Controller2;

    pub const VTable = extern struct {
        // ICoreWebView2Controller2 (indices 0-27)
        base: ICoreWebView2Controller2.VTable,
        // Index 28: get_RasterizationScale(double*)
        get_RasterizationScale: *const fn (*const ICoreWebView2Controller3, *f64) callconv(.winapi) HRESULT,
        // Index 29: put_RasterizationScale(double)
        put_RasterizationScale: *const fn (*const ICoreWebView2Controller3, f64) callconv(.winapi) HRESULT,
        // Index 30: get_ShouldDetectMonitorScaleChanges(BOOL*)
        get_ShouldDetectMonitorScaleChanges: *const fn (*const ICoreWebView2Controller3, *BOOL) callconv(.winapi) HRESULT,
        // Index 31: put_ShouldDetectMonitorScaleChanges(BOOL)
        put_ShouldDetectMonitorScaleChanges: *const fn (*const ICoreWebView2Controller3, BOOL) callconv(.winapi) HRESULT,
        // Index 32: add_RasterizationScaleChanged(ICoreWebView2RasterizationScaleChangedEventHandler*, EventRegistrationToken*)
        add_RasterizationScaleChanged: *const fn (*const ICoreWebView2Controller3, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 33: remove_RasterizationScaleChanged(EventRegistrationToken)
        remove_RasterizationScaleChanged: *const fn (*const ICoreWebView2Controller3, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 34: get_BoundsMode(COREWEBVIEW2_BOUNDS_MODE*)
        get_BoundsMode: *const fn (*const ICoreWebView2Controller3, *COREWEBVIEW2_BOUNDS_MODE) callconv(.winapi) HRESULT,
        // Index 35: put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE)
        put_BoundsMode: *const fn (*const ICoreWebView2Controller3, COREWEBVIEW2_BOUNDS_MODE) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Controller3) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Controller3) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Controller3) *ICoreWebView2Controller2 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Controller4 ───────────────────────────────────────────
// Inherits ICoreWebView2Controller3 (slots 0-35); own slots 36-37.

pub const ICoreWebView2Controller4 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{97d418d5-a426-4e49-a151-e1a10f327d9e}");
    pub const Parent = ICoreWebView2Controller3;

    pub const VTable = extern struct {
        // ICoreWebView2Controller3 (indices 0-35)
        base: ICoreWebView2Controller3.VTable,
        // Index 36: get_AllowExternalDrop(BOOL*)
        get_AllowExternalDrop: *const fn (*const ICoreWebView2Controller4, *BOOL) callconv(.winapi) HRESULT,
        // Index 37: put_AllowExternalDrop(BOOL)
        put_AllowExternalDrop: *const fn (*const ICoreWebView2Controller4, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Controller4) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Controller4) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Controller4) *ICoreWebView2Controller3 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings ──────────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-20.

pub const ICoreWebView2Settings = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e562e4f0-d7fa-43ac-8d71-c05150499f00}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Settings, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Settings) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Settings) callconv(.winapi) u32,
        // Index 3: get_IsScriptEnabled(BOOL*)
        get_IsScriptEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 4: put_IsScriptEnabled(BOOL)
        put_IsScriptEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 5: get_IsWebMessageEnabled(BOOL*)
        get_IsWebMessageEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: put_IsWebMessageEnabled(BOOL)
        put_IsWebMessageEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 7: get_AreDefaultScriptDialogsEnabled(BOOL*)
        get_AreDefaultScriptDialogsEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 8: put_AreDefaultScriptDialogsEnabled(BOOL)
        put_AreDefaultScriptDialogsEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 9: get_IsStatusBarEnabled(BOOL*)
        get_IsStatusBarEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 10: put_IsStatusBarEnabled(BOOL)
        put_IsStatusBarEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 11: get_AreDevToolsEnabled(BOOL*)
        get_AreDevToolsEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 12: put_AreDevToolsEnabled(BOOL)
        put_AreDevToolsEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 13: get_AreDefaultContextMenusEnabled(BOOL*)
        get_AreDefaultContextMenusEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 14: put_AreDefaultContextMenusEnabled(BOOL)
        put_AreDefaultContextMenusEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 15: get_AreHostObjectsAllowed(BOOL*)
        get_AreHostObjectsAllowed: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 16: put_AreHostObjectsAllowed(BOOL)
        put_AreHostObjectsAllowed: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 17: get_IsZoomControlEnabled(BOOL*)
        get_IsZoomControlEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 18: put_IsZoomControlEnabled(BOOL)
        put_IsZoomControlEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
        // Index 19: get_IsBuiltInErrorPageEnabled(BOOL*)
        get_IsBuiltInErrorPageEnabled: *const fn (*const ICoreWebView2Settings, *BOOL) callconv(.winapi) HRESULT,
        // Index 20: put_IsBuiltInErrorPageEnabled(BOOL)
        put_IsBuiltInErrorPageEnabled: *const fn (*const ICoreWebView2Settings, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2Settings2 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings (slots 0-20); own slots 21-22.

pub const ICoreWebView2Settings2 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{ee9a0f68-f46c-4e32-ac23-ef8cac224d2a}");
    pub const Parent = ICoreWebView2Settings;

    pub const VTable = extern struct {
        // ICoreWebView2Settings (indices 0-20)
        base: ICoreWebView2Settings.VTable,
        // Index 21: get_UserAgent(LPWSTR*)
        get_UserAgent: *const fn (*const ICoreWebView2Settings2, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 22: put_UserAgent(LPCWSTR)
        put_UserAgent: *const fn (*const ICoreWebView2Settings2, ?LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings2) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings2) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings2) *ICoreWebView2Settings {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings3 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings2 (slots 0-22); own slots 23-24.

pub const ICoreWebView2Settings3 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{fdb5ab74-af33-4854-84f0-0a631deb5eba}");
    pub const Parent = ICoreWebView2Settings2;

    pub const VTable = extern struct {
        // ICoreWebView2Settings2 (indices 0-22)
        base: ICoreWebView2Settings2.VTable,
        // Index 23: get_AreBrowserAcceleratorKeysEnabled(BOOL*)
        get_AreBrowserAcceleratorKeysEnabled: *const fn (*const ICoreWebView2Settings3, *BOOL) callconv(.winapi) HRESULT,
        // Index 24: put_AreBrowserAcceleratorKeysEnabled(BOOL)
        put_AreBrowserAcceleratorKeysEnabled: *const fn (*const ICoreWebView2Settings3, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings3) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings3) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings3) *ICoreWebView2Settings2 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings4 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings3 (slots 0-24); own slots 25-28.

pub const ICoreWebView2Settings4 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{cb56846c-4168-4d53-b04f-03b6d6796ff2}");
    pub const Parent = ICoreWebView2Settings3;

    pub const VTable = extern struct {
        // ICoreWebView2Settings3 (indices 0-24)
        base: ICoreWebView2Settings3.VTable,
        // Index 25: get_IsPasswordAutosaveEnabled(BOOL*)
        get_IsPasswordAutosaveEnabled: *const fn (*const ICoreWebView2Settings4, *BOOL) callconv(.winapi) HRESULT,
        // Index 26: put_IsPasswordAutosaveEnabled(BOOL)
        put_IsPasswordAutosaveEnabled: *const fn (*const ICoreWebView2Settings4, BOOL) callconv(.winapi) HRESULT,
        // Index 27: get_IsGeneralAutofillEnabled(BOOL*)
        get_IsGeneralAutofillEnabled: *const fn (*const ICoreWebView2Settings4, *BOOL) callconv(.winapi) HRESULT,
        // Index 28: put_IsGeneralAutofillEnabled(BOOL)
        put_IsGeneralAutofillEnabled: *const fn (*const ICoreWebView2Settings4, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings4) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings4) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings4) *ICoreWebView2Settings3 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings5 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings4 (slots 0-28); own slots 29-30.

pub const ICoreWebView2Settings5 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{183e7052-1d03-43a0-ab99-98e043b66b39}");
    pub const Parent = ICoreWebView2Settings4;

    pub const VTable = extern struct {
        // ICoreWebView2Settings4 (indices 0-28)
        base: ICoreWebView2Settings4.VTable,
        // Index 29: get_IsPinchZoomEnabled(BOOL*)
        get_IsPinchZoomEnabled: *const fn (*const ICoreWebView2Settings5, *BOOL) callconv(.winapi) HRESULT,
        // Index 30: put_IsPinchZoomEnabled(BOOL)
        put_IsPinchZoomEnabled: *const fn (*const ICoreWebView2Settings5, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings5) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings5) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings5) *ICoreWebView2Settings4 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings6 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings5 (slots 0-30); own slots 31-32.

pub const ICoreWebView2Settings6 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{11cb3acd-9bc8-43b8-83bf-f40753714f87}");
    pub const Parent = ICoreWebView2Settings5;

    pub const VTable = extern struct {
        // ICoreWebView2Settings5 (indices 0-30)
        base: ICoreWebView2Settings5.VTable,
        // Index 31: get_IsSwipeNavigationEnabled(BOOL*)
        get_IsSwipeNavigationEnabled: *const fn (*const ICoreWebView2Settings6, *BOOL) callconv(.winapi) HRESULT,
        // Index 32: put_IsSwipeNavigationEnabled(BOOL)
        put_IsSwipeNavigationEnabled: *const fn (*const ICoreWebView2Settings6, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings6) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings6) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings6) *ICoreWebView2Settings5 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings7 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings6 (slots 0-32); own slots 33-34.

pub const ICoreWebView2Settings7 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{488dc902-35ef-42d2-bc7d-94b65c4bc49c}");
    pub const Parent = ICoreWebView2Settings6;

    pub const VTable = extern struct {
        // ICoreWebView2Settings6 (indices 0-32)
        base: ICoreWebView2Settings6.VTable,
        // Index 33: get_HiddenPdfToolbarItems(COREWEBVIEW2_PDF_TOOLBAR_ITEMS*)
        get_HiddenPdfToolbarItems: *const fn (*const ICoreWebView2Settings7, *COREWEBVIEW2_PDF_TOOLBAR_ITEMS) callconv(.winapi) HRESULT,
        // Index 34: put_HiddenPdfToolbarItems(COREWEBVIEW2_PDF_TOOLBAR_ITEMS)
        put_HiddenPdfToolbarItems: *const fn (*const ICoreWebView2Settings7, COREWEBVIEW2_PDF_TOOLBAR_ITEMS) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings7) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings7) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings7) *ICoreWebView2Settings6 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Settings8 ─────────────────────────────────────────────
// Inherits ICoreWebView2Settings7 (slots 0-34); own slots 35-36.

pub const ICoreWebView2Settings8 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{9e6b0e8f-86ad-4e81-8147-a9b5edb68650}");
    pub const Parent = ICoreWebView2Settings7;

    pub const VTable = extern struct {
        // ICoreWebView2Settings7 (indices 0-34)
        base: ICoreWebView2Settings7.VTable,
        // Index 35: get_IsReputationCheckingRequired(BOOL*)
        get_IsReputationCheckingRequired: *const fn (*const ICoreWebView2Settings8, *BOOL) callconv(.winapi) HRESULT,
        // Index 36: put_IsReputationCheckingRequired(BOOL)
        put_IsReputationCheckingRequired: *const fn (*const ICoreWebView2Settings8, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Settings8) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Settings8) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Settings8) *ICoreWebView2Settings7 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment2 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment (slots 0-7); own slots 8-8.

pub const ICoreWebView2Environment2 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{41f3632b-5ef4-404f-ad82-2d606c5a9a21}");
    pub const Parent = ICoreWebView2Environment;

    pub const VTable = extern struct {
        // ICoreWebView2Environment (indices 0-7)
        base: ICoreWebView2Environment.VTable,
        // Index 8: CreateWebResourceRequest(LPCWSTR, LPCWSTR, IStream*, LPCWSTR, ICoreWebView2WebResourceRequest**)
        CreateWebResourceRequest: *const fn (*const ICoreWebView2Environment2, ?LPCWSTR, ?LPCWSTR, ?*anyopaque, ?LPCWSTR, *?*ICoreWebView2WebResourceRequest) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment2) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment2) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment2) *ICoreWebView2Environment {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment3 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment2 (slots 0-8); own slots 9-10.

pub const ICoreWebView2Environment3 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{80a22ae3-be7c-4ce2-afe1-5a50056cdeeb}");
    pub const Parent = ICoreWebView2Environment2;

    pub const VTable = extern struct {
        // ICoreWebView2Environment2 (indices 0-8)
        base: ICoreWebView2Environment2.VTable,
        // Index 9: CreateCoreWebView2CompositionController(HWND, ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler*)
        CreateCoreWebView2CompositionController: *const fn (*const ICoreWebView2Environment3, HWND, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 10: CreateCoreWebView2PointerInfo(ICoreWebView2PointerInfo**)
        CreateCoreWebView2PointerInfo: *const fn (*const ICoreWebView2Environment3, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment3) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment3) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment3) *ICoreWebView2Environment2 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment4 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment3 (slots 0-10); own slots 11-11.

pub const ICoreWebView2Environment4 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{20944379-6dcf-41d6-a0a0-abc0fc50de0d}");
    pub const Parent = ICoreWebView2Environment3;

    pub const VTable = extern struct {
        // ICoreWebView2Environment3 (indices 0-10)
        base: ICoreWebView2Environment3.VTable,
        // Index 11: GetAutomationProviderForWindow(HWND, IUnknown**)
        GetAutomationProviderForWindow: *const fn (*const ICoreWebView2Environment4, HWND, *?*IUnknown) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment4) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment4) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment4) *ICoreWebView2Environment3 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment5 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment4 (slots 0-11); own slots 12-13.

pub const ICoreWebView2Environment5 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{319e423d-e0d7-4b8d-9254-ae9475de9b17}");
    pub const Parent = ICoreWebView2Environment4;

    pub const VTable = extern struct {
        // ICoreWebView2Environment4 (indices 0-11)
        base: ICoreWebView2Environment4.VTable,
        // Index 12: add_BrowserProcessExited(ICoreWebView2BrowserProcessExitedEventHandler*, EventRegistrationToken*)
        add_BrowserProcessExited: *const fn (*const ICoreWebView2Environment5, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 13: remove_BrowserProcessExited(EventRegistrationToken)
        remove_BrowserProcessExited: *const fn (*const ICoreWebView2Environment5, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment5) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment5) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment5) *ICoreWebView2Environment4 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment6 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment5 (slots 0-13); own slots 14-14.

pub const ICoreWebView2Environment6 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e59ee362-acbd-4857-9a8e-d3644d9459a9}");
    pub const Parent = ICoreWebView2Environment5;

    pub const VTable = extern struct {
        // ICoreWebView2Environment5 (indices 0-13)
        base: ICoreWebView2Environment5.VTable,
        // Index 14: CreatePrintSettings(ICoreWebView2PrintSettings**)
        CreatePrintSettings: *const fn (*const ICoreWebView2Environment6, *?*ICoreWebView2PrintSettings) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment6) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment6) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment6) *ICoreWebView2Environment5 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment7 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment6 (slots 0-14); own slots 15-15.

pub const ICoreWebView2Environment7 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{43c22296-3bbd-43a4-9c00-5c0df6dd29a2}");
    pub const Parent = ICoreWebView2Environment6;

    pub const VTable = extern struct {
        // ICoreWebView2Environment6 (indices 0-14)
        base: ICoreWebView2Environment6.VTable,
        // Index 15: get_UserDataFolder(LPWSTR*)
        get_UserDataFolder: *const fn (*const ICoreWebView2Environment7, *?LPWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment7) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment7) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment7) *ICoreWebView2Environment6 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment8 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment7 (slots 0-15); own slots 16-18.

pub const ICoreWebView2Environment8 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{d6eb91dd-c3d2-45e5-bd29-6dc2bc4de9cf}");
    pub const Parent = ICoreWebView2Environment7;

    pub const VTable = extern struct {
        // ICoreWebView2Environment7 (indices 0-15)
        base: ICoreWebView2Environment7.VTable,
        // Index 16: add_ProcessInfosChanged(ICoreWebView2ProcessInfosChangedEventHandler*, EventRegistrationToken*)
        add_ProcessInfosChanged: *const fn (*const ICoreWebView2Environment8, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 17: remove_ProcessInfosChanged(EventRegistrationToken)
        remove_ProcessInfosChanged: *const fn (*const ICoreWebView2Environment8, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 18: GetProcessInfos(ICoreWebView2ProcessInfoCollection**)
        GetProcessInfos: *const fn (*const ICoreWebView2Environment8, *?*ICoreWebView2ProcessInfoCollection) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment8) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment8) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment8) *ICoreWebView2Environment7 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment9 ──────────────────────────────────────────
// Inherits ICoreWebView2Environment8 (slots 0-18); own slots 19-19.

pub const ICoreWebView2Environment9 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f06f41bf-4b5a-49d8-b9f6-fa16cd29f274}");
    pub const Parent = ICoreWebView2Environment8;

    pub const VTable = extern struct {
        // ICoreWebView2Environment8 (indices 0-18)
        base: ICoreWebView2Environment8.VTable,
        // Index 19: CreateContextMenuItem(LPCWSTR, IStream*, COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND, ICoreWebView2ContextMenuItem**)
        CreateContextMenuItem: *const fn (*const ICoreWebView2Environment9, ?LPCWSTR, ?*anyopaque, COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND, *?*ICoreWebView2ContextMenuItem) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment9) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment9) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment9) *ICoreWebView2Environment8 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2Environment10 ─────────────────────────────────────────
// Inherits ICoreWebView2Environment9 (slots 0-19); own slots 20-22.

pub const ICoreWebView2Environment10 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{ee0eb9df-6f12-46ce-b53f-3f47b9c928e0}");
    pub const Parent = ICoreWebView2Environment9;

    pub const VTable = extern struct {
        // ICoreWebView2Environment9 (indices 0-19)
        base: ICoreWebView2Environment9.VTable,
        // Index 20: CreateCoreWebView2ControllerOptions(ICoreWebView2ControllerOptions**)
        CreateCoreWebView2ControllerOptions: *const fn (*const ICoreWebView2Environment10, *?*ICoreWebView2ControllerOptions) callconv(.winapi) HRESULT,
        // Index 21: CreateCoreWebView2ControllerWithOptions(HWND, ICoreWebView2ControllerOptions*, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*)
        CreateCoreWebView2ControllerWithOptions: *const fn (*const ICoreWebView2Environment10, HWND, ?*ICoreWebView2ControllerOptions, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 22: CreateCoreWebView2CompositionControllerWithOptions(HWND, ICoreWebView2ControllerOptions*, ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler*)
        CreateCoreWebView2CompositionControllerWithOptions: *const fn (*const ICoreWebView2Environment10, HWND, ?*ICoreWebView2ControllerOptions, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment10) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment10) void {
        comRelease(self);
    }

    /// The same object viewed as its parent interface (borrowed).
    pub fn asBase(self: *ICoreWebView2Environment10) *ICoreWebView2Environment9 {
        return @ptrCast(self);
    }
};

// ─── ICoreWebView2ControllerOptions ─────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-6.

pub const ICoreWebView2ControllerOptions = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{12aae616-8ccb-44ec-bcb3-eb1831881635}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ControllerOptions, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ControllerOptions) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ControllerOptions) callconv(.winapi) u32,
        // Index 3: get_ProfileName(LPWSTR*)
        get_ProfileName: *const fn (*const ICoreWebView2ControllerOptions, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: put_ProfileName(LPCWSTR)
        put_ProfileName: *const fn (*const ICoreWebView2ControllerOptions, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_IsInPrivateModeEnabled(BOOL*)
        get_IsInPrivateModeEnabled: *const fn (*const ICoreWebView2ControllerOptions, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: put_IsInPrivateModeEnabled(BOOL)
        put_IsInPrivateModeEnabled: *const fn (*const ICoreWebView2ControllerOptions, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ControllerOptions) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ControllerOptions) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2EnvironmentOptions ────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2EnvironmentOptions = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2EnvironmentOptions, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2EnvironmentOptions) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2EnvironmentOptions) callconv(.winapi) u32,
        // Index 3: get_AdditionalBrowserArguments(LPWSTR*)
        get_AdditionalBrowserArguments: *const fn (*const ICoreWebView2EnvironmentOptions, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: put_AdditionalBrowserArguments(LPCWSTR)
        put_AdditionalBrowserArguments: *const fn (*const ICoreWebView2EnvironmentOptions, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_Language(LPWSTR*)
        get_Language: *const fn (*const ICoreWebView2EnvironmentOptions, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: put_Language(LPCWSTR)
        put_Language: *const fn (*const ICoreWebView2EnvironmentOptions, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 7: get_TargetCompatibleBrowserVersion(LPWSTR*)
        get_TargetCompatibleBrowserVersion: *const fn (*const ICoreWebView2EnvironmentOptions, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 8: put_TargetCompatibleBrowserVersion(LPCWSTR)
        put_TargetCompatibleBrowserVersion: *const fn (*const ICoreWebView2EnvironmentOptions, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 9: get_AllowSingleSignOnUsingOSPrimaryAccount(BOOL*)
        get_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*const ICoreWebView2EnvironmentOptions, *BOOL) callconv(.winapi) HRESULT,
        // Index 10: put_AllowSingleSignOnUsingOSPrimaryAccount(BOOL)
        put_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*const ICoreWebView2EnvironmentOptions, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2EnvironmentOptions) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2EnvironmentOptions) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2NavigationStartingEventArgs ───────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-9.

pub const ICoreWebView2NavigationStartingEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{5b495469-e119-438a-9b18-7604f25f2e49}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) u32,
        // Index 3: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_IsUserInitiated(BOOL*)
        get_IsUserInitiated: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: get_IsRedirected(BOOL*)
        get_IsRedirected: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: get_RequestHeaders(ICoreWebView2HttpRequestHeaders**)
        get_RequestHeaders: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *?*ICoreWebView2HttpRequestHeaders) callconv(.winapi) HRESULT,
        // Index 7: get_Cancel(BOOL*)
        get_Cancel: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 8: put_Cancel(BOOL)
        put_Cancel: *const fn (*const ICoreWebView2NavigationStartingEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 9: get_NavigationId(UINT64*)
        get_NavigationId: *const fn (*const ICoreWebView2NavigationStartingEventArgs, *u64) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2NavigationStartingEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2NavigationStartingEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ContentLoadingEventArgs ───────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2ContentLoadingEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0c8a1275-9b6b-4901-87ad-70df25bafa6e}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ContentLoadingEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ContentLoadingEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ContentLoadingEventArgs) callconv(.winapi) u32,
        // Index 3: get_IsErrorPage(BOOL*)
        get_IsErrorPage: *const fn (*const ICoreWebView2ContentLoadingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 4: get_NavigationId(UINT64*)
        get_NavigationId: *const fn (*const ICoreWebView2ContentLoadingEventArgs, *u64) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ContentLoadingEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ContentLoadingEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2SourceChangedEventArgs ────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-3.

pub const ICoreWebView2SourceChangedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{31e0e545-1dba-4266-8914-f63848a1f7d7}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2SourceChangedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2SourceChangedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2SourceChangedEventArgs) callconv(.winapi) u32,
        // Index 3: get_IsNewDocument(BOOL*)
        get_IsNewDocument: *const fn (*const ICoreWebView2SourceChangedEventArgs, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2SourceChangedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2SourceChangedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ProcessFailedEventArgs ────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-3.

pub const ICoreWebView2ProcessFailedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{8155a9a4-1474-4a86-8cae-151b0fa6b8ca}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ProcessFailedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ProcessFailedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ProcessFailedEventArgs) callconv(.winapi) u32,
        // Index 3: get_ProcessFailedKind(COREWEBVIEW2_PROCESS_FAILED_KIND*)
        get_ProcessFailedKind: *const fn (*const ICoreWebView2ProcessFailedEventArgs, *COREWEBVIEW2_PROCESS_FAILED_KIND) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ProcessFailedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ProcessFailedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2WebMessageReceivedEventArgs ───────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-5.

pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0f99a40c-e962-4207-9e92-e3d542eff849}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2WebMessageReceivedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Source(LPWSTR*)
        get_Source: *const fn (*const ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_WebMessageAsJson(LPWSTR*)
        get_WebMessageAsJson: *const fn (*const ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: TryGetWebMessageAsString(LPWSTR*)
        TryGetWebMessageAsString: *const fn (*const ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2WebMessageReceivedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2WebMessageReceivedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ScriptDialogOpeningEventArgs ──────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2ScriptDialogOpeningEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{7390bb70-abe0-4843-9529-f143b31b03d6}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs) callconv(.winapi) u32,
        // Index 3: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Kind(COREWEBVIEW2_SCRIPT_DIALOG_KIND*)
        get_Kind: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *COREWEBVIEW2_SCRIPT_DIALOG_KIND) callconv(.winapi) HRESULT,
        // Index 5: get_Message(LPWSTR*)
        get_Message: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: Accept()
        Accept: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs) callconv(.winapi) HRESULT,
        // Index 7: get_DefaultText(LPWSTR*)
        get_DefaultText: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_ResultText(LPWSTR*)
        get_ResultText: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 9: put_ResultText(LPCWSTR)
        put_ResultText: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 10: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2ScriptDialogOpeningEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ScriptDialogOpeningEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ScriptDialogOpeningEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2PermissionRequestedEventArgs ──────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-8.

pub const ICoreWebView2PermissionRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{973ae2ef-ff18-4894-8fb2-3c758f046810}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2PermissionRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2PermissionRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_PermissionKind(COREWEBVIEW2_PERMISSION_KIND*)
        get_PermissionKind: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, *COREWEBVIEW2_PERMISSION_KIND) callconv(.winapi) HRESULT,
        // Index 5: get_IsUserInitiated(BOOL*)
        get_IsUserInitiated: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: get_State(COREWEBVIEW2_PERMISSION_STATE*)
        get_State: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, *COREWEBVIEW2_PERMISSION_STATE) callconv(.winapi) HRESULT,
        // Index 7: put_State(COREWEBVIEW2_PERMISSION_STATE)
        put_State: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, COREWEBVIEW2_PERMISSION_STATE) callconv(.winapi) HRESULT,
        // Index 8: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2PermissionRequestedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2PermissionRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2PermissionRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2NewWindowRequestedEventArgs ───────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2NewWindowRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{34acb11c-fc37-4418-9132-f9c21d1eafb9}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: put_NewWindow(ICoreWebView2*)
        put_NewWindow: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, ?*ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 5: get_NewWindow(ICoreWebView2**)
        get_NewWindow: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *?*ICoreWebView2) callconv(.winapi) HRESULT,
        // Index 6: put_Handled(BOOL)
        put_Handled: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 7: get_Handled(BOOL*)
        get_Handled: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 8: get_IsUserInitiated(BOOL*)
        get_IsUserInitiated: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 9: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
        // Index 10: get_WindowFeatures(ICoreWebView2WindowFeatures**)
        get_WindowFeatures: *const fn (*const ICoreWebView2NewWindowRequestedEventArgs, *?*ICoreWebView2WindowFeatures) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2NewWindowRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2NewWindowRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2WindowFeatures ────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-12.

pub const ICoreWebView2WindowFeatures = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{5eaf559f-b46e-4397-8860-e422f287ff1e}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2WindowFeatures, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2WindowFeatures) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2WindowFeatures) callconv(.winapi) u32,
        // Index 3: get_HasPosition(BOOL*)
        get_HasPosition: *const fn (*const ICoreWebView2WindowFeatures, *BOOL) callconv(.winapi) HRESULT,
        // Index 4: get_HasSize(BOOL*)
        get_HasSize: *const fn (*const ICoreWebView2WindowFeatures, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: get_Left(UINT32*)
        get_Left: *const fn (*const ICoreWebView2WindowFeatures, *u32) callconv(.winapi) HRESULT,
        // Index 6: get_Top(UINT32*)
        get_Top: *const fn (*const ICoreWebView2WindowFeatures, *u32) callconv(.winapi) HRESULT,
        // Index 7: get_Height(UINT32*)
        get_Height: *const fn (*const ICoreWebView2WindowFeatures, *u32) callconv(.winapi) HRESULT,
        // Index 8: get_Width(UINT32*)
        get_Width: *const fn (*const ICoreWebView2WindowFeatures, *u32) callconv(.winapi) HRESULT,
        // Index 9: get_ShouldDisplayMenuBar(BOOL*)
        get_ShouldDisplayMenuBar: *const fn (*const ICoreWebView2WindowFeatures, *BOOL) callconv(.winapi) HRESULT,
        // Index 10: get_ShouldDisplayStatus(BOOL*)
        get_ShouldDisplayStatus: *const fn (*const ICoreWebView2WindowFeatures, *BOOL) callconv(.winapi) HRESULT,
        // Index 11: get_ShouldDisplayToolbar(BOOL*)
        get_ShouldDisplayToolbar: *const fn (*const ICoreWebView2WindowFeatures, *BOOL) callconv(.winapi) HRESULT,
        // Index 12: get_ShouldDisplayScrollBars(BOOL*)
        get_ShouldDisplayScrollBars: *const fn (*const ICoreWebView2WindowFeatures, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2WindowFeatures) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2WindowFeatures) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2WebResourceRequestedEventArgs ─────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-7.

pub const ICoreWebView2WebResourceRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{453e667f-12c7-49d4-be6d-ddbe7956f57a}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Request(ICoreWebView2WebResourceRequest**)
        get_Request: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs, *?*ICoreWebView2WebResourceRequest) callconv(.winapi) HRESULT,
        // Index 4: get_Response(ICoreWebView2WebResourceResponse**)
        get_Response: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs, *?*ICoreWebView2WebResourceResponse) callconv(.winapi) HRESULT,
        // Index 5: put_Response(ICoreWebView2WebResourceResponse*)
        put_Response: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs, ?*ICoreWebView2WebResourceResponse) callconv(.winapi) HRESULT,
        // Index 6: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
        // Index 7: get_ResourceContext(COREWEBVIEW2_WEB_RESOURCE_CONTEXT*)
        get_ResourceContext: *const fn (*const ICoreWebView2WebResourceRequestedEventArgs, *COREWEBVIEW2_WEB_RESOURCE_CONTEXT) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2WebResourceRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2WebResourceRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2WebResourceRequest ────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-9.

pub const ICoreWebView2WebResourceRequest = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{97055cd4-512c-4264-8b5f-e3f446cea6a5}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2WebResourceRequest, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2WebResourceRequest) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2WebResourceRequest) callconv(.winapi) u32,
        // Index 3: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2WebResourceRequest, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: put_Uri(LPCWSTR)
        put_Uri: *const fn (*const ICoreWebView2WebResourceRequest, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_Method(LPWSTR*)
        get_Method: *const fn (*const ICoreWebView2WebResourceRequest, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: put_Method(LPCWSTR)
        put_Method: *const fn (*const ICoreWebView2WebResourceRequest, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 7: get_Content(IStream**)
        get_Content: *const fn (*const ICoreWebView2WebResourceRequest, *?*anyopaque) callconv(.winapi) HRESULT,
        // Index 8: put_Content(IStream*)
        put_Content: *const fn (*const ICoreWebView2WebResourceRequest, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 9: get_Headers(ICoreWebView2HttpRequestHeaders**)
        get_Headers: *const fn (*const ICoreWebView2WebResourceRequest, *?*ICoreWebView2HttpRequestHeaders) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2WebResourceRequest) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2WebResourceRequest) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2WebResourceResponse ───────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-9.

pub const ICoreWebView2WebResourceResponse = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{aafcc94f-fa27-48fd-97df-830ef75aaec9}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2WebResourceResponse, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2WebResourceResponse) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2WebResourceResponse) callconv(.winapi) u32,
        // Index 3: get_Content(IStream**)
        get_Content: *const fn (*const ICoreWebView2WebResourceResponse, *?*anyopaque) callconv(.winapi) HRESULT,
        // Index 4: put_Content(IStream*)
        put_Content: *const fn (*const ICoreWebView2WebResourceResponse, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 5: get_Headers(ICoreWebView2HttpResponseHeaders**)
        get_Headers: *const fn (*const ICoreWebView2WebResourceResponse, *?*ICoreWebView2HttpResponseHeaders) callconv(.winapi) HRESULT,
        // Index 6: get_StatusCode(int*)
        get_StatusCode: *const fn (*const ICoreWebView2WebResourceResponse, *i32) callconv(.winapi) HRESULT,
        // Index 7: put_StatusCode(int)
        put_StatusCode: *const fn (*const ICoreWebView2WebResourceResponse, i32) callconv(.winapi) HRESULT,
        // Index 8: get_ReasonPhrase(LPWSTR*)
        get_ReasonPhrase: *const fn (*const ICoreWebView2WebResourceResponse, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 9: put_ReasonPhrase(LPCWSTR)
        put_ReasonPhrase: *const fn (*const ICoreWebView2WebResourceResponse, ?LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2WebResourceResponse) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2WebResourceResponse) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2HttpRequestHeaders ────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-8.

pub const ICoreWebView2HttpRequestHeaders = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e86cac0e-5523-465c-b536-8fb9fc8c8c60}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2HttpRequestHeaders, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2HttpRequestHeaders) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2HttpRequestHeaders) callconv(.winapi) u32,
        // Index 3: GetHeader(LPCWSTR, LPWSTR*)
        GetHeader: *const fn (*const ICoreWebView2HttpRequestHeaders, ?LPCWSTR, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: GetHeaders(LPCWSTR, ICoreWebView2HttpHeadersCollectionIterator**)
        GetHeaders: *const fn (*const ICoreWebView2HttpRequestHeaders, ?LPCWSTR, *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(.winapi) HRESULT,
        // Index 5: Contains(LPCWSTR, BOOL*)
        Contains: *const fn (*const ICoreWebView2HttpRequestHeaders, ?LPCWSTR, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: SetHeader(LPCWSTR, LPCWSTR)
        SetHeader: *const fn (*const ICoreWebView2HttpRequestHeaders, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 7: RemoveHeader(LPCWSTR)
        RemoveHeader: *const fn (*const ICoreWebView2HttpRequestHeaders, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 8: GetIterator(ICoreWebView2HttpHeadersCollectionIterator**)
        GetIterator: *const fn (*const ICoreWebView2HttpRequestHeaders, *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2HttpRequestHeaders) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2HttpRequestHeaders) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2HttpResponseHeaders ───────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-7.

pub const ICoreWebView2HttpResponseHeaders = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{03c5ff5a-9b45-4a88-881c-89a9f328619c}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2HttpResponseHeaders, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2HttpResponseHeaders) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2HttpResponseHeaders) callconv(.winapi) u32,
        // Index 3: AppendHeader(LPCWSTR, LPCWSTR)
        AppendHeader: *const fn (*const ICoreWebView2HttpResponseHeaders, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 4: Contains(LPCWSTR, BOOL*)
        Contains: *const fn (*const ICoreWebView2HttpResponseHeaders, ?LPCWSTR, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: GetHeader(LPCWSTR, LPWSTR*)
        GetHeader: *const fn (*const ICoreWebView2HttpResponseHeaders, ?LPCWSTR, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: GetHeaders(LPCWSTR, ICoreWebView2HttpHeadersCollectionIterator**)
        GetHeaders: *const fn (*const ICoreWebView2HttpResponseHeaders, ?LPCWSTR, *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(.winapi) HRESULT,
        // Index 7: GetIterator(ICoreWebView2HttpHeadersCollectionIterator**)
        GetIterator: *const fn (*const ICoreWebView2HttpResponseHeaders, *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2HttpResponseHeaders) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2HttpResponseHeaders) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2HttpHeadersCollectionIterator ─────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-5.

pub const ICoreWebView2HttpHeadersCollectionIterator = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{0702fc30-f43b-47bb-ab52-a42cb552ad9f}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2HttpHeadersCollectionIterator, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2HttpHeadersCollectionIterator) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2HttpHeadersCollectionIterator) callconv(.winapi) u32,
        // Index 3: GetCurrentHeader(LPWSTR*, LPWSTR*)
        GetCurrentHeader: *const fn (*const ICoreWebView2HttpHeadersCollectionIterator, *?LPWSTR, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_HasCurrentHeader(BOOL*)
        get_HasCurrentHeader: *const fn (*const ICoreWebView2HttpHeadersCollectionIterator, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: MoveNext(BOOL*)
        MoveNext: *const fn (*const ICoreWebView2HttpHeadersCollectionIterator, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2HttpHeadersCollectionIterator) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2HttpHeadersCollectionIterator) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2Deferral ──────────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-3.

pub const ICoreWebView2Deferral = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{c10e7f7b-b585-46f0-a623-8befbf3e4ee0}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Deferral, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Deferral) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Deferral) callconv(.winapi) u32,
        // Index 3: Complete()
        Complete: *const fn (*const ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Deferral) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Deferral) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2MoveFocusRequestedEventArgs ───────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-5.

pub const ICoreWebView2MoveFocusRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{2d6aa13b-3839-4a15-92fc-d88b3c0d9c9d}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2MoveFocusRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2MoveFocusRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2MoveFocusRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Reason(COREWEBVIEW2_MOVE_FOCUS_REASON*)
        get_Reason: *const fn (*const ICoreWebView2MoveFocusRequestedEventArgs, *COREWEBVIEW2_MOVE_FOCUS_REASON) callconv(.winapi) HRESULT,
        // Index 4: get_Handled(BOOL*)
        get_Handled: *const fn (*const ICoreWebView2MoveFocusRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: put_Handled(BOOL)
        put_Handled: *const fn (*const ICoreWebView2MoveFocusRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2MoveFocusRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2MoveFocusRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2DOMContentLoadedEventArgs ─────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-3.

pub const ICoreWebView2DOMContentLoadedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{16b1e21a-c503-44f2-84c9-70aba5031283}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2DOMContentLoadedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2DOMContentLoadedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2DOMContentLoadedEventArgs) callconv(.winapi) u32,
        // Index 3: get_NavigationId(UINT64*)
        get_NavigationId: *const fn (*const ICoreWebView2DOMContentLoadedEventArgs, *u64) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2DOMContentLoadedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2DOMContentLoadedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2CookieManager ─────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2CookieManager = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{177cd9e7-b6f5-451a-94a0-5d7a3a4c4141}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2CookieManager, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2CookieManager) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2CookieManager) callconv(.winapi) u32,
        // Index 3: CreateCookie(LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, ICoreWebView2Cookie**)
        CreateCookie: *const fn (*const ICoreWebView2CookieManager, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, *?*ICoreWebView2Cookie) callconv(.winapi) HRESULT,
        // Index 4: CopyCookie(ICoreWebView2Cookie*, ICoreWebView2Cookie**)
        CopyCookie: *const fn (*const ICoreWebView2CookieManager, ?*ICoreWebView2Cookie, *?*ICoreWebView2Cookie) callconv(.winapi) HRESULT,
        // Index 5: GetCookies(LPCWSTR, ICoreWebView2GetCookiesCompletedHandler*)
        GetCookies: *const fn (*const ICoreWebView2CookieManager, ?LPCWSTR, ?*anyopaque) callconv(.winapi) HRESULT,
        // Index 6: AddOrUpdateCookie(ICoreWebView2Cookie*)
        AddOrUpdateCookie: *const fn (*const ICoreWebView2CookieManager, ?*ICoreWebView2Cookie) callconv(.winapi) HRESULT,
        // Index 7: DeleteCookie(ICoreWebView2Cookie*)
        DeleteCookie: *const fn (*const ICoreWebView2CookieManager, ?*ICoreWebView2Cookie) callconv(.winapi) HRESULT,
        // Index 8: DeleteCookies(LPCWSTR, LPCWSTR)
        DeleteCookies: *const fn (*const ICoreWebView2CookieManager, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 9: DeleteCookiesWithDomainAndPath(LPCWSTR, LPCWSTR, LPCWSTR)
        DeleteCookiesWithDomainAndPath: *const fn (*const ICoreWebView2CookieManager, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 10: DeleteAllCookies()
        DeleteAllCookies: *const fn (*const ICoreWebView2CookieManager) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2CookieManager) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2CookieManager) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2Cookie ────────────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-16.

pub const ICoreWebView2Cookie = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{ad26d6be-1486-43e6-bf87-a2034006ca21}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Cookie, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Cookie) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Cookie) callconv(.winapi) u32,
        // Index 3: get_Name(LPWSTR*)
        get_Name: *const fn (*const ICoreWebView2Cookie, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Value(LPWSTR*)
        get_Value: *const fn (*const ICoreWebView2Cookie, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: put_Value(LPCWSTR)
        put_Value: *const fn (*const ICoreWebView2Cookie, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 6: get_Domain(LPWSTR*)
        get_Domain: *const fn (*const ICoreWebView2Cookie, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 7: get_Path(LPWSTR*)
        get_Path: *const fn (*const ICoreWebView2Cookie, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_Expires(double*)
        get_Expires: *const fn (*const ICoreWebView2Cookie, *f64) callconv(.winapi) HRESULT,
        // Index 9: put_Expires(double)
        put_Expires: *const fn (*const ICoreWebView2Cookie, f64) callconv(.winapi) HRESULT,
        // Index 10: get_IsHttpOnly(BOOL*)
        get_IsHttpOnly: *const fn (*const ICoreWebView2Cookie, *BOOL) callconv(.winapi) HRESULT,
        // Index 11: put_IsHttpOnly(BOOL)
        put_IsHttpOnly: *const fn (*const ICoreWebView2Cookie, BOOL) callconv(.winapi) HRESULT,
        // Index 12: get_SameSite(COREWEBVIEW2_COOKIE_SAME_SITE_KIND*)
        get_SameSite: *const fn (*const ICoreWebView2Cookie, *COREWEBVIEW2_COOKIE_SAME_SITE_KIND) callconv(.winapi) HRESULT,
        // Index 13: put_SameSite(COREWEBVIEW2_COOKIE_SAME_SITE_KIND)
        put_SameSite: *const fn (*const ICoreWebView2Cookie, COREWEBVIEW2_COOKIE_SAME_SITE_KIND) callconv(.winapi) HRESULT,
        // Index 14: get_IsSecure(BOOL*)
        get_IsSecure: *const fn (*const ICoreWebView2Cookie, *BOOL) callconv(.winapi) HRESULT,
        // Index 15: put_IsSecure(BOOL)
        put_IsSecure: *const fn (*const ICoreWebView2Cookie, BOOL) callconv(.winapi) HRESULT,
        // Index 16: get_IsSession(BOOL*)
        get_IsSession: *const fn (*const ICoreWebView2Cookie, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Cookie) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Cookie) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2CookieList ────────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2CookieList = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f7f6f714-5d2a-43c6-9503-346ece02d186}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2CookieList, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2CookieList) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2CookieList) callconv(.winapi) u32,
        // Index 3: get_Count(UINT32*)
        get_Count: *const fn (*const ICoreWebView2CookieList, *u32) callconv(.winapi) HRESULT,
        // Index 4: GetValueAtIndex(UINT32, ICoreWebView2Cookie**)
        GetValueAtIndex: *const fn (*const ICoreWebView2CookieList, u32, *?*ICoreWebView2Cookie) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2CookieList) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2CookieList) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2DownloadStartingEventArgs ─────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2DownloadStartingEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e99bbe21-43e9-4544-a732-282764eafa60}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2DownloadStartingEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2DownloadStartingEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2DownloadStartingEventArgs) callconv(.winapi) u32,
        // Index 3: get_DownloadOperation(ICoreWebView2DownloadOperation**)
        get_DownloadOperation: *const fn (*const ICoreWebView2DownloadStartingEventArgs, *?*ICoreWebView2DownloadOperation) callconv(.winapi) HRESULT,
        // Index 4: get_Cancel(BOOL*)
        get_Cancel: *const fn (*const ICoreWebView2DownloadStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: put_Cancel(BOOL)
        put_Cancel: *const fn (*const ICoreWebView2DownloadStartingEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 6: get_ResultFilePath(LPWSTR*)
        get_ResultFilePath: *const fn (*const ICoreWebView2DownloadStartingEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 7: put_ResultFilePath(LPCWSTR)
        put_ResultFilePath: *const fn (*const ICoreWebView2DownloadStartingEventArgs, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_Handled(BOOL*)
        get_Handled: *const fn (*const ICoreWebView2DownloadStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 9: put_Handled(BOOL)
        put_Handled: *const fn (*const ICoreWebView2DownloadStartingEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 10: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2DownloadStartingEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2DownloadStartingEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2DownloadStartingEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2DownloadOperation ─────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-21.

pub const ICoreWebView2DownloadOperation = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{3d6b6cf2-afe1-44c7-a995-c65117714336}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2DownloadOperation, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2DownloadOperation) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2DownloadOperation) callconv(.winapi) u32,
        // Index 3: add_BytesReceivedChanged(ICoreWebView2BytesReceivedChangedEventHandler*, EventRegistrationToken*)
        add_BytesReceivedChanged: *const fn (*const ICoreWebView2DownloadOperation, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 4: remove_BytesReceivedChanged(EventRegistrationToken)
        remove_BytesReceivedChanged: *const fn (*const ICoreWebView2DownloadOperation, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 5: add_EstimatedEndTimeChanged(ICoreWebView2EstimatedEndTimeChangedEventHandler*, EventRegistrationToken*)
        add_EstimatedEndTimeChanged: *const fn (*const ICoreWebView2DownloadOperation, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 6: remove_EstimatedEndTimeChanged(EventRegistrationToken)
        remove_EstimatedEndTimeChanged: *const fn (*const ICoreWebView2DownloadOperation, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 7: add_StateChanged(ICoreWebView2StateChangedEventHandler*, EventRegistrationToken*)
        add_StateChanged: *const fn (*const ICoreWebView2DownloadOperation, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 8: remove_StateChanged(EventRegistrationToken)
        remove_StateChanged: *const fn (*const ICoreWebView2DownloadOperation, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 9: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2DownloadOperation, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 10: get_ContentDisposition(LPWSTR*)
        get_ContentDisposition: *const fn (*const ICoreWebView2DownloadOperation, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 11: get_MimeType(LPWSTR*)
        get_MimeType: *const fn (*const ICoreWebView2DownloadOperation, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 12: get_TotalBytesToReceive(INT64*)
        get_TotalBytesToReceive: *const fn (*const ICoreWebView2DownloadOperation, *i64) callconv(.winapi) HRESULT,
        // Index 13: get_BytesReceived(INT64*)
        get_BytesReceived: *const fn (*const ICoreWebView2DownloadOperation, *i64) callconv(.winapi) HRESULT,
        // Index 14: get_EstimatedEndTime(LPWSTR*)
        get_EstimatedEndTime: *const fn (*const ICoreWebView2DownloadOperation, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 15: get_ResultFilePath(LPWSTR*)
        get_ResultFilePath: *const fn (*const ICoreWebView2DownloadOperation, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 16: get_State(COREWEBVIEW2_DOWNLOAD_STATE*)
        get_State: *const fn (*const ICoreWebView2DownloadOperation, *COREWEBVIEW2_DOWNLOAD_STATE) callconv(.winapi) HRESULT,
        // Index 17: get_InterruptReason(COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON*)
        get_InterruptReason: *const fn (*const ICoreWebView2DownloadOperation, *COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON) callconv(.winapi) HRESULT,
        // Index 18: Cancel()
        Cancel: *const fn (*const ICoreWebView2DownloadOperation) callconv(.winapi) HRESULT,
        // Index 19: Pause()
        Pause: *const fn (*const ICoreWebView2DownloadOperation) callconv(.winapi) HRESULT,
        // Index 20: Resume()
        Resume: *const fn (*const ICoreWebView2DownloadOperation) callconv(.winapi) HRESULT,
        // Index 21: get_CanResume(BOOL*)
        get_CanResume: *const fn (*const ICoreWebView2DownloadOperation, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2DownloadOperation) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2DownloadOperation) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2FrameCreatedEventArgs ─────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-3.

pub const ICoreWebView2FrameCreatedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{4d6e7b5e-9baa-11eb-a8b3-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2FrameCreatedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2FrameCreatedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2FrameCreatedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Frame(ICoreWebView2Frame**)
        get_Frame: *const fn (*const ICoreWebView2FrameCreatedEventArgs, *?*ICoreWebView2Frame) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2FrameCreatedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2FrameCreatedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2Frame ─────────────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2Frame = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f1131a5e-9ba9-11eb-a8b3-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Frame, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Frame) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Frame) callconv(.winapi) u32,
        // Index 3: get_Name(LPWSTR*)
        get_Name: *const fn (*const ICoreWebView2Frame, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: add_NameChanged(ICoreWebView2FrameNameChangedEventHandler*, EventRegistrationToken*)
        add_NameChanged: *const fn (*const ICoreWebView2Frame, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 5: remove_NameChanged(EventRegistrationToken)
        remove_NameChanged: *const fn (*const ICoreWebView2Frame, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 6: AddHostObjectToScriptWithOrigins(LPCWSTR, VARIANT*, UINT32, LPCWSTR*)
        AddHostObjectToScriptWithOrigins: *const fn (*const ICoreWebView2Frame, ?LPCWSTR, ?*anyopaque, u32, *?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 7: RemoveHostObjectFromScript(LPCWSTR)
        RemoveHostObjectFromScript: *const fn (*const ICoreWebView2Frame, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 8: add_Destroyed(ICoreWebView2FrameDestroyedEventHandler*, EventRegistrationToken*)
        add_Destroyed: *const fn (*const ICoreWebView2Frame, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 9: remove_Destroyed(EventRegistrationToken)
        remove_Destroyed: *const fn (*const ICoreWebView2Frame, EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 10: IsDestroyed(BOOL*)
        IsDestroyed: *const fn (*const ICoreWebView2Frame, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Frame) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Frame) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ClientCertificateRequestedEventArgs ───────────────────
// Inherits IUnknown (slots 0-2); own slots 3-14.

pub const ICoreWebView2ClientCertificateRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{bc59db28-bcc3-11eb-8529-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Host(LPWSTR*)
        get_Host: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Port(int*)
        get_Port: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *i32) callconv(.winapi) HRESULT,
        // Index 5: get_IsProxy(BOOL*)
        get_IsProxy: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: get_AllowedCertificateAuthorities(ICoreWebView2StringCollection**)
        get_AllowedCertificateAuthorities: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *?*ICoreWebView2StringCollection) callconv(.winapi) HRESULT,
        // Index 7: get_MutuallyTrustedCertificates(ICoreWebView2ClientCertificateCollection**)
        get_MutuallyTrustedCertificates: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *?*ICoreWebView2ClientCertificateCollection) callconv(.winapi) HRESULT,
        // Index 8: get_SelectedCertificate(ICoreWebView2ClientCertificate**)
        get_SelectedCertificate: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *?*ICoreWebView2ClientCertificate) callconv(.winapi) HRESULT,
        // Index 9: put_SelectedCertificate(ICoreWebView2ClientCertificate*)
        put_SelectedCertificate: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, ?*ICoreWebView2ClientCertificate) callconv(.winapi) HRESULT,
        // Index 10: get_Cancel(BOOL*)
        get_Cancel: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 11: put_Cancel(BOOL)
        put_Cancel: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 12: get_Handled(BOOL*)
        get_Handled: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 13: put_Handled(BOOL)
        put_Handled: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 14: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2ClientCertificateRequestedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ClientCertificateRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ClientCertificateRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ClientCertificateCollection ───────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2ClientCertificateCollection = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{ef5674d2-bcc3-11eb-8529-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ClientCertificateCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ClientCertificateCollection) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ClientCertificateCollection) callconv(.winapi) u32,
        // Index 3: get_Count(UINT32*)
        get_Count: *const fn (*const ICoreWebView2ClientCertificateCollection, *u32) callconv(.winapi) HRESULT,
        // Index 4: GetValueAtIndex(UINT32, ICoreWebView2ClientCertificate**)
        GetValueAtIndex: *const fn (*const ICoreWebView2ClientCertificateCollection, u32, *?*ICoreWebView2ClientCertificate) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ClientCertificateCollection) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ClientCertificateCollection) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ClientCertificate ─────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-11.

pub const ICoreWebView2ClientCertificate = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{e7188076-bcc3-11eb-8529-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ClientCertificate, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ClientCertificate) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ClientCertificate) callconv(.winapi) u32,
        // Index 3: get_Subject(LPWSTR*)
        get_Subject: *const fn (*const ICoreWebView2ClientCertificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Issuer(LPWSTR*)
        get_Issuer: *const fn (*const ICoreWebView2ClientCertificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_ValidFrom(double*)
        get_ValidFrom: *const fn (*const ICoreWebView2ClientCertificate, *f64) callconv(.winapi) HRESULT,
        // Index 6: get_ValidTo(double*)
        get_ValidTo: *const fn (*const ICoreWebView2ClientCertificate, *f64) callconv(.winapi) HRESULT,
        // Index 7: get_DerEncodedSerialNumber(LPWSTR*)
        get_DerEncodedSerialNumber: *const fn (*const ICoreWebView2ClientCertificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_DisplayName(LPWSTR*)
        get_DisplayName: *const fn (*const ICoreWebView2ClientCertificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 9: ToPemEncoding(LPWSTR*)
        ToPemEncoding: *const fn (*const ICoreWebView2ClientCertificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 10: get_PemEncodedIssuerCertificateChain(ICoreWebView2StringCollection**)
        get_PemEncodedIssuerCertificateChain: *const fn (*const ICoreWebView2ClientCertificate, *?*ICoreWebView2StringCollection) callconv(.winapi) HRESULT,
        // Index 11: get_Kind(COREWEBVIEW2_CLIENT_CERTIFICATE_KIND*)
        get_Kind: *const fn (*const ICoreWebView2ClientCertificate, *COREWEBVIEW2_CLIENT_CERTIFICATE_KIND) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ClientCertificate) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ClientCertificate) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2StringCollection ──────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2StringCollection = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f41f3f8a-bcc3-11eb-8529-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2StringCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2StringCollection) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2StringCollection) callconv(.winapi) u32,
        // Index 3: get_Count(UINT32*)
        get_Count: *const fn (*const ICoreWebView2StringCollection, *u32) callconv(.winapi) HRESULT,
        // Index 4: GetValueAtIndex(UINT32, LPWSTR*)
        GetValueAtIndex: *const fn (*const ICoreWebView2StringCollection, u32, *?LPWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2StringCollection) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2StringCollection) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2BasicAuthenticationRequestedEventArgs ─────────────────
// Inherits IUnknown (slots 0-2); own slots 3-8.

pub const ICoreWebView2BasicAuthenticationRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{ef05516f-d897-4f9e-b672-d8e2307a3fb0}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_Uri(LPWSTR*)
        get_Uri: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Challenge(LPWSTR*)
        get_Challenge: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_Response(ICoreWebView2BasicAuthenticationResponse**)
        get_Response: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, *?*ICoreWebView2BasicAuthenticationResponse) callconv(.winapi) HRESULT,
        // Index 6: get_Cancel(BOOL*)
        get_Cancel: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 7: put_Cancel(BOOL)
        put_Cancel: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 8: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2BasicAuthenticationRequestedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2BasicAuthenticationRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2BasicAuthenticationRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2BasicAuthenticationResponse ───────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-6.

pub const ICoreWebView2BasicAuthenticationResponse = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{07023f7d-2d77-4d67-9040-6e7d428c6a40}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2BasicAuthenticationResponse, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2BasicAuthenticationResponse) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2BasicAuthenticationResponse) callconv(.winapi) u32,
        // Index 3: get_UserName(LPWSTR*)
        get_UserName: *const fn (*const ICoreWebView2BasicAuthenticationResponse, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: put_UserName(LPCWSTR)
        put_UserName: *const fn (*const ICoreWebView2BasicAuthenticationResponse, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_Password(LPWSTR*)
        get_Password: *const fn (*const ICoreWebView2BasicAuthenticationResponse, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: put_Password(LPCWSTR)
        put_Password: *const fn (*const ICoreWebView2BasicAuthenticationResponse, ?LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2BasicAuthenticationResponse) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2BasicAuthenticationResponse) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ContextMenuRequestedEventArgs ─────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2ContextMenuRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{a1d309ee-c03f-11eb-8529-0242ac130003}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs) callconv(.winapi) u32,
        // Index 3: get_MenuItems(ICoreWebView2ContextMenuItemCollection**)
        get_MenuItems: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *?*ICoreWebView2ContextMenuItemCollection) callconv(.winapi) HRESULT,
        // Index 4: get_ContextMenuTarget(ICoreWebView2ContextMenuTarget**)
        get_ContextMenuTarget: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *?*ICoreWebView2ContextMenuTarget) callconv(.winapi) HRESULT,
        // Index 5: get_Location(POINT*)
        get_Location: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *POINT) callconv(.winapi) HRESULT,
        // Index 6: put_SelectedCommandId(INT32)
        put_SelectedCommandId: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, i32) callconv(.winapi) HRESULT,
        // Index 7: get_SelectedCommandId(INT32*)
        get_SelectedCommandId: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *i32) callconv(.winapi) HRESULT,
        // Index 8: put_Handled(BOOL)
        put_Handled: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
        // Index 9: get_Handled(BOOL*)
        get_Handled: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        // Index 10: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2ContextMenuRequestedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ContextMenuRequestedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ContextMenuRequestedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ContextMenuItemCollection ─────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-6.

pub const ICoreWebView2ContextMenuItemCollection = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{f562a2f5-c415-45cf-b909-d4b7c1e276d3}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ContextMenuItemCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ContextMenuItemCollection) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ContextMenuItemCollection) callconv(.winapi) u32,
        // Index 3: get_Count(UINT32*)
        get_Count: *const fn (*const ICoreWebView2ContextMenuItemCollection, *u32) callconv(.winapi) HRESULT,
        // Index 4: GetValueAtIndex(UINT32, ICoreWebView2ContextMenuItem**)
        GetValueAtIndex: *const fn (*const ICoreWebView2ContextMenuItemCollection, u32, *?*ICoreWebView2ContextMenuItem) callconv(.winapi) HRESULT,
        // Index 5: RemoveValueAtIndex(UINT32)
        RemoveValueAtIndex: *const fn (*const ICoreWebView2ContextMenuItemCollection, u32) callconv(.winapi) HRESULT,
        // Index 6: InsertValueAtIndex(UINT32, ICoreWebView2ContextMenuItem*)
        InsertValueAtIndex: *const fn (*const ICoreWebView2ContextMenuItemCollection, u32, ?*ICoreWebView2ContextMenuItem) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ContextMenuItemCollection) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ContextMenuItemCollection) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ContextMenuItem ───────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-15.

pub const ICoreWebView2ContextMenuItem = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{7aed49e3-a93f-497a-811c-749c6b6b6c65}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ContextMenuItem, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ContextMenuItem) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ContextMenuItem) callconv(.winapi) u32,
        // Index 3: get_Name(LPWSTR*)
        get_Name: *const fn (*const ICoreWebView2ContextMenuItem, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Label(LPWSTR*)
        get_Label: *const fn (*const ICoreWebView2ContextMenuItem, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_CommandId(INT32*)
        get_CommandId: *const fn (*const ICoreWebView2ContextMenuItem, *i32) callconv(.winapi) HRESULT,
        // Index 6: get_ShortcutKeyDescription(LPWSTR*)
        get_ShortcutKeyDescription: *const fn (*const ICoreWebView2ContextMenuItem, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 7: get_Icon(IStream**)
        get_Icon: *const fn (*const ICoreWebView2ContextMenuItem, *?*anyopaque) callconv(.winapi) HRESULT,
        // Index 8: get_Kind(COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND*)
        get_Kind: *const fn (*const ICoreWebView2ContextMenuItem, *COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND) callconv(.winapi) HRESULT,
        // Index 9: put_IsEnabled(BOOL)
        put_IsEnabled: *const fn (*const ICoreWebView2ContextMenuItem, BOOL) callconv(.winapi) HRESULT,
        // Index 10: get_IsEnabled(BOOL*)
        get_IsEnabled: *const fn (*const ICoreWebView2ContextMenuItem, *BOOL) callconv(.winapi) HRESULT,
        // Index 11: put_IsChecked(BOOL)
        put_IsChecked: *const fn (*const ICoreWebView2ContextMenuItem, BOOL) callconv(.winapi) HRESULT,
        // Index 12: get_IsChecked(BOOL*)
        get_IsChecked: *const fn (*const ICoreWebView2ContextMenuItem, *BOOL) callconv(.winapi) HRESULT,
        // Index 13: get_Children(ICoreWebView2ContextMenuItemCollection**)
        get_Children: *const fn (*const ICoreWebView2ContextMenuItem, *?*ICoreWebView2ContextMenuItemCollection) callconv(.winapi) HRESULT,
        // Index 14: add_CustomItemSelected(ICoreWebView2CustomItemSelectedEventHandler*, EventRegistrationToken*)
        add_CustomItemSelected: *const fn (*const ICoreWebView2ContextMenuItem, ?*anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        // Index 15: remove_CustomItemSelected(EventRegistrationToken)
        remove_CustomItemSelected: *const fn (*const ICoreWebView2ContextMenuItem, EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ContextMenuItem) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ContextMenuItem) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ContextMenuTarget ─────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-15.

pub const ICoreWebView2ContextMenuTarget = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{b8611d99-eed6-4f3f-902c-a198502ad472}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ContextMenuTarget, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ContextMenuTarget) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ContextMenuTarget) callconv(.winapi) u32,
        // Index 3: get_Kind(COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND*)
        get_Kind: *const fn (*const ICoreWebView2ContextMenuTarget, *COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND) callconv(.winapi) HRESULT,
        // Index 4: get_IsEditable(BOOL*)
        get_IsEditable: *const fn (*const ICoreWebView2ContextMenuTarget, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: get_IsRequestedForMainFrame(BOOL*)
        get_IsRequestedForMainFrame: *const fn (*const ICoreWebView2ContextMenuTarget, *BOOL) callconv(.winapi) HRESULT,
        // Index 6: get_PageUri(LPWSTR*)
        get_PageUri: *const fn (*const ICoreWebView2ContextMenuTarget, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 7: get_FrameUri(LPWSTR*)
        get_FrameUri: *const fn (*const ICoreWebView2ContextMenuTarget, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_HasLinkUri(BOOL*)
        get_HasLinkUri: *const fn (*const ICoreWebView2ContextMenuTarget, *BOOL) callconv(.winapi) HRESULT,
        // Index 9: get_LinkUri(LPWSTR*)
        get_LinkUri: *const fn (*const ICoreWebView2ContextMenuTarget, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 10: get_HasLinkText(BOOL*)
        get_HasLinkText: *const fn (*const ICoreWebView2ContextMenuTarget, *BOOL) callconv(.winapi) HRESULT,
        // Index 11: get_LinkText(LPWSTR*)
        get_LinkText: *const fn (*const ICoreWebView2ContextMenuTarget, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 12: get_HasSourceUri(BOOL*)
        get_HasSourceUri: *const fn (*const ICoreWebView2ContextMenuTarget, *BOOL) callconv(.winapi) HRESULT,
        // Index 13: get_SourceUri(LPWSTR*)
        get_SourceUri: *const fn (*const ICoreWebView2ContextMenuTarget, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 14: get_HasSelection(BOOL*)
        get_HasSelection: *const fn (*const ICoreWebView2ContextMenuTarget, *BOOL) callconv(.winapi) HRESULT,
        // Index 15: get_SelectionText(LPWSTR*)
        get_SelectionText: *const fn (*const ICoreWebView2ContextMenuTarget, *?LPWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ContextMenuTarget) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ContextMenuTarget) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ServerCertificateErrorDetectedEventArgs ───────────────
// Inherits IUnknown (slots 0-2); own slots 3-8.

pub const ICoreWebView2ServerCertificateErrorDetectedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{012193ed-7c13-48ff-969d-a84c1f432a14}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs) callconv(.winapi) u32,
        // Index 3: get_ErrorStatus(COREWEBVIEW2_WEB_ERROR_STATUS*)
        get_ErrorStatus: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, *COREWEBVIEW2_WEB_ERROR_STATUS) callconv(.winapi) HRESULT,
        // Index 4: get_RequestUri(LPWSTR*)
        get_RequestUri: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_ServerCertificate(ICoreWebView2Certificate**)
        get_ServerCertificate: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, *?*ICoreWebView2Certificate) callconv(.winapi) HRESULT,
        // Index 6: get_Action(COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION*)
        get_Action: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, *COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION) callconv(.winapi) HRESULT,
        // Index 7: put_Action(COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION)
        put_Action: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION) callconv(.winapi) HRESULT,
        // Index 8: GetDeferral(ICoreWebView2Deferral**)
        GetDeferral: *const fn (*const ICoreWebView2ServerCertificateErrorDetectedEventArgs, *?*ICoreWebView2Deferral) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ServerCertificateErrorDetectedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ServerCertificateErrorDetectedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2Certificate ───────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-10.

pub const ICoreWebView2Certificate = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{c5fb2fce-1cac-4aee-9c79-5ed0362eaae0}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Certificate, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Certificate) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Certificate) callconv(.winapi) u32,
        // Index 3: get_Subject(LPWSTR*)
        get_Subject: *const fn (*const ICoreWebView2Certificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_Issuer(LPWSTR*)
        get_Issuer: *const fn (*const ICoreWebView2Certificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 5: get_ValidFrom(double*)
        get_ValidFrom: *const fn (*const ICoreWebView2Certificate, *f64) callconv(.winapi) HRESULT,
        // Index 6: get_ValidTo(double*)
        get_ValidTo: *const fn (*const ICoreWebView2Certificate, *f64) callconv(.winapi) HRESULT,
        // Index 7: get_DerEncodedSerialNumber(LPWSTR*)
        get_DerEncodedSerialNumber: *const fn (*const ICoreWebView2Certificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_DisplayName(LPWSTR*)
        get_DisplayName: *const fn (*const ICoreWebView2Certificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 9: ToPemEncoding(LPWSTR*)
        ToPemEncoding: *const fn (*const ICoreWebView2Certificate, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 10: get_PemEncodedIssuerCertificateChain(ICoreWebView2StringCollection**)
        get_PemEncodedIssuerCertificateChain: *const fn (*const ICoreWebView2Certificate, *?*ICoreWebView2StringCollection) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Certificate) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Certificate) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2Profile ───────────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-9.

pub const ICoreWebView2Profile = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{79110ad3-cd5d-4373-8bc3-c60658f17a5f}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2Profile, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2Profile) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2Profile) callconv(.winapi) u32,
        // Index 3: get_ProfileName(LPWSTR*)
        get_ProfileName: *const fn (*const ICoreWebView2Profile, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 4: get_IsInPrivateModeEnabled(BOOL*)
        get_IsInPrivateModeEnabled: *const fn (*const ICoreWebView2Profile, *BOOL) callconv(.winapi) HRESULT,
        // Index 5: get_ProfilePath(LPWSTR*)
        get_ProfilePath: *const fn (*const ICoreWebView2Profile, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 6: get_DefaultDownloadFolderPath(LPWSTR*)
        get_DefaultDownloadFolderPath: *const fn (*const ICoreWebView2Profile, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 7: put_DefaultDownloadFolderPath(LPCWSTR)
        put_DefaultDownloadFolderPath: *const fn (*const ICoreWebView2Profile, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 8: get_PreferredColorScheme(COREWEBVIEW2_PREFERRED_COLOR_SCHEME*)
        get_PreferredColorScheme: *const fn (*const ICoreWebView2Profile, *COREWEBVIEW2_PREFERRED_COLOR_SCHEME) callconv(.winapi) HRESULT,
        // Index 9: put_PreferredColorScheme(COREWEBVIEW2_PREFERRED_COLOR_SCHEME)
        put_PreferredColorScheme: *const fn (*const ICoreWebView2Profile, COREWEBVIEW2_PREFERRED_COLOR_SCHEME) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Profile) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2Profile) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2PrintSettings ─────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-28.

pub const ICoreWebView2PrintSettings = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{377f3721-c74e-48ca-8db1-df68e51d60e2}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2PrintSettings, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2PrintSettings) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2PrintSettings) callconv(.winapi) u32,
        // Index 3: get_Orientation(COREWEBVIEW2_PRINT_ORIENTATION*)
        get_Orientation: *const fn (*const ICoreWebView2PrintSettings, *COREWEBVIEW2_PRINT_ORIENTATION) callconv(.winapi) HRESULT,
        // Index 4: put_Orientation(COREWEBVIEW2_PRINT_ORIENTATION)
        put_Orientation: *const fn (*const ICoreWebView2PrintSettings, COREWEBVIEW2_PRINT_ORIENTATION) callconv(.winapi) HRESULT,
        // Index 5: get_ScaleFactor(double*)
        get_ScaleFactor: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 6: put_ScaleFactor(double)
        put_ScaleFactor: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 7: get_PageWidth(double*)
        get_PageWidth: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 8: put_PageWidth(double)
        put_PageWidth: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 9: get_PageHeight(double*)
        get_PageHeight: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 10: put_PageHeight(double)
        put_PageHeight: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 11: get_MarginTop(double*)
        get_MarginTop: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 12: put_MarginTop(double)
        put_MarginTop: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 13: get_MarginBottom(double*)
        get_MarginBottom: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 14: put_MarginBottom(double)
        put_MarginBottom: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 15: get_MarginLeft(double*)
        get_MarginLeft: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 16: put_MarginLeft(double)
        put_MarginLeft: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 17: get_MarginRight(double*)
        get_MarginRight: *const fn (*const ICoreWebView2PrintSettings, *f64) callconv(.winapi) HRESULT,
        // Index 18: put_MarginRight(double)
        put_MarginRight: *const fn (*const ICoreWebView2PrintSettings, f64) callconv(.winapi) HRESULT,
        // Index 19: get_ShouldPrintBackgrounds(BOOL*)
        get_ShouldPrintBackgrounds: *const fn (*const ICoreWebView2PrintSettings, *BOOL) callconv(.winapi) HRESULT,
        // Index 20: put_ShouldPrintBackgrounds(BOOL)
        put_ShouldPrintBackgrounds: *const fn (*const ICoreWebView2PrintSettings, BOOL) callconv(.winapi) HRESULT,
        // Index 21: get_ShouldPrintSelectionOnly(BOOL*)
        get_ShouldPrintSelectionOnly: *const fn (*const ICoreWebView2PrintSettings, *BOOL) callconv(.winapi) HRESULT,
        // Index 22: put_ShouldPrintSelectionOnly(BOOL)
        put_ShouldPrintSelectionOnly: *const fn (*const ICoreWebView2PrintSettings, BOOL) callconv(.winapi) HRESULT,
        // Index 23: get_ShouldPrintHeaderAndFooter(BOOL*)
        get_ShouldPrintHeaderAndFooter: *const fn (*const ICoreWebView2PrintSettings, *BOOL) callconv(.winapi) HRESULT,
        // Index 24: put_ShouldPrintHeaderAndFooter(BOOL)
        put_ShouldPrintHeaderAndFooter: *const fn (*const ICoreWebView2PrintSettings, BOOL) callconv(.winapi) HRESULT,
        // Index 25: get_HeaderTitle(LPWSTR*)
        get_HeaderTitle: *const fn (*const ICoreWebView2PrintSettings, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 26: put_HeaderTitle(LPCWSTR)
        put_HeaderTitle: *const fn (*const ICoreWebView2PrintSettings, ?LPCWSTR) callconv(.winapi) HRESULT,
        // Index 27: get_FooterUri(LPWSTR*)
        get_FooterUri: *const fn (*const ICoreWebView2PrintSettings, *?LPWSTR) callconv(.winapi) HRESULT,
        // Index 28: put_FooterUri(LPCWSTR)
        put_FooterUri: *const fn (*const ICoreWebView2PrintSettings, ?LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2PrintSettings) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2PrintSettings) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2BrowserProcessExitedEventArgs ─────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2BrowserProcessExitedEventArgs = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{1f00663f-af8c-4782-9cdd-dd01c52e34cb}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2BrowserProcessExitedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2BrowserProcessExitedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2BrowserProcessExitedEventArgs) callconv(.winapi) u32,
        // Index 3: get_BrowserProcessExitKind(COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND*)
        get_BrowserProcessExitKind: *const fn (*const ICoreWebView2BrowserProcessExitedEventArgs, *COREWEBVIEW2_BROWSER_PROCESS_EXIT_KIND) callconv(.winapi) HRESULT,
        // Index 4: get_BrowserProcessId(UINT32*)
        get_BrowserProcessId: *const fn (*const ICoreWebView2BrowserProcessExitedEventArgs, *u32) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2BrowserProcessExitedEventArgs) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2BrowserProcessExitedEventArgs) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ProcessInfo ───────────────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2ProcessInfo = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{84fa7612-3f3d-4fbf-889d-fad000492d72}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ProcessInfo, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ProcessInfo) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ProcessInfo) callconv(.winapi) u32,
        // Index 3: get_ProcessId(INT32*)
        get_ProcessId: *const fn (*const ICoreWebView2ProcessInfo, *i32) callconv(.winapi) HRESULT,
        // Index 4: get_Kind(COREWEBVIEW2_PROCESS_KIND*)
        get_Kind: *const fn (*const ICoreWebView2ProcessInfo, *COREWEBVIEW2_PROCESS_KIND) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ProcessInfo) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ProcessInfo) void {
        comRelease(self);
    }
};

// ─── ICoreWebView2ProcessInfoCollection ─────────────────────────────────
// Inherits IUnknown (slots 0-2); own slots 3-4.

pub const ICoreWebView2ProcessInfoCollection = extern struct {
    vtable: *const VTable,

    pub const IID = GUID.parse("{402b99cd-a0cc-4fa5-b7a5-51d86a1d2339}");

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const ICoreWebView2ProcessInfoCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*const ICoreWebView2ProcessInfoCollection) callconv(.winapi) u32,
        Release: *const fn (*const ICoreWebView2ProcessInfoCollection) callconv(.winapi) u32,
        // Index 3: get_Count(UINT32*)
        get_Count: *const fn (*const ICoreWebView2ProcessInfoCollection, *u32) callconv(.winapi) HRESULT,
        // Index 4: GetValueAtIndex(UINT32, ICoreWebView2ProcessInfo**)
        GetValueAtIndex: *const fn (*const ICoreWebView2ProcessInfoCollection, u32, *?*ICoreWebView2ProcessInfo) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2ProcessInfoCollection) void {
        comAddRef(self);
    }

    pub fn release(self: *ICoreWebView2ProcessInfoCollection) void {
        comRelease(self);
    }
};

// ─── Host-implemented ICoreWebView2EnvironmentOptions ───────────────────

pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));

/// Allocates strings returned through `LPWSTR*` out-params of host
/// objects (the runtime frees them with CoTaskMemFree).
pub extern "ole32" fn CoTaskMemAlloc(cb: usize) callconv(.winapi) ?*anyopaque;

/// Host object for `Loader.createEnvironmentWithOptions`: carries
/// AdditionalBrowserArguments (proxy flags, spike S5), Language,
/// TargetCompatibleBrowserVersion (defaults to the SDK's target version)
/// and AllowSingleSignOnUsingOSPrimaryAccount. Answers QueryInterface for
/// IUnknown and ICoreWebView2EnvironmentOptions only; the runtime treats
/// the newer EnvironmentOptions2+ as absent. Refcounted like `Handler`:
/// create (refcount 1), pass `interface()`, then `unref()`.
pub const EnvironmentOptions = struct {
    iface: ICoreWebView2EnvironmentOptions = .{ .vtable = &vtable_impl },
    ref_count: u32 = 1,
    alloc: std.mem.Allocator,
    additional_browser_arguments: ?[:0]u16 = null,
    language: ?[:0]u16 = null,
    target_compatible_browser_version: ?[:0]u16 = null,
    allow_single_sign_on: BOOL = FALSE,

    pub const Init = struct {
        /// Extra Chromium switches, e.g. `--proxy-server=...`.
        additional_browser_arguments: ?[]const u8 = null,
        /// BCP 47 UI language, e.g. `en-US`.
        language: ?[]const u8 = null,
        /// null = `iids.target_browser_version` of the bound SDK.
        target_compatible_browser_version: ?[]const u8 = null,
        allow_single_sign_on_using_os_primary_account: bool = false,
    };

    const implemented = iids.comptimeChain("ICoreWebView2EnvironmentOptions");

    const vtable_impl: ICoreWebView2EnvironmentOptions.VTable = .{
        .QueryInterface = implQueryInterface,
        .AddRef = implAddRef,
        .Release = implRelease,
        .get_AdditionalBrowserArguments = getAdditionalBrowserArguments,
        .put_AdditionalBrowserArguments = putAdditionalBrowserArguments,
        .get_Language = getLanguage,
        .put_Language = putLanguage,
        .get_TargetCompatibleBrowserVersion = getTargetCompatibleBrowserVersion,
        .put_TargetCompatibleBrowserVersion = putTargetCompatibleBrowserVersion,
        .get_AllowSingleSignOnUsingOSPrimaryAccount = getAllowSingleSignOn,
        .put_AllowSingleSignOnUsingOSPrimaryAccount = putAllowSingleSignOn,
    };

    /// UTF-8 inputs are converted to owned UTF-16 (error.InvalidUtf8 on
    /// malformed input).
    pub fn create(alloc: std.mem.Allocator, init: Init) !*EnvironmentOptions {
        const self = try alloc.create(EnvironmentOptions);
        self.* = .{ .alloc = alloc };
        errdefer self.destroy();
        self.allow_single_sign_on = if (init.allow_single_sign_on_using_os_primary_account) TRUE else FALSE;
        if (init.additional_browser_arguments) |v|
            self.additional_browser_arguments = try std.unicode.utf8ToUtf16LeAllocZ(alloc, v);
        if (init.language) |v|
            self.language = try std.unicode.utf8ToUtf16LeAllocZ(alloc, v);
        self.target_compatible_browser_version = try std.unicode.utf8ToUtf16LeAllocZ(
            alloc,
            init.target_compatible_browser_version orelse iids.target_browser_version,
        );
        return self;
    }

    /// The COM interface pointer to hand to the loader (borrowed).
    pub fn interface(self: *EnvironmentOptions) *ICoreWebView2EnvironmentOptions {
        return &self.iface;
    }

    /// Drop the creating reference (calls COM Release).
    pub fn unref(self: *EnvironmentOptions) void {
        _ = implRelease(&self.iface);
    }

    fn destroy(self: *EnvironmentOptions) void {
        const alloc = self.alloc;
        if (self.additional_browser_arguments) |v| alloc.free(v);
        if (self.language) |v| alloc.free(v);
        if (self.target_compatible_browser_version) |v| alloc.free(v);
        alloc.destroy(self);
    }

    fn fromIface(this: *const ICoreWebView2EnvironmentOptions) *EnvironmentOptions {
        return @fieldParentPtr("iface", @constCast(this));
    }

    fn implQueryInterface(this: *const ICoreWebView2EnvironmentOptions, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        const r: *const iids.Guid = @ptrCast(riid);
        if (iids.qiMatches(r.*, implemented)) {
            _ = implAddRef(this);
            out.* = @constCast(this);
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn implAddRef(this: *const ICoreWebView2EnvironmentOptions) callconv(.winapi) u32 {
        const self = fromIface(this);
        return @atomicRmw(u32, &self.ref_count, .Add, 1, .monotonic) + 1;
    }

    fn implRelease(this: *const ICoreWebView2EnvironmentOptions) callconv(.winapi) u32 {
        const self = fromIface(this);
        const prev = @atomicRmw(u32, &self.ref_count, .Sub, 1, .acq_rel);
        if (prev == 1) {
            self.destroy();
            return 0;
        }
        return prev - 1;
    }

    /// CoTaskMemAlloc'd copy of `value` (null stays null).
    fn getString(value: ?[:0]u16, out: *?LPWSTR) HRESULT {
        const v = value orelse {
            out.* = null;
            return S_OK;
        };
        const bytes = (v.len + 1) * @sizeOf(u16);
        const raw = CoTaskMemAlloc(bytes) orelse {
            out.* = null;
            return E_OUTOFMEMORY;
        };
        const dst: [*]u16 = @ptrCast(@alignCast(raw));
        @memcpy(dst[0 .. v.len + 1], v[0 .. v.len + 1]);
        out.* = @ptrCast(dst);
        return S_OK;
    }

    /// Replace `field` with an owned copy of `value` (null clears it).
    fn putString(self: *EnvironmentOptions, field: *?[:0]u16, value: ?LPCWSTR) HRESULT {
        var copy: ?[:0]u16 = null;
        if (value) |v| {
            copy = self.alloc.dupeZ(u16, std.mem.span(v)) catch return E_OUTOFMEMORY;
        }
        if (field.*) |old| self.alloc.free(old);
        field.* = copy;
        return S_OK;
    }

    fn getAdditionalBrowserArguments(this: *const ICoreWebView2EnvironmentOptions, out: *?LPWSTR) callconv(.winapi) HRESULT {
        return getString(fromIface(this).additional_browser_arguments, out);
    }

    fn putAdditionalBrowserArguments(this: *const ICoreWebView2EnvironmentOptions, value: ?LPCWSTR) callconv(.winapi) HRESULT {
        const self = fromIface(this);
        return self.putString(&self.additional_browser_arguments, value);
    }

    fn getLanguage(this: *const ICoreWebView2EnvironmentOptions, out: *?LPWSTR) callconv(.winapi) HRESULT {
        return getString(fromIface(this).language, out);
    }

    fn putLanguage(this: *const ICoreWebView2EnvironmentOptions, value: ?LPCWSTR) callconv(.winapi) HRESULT {
        const self = fromIface(this);
        return self.putString(&self.language, value);
    }

    fn getTargetCompatibleBrowserVersion(this: *const ICoreWebView2EnvironmentOptions, out: *?LPWSTR) callconv(.winapi) HRESULT {
        return getString(fromIface(this).target_compatible_browser_version, out);
    }

    fn putTargetCompatibleBrowserVersion(this: *const ICoreWebView2EnvironmentOptions, value: ?LPCWSTR) callconv(.winapi) HRESULT {
        const self = fromIface(this);
        return self.putString(&self.target_compatible_browser_version, value);
    }

    fn getAllowSingleSignOn(this: *const ICoreWebView2EnvironmentOptions, out: *BOOL) callconv(.winapi) HRESULT {
        out.* = fromIface(this).allow_single_sign_on;
        return S_OK;
    }

    fn putAllowSingleSignOn(this: *const ICoreWebView2EnvironmentOptions, value: BOOL) callconv(.winapi) HRESULT {
        fromIface(this).allow_single_sign_on = if (value != FALSE) TRUE else FALSE;
        return S_OK;
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

/// `Handler` for the callback interfaces whose Invoke takes a single
/// argument (CapturePreview and ClearServerCertificateErrorActions
/// completions: `Invoke(HRESULT errorCode)`). Same lifetime rules.
pub fn Handler1(
    comptime iid: GUID,
    comptime Ctx: type,
    comptime Arg0: type,
) type {
    return extern struct {
        const Self = @This();

        pub const Callback = *const fn (ctx: *Ctx, arg0: Arg0) void;

        pub const VTable = extern struct {
            // Index 0
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            // Index 1
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            // Index 2
            Release: *const fn (*Self) callconv(.winapi) u32,
            // Index 3
            Invoke: *const fn (*Self, Arg0) callconv(.winapi) HRESULT,
        };

        vtable: *const VTable,
        ref_count: u32,
        ctx: *Ctx,
        callback: *const anyopaque,
        alloc_ptr: *anyopaque,
        alloc_vtable: *const anyopaque,

        const vtable_impl: VTable = .{
            .QueryInterface = implQueryInterface,
            .AddRef = implAddRef,
            .Release = implRelease,
            .Invoke = implInvoke,
        };

        /// Create a handler with refcount 1 (see `Handler.create`).
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

        fn implInvoke(self: *Self, arg0: Arg0) callconv(.winapi) HRESULT {
            const cb: Callback = @ptrCast(@alignCast(self.callback));
            cb(self.ctx, arg0);
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

/// ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler:
/// Invoke(HRESULT errorCode, LPCWSTR result)
pub fn AddScriptToExecuteOnDocumentCreatedCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler,
        Ctx,
        HRESULT,
        ?LPCWSTR,
    );
}

/// ICoreWebView2BasicAuthenticationRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2BasicAuthenticationRequestedEventArgs* args)
pub fn BasicAuthenticationRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2BasicAuthenticationRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2BasicAuthenticationRequestedEventArgs,
    );
}

/// ICoreWebView2BrowserProcessExitedEventHandler:
/// Invoke(ICoreWebView2Environment* sender, ICoreWebView2BrowserProcessExitedEventArgs* args)
pub fn BrowserProcessExitedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2BrowserProcessExitedEventHandler,
        Ctx,
        ?*ICoreWebView2Environment,
        ?*ICoreWebView2BrowserProcessExitedEventArgs,
    );
}

/// ICoreWebView2BytesReceivedChangedEventHandler:
/// Invoke(ICoreWebView2DownloadOperation* sender, IUnknown* args)
pub fn BytesReceivedChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2BytesReceivedChangedEventHandler,
        Ctx,
        ?*ICoreWebView2DownloadOperation,
        ?*IUnknown,
    );
}

/// ICoreWebView2CapturePreviewCompletedHandler:
/// Invoke(HRESULT errorCode)
pub fn CapturePreviewCompletedHandler(comptime Ctx: type) type {
    return Handler1(
        IID_ICoreWebView2CapturePreviewCompletedHandler,
        Ctx,
        HRESULT,
    );
}

/// ICoreWebView2ClearServerCertificateErrorActionsCompletedHandler:
/// Invoke(HRESULT errorCode)
pub fn ClearServerCertificateErrorActionsCompletedHandler(comptime Ctx: type) type {
    return Handler1(
        IID_ICoreWebView2ClearServerCertificateErrorActionsCompletedHandler,
        Ctx,
        HRESULT,
    );
}

/// ICoreWebView2ClientCertificateRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2ClientCertificateRequestedEventArgs* args)
pub fn ClientCertificateRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ClientCertificateRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2ClientCertificateRequestedEventArgs,
    );
}

/// ICoreWebView2ContainsFullScreenElementChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn ContainsFullScreenElementChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ContainsFullScreenElementChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2ContentLoadingEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2ContentLoadingEventArgs* args)
pub fn ContentLoadingEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ContentLoadingEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2ContentLoadingEventArgs,
    );
}

/// ICoreWebView2ContextMenuRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2ContextMenuRequestedEventArgs* args)
pub fn ContextMenuRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ContextMenuRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2ContextMenuRequestedEventArgs,
    );
}

/// ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler:
/// Invoke(HRESULT errorCode, ICoreWebView2CompositionController* result)
pub fn CreateCoreWebView2CompositionControllerCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler,
        Ctx,
        HRESULT,
        ?*anyopaque,
    );
}

/// ICoreWebView2CustomItemSelectedEventHandler:
/// Invoke(ICoreWebView2ContextMenuItem* sender, IUnknown* args)
pub fn CustomItemSelectedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2CustomItemSelectedEventHandler,
        Ctx,
        ?*ICoreWebView2ContextMenuItem,
        ?*IUnknown,
    );
}

/// ICoreWebView2DOMContentLoadedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2DOMContentLoadedEventArgs* args)
pub fn DOMContentLoadedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2DOMContentLoadedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2DOMContentLoadedEventArgs,
    );
}

/// ICoreWebView2DownloadStartingEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2DownloadStartingEventArgs* args)
pub fn DownloadStartingEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2DownloadStartingEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2DownloadStartingEventArgs,
    );
}

/// ICoreWebView2EstimatedEndTimeChangedEventHandler:
/// Invoke(ICoreWebView2DownloadOperation* sender, IUnknown* args)
pub fn EstimatedEndTimeChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2EstimatedEndTimeChangedEventHandler,
        Ctx,
        ?*ICoreWebView2DownloadOperation,
        ?*IUnknown,
    );
}

/// ICoreWebView2FaviconChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn FaviconChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2FaviconChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2FrameCreatedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2FrameCreatedEventArgs* args)
pub fn FrameCreatedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2FrameCreatedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2FrameCreatedEventArgs,
    );
}

/// ICoreWebView2FrameDestroyedEventHandler:
/// Invoke(ICoreWebView2Frame* sender, IUnknown* args)
pub fn FrameDestroyedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2FrameDestroyedEventHandler,
        Ctx,
        ?*ICoreWebView2Frame,
        ?*IUnknown,
    );
}

/// ICoreWebView2FrameNameChangedEventHandler:
/// Invoke(ICoreWebView2Frame* sender, IUnknown* args)
pub fn FrameNameChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2FrameNameChangedEventHandler,
        Ctx,
        ?*ICoreWebView2Frame,
        ?*IUnknown,
    );
}

/// ICoreWebView2GetCookiesCompletedHandler:
/// Invoke(HRESULT errorCode, ICoreWebView2CookieList* result)
pub fn GetCookiesCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2GetCookiesCompletedHandler,
        Ctx,
        HRESULT,
        ?*ICoreWebView2CookieList,
    );
}

/// ICoreWebView2GetFaviconCompletedHandler:
/// Invoke(HRESULT errorCode, IStream* result)
pub fn GetFaviconCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2GetFaviconCompletedHandler,
        Ctx,
        HRESULT,
        ?*anyopaque,
    );
}

/// ICoreWebView2HistoryChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn HistoryChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2HistoryChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2IsDefaultDownloadDialogOpenChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn IsDefaultDownloadDialogOpenChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2IsDefaultDownloadDialogOpenChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2IsDocumentPlayingAudioChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn IsDocumentPlayingAudioChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2IsDocumentPlayingAudioChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2IsMutedChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn IsMutedChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2IsMutedChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2MoveFocusRequestedEventHandler:
/// Invoke(ICoreWebView2Controller* sender, ICoreWebView2MoveFocusRequestedEventArgs* args)
pub fn MoveFocusRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2MoveFocusRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2Controller,
        ?*ICoreWebView2MoveFocusRequestedEventArgs,
    );
}

/// ICoreWebView2NavigationStartingEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2NavigationStartingEventArgs* args)
pub fn NavigationStartingEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2NavigationStartingEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2NavigationStartingEventArgs,
    );
}

/// ICoreWebView2NewBrowserVersionAvailableEventHandler:
/// Invoke(ICoreWebView2Environment* sender, IUnknown* args)
pub fn NewBrowserVersionAvailableEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2NewBrowserVersionAvailableEventHandler,
        Ctx,
        ?*ICoreWebView2Environment,
        ?*IUnknown,
    );
}

/// ICoreWebView2NewWindowRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2NewWindowRequestedEventArgs* args)
pub fn NewWindowRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2NewWindowRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2NewWindowRequestedEventArgs,
    );
}

/// ICoreWebView2PermissionRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2PermissionRequestedEventArgs* args)
pub fn PermissionRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2PermissionRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2PermissionRequestedEventArgs,
    );
}

/// ICoreWebView2PrintCompletedHandler:
/// Invoke(HRESULT errorCode, COREWEBVIEW2_PRINT_STATUS result)
pub fn PrintCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2PrintCompletedHandler,
        Ctx,
        HRESULT,
        COREWEBVIEW2_PRINT_STATUS,
    );
}

/// ICoreWebView2PrintToPdfCompletedHandler:
/// Invoke(HRESULT errorCode, BOOL result)
pub fn PrintToPdfCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2PrintToPdfCompletedHandler,
        Ctx,
        HRESULT,
        BOOL,
    );
}

/// ICoreWebView2PrintToPdfStreamCompletedHandler:
/// Invoke(HRESULT errorCode, IStream* result)
pub fn PrintToPdfStreamCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2PrintToPdfStreamCompletedHandler,
        Ctx,
        HRESULT,
        ?*anyopaque,
    );
}

/// ICoreWebView2ProcessFailedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2ProcessFailedEventArgs* args)
pub fn ProcessFailedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ProcessFailedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2ProcessFailedEventArgs,
    );
}

/// ICoreWebView2ProcessInfosChangedEventHandler:
/// Invoke(ICoreWebView2Environment* sender, IUnknown* args)
pub fn ProcessInfosChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ProcessInfosChangedEventHandler,
        Ctx,
        ?*ICoreWebView2Environment,
        ?*IUnknown,
    );
}

/// ICoreWebView2RasterizationScaleChangedEventHandler:
/// Invoke(ICoreWebView2Controller* sender, IUnknown* args)
pub fn RasterizationScaleChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2RasterizationScaleChangedEventHandler,
        Ctx,
        ?*ICoreWebView2Controller,
        ?*IUnknown,
    );
}

/// ICoreWebView2ScriptDialogOpeningEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2ScriptDialogOpeningEventArgs* args)
pub fn ScriptDialogOpeningEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ScriptDialogOpeningEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2ScriptDialogOpeningEventArgs,
    );
}

/// ICoreWebView2ServerCertificateErrorDetectedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2ServerCertificateErrorDetectedEventArgs* args)
pub fn ServerCertificateErrorDetectedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ServerCertificateErrorDetectedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2ServerCertificateErrorDetectedEventArgs,
    );
}

/// ICoreWebView2SourceChangedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2SourceChangedEventArgs* args)
pub fn SourceChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2SourceChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2SourceChangedEventArgs,
    );
}

/// ICoreWebView2StateChangedEventHandler:
/// Invoke(ICoreWebView2DownloadOperation* sender, IUnknown* args)
pub fn StateChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2StateChangedEventHandler,
        Ctx,
        ?*ICoreWebView2DownloadOperation,
        ?*IUnknown,
    );
}

/// ICoreWebView2StatusBarTextChangedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn StatusBarTextChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2StatusBarTextChangedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2TrySuspendCompletedHandler:
/// Invoke(HRESULT errorCode, BOOL result)
pub fn TrySuspendCompletedHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2TrySuspendCompletedHandler,
        Ctx,
        HRESULT,
        BOOL,
    );
}

/// ICoreWebView2WebMessageReceivedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2WebMessageReceivedEventArgs* args)
pub fn WebMessageReceivedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2WebMessageReceivedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2WebMessageReceivedEventArgs,
    );
}

/// ICoreWebView2WebResourceRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2WebResourceRequestedEventArgs* args)
pub fn WebResourceRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2WebResourceRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*ICoreWebView2WebResourceRequestedEventArgs,
    );
}

/// ICoreWebView2WebResourceResponseReceivedEventHandler:
/// Invoke(ICoreWebView2* sender, ICoreWebView2WebResourceResponseReceivedEventArgs* args)
pub fn WebResourceResponseReceivedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2WebResourceResponseReceivedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*anyopaque,
    );
}

/// ICoreWebView2WindowCloseRequestedEventHandler:
/// Invoke(ICoreWebView2* sender, IUnknown* args)
pub fn WindowCloseRequestedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2WindowCloseRequestedEventHandler,
        Ctx,
        ?*ICoreWebView2,
        ?*IUnknown,
    );
}

/// ICoreWebView2ZoomFactorChangedEventHandler:
/// Invoke(ICoreWebView2Controller* sender, IUnknown* args)
pub fn ZoomFactorChangedEventHandler(comptime Ctx: type) type {
    return Handler(
        IID_ICoreWebView2ZoomFactorChangedEventHandler,
        Ctx,
        ?*ICoreWebView2Controller,
        ?*IUnknown,
    );
}

// ─── Binding verification ───────────────────────────────────────────────
// Runs whenever this file is analyzed: every bound interface struct (a
// decl with `IID` and `VTable`) and every handler `IID_*` constant must
// match its row in the WebView2.h fixture table (IID, slot names at their
// exact indexes, slot count), and every fixture row must be bound.

comptime {
    _ = verifyBindings();
}

const bindings = @This();

/// Number of interface structs and handler IIDs `verifyBindings` checked.
pub const verified_count = verifyBindings();

fn verifyBindings() usize {
    @setEvalBranchQuota(4_000_000);
    var n: usize = 0;
    for (@typeInfo(bindings).@"struct".decls) |d| {
        if (std.mem.startsWith(u8, d.name, "IID_")) {
            const row = iids.find(d.name[4..]) orelse
                @compileError("IID constant without a fixture row: " ++ d.name);
            if (std.mem.endsWith(u8, row.name, "Handler")) {
                verifyIid(@field(bindings, d.name), row);
                n += 1;
            }
        } else if (std.mem.eql(u8, d.name, "IUnknown") or std.mem.startsWith(u8, d.name, "ICoreWebView2")) {
            const T = @field(bindings, d.name);
            const row = iids.find(d.name) orelse
                @compileError("bound interface without a fixture row: " ++ d.name);
            verifyIid(T.IID, row);
            verifyVTable(T.VTable, row);
            n += 1;
        }
    }
    for (iids.entries) |row| {
        const bound = if (std.mem.endsWith(u8, row.name, "Handler"))
            @hasDecl(bindings, "IID_" ++ row.name)
        else
            @hasDecl(bindings, row.name);
        if (!bound) @compileError("fixture row not bound: " ++ row.name);
    }
    if (n != iids.entries.len) @compileError("bound/fixture count mismatch");
    return n;
}

fn verifyIid(comptime got: GUID, comptime row: *const iids.Entry) void {
    const want = iids.Guid.comptimeParse(row.iid);
    if (got.Data1 != want.data1 or got.Data2 != want.data2 or got.Data3 != want.data3 or
        !std.mem.eql(u8, &got.Data4, &want.data4))
        @compileError("IID mismatch with WebView2.h for " ++ row.name);
}

/// Flattens `base` chains and checks each slot's name and index.
fn verifyVTable(comptime VT: type, comptime row: *const iids.Entry) void {
    if (@sizeOf(VT) != @as(usize, row.slot_count) * @sizeOf(usize))
        @compileError("vtable slot count mismatch for " ++ row.name);
    const next = verifySlots(VT, row, 0);
    if (next != row.slot_count) @compileError("vtable slot count mismatch for " ++ row.name);
}

fn verifySlots(comptime VT: type, comptime row: *const iids.Entry, comptime first: usize) usize {
    var index = first;
    for (@typeInfo(VT).@"struct".fields) |f| {
        if (@offsetOf(VT, f.name) != (index - first) * @sizeOf(usize))
            @compileError("vtable slot offset mismatch: " ++ row.name ++ "." ++ f.name);
        if (std.mem.eql(u8, f.name, "base")) {
            index = verifySlots(f.type, row, index);
            continue;
        }
        if (@typeInfo(f.type) != .pointer)
            @compileError("vtable slot is not a function pointer: " ++ row.name ++ "." ++ f.name);
        const want = iids.slotName(row.name, index) orelse
            @compileError("extra vtable slot: " ++ row.name ++ "." ++ f.name);
        const pad = std.fmt.comptimePrint("_pad{d}", .{index});
        if (!std.mem.eql(u8, f.name, want) and !std.mem.eql(u8, f.name, pad))
            @compileError(std.fmt.comptimePrint("slot {d} of {s} is {s}, WebView2.h says {s}", .{ index, row.name, f.name, want }));
        index += 1;
    }
    return index;
}

test "unit: platform: every bound IID equals the WebView2 SDK value and every vtable has the asserted slot count" {
    // The checks run at comptime; this pins that all rows were visited.
    try std.testing.expectEqual(iids.entries.len, verified_count);
    try std.testing.expectEqual(@as(usize, 61), @sizeOf(ICoreWebView2.VTable) / @sizeOf(usize));
    try std.testing.expectEqual(
        @as(usize, iids.find("ICoreWebView2_16").?.slot_count),
        @sizeOf(ICoreWebView2_16.VTable) / @sizeOf(usize),
    );
    try std.testing.expectEqual(@as(usize, 61), @offsetOf(ICoreWebView2_2.VTable, "add_WebResourceResponseReceived") / @sizeOf(usize));
    try std.testing.expect(guidEql(&ICoreWebView2.IID, &IID_ICoreWebView2));
}

test "unit: platform: (windows) EnvironmentOptions answers qi and round-trips its properties" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const opts = try EnvironmentOptions.create(testing.allocator, .{
        .additional_browser_arguments = "--proxy-server=http://127.0.0.1:8080",
        .language = "de-DE",
    });
    defer opts.unref();
    const iface = opts.interface();

    const same = qi(ICoreWebView2EnvironmentOptions, iface) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(iface, same);
    same.release();
    const unk = qi(IUnknown, iface) orelse return error.TestUnexpectedResult;
    unk.release();
    try testing.expect(qi(ICoreWebView2, iface) == null);
    try testing.expect(qi(ICoreWebView2Environment2, iface) == null);

    const expectString = struct {
        fn f(hr: HRESULT, got: ?LPWSTR, want: ?[]const u8) !void {
            defer if (got) |p| CoTaskMemFree(p);
            try testing.expectEqual(S_OK, hr);
            const w = want orelse return testing.expect(got == null);
            const utf8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.span(got.?));
            defer testing.allocator.free(utf8);
            try testing.expectEqualStrings(w, utf8);
        }
    }.f;
    var out: ?LPWSTR = null;
    var hr = iface.vtable.get_AdditionalBrowserArguments(iface, &out);
    try expectString(hr, out, "--proxy-server=http://127.0.0.1:8080");
    hr = iface.vtable.get_TargetCompatibleBrowserVersion(iface, &out);
    try expectString(hr, out, iids.target_browser_version);

    const lang = std.unicode.utf8ToUtf16LeStringLiteral("日本語-\u{1F600}");
    try testing.expectEqual(S_OK, iface.vtable.put_Language(iface, lang));
    hr = iface.vtable.get_Language(iface, &out);
    try expectString(hr, out, "日本語-\u{1F600}");
    try testing.expectEqual(S_OK, iface.vtable.put_Language(iface, null));
    hr = iface.vtable.get_Language(iface, &out);
    try expectString(hr, out, null);

    var sso: BOOL = TRUE;
    try testing.expectEqual(S_OK, iface.vtable.get_AllowSingleSignOnUsingOSPrimaryAccount(iface, &sso));
    try testing.expectEqual(FALSE, sso);
    try testing.expectEqual(S_OK, iface.vtable.put_AllowSingleSignOnUsingOSPrimaryAccount(iface, 7));
    try testing.expectEqual(S_OK, iface.vtable.get_AllowSingleSignOnUsingOSPrimaryAccount(iface, &sso));
    try testing.expectEqual(TRUE, sso);
}

test "unit: platform: (windows) EnvironmentOptions rejects invalid UTF-8 without leaking" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidUtf8, EnvironmentOptions.create(std.testing.allocator, .{
        .language = "en-US",
        .additional_browser_arguments = "--bad=\xff\xfe",
    }));
}

/// Handler factory name for a fixture handler row: the interface name
/// without the `ICoreWebView2` prefix, except the two loader completions.
fn factoryName(comptime iface: []const u8) []const u8 {
    if (std.mem.eql(u8, iface, "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler"))
        return "EnvironmentCompletedHandler";
    if (std.mem.eql(u8, iface, "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler"))
        return "ControllerCompletedHandler";
    return iface["ICoreWebView2".len..];
}

test "unit: platform: every handler row has a factory with its IID" {
    const Dummy = struct {};
    @setEvalBranchQuota(1_000_000);
    inline for (iids.entries) |row| {
        if (comptime std.mem.endsWith(u8, row.name, "Handler")) {
            const H = @field(bindings, factoryName(row.name))(Dummy);
            const iid = @field(bindings, "IID_" ++ row.name);
            try std.testing.expectEqual(@as(usize, 4), @sizeOf(H.VTable) / @sizeOf(usize));
            try std.testing.expect(guidEql(&iid, &iid));
        }
    }
}

test "unit: platform: (windows) every binding type-checks" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Dummy = struct {};
    @setEvalBranchQuota(1_000_000);
    inline for (iids.entries) |row| {
        if (comptime std.mem.endsWith(u8, row.name, "Handler")) {
            std.testing.refAllDecls(@field(bindings, factoryName(row.name))(Dummy));
        } else {
            std.testing.refAllDecls(@field(bindings, row.name));
        }
    }
    std.testing.refAllDecls(EnvironmentOptions);
    std.testing.refAllDecls(Loader);
    _ = &qi;
    _ = &retain;
    _ = &comAddRef;
    _ = &comRelease;
}
