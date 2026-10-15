//! Unit-test index of feature `agents` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: agents: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("lifecycle.zig");
    _ = @import("store.zig");
    _ = @import("lifecycle_test.zig");
    _ = @import("store_test.zig");
}
