//! Unit-test index of feature `meta` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: meta: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("gh_pr.zig");
    _ = @import("git.zig");
    _ = @import("ports.zig");
}
