# S7: Direct2D sidebar child HWND next to GL and WebView2 siblings

| | |
|---|---|
| Spike | W0-D S7 (`d2d-sidebar-child`), ARCHITECTURE ADR-14.7 |
| ADRs under test | ADR-11.1 (sidebar = child HWND `WmuxSidebar`, D2D 1.1 + DirectWrite, `ID2D1HwndRenderTarget`, `D2DERR_RECREATE_TARGET` handled), ADR-11.2, ADR-11.5 (DPI), ADR-11.6 risks line |
| Consumers | W1-8 (sidebar, right-sidebar frame), W1-8a (D2D/DWrite bindings), W5 (tab bars via `BindDC`), W0-B and S2 (hidden-instance harness: see section 5.4) |
| Date | 2026-10-15 |
| Prototype | `docs/arch/spikes/proto/S7/` (C prototype, Zig binding check, runner, matrix, evidence) |
| Verdict | **Adopt with changes**: child HWND + `ID2D1HwndRenderTarget`. Fallback (`BindDC` in the parent's paint) works but is slower and gives no invalidation isolation. Flip-model D2D rejected for the sidebar. |

## 1. Question

Can a Direct2D/DirectWrite-rendered **child** HWND (the future `WmuxSidebar`) sit next to wmux's OpenGL terminal child HWNDs and a WebView2 child in the same top-level window without:

- z-order problems,
- flicker on resize (WM_SIZE storms) or redraw gaps,
- capture problems (`PrintWindow`, which the e2e harness relies on),
- device-loss trouble (`D2DERR_RECREATE_TARGET`),
- per-monitor DPI problems (`GetDpiForWindow`, `WM_DPICHANGED` for children)?

Compare with the fallback: `ID2D1DCRenderTarget::BindDC` inside the parent's double-buffered `WM_PAINT`, with no child HWND. Recommend one, with concrete guidance.

## 2. Setup

### 2.1 Machine and versions

- Windows 11 Enterprise 25H2, build 26200.9448. Process is Per-Monitor-V2 (`SetProcessDpiAwarenessContext(-4)`, the same as the wmux manifest).
- GPU: Intel(R) Graphics, driver 32.0.101.8860. GL: `Intel / Intel(R) Graphics / 4.6.0 - Build 32.0.101.8860`.
- Two monitors: `\\.\DISPLAY2` 3840x2160 at 144 DPI (primary, origin 0,0) and `\\.\DISPLAY1` 1920x1200 at 96 DPI (origin 937,2160).
- WebView2 runtime 155.0.4283.45, `WebView2Loader.dll` from the installed wmux.
- Toolchain: Zig 0.15.2 `zig cc` (clang, `-target x86_64-windows-gnu`, mingw-w64 headers) for the C prototype; `zig build-exe` for the Zig binding check. Windows SDK 10.0.26100 headers were read only for interface facts (WGC IIDs and slot order).
- Load: many other agents built Ghostty in parallel during every run, so tail latencies (p95, max) are noisy. Medians are the reliable numbers.

### 2.2 Prototype (`proto/S7/s7proto.c`, standalone, never part of the wmux build)

A single top-level window that mirrors `Window.zig`:

- **Top-level**: `WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN`, class `CS_DBLCLKS` with a background brush, `WM_ERASEBKGND -> 1`, and GDI "chrome" (tab strip and dividers) painted in `WM_PAINT`.
- **Sidebar**, in one of three modes:
  - `hwndrt`: child `S7Sidebar` (`WS_CHILD|WS_VISIBLE|WS_CLIPSIBLINGS`, no class brush) drawn through `ID2D1HwndRenderTarget` created from `ID2D1Factory1`.
  - `flip`: the same child drawn through a D2D 1.1 device context on a DXGI `FLIP_SEQUENTIAL` swap chain.
  - `dcrt` (the fallback): no child; the parent's `WM_PAINT` draws the sidebar into a cached 32-bpp DIB through `ID2D1DCRenderTarget::BindDC`, then `BitBlt`s it, which is the shape of today's `Sidebar.paint`.
- **Two GL children** (`CS_OWNDC`, `ChoosePixelFormat`/`SetPixelFormat`/`wglCreateContext` exactly as `Surface.zig`). Each renders from its own thread like Ghostty's renderer, and `WM_SIZE` waits up to 16 ms for a frame, like `Surface.handleResize` during live resize.
- **WebView2**: a host child with a controller and a `NavigateToString` page.
- **Content**: the sidebar draws 40 rows with DirectWrite text, pills and progress bars; one row with color emoji drawn with `D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT`, and a control row drawn without the flag; a 100-DIP ruler; and a 3-px right-edge marker.
- **Classification**: every region has a distinct flat color, so captures are classified per pixel (gaps, stale content, wrong sibling on top).

Tests (`--tests=`):

- `capture`: capture-method semantics.
- `idle`: invalidation isolation.
- `resize` and `drag`: 60-step top-level resize and sidebar-width drag storms.
- `wresize` and `wdrag`: the same storms recorded with Windows.Graphics.Capture.
- `overlap`: deliberate sibling overlap and z-order combinations.
- `dpi`: real off-screen monitor moves plus simulated 96/144/192.
- `devloss`: injected `D2DERR_RECREATE_TARGET` plus 30 full re-creations.
- `timing`: 120 forced repaints.
- `abi`: struct-return ABI.

`matrix.ps1` lists the 24 configurations. `d2d_vtable_check.zig` validates the Zig binding pattern.

### 2.3 Hidden technique and focus safety

- Top-level created with `WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW` at (-32000,-32000) and shown with `SW_SHOWNOACTIVATE`.
- Every `SetWindowPos` carries `SWP_NOACTIVATE`. `SetFocus` and `MoveFocus` are never called. `WM_MOUSEACTIVATE` returns `MA_NOACTIVATE`.
- Launched by `run-s7.ps1` through `ProcessStartInfo{UseShellExecute=false, CreateNoWindow=true}`.
- An external C# sampler checks `GetForegroundWindow` + `GetWindowThreadProcessId` every 50 to 100 ms against our PID and its descendants (Toolhelp parent chain). An in-process watchdog checks every 50 ms.
- **70 runs, about 36 min of runtime, 26,125 external samples: 0 violations, 0 abnormal exits.** The 5 foreground changes observed were the user switching their own windows. The first few smoke runs used a slower WMI-based sampler; the in-process 50 ms watchdog covered every run.

Commands:

```powershell
pwsh docs/arch/spikes/proto/S7/build.ps1  -Out <scratch>            # zig cc ... -ld2d1 -ldwrite -ld3d11 -ldxgi -ldwmapi -lopengl32 -lgdi32 -luser32 -lole32 -lpsapi
pwsh docs/arch/spikes/proto/S7/matrix.ps1 -Out <scratch> -Name m     # 24 hidden runs, results in <scratch>\m\results.jsonl
zig build-exe docs/arch/spikes/proto/S7/d2d_vtable_check.zig -target x86_64-windows-gnu -ld2d1 -luser32
```

## 3. Results

### 3.1 First, what the capture methods actually show (this changed the methodology)

Measured with a repaint probe: change the sidebar color, `InvalidateRect`, do not pump, then capture. Also measured with `GetUpdateRect`/`BeginPaint`/`GetClipBox` logging and with Windows.Graphics.Capture (WGC).

| Observation | Evidence |
|---|---|
| For a top-level that is entirely off-screen, normal `WM_PAINT` gets **`rcPaint` = (0,0,0,0) and a NULLREGION clip box**, for the top-level and for its children. GDI paints and blt-model presents therefore never reach the redirection surface. Only paints driven by `PrintWindow` get a real clip (COMPLEXREGION). | `paintdbg` lines in `results-summary.jsonl` (`GetUpdateRect` = full sidebar, `rcPaint` = empty). |
| **Every `PrintWindow` variant** (flags 0, `PW_CLIENTONLY`, `PW_RENDERFULLCONTENT`) first services the window tree's paints. In practice it is a full synchronous repaint, so the window procedures are re-entered inside `PrintWindow`. | Probe: new color shown; 1 or 2 `WM_PAINT`s during the call. Sync-paint storms: 0 extra `WM_PAINT`s without captures, 1 per step with captures. |
| `PrintWindow` without `PW_RENDERFULLCONTENT` and `BitBlt` from the window DC miss flip-model and DirectComposition content: a flip sidebar and WebView2 come back **white** or host-colored. `BitBlt` also misses later DX presents (it showed a stale sidebar). | `capture` / `capture_child` rows (B1, A1). |
| WGC frames of an off-screen window update only for flip/DComp surfaces. Redirection-surface content (GDI chrome, HWND RT, GL) stays frozen at its first state. | `wgc_frame` rows: a flip sidebar tracked each width step; HWND RT stayed at the initial width while WebView2 drove the frames. |
| A "passive" probe (`DwmFlush` + `PrintWindow` with our `WM_PAINT`s deferred) always shows the pre-step frame, identically for every renderer. DWM keeps the old surface until pending paints are serviced. | `v-*` validation runs. |

Consequence: off-screen, the only faithful capture is `PrintWindow(PW_RENDERFULLCONTENT)`, and it shows the **result of a forced full repaint**. Storms therefore check the settled state after each step, and UI-thread cost is measured in separate capture-free runs (`--nocap`, `timing`). True on-screen transient flicker cannot be observed from an off-screen window (see 3.11).

### 3.2 Steady state: correctness per renderer (`PrintWindow(PW_RENDERFULLCONTENT)`, 1378x844 client, 144 DPI)

| Renderer | Bad sidebar px | Marker | Ruler 100 DIP | Color-emoji px (flag / no flag) | Plain `PrintWindow` / `BitBlt` |
|---|---|---|---|---|---|
| HWND RT, hardware | 0 | ok | 150 px | 322 / 0 | visible |
| HWND RT, software type | 0 | ok | 150 | 322 / 0 | visible |
| DC RT (fallback) | 0 | ok | 150 | 322 / 0 | visible |
| Flip (D2D 1.1 + DXGI) | 0 | ok | 150 | 322 / 0 | **white** |
| HWND RT, layered top-level (`WS_EX_LAYERED`, alpha 230) | 0 | ok | 150 | 322 / 0 | visible |

- Color emoji works in all modes.
- `CheckWindowState()` returns `D2D1_WINDOW_STATE_NONE` (not occluded) for the off-screen window, and an HWND RT also renders (`EndDraw` S_OK) on a never-shown HWND (Zig check).
- The D2D child never changed what the GL siblings or WebView2 showed in any matched configuration (3.12).

### 3.3 Z-order with overlapping siblings (60 px overlap; 3 samples, 120 ms apart, while GL keeps presenting)

| Top of z-order | GL child `WS_CLIPSIBLINGS` | D2D child `WS_CLIPSIBLINGS` | Visible in the overlap |
|---|---|---|---|
| D2D | 0 | 0 | GL (wrong) |
| D2D | 1 | 0 | D2D |
| D2D | 0 | 1 | GL (wrong) |
| D2D | 1 | 1 | D2D |
| GL | 0 | 0 | unstable: gl, gl, d2d (wrong) |
| GL | 1 | 0 | unstable: d2d, d2d, gl (wrong) |
| GL | 0 | 1 | GL |
| GL | 1 | 1 | GL |

- **D2D overlay child above the WebView2 host**: the WebView2 page wins unless the **host** has `WS_CLIPSIBLINGS`; with it, the overlay is visible.
- **D2D overlay above GL**: GL wins unless GL has `WS_CLIPSIBLINGS`.
- **Flip sidebar**: drawn above GL even when it is *below* GL in z-order, unless the flip child itself has `WS_CLIPSIBLINGS`. Its composition surface sits above the redirection surface.
- **Rule**: whichever sibling is lower must clip siblings. Correct, stable z-order in both orders requires `WS_CLIPSIBLINGS` on **every** child.
- Today wmux's terminal surfaces (`Surface.zig`) and browser hosts (`BrowserPane.zig`) are plain `WS_CHILD`.
- Default z-order: the **first-created child is on top** and later children are inserted below (`GW_CHILD` order equals creation order). An overlay created later must be raised explicitly with `SetWindowPos(HWND_TOP)`.

### 3.4 Invalidation isolation

| | Child HWND (HWND RT or flip) | DC RT fallback |
|---|---|---|
| 1.5 s idle while both GL threads present continuously | 0 sidebar paints, 0 parent paints | 0 / 0 |
| 20× `InvalidateRect(parent, tabStrip)` + `UpdateWindow` | 20 parent paints, **0 sidebar frames** | 20 parent paints, **20 sidebar frames** (13 to 20 ms each) |

### 3.5 Resize and sidebar-drag storms (60 steps; settled check after each step)

- **Settled correctness**: inside the sidebar region (no gap pixels, marker present at the new edge), **every step passed in every child-HWND configuration**: HWND RT sync and async, `DeferWindowPos`, no clip, software, retain, flip with STRETCH or NONE scaling, layered, and real 96 DPI (15 runs). The one exception is the deliberately broken "skip render" variant, covered below. The DC RT fallback failed 1 step in 3 of its storms. The other flags all sit in GL1's area right after the sidebar shrank: GL1 bad pixels on up to 10/60 steps (real-96-DPI drag) and stale marker pixels on up to 6/60. GL1 presents asynchronously from its own thread and had not yet covered the strip the sidebar gave up, so the old sidebar pixels were still visible there. This happens identically with the DC RT and is existing wmux behavior, not a sidebar effect.
- **Paints per step without captures** (HWND RT, render in `WM_SIZE` then `ValidateRect`): exactly **1 render per step and 0 `WM_PAINT`s** (60 `WM_SIZE`s, 60 frames).
- **"Skip the render in `WM_PAINT` when nothing changed" broke captures**: 52/60 and 60/60 steps came back with the sidebar missing, and `PrintWindow` stalled for 0.7 to 1 s per step. `PrintWindow` needs a fresh present *during* its forced paint, so the sidebar must always render in `WM_PAINT`.
- **UI-thread cost per step, without captures** (`t_layout` = whole `SetWindowPos` or relayout, including two GL frame waits and WebView2 bounds):

| Config | Layout (resize) mean / max | Layout (drag) | Sidebar frame p50 / p95 / max (resize) | Sidebar frame (drag: width changes, text re-layout) |
|---|---|---|---|---|
| HWND RT, IMMEDIATELY, sync | 33 / 81 ms | 33 / 77 | 6.0 / 9.8 / 14 ms | 9.4 / 12.0 / 31 |
| HWND RT, no GL frame wait | 28 / 50 | 24 / 32 | 6.3 / 13.0 / 18 | 8.9 / 11.2 / 12 |
| DC RT hardware, async | 35 / 71 | 20 / 68 | 13.4 / 31.3 / 41 | 20.3 / 37.9 / 56 |
| DC RT hardware, sync (`RDW_UPDATENOW` in `WM_SIZE`) | 103 / **1203** | 79 / 236 | 14.8 / 182 / **1106** | 30.0 / 165 / 190 |

### 3.6 Rendering cost (120 forced repaints, 390x844 px at 144 DPI, about 13 visible rows; no captures)

| Renderer | Frame p50 | p95 | Draw calls p50 | `EndDraw` (+`Present`) p50 |
|---|---|---|---|---|
| HWND RT, `D2D1_PRESENT_OPTIONS_IMMEDIATELY` | 5.5 to 6.5 ms | 7 to 36 (load) | 3.7 | 1.8 |
| HWND RT, `IMMEDIATELY` + `RETAIN_CONTENTS` | 5.5 | 9.8 | 3.7 | 1.7 |
| HWND RT, `D2D1_PRESENT_OPTIONS_NONE` | **46.8** | 52.9 | 3.8 | **42.7** (blocks on vsync) |
| HWND RT, software type | 8.1 | 13.7 | 3.8 | 3.8 |
| Flip, `Present(0,0)` | 4.9 | 17.1 | 3.5 | 1.0 |
| Flip, `Present(1,0)` | 16.4 | 31.7 | 3.9 | 12.3 |
| DC RT, hardware (`BindDC` + DIB + `BitBlt`) | 19.2 to 20.9 | 46 to 64 | 7.0 to 7.5 | 9.3 to 9.7 (GPU to DIB readback) |
| DC RT, software type | 10.8 | 21.1 | 5.9 | 4.1 |

Off-screen, the final present blit is clipped away, so absolute on-screen costs are slightly higher for every mode. The ratios hold.

### 3.7 DPI

- **Simulated 1.0 / 1.5 / 2.0**: `SetDpi` on the RT, layout in DIPs. Identical in all three renderers:

| DPI | Sidebar width (260 DIP) | Ruler (100 DIP) | Title ink height | Color-emoji px | Bad px |
|---|---|---|---|---|---|
| 96 | 260 px | 100 px | 13 px | 147 | 0 |
| 144 | 390 | 150 | 20 | 322 | 0 |
| 192 | 520 | 200 | 26 | 583 | 0 |

- **Real 96 DPI**: a window created off-screen nearest the 96-DPI monitor, at (1000,3500), gets `GetDpiForWindow` = 96 for the top-level and the child. All sidebar checks passed there in captures and both storms (ruler 100 px, sidebar 260 px, color emoji).
- **Real monitor change**: moving the off-screen window next to the other monitor sends `WM_GETDPISCALEDSIZE(96)` but **never `WM_DPICHANGED`**, and no `WM_DPICHANGED_BEFOREPARENT`/`AFTERPARENT` reach the child. `MonitorFromWindow(DEFAULTTONULL)` = NULL, so Windows does not commit a DPI change for a window that intersects no monitor. The real cross-monitor sequence therefore could not be exercised (open risk 1).
- **Gotcha, measured**: an RT created with `dpiX = dpiY = 0` reports **144** (the system DPI) even when its window is at 96 DPI. Always pass `GetDpiForWindow(hwnd)`.

### 3.8 Device loss and re-creation

| Renderer | Injected `D2DERR_RECREATE_TARGET` | 30× full re-create: create / first frame (mean, max) | Leaks over 30 cycles |
|---|---|---|---|
| HWND RT, hardware | recovered, pixels correct | 9 to 13 ms / **194 to 249 ms** (max 588) | handles, GDI and USER objects constant |
| HWND RT, software | recovered | 1.7 / 31.7 ms | none |
| DC RT, hardware | recovered | 1.0 / 120 ms (max 391) | none |
| DC RT, software | recovered | 0.4 / 57 ms | none |
| Flip | recovered (slow) | **5.2 s** / 0.2 s (max 17 s): `CreateSwapChainForHwnd` on the same HWND stalls after the old chain is released (off-screen; `ClearState`+`Flush` done) | none |

An HWND RT owns its own D3D device, created lazily at the first `EndDraw`. That is why the first frame costs about 0.2 s here, under load. Real TDR and RDP transitions were not triggered (unsafe and unavailable): see open risk 3.

### 3.9 Struct-return ABI (bindings)

`ID2D1RenderTarget::GetSize` is vtable slot 53 (cross-checked against the mingw vtable).

- Hidden-out-pointer call: **260.00 x 562.67 DIP** (correct for 390x844 px at 144 DPI).
- Declared as returning `D2D1_SIZE_F` by value, the way a naive header translation or the mingw C header declares it: **garbage, without a crash** (w = -2.9e-35, h = 6.6e-43). The callee writes through an uninitialized register, i.e. silent memory corruption.
- The Zig check confirms the correct pattern in Zig 0.15.2: `GetSize` = 200 x 133.33 DIP for 300x200 px at 144 DPI; `GetPixelSize` tracks `Resize` (450x300); `GetPixelFormat` = (87, IGNORE).
- Separately, mingw-w64's C macros for methods inherited by D2D 1.1 interfaces (for example `ID2D1DeviceContext_Release`) do not compile against its nested-`Base` vtables. Irrelevant to Zig bindings; a trap for anyone trying `@cImport`.

### 3.10 Flip-model D2D (evaluated as an alternative)

Advantages:

- Cheapest present (1.0 ms).
- Live-composed even off-screen.

Disadvantages:

- Invisible to plain `PrintWindow` and `BitBlt`.
- A separate composition surface that can desynchronize from the redirection surface (GDI chrome, GL) during resize. The off-screen WGC frames showed exactly that split.
- Ignores sibling z-order without `WS_CLIPSIBLINGS`.
- Multi-second swap-chain re-creation.
- More code (D3D11 device, DXGI factory, `ResizeBuffers`, target re-binding).

### 3.11 What could not be measured, and why

- **On-screen transient flicker during a live drag-resize.** Off-screen, normal paints are clipped away, `PrintWindow` forces a full repaint, and DWM neither live-composes the redirection surface nor advances the frame while paints are pending. The decision on flicker therefore rests on structure:
  - The HWND RT presents into the **same redirection surface** as the GDI chrome and (on this Intel ICD) the GL children. DWM's resize synchronization treats it as one surface.
  - Rendering synchronously inside `WM_SIZE` puts the sidebar's new frame in that surface before the window's paint completes.
  - The DC RT fallback has the same property by construction. Flip and DComp surfaces (flip D2D, WebView2) do not.
- **The real per-monitor DPI change sequence** (3.7).
- **RDP / TDR device loss** (3.8).

### 3.12 Observations outside S7's scope (for S2 and W0-B)

- **GL presentation in hidden instances is fragile.** None of the variations below is caused by the D2D child: GL results were identical with and without it in every matched pair, and the only failing layered+WebView2 run was the one *without* the D2D child.

| Top-level | WebView2 | D2D child | GL child created first | GL child created second |
|---|---|---|---|---|
| normal | no / yes | with or without | GL frames | **white** (`glReadPixels` shows correct frames; `SwapBuffers` OK) |
| layered | no | with or without | GL frames | GL frames |
| layered | yes | none | erase color only | erase color only |
| layered | yes | created first | GL frames | GL frames |

- WebView2 output is **color-managed**: `#0080C0` captures as (35,124,188) and `#FF8000` as (252,134,42). Pixel assertions need tolerance or calibration.
- An off-screen window's DPI is decided at creation by the nearest monitor ((-32000,-32000) gives the primary's 144; (1000,3500) gives 96), and it never changes afterwards (3.7). The harness can pick a test DPI by choosing the creation position.

