---
id: W0-ST-2
wp: W0-ST
title: terminal.search.Thread test stops and joins its thread on every path
status: accepted
files:
  - path: src/terminal/search/Thread.zig
    class: frozen            # shared Ghostty core (section 0); listed in W0-ST touches
    owner: none
stub: none needed; test-only change in wp/W0-ST-flakes
decision:
  outcome: "accepted (ruling D17): folded into W0-ST part 1 (wp/W0-ST-flakes)"
  by: "program owner (lead architect), ruling D17 of 2026-10-16; recorded by the W0-ST agent"
  date: "2026-10-16"
---

## What
The unnamed `test` block at the end of `src/terminal/search/Thread.zig`:
- right after `std.Thread.spawn`, a `defer` notifies `thread.stop` and joins the thread, so it
  runs on every exit path and before the earlier deferred `thread.deinit`, `ud.deinit` and
  `t.deinit`;
- the completion wait (`ud.reset.timedWait`) grows from 100 ms to 10 s;
- the explicit `thread.stop.notify()` / `os_thread.join()` after the wait are removed (the
  defer does it).

## Why
`try ud.reset.timedWait(100 * std.time.ns_per_ms)` returned `error.Timeout` under CPU load
and left the test before the stop and join; the search thread kept running on the freed
terminal and segfaulted later in the same test binary. The test is unnamed, so every filtered
`zig build test` run includes it and `test/known-failures.txt` cannot list it (FOLLOWUPS,
ADR-12.7). Core file, ruling D17.

## Exact diff sketch
```diff
--- a/src/terminal/search/Thread.zig
+++ b/src/terminal/search/Thread.zig
@@ test
     var os_thread = try std.Thread.spawn(.{}, threadMain, .{&thread});
+    defer {
+        thread.stop.notify() catch |err| log.err(...);
+        os_thread.join();
+    }
@@
-    try ud.reset.timedWait(100 * std.time.ns_per_ms);
-    try thread.stop.notify();
-    os_thread.join();
+    try ud.reset.timedWait(10 * std.time.ns_per_s);
```

## Stub until merged
Nothing to stub.

## Impact and risks
Test-only; no production code changes. A genuinely broken search thread now fails the test
after 10 s instead of 100 ms.
