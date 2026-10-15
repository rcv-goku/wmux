# Spike S2: hidden e2e instances (decision note)

| | |
|---|---|
| Spike | S2 (ARCHITECTURE ADR-14.7), W0-D-S2 |
| Consumers | W0-B (harness v0, `test/e2e/WmuxTest.psm1`), every e2e suite (Appendix D), the owners of `app/runtime_env.zig` and `app/foreground.zig` (ADR-12.3, ADR-3.11), CI (ADR-12.6) |
| Baseline | wmux `master` @ `aa1f532`, debug build |
| Date | 2026-10-15 |
| Decision | **Adopt with changes**: keep the styles and the no-activation rules, but replace the (-32000, -32000) placement with "fully on the primary monitor + `DWMWA_CLOAK`". Reject the alternate-desktop fallback. |

## 1. Question

ADR-12.3 specifies `WMUX_TEST_HIDDEN=1` like this: top-level windows are `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`, placed at (-32000, -32000) with a fixed 1600x1000 client area, shown only with `SW_SHOWNOACTIVATE`, and nothing activates them. With that recipe, do the following hold on a real machine?

1. ConPTY spawns and a shell runs. Check: on the legacy pipe `\\.\pipe\wmux-ipc-<pid>`, `send "echo hi"` is followed by a `read-screen` that contains `hi`.
2. The OpenGL renderer's output can be captured: `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` gives an image that is not blank.
3. A WebView2 browser pane can be created and navigated.
4. The OS foreground window never belongs to the instance, and the user's foreground window is the same before and after.
5. The instance does not appear in the taskbar or in Alt-Tab.

If any of these fails: does an alternate desktop (`CreateDesktop` + `STARTUPINFO.lpDesktop`) work instead, and does GL work there?

## 2. Answer in short

- **Points 1, 3, 4 and 5 hold** in every run: 11 runs of the patched wmux and 14 runs of a standalone probe. They held even when the launching process had OS foreground rights, so the child inherited them (the worst case).
- **Point 2 fails at (-32000, -32000).** GL renders correctly (a back-buffer readback returns the expected pixel). But on this Intel OpenGL driver, presented frames reach the DWM redirection surface only for the part of the window that lies on a monitor. `PrintWindow` therefore returns the GL area as solid white. The GDI chrome and the WebView2 content are captured. The alternate desktop fails the same way.
- **Fix that works:** place the hidden window fully inside the primary monitor's work area and cloak it with `DwmSetWindowAttribute(DWMWA_CLOAK)` before the first `ShowWindow`. Then GL is captured (`cloak-terminal.png`), and the window is still invisible, not hit-testable, absent from the taskbar and Alt-Tab, and never foreground.

## 3. Setup

### 3.1 Machine and versions

| Item | Value |
|---|---|
| OS | Windows 11 Enterprise 25H2, build 10.0.26200.9448 |
| Hardware | Dell Pro 16 PC16250, 14 logical CPUs, 64 GB RAM. CPU load was 100% during most runs because other agents were building in parallel. |
| GPU / GL | Intel(R) Graphics, driver 32.0.101.8860. `GL_VERSION` "4.6.0 - Build 32.0.101.8860"; a 4.3 core context via `wglCreateContextAttribsARB` works. |
| Displays | Two monitors (primary 2560x1440). The hidden wmux window reported `GetDpiForWindow` = 144 and WebView2 `devicePixelRatio` = 1.5. |
| WebView2 | Runtime 155.0.4283.45; `WebView2Loader.dll` 1.0.3485.44, copied into the worktree's ignored `zig-out\bin` |
| Toolchain | Zig 0.15.2; `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu` (debug, console subsystem). Fresh worktree: 425 s; incremental: 180-310 s. |
| Driver host | PowerShell 7.6.6 on .NET 10.0.12. Helpers are compiled with `Add-Type -Path S2Native.cs`. |
| Launch | `ProcessStartInfo{UseShellExecute=false, CreateNoWindow=true}` with stdout and stderr redirected. Started from a PowerShell that itself runs under Windows Terminal. |

### 3.2 Prototypes (under `proto/S2/`)

