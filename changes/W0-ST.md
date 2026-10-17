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
