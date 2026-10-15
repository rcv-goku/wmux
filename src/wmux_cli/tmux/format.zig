//! tmux format strings (`-F`, `display-message -p`): `#{name}` variables,
//! `#{?cond,then,else}` conditionals, `#{==:a,b}` / `#{!=:a,b}` comparisons,
//! the short aliases `#D #F #I #P #S #T #W` and the escapes `##`, `#,` and
//! `#}`. Unresolved long tokens expand to nothing (cmux strips them); the
//! variable values come from a caller-supplied resolver.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Resolver = struct {
    ptr: *const anyopaque,
    lookupFn: *const fn (ptr: *const anyopaque, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8,

    pub fn lookup(self: Resolver, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        return self.lookupFn(self.ptr, arena, name);
    }
};

/// Recursion bound for nested `#{...}`; deeper input is emitted as-is.
const max_depth = 32;

fn shortAlias(c: u8) ?[]const u8 {
    return switch (c) {
        'D' => "pane_id",
        'F' => "window_flags",
        'I' => "window_index",
        'P' => "pane_index",
        'S' => "session_name",
        'T' => "pane_title",
        'W' => "window_name",
        else => null,
    };
}

/// tmux truthiness: non-empty and not "0".
pub fn truthy(s: []const u8) bool {
    return s.len > 0 and !std.mem.eql(u8, s, "0");
}

pub fn expand(arena: Allocator, fmt: []const u8, r: Resolver) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try expandInto(arena, &out, fmt, r, 0);
    return out.items;
}

fn expandInto(arena: Allocator, out: *std.ArrayList(u8), fmt: []const u8, r: Resolver, depth: usize) Allocator.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '#' or i + 1 >= fmt.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const n = fmt[i + 1];
        switch (n) {
            '#', ',', '}' => {
                try out.append(arena, n);
                i += 2;
            },
            '{' => {
                const close = matchingBrace(fmt, i + 2) orelse {
                    // Unterminated: keep the rest verbatim.
                    try out.appendSlice(arena, fmt[i..]);
                    return;
                };
                const body = fmt[i + 2 .. close];
                if (depth >= max_depth) {
                    try out.appendSlice(arena, fmt[i .. close + 1]);
                } else {
                    try expandToken(arena, out, body, r, depth + 1);
                }
                i = close + 1;
            },
            else => {
                if (shortAlias(n)) |name| {
                    if (try r.lookup(arena, name)) |v| try out.appendSlice(arena, v);
                } else {
                    try out.appendSlice(arena, fmt[i .. i + 2]);
                }
                i += 2;
            },
        }
    }
}

/// Index of the `}` closing a `#{` whose body starts at `start`.
fn matchingBrace(fmt: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '#' and i + 1 < fmt.len) {
            if (fmt[i + 1] == '{') {
                depth += 1;
                i += 1;
            } else {
                i += 1; // `##`, `#}`, `#,` and aliases never close
            }
            continue;
        }
        if (fmt[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Splits `s` at top-level commas (not inside a nested `#{...}`).
fn splitTopLevel(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '#' and i + 1 < s.len) {
            if (s[i + 1] == '{') depth += 1;
            i += 1;
            continue;
        }
        if (c == '}' and depth > 0) {
            depth -= 1;
        } else if (c == ',' and depth == 0) {
            try parts.append(arena, s[start..i]);
            start = i + 1;
        }
    }
    try parts.append(arena, s[start..]);
    return parts.items;
}

fn evalOperand(arena: Allocator, s: []const u8, r: Resolver, depth: usize) Allocator.Error![]const u8 {
    var tmp: std.ArrayList(u8) = .empty;
    try expandInto(arena, &tmp, s, r, depth);
    return tmp.items;
}

fn expandToken(arena: Allocator, out: *std.ArrayList(u8), body: []const u8, r: Resolver, depth: usize) Allocator.Error!void {
    if (body.len == 0) return;
    if (body[0] == '?') {
        const parts = try splitTopLevel(arena, body[1..]);
        if (parts.len < 2) return;
        const cond_src = parts[0];
        const cond = if (std.mem.indexOf(u8, cond_src, "#{") != null)
            try evalOperand(arena, cond_src, r, depth)
        else
            (try r.lookup(arena, cond_src)) orelse "";
        const chosen = if (truthy(cond)) parts[1] else if (parts.len > 2) parts[2] else "";
        try expandInto(arena, out, chosen, r, depth);
        return;
    }
    if (std.mem.startsWith(u8, body, "==:") or std.mem.startsWith(u8, body, "!=:")) {
        const parts = try splitTopLevel(arena, body[3..]);
        if (parts.len != 2) return;
        const a = try evalOperand(arena, parts[0], r, depth);
        const b = try evalOperand(arena, parts[1], r, depth);
        const eq = std.mem.eql(u8, a, b);
        try out.append(arena, if (eq == (body[0] == '=')) '1' else '0');
        return;
    }
    if (try r.lookup(arena, body)) |v| try out.appendSlice(arena, v);
}

const testing = std.testing;

const TestVars = struct {
    fn lookup(_: *const anyopaque, _: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "pane_id", "%3" },
            .{ "pane_active", "1" },
            .{ "window_active", "0" },
            .{ "session_name", "dev" },
            .{ "window_index", "0" },
            .{ "pane_title", "naïve ✓" },
        });
        return map.get(name);
    }
    const resolver: Resolver = .{ .ptr = undefined, .lookupFn = lookup };
};

fn expectExpand(want: []const u8, fmt: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(want, try expand(arena_state.allocator(), fmt, TestVars.resolver));
}

test "unit: tmux: format: variables, aliases and escapes" {
    try expectExpand("%3", "#{pane_id}");
    try expectExpand("dev:0 %3", "#{session_name}:#{window_index} #D");
    try expectExpand("dev", "#S");
    try expectExpand("a##b", "a####b");
    try expectExpand("#", "#");
    try expectExpand("x#", "x#");
    try expectExpand("#Q", "#Q");
    try expectExpand("naïve ✓", "#{pane_title}");
    try expectExpand("", "");
}

test "unit: tmux: format: unknown long tokens are stripped" {
    try expectExpand("[]", "[#{no_such_var}]");
    try expectExpand("", "#{}");
}

test "unit: tmux: format: conditionals and comparisons" {
    try expectExpand(" (active)", "#{?pane_active, (active),}");
    try expectExpand("no", "#{?window_active,yes,no}");
    try expectExpand("", "#{?window_active,yes}");
    try expectExpand("in dev", "#{?#{==:#{session_name},dev},in #{session_name},elsewhere}");
    try expectExpand("1", "#{!=:#{pane_id},%4}");
    try expectExpand("0", "#{==:a,b}");
    try expectExpand("a,b", "#{?pane_active,a#,b,c}");
}

test "unit: tmux: format: malformed input is kept verbatim" {
    try expectExpand("#{pane_id", "#{pane_id");
    try expectExpand("x #{?a", "x #{?a");
    // Deep nesting beyond the bound must not recurse forever.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var deep: std.ArrayList(u8) = .empty;
    for (0..200) |_| try deep.appendSlice(a, "#{?pane_active,");
    try deep.appendSlice(a, "x");
    for (0..200) |_| try deep.appendSlice(a, ",}");
    _ = try expand(a, deep.items, TestVars.resolver);
}
