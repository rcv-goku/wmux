# W0-ST: wave-0 stabilization

Part 1, flake fixes (ruling D17):

- Fixed: closing a terminal tab or workspace right after creating it could hang wmux (the UI
  thread waited forever for the terminal's pty read thread). The Windows read thread now
  checks for the quit signal before every read, and teardown repeats the cancel until the
  thread has exited (`src/termio/Exec.zig`, CCR W0-ST-1). Regression suite:
  `test/e2e/suites/regression/W0-ST.e2e.ps1`.
- Fixed: the `terminal.search.Thread` unit test always stops and joins its thread, so filtered
  `zig build test` runs no longer crash under load (`src/terminal/search/Thread.zig`,
  CCR W0-ST-2).

Part 2, stabilization (test infrastructure only):

- e2e harness: the failure snapshot of `Stop-WmuxInstance` no longer waits on a hung wmux UI
  thread. A window that `IsHungAppWindow` reports is not captured (the reason goes to
  `artifacts\failure-snapshot.txt`), other captures give up after 5 s, and
  `Save-WmuxWindowCapture` takes a `-TimeoutMs`. New self-test with a hung fixture window.
- `regression/w0-regression`: the session test keeps restoring workspace 0 only; a
  two-workspace legacy restore still loses workspace 1 (W1-7).
- The unfiltered win32 `zig build test` compiles again: two `features/session/legacy_v2.zig`
  tests no longer build `SplitTree(Pane)` through init/deinit, which pulled the GTK apprt's tests
  into the binary.
