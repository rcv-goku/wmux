//! Sidebar row contributors (ARCHITECTURE.md ADR-11.3). A feature puts
//! content into the workspace rows by declaring
//! `pub const sidebar_rows = @import("sidebar.zig").rows;` (a
//! `[]const RowContributor`) in its mod.zig, each contributor in its
//! pre-assigned `Slot`; ui/contrib.zig aggregates them. Contributors read
//! feature state only and never paint.
//!
//! Written by W0-A3 so the registry can name the type. W1-8 owns
//! ui/sidebar/**: the row pipeline (logic/row_model.zig, row layout,
//! paint, hit-test) calls the contributors and may extend `RowContext`.

const Window = @import("../Window.zig");
const Workspace = @import("../../model/Workspace.zig");
const row_model = @import("logic/row_model.zig");

/// Pre-assigned contributor order (values are binding, ADR-11.3).
pub const Slot = row_model.Slot;

/// The builder primitives a contributor writes into (line, pills,
/// progress, chips, markdown, collapsible, spinner, badge).
pub const RowBuilder = row_model.RowBuilder;

/// What a contributor sees besides its workspace.
pub const RowContext = struct {
    window: *const Window,
};

pub const RowContributor = struct {
    /// Stable id (`status.progress`, `meta.ports`, ...).
    id: []const u8,
    slot: Slot,
    build: *const fn (b: *RowBuilder, ws: *const Workspace, ctx: *const RowContext) void,
};
