//! Element ref table for one browser surface (browser-element-refs): `@eN`
//! tokens (printed `eN`) mapped to a backendDOMNodeId, frame and CSS path.
//!
//! Lifecycle: `beginSnapshot` restarts numbering at e1 (a snapshot replaces
//! the previous ref set, so a login form yields e1, e2, e3). `find` adds to
//! the current set with `add`, reusing the ref of an element that already has
//! one. A main-frame navigation or `DOM.documentUpdated` drops every ref and
//! the selected frame; a subframe navigation drops only that frame's refs.
//! A dropped or never-issued ref fails with `error.RefNotFound`, which the RPC
//! layer reports as not_found "Element reference not found".

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ref_not_found_message = "Element reference not found";
pub const element_not_found_message = "Element not found";
pub const not_found_hint = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector.";

/// Socket param keys that may carry a selector or ref, in priority order.
pub const selector_param_keys = [_][]const u8{ "selector", "sel", "element_ref", "ref" };

pub const LookupError = error{ InvalidRef, RefNotFound };

/// What a ref points at. Strings are copied by `add`.
pub const Target = struct {
    backend_node_id: ?i64 = null,
    /// null = main frame.
    frame_id: ?[]const u8 = null,
    role: []const u8 = "",
    name: []const u8 = "",
    /// Document-relative CSS path (relative to `frame_id`'s document).
    css_path: ?[]const u8 = null,
};

pub const Entry = struct {
    id: u32,
    backend_node_id: ?i64,
    frame_id: ?[]const u8,
    role: []const u8,
    name: []const u8,
    css_path: ?[]const u8,

    fn deinit(self: *Entry, gpa: Allocator) void {
        if (self.frame_id) |f| gpa.free(f);
        gpa.free(self.role);
        gpa.free(self.name);
        if (self.css_path) |c| gpa.free(c);
    }
};

