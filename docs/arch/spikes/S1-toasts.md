# Spike S1 — Unpackaged WinRT toasts for a Win32 app

- WP: W0-D (spike). Consumers: **W3-7** (`features/toasts/`, `platform/winrt/`, `features/deeplinks/`, `features/tray/`), with ties to **W0-A3** (link libraries, `app/single_instance.zig`, `app/foreground.zig`), **W1-1** (launch pipe), **W2-5** (notifications core / balloon fallback).
- ADRs: ADR-7.5 (desktop delivery), ADR-3.1/3.11 (launch pipe, foreground), ADR-14.3 (W0-A3 link list), ADR-14.7 (this spike).
- Date: 2026-10-15. Host: Windows 11 Enterprise **10.0.26200**, session 1. Toolchain: Zig 0.15.2, `-target x86_64-windows-gnu`, Windows SDK 10.0.26100 headers (for IID/vtable verification only).
- Reference code: `docs/arch/spikes/proto/S1/` (`s1.zig`, `README.md`, `fg-sampler.ps1`, `uia-observe.ps1`).
- Spike identities only: AUMID `wmux.spike.s1`, protocol `wmux-spike-s1`, CLSID `{F6731D70-24AA-4042-AAA9-4A386308A09B}`, pipe `\\.\pipe\wmux-spike-s1-launch`. All registry keys were created and then deleted; the external foreground sampler recorded **0** foreground violations over **14,179** samples.

---

## Question

For an **unpackaged** Win32 app (no MSIX, no AppContainer):

1. Does a toast under a **registry-registered AUMID** (`HKCU\Software\Classes\AppUserModelId\<aumid>` with `DisplayName`/`IconUri`, **no Start-menu shortcut**) show and persist in Action Center on this Windows 11 build?
2. Can **protocol activation** (`activationType="protocol"`, `launch="<scheme>:…"`) reach a running process (the launch pipe) and does that process get **foreground rights** (`AllowSetForegroundWindow` semantics)?
3. Does a **COM activator** (CLSID + `INotificationActivationCallback`) receive inline **Reply** input for an unpackaged app?
4. Can `ToastNotifier.Setting` / `ToastNotificationManager` detect **disabled** notifications?
5. Does `ToastNotificationHistory.Remove(tag, group)` **withdraw** a toast (tag/group ≤ 64 chars)?

Method: a standalone Zig program (`s1.zig`) calling WinRT through hand-written ABI (`RoGetActivationFactory`/`RoActivateInstance`, `HSTRING`, `IInspectable` vtables). No WinRT language projection, no C++/WinRT, no external SDK import library. Every IID and vtable slot order checked against the SDK headers; the four parameterized (`pinterface`) IIDs are recomputed by SHA-1 and asserted equal to the header values in a `zig test`.

---

## Setup (exact)

Build (binaries go to a scratch dir outside the repo; never committed):

```powershell
$Z = 'C:\Users\Rey.ColonValero\zig-x86_64-windows-0.15.2\zig.exe'
& $Z build-exe s1.zig -target x86_64-windows-gnu -O ReleaseSafe --subsystem console --name s1  "-femit-bin=$B\s1.exe"
& $Z build-exe s1.zig -target x86_64-windows-gnu -O ReleaseSafe --subsystem windows --name s1w "-femit-bin=$B\s1w.exe"
& $Z test s1.zig -target x86_64-windows-gnu      # "pinterface IIDs match the SDK headers" — passes
```

`s1.exe` (console) drives; `s1w.exe` (GUI subsystem, creates no window) is the registered protocol handler and the COM `LocalServer32`. See `proto/S1/README.md` for every command and the full run sequence. Linking uses **only** Zig's bundled mingw import defs (no Windows SDK `.lib`):

```
api-ms-win-core-winrt-l1-1-0        RoInitialize, RoUninitialize, RoGetActivationFactory, RoActivateInstance
api-ms-win-core-winrt-string-l1-1-0 WindowsCreateString(+Reference), WindowsDeleteString, WindowsGetStringRawBuffer
ole32        CoInitializeEx, CoUninitialize, CoCreateInstance, CoRegisterClassObject, CoRevokeClassObject, CoAllowSetForegroundWindow
shell32      SetCurrentProcessExplicitAppUserModelID, SHQueryUserNotificationState, ShellExecuteExW
shlwapi      AssocQueryStringW
advapi32 user32 kernel32  (registry, foreground probes, pipe, process)
```

