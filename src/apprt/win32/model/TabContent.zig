//! What a tab displays (ARCHITECTURE.md §0.2, ADR-6.1): a terminal
//! surface, a WebView2 browser, or nothing (`placeholder`: the HWND-less
//! content of the model tests' fake graphs). W0-A3 adds the `.web`
//! web-panel variant.

const Surface = @import("../Surface.zig");
const BrowserPane = @import("../web/BrowserPane.zig");
const w32 = @import("../platform/win32.zig");

pub const TabContent = union(enum) {
    terminal: *Surface,
    browser: *BrowserPane,
    placeholder,

    /// The content's top HWND, if it has one.
    pub fn hwnd(self: TabContent) ?w32.HWND {
        return switch (self) {
            .terminal => |s| s.hwnd,
            .browser => |b| b.host_hwnd,
            .placeholder => null,
        };
    }
};
