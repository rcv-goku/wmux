//! wmuxd-remote wire protocol (ADR-13): framing, control messages and
//! payload types shared by the daemon (src/remote/daemon/) and the Windows
//! carrier client. std-only and OS-agnostic.

pub const frame = @import("frame.zig");
pub const messages = @import("messages.zig");
pub const rpc = @import("rpc.zig");

test {
    _ = frame;
    _ = messages;
    _ = rpc;
}
