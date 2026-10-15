# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Read first: the wmux → cmux parity program

- The authoritative architecture is [`docs/arch/ARCHITECTURE.md`](docs/arch/ARCHITECTURE.md).
  Read §0 (ground rules G1–G10), the ADR(s) for your area,
  **§15 "Conventions for implementation agents"** and your work-package spec
  `docs/arch/wp/<id>.md` before changing code.
- How work packages, CCRs, spikes, waves and the gate scripts work:
  [`docs/arch/README.md`](docs/arch/README.md).
- Edit only what your WP spec lists (`owns`, `touches`, `appends`); anything else is a Core
  Change Request (`docs/arch/ccr/<id>-<n>.md`). `scripts/check-ownership.ps1` enforces it.
- Never copy cmux source, scripts, docs or tests (interface facts only, G1), and never
  steal OS focus from tests, CLI or automation paths (G4).

## Commands

- **Build (debug, console subsystem):** `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`
- **Build (release):** `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`
- **Unit tests (CI filter set):** `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu "-Dtest-filter=unit: "`,
  plus the filters `sidebar`, `wsl`, `win-pwd` and `ipc:` (repeated `-Dtest-filter` flags are ORed in one compile)
- **Tests of one feature:** `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu "-Dtest-filter=unit: <feature>"`
- **Full test suite:** `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`
  (known environment-specific failures: `test/known-failures.txt`)
- **Fast / CLI tests** (once W0-A3 adds the steps): `zig build test-fast ...`, `zig build test-cli ...`
- **Formatting (Zig):** `zig fmt <changed files>`; never reformat files you do not own.
- **New WP worktree:** `pwsh scripts/new-worktree.ps1 -Wp <id> [-Slug <slug>]`
- **Local gate:** `pwsh scripts/gate.ps1 -Wp <id>`; merge gate (integrator): `pwsh scripts/gate.ps1 -Full`
- **Install:** `zig build install -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p "$env:LOCALAPPDATA\Programs\wmux"`

## Directory Structure

- Shared Zig core: `src/`
- Win32 application runtime: `src/apprt/win32/` (Wave 0 restructures it into
  `app/ platform/ model/ ui/ input/ rpc/ settings/ web/ features/`, ARCHITECTURE ADR-1.1)
- Data structures (split tree, etc.): `src/datastruct/`
- Input/command handling: `src/input/`
- Action definitions: `src/apprt/action.zig`
- IPC named-pipe server: `src/apprt/win32/ipc.zig` (transport and protocol), handlers in
  `src/apprt/win32/App.zig` (`ipc*` functions); W0-A1 moves them to `rpc/server/legacy_pipe.zig`,
  `rpc/compat/legacy_json.zig` and per-feature `features/<id>/legacy.zig`
- Executable: `wmux.exe` (`src/build/GhosttyExe.zig`), installed to `%LOCALAPPDATA%\Programs\wmux`
  next to `WebView2Loader.dll`
- Architecture, WP specs, CCRs, spike notes: `docs/arch/`
- Tooling: `scripts/` (worktrees, gates, ownership and manifest checks)
- CI: `.github/workflows/`

## IPC

- Today: the app listens on `\\.\pipe\wmux-ipc-<pid>` and speaks newline-delimited JSON
  (`{"id":1,"cmd":"...","args":{...}}`). Shells spawned by wmux get `GHOSTTY_PID`; the
  `wmux +<verb>` CLI subcommands (`wmux +workspace list`, `wmux +send ...`) use it, or the
  only `wmux-ipc-*` pipe, to find the instance. `wmux +version` works without a pipe.
- Coming (ADR-3, W1-1): the cmux v2 control pipe `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`
  (plus `-launch`), with `CMUX_SOCKET_PATH`/`WMUX_SOCKET_PATH` naming it, and the console CLI
  `cli\cmux.exe` / `cli\wmux.com` (ADR-4). The legacy `wmux-ipc-<pid>` pipe stays for one
  release and is removed at M3. New features never add `+verbs` or legacy JSON commands (G8).
