//! Unit-test index of feature `session` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: session: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("integrity.zig");
    _ = @import("limits.zig");
    _ = @import("migrate_v2.zig");
    _ = @import("sanitize.zig");
    _ = @import("schema_v3.zig");
}
