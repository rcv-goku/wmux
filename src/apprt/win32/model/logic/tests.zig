//! Test index of the model's pure logic (ARCHITECTURE.md ADR-12.1): the
//! std-only files of this directory. The full test suite reaches it through
//! ui/Window.zig's test block; `zig build test-fast` picks it up once
//! fast_tests.zig imports it (CCR W0-A2-1).
//!
//! fake.zig is deliberately not listed: it builds real model objects
//! (Workspace, Pane, Tab and the split tree of src/datastruct), which cannot
//! compile in the std-only test-fast module. ui/Window.zig's test block
//! collects it for the full suite (CCR W0-A2-1 covers the check-manifest
//! rule this conflicts with).

test {
    _ = @import("arith.zig");
    _ = @import("handle_registry.zig");
    _ = @import("titles.zig");
}