## 4. Decision

**Adopt ADR-11.1 with changes.** `WmuxSidebar` is a child HWND drawn with `ID2D1HwndRenderTarget` from an `ID2D1Factory1` plus DirectWrite. The mandatory changes:

1. **`WS_CLIPSIBLINGS` on every child of the top-level**: the sidebar, terminal surfaces (`Surface.zig`), browser hosts (`BrowserPane.zig`), the right-sidebar host and every future overlay. Without it, z-order is wrong or nondeterministic as soon as siblings overlap (3.3). This touches files the sidebar WP does not own, so it needs a CCR, or W0-A3 does it as a one-line change per file.
2. **`D2D1_PRESENT_OPTIONS_IMMEDIATELY`.** Never `NONE` on the UI thread: it blocks about 43 ms per frame.
3. **Explicit DPI**: create with `GetDpiForWindow(child)`, re-check on every render and `SetDpi` on change. Never `dpi = 0`. Never re-create the RT for DPI or size changes (use `SetDpi` and `Resize`).
4. **Render synchronously in `WM_SIZE`** after `Resize`, then `ValidateRect`. **Always render in `WM_PAINT`** (no "already up to date" skip), because `PrintWindow` depends on it. Return 1 from `WM_ERASEBKGND` and use no class brush.
5. **Device loss**: on `D2DERR_RECREATE_TARGET` from `EndDraw` (or `Resize`), release the RT and everything it created (brushes, bitmaps, layers). Keep the factory, DirectWrite formats and text layouts. `InvalidateRect`; re-create lazily on the next paint. Budget about 0.2 s for the re-creation.
6. **Bindings use the hidden-out-pointer ABI** for every struct-returning method (3.9).
7. **Layout**: move the sidebar and panes in one `BeginDeferWindowPos`/`EndDeferWindowPos` batch. Raise overlays explicitly.

