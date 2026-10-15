//! Listening-port logic for the `ports` sidebar contributor (ADR-11.3,
//! W2-6) and the per-workspace `CMUX_PORT` range. Pure: the worker thread
//! reads `GetExtendedTcpTable` (AF_INET and AF_INET6,
//! `TCP_TABLE_OWNER_PID_LISTENER`) and the surface job's process ids
//! (`JobObjectBasicProcessIdList`, ADR-3.9) and hands the rows here.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `MIB_TCP_STATE_LISTEN`.
pub const mib_tcp_state_listen: u32 = 2;

pub const Addr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    /// `127.0.0.0/8`, `::1`, or IPv4-mapped `::ffff:127.x.x.x`.
    pub fn isLoopback(self: Addr) bool {
        return switch (self) {
            .v4 => |a| a[0] == 127,
            .v6 => |a| blk: {
                if (std.mem.allEqual(u8, a[0..15], 0) and a[15] == 1) break :blk true;
                break :blk isV4Mapped(a) and a[12] == 127;
            },
        };
    }

    /// `0.0.0.0`, `::` or `::ffff:0.0.0.0`.
    pub fn isAny(self: Addr) bool {
        return switch (self) {
            .v4 => |a| std.mem.allEqual(u8, &a, 0),
            .v6 => |a| std.mem.allEqual(u8, &a, 0) or
                (isV4Mapped(a) and std.mem.allEqual(u8, a[12..16], 0)),
        };
    }

    fn isV4Mapped(a: [16]u8) bool {
        return std.mem.allEqual(u8, a[0..10], 0) and a[10] == 0xff and a[11] == 0xff;
    }
};

/// One listener row from the TCP or TCP6 owner-pid table.
pub const ListenerRow = struct {
    addr: Addr,
    /// Host byte order.
    port: u16,
    /// `MIB_TCP_STATE`; only `mib_tcp_state_listen` rows count.
    state: u32 = mib_tcp_state_listen,
    pid: u32,

    /// From `MIB_TCPROW_OWNER_PID` fields as stored in memory: the address
    /// dword holds network-order bytes; the port is network order in the
    /// low 16 bits.
    pub fn fromMib4(state: u32, local_addr: u32, local_port: u32, pid: u32) ListenerRow {
        return .{
            .addr = .{ .v4 = @bitCast(local_addr) },
            .port = portFromMib(local_port),
            .state = state,
            .pid = pid,
        };
    }

    /// From `MIB_TCP6ROW_OWNER_PID` fields (`ucLocalAddr` is 16 network-order
    /// bytes; the scope id is irrelevant for listeners).
    pub fn fromMib6(state: u32, local_addr: [16]u8, local_port: u32, pid: u32) ListenerRow {
        return .{
            .addr = .{ .v6 = local_addr },
            .port = portFromMib(local_port),
            .state = state,
            .pid = pid,
        };
    }
};

/// Convert a `dwLocalPort` value (network-order port in the low 16 bits of
/// the in-memory dword) to a host-order port.
pub fn portFromMib(dw: u32) u16 {
    const bytes: [4]u8 = @bitCast(dw);
    return std.mem.readInt(u16, bytes[0..2], .big);
}

/// One listening port of a workspace, merged across rows.
pub const Port = struct {
    port: u16,
    /// Some listener is bound to a loopback address.
    loopback: bool = false,
    /// Some listener is bound to the unspecified address (all interfaces).
    any: bool = false,
    /// Some listener is bound to another specific address.
    specific: bool = false,
    ipv4: bool = false,
    ipv6: bool = false,

    /// Whether `http://localhost:<port>` reaches it: bound to loopback or
    /// all interfaces.
    pub fn reachableViaLocalhost(self: Port) bool {
        return self.loopback or self.any;
    }
};

