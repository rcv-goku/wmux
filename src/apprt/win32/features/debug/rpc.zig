//! The core `wmux.debug.*` methods (ARCHITECTURE.md Appendix B.3, AF-14;
//! W1-1a), declared in `mod.zig` as `debug_methods`: every entry is
//! `test_only` (served and listed only in WMUX_TEST_MODE). The handlers are
//! in hooks_core.zig. Feature-specific hooks belong to their owners'
//! `features/<id>/debug.zig` (`wmux.debug.notices` W1-4b, `web.*` W1-6c,
//! `sidebar.*` W1-8b, ...), aggregated the same way by rpc/registry.zig.

const hooks = @import("hooks_core.zig");
const rpc = @import("../../rpc/types.zig");

pub const debug_methods = [_]rpc.Method{
    .{ .name = "wmux.debug.ready", .handler = hooks.ready, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.app.quit", .handler = hooks.appQuit, .access = .admin, .test_only = true },
    .{ .name = "wmux.debug.dialogs.list", .handler = hooks.dialogsList, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.dialogs.answer", .handler = hooks.dialogsAnswer, .test_only = true },
    .{ .name = "wmux.debug.clipboard.get", .handler = hooks.clipboardGet, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.clipboard.set", .handler = hooks.clipboardSet, .test_only = true },
    .{ .name = "wmux.debug.focus_state", .handler = hooks.focusState, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.layout", .handler = hooks.layout, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.type", .handler = hooks.typeText, .access = .input, .test_only = true },
    .{ .name = "wmux.debug.key", .handler = hooks.key, .access = .input, .test_only = true },
    .{ .name = "wmux.debug.menu.list", .handler = hooks.menuList, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.menu.invoke", .handler = hooks.menuInvoke, .test_only = true },
    .{ .name = "wmux.debug.timers", .handler = hooks.timers, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.external_open.list", .handler = hooks.externalOpenList, .lane = .worker, .access = .read, .test_only = true },
    .{ .name = "wmux.debug.sounds.list", .handler = hooks.soundsList, .lane = .worker, .access = .read, .test_only = true },
};