- **`hidden_probe.zig`**: standalone Win32 + WGL + GDI program, about 600 lines. It creates a 1600x1000-client top-level window with a GL child and draws a test pattern: dark-blue background with red, green and white 200x100 rectangles. It then captures the window with `PrintWindow` in three ways (window, client, legacy) and counts pattern pixels.
  - Flags: `--ex=<hex>`, `--x/--y`, `--cloak`, `--gdi`, `--focus` (calls `SetFocus` on the child), `--readback`, `--cbt` (thread-local `WH_CBT` hook), `--msgbox` (requires `--cbt`), `--hold`.
  - Safety: after every step it checks `GetForegroundWindow()` and exits with code 3 if the window is ours. It refuses to show an on-screen window whose cloak did not take effect.
  - Build: `zig build-exe hidden_probe.zig -target x86_64-windows-gnu -O Debug -lc -luser32 -lgdi32 -lopengl32 -ldwmapi -femit-bin=<out>\hidden_probe.exe`
- **`wmux-hidden-mode.patch`**: the wmux patch used for the experiments. It applies cleanly to `aa1f532`; the sources have been reverted.
  - New file `hidden_mode.zig`, read once in `App.init`.
  - In `win32.zig`, `CreateWindowExW`, `ShowWindow`, `SetWindowPos`, `SetFocus` and `SetForegroundWindow` now go through a policy (`raw.*` keeps the original externs):
    - Every top-level window gets `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`.
    - With the cloak placement, every top-level window is cloaked right after creation.
    - Top-level `ShowWindow` calls become `SW_SHOWNOACTIVATE`; top-level `SetWindowPos` calls get `|SWP_NOACTIVATE`.
    - `SetForegroundWindow` and `raiseForegroundWindow` are no-ops; `raiseForegroundWindow` returns before calling `AttachThreadInput`.
    - Under the `gate` policy, `SetFocus` runs only when the window's top-level ancestor is already the active window.
  - `Window.init` uses a fixed rect computed with `AdjustWindowRectEx` from the final ex-style, and skips restoring or saving the window placement.
  - Spike-only knobs: `WMUX_TEST_HIDDEN_PLACEMENT=offscreen|cloak` and `WMUX_TEST_HIDDEN_FOCUS=gate|keep`.
- **`S2Native.cs`**, reusable by W0-B:
  - `FgSampler`: reads the foreground window every 50 ms. It watches the whole process tree: the root PID plus descendants from a Toolhelp snapshot taken every 250 ms; PIDs that have exited stay on the list. On a violation it kills the tree.
  - Visibility guard: fails when a window of the tree is visible, `DWMWA_CLOAKED` is successfully queried as 0, and `MonitorFromRect(..., MONITOR_DEFAULTTONULL)` is non-null.
  - Window inventory with an Alt-Tab eligibility check.
  - `PrintWindow` into a 32bpp DIB plus a minimal PNG writer, so no System.Drawing is needed.
  - `GetGUIThreadInfo`.
  - Foreground-rights probe: `AllowSetForegroundWindow(own pid)`, which succeeds only if the caller already holds the right.
  - `CreateDesktopW` plus a `CreateProcessW` launcher that sets `lpDesktop`.
- **`run-probe.ps1`** and **`run-wmux-hidden.ps1`**: the drivers. Taskbar check: UI Automation lists the buttons under `Shell_TrayWnd` and `Shell_SecondaryTrayWnd` whose `AutomationId` is `Appid:*`, taken before and during the run. Each enumeration takes about 1 s.

### 3.3 Isolation used on today's master (before W1)

Without isolation, a test instance reads and writes the user's `%LOCALAPPDATA%\ghostty\{window-state, session-state.json, scrollback, webview2, update_check_at}`. It would also join the user's WebView2 user-data folder, which means attaching to the user's browser process.