Safety harness: `fg-sampler.ps1` (external, 100 ms `GetForegroundWindow` sampler) ran the whole session; `s1.zig` also runs an in-process foreground guard that calls `ExitProcess(99)` if a spike process ever becomes foreground (never fired); `uia-observe.ps1` passively dumped the toast banner's UI Automation tree. The only path that ever calls `SetForegroundWindow` is the opt-in `--foreground-demo` (not used in automated runs).

Registry footprint (HKCU, all deleted at the end by `s1 unregister`):

```
Software\Classes\AppUserModelId\wmux.spike.s1   DisplayName, IconUri, CustomActivator={CLSID}
Software\Classes\wmux-spike-s1                   "URL:…", "URL Protocol"="", shell\open\command = "…\s1w.exe" "%1"
Software\Classes\CLSID\{F6731D70-…}\LocalServer32 = "…\s1w.exe" -ToastActivated
Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\wmux.spike.s1  (created by the platform on first toast)
```

---

## Results

### 1. Registry-only AUMID toast shows and persists — YES

- `ToastNotificationManager.CreateToastNotifierWithId("wmux.spike.s1")` → `S_OK`; `Show` → `S_OK` in **~130–150 ms**, with **no Start-menu shortcut** and no MSIX identity. Three toasts were shown (text "wmux spike test - safe to ignore"), all succeeded.
- **Persistence:** immediately after `Show`, `GetHistoryWithId(aumid)` count went `0 → 1`; the toast was still listed **by a different, later process** after the showing process had exited. The `Dismissed` event fired with `reason=2` (**TimedOut**, ~8.4 s) when the banner auto-hid, but the entry **stayed in Action Center** until explicitly removed — i.e. banner lifetime and Action-Center lifetime are independent, exactly what ADR-7.5 assumes.
- The platform created `…\Notifications\Settings\wmux.spike.s1` itself on the first toast. `DisplayName`/`IconUri` from the AUMID key are used for the toast's app title/icon.
- The toast XML round-trips: `IToastNotification.get_Content` → `IXmlNodeSerializer.GetXml` returned the exact XML sent (including the `launch` URI and the `<actions>`).

### 2. Protocol activation reaches the launch pipe — YES. Foreground grant — plumbing correct, success is a manual step.

- Registering `HKCU\Software\Classes\wmux-spike-s1` with `URL Protocol` and `shell\open\command` is enough: `AssocQueryStringW(ASSOCSTR_COMMAND)` resolves the handler **without launching it**, and `ShellExecuteExW("open", "wmux-spike-s1://…")` runs `s1w.exe "<uri>"`. A toast with `launch="wmux-spike-s1://notification/open?id=…" activationType="protocol"` is therefore delivered to our handler. (Automated runs simulated the click with `ShellExecuteExW`; the real click is the manual step below.)
- The handler connects to the always-on launch pipe (`SECURITY_IDENTIFICATION` so a squatting server cannot impersonate it), reads the server PID with `GetNamedPipeServerProcessId`, and forwards the URI. **Forward latency handler→server: 82–205 µs.** The server logged `launch_received` with the correct URI every time, including when the server itself spawned the handler (`spawn-via-server`) and when a fresh server was cold-started through COM.
- **No running instance:** the handler fails to open the pipe (`ERROR_FILE_NOT_FOUND`) and exits **3** — the signal for "become the app, restore session, then open the record" (ADR-7.5).
- **Foreground rights.** The handler calls `AllowSetForegroundWindow(server_pid)` at the correct point (after reading the server PID, before the server processes the request), matching ADR-3.1/3.11. **The actual grant could not be confirmed automatically**, for two reasons: (a) the right is conferred by the real **toast click** (a user input event), which cannot be scripted here; and (b) the host desktop **locked** partway through the run (the real user stepped away), and on a locked desktop no process is foreground-eligible, so every `AllowSetForegroundWindow` returned `ERROR_ACCESS_DENIED (5)` and the server's post-grant probe stayed false. Before the lock, an idle-but-unlocked process's self-probe was **true**. The mechanism and call sequence are in place; confirming the grant is the documented manual step (§Manual verification) and is the item W3-7 must re-check on a real click. The balloon fallback (ADR-7.5) covers the case where it ever fails.

