//! Test index of the tab bar's pure logic (ARCHITECTURE.md ADR-12.1). The
//! full test suite reaches it through ui/Window.zig's test block; `zig build
//! test-fast` picks it up once fast_tests.zig imports it (CCR W0-A2-1).

test {
    _ = @import("geometry.zig");
}
