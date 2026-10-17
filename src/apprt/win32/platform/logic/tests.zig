//! Pure `unit: platform:` tests of the platform layer (std only, any OS).
//! Listed in `src/apprt/win32/fast_tests.zig`; one import per logic file.
//!   zig test src/apprt/win32/platform/logic/tests.zig

test {
    _ = @import("webview2_iids.zig");
}
