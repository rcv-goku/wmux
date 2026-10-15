# Spike S5: WebView2 per-environment proxies

Status: decided (W0-D-S5, 2026-10-15).
Consumer: W6-5 (browser egress broker, per-route environments). Also relevant to W1-6 (bindings), W6-1 (Phase A) and ADR-6.3 / ADR-13.
Reference prototypes: `docs/arch/spikes/proto/S5/` (see its `README.md`).

## Question

ADR-13 plans browser egress for remote workspaces as one WebView2 environment per route:

- a separate user-data folder per route;
- `AdditionalBrowserArguments = "--proxy-server=socks5://127.0.0.1:<p> --proxy-bypass-list=<-loopback>"`;
- a local SOCKS5 broker that serves a connection only when the owning PID of that TCP connection (`GetExtendedTcpTable(TCP_TABLE_OWNER_PID_CONNECTIONS)`) belongs to that environment's `BrowserProcessId` process tree.

This spike verifies five points:

- two such environments can coexist in one process, each reaching only its own proxy;
- `<-loopback>` sends loopback URLs through the proxy;
- the PID check is correct and cheap;
- the fallback (HTTP proxy + `BasicAuthenticationRequested`) works;
- user-data folders can be cleaned up.

## Setup

- **Machine:** Windows 11 Enterprise 10.0.26200, 14 logical CPUs, 64 GB. Managed workstation; CPU at about 100% during all runs because of parallel builds by other agents.
- **WebView2:**
  - Runtime 155.0.4283.45 (Evergreen).
  - `WebView2Loader.dll` 1.0.4022.49 from NuGet `Microsoft.Web.WebView2` 1.0.4022.49 (signature valid).
  - IIDs and vtable slots checked against that package's `WebView2.idl`.
- **Toolchain:** Zig 0.15.2, `x86_64-windows-gnu`.
- **Bindings:** the prototypes import wmux's `src/apprt/win32/webview2.zig` as module `wv2`. Slots that file does not bind yet are called by vtable index (table in Guidance 8). No wmux source was modified.
- **`s5proto.zig`** (one process, run three times; run 3 is the final configuration):
  - A test origin on `127.0.0.1:T` and `[::1]:T`. Pages open a WebSocket echo. The origin logs whether a request arrived through one of our proxies or directly from a browser.
  - SOCKS5 brokers with the PID check: socksA, socksB, socksD, socksH. Plus socksOpen without the check, as a control.
  - HTTP proxies requiring `Proxy-Authorization: Basic`: httpE, httpE2, httpG.
  - Environments, each with its own user-data folder and hidden window:

| Env | Proxy arguments | Purpose |
|---|---|---|
| A | `socks5://socksA` + `<-loopback>` | `127.0.0.1`, `localhost`, `tenant.localhost`, `[::1]`, WebSocket |
| B | `socks5://socksB` + `<-loopback>` | separation from A |
| C | `socks5://socksA` + `<-loopback>` | a sibling environment pointed at A's broker; must be refused |
| D | `socks5://socksD`, no bypass override | control for `<-loopback>` |
| E / E2 | `http://httpE` / `http://httpE2` + `<-loopback>` | fallback; credentials supplied synchronously / via a deferral |
| G | `http://user:pass@httpG` | are inline proxy credentials accepted? |
| H | `socks5://<port with no listener>` | broker not running; started later on the same port |
| F | A's folder, different proxy port | second environment on a folder in use |

- **`s5close.zig`:** teardown probe. Load one page, call `Controller::Close()`, then measure browser exit, `BrowserProcessExited` and folder deletion. 11 processes, several release strategies.
- **`run-s5.ps1`:**
  - starts the probes with `UseShellExecute=false`, `CreateNoWindow=true`;
  - samples the foreground window every 100 ms;
  - records the process table during a hold phase;
  - runs `curl.exe` through socksA and socksOpen as a foreign process.
- **Focus:** windows are `WS_POPUP` with `WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW` at (-32000,-32000), shown with `SW_SHOWNOACTIVATE`. The in-process sampler and the external sampler both reported zero focus violations in every run.

## Results

### 1. Two environments in one process: works