**Fallback**: `BindDC` in the parent's paint remains a working plan B. It is correct, with color emoji, DPI and device loss all fine, and immune to sibling z-order. Use it only if a GPU vendor's GL or WebView2 path turns out to break the child approach in W1-8 manual testing. Costs:

- About 2 to 3x the frame time (hardware DC RT readback), or about 1.8x with `D2D1_RENDER_TARGET_TYPE_SOFTWARE`.
- The sidebar redraws on every parent repaint unless painting is gated on the update region.
- Synchronous use in `WM_SIZE` produced 1 s stalls.
- No focus, scrolling or UIA isolation.

**Rejected**: a flip-model D2D 1.1 swap chain for the sidebar (3.10).

## 5. Guidance for the consuming WPs

### 5.1 W1-8: the `WmuxSidebar` child

Win32 declarations to add (they are missing from `win32.zig` today):

- `WS_CLIPSIBLINGS = 0x04000000`
- `WM_DPICHANGED_BEFOREPARENT = 0x02E2`, `WM_DPICHANGED_AFTERPARENT = 0x02E3`, `WM_GETDPISCALEDSIZE = 0x02E4`
- `HWND_TOP = 0`
- `BeginDeferWindowPos`, `DeferWindowPos`, `EndDeferWindowPos`