The driver therefore sets `LOCALAPPDATA`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` to a per-run root and removes inherited `GHOSTTY_*`, `WMUX_*` and `CMUX_*` variables. It also pre-writes `<root>\localappdata\ghostty\update_check_at` with the current time, which skips the update check and its tray balloon. The Ghostty config is:

```
command = cmd.exe /d /k prompt WMUX$G
confirm-close-surface = false
```

Reproduce:

```powershell
pwsh -NoProfile -File docs\arch\spikes\proto\S2\run-wmux-hidden.ps1 -Exe <wt>\zig-out\bin\wmux.exe -OutDir <dir> -Placement cloak -Focus gate -Taskbar -GracefulStop
pwsh -NoProfile -File docs\arch\spikes\proto\S2\run-probe.ps1 -Probe <dir>\hidden_probe.exe -OutDir <dir> -Tag p4 -ProbeArgs '--cloak','--x=100','--y=100','--readback'
```

## 4. Results

### 4.1 Probe matrix (`hidden_probe.exe`)

All windows used ex-style `0x08000180` (`NOACTIVATE|TOOLWINDOW` plus the automatic `WINDOWEDGE`), except where the table says otherwise. "PrintWindow client" counts pixels in the 1,600,000-pixel client area: red / green / background / white. A rectangle that was captured shows up as 19,800 red (and green) pixels.

| Run | Placement / flags | Rights* | Foreground change | PrintWindow client (red / green / bg / white) | Notes |
|---|---|---|---|---|---|
| p2 | off-screen, GDI pattern | yes | none | 19,800 / 19,800 / 1,537,800 / 19,800 | GDI is captured off-screen |
| p3 | off-screen, GL | yes | none | 0 / 0 / 0 / 1,600,000 | back-buffer readback = 255,0,0,255: GL rendered, the present never landed |
| p4 | on-screen (100,100) + `DWMWA_CLOAK` | yes | none | 19,800 / 19,800 / 1,537,800 / 19,800 | `WindowFromPoint` at the centre does not return our window |
| p5 | cloaked, x=-1000 (partly off-screen) | yes | none | 0 / 0 / 607,392 / 992,000 | only the 608 columns on a monitor were presented: presents are clipped to window ∩ monitors |
| p6 | off-screen + `SetFocus(child)` | yes | none | white, as p3 | local activation: `WM_ACTIVATEAPP(1)`, `WM_NCACTIVATE(0)`, `WM_ACTIVATE(1)`, `WM_SETFOCUS`; `GetActiveWindow()==top` |
| p7 | cloaked + `SetFocus(child)` | yes | none | as p4 | same local activation, no OS foreground |
| p8 | alternate desktop, on-screen, GL | yes** | none | 0 / 0 / 0 / 1,600,000 | Intel ICD loads (GL 4.6 / 4.3 core, not "GDI Generic"); readback correct; GL not captured |
| p9 | alternate desktop, GDI | yes** | none | 19,800 / 19,800 / 1,537,800 / 19,800 | |
| p10 | hidden recipe, held 2.5 s | yes | none | n/a | no taskbar button; not an Alt-Tab candidate |
| p11 | **control**: `--ex=0`, off-screen, `SW_SHOWNOACTIVATE` | yes | none | n/a | taskbar button "hidden_probe - 1 running window" on both taskbars; Alt-Tab candidate. The detector works. |
| p12 | `--cbt --cloak --msgbox` | no | none | n/a | cloak inside `HCBT_CREATEWND` fails (see below), so the hook falls back to (-32000,-32000). The `MessageBox` dialog (`#32770`) inherits the owner's cloak (`DWMWA_CLOAKED=1`). `HCBT_ACTIVATE` was blocked twice. `MessageBox` returned `IDOK` after `WM_CLOSE`. |
| p13 | `--cbt --cloak --focus` | no | none | n/a | activation blocked by the hook, so `SetFocus` has no effect (same result as the `gate` policy) |

\* "Rights": the probe's own `AllowSetForegroundWindow(own pid)` succeeded, meaning it inherited foreground rights. This happened while the user had Windows Terminal focused.
\*\* On the alternate desktop, `GetForegroundWindow()` was NULL ("no foreground window" rule).

p1 and p14 repeated p3 and p7 with the same outcome. In p1 the user switched from Teams to Edge during the run; the switch involved no process of ours.

Failing call: `DwmSetWindowAttribute(DWMWA_CLOAK)` inside a `WH_CBT` `HCBT_CREATEWND` callback returns `0x80070006` (`E_HANDLE`). The same call made right after `CreateWindowExW` returns `S_OK`, and `DWMWA_CLOAKED` then reads 1.

