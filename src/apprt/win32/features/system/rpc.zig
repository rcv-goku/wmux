//! v2 methods of feature `system` (ARCHITECTURE.md ADR-3.6, Appendix B.1;
//! W1-1a): `system.ping` and `system.capabilities`, both on the `pipe`
//! lane (connection thread, no model access) with `.read` access.
//! `system.identify`/`system.tree` are W2-2's; `auth.login` and the
//! text-v1 verbs are W1-1b's (`rpc_auth.zig`, `text_verbs.zig`).

const std = @import("std");
const builtin = @import("builtin");

const dispatch = @import("../../rpc/dispatch.zig");
const rpc = @import("../../rpc/types.zig");
const server = @import("../../rpc/server/mod.zig");

pub const methods = [_]rpc.Method{
    .{ .name = "system.ping", .handler = ping, .lane = .pipe, .access = .read },
    .{ .name = "system.capabilities", .handler = capabilities, .lane = .pipe, .access = .read },
};

/// `{"pong":true}`.
fn ping(ctx: *rpc.Ctx) rpc.Error!void {
    ctx.ok(.{ .pong = true });
}

/// `{protocol:"cmux-socket", version:2, socket_path, access_mode,
/// capabilities:{wmux:{version, build, channel, platform:"windows"}},
/// methods:[sorted]}` (ADR-3.6). `methods` lists the registry minus hidden
/// methods, and minus `test_only` ones (`wmux.debug.*`) outside
/// WMUX_TEST_MODE.
fn capabilities(ctx: *rpc.Ctx) rpc.Error!void {
    const i = server.info() orelse return ctx.fail(.unavailable, "Control server stopped", null);
    const names = dispatch.capabilityNames(ctx.arena, i.test_methods) catch return ctx.fail(.internal_error, "Out of memory", null);
    ctx.ok(.{
        .protocol = "cmux-socket",
        .version = 2,
        .socket_path = i.socket_path,
        .access_mode = i.access_mode,
        .capabilities = .{ .wmux = .{
            .version = i.version,
            .build = @tagName(builtin.mode),
            .channel = i.channel,
            .platform = "windows",
        } },
        .methods = names,
    });
}
