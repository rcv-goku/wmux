//! Feature manifest [frozen, merge=union] (ADR-1.4): one line per feature
//! module, sorted by id. Every registry aggregates from this list. Adding a
//! feature means one line here plus one line per struct in ext.zig.
const std = @import("std");

pub const modules = .{
    @import("a11y/mod.zig"),
    @import("about/mod.zig"),
    @import("agent_chat/mod.zig"),
    @import("agent_messages/mod.zig"),
    @import("agent_status/mod.zig"),
    @import("agents/mod.zig"),
    @import("auto_naming/mod.zig"),
    @import("automation/mod.zig"),
    @import("browser/mod.zig"),
    @import("browser_profiles/mod.zig"),
    @import("canvas/mod.zig"),
    @import("chrome/mod.zig"),
    @import("comments/mod.zig"),
    @import("context_menus/mod.zig"),
    @import("copy_mode/mod.zig"),
    @import("custom_actions/mod.zig"),
    @import("custom_sidebars/mod.zig"),
    @import("debug/mod.zig"),
    @import("deeplinks/mod.zig"),
    @import("diff/mod.zig"),
    @import("dnd/mod.zig"),
    @import("dock/mod.zig"),
    @import("env_identity/mod.zig"),
    @import("events/mod.zig"),
    @import("feed/mod.zig"),
    @import("file_preview/mod.zig"),
    @import("files_explorer/mod.zig"),
    @import("find/mod.zig"),
    @import("find_in_dir/mod.zig"),
    @import("focus_history/mod.zig"),
    @import("global_search/mod.zig"),
    @import("groups/mod.zig"),
    @import("hibernation/mod.zig"),
    @import("hints/mod.zig"),
    @import("history/mod.zig"),
    @import("i18n/mod.zig"),
    @import("image_paste/mod.zig"),
    @import("install_cli/mod.zig"),
    @import("keep_awake/mod.zig"),
    @import("layouts/mod.zig"),
    @import("markdown/mod.zig"),
    @import("meta/mod.zig"),
    @import("notifications/mod.zig"),
    @import("palette/mod.zig"),
    @import("panes_surfaces/mod.zig"),
    @import("policy/mod.zig"),
    @import("quick_terminal/mod.zig"),
    @import("remote/mod.zig"),
    @import("remote_tmux/mod.zig"),
    @import("resume/mod.zig"),
    @import("session/mod.zig"),
    @import("settings_ui/mod.zig"),
    @import("shortcuts/mod.zig"),
    @import("sleepy_mode/mod.zig"),
    @import("status/mod.zig"),
    @import("sync_input/mod.zig"),
    @import("system/mod.zig"),
    @import("task_manager/mod.zig"),
    @import("terminal_io/mod.zig"),
    @import("textbox/mod.zig"),
    @import("tmux_compat/mod.zig"),
    @import("toasts/mod.zig"),
    @import("todo/mod.zig"),
    @import("tray/mod.zig"),
    @import("updater/mod.zig"),
    @import("vault/mod.zig"),
    @import("windows/mod.zig"),
    @import("workspace_status/mod.zig"),
    @import("workspace_style/mod.zig"),
    @import("workspaces/mod.zig"),
};

comptime {
    @setEvalBranchQuota(1_000_000);
    for (0..modules.len) |i| {
        for (0..i) |j| {
            if (std.mem.eql(u8, modules[i].id, modules[j].id)) {
                @compileError("duplicate feature id in features/manifest.zig: " ++ modules[i].id);
            }
        }
    }
}