Link `d2d1` (planned in W0-A3).

Creation. Create the sidebar in `Window.init` before the first pane, so it is the top sibling by default:

```zig
// class: no CS_*REDRAW needed (we render in WM_SIZE), no background brush
const wc = w32.WNDCLASSEXW{ .cbSize = @sizeOf(w32.WNDCLASSEXW), .style = 0, .lpfnWndProc = &sidebarWndProc,
    .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = app.hinstance, .hIcon = null,
    .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW), .hbrBackground = null, .lpszMenuName = null,
    .lpszClassName = SIDEBAR_CLASS, .hIconSm = null };
const hwnd = w32.CreateWindowExW(0, SIDEBAR_CLASS, L(""), w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPSIBLINGS,
    r.left, r.top, r.right - r.left, r.bottom - r.top, parent_hwnd, null, app.hinstance, null);
```

Render target and render loop:

```zig
fn ensureTarget(self: *Sidebar) !void {
    if (self.rt != null) return;
    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(self.hwnd, &rc);
    const dpi: f32 = @floatFromInt(w32.GetDpiForWindow(self.hwnd)); // never 0
    var rt: ?*d2d.ID2D1HwndRenderTarget = null;
    try d2d.check(self.factory.vtable.CreateHwndRenderTarget(self.factory,
        &.{ .dpi_x = dpi, .dpi_y = dpi }, // DEFAULT type, B8G8R8A8_UNORM + ALPHA_MODE_IGNORE (opaque)
        &.{ .hwnd = self.hwnd,
            .pixel_size = .{ .width = @intCast(@max(rc.right, 1)), .height = @intCast(@max(rc.bottom, 1)) },
            .present_options = d2d.D2D1_PRESENT_OPTIONS_IMMEDIATELY },
        &rt));
    self.rt = rt.?;
    self.rt_dpi = dpi;
    // device-dependent resources are created from the RT and dropped with it
    try d2d.check(self.rt.?.createSolidColorBrush(&.{ .r = 1, .g = 1, .b = 1, .a = 1 }, &self.brush));
}

fn render(self: *Sidebar) void {
    self.ensureTarget() catch return;
    const rt = self.rt.?;
    const dpi: f32 = @floatFromInt(w32.GetDpiForWindow(self.hwnd));
    if (dpi != self.rt_dpi) { rt.vtable.SetDpi(rt, dpi, dpi); self.rt_dpi = dpi; } // layouts stay in DIPs
    rt.vtable.BeginDraw(rt);
    self.paintRows(rt); // Clear + visible rows; DrawTextLayout(..., ENABLE_COLOR_FONT | CLIP)
    const hr = rt.vtable.EndDraw(rt, null, null);
    if (hr == d2d.D2DERR_RECREATE_TARGET) {
        self.discardDeviceResources(); // brush, bitmaps, layers, then the RT; keep factory/formats/layouts
        _ = w32.InvalidateRect(self.hwnd, null, 0);
    }
}

fn sidebarWndProc(hwnd: w32.HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SIZE => {
            const size = d2d.D2D1_SIZE_U{ .width = @intCast(lp & 0xFFFF), .height = @intCast((lp >> 16) & 0xFFFF) };
            if (self.rt) |rt| if (rt.vtable.Resize(rt, &size) == d2d.D2DERR_RECREATE_TARGET) self.discardDeviceResources();
            self.relayoutIfWidthChanged(); // row_layout cache keyed by width + DPI
            self.render(); // synchronous: the frame is in the redirection surface before the parent finishes painting
            _ = w32.ValidateRect(hwnd, null);
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            _ = w32.BeginPaint(hwnd, &ps);
            self.render(); // ALWAYS render: PrintWindow-driven paints need a fresh present
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        WM_DPICHANGED_AFTERPARENT => { _ = w32.InvalidateRect(hwnd, null, 0); return 0; }, // render() re-reads the DPI
        else => return w32.DefWindowProcW(hwnd, msg, wp, lp),
    }
}
```

