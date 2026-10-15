//! Pure device-loss policy for Direct2D render-target hosts (ARCHITECTURE
//! ADR-11.1 "D2DERR_RECREATE_TARGET handled"; ADR-11.6 risk "D2D device loss
//! over RDP (recreate; tested over RDP)").
//!
//! `classify` turns the HRESULT of EndDraw/Flush/Resize into an action;
//! `LossPolicy` decides when repeated losses (driver resets, RDP reconnect
//! storms) or a missing GPU should move a host to the software rasterizer.
//! std-only: the HRESULT values duplicate `platform/com.zig` (a test in
//! `ui/gfx/tests.zig` pins them).
const std = @import("std");

fn hresult(comptime v: u32) i32 {
    return @bitCast(v);
}

pub const D2DERR_RECREATE_TARGET = hresult(0x8899000C);
pub const D2DERR_DISPLAY_STATE_INVALID = hresult(0x88990006);
pub const D2DERR_NO_HARDWARE_DEVICE = hresult(0x8899000B);
pub const DXGI_ERROR_DEVICE_REMOVED = hresult(0x887A0005);
pub const DXGI_ERROR_DEVICE_HUNG = hresult(0x887A0006);
pub const DXGI_ERROR_DEVICE_RESET = hresult(0x887A0007);

pub const Outcome = enum {
    /// The frame was presented (success codes, including S_FALSE).
    ok,
    /// The device is gone: release the target and every device resource,
    /// recreate them, and repaint (invalidate the window).
    recreate,
    /// Any other failure: log it; the next paint tries again.
    failed,
};

pub fn classify(hr: i32) Outcome {
    if (hr >= 0) return .ok;
    return switch (hr) {
        D2DERR_RECREATE_TARGET,
        D2DERR_DISPLAY_STATE_INVALID,
        DXGI_ERROR_DEVICE_REMOVED,
        DXGI_ERROR_DEVICE_HUNG,
        DXGI_ERROR_DEVICE_RESET,
        => .recreate,
        else => .failed,
    };
}

pub const RenderMode = enum {
    /// D2D1_RENDER_TARGET_TYPE_DEFAULT: hardware when available.
    hardware,
    /// D2D1_RENDER_TARGET_TYPE_SOFTWARE: the WARP-like CPU rasterizer.
    software,
};

pub const LossPolicy = struct {
    mode: RenderMode = .hardware,
    /// Losses since the last successful present.
    consecutive_losses: u32 = 0,
    total_losses: u32 = 0,

    /// Back-to-back losses tolerated before falling back to software.
    pub const max_consecutive_losses: u32 = 3;

    pub fn onPresented(self: *LossPolicy) void {
        self.consecutive_losses = 0;
    }

    pub fn onLost(self: *LossPolicy) void {
        self.consecutive_losses +|= 1;
        self.total_losses +|= 1;
        if (self.mode == .hardware and self.consecutive_losses >= max_consecutive_losses) self.mode = .software;
    }

    /// Creating a hardware-capable target failed (e.g.
    /// D2DERR_NO_HARDWARE_DEVICE): stay on software from now on.
    pub fn onHardwareUnavailable(self: *LossPolicy) void {
        self.mode = .software;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: gfx: device loss classification" {
    try testing.expectEqual(Outcome.ok, classify(0));
    try testing.expectEqual(Outcome.ok, classify(1)); // S_FALSE
    try testing.expectEqual(Outcome.recreate, classify(D2DERR_RECREATE_TARGET));
    try testing.expectEqual(Outcome.recreate, classify(DXGI_ERROR_DEVICE_REMOVED));
    try testing.expectEqual(Outcome.recreate, classify(DXGI_ERROR_DEVICE_RESET));
    try testing.expectEqual(Outcome.recreate, classify(DXGI_ERROR_DEVICE_HUNG));
    try testing.expectEqual(Outcome.recreate, classify(D2DERR_DISPLAY_STATE_INVALID));
    try testing.expectEqual(Outcome.failed, classify(hresult(0x80004005))); // E_FAIL
    try testing.expectEqual(Outcome.failed, classify(hresult(0x88990001))); // D2DERR_WRONG_STATE
}

test "unit: gfx: repeated device loss falls back to software" {
    var p: LossPolicy = .{};
    p.onLost();
    p.onPresented();
    p.onLost();
    p.onLost();
    try testing.expectEqual(RenderMode.hardware, p.mode);
    p.onLost();
    try testing.expectEqual(RenderMode.software, p.mode);
    try testing.expectEqual(@as(u32, 4), p.total_losses);
    p.onPresented();
    try testing.expectEqual(@as(u32, 0), p.consecutive_losses);
    try testing.expectEqual(RenderMode.software, p.mode); // sticky

    var q: LossPolicy = .{};
    q.onHardwareUnavailable();
    try testing.expectEqual(RenderMode.software, q.mode);
}
