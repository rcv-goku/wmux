//! Test index of the RPC transport's pure logic (W1-1a-t). std and
//! wmux_proto only; fast_tests.zig imports this file.
//!
//!     zig test --dep wmux_proto -Mroot=src/apprt/win32/rpc/logic/tests.zig -Mwmux_proto=src/wmux_proto/proto.zig

test {
    _ = @import("admission.zig");
    _ = @import("framer.zig");
    _ = @import("ratelimit.zig");
    _ = @import("request_state.zig");
}