Top level (`chrome` window hook) and layout:

```zig
w32.WM_DPICHANGED => {
    const r: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
    _ = w32.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top,
        w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    window.layoutAll(); // children get WM_SIZE; the sidebar picks up the new DPI in render()
    return 0;
},

fn layoutAll(self: *Window) void { // sidebar + panes in one batch
    var d = w32.BeginDeferWindowPos(@intCast(1 + self.visiblePaneCount())) orelse return self.layoutSequential();
    const f = w32.SWP_NOZORDER | w32.SWP_NOACTIVATE | w32.SWP_NOOWNERZORDER;
    d = w32.DeferWindowPos(d, self.sidebar_hwnd, null, sb.left, sb.top, sbw, sbh, f) orelse return;
    // ... each visible pane HWND ...
    _ = w32.EndDeferWindowPos(d);
}
```

Other W1-8 work items:

- **Input moves into the child.** `Window.zig` today routes `x < sidebarWidth()` clicks, double-clicks, row drags, wheel and the edge drag (`hitTestSidebarEdge`). In the child, `SetCapture` goes on the child during row drags. For the edge drag, either the child treats its right 4 px as the splitter and reports the new width to `Window`, or `Window` keeps a parent-owned splitter strip that the child does not cover. Remove `Sidebar.paint` from `paintChrome`, and stop `invalidateSidebar` from invalidating the parent.
- **Budget.** A full repaint costs about 6 ms (median) at 1.5x on this iGPU. Width changes add DirectWrite re-layout: drag frames ran about 9 ms. Cache `IDWriteTextLayout` per row by (content hash, width), as ADR-11.2 says. Keep a single brush and call `SetColor` (that is what the prototype does).
- **Startup.** The first `EndDraw` creates the D3D device: about 0.2 s here. Paint the sidebar once early in window creation and measure cold-start impact.
- **Never** `D2D1_PRESENT_OPTIONS_NONE`. Never re-create the RT for size or DPI. Never skip the render in `WM_PAINT`.
- **Manual checks to record in the WP**:
  1. Drag the window between the 144 and 96 DPI monitors: the sidebar is crisp with no blur, row geometry and fonts update, and `WM_DPICHANGED_AFTERPARENT` reaches the child.
  2. Live-resize and drag the sidebar edge on screen, looking for gaps or flashes.
  3. RDP disconnect and reconnect: the sidebar recovers.

  A human can run the prototype visibly with `s7proto.exe --pos=200,200 --webview=1 --steps=300 --tests=resize,drag` (still non-activating).
