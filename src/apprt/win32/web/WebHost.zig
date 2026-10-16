//! The WebView2 host of a web panel (ARCHITECTURE.md ADR-6.1, ADR-6.9):
//! one host HWND of class `WmuxPanelHost` per placement (pane tab, right
//! sidebar, popup, top-level window) with a lazily created controller in
//! the shared environment's `wmux-ui` profile, keeping BrowserPane's
//! in-flight-ref and zombie discipline.
//!
//! Stub written by W0-A3 so model/TabContent.zig and web/WebPanel.zig can
//! name it; W1-6 implements it (it owns web/**).

const WebHost = @This();

const w32 = @import("../platform/win32.zig");

/// The host HWND (null until created).
hwnd: ?w32.HWND = null,