### 4.2 wmux matrix (patched debug `wmux.exe`, legacy pipe protocol)

Common to all runs:

- `send {"text":"echo hi","enter":true}` was followed by a `read-screen` containing a line `hi`, and `send "set /a 6*7"` by a line `42`. Every run passed both.
- `open {"url":"about:blank","target":"tab"}` returned `{"id":1}`; `eval location.href` returned `"about:blank"`; `navigate` to a `data:` URL succeeded; `eval document.body.innerText` returned `S2 hidden WebView2`. Every run passed.
- `document.visibilityState` was `visible`, `hidden=false` and `hasFocus()=false` in every run. rAF ran 44-96 times per ~1.55 s, so there was no occlusion throttling.
- WebView2 content was captured in both placements. `#CC0000` was captured as `#CA1E10` (display color management): never compare exact colors.

| Run | Placement / focus | Rights | Pipe ready | First prompt | Terminal child capture (distinct colors, dominant) | WebView2 ready | Foreground violations / samples | Visible violations | Taskbar new / Alt-Tab | Stop |
|---|---|---|---|---|---|---|---|---|---|---|
| w1 | off-screen / gate | **yes** | 12,237 ms† | 17,144 ms | 1, 0xFFFFFF 100% | 2,154 ms | 0 / 327 | (guard added after w1) | 0 / 0 | kill |
| w2 | cloak / gate | no (locked) | 4,355 ms | 10,044 ms | 246, 0x282C34 99.65% | 2,709 ms | 0 / 219 | 0 | 0 / 0 | kill |
| w3 | cloak / keep | no (locked) | 1,373 ms | 9,948 ms | 246, 0x282C34 | 4,086 ms | 0 / 168 | 0 | 0 / 0 | kill |
| w4 | off-screen / keep | no (locked) | 1,222 ms | 4,115 ms | 1, 0xFFFFFF | 2,512 ms | 0 / 148 | 0 | 0 / 0 | kill |
| w5 x3 | cloak / gate | no (locked) | 1,296-2,285 ms | 4,081-5,619 ms | 246, 0x282C34 | 4,334-5,513 ms | 0 / 141-259 | 0 | n/a / 0 | kill |
| w6 | cloak / gate | no (locked) | 1,912 ms | 3,586 ms | 246, 0x282C34 | 4,357 ms | 0 / 208 | 1‡ | n/a / 0 | kill |
| w7 | cloak / gate | no (locked) | 2,596 ms | 12,143 ms | 246, 0x282C34 | 4,672 ms | 0 / 484 | 0 | 0 / 0 | WM_CLOSE, 2,205 ms |
| w8 | cloak / gate (final build) | no | 3,516 ms | 4,829 ms | 246, 0x282C34 | 2,587 ms | 0 / 387 | 0 | 0 / 0 | WM_CLOSE, 1,010 ms |
| w9 | off-screen / gate (final build) | no | 366 ms | 1,022 ms | 1, 0xFFFFFF | 2,621 ms | 0 / 280 | 0 | 0 / 0 | WM_CLOSE, 748 ms |

† This was the first launch of a freshly linked 61 MB debug exe; `Process.Start` itself took about 11 s, consistent with on-access antivirus scanning.
‡ A teardown race during `Kill`: a window being destroyed made the DWM query fail. The guard now counts only successful "not cloaked" answers and is switched off during teardown.

What else the runs showed:

- **Foreground.**
  - The user's foreground window was the same before and after every wmux run: Windows Terminal in w1; `LockApp` while the workstation was locked (w2-w7); Teams (w8, w9).
  - In w1 the launcher held foreground rights, so the child inherited them; still nothing activated.
  - The patch log shows the only activation attempts wmux made in these flows:
    - `ShowWindow(main, SW_SHOW=5)` from `Window.addTabWithCommand`, rewritten to `SW_SHOWNOACTIVATE`;
    - `SetFocus` on the terminal surface, the browser host and the address `Edit`, all three gated.
