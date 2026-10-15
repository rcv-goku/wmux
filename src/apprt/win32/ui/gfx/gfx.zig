//! Direct2D/DirectWrite drawing layer for wmux's native UI (ARCHITECTURE
//! ADR-11): the D2D sidebar (W1-8), the right-sidebar mode bar, the native
//! palette (W2-7) and the D2D tab bars (W5) draw through this module.
//!
//! Layers:
//! - `logic/` (std-only, unit-tested in test-fast): geometry and DPI
//!   snapping, color and contrast, text styles + `TextMeasurer` (+ a fake),
//!   UTF-16 offset mapping, the LRU cache, the device-loss policy.
//! - `Context` (per UI thread): Direct2D factory, `TextSystem`
//!   (DirectWrite formats/layouts), shared stroke styles, WIC factory.
//! - Hosts: `HwndTarget` (child HWND), `DcTarget` (GDI DC via BindDC),
//!   `BitmapTarget` (offscreen WIC bitmap: tests, screenshots). Each hands
//!   out a `Canvas` per frame and recreates itself after device loss.
//!
//! Typical WM_PAINT for a D2D child window:
//!
//!     var ps: PAINTSTRUCT = undefined;
//!     _ = BeginPaint(hwnd, &ps);
//!     defer _ = EndPaint(hwnd, &ps);
//!     if (try target.begin()) |c| {
//!         var canvas = c;
//!         canvas.clear(theme.background);
//!         canvas.text("Workspace 1", row_rect, &title_style, theme.text);
//!         if (target.end(&canvas) == .recreate) _ = InvalidateRect(hwnd, null, 0);
//!     }
//!
//! The platform bindings are re-exported for code that needs raw access
//! (`canvas.rt` is the ID2D1RenderTarget of the frame).
pub const com = @import("../../platform/com.zig");
pub const d2d = @import("../../platform/d2d.zig");
pub const dwrite = @import("../../platform/dwrite.zig");
pub const wic = @import("../../platform/wic.zig");

pub const geometry = @import("logic/geometry.zig");
pub const color = @import("logic/color.zig");
pub const text_style = @import("logic/text_style.zig");
pub const utf16 = @import("logic/utf16_map.zig");
pub const device_state = @import("logic/device_state.zig");
pub const LruCache = @import("logic/lru.zig").LruCache;

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const PixelRect = geometry.PixelRect;
pub const Insets = geometry.Insets;
pub const Align = geometry.Align;
pub const Dpi = geometry.Dpi;
pub const Color = color.Color;
pub const TextStyle = text_style.TextStyle;
pub const TextExtent = text_style.TextExtent;
pub const TextMeasurer = text_style.TextMeasurer;
pub const FakeMeasurer = text_style.FakeMeasurer;

pub const context = @import("context.zig");
pub const Context = context.Context;
pub const text = @import("text.zig");
pub const TextSystem = text.TextSystem;
pub const TextLayout = text.TextLayout;
pub const canvas = @import("canvas.zig");
pub const Canvas = canvas.Canvas;
pub const DeviceResources = canvas.DeviceResources;
pub const target = @import("target.zig");
pub const HwndTarget = target.HwndTarget;
pub const DcTarget = target.DcTarget;
pub const TargetOptions = target.TargetOptions;
pub const Unit = target.Unit;
pub const EndResult = target.EndResult;
pub const offscreen = @import("offscreen.zig");
pub const BitmapTarget = offscreen.BitmapTarget;