/// Listening ports owned by any of `pids`, ascending and unique, with the
/// address flags of every contributing row OR-ed together. Rows that are
/// not in LISTEN state or have port 0 are skipped. Caller owns the result.
pub fn collect(gpa: Allocator, rows: []const ListenerRow, pids: []const u32) Allocator.Error![]Port {
    var pid_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer pid_set.deinit(gpa);
    try pid_set.ensureTotalCapacity(gpa, @intCast(pids.len));
    for (pids) |p| pid_set.putAssumeCapacity(p, {});

    var by_port: std.AutoArrayHashMapUnmanaged(u16, Port) = .empty;
    defer by_port.deinit(gpa);
    for (rows) |r| {
        if (r.state != mib_tcp_state_listen or r.port == 0) continue;
        if (!pid_set.contains(r.pid)) continue;
        const gop = try by_port.getOrPut(gpa, r.port);
        if (!gop.found_existing) gop.value_ptr.* = .{ .port = r.port };
        const p = gop.value_ptr;
        if (r.addr.isLoopback()) {
            p.loopback = true;
        } else if (r.addr.isAny()) {
            p.any = true;
        } else {
            p.specific = true;
        }
        switch (r.addr) {
            .v4 => p.ipv4 = true,
            .v6 => p.ipv6 = true,
        }
    }

    const out = try gpa.dupe(Port, by_port.values());
    std.mem.sort(Port, out, {}, struct {
        fn lt(_: void, a: Port, b: Port) bool {
            return a.port < b.port;
        }
    }.lt);
    return out;
}

/// Consecutive scans a port may be missing before its badge retires. A
/// single transient miss keeps the badge; the second consecutive miss
/// removes it.
pub const retire_after_misses: u8 = 2;

/// Smooths scan results so badges are stable across transient misses.
/// Feed every scan to `update`; read `ports` (ascending) afterwards.
pub const Tracker = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { port: Port, misses: u8 = 0 };

    pub fn deinit(self: *Tracker, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// Merge one scan (`scan` ascending and unique, as from `collect`).
    /// Present ports reset their miss count and take the new flags; absent
    /// ones count a miss and retire at `retire_after_misses`. Returns
    /// whether the visible set or flags changed (repaint needed).
    pub fn update(self: *Tracker, gpa: Allocator, scan: []const Port) Allocator.Error!bool {
        var next: std.ArrayList(Entry) = .empty;
        errdefer next.deinit(gpa);
        try next.ensureTotalCapacity(gpa, self.entries.items.len + scan.len);
        var changed = false;
        var i: usize = 0;
        var j: usize = 0;
        const old = self.entries.items;
        while (i < old.len or j < scan.len) {
            if (j >= scan.len or (i < old.len and old[i].port.port < scan[j].port)) {
                const misses = old[i].misses +| 1;
                if (misses < retire_after_misses) {
                    next.appendAssumeCapacity(.{ .port = old[i].port, .misses = misses });
                } else changed = true;
                i += 1;
            } else if (i >= old.len or scan[j].port < old[i].port.port) {
                next.appendAssumeCapacity(.{ .port = scan[j] });
                changed = true;
                j += 1;
            } else {
                if (!std.meta.eql(old[i].port, scan[j])) changed = true;
                next.appendAssumeCapacity(.{ .port = scan[j] });
                i += 1;
                j += 1;
            }
        }
        self.entries.deinit(gpa);
        self.entries = next;
        return changed;
    }

    /// Visible port numbers, ascending. Caller owns the result.
    pub fn ports(self: *const Tracker, gpa: Allocator) Allocator.Error![]u16 {
        const out = try gpa.alloc(u16, self.entries.items.len);
        for (self.entries.items, out) |e, *o| o.* = e.port.port;
        return out;
    }

    /// Drop everything (listener gone because the surface closed, or the
    /// ports row became hidden).
    pub fn clear(self: *Tracker) void {
        self.entries.clearRetainingCapacity();
    }
};

/// Write the `ports=` value used by `sidebar-state` and custom sidebars:
/// comma-separated ascending numbers, empty when none.
pub fn writeList(w: *std.Io.Writer, list: []const u16) std.Io.Writer.Error!void {
    for (list, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{p});
    }
}

// ---------------------------------------------------------------------------
// Per-workspace port range (CMUX_PORT, CMUX_PORT_END, CMUX_PORT_RANGE)
// ---------------------------------------------------------------------------

/// `automation.portBase` default.
pub const default_port_base: u16 = 9100;
/// `automation.portRange` default.
pub const default_port_range: u16 = 10;

