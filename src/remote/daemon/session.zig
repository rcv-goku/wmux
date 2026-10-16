//! One persistent PTY session: the child process, its master fd, the
//! scrollback ring, the attachments (one per client view) and the pending
//! input queue. Owned and mutated only by the server loop thread.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Ring = @import("ring.zig").Ring;
const sizing = @import("sizing.zig");
const Size = sizing.Size;
const pty = @import("pty.zig");

/// Default and maximum scrollback ring sizes.
pub const default_scrollback: usize = 1024 * 1024;
pub const max_scrollback: usize = 8 * 1024 * 1024;
/// Pending PTY input above this is refused (`busy`).
pub const max_input_queue: usize = 1024 * 1024;

pub const Attachment = struct {
    id: []u8,
    /// Owning connection; the attachment ends with it.
    conn_id: u64,
    /// Data channel on that connection (pty.attach); null for session.attach.
    channel: ?u32,
    size: Size,
};

pub const Session = struct {
    id: []u8,
    pid: posix.pid_t,
    /// -1 after close.
    master: posix.fd_t,
    /// Set once the child was reaped.
    exit: ?pty.Exit = null,
    /// Master hit EOF/EIO (all slave fds closed).
    master_eof: bool = false,
    ring: Ring,
    size: Size,
    attachments: std.ArrayList(Attachment) = .empty,
    input: std.ArrayList(u8) = .empty,
    created_ms: i64,
    /// When the last attachment left (for the idle TTL); creation time initially.
    detached_since_ms: i64,

    pub fn create(gpa: Allocator, id: []const u8, opts: pty.SpawnOptions, scrollback: usize, now_ms: i64) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const owned_id = try gpa.dupe(u8, id);
        errdefer gpa.free(owned_id);
        var ring = try Ring.init(gpa, @min(scrollback, max_scrollback));
        errdefer ring.deinit(gpa);
        const sp = try pty.spawn(gpa, opts);
        s.* = .{
            .id = owned_id,
            .pid = sp.pid,
            .master = sp.master,
            .ring = ring,
            .size = opts.size,
            .created_ms = now_ms,
            .detached_since_ms = now_ms,
        };
        return s;
    }

    /// Frees memory and closes the master. The caller handles the process.
    pub fn destroy(self: *Session, gpa: Allocator) void {
        if (self.master >= 0) posix.close(self.master);
        for (self.attachments.items) |a| gpa.free(a.id);
        self.attachments.deinit(gpa);
        self.input.deinit(gpa);
        self.ring.deinit(gpa);
        gpa.free(self.id);
        gpa.destroy(self);
    }

    pub fn alive(self: *const Session) bool {
        return self.exit == null;
    }

    /// Recomputes the smallest-wins size and applies it when it changed.
    pub fn applySize(self: *Session) void {
        const next = sizing.effective(self.size, self.attachments.items);
        if (next.eql(self.size)) return;
        self.size = next;
        if (self.master >= 0) pty.setSize(self.master, next);
    }

    pub fn findAttachment(self: *Session, id: []const u8) ?usize {
        for (self.attachments.items, 0..) |a, i| if (std.mem.eql(u8, a.id, id)) return i;
        return null;
    }

    pub fn removeAttachmentAt(self: *Session, gpa: Allocator, i: usize, now_ms: i64) void {
        const a = self.attachments.orderedRemove(i);
        gpa.free(a.id);
        if (self.attachments.items.len == 0) self.detached_since_ms = now_ms;
        self.applySize();
    }

    /// Queues input and writes as much as the PTY accepts now.
    pub fn queueInput(self: *Session, gpa: Allocator, bytes: []const u8) error{ Busy, Closed, OutOfMemory }!void {
        if (self.master < 0 or !self.alive()) return error.Closed;
        if (self.input.items.len + bytes.len > max_input_queue) return error.Busy;
        try self.input.appendSlice(gpa, bytes);
        self.flushInput();
    }

    pub fn flushInput(self: *Session) void {
        while (self.input.items.len > 0 and self.master >= 0) {
            const n = posix.write(self.master, self.input.items) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.input.clearRetainingCapacity();
                    return;
                },
            };
            std.mem.copyForwards(u8, self.input.items[0 .. self.input.items.len - n], self.input.items[n..]);
            self.input.shrinkRetainingCapacity(self.input.items.len - n);
        }
    }

    pub fn scrollbackBytes(self: *const Session) usize {
        return self.ring.len;
    }
};