- **Win32 focus state** (`GetGUIThreadInfo` on the UI thread): with `gate`, `active=0 focus=0`. With `keep`, `active=<main>` and `focus=<surface>`, and later `focus=<address Edit>`. That is local activation only, with no OS foreground change.
- **Windows of the process tree** (wmux, 2x conhost, cmd, 6x msedgewebview2):
  - Visible: `WmuxWindow`, `WmuxPaneButtons` and `GhosttyScrollbar`, all `0x08..0080`-styled (tool window, no-activate). With the cloak placement all three were cloaked (`DWMWA_CLOAKED=1`); child windows reported 5 (`APP|INHERITED`).
  - Hidden: `PseudoConsoleWindow`, Chrome helper windows, IME windows.
  - No window was an Alt-Tab candidate, and no taskbar button appeared (runs with `-Taskbar`).
- **Hit testing:** with the cloak placement, `WindowFromPoint` at the hidden window's centre returned the user's window underneath (Windows Terminal in w8; `LockApp` while locked). User clicks pass through.
- **Locked workstation:** w2-w7 ran while the session was locked. DWM kept composing, so GL capture and WebView2 kept working.
- **DPI:** the driver's own DPI awareness changes what it sees. In w5 and w6 the driver process was DPI-unaware; it saw the 1622x1056 window as 1081x704, and `PrintWindow` returned a downscaled 1081x704 image. Runs that loaded UI Automation (`-Taskbar`) were per-monitor aware and saw 1622x1056.
- **Teardown:**
  - `WM_CLOSE` exits cleanly in 0.75-2.2 s. Its hidden-mode handler skips `savePlacement`, and `confirm-close-surface=false` prevents a dialog.
  - After either a graceful exit or `Kill(entireProcessTree)`, the WebView2 user-data folder stayed locked for about 25-60 s: `ERROR_SHARING_VIOLATION` on `EBWebView\lockfile` and leveldb `LOCK`/`*.log`.
  - The lock holders were the instance's own `msedgewebview2` processes. After a graceful exit they live on as orphans for about 30-60 s (`Kill(true)` cannot reach them once wmux has exited). After a kill they are terminated but still in teardown: `Process.GetProcessById` says "not running" while `Win32_Process` still lists them.

### 4.3 Fallback: alternate desktop

`CreateDesktopW("S2Desk-<hex>", GENERIC_ALL)` plus `CreateProcessW` with `STARTUPINFOW.lpDesktop = "WinSta0\S2Desk-<hex>"` and `CREATE_NO_WINDOW` launch fine. `SwitchDesktop` is never called, and `CloseDesktop` destroys the desktop object once the process exits.

GL works on that desktop (the Intel ICD loads; no GDI Generic fallback). But presented frames are not visible to `PrintWindow` there either (p8). GDI content is (p9). For screenshots this is no better than off-screen, and harness plumbing (sampling, capture, enumeration) becomes per-desktop. **Rejected.**

## 5. Decision

**Adopt with changes.**

1. **Keep:**
   - `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE` on every top-level window, including owned popups;
   - top-level windows shown only with `SW_SHOWNOACTIVATE`;
   - no activation APIs (`SetForegroundWindow`, `AttachThreadInput`, activating `ShowWindow`/`SetWindowPos`);
   - launch via `ProcessStartInfo{UseShellExecute=false, CreateNoWindow=true}`;
   - the foreground sampler.
2. **Change the placement in ADR-12.3.**
   - Old: "(-32000, -32000)".
   - New: "Fully inside the primary monitor's work area, with the client area clamped to that work area minus the frame. Cloaked with `DWMWA_CLOAK` after `CreateWindowExW` and before the first `ShowWindow`. Cloaking is verified via `DWMWA_CLOAKED`. If cloaking fails, the window moves to (-32000, -32000); GL content is then not capturable, and the harness reports GL screenshot assertions as inconclusive."
   - Reason: on a real GPU driver, off-screen and alternate-desktop windows produce blank GL screenshots.
