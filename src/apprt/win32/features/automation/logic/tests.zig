//! Unit-test index of feature `automation` (ADR-12.1): import every logic/*.zig file
//! here and name tests "unit: automation: <behavior>". Logic files use only std,
//! wmux_proto and sibling logic files; they run in `zig build test-fast`.

test {
    _ = @import("firings.zig");
    _ = @import("fold.zig");
    _ = @import("loop_guard.zig");
    _ = @import("match.zig");
    _ = @import("ratelimit.zig");
    _ = @import("redact.zig");
    _ = @import("rules.zig");
    _ = @import("template.zig");
    _ = @import("webhook.zig");
}