### 3. COM activator receives inline Reply — YES

- `CoRegisterClassObject(CLSID, CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE)` in the server + `CustomActivator={CLSID}` on the AUMID key + `CLSID\…\LocalServer32` is sufficient for an **unpackaged** app. `INotificationActivationCallback::Activate` fired with:
  - `appUserModelId = "wmux.spike.s1"`,
  - `invokedArgs = "action=reply&id=<record>"` (from the `<action … arguments=…>`),
  - one `NOTIFICATION_USER_INPUT_DATA` pair `{Key:"reply", Value:"<typed text>"}` from the `<input id="reply" type="text">`.
- This was verified out-of-process via `CoCreateInstance` + `Activate` (the activation path the shell uses). **Cold start** (no server running): COM/DcomLaunch started `s1w.exe -ToastActivated -Embedding` (parent `svchost.exe`) in **~1.9 s**, after which `Activate` returned in ~19 ms. **Warm:** `CoCreateInstance` 0.19–0.59 s, `Activate` 19–103 ms.
- `INotificationActivationCallback` **marshals out of the box**: its proxy/stub is system-registered (`{95E15D0A-…}` → `OneCoreUAPCommonProxyStub.dll`), so we do **not** ship a proxy DLL. The activator answered `QueryInterface` for `IUnknown` and `INotificationActivationCallback`; the class factory answered `IClassFactory`.

### 4. Disabled-state detection — detection works; do NOT fake it via the registry

- `IToastNotifier::get_Setting` returned `NotificationSetting.Enabled (0)` once the AUMID had sent its first toast. **Gotcha:** before the first toast (fresh registration) it returned `0x80070490` (`ERROR_NOT_FOUND`) — treat a failed/`NOT_FOUND` `get_Setting` as "not yet known / assume enabled", not as "disabled".
- Writing `…\Notifications\Settings\wmux.spike.s1\Enabled = 0 (DWORD)` directly did **not** make `get_Setting` report `DisabledForApplication`; it kept returning `Enabled`. So `get_Setting` reflects the notification service's cached view, not that registry value directly. Detection is reliable; **forcing** a disabled state for testing must go through the Settings UI (manual) — a registry poke is not a usable test hook. The five states (`Enabled`, `DisabledForApplication`, `DisabledForUser`, `DisabledByGroupPolicy`, `DisabledByManifest`) map to the gap's required status strings.

### 5. `History.Remove` withdraws — YES (and the 64-char limit is real)

- `IToastNotificationHistory`:
  - `RemoveGroupedTagWithId(tag, group, aumid)` → history count `1 → 0` (the per-record withdraw on read/dismiss/replace).
  - `RemoveGroupWithId(group, aumid)` → `1 → 0` (the per-workspace withdraw on workspace select).
  - Removing a **nonexistent** tag/group returns `S_OK` and leaves the count unchanged (idempotent — safe to call unconditionally).
  - `ClearWithId(aumid)` clears all (used in cleanup).
- **Tag/Group length:** `put_Tag`/`put_Group` accept **64** chars (`S_OK`); **65** chars are rejected before `Show` (`put_Tag 0x803E0116`, `put_Group 0x803E0209`). So ADR-7.5's full 36-char UUIDs are comfortably legal.
- **Quirk (does not affect wmux):** for a **64-char** tag/group, `put`/`Show`/persist/`Remove` all work, but reading the value **back** from a history item via `get_Tag`/`get_Group` fails with `0x80070057` (`E_INVALIDARG`) and returns empty — isolated across two templates, so it is length-driven, not template-driven. A **36-char** tag/group round-trips cleanly. wmux uses 36-char UUIDs for both tag and group, so it is in the clean regime; just never rely on reading a ≥~64-char tag back out of history.

### Build / linking finding (correction for ADR-14.3)