- **Separate browser processes.** All 8 environments ran in one host process. Each got its own `msedgewebview2.exe` browser process, and its command line carried its own `--proxy-server` and `--proxy-bypass-list=<-loopback>` verbatim.
- **Separate proxies.**
  - A's requests appeared only on socksA and B's only on socksB.
  - All 6 A/B pages loaded through their own proxy, and the WebSocket echo worked.
  - Run 3 checks: `two-environments-one-process` and 6× `loopback-through-own-proxy` passed.
- **A folder in use rejects other arguments.** The second environment on A's folder with a different proxy is created with `S_OK`. Its `CreateCoreWebView2Controller` then completes with `0x8007139F` (`HRESULT_FROM_WIN32(ERROR_INVALID_STATE)`). The proxy is a per-folder setting. SDK 1.0.4022.49 has no per-profile proxy API.
- **Creation is lazy.**
  - `CreateCoreWebView2EnvironmentWithOptions` completes in 3-97 ms. `GetProcessInfos` is empty at that point.
  - The browser process starts with the first controller. Controllers completed 3.0-5.6 s later, with 8 environments starting concurrently on a saturated CPU.
  - `ProcessInfosChanged` reports the BROWSER entry right before the controller callback. `ICoreWebView2::get_BrowserProcessId` matched it in every case.
- **Environment options.**
  - The loader asks the host options object for `ICoreWebView2EnvironmentOptions2` through `8` plus three non-public IIDs. Answering `E_NOINTERFACE` is fine.
  - It reads `AdditionalBrowserArguments`.
  - `TargetCompatibleBrowserVersion "86.0.616.0"` was accepted.
- **Navigation timing.**
  - First navigation in a new environment: 3.8-6.4 s.
  - Later navigations: 0.3-1.6 s, including the WebSocket echo.
- **Cost per environment, measured on a simple page:**
  - 7-9 processes;
  - 168-219 MB private memory (362-482 MB working set);
  - largest parts: GPU process 68-75 MB, browser 34-37 MB, about 20 MB per renderer.

### 2. Loopback through the proxy: works

- **With `<-loopback>` (env A):** `127.0.0.1`, `localhost`, `tenant.localhost` and `[::1]` all went through socksA, for both page loads and WebSockets.
- **Without it (env D):** loopback went direct to the origin even though a proxy was configured. socksD saw no loopback request.
- **Chromium's SOCKS5 behaviour:**
  - The greeting is always `05 01 00`, i.e. "no authentication" only, on all 31 admitted connections of run 3. Username/password authentication is therefore impossible, which confirms the premise of ADR-13.
  - Every CONNECT uses address type 3 (domain name) with the host string from the URL: `127.0.0.1`, `localhost`, `tenant.localhost`, and `::1` without brackets. Chromium never resolves locally and never sends type 1 or 4.
  - Each WebSocket is its own CONNECT.
  - Some speculative connections close before the greeting.
- **No direct fallback.** With a single configured proxy and no listener, env H failed with `ERR_PROXY_CONNECTION_FAILED`. Nothing went direct.
- **The broker may start late.** Once a broker listened on H's port, the next navigation succeeded. The environment was not re-created.
- **Background traffic.** WebView2's own background traffic also uses the environment's proxy: `config.edge.skype.com:443` from every environment and `nav-edge.smartscreen.microsoft.com:443`. The prototype only connected loopback targets and refused the rest.

### 3. PID check: works

- **Who connects.** The connecting process was always the network service (`--type=utility --utility-sub-type=network.mojom.NetworkService`), a direct child of the environment's browser process.
- **Outcomes in run 3:**
  - All 31 served connections belonged to the right environment.
  - All 9 connections from sibling environment C to socksA were refused (8 with `05 FF`, 1 closed before the greeting). Its page failed with `ERR_SOCKS_CONNECTION_FAILED` (`WebErrorStatus` 0) and never reached the origin.
  - A connection from the host process itself was refused.
  - `curl.exe` through socksA exited with code 97 ("No authentication method was acceptable"). Through socksOpen it got HTTP 200.
- **Three ways to decide membership, compared:**

| Method | Cost per connection | Agreement / issues |
|---|---|---|
| `GetExtendedTcpTable` lookup of the 4-tuple | p50 0.18-0.40 ms, max 6.9-20.7 ms (110-133 rows) | correct owner in 200/200 benchmark lookups |
| Parent check: owner == browser, or `NtQueryInformationProcess(ProcessBasicInformation)` parent == browser with creation-time order | p50 44-46 µs, max 0.25-3.3 ms | agreed with the full tree walk on 41/41 and 42/42 connections |
| Toolhelp snapshot + parent walk | p50 31-149 ms, max 1.3 s | too slow per connection on this machine |
| Membership in `GetProcessInfos` (cached on the UI thread) | — | lags at start-up: 3 network-service connections arrived before the host processed `ProcessInfosChanged` (run 2) |