- **Debug hook.** Inject device loss in tests, for example `wmux.debug.sidebar.simulateDeviceLoss` setting a one-shot flag that makes the next `EndDraw` result count as `D2DERR_RECREATE_TARGET`. Real TDR cannot be triggered safely.

### 5.2 W1-8a: D2D and DirectWrite bindings

- **Hand-written `extern struct` vtables work** (`d2d_vtable_check.zig`). Methods that return a struct take a **hidden out-pointer after `this` and return that pointer**:

```zig
GetSize: *const fn (*ID2D1RenderTarget, *D2D1_SIZE_F) callconv(.winapi) *D2D1_SIZE_F, // slot 53
pub fn getSize(self: *ID2D1RenderTarget) D2D1_SIZE_F {
    var out: D2D1_SIZE_F = undefined;
    _ = self.vtable.GetSize(self, &out);
    return out;
}
```

  This applies to at least `ID2D1RenderTarget.GetSize/GetPixelSize/GetPixelFormat`, `ID2D1Bitmap.GetSize/GetPixelSize/GetPixelFormat`, `ID2D1Brush`/`ID2D1SolidColorBrush.GetColor` and `ID2D1DeviceContext.GetSize/GetPixelSize`. It applies whatever the struct size. With 8 bytes or less, a by-value declaration expects the result in RAX. With more (e.g. `D2D1_COLOR_F`), the C ABI puts the hidden pointer *before* `this`, while the C++ method expects it *after* `this`. Parameters passed by value (`D2D1_POINT_2F` origin in `DrawTextLayout`, the WebView2 `RECT`) are fine as-is.
