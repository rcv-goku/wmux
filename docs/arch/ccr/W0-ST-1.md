---
id: W0-ST-1
wp: W0-ST
title: Race-free Windows read-thread teardown in termio/Exec.zig
status: accepted
files:
  - path: src/termio/Exec.zig
    class: frozen            # shared Ghostty core (section 0); listed in W0-ST touches
    owner: none
stub: none needed; the change is self-contained in Exec.zig and lands in wp/W0-ST-flakes
decision:
  outcome: "accepted (ruling D17): folded into W0-ST part 1 (wp/W0-ST-flakes)"
  by: "program owner (lead architect), ruling D17 of 2026-10-16; recorded by the W0-ST agent"
  date: "2026-10-16"
---

## What
`src/termio/Exec.zig`, Windows paths only:
- `threadExit` calls a new `stopReadThreadWindows(exec)` instead of one `CancelIoEx` before
  `exec.read_thread.join()`. It repeats `CancelSynchronousIo(thread handle)` and
  `CancelIoEx(read handle)` every 10 ms until `WaitForSingleObject(thread handle)` reports
  that the read thread exited, for at most 10 s; after that it logs an error and the join
  blocks as before.
- `ReadThread.threadMainWindows` checks the quit pipe (`PeekNamedPipe`) before every
  `ReadFile` instead of only after a cancelled one; a cancelled `ReadFile` loops back to that
  check.
- A local `extern "kernel32" fn CancelSynchronousIo` declaration (not in the std bindings).

## Why
Pre-existing flake (FOLLOWUPS "Gate and test reliability", ADR-12.7 known flakes): a
`CancelIoEx` issued while the read thread is outside `ReadFile` (processing output, between
two reads, or not started yet) cancels nothing, the thread then blocks in `ReadFile` until
the pseudoconsole writes again, and `read_thread.join()` hangs the UI thread inside
`core_surface.deinit`. Reproduced on the unfixed Debug build: the hang hit on the second
close of a just-created workspace and again on the second close of a just-created tab
(`test/e2e/suites/regression/W0-ST.e2e.ps1`; the log stops after
`child process exited` without `read thread got quit signal`). The read thread lives in the
shared core, so no owned file or extension point can change it (G8); ruling D17 approves the
core change.

## Exact diff sketch
```diff
--- a/src/termio/Exec.zig
+++ b/src/termio/Exec.zig
@@ threadExit
-        if (windows.kernel32.CancelIoEx(exec.read_thread_fd, null) == 0) { ... }
+    if (comptime builtin.os.tag == .windows) stopReadThreadWindows(exec);
     exec.read_thread.join();
@@
+fn stopReadThreadWindows(exec: *ThreadData) void {
+    // CancelSynchronousIo + CancelIoEx, then WaitForSingleObject(thread, 10 ms), up to 10 s
+}
+extern "kernel32" fn CancelSynchronousIo(hThread: windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
@@ ReadThread.threadMainWindows
-        while (true) { while (true) { ReadFile ... .OPERATION_ABORTED => break } PeekNamedPipe(quit) }
+        while (true) { PeekNamedPipe(quit) -> return; ReadFile ... .OPERATION_ABORTED => continue }
```

## Stub until merged
Nothing to stub. Until the merge, closing a just-created tab or workspace can hang (known
flake, ADR-12.7).

## Impact and risks
- POSIX and macOS paths are unchanged (every change is behind `builtin.os.tag == .windows`).
- One extra `PeekNamedPipe` per `ReadFile` (1 KiB read buffer) on Windows; negligible next to
  `processOutput`.
- Closing the read handle or the pseudoconsole was rejected as a last resort: `CloseHandle`
  on a synchronous pipe handle waits for the pending read like the join does, the pty owns the
  handles and closes them again in `Pty.deinit`, and `ClosePseudoConsole` alone does not end
  the read while the pty still holds the pipe's write end. The bounded retry cannot miss: once
  the quit byte is written the thread can only block in a `ReadFile` entered after the check,
  which the next cancel interrupts.
- No merge-order constraint; W1-3 (termio/env work) should rebase over it.