pub const RefTable = struct {
    gpa: Allocator,
    /// Ascending by id (ids are issued in order; removals keep order).
    entries: std.ArrayList(Entry) = .empty,
    /// backend id -> position in `entries` of its first entry.
    by_backend: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    next_id: u32 = 1,
    /// Bumped whenever the ref set is replaced or invalidated.
    generation: u64 = 0,
    /// Frame selected by `browser frame <sel>` (null = main). Owned.
    selected_frame: ?[]u8 = null,

    pub fn init(gpa: Allocator) RefTable {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RefTable) void {
        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.by_backend.deinit(self.gpa);
        if (self.selected_frame) |f| self.gpa.free(f);
        self.* = undefined;
    }

    pub fn count(self: *const RefTable) usize {
        return self.entries.items.len;
    }

    /// Start a fresh ref set (numbering restarts at e1).
    pub fn beginSnapshot(self: *RefTable) void {
        self.clearEntries();
        self.next_id = 1;
        self.generation +%= 1;
    }

    /// Register a target; returns its ref number. An element that already has
    /// a ref in the current set (same backend id and frame) keeps it.
    pub fn add(self: *RefTable, target: Target) Allocator.Error!u32 {
        if (target.backend_node_id) |bid| {
            if (self.by_backend.get(bid)) |pos| {
                const first = self.entries.items[pos];
                if (optEql(first.frame_id, target.frame_id)) return first.id;
                // Same backend id in another frame: rare, scan.
                for (self.entries.items[pos + 1 ..]) |e| {
                    if (e.backend_node_id == bid and optEql(e.frame_id, target.frame_id)) return e.id;
                }
            }
        }
        const gpa = self.gpa;
        const frame = if (target.frame_id) |f| try gpa.dupe(u8, f) else null;
        errdefer if (frame) |f| gpa.free(f);
        const role = try gpa.dupe(u8, target.role);
        errdefer gpa.free(role);
        const name = try gpa.dupe(u8, target.name);
        errdefer gpa.free(name);
        const css = if (target.css_path) |c| try gpa.dupe(u8, c) else null;
        errdefer if (css) |c| gpa.free(c);
        try self.entries.ensureUnusedCapacity(gpa, 1);
        if (target.backend_node_id != null) try self.by_backend.ensureUnusedCapacity(gpa, 1);
        const id = self.next_id;
        const pos: u32 = @intCast(self.entries.items.len);
        if (target.backend_node_id) |bid| {
            const gop = self.by_backend.getOrPutAssumeCapacity(bid);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        }
        self.entries.appendAssumeCapacity(.{
            .id = id,
            .backend_node_id = target.backend_node_id,
            .frame_id = frame,
            .role = role,
            .name = name,
            .css_path = css,
        });
        self.next_id +|= 1;
        return id;
    }

    /// Resolve `e3`, `@e3` or `ref=e3`.
    pub fn lookup(self: *const RefTable, token: []const u8) LookupError!*const Entry {
        const id = parseRefToken(token) orelse return error.InvalidRef;
        return self.lookupId(id) orelse error.RefNotFound;
    }

    pub fn lookupId(self: *const RefTable, id: u32) ?*const Entry {
        return @constCast(self).entryMut(id);
    }

    /// Mutable entry by id (binary search; entries are ascending by id).
    pub fn entryMut(self: *RefTable, id: u32) ?*Entry {
        const items = self.entries.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].id == id) return &items[mid];
            if (items[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Navigation committed in `frame_id` (null or `is_main` = main frame).
    pub fn onNavigation(self: *RefTable, frame_id: ?[]const u8, is_main: bool) void {
        if (is_main or frame_id == null) {
            self.clearEntries();
            self.setSelectedFrame(null) catch unreachable; // null never allocates
            self.generation +%= 1;
            return;
        }
        const f = frame_id.?;
        var i: usize = 0;
        var removed = false;
        while (i < self.entries.items.len) {
            const e = &self.entries.items[i];
            if (e.frame_id != null and std.mem.eql(u8, e.frame_id.?, f)) {
                e.deinit(self.gpa);
                _ = self.entries.orderedRemove(i);
                removed = true;
            } else i += 1;
        }
        if (self.selected_frame) |sf| if (std.mem.eql(u8, sf, f)) {
            self.setSelectedFrame(null) catch unreachable;
            removed = true;
        };
        if (removed) {
            self.reindex();
            self.generation +%= 1;
        }
    }

    /// `DOM.documentUpdated`: the whole document was replaced.
    pub fn onDocumentUpdated(self: *RefTable) void {
        self.clearEntries();
        self.generation +%= 1;
    }

    /// `DOM.childNodeRemoved` (or a failed resolve): drop refs to that node.
    pub fn onNodeRemoved(self: *RefTable, backend_node_id: i64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = &self.entries.items[i];
            if (e.backend_node_id == backend_node_id) {
                e.deinit(self.gpa);
                _ = self.entries.orderedRemove(i);
                self.generation +%= 1;
            } else i += 1;
        }
        self.reindex();
    }

    /// Rebuild `by_backend` after removals. Never allocates: the map only
    /// shrinks relative to its previous contents.
    fn reindex(self: *RefTable) void {
        self.by_backend.clearRetainingCapacity();
        for (self.entries.items, 0..) |e, pos| {
            const bid = e.backend_node_id orelse continue;
            const gop = self.by_backend.getOrPutAssumeCapacity(bid);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(pos);
        }
    }

    pub fn setSelectedFrame(self: *RefTable, frame_id: ?[]const u8) Allocator.Error!void {
        const copy = if (frame_id) |f| try self.gpa.dupe(u8, f) else null;
        if (self.selected_frame) |old| self.gpa.free(old);
        self.selected_frame = copy;
    }

    /// `{"e1":{"role":…,"name":…},…}` (the snapshot JSON `refs` member).
    pub fn writeJson(self: *const RefTable, s: *std.json.Stringify) std.Io.Writer.Error!void {
        try s.beginObject();
        var buf: [16]u8 = undefined;
        for (self.entries.items) |e| {
            try s.objectField(formatRef(&buf, e.id));
            try s.beginObject();
            try s.objectField("role");
            try s.write(e.role);
            try s.objectField("name");
            try s.write(e.name);
            try s.endObject();
        }
        try s.endObject();
    }

    fn clearEntries(self: *RefTable) void {
        for (self.entries.items) |*e| e.deinit(self.gpa);
        self.entries.clearRetainingCapacity();
        self.by_backend.clearRetainingCapacity();
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// `e3`, `@e3` or `ref=e3` (surrounding whitespace allowed) -> 3. Rejects
/// signs, empty digits, leading zeros, overflow and trailing junk.
pub fn parseRefToken(token: []const u8) ?u32 {
    var s = std.mem.trim(u8, token, " \t\r\n");
    if (std.mem.startsWith(u8, s, "ref=")) {
        s = s[4..];
    } else if (s.len > 0 and s[0] == '@') {
        s = s[1..];
    }
    if (s.len < 2 or s[0] != 'e') return null;
    const digits = s[1..];
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits.len > 1 and digits[0] == '0') return null;
    const v = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (v == 0) return null;
    return v;
}

pub fn isRefToken(s: []const u8) bool {
    return parseRefToken(s) != null;
}

/// "e<id>" into `buf` ("e" + at most 10 digits always fits).
pub fn formatRef(buf: *[16]u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "e{d}", .{id}) catch unreachable;
}