- **Cold first call.** In run 1 the first `GetExtendedTcpTable` calls took 368-730 ms. After one warm-up call at start (about 3 ms), the first real lookups took 0.26-0.74 ms.
- **Arming.** The browser PID was always known before the first connection arrived (`waited=0ms` everywhere).

### 4. Fallback, HTTP proxy + `BasicAuthenticationRequested`: works, with caveats

- **The event fires once per environment, on the first 407.**
  - `Uri` is the proxy (`http://127.0.0.1:<port>/`).
  - `Challenge` is `Basic realm="..."`.
  - Credentials set synchronously on `Response` work, and so do credentials set later via `GetDeferral()` + `Complete()`.
- **The challenged navigation completes with `WebErrorStatus` 18 (`VALID_PROXY_AUTHENTICATION_REQUIRED`).** WebView2 then starts a new navigation to the same URI with a new `NavigationId`, and that one succeeds. With a deferral, the new navigation starts about 10 ms after `Complete()`. If the host navigates elsewhere first, the retry completes with 9 (`CONNECTION_ABORTED`); runs 1-2 got this wrong for exactly that reason.
- **Later requests carry the header up front.** Plain `http://` requests arrive in absolute form on keep-alive connections; WebSockets and https use CONNECT.
- **Browser background requests never authenticate.** They got 407 with no event, even after the credentials were cached.
- **Inline credentials are rejected.** `--proxy-server=http://user:pass@…` gives `ERR_NO_SUPPORTED_PROXIES`, with no proxy connection at all.

### 5. Cleanup: works only asynchronously

- **`Controller::Close()` returns `S_OK`, but the browser process outlives it.** On this machine it lived 40-50 s in five single-environment trials, 104-203 s in others, and more than 150 s for all 8 environments of run 2.
  - The variance is large.
  - None of these changed it consistently: holding or releasing the environment, registering `BrowserProcessExited` or not, removing the handler, destroying the parent window, skipping `Close()`.
- **`BrowserProcessExited` arrives after the last process of the tree is gone.**
  - About 36 s after the browser process itself exited (82 s after `Close()` in one trial).
  - Requires keeping the environment and its handler registered until then.
  - After the event the folder could be deleted, once only after about 30 more seconds of `AccessDenied`.
- **Forced termination did not make it deterministic.** Terminating the tree 3 s after `Close()` gave browser exit at 24 s and the event at 50 s. Sandboxed renderers cannot be opened for termination by the host.
- **Folders in use fail to delete** with `AccessDenied` / `FileBusy`.
- **Re-creating on the same folder.**
  - Same arguments, 12 s after `Close()`, while the old browser was still shutting down: works, and gets a new browser process.
  - Different arguments while the old browser is active: fails with `0x8007139F` (result 1).
- **After the host process exited (run 1),** leftover WebView2 processes needed 2-7 minutes to disappear.

## Decision

**Adopt, with changes.** Per-route environments with SOCKS5 and the PID check work as ADR-13 describes. The HTTP + `BasicAuthenticationRequested` path also works but is more complex and has gaps, so it stays a documented fallback only.

Changes to the ADR-13 design:

1. **Membership predicate.** The owner of the connection must be the environment's browser process or a direct child of it. Get the parent with `NtQueryInformationProcess`, check creation-time order, and keep a handle to the browser process open for the environment's lifetime (an open handle keeps its PID from being reused). Do not take a Toolhelp snapshot per connection. Use `GetProcessInfos` for diagnostics only.
2. **Arming.** Because creation is lazy, arm the check when the browser PID becomes known: `ProcessInfosChanged` with a BROWSER entry, or `get_BrowserProcessId` in the controller callback. Hold connections that arrive earlier for a bounded time instead of refusing them.
3. **Stable broker port per user-data folder.** The port is baked into the browser command line. Keep it for the life of the environment. Restart the broker on the same port if needed (works, see result 2). If a different port is unavoidable (bind conflict, or a restart while an old browser still holds the folder), use a new folder generation `remote-<routehash>-<n>` instead of reusing the folder.
4. **Asynchronous teardown.**
   - Close controllers, keep the environment with a `BrowserProcessExited` handler, then delete the folder on a worker thread with retries.
   - At start-up, garbage-collect unused `remote-*` folders.
   - Never wait on the UI thread.
