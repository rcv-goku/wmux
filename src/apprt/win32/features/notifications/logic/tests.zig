//! Unit-test index of feature `notifications` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: notifications: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("text.zig");
    _ = @import("store.zig");
    _ = @import("unread.zig");
    _ = @import("ingest.zig");
    _ = @import("persist.zig");
}
