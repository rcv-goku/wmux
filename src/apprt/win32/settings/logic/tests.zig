//! Unit test index of the settings layer's pure logic [appendable: one
//! sorted import per line] (ADR-12.1). Listed in apprt/win32/fast_tests.zig,
//! so `zig build test-fast` runs it with only std and wmux_proto.

test {
    _ = @import("debounce.zig");
    _ = @import("layers.zig");
}