5. **Background traffic policy.** WebView2 service traffic follows the route proxy, so it leaves from the remote host. W6-5 decides whether to allow it or to reduce it (for example `ICoreWebView2Settings8::put_IsReputationCheckingRequired(FALSE)` for remote environments; untested).

## Guidance for W6-5 (and W1-6)

### 1. Creating a route environment (UI thread)

1. Bind the broker first, on `127.0.0.1:0` with `SO_EXCLUSIVEADDRUSE`, and read the port. Bind IPv4 loopback only; Chromium connects to the literal you configure.
2. Set the arguments to exactly `--proxy-server=socks5://127.0.0.1:<port> --proxy-bypass-list=<-loopback>`.
3. Create the environment with folder `STATE\webview2\remote-<routehash>[-<gen>]` and a host-implemented `ICoreWebView2EnvironmentOptions`. Return strings with `CoTaskMemAlloc`; answer `E_NOINTERFACE` for `Options2..8`.
4. Register `ICoreWebView2Environment8::add_ProcessInfosChanged` and `ICoreWebView2Environment5::add_BrowserProcessExited` right away.
5. On the first controller: read `get_BrowserProcessId` (slot 37). Open `SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION` on that PID, read its creation time, and publish `{pid, created}` to the broker thread (atomic or mutex). That arms the route.
6. If the controller fails with `0x8007139F`, the folder is still held by a browser with other arguments. Bump the generation and retry once.

### 2. The broker's membership check (broker thread, no COM)

```zig
const Armed = struct { pid: u32, created: u64 }; // published by the UI thread

/// `peer` is the address accept() returned; `port_be` the listener's port.
fn admitted(peer: ws2_32.sockaddr.in, port_be: u16, armed: Armed) bool {
    const owner = ownerPid(peer.addr, peer.port, loopback_be, port_be) orelse return false;
    if (owner == armed.pid) return true; // network service in-process
    const parent = parentPid(owner) orelse return false;
    if (parent != armed.pid) return false;
    const born = creationTime(owner) orelse return false;
    return armed.created <= born;
}
```

Implementation notes:
- **`ownerPid`:** call `GetExtendedTcpTable(buf, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0)` and grow the buffer on error 122. Find the row whose local endpoint is the peer and whose remote endpoint is `127.0.0.1:<listen port>`. Ports are in network order in the low 16 bits; compare them to `sockaddr_in.port` as-is. The prototype's `tcpOwner4` is a working version.
- **`parentPid`:** `NtQueryInformationProcess(ProcessBasicInformation).InheritedFromUniqueProcessId`.
- **`creationTime`:** `GetProcessTimes`.
- **Warm-up:** make one dummy `GetExtendedTcpTable` call when the broker starts.
- **Refusal:** refuse before parsing anything else. Answer the greeting with `05 FF` and close. Chromium shows `ERR_SOCKS_CONNECTION_FAILED`.
- **Disarming:** disarm when the browser handle signals, then wait for the next arming.

### 3. SOCKS5 details for the broker and `proxy.open`

- Expect only method `00`.
- Expect requests with address type 3 and a host string. Parse IP literals (including bare `::1`) before handing the name to the remote side; the remote resolves names, which is what makes "remote localhost" work.
- Reply success as `05 00 00 01 00000000 0000`.
- Forward any bytes that arrive right after the request.
- Treat EOF before the greeting as normal.

### 4. Loopback and local workspaces

- Always pass `<-loopback>`. Without it, loopback silently stays local.
- Local workspaces keep using the shared environment without a proxy (ADR-6.3).

### 5. Teardown

- **Last pane of a route closed:** keep the environment and broker for reuse. Re-creating costs 3-6 s, and the old browser lingers anyway.
- **Route disconnected for good:**
  1. Close every controller.
  2. Keep the environment until `BrowserProcessExited`.
  3. Then release it, stop the broker, and queue the folder for deletion on a worker thread with backoff (expect `AccessDenied` / `FileBusy` for tens of seconds).
- **At start-up:** delete `remote-*` folders that no running instance uses.

### 6. Fallback, only if the PID check cannot be used

