//! Unit-test index of feature `feed` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: feed: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("model.zig");
    _ = @import("decisions.zig");
    _ = @import("store.zig");
    _ = @import("query.zig");
    _ = @import("model_test.zig");
    _ = @import("decisions_test.zig");
    _ = @import("store_test.zig");
    _ = @import("query_test.zig");
}