3. **Focus policy in hidden mode:** `gate`, meaning no Win32 activation at all, not even local. `keep` was also safe for the OS foreground (p6, p7, w3, w4), but `gate` gives zero activation by construction. Logical focus (`wmux.debug.focus_state`) stays the asserted truth.
4. **Alternate desktop:** rejected.
5. **Changes requested from the lead architect:**
   - ADR-12.3: the placement text above, the `gate` focus policy, and the WH_CBT rule in §6.1.
   - Appendix D.2 step 7: the sampler watches the whole process tree and includes a visibility guard.
   - D.3 `Get-WmuxScreenshot`: the GL caveat, and a DPI-aware harness.
   - D.3 `Stop-WmuxInstance`: graceful stop, then a kill of orphaned WebView2 processes, then asynchronous deletion of the state root.
   - ADR-12.6: the CI display-size note in §6.3.

## 6. Guidance for the consuming WPs

### 6.1 W0-A / W1: `app/runtime_env.zig`, `app/foreground.zig`, `platform/win32.zig`

Read `WMUX_TEST_HIDDEN` once on the UI thread, before any window exists. Route every top-level window through one creation path. Code written for this spike (`hidden_mode.zig` in the patch):

```zig
// Top-level = no WS_CHILD and not a message-only window.
fn isTopLevelCreate(style: u32, parent: ?HWND) bool {
    return style & WS_CHILD == 0 and parent != HWND_MESSAGE;
}

// 1. ex-style for every top-level window (main window and owned popups)
const ex = if (hidden) ex_in | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE else ex_in;

// 2. size from the client area using the FINAL ex-style (a tool window has a
//    smaller caption: 1600x1000 client -> 1622x1056 window at 144 DPI here)
var r: RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
_ = AdjustWindowRectEx(&r, style, 0, ex);
//    position = primary work-area origin; clamp client_w/h to the work area
//    MonitorFromPoint(.{0,0}, MONITOR_DEFAULTTOPRIMARY) -> GetMonitorInfoW().rcWork

// 3. create WITHOUT WS_VISIBLE, then cloak, verify, or fall back off-screen
const hwnd = CreateWindowExW(ex, cls, title, style, x, y, w, h, null, null, hinst, null);
const on: u32 = 1;
const hr = DwmSetWindowAttribute(hwnd, 13 /* DWMWA_CLOAK */, &on, 4);
var st: u32 = 0;
_ = DwmGetWindowAttribute(hwnd, 14 /* DWMWA_CLOAKED */, &st, 4);
if (hr != 0 or st == 0) // never leave a visible window on the user's screen
    _ = SetWindowPos(hwnd, null, -32000, -32000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

// 4. show without activation
_ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
```

Activation choke points, all no-ops or rewrites in hidden mode:

- **`ShowWindow`** on a top-level window: anything other than `SW_HIDE`, `SW_SHOWNA` or `SW_SHOWNOACTIVATE` becomes `SW_SHOWNOACTIVATE`. This includes maximize and restore.
- **`SetWindowPos`** on a top-level window: add `SWP_NOACTIVATE`. Without that flag, `SetWindowPos` activates the window.
- **`SetForegroundWindow`, `raiseForegroundWindow`, `forceForegroundWindow`:** return immediately, and in particular before `AttachThreadInput`. The current `raiseForegroundWindow` attaches to the user's foreground thread.
- **`SetFocus(h)`:** call it only when `GetAncestor(h, GA_ROOT) == GetActiveWindow()`, which never happens in hidden mode. `SetFocus` on a child of an inactive top-level window activates that top-level window (p6).
- Per ADR-3.11, activation APIs live only in `app/foreground.zig`. A lint over `platform/win32.zig` users enforces that.

Other rules:

- **Windows created by user32 itself** (`MessageBox`, `TrackPopupMenu` menus, tooltips, common dialogs) bypass the wrappers. In hidden mode, install a thread-local `WH_CBT` hook on the UI thread with `SetWindowsHookExW(WH_CBT, proc, null, GetCurrentThreadId())`:
  - On `HCBT_CREATEWND` for a top-level window, set `lpcs.x/y` to -32000. Do **not** cloak there (`E_HANDLE`).
  - On `HCBT_ACTIVATE`, return 1.
  - Owned windows inherit their owner's cloak (seen for the IME window and the `MessageBox` dialog). Activation stayed blocked, yet the dialog still worked (p12). The hook from the probe:

  ```zig
  fn cbtProc(code: i32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
      if (code == HCBT_CREATEWND) {
          const cs = (@as(*CBT_CREATEWNDW, @ptrFromInt(@as(usize, @bitCast(lp))))).lpcs;
          if (@as(u32, @bitCast(cs.style)) & WS_CHILD == 0 and cs.hwndParent != HWND_MESSAGE) {
              cs.x = -32000;
              cs.y = -32000; // unowned user32 windows stay off any monitor
          }
      } else if (code == HCBT_ACTIVATE) return 1; // nothing on this thread may activate
      return CallNextHookEx(null, code, wp, lp);
  }
  ```

  ADR-12.3's `WMUX_TEST_MODE` sinks still apply: auto-answer message boxes; no `ShellExecute` (`open_url`, `open_config`, update balloon), because external apps launched that way are outside the process tree and get their own visible windows; no context menus; no global hotkeys; no tray icon.