The whole WinRT toast stack builds and runs with Zig 0.15.2's bundled mingw and **no Windows SDK**. But **`runtimeobject` and `combase` are not available as link libraries** for `x86_64-windows-gnu` (`-lruntimeobject`/`-lcombase` → "unable to find dynamic system library"; there is no x64 `.def`). ADR-14.3's W0-A3 link list names `runtimeobject`; that line will not link. The functions actually needed are exported by the api-set DLLs, which **do** have x64 defs: link/declare against `api-ms-win-core-winrt-l1-1-0` and `api-ms-win-core-winrt-string-l1-1-0` (Zig auto-links the DLL named in each `extern "<dll>"`, so no explicit `linkSystemLibrary` is even required if the externs name those api-sets). `ole32` covers the COM entry points.

---

## Decision: ADOPT (with one changed assumption)

The ADR-7.5 design is sound on this build with hand-written WinRT ABI: registry-only AUMID toasts show and persist; protocol activation reaches the launch pipe; the COM activator delivers inline Reply for an unpackaged app; `get_Setting` detects disabled; `History.Remove(tag, group)` withdraws. No MSIX, no Start-menu shortcut, no SDK import library, no proxy DLL.

Changed assumptions / required edits for consumers:

1. **Link list (ADR-14.3 / W0-A3):** replace `runtimeobject` with the two `api-ms-win-core-winrt-*` api-sets (or rely on the `extern "<api-set>"` names). `combase` is likewise unavailable; use `ole32` for the COM entry points.
2. **Foreground grant is verified only by a real click** and was further blocked by a locked desktop during this run; W3-7 must re-confirm it interactively (steps below) and keep the balloon fallback.
3. **Disabled-state** can be *detected* but not *forced* via registry; tests toggle it through the Settings UI.

Fallback (unchanged, already in ADR-7.5): Start-menu-shortcut AUMID if a future build rejects registry-only identity; balloon (`features/tray`) when `get_Setting` ≠ Enabled or any WinRT call fails.

---

## Guidance for the consuming WPs (W3-7, W0-A3, W1-1)

**API sequence — show a toast**

1. Once at startup, before the first window: `SetCurrentProcessExplicitAppUserModelID(aumid_w)` (ADR-7.5). Then `RoInitialize(RO_INIT_MULTITHREADED)` (or `CoInitializeEx` + the apartment of your choice; MTA is simplest for a worker that only shows toasts).
2. `RoGetActivationFactory("Windows.UI.Notifications.ToastNotificationManager", IID_IToastNotificationManagerStatics)` → `CreateToastNotifierWithId(aumid)`.
3. `RoActivateInstance("Windows.Data.Xml.Dom.XmlDocument")` → `QI IXmlDocumentIO` → `LoadXml(hstring)`. Build the XML as text (see the templates in `s1.zig`; `&` must be `&amp;` inside `launch`/`arguments`).
4. `RoGetActivationFactory("Windows.UI.Notifications.ToastNotification", IID_IToastNotificationFactory)` → `CreateToastNotification(xmlDoc)`.
5. `QI IToastNotification2`; `put_Tag(recordUuid)` (36 chars), `put_Group(workspaceUuid)` (36 chars). Optionally `add_Dismissed/add_Activated/add_Failed` (delegates are IUnknown-based; also answer `QI` for `IAgileObject` so the platform does not try to marshal them — see `Delegate` in `s1.zig`).
6. `IToastNotifier::Show(toast)`.

**HSTRING**: for a comptime class name use `WindowsCreateStringReference` (no allocation; the 24-byte `HSTRING_HEADER` lives on the stack and must outlive the HSTRING). For runtime strings use `WindowsCreateString` (copies) and `WindowsDeleteString`. UTF-8→UTF-16 first; cap on code-point boundaries (G6).