- **Slots used and verified**:
  - `ID2D1Factory`: `CreateHwndRenderTarget` 14, `CreateDCRenderTarget` 16.
  - `ID2D1RenderTarget`: `CreateSolidColorBrush` 8, `FillRectangle` 17, `FillRoundedRectangle` 19, `DrawTextLayout` 28, `SetTransform` 30, `SetAntialiasMode` 32, `SetTextAntialiasMode` 34, `Clear` 47, `BeginDraw` 48, `EndDraw` 49, `GetPixelFormat` 50, `SetDpi` 51, `GetDpi` 52, `GetSize` 53, `GetPixelSize` 54.
  - `ID2D1HwndRenderTarget`: `CheckWindowState` 57, `Resize` 58, `GetHwnd` 59.
  - `ID2D1DCRenderTarget`: `BindDC` 57.
- **Constants**: `D2DERR_RECREATE_TARGET` = 0x8899000C; `D2D1_PRESENT_OPTIONS_IMMEDIATELY` = 2; `DXGI_FORMAT_B8G8R8A8_UNORM` = 87; `D2D1_ALPHA_MODE_IGNORE` = 3; `D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT` = 4.
- Factory: `D2D1CreateFactory(SINGLE_THREADED, IID_ID2D1Factory1)`, one per app, UI thread only (G3). An HWND RT can be created on a hidden or never-shown window.
- Do not `@cImport` mingw's `d2d1_1.h` for C-style calls: its inherited-method macros are broken (3.9).