- **Never read or write user state in hidden or test mode.** Skip `Window.savePlacement` and `restorePlacement`. Until ADR-9 and Appendix G land, the harness must redirect `LOCALAPPDATA` (§3.3).
- **Focus-dependent terminal behavior** (DECSET 1004 focus events, the unfocused cursor) never sees a Win32 focus change in hidden mode; the core keeps its initial focused state. Tests that need it require a `wmux.debug.*` helper that calls the core focus callback directly.
- **WebView2:** no occlusion handling was needed. `visibilityState` stayed `visible` and rAF kept running in both placements, so there is no need for `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`. In test mode, `wmux.debug.app.quit` should close all controllers and wait, with a bound, for `ICoreWebView2Environment5::BrowserProcessExited` before exiting, so that the user-data folder is unlocked when the process ends.

### 6.2 W0-B: `test/e2e/WmuxTest.psm1` (reuse `S2Native.cs`)

- **Launch:**

  ```powershell
  $psi = [Diagnostics.ProcessStartInfo]::new($exe)
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true   # drain with ReadToEndAsync()
  foreach ($k in @($psi.Environment.Keys)) { if ($k -match '^(GHOSTTY_|WMUX_|CMUX_)') { [void]$psi.Environment.Remove($k) } }
  $psi.Environment['WMUX_TEST_HIDDEN'] = '1'
  $psi.Environment['LOCALAPPDATA'] = "$root\localappdata"      # pre-W1 isolation, see §3.3
  $psi.Environment['XDG_CONFIG_HOME'] = "$root\xdg-config"     # + XDG_STATE_HOME, XDG_CACHE_HOME
  $p = [Diagnostics.Process]::Start($psi); $sampler.RootPid = [uint32]$p.Id
  ```

- **Sampler (Appendix D.2 step 7):**
  - Watch the process tree, not just the PID: wmux, conhost, the shells and the msedgewebview2 processes. Refresh it every 250 ms and keep PIDs that have exited.
  - Sample at 50-100 ms.
  - On a violation, kill the tree and fail the test.
  - Add the visibility guard (`S2Native.IsUserVisible`).
  - Log only the PID, process name and window class of non-instance windows, never their titles.
- **DPI:** make the harness thread per-monitor-v2 aware (`SetThreadDpiAwarenessContext(-4)`) before `GetWindowRect` or `PrintWindow`. A DPI-unaware harness gets virtualized geometry and downscaled captures (w5, w6). Never assume 96 DPI or 1600x1000 physical pixels; assert grid sizes via RPC.
- **Readiness:**
  - Poll `NamedPipeClientStream.Connect(100)` on `wmux-ipc-<pid>`. The code uses `wmux-ipc-<pid>`; `AGENTS.md` still says `ghostty-ipc-<pid>`, which is drift for W0-C to fix.
  - Then poll `read-screen` until `WMUX>` appears.
  - Budgets: 30 s for the pipe (the first launch after a rebuild took 12 s) and 20 s for the first prompt in debug builds (up to 17 s under load).
  - `send`/`read-screen` without arguments target the active tab. After `open target=tab`, the browser tab is active and `send` answers `NotATerminal`.
