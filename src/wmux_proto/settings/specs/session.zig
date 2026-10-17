//! Settings specs of feature `session` (ADR-5.2), filled by the WP that owns the
//! feature (wave W1). The `Spec` type lives in ../spec.zig (W0-P2).
//!
//! cmux has no `cmux.json` key for session restore or autosave (it restores
//! unless CMUX_DISABLE_SESSION_RESTORE is set), so the wmux switches live
//! under `wmux.session` (G2, W1-7a).

const Spec = @import("../spec.zig").Spec;

pub const specs = [_]Spec{
    .{
        .path = "wmux.session.restoreOnLaunch",
        .ty = .boolean,
        .default = "true",
        .section = "app",
        .label = "Restore the previous session on launch",
        .doc = "Reopen the windows, workspaces, splits and tabs of the last session when wmux starts (the terminals start again in their working directories). WMUX_DISABLE_SESSION_RESTORE or CMUX_DISABLE_SESSION_RESTORE, or launching wmux with a path, URL or command, skips the restore once.",
        .keywords = &.{ "session", "restore", "startup", "relaunch" },
        .apply = .restart,
        .cmux_compat = false,
    },
    .{
        .path = "wmux.session.autosave",
        .ty = .boolean,
        .default = "true",
        .section = "app",
        .label = "Save the session automatically",
        .doc = "Save the session layout every 8 seconds when it changed, and fully on quit, on closing the last window and on logoff or shutdown. Off: the session file is not updated (the last saved session is still restored).",
        .keywords = &.{ "session", "autosave", "save" },
        .apply = .restart,
        .cmux_compat = false,
    },
};

test {
    _ = specs;
}