HTTP proxy with a random per-tunnel credential:
1. Register `ICoreWebView2_10::add_BasicAuthenticationRequested` on every webview before its first navigation; otherwise WebView2 shows its own credential dialog.
2. Answer only when `Uri` is the broker's URI.
3. Track `NavigationStarting` / `NavigationCompleted` IDs, and treat `WebErrorStatus` 18 right after the event as transient: a new navigation to the same URI follows.
4. Expect absolute-form requests on keep-alive connections, and CONNECT for https/ws.
5. Accept that browser background requests cannot authenticate.

### 7. Phase A (`ssh -D`)

An `ssh -D` port has no membership check: any local process can use it, as the socksOpen + `curl` control shows. Keep this as the documented Phase A caveat. Alternatively, put the in-process broker with the check in front of it.

### 8. Bindings needed (W1-6 completion or a CCR against `platform/webview2.zig`)

| Interface | IID | Slots used |
|---|---|---|
| `ICoreWebView2EnvironmentOptions` (host-implemented) | `2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5` | 3-10: get/put AdditionalBrowserArguments, Language, TargetCompatibleBrowserVersion, AllowSingleSignOnUsingOSPrimaryAccount |
| `ICoreWebView2` | `76eceacb-…` | 7 `add_NavigationStarting`, 37 `get_BrowserProcessId` |
| `ICoreWebView2_10` | `b1690564-6f5a-4983-8e48-31d1143fecdb` | 97 / 98 add/remove `BasicAuthenticationRequested` |
| `ICoreWebView2Environment5` | `319e423d-e0d7-4b8d-9254-ae9475de9b17` | 12 / 13 add/remove `BrowserProcessExited` |
| `ICoreWebView2Environment8` | `d6eb91dd-c3d2-45e5-bd29-6dc2bc4de9cf` | 16 / 17 add/remove `ProcessInfosChanged`, 18 `GetProcessInfos` |
| `ICoreWebView2ProcessInfoCollection` / `ICoreWebView2ProcessInfo` | `402b99cd-…` / `84fa7612-…` | 3 `Count`, 4 `GetValueAtIndex` / 3 `ProcessId`, 4 `Kind` (0 = browser) |
| `ICoreWebView2BasicAuthenticationRequestedEventArgs` | `ef05516f-…` | 3 `Uri`, 4 `Challenge`, 5 `Response`, 7 `put_Cancel`, 8 `GetDeferral` |
| `ICoreWebView2BasicAuthenticationResponse` | `07023f7d-…` | 4 `put_UserName`, 6 `put_Password` |
| `ICoreWebView2BrowserProcessExitedEventArgs` | `1f00663f-…` | 3 `Kind` (0 normal, 1 failed), 4 `BrowserProcessId` |
| Event handlers | NavigationStarting `9adbe429-f36d-432b-9ddc-f8881fbd76e3`, BasicAuth `58b4d6c2-18d4-497e-b39b-9a96533fa278`, ProcessInfosChanged `f4af0c39-44b9-40e9-8b11-0484cfb9e0a1`, BrowserProcessExited `fa504257-a216-4911-a860-fe8825712861` | `Invoke` (slot 3) |
| Event args | `NavigationCompletedEventArgs` slot 5 `get_NavigationId`; `NavigationStartingEventArgs` slot 9 `get_NavigationId` | — |

The existing generic `Handler(iid, Ctx, A0, A1)` in `webview2.zig` covered every callback the prototypes needed.

## Open risks

- **Teardown timings are machine-specific.** They were measured on a managed workstation with the CPU saturated, and the root cause of the slow exit was not identified. Other machines may be much faster. The design above does not depend on speed.
- **Untested leak paths.** UDP (WebRTC) is not carried over SOCKS5 and may leave locally; consider `--force-webrtc-ip-handling-policy=disable_non_proxied_udp` (untested). DNS prefetch leakage was not specifically tested.
- **Process model changes.** If a future runtime moves the network service in-process or deeper in the tree, the predicate needs adjusting. The in-process case is already covered. Log mismatches (owner in the tree walk but not a direct child) to detect changes.
- **Memory.** About 170-220 MB private per active route environment.
- **Undocumented fallback behaviour.** Completion with 18 followed by an automatic retry is not documented and could change.
- **Shared folders.** A route folder shared by two wmux instances (channels) would hit `0x8007139F`. Keep route folders under the per-channel `STATE`.