- **Screenshots** (until `wmux.debug.window.screenshot` exists): `S2Native.PrintWindowCapture(hwnd, 2 /*PW_RENDERFULLCONTENT*/)` followed by `SavePng`. Assert that the `WmuxTerminal` child is "not blank" (at least 3 distinct colors and a dominant color under 99.9%) only when the instance is cloaked. Use tolerances, never exact colors.
- **Taskbar and Alt-Tab** (smoke only): compare UI Automation button lists before and during the run (§3.2), and use `S2Native.IsAltTabCandidate`.
- **`Stop-WmuxInstance`:**
  1. Ask the app to quit. On the legacy protocol, `PostMessage(main, WM_CLOSE)` with `confirm-close-surface=false`.
  2. `WaitForExit(15 s)`, then `Kill(entireProcessTree)`.
  3. Kill any PIDs still alive from the recorded tree (orphaned WebView2 processes).
  4. Delete the state root with background retries for up to 60 s, and sweep stale `%TEMP%\wmux-e2e\*` roots at runner start.
  5. Never fail a test because cleanup failed.

### 6.3 CI (ADR-12.6)

- GitHub `windows-latest` sessions are 1024x768, so the 1600x1000 client must be clamped to the work area, or the runner resolution raised. A clamped client is another reason for tests not to assume pixel sizes.
- **Mesa llvmpipe was not tested.** Downloading and running a third-party `opengl32.dll` on this corporate machine was out of scope. Its WGL presents through GDI, so it should behave like p2/p9 (captured even off-screen). First CI step: run `hidden_probe.exe` with and without `--cloak --x=0 --y=0` with the llvmpipe DLLs next to it, and expect `red=19800` in `capture=top_client`.

## 7. Open risks

1. **Driver variance.** Only Intel Graphics 32.0.101.8860 was tested. NVIDIA and AMD ICDs may clip or skip presents differently, including for cloaked windows. Mitigations:
   - the harness self-check ("terminal not blank");
   - the robust long-term option: implement `wmux.debug.window.screenshot` inside the app (GL readback of the last frame on the renderer thread, composited with a `PrintWindow` of the chrome), which does not depend on placement or DWM.
2. **Cloaked windows sit on the user's monitor.** An unowned top-level window created outside the choke points would be visible and could receive clicks. The visibility guard kills the instance within one sample, and the WH_CBT hook covers user32-created windows.
3. **Display changes during a run** (dock or undock, resolution change, RDP) can move the cloaked window off every monitor, which blanks GL capture. They also change DPI-dependent sizes.
4. **Locked sessions and RDP.** A locked session was verified to work. A disconnected RDP session was not tested; DWM may stop composing, which would blank GL capture.
5. **Windows version.** Only Windows 11 25H2 (26200.9448) was tested. Results assume `DWMWA_CLOAK` and "local activation is not foreground" behave as on this build.
6. **WebView2 folder lock.** The user-data folder stayed locked for about 25-60 s after exit here; corporate filter drivers are a likely factor.
7. **Sampler blind spots.** Processes started outside the instance's tree (via `ShellExecute`/explorer, COM servers, services) are not attributed to it. Tests must not launch external GUI apps.
8. **Worst case covered only partly.** The worst case (the child inherits foreground rights) occurred only while the user happened to have Windows Terminal focused (w1, p2-p11). The other runs had no rights. A `WH_CBT` `HCBT_ACTIVATE` block makes the outcome independent of that.

## 8. Files and system changes

- `proto/S2/hidden_probe.zig`, `S2Native.cs`, `run-probe.ps1`, `run-wmux-hidden.ps1`: prototypes and drivers (§3.2).
- `proto/S2/wmux-hidden-mode.patch`: the wmux patch used for the w-runs. `git apply --check` passes on `aa1f532`; the sources are reverted on this branch.
- `proto/S2/offscreen-terminal.png` (w9: GL area white), `cloak-terminal.png` (w8: `WMUX>echo hi` / `hi` / `set /a 6*7` / `42` rendered), `cloak-browser.png` (w8: WebView2 tab captured).
- **System changes: none persistent.**
  - `WebView2Loader.dll` was copied into the worktree's ignored `zig-out\bin`.
  - Per-run state roots (including WebView2 user-data folders) under the ignored `zig-out\s2` were deleted after their locks released.
  - Alternate desktops were closed. `SwitchDesktop` was never called.
  - No registry, PATH, scheduled-task or user-profile changes.
  - All test processes have exited.
