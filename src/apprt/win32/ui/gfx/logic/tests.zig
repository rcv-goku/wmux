//! Pure-logic tests of the gfx layer ("unit: gfx: ..."). std-only, so this
//! file can join `zig build test-fast` (ADR-12.1/12.2). Standalone:
//!
//!   & $Z test src/apprt/win32/ui/gfx/logic/tests.zig
//!
//! The Direct2D/DirectWrite/WIC tests live in `../tests.zig`.
test {
    _ = @import("color.zig");
    _ = @import("device_state.zig");
    _ = @import("geometry.zig");
    _ = @import("lru.zig");
    _ = @import("text_style.zig");
    _ = @import("utf16_map.zig");
}
