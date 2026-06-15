# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`
- **Build (release):** `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`
- **Test:** `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`
- **Test filter:** `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Install:** `zig build install -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p "$env:LOCALAPPDATA\Programs\ghostty"`

## Directory Structure

- Shared Zig core: `src/`
- Win32 application runtime: `src/apprt/win32/`
- Data structures (split tree, etc.): `src/datastruct/`
- Input/command handling: `src/input/`
- Action definitions: `src/apprt/action.zig`
- IPC named pipe server: `src/apprt/win32/App.zig` (ipc* functions)
- CI: `.github/workflows/`

## IPC

The IPC server listens on `\\.\pipe\ghostty-ipc-<pid>` and accepts JSON
commands. Test with the `+` CLI subcommands (e.g. `ghostty +version`).
