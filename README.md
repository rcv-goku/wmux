# wmux

A modern terminal multiplexer for Windows, powered by [Ghostty](https://ghostty.org).

> [!IMPORTANT]
> **This is an independent project.** It is not affiliated with, endorsed by,
> or supported by the Ghostty project or its maintainers. Please file issues
> here, not upstream.

## What is wmux?

wmux is a native Windows terminal multiplexer that replaces tools like tmux
and cmux. It uses Ghostty's terminal core, font stack, and ConPTY layer as
its rendering engine, wrapped in a native Win32 application runtime with
workspaces, splits, tabs, an embedded browser, and a full IPC/scripting API.

## Features

- **Workspaces** — organize your work into named workspaces, each with its
  own tabs and splits. Sidebar with status indicators, rename, drag-reorder,
  and resize.
- **Splits & tabs** — horizontal/vertical splits, tab bar with close/reorder/
  rename, keyboard shortcuts (`alt+1`–`alt+8`). Focus border highlights
  the active pane in splits.
- **Backend picker** — open tabs as your default shell, PowerShell, cmd, any
  installed WSL distribution (enumerated live), or an embedded browser.
- **Browser panes (WebView2)** — Chromium-based browser as a split or tab,
  with address bar and close button. Requires WebView2
  (see [Prerequisites](#prerequisites)).
- **IPC/scripting API** — drive everything over a named pipe
  (`\\.\pipe\wmux-ipc-<pid>`): create workspaces, tabs, splits; send
  keystrokes; read screen content; manage sessions; trigger notifications.
- **Session save/restore** — persist and reload your workspace layout.
- **Synchronized input** — type into all panes simultaneously.
- **Layout engine** — switch between even-horizontal, even-vertical,
  main-vertical, main-horizontal, and tiled layouts.
- **Per-pane corner buttons** — always-visible action cluster: New Terminal,
  New Browser, Split Right, Split Down.
- **Notifications** — desktop notifications that jump to the originating tab.
- **Working-directory inheritance** — new tabs/splits open in the current
  directory (OSC 7).
- **Window state persistence** — size, position, and maximized state restored
  across restarts.

## Prerequisites

### WebView2 Runtime (required for browser panes)

Browser panes use Microsoft Edge WebView2. Most Windows 11 consumer editions
include it, but Enterprise/LTSC editions may not. To install:

```powershell
winget install Microsoft.EdgeWebView2Runtime
```

Or download from [Microsoft's WebView2 page](https://developer.microsoft.com/en-us/microsoft-edge/webview2/).

### WebView2Loader.dll (required at build time)

The `WebView2Loader.dll` must be placed next to `wmux.exe`. It ships in
the [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2)
NuGet package under `build/native/x64/WebView2Loader.dll`.

Quick fetch:
```powershell
$tmp = New-TemporaryFile | Rename-Item -NewName { $_.Name + '.zip' } -PassThru
Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $tmp
Expand-Archive $tmp -DestinationPath "$tmp-dir"
Copy-Item "$tmp-dir\build\native\x64\WebView2Loader.dll" zig-out\bin\
```

If WebView2 is missing, wmux will start normally — terminal panes work
fine — but browser panes will be disabled with a warning.

## Building

Requires [Zig](https://ziglang.org/download/) **0.15.2**.

```powershell
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

The binary lands at `zig-out\bin\wmux.exe`.

### Install

```powershell
zig build install -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p "$env:LOCALAPPDATA\Programs\wmux"
```

### Run tests

```powershell
zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+T` | New tab (inherits current pane's backend) |
| `Ctrl+W` | Close active pane (closes tab if unsplit) |
| `Ctrl+Shift+W` | Close entire tab |
| `Ctrl+Shift+N` | New window |
| `Ctrl+Shift+Q` | Quit |
| `Alt+F4` | Close window |
| `Ctrl+Shift+←` | Previous tab |
| `Ctrl+Shift+→` | Next tab |
| `Alt+1`–`Alt+8` | Switch to tab by number |

All shortcuts are configurable via the Ghostty `keybind` config option.

## IPC Commands

All commands use the `wmux` binary (e.g. `wmux +version`). The IPC pipe
is at `\\.\pipe\wmux-ipc-<pid>`.

| Command | Description |
|---------|-------------|
| `+version` | Print version |
| `+list-actions` | List available actions |
| `+workspace list` | List workspaces |
| `+tab list` | List tabs in active workspace |
| `+surface list` | List surfaces/panes |
| `+workspace new` | Create a new workspace |
| `+tab new` | Create a new tab |
| `+send` | Send input to a pane |
| `+notify` | Trigger a notification |
| `+capture-pane` | Capture pane content |
| `+session save/restore` | Save or restore session |
| `+select-layout` | Change split layout |
| `+sync-input` | Toggle synchronized input |
| `+break-pane` | Break pane to new tab |
| `+move-pane` | Move pane between tabs |
| `+swap-split` | Swap split panes |

## Credits

Built on [Ghostty](https://ghostty.org) by Mitchell Hashimoto. The
Win32 application runtime derives from work by
[InsipidPoint/ghostty-windows](https://github.com/InsipidPoint/ghostty-windows).

## License

[MIT](LICENSE)