### 5.3 W5: tab bars through `BindDC` in the double-buffered paint

- **Hardware DC RT** pays a GPU-to-DIB readback in `EndDraw`: about 9 ms (median) for 390x844 px.
- For thin strips, measure `D2D1_RENDER_TARGET_TYPE_SOFTWARE`: about 1.8x cheaper than hardware here, and it re-creates in about 57 ms versus 120 ms.
- **Gate the DC RT paint on `ps.rcPaint`**, or every chrome invalidation redraws everything (3.4). Off-screen, `rcPaint` is empty and `PrintWindow`-driven paints get the real rectangle, so gating is safe for tests too.
- Never call `RedrawWindow(..., RDW_UPDATENOW)` with a hardware DC RT inside `WM_SIZE` (1 s stalls).

### 5.4 W0-B and S2: hidden-instance harness

- **Pixel assertions** must use `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)`.
  - It performs a full synchronous repaint first. App window procedures re-enter during the call (in-process) or the target thread services it (cross-process), so do not call it while holding locks the UI thread needs.
  - It is the only method that sees DirectComposition, flip and WebView2 content.
- **Do not** use `BitBlt` from window DCs or WGC on off-screen instances (3.1).
- Off-screen, normal paints are clipped away (empty `rcPaint`/clip box). Anything that reads back without `PrintWindow` sees stale content.
- **GL**: only the first-created GL child of a non-layered hidden window shows frames, and later GL children read back white (3.12). Assert on GL panes only for the first pane, or report the issue to S2.
- **WebView2** colors are color-managed: compare with tolerance, or calibrate from a reference element.
- **DPI**: choose an instance's DPI by its off-screen creation position. Off-screen moves never change DPI.

### 5.5 W7: UIA

- The sidebar child is the natural anchor for the `List`/`ListItem` provider (ADR-11.5), and keyboard focus for `focusSidebar` can live on it.

## 6. Open risks

1. **Real cross-monitor DPI change** for a PMv2 window with a D2D child: the order of `WM_DPICHANGED_BEFOREPARENT`, `WM_DPICHANGED` and `WM_DPICHANGED_AFTERPARENT`, and when `GetDpiForWindow(child)` flips, are unobserved. Windows does not commit DPI changes for off-screen windows. Mitigation: `render()` re-reads the DPI on every frame, plus the manual check in 5.1.
2. **On-screen transient flicker** during live resize could not be observed (3.11). The structural argument favors the HWND RT (same redirection surface, synchronous `WM_SIZE` render). The manual check is required in W1-8.
3. **RDP, TDR and adapter changes** were never triggered; only injected loss and full re-creation were tested. Mitigation: debug injection hook plus a manual RDP test (ADR-11.6 already asks for it).
4. **One GPU vendor** (Intel iGPU, GL 4.6 driver 32.0.101.8860). On NVIDIA or AMD, a GL ICD that presents GL through DXGI flip model would make GL a separate composition surface. That raises the same desync and `WS_CLIPSIBLINGS` concerns as flip D2D, but not for the sidebar itself.
5. **Each HWND RT owns a D3D device**: about 0.2 s to create and some MB per device. If W1-8 or W5 add more D2D child windows (right-sidebar mode bar, overlays, tab bars), re-evaluate one shared D3D11 device with D2D 1.1 per-window targets.
6. **Timing measured under heavy parallel load and off-screen.** Medians are representative; p95 and max values are noisy.
7. **Hidden-instance GL fragility** (3.12) can make GL-pane e2e assertions flaky regardless of the sidebar. This belongs to S2/W0-B.

## 7. Files

- `proto/S7/s7proto.c`: the prototype (all modes, tests and classifiers).
- `proto/S7/d2d_vtable_check.zig`: Zig binding pattern and struct-return ABI check.
- `proto/S7/build.ps1`, `run-s7.ps1` (hidden launcher plus foreground sampler), `matrix.ps1` (the 24 runs).
- `proto/S7/results-summary.jsonl`: condensed evidence behind every number above (storms, timing, overlap, DPI, device loss, capture probes, paint and WGC diagnostics). DC RT rows come from the re-run after the `rcPaint` fix.
- No wmux sources were modified; there is no patch.