pub const PortRange = struct {
    /// `CMUX_PORT`.
    start: u16,
    /// `CMUX_PORT_END` (inclusive).
    end: u16,
    /// `CMUX_PORT_RANGE`.
    size: u16,
};

/// `CMUX_PORT = base + ordinal * size`, `CMUX_PORT_END = CMUX_PORT + size - 1`.
/// `ordinal` is the workspace's 0-based per-session ordinal. Fails when
/// `size` is 0 or the range would pass 65535.
pub fn workspaceRange(base: u16, size: u16, ordinal: u32) error{OutOfRange}!PortRange {
    if (size == 0) return error.OutOfRange;
    const start: u64 = @as(u64, base) + @as(u64, ordinal) * size;
    const end: u64 = start + size - 1;
    if (end > std.math.maxInt(u16)) return error.OutOfRange;
    return .{ .start = @intCast(start), .end = @intCast(end), .size = size };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const v6_any = [_]u8{0} ** 16;
const v6_loopback = [_]u8{0} ** 15 ++ [_]u8{1};
const v6_mapped_loopback = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff, 127, 0, 0, 1 };
const v6_global = [_]u8{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 11 ++ [_]u8{1};

test "unit: meta: ports portFromMib and fromMib4 decode network order" {
    // dwLocalPort for 8080 (0x1F90) holds bytes 1F 90 00 00 in memory.
    const dw: u32 = @bitCast([4]u8{ 0x1F, 0x90, 0, 0 });
    try testing.expectEqual(@as(u16, 8080), portFromMib(dw));
    const addr: u32 = @bitCast([4]u8{ 127, 0, 0, 1 });
    const row = ListenerRow.fromMib4(mib_tcp_state_listen, addr, dw, 44);
    try testing.expectEqual(@as(u16, 8080), row.port);
    try testing.expect(row.addr.isLoopback());
    try testing.expectEqual(@as(u32, 44), row.pid);
    const row6 = ListenerRow.fromMib6(mib_tcp_state_listen, v6_any, dw, 1);
    try testing.expect(row6.addr.isAny());
}

test "unit: meta: ports address classification" {
    try testing.expect((Addr{ .v4 = .{ 127, 8, 9, 10 } }).isLoopback());
    try testing.expect(!(Addr{ .v4 = .{ 10, 0, 0, 1 } }).isLoopback());
    try testing.expect((Addr{ .v4 = .{ 0, 0, 0, 0 } }).isAny());
    try testing.expect((Addr{ .v6 = v6_loopback }).isLoopback());
    try testing.expect((Addr{ .v6 = v6_mapped_loopback }).isLoopback());
    try testing.expect((Addr{ .v6 = v6_any }).isAny());
    try testing.expect(!(Addr{ .v6 = v6_any }).isLoopback());
    try testing.expect(!(Addr{ .v6 = v6_global }).isLoopback());
    try testing.expect(!(Addr{ .v6 = v6_global }).isAny());
}

test "unit: meta: ports collect filters by pid and state, merges families" {
    const gpa = testing.allocator;
    const rows = [_]ListenerRow{
        .{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 8000, .pid = 10 },
        .{ .addr = .{ .v6 = v6_any }, .port = 8000, .pid = 10 },
        .{ .addr = .{ .v4 = .{ 127, 0, 0, 1 } }, .port = 5173, .pid = 11 },
        .{ .addr = .{ .v6 = v6_global }, .port = 3000, .pid = 11 },
        // Other process: not ours.
        .{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 445, .pid = 4 },
        // Not listening.
        .{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 9999, .pid = 10, .state = 5 },
        // Port 0.
        .{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 0, .pid = 10 },
        // Duplicate row.
        .{ .addr = .{ .v6 = v6_loopback }, .port = 5173, .pid = 11 },
    };
    const out = try collect(gpa, &rows, &.{ 11, 10, 10 });
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(Port{ .port = 3000, .specific = true, .ipv6 = true }, out[0]);
    try testing.expectEqual(Port{ .port = 5173, .loopback = true, .ipv4 = true, .ipv6 = true }, out[1]);
    try testing.expectEqual(Port{ .port = 8000, .any = true, .ipv4 = true, .ipv6 = true }, out[2]);
    try testing.expect(out[1].reachableViaLocalhost());
    try testing.expect(!out[0].reachableViaLocalhost());
}

test "unit: meta: ports collect with no rows or no pids" {
    const gpa = testing.allocator;
    const rows = [_]ListenerRow{.{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 80, .pid = 1 }};
    const a = try collect(gpa, &.{}, &.{1});
    defer gpa.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try collect(gpa, &rows, &.{});
    defer gpa.free(b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "unit: meta: ports collect handles every port number in random order" {
    const gpa = testing.allocator;
    const rows = try gpa.alloc(ListenerRow, 65535 * 2);
    defer gpa.free(rows);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    for (rows, 0..) |*r, i| {
        r.* = .{ .addr = .{ .v4 = .{ 127, 0, 0, 1 } }, .port = @intCast(i % 65535 + 1), .pid = 7 };
    }
    prng.random().shuffle(ListenerRow, rows);
    const out = try collect(gpa, rows, &.{7});
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 65535), out.len);
    for (out, 1..) |p, want| try testing.expectEqual(@as(u16, @intCast(want)), p.port);
}

test "unit: meta: ports Tracker survives one miss and retires on the second" {
    const gpa = testing.allocator;
    var t: Tracker = .{};
    defer t.deinit(gpa);
    const p3000: Port = .{ .port = 3000, .loopback = true, .ipv4 = true };
    const p8000: Port = .{ .port = 8000, .any = true, .ipv4 = true };

    try testing.expect(try t.update(gpa, &.{ p3000, p8000 }));
    try testing.expect(!try t.update(gpa, &.{ p3000, p8000 }));
    // 8000 missing once: still shown, no repaint.
    try testing.expect(!try t.update(gpa, &.{p3000}));
    {
        const ports_now = try t.ports(gpa);
        defer gpa.free(ports_now);
        try testing.expectEqualSlices(u16, &.{ 3000, 8000 }, ports_now);
    }
    // Back again: miss count resets.
    try testing.expect(!try t.update(gpa, &.{ p3000, p8000 }));
    try testing.expect(!try t.update(gpa, &.{p3000}));
    // Second consecutive miss retires it.
    try testing.expect(try t.update(gpa, &.{p3000}));
    {
        const ports_now = try t.ports(gpa);
        defer gpa.free(ports_now);
        try testing.expectEqualSlices(u16, &.{3000}, ports_now);
    }
    // Flag change counts as a change.
    var p3000v6 = p3000;
    p3000v6.ipv6 = true;
    try testing.expect(try t.update(gpa, &.{p3000v6}));
    // New port inserted in order.
    try testing.expect(try t.update(gpa, &.{ .{ .port = 22 }, p3000v6 }));
    {
        const ports_now = try t.ports(gpa);
        defer gpa.free(ports_now);
        try testing.expectEqualSlices(u16, &.{ 22, 3000 }, ports_now);
    }
    t.clear();
    try testing.expect(!try t.update(gpa, &.{}));
}

test "unit: meta: ports writeList formats the ports= value" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeList(&aw.writer, &.{});
    try testing.expectEqualStrings("", aw.written());
    try writeList(&aw.writer, &.{ 3000, 8080, 65535 });
    try testing.expectEqualStrings("3000,8080,65535", aw.written());
}

test "unit: meta: ports workspaceRange computes CMUX_PORT ranges" {
    const first = try workspaceRange(default_port_base, default_port_range, 0);
    try testing.expectEqual(PortRange{ .start = 9100, .end = 9109, .size = 10 }, first);
    const second = try workspaceRange(default_port_base, default_port_range, 1);
    try testing.expectEqual(PortRange{ .start = 9110, .end = 9119, .size = 10 }, second);
    const last = try workspaceRange(65530, 6, 0);
    try testing.expectEqual(@as(u16, 65535), last.end);
    try testing.expectError(error.OutOfRange, workspaceRange(65530, 7, 0));
    try testing.expectError(error.OutOfRange, workspaceRange(9100, 0, 0));
    try testing.expectError(error.OutOfRange, workspaceRange(9100, 10, std.math.maxInt(u32)));
}
