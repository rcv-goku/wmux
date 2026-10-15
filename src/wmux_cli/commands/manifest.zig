//! CLI command family manifest [frozen, merge=union] (ADR-1.4, ADR-4.9,
//! Appendix C): one line per family file, sorted. Each family file declares
//! `pub const commands`; W1-2 builds dispatch and help over this list.

pub const families = .{
    @import("browser.zig"),
    @import("canvas.zig"),
    @import("config.zig"),
    @import("events.zig"),
    @import("hooks_agents.zig"),
    @import("layout_todo.zig"),
    @import("legacy_plus.zig"),
    @import("notify.zig"),
    @import("open_files.zig"),
    @import("pane_surface.zig"),
    @import("remote.zig"),
    @import("right_sidebar.zig"),
    @import("session.zig"),
    @import("sidebar_meta.zig"),
    @import("system.zig"),
    @import("teams.zig"),
    @import("terminal_io.zig"),
    @import("window.zig"),
    @import("wmux_ns.zig"),
    @import("workspace.zig"),
    @import("workspace_group.zig"),
};

// A line duplicated by a union merge fails the build here (ADR-0.4).
comptime {
    @setEvalBranchQuota(1_000_000);
    for (0..families.len) |i| {
        for (0..i) |j| {
            if (families[i] == families[j]) {
                @compileError("duplicate family in src/wmux_cli/commands/manifest.zig: " ++ @typeName(families[i]));
            }
        }
    }
}

test {
    inline for (families) |f| _ = f;
}