/// First non-empty string among `selector`, `sel`, `element_ref`, `ref`.
pub fn selectorFromParams(params: std.json.ObjectMap) ?[]const u8 {
    for (selector_param_keys) |k| {
        const v = params.get(k) orelse continue;
        if (v != .string) continue;
        if (std.mem.trim(u8, v.string, " \t\r\n").len == 0) continue;
        return v.string;
    }
    return null;
}

/// v2 error code and message for errors raised by this package's resolvers.
pub const ErrorInfo = struct { code: []const u8, message: []const u8 };

pub fn errorInfo(err: anyerror) ErrorInfo {
    return switch (err) {
        error.RefNotFound => .{ .code = "not_found", .message = ref_not_found_message },
        error.ElementNotFound => .{ .code = "not_found", .message = element_not_found_message },
        error.InvalidRef => .{ .code = "invalid_params", .message = "Invalid element reference" },
        error.InvalidSelector => .{ .code = "invalid_params", .message = "Invalid selector" },
        error.UnsupportedSelector => .{ .code = "not_supported", .message = "Selector not supported natively" },
        error.MissingParam, error.InvalidParams, error.EmptyValue, error.UnknownFlag, error.MissingValue, error.UnexpectedArgument, error.InvalidNumber => .{ .code = "invalid_params", .message = "Invalid parameters" },
        error.OutOfMemory => .{ .code = "internal_error", .message = "Out of memory" },
        else => .{ .code = "internal_error", .message = "Internal error" },
    };
}

/// `data` of an element-not-found error (cmux diagnostics payload).
pub const Diagnostics = struct {
    selector: []const u8,
    match_count: usize = 0,
    visible_match_count: usize = 0,
    sample: []const []const u8 = &.{},
    snapshot_excerpt: []const u8 = "",
    body_excerpt: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    action: []const u8 = "",
    retry_attempts: u32 = 0,

    pub fn write(self: *const Diagnostics, s: *std.json.Stringify) std.Io.Writer.Error!void {
        try s.beginObject();
        try s.objectField("selector");
        try s.write(self.selector);
        try s.objectField("match_count");
        try s.write(self.match_count);
        try s.objectField("visible_match_count");
        try s.write(self.visible_match_count);
        try s.objectField("sample");
        try s.write(self.sample);
        try s.objectField("snapshot_excerpt");
        try s.write(self.snapshot_excerpt);
        try s.objectField("body_excerpt");
        try s.write(self.body_excerpt);
        try s.objectField("title");
        try s.write(self.title);
        try s.objectField("url");
        try s.write(self.url);
        try s.objectField("action");
        try s.write(self.action);
        try s.objectField("retry_attempts");
        try s.write(self.retry_attempts);
        try s.objectField("hint");
        try s.write(not_found_hint);
        try s.endObject();
    }
};