**Withdraw**: `IToastNotificationManagerStatics2::get_History` → `IToastNotificationHistory`. On read/dismiss/replace: `RemoveGroupedTagWithId(tag, group, aumid)`. On workspace select: `RemoveGroupWithId(group, aumid)`. Both are idempotent. Pass the **aumid** overloads (the no-id `Remove`/`RemoveGroup` use the process's current AUMID, which only works after `SetCurrentProcessExplicitAppUserModelID`).

**Disabled detection**: `IToastNotifier::get_Setting`. Map `Enabled→deliver`; `DisabledForApplication/ForUser/ByGroupPolicy/ByManifest→skip banner, still record in-app, show the balloon fallback + one-time notice`. Treat `get_Setting` failure or `ERROR_NOT_FOUND` (seen before the first toast) as "assume enabled".

**Protocol activation path (click → running instance)** — the exact chain this spike proved:
1. Toast XML carries `launch="wmux://notification/open?id=<uuid>&ws=<uuid>" activationType="protocol"` and, for buttons, `<action … activationType="protocol" arguments="wmux://…">`.
2. Register `HKCU\Software\Classes\wmux` with `URL Protocol`, `shell\open\command = "<INSTALL>\wmux.exe" "%1"` (non-stable channels: `wmux-<channel>`).
3. Click runs `wmux.exe "wmux://…"`. In `wmux.exe` argv routing (W1-2), detect the `wmux:`/`wmux-<channel>:` prefix and run the deeplink/launch client **before** normal startup.
4. The client opens the launch pipe, `GetNamedPipeServerProcessId`, `AllowSetForegroundWindow(server_pid)`, sends `app.launch {intent:"uri", uri}` (ADR-3.1), and exits. If the pipe is absent, become the app, restore session, then run `notification.open` if the record still exists.
5. The server runs `notification.open` (focus intent + `app/foreground.zig` activation) only within the grant window.

Open the pipe with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION` (prevents a squatting server impersonating the client) and set `PIPE_READMODE_MESSAGE`.

**COM activator (Reply only)** — needed only for inline Reply:
1. In the running app, host an `INotificationActivationCallback` and `CoRegisterClassObject(CLSID, CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE)`.
2. Register `CustomActivator={CLSID}` on the AUMID key and `HKCU\Software\Classes\CLSID\{CLSID}\LocalServer32 = "<INSTALL>\wmux.exe" -ToastActivated`.
3. `Activate(aumid, invokedArgs, data[], count)` gives you the button `arguments` and the `{key,value}` input pairs. Re-resolve the target surface by UUID (G-rule: never keep raw pointers), write reply+Enter if it still exists.
4. When launched cold for activation, `wmux.exe` is started as `… -ToastActivated -Embedding`; treat `-ToastActivated` (and `-Embedding`/`/Embedding`) as "start, register the class object, service the activation, idle-exit". No proxy DLL ships — the system proxy/stub marshals the interface. If HKCU COM registration is blocked by policy, omit Reply buttons; protocol clicks still work (ADR-7.5).

**Threading/COM notes**: check every HRESULT; `get_Setting`/history calls are fast and safe from a worker thread, but all model/HWND mutation stays on the UI thread via `app.tasks` (G3). Toast event delegates are invoked on platform (MTA) threads — marshal back with `app.tasks.post`.

**Test mode**: register nothing and show nothing; append deliveries to `WMUX_TEST_TOAST_SINK` (ADR-7.5 / ADR-12.3).

---

## Open risks

- **Foreground grant on real click** is unproven here (locked desktop + click is inherently manual). W3-7 must confirm `handler_grant_ok=true` and the server `post_probe=true` on an unlocked desktop (use `--foreground-demo` for a visible check), and keep `AllowSetForegroundWindow` strictly inside the ≤2 s grant window (ADR-3.11). Balloon fallback mitigates.
- **64-char tag/group read-back** returns `E_INVALIDARG`. Harmless for 36-char UUIDs; do not design anything that reads tags back out of history near the limit.
- **`get_Setting` is service-cached**, not registry-direct: detection is fine, but automated tests cannot flip DisabledForApplication via the registry — toggle via Settings or treat as manual.
- **DcomLaunch cold start ~1.9 s** for the first Reply activation when no instance is running. Acceptable (Reply only), but the user may perceive lag; pre-starting the class object at app launch avoids it (the running app already has it registered).
- **Focus Assist / Do-Not-Disturb** (`SHQueryUserNotificationState`) hides banners; records still land (matches cmux). Self-played sounds (ADR-7.6) must also honor it.
- **Group Policy** `NoToastApplicationNotification` (checked, absent here) disables toasts machine/user-wide → `get_Setting = DisabledByGroupPolicy` → balloon fallback.
- Verified on build **26200** only; the `runtimeobject`-vs-api-set linking detail is specific to Zig 0.15.2's bundled mingw and should be re-checked if the toolchain is upgraded.
