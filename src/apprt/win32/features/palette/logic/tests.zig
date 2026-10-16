//! Unit-test index of feature `palette` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: palette: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("fuzzy.zig");
    _ = @import("modes.zig");
    _ = @import("ranking.zig");
    _ = @import("usage.zig");
}
