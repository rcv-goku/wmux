//! Workspace lifecycle status lanes (feature `workspace_status`): the
//! inferred lane from live signals, a manual pin `{status, inferred_at_override}`
//! that auto-clears once inference moves (anti-rot), `auto`/`none`, `cycle`,
//! and the `workspace status` text and JSON payloads. Pure: std only.
//! Signals arrive as plain values so this file never imports other features.

const std = @import("std");

/// Lane wire values are frozen: `todo`, `working`, `needs-attention`,
/// `review`, `done`. Declaration order is the `cycle` order.
pub const Lane = enum {
    todo,
    working,
    needs_attention,
    review,
    done,

    pub fn wireName(self: Lane) []const u8 {
        return switch (self) {
            .todo => "todo",
            .working => "working",
            .needs_attention => "needs-attention",
            .review => "review",
            .done => "done",
        };
    }

    pub fn parse(s: []const u8) ?Lane {
        const map = std.StaticStringMap(Lane).initComptime(.{
            .{ "todo", .todo },
            .{ "working", .working },
            .{ "needs-attention", .needs_attention },
            .{ "review", .review },
            .{ "done", .done },
        });
        return map.get(s);
    }

    /// todo → working → needs-attention → review → done → todo.
    pub fn next(self: Lane) Lane {
        return switch (self) {
            .done => .todo,
            else => @enumFromInt(@intFromEnum(self) + 1),
        };
    }

    pub fn jsonStringify(self: Lane, jws: anytype) !void {
        try jws.write(self.wireName());
    }

    /// Inverse of `jsonStringify`: std.json would otherwise match tag names
    /// and reject `"needs-attention"`. Only wire-name strings are accepted.
    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Lane {
        const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
        defer switch (token) {
            .allocated_number, .allocated_string => |s| gpa.free(s),
            else => {},
        };
        return switch (token) {
            inline .string, .allocated_string => |s| parse(s) orelse error.InvalidEnumTag,
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(gpa: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Lane {
        _ = gpa;
        _ = options;
        return switch (source) {
            .string => |s| parse(s) orelse error.InvalidEnumTag,
            else => error.UnexpectedToken,
        };
    }
};

/// Agent lifecycle state as published by the `agents` feature (ADR-10.4).
pub const AgentState = enum {
    unknown,
    running,
    needs_input,
    idle,
    background_work_pending,
    ended,
};

/// Pull-request counts for the workspace's branch(es).
pub const PrCounts = struct {
    open: u32 = 0,
    merged: u32 = 0,
    closed: u32 = 0,

    pub fn total(self: PrCounts) u64 {
        return @as(u64, self.open) + self.merged + self.closed;
    }
};

/// Everything inference looks at. Defaults describe an idle workspace.
pub const Signals = struct {
    /// One entry per agent session bound to the workspace's surfaces.
    agents: []const AgentState = &.{},
    /// An agent notification asking the user for input (permission, question)
    /// that the lifecycle has not folded into `needs_input` yet.
    attention_requested: bool = false,
    prs: PrCounts = .{},
    git_dirty: bool = false,
    /// wmux extension, off unless the caller opts in: a checklist item marked
    /// in-progress counts like a dirty tree (`working`).
    todo_in_progress: bool = false,
};

/// Inferred lane, first match wins: an agent needs input → needs-attention;
/// an agent is running → working; an open PR → review; PRs exist and all are
/// merged or closed → done; a dirty tree → working; otherwise todo.
pub fn infer(s: Signals) Lane {
    var running = false;
    for (s.agents) |a| switch (a) {
        .needs_input => return .needs_attention,
        .running, .background_work_pending => running = true,
        .unknown, .idle, .ended => {},
    };
    if (s.attention_requested) return .needs_attention;
    if (running) return .working;
    if (s.prs.open > 0) return .review;
    if (s.prs.total() > 0) return .done;
    if (s.git_dirty or s.todo_in_progress) return .working;
    return .todo;
}

/// Persisted manual pin.
pub const Override = struct {
    status: Lane,
    inferred_at_override: Lane,
};

/// `workspace status set <lane|auto|none>`.
pub const SetCommand = union(enum) {
    lane: Lane,
    auto,
    none,

    pub fn parse(s: []const u8) ?SetCommand {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "none")) return .none;
        return .{ .lane = Lane.parse(s) orelse return null };
    }
};

/// `workspace status [set <x> | cycle]` after the `status` word.
pub const Subcommand = union(enum) {
    get,
    set: SetCommand,
    cycle,
};

pub const ParseError = error{ UnknownSubcommand, MissingLane, InvalidLane };

/// Parses the positional words after `workspace status`. On error,
/// `writeParseError` renders the message for the same `args`.
pub fn parseSubcommand(args: []const []const u8) ParseError!Subcommand {
    if (args.len == 0) return .get;
    const verb = args[0];
    if (std.mem.eql(u8, verb, "cycle")) {
        if (args.len > 1) return error.UnknownSubcommand;
        return .cycle;
    }
    if (std.mem.eql(u8, verb, "set")) {
        if (args.len < 2) return error.MissingLane;
        if (args.len > 2) return error.InvalidLane;
        return .{ .set = SetCommand.parse(args[1]) orelse return error.InvalidLane };
    }
    return error.UnknownSubcommand;
}

pub fn writeParseError(w: *std.Io.Writer, err: ParseError, args: []const []const u8) std.Io.Writer.Error!void {
    switch (err) {
        error.UnknownSubcommand => {
            const x = if (args.len == 0) "" else if (std.mem.eql(u8, args[0], "cycle") and args.len > 1) args[1] else args[0];
            try w.print("Unknown workspace status subcommand: {s}. Try: cmux workspace status [set <lane|auto> | cycle]", .{x});
        },
        error.MissingLane => try w.writeAll("workspace status set requires a lane: todo, working, needs-attention, review, done, auto or none"),
        error.InvalidLane => {
            // Every word after `set`: `set needs attention` names
            // "needs attention", not a lone (and misleading) "needs".
            try w.writeAll("Invalid workspace status: ");
            if (args.len > 1) {
                for (args[1..], 0..) |word, i| {
                    if (i > 0) try w.writeByte(' ');
                    try w.writeAll(word);
                }
            }
            try w.writeAll(" (expected todo, working, needs-attention, review, done, auto or none)");
        },
    }
}

/// Per-workspace status state (persisted in the session).
pub const Status = struct {
    override: ?Override = null,
    /// `set none`: hide the status glyph for this workspace.
    hidden: bool = false,

    /// Default for workspaces created during the session; restored ones
    /// (including older snapshots without the field) use `.{}`.
    pub const new_workspace: Status = .{ .hidden = true };

    /// The pin while the live inferred lane still equals the lane recorded
    /// when it was set; otherwise the inferred lane. Never mutates.
    pub fn effective(self: Status, inferred: Lane) Lane {
        if (self.activePin(inferred)) |o| return o.status;
        return inferred;
    }

    pub fn activePin(self: Status, inferred: Lane) ?Override {
        const o = self.override orelse return null;
        return if (o.inferred_at_override == inferred) o else null;
    }

    /// Anti-rot: drops a pin whose recorded inferred lane no longer matches.
    /// Returns true when it cleared one (caller persists and emits).
    pub fn reconcile(self: *Status, inferred: Lane) bool {
        const o = self.override orelse return false;
        if (o.inferred_at_override == inferred) return false;
        self.override = null;
        return true;
    }

    /// `set <lane>` pins it against the current inferred lane, `auto` clears
    /// the pin; both make the status visible again. `none` only hides (an
    /// existing pin survives under the hidden flag).
    pub fn set(self: *Status, cmd: SetCommand, inferred: Lane) void {
        switch (cmd) {
            .lane => |l| {
                self.override = .{ .status = l, .inferred_at_override = inferred };
                self.hidden = false;
            },
            .auto => {
                self.override = null;
                self.hidden = false;
            },
            .none => self.hidden = true,
        }
    }

    /// Advances the manual lane one step from the current effective lane and
    /// pins it. Returns the new effective lane.
    pub fn cycle(self: *Status, inferred: Lane) Lane {
        _ = self.reconcile(inferred);
        const to = self.effective(inferred).next();
        self.set(.{ .lane = to }, inferred);
        return to;
    }

    /// True when a row should draw the lane glyph: controls on, not hidden,
    /// and a live manual pin (automatic status draws no row chrome).
    pub fn showsGlyph(self: Status, controls_enabled: bool, inferred: Lane) bool {
        return controls_enabled and !self.hidden and self.activePin(inferred) != null;
    }

    pub fn payload(self: Status, inferred: Lane) Payload {
        return .{
            .effective = self.effective(inferred),
            .inferred = inferred,
            .override = self.activePin(inferred),
        };
    }
};

/// `workspace.status.get` / `--json`:
/// `{"effective":..,"inferred":..,"override":{"status":..,"inferred_at_override":..}|null}`.
pub const Payload = struct {
    effective: Lane,
    inferred: Lane,
    override: ?Override,

    /// Three lines: `<effective>`, `inferred: <lane>`, then
    /// `override: <status> (auto-clears when inferred moves off <lane>)` or
    /// `override: none (auto)`.
    pub fn writeText(self: Payload, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}\ninferred: {s}\n", .{ self.effective.wireName(), self.inferred.wireName() });
        if (self.override) |o| {
            try w.print("override: {s} (auto-clears when inferred moves off {s})\n", .{
                o.status.wireName(), o.inferred_at_override.wireName(),
            });
        } else {
            try w.writeAll("override: none (auto)\n");
        }
    }
};

/// Status menu / popover first entry: `Auto — <inferred>`, or
/// `Auto — return to <inferred>` while a pin is active.
pub fn writeAutoLabel(w: *std.Io.Writer, status: Status, inferred: Lane) std.Io.Writer.Error!void {
    const verb = if (status.activePin(inferred) != null) "return to " else "";
    try w.print("Auto \u{2014} {s}{s}", .{ verb, inferred.wireName() });
}

/// Edge detector for "status first reaches done": `observe` returns true once
/// per transition of the effective lane into `done`.
pub const DoneEdge = struct {
    done: bool = false,

    pub fn observe(self: *DoneEdge, effective: Lane) bool {
        const now = effective == .done;
        defer self.done = now;
        return now and !self.done;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn text(p: Payload) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try p.writeText(&aw.writer);
    return aw.toOwnedSlice();
}

test "unit: workspace_status: lane wire names, parse and cycle order" {
    inline for (std.meta.fields(Lane)) |f| {
        const l: Lane = @enumFromInt(f.value);
        try testing.expectEqual(l, Lane.parse(l.wireName()).?);
    }
    try testing.expectEqualStrings("needs-attention", Lane.needs_attention.wireName());
    try testing.expect(Lane.parse("needs_attention") == null);
    try testing.expect(Lane.parse("Done") == null);
    try testing.expect(Lane.parse("") == null);
    try testing.expectEqual(Lane.working, Lane.todo.next());
    try testing.expectEqual(Lane.needs_attention, Lane.working.next());
    try testing.expectEqual(Lane.review, Lane.needs_attention.next());
    try testing.expectEqual(Lane.done, Lane.review.next());
    try testing.expectEqual(Lane.todo, Lane.done.next());
}

test "unit: workspace_status: inference first match wins" {
    try testing.expectEqual(Lane.todo, infer(.{}));
    try testing.expectEqual(Lane.working, infer(.{ .git_dirty = true }));
    try testing.expectEqual(Lane.done, infer(.{ .prs = .{ .merged = 1, .closed = 2 }, .git_dirty = true }));
    try testing.expectEqual(Lane.review, infer(.{ .prs = .{ .open = 1, .merged = 3 } }));
    try testing.expectEqual(Lane.working, infer(.{
        .agents = &.{ .idle, .running },
        .prs = .{ .open = 1 },
    }));
    try testing.expectEqual(Lane.working, infer(.{ .agents = &.{.background_work_pending} }));
    // needs input beats running regardless of order.
    try testing.expectEqual(Lane.needs_attention, infer(.{ .agents = &.{ .running, .needs_input } }));
    try testing.expectEqual(Lane.needs_attention, infer(.{ .agents = &.{.running}, .attention_requested = true }));
    // Idle, ended and unknown agents contribute nothing.
    try testing.expectEqual(Lane.todo, infer(.{ .agents = &.{ .idle, .ended, .unknown } }));
    // Todo signal is opt-in and ranks with a dirty tree.
    try testing.expectEqual(Lane.working, infer(.{ .todo_in_progress = true }));
    try testing.expectEqual(Lane.review, infer(.{ .todo_in_progress = true, .prs = .{ .open = 1 } }));
    // Huge counts do not overflow.
    const max = std.math.maxInt(u32);
    try testing.expectEqual(Lane.done, infer(.{ .prs = .{ .merged = max, .closed = max } }));
}

test "unit: workspace_status: pin holds while inferred is unchanged then auto-clears" {
    var s: Status = .{};
    // `set review` while an agent is working.
    s.set(.{ .lane = .review }, .working);
    try testing.expectEqual(Lane.review, s.effective(.working));
    try testing.expect(!s.reconcile(.working));
    // The agent finishes: inference moves → effective follows, pin clears.
    try testing.expectEqual(Lane.todo, s.effective(.todo));
    try testing.expect(s.reconcile(.todo));
    try testing.expect(s.override == null);
    // Even if inference returns to the old lane, the pin stays gone.
    try testing.expectEqual(Lane.working, s.effective(.working));
}

test "unit: workspace_status: auto clears immediately, none hides but keeps the pin" {
    var s: Status = .new_workspace;
    try testing.expect(s.hidden);
    s.set(.{ .lane = .done }, .todo);
    try testing.expect(!s.hidden);
    try testing.expect(s.showsGlyph(true, .todo));
    try testing.expect(!s.showsGlyph(false, .todo));
    s.set(.none, .todo);
    try testing.expect(s.hidden);
    try testing.expectEqual(Lane.done, s.effective(.todo));
    try testing.expect(!s.showsGlyph(true, .todo));
    s.set(.auto, .todo);
    try testing.expect(!s.hidden);
    try testing.expect(s.override == null);
    try testing.expectEqual(Lane.todo, s.effective(.todo));
    try testing.expect(!s.showsGlyph(true, .todo));
}

test "unit: workspace_status: cycle advances from the effective lane and wraps" {
    var s: Status = .{};
    try testing.expectEqual(Lane.working, s.cycle(.todo));
    try testing.expectEqual(Lane.needs_attention, s.cycle(.todo));
    try testing.expectEqual(Lane.review, s.cycle(.todo));
    try testing.expectEqual(Lane.done, s.cycle(.todo));
    try testing.expectEqual(Lane.todo, s.cycle(.todo));
    try testing.expectEqual(Override{ .status = .todo, .inferred_at_override = .todo }, s.override.?);
    // A stale pin is dropped first; cycling starts from the live inferred lane.
    s.set(.{ .lane = .done }, .todo);
    try testing.expectEqual(Lane.done, s.cycle(.review));
    try testing.expectEqual(Lane.review, s.override.?.inferred_at_override);
}

test "unit: workspace_status: text output three lines" {
    const gpa = testing.allocator;
    var s: Status = .{};
    {
        const t = try text(s.payload(.working));
        defer gpa.free(t);
        try testing.expectEqualStrings("working\ninferred: working\noverride: none (auto)\n", t);
    }
    s.set(.{ .lane = .done }, .needs_attention);
    {
        const t = try text(s.payload(.needs_attention));
        defer gpa.free(t);
        try testing.expectEqualStrings(
            "done\ninferred: needs-attention\noverride: done (auto-clears when inferred moves off needs-attention)\n",
            t,
        );
    }
    // A stale pin is not reported.
    const t = try text(s.payload(.todo));
    defer gpa.free(t);
    try testing.expectEqualStrings("todo\ninferred: todo\noverride: none (auto)\n", t);
}

test "unit: workspace_status: json payload keys" {
    const gpa = testing.allocator;
    var s: Status = .{};
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(s.payload(.todo), .{}, &aw.writer);
    try testing.expectEqualStrings("{\"effective\":\"todo\",\"inferred\":\"todo\",\"override\":null}", aw.written());
    aw.clearRetainingCapacity();
    s.set(.{ .lane = .review }, .working);
    try std.json.Stringify.value(s.payload(.working), .{}, &aw.writer);
    try testing.expectEqualStrings(
        "{\"effective\":\"review\",\"inferred\":\"working\",\"override\":{\"status\":\"review\",\"inferred_at_override\":\"working\"}}",
        aw.written(),
    );
    // Override round-trips through std.json for the session snapshot.
    const parsed = try std.json.parseFromSlice(Override, gpa, "{\"status\":\"done\",\"inferred_at_override\":\"todo\"}", .{});
    defer parsed.deinit();
    try testing.expectEqual(Override{ .status = .done, .inferred_at_override = .todo }, parsed.value);
}

test "unit: workspace_status: every lane round-trips through std.json by wire name" {
    const gpa = testing.allocator;
    inline for (std.meta.fields(Lane)) |f| {
        const l: Lane = @enumFromInt(f.value);
        const o: Override = .{ .status = l, .inferred_at_override = l.next() };
        const json = try std.json.Stringify.valueAlloc(gpa, o, .{});
        defer gpa.free(json);
        const parsed = try std.json.parseFromSlice(Override, gpa, json, .{});
        defer parsed.deinit();
        try testing.expectEqual(o, parsed.value);
        const tree = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer tree.deinit();
        const from_value = try std.json.parseFromValue(Override, gpa, tree.value, .{});
        defer from_value.deinit();
        try testing.expectEqual(o, from_value.value);
    }
    // A persisted Status keeps a needs-attention pin.
    const status: Status = .{ .override = .{ .status = .needs_attention, .inferred_at_override = .working }, .hidden = true };
    const json = try std.json.Stringify.valueAlloc(gpa, status, .{});
    defer gpa.free(json);
    const back = try std.json.parseFromSlice(Status, gpa, json, .{});
    defer back.deinit();
    try testing.expectEqual(status, back.value);
    // Tag spellings and enum numbers are not wire names.
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Lane, gpa, "\"needs_attention\"", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Lane, gpa, "2", .{}));
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromValue(Lane, gpa, .{ .string = "auto" }, .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromValue(Lane, gpa, .{ .integer = 2 }, .{}));
}

test "unit: workspace_status: subcommand parsing and error strings" {
    try testing.expectEqual(Subcommand.get, try parseSubcommand(&.{}));
    try testing.expectEqual(Subcommand.cycle, try parseSubcommand(&.{"cycle"}));
    try testing.expectEqual(Subcommand{ .set = .{ .lane = .needs_attention } }, try parseSubcommand(&.{ "set", "needs-attention" }));
    try testing.expectEqual(Subcommand{ .set = .auto }, try parseSubcommand(&.{ "set", "auto" }));
    try testing.expectEqual(Subcommand{ .set = .none }, try parseSubcommand(&.{ "set", "none" }));

    const Case = struct { args: []const []const u8, err: ParseError, msg: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{"bogus"}, .err = error.UnknownSubcommand, .msg = "Unknown workspace status subcommand: bogus. Try: cmux workspace status [set <lane|auto> | cycle]" },
        .{ .args = &.{ "cycle", "x" }, .err = error.UnknownSubcommand, .msg = "Unknown workspace status subcommand: x. Try: cmux workspace status [set <lane|auto> | cycle]" },
        .{ .args = &.{"set"}, .err = error.MissingLane, .msg = "workspace status set requires a lane: todo, working, needs-attention, review, done, auto or none" },
        .{ .args = &.{ "set", "Done" }, .err = error.InvalidLane, .msg = "Invalid workspace status: Done (expected todo, working, needs-attention, review, done, auto or none)" },
        .{ .args = &.{ "set", "" }, .err = error.InvalidLane, .msg = "Invalid workspace status:  (expected todo, working, needs-attention, review, done, auto or none)" },
        .{ .args = &.{ "set", "done", "extra" }, .err = error.InvalidLane, .msg = "Invalid workspace status: done extra (expected todo, working, needs-attention, review, done, auto or none)" },
        .{ .args = &.{ "set", "needs", "attention" }, .err = error.InvalidLane, .msg = "Invalid workspace status: needs attention (expected todo, working, needs-attention, review, done, auto or none)" },
        .{ .args = &.{"ünïcødé"}, .err = error.UnknownSubcommand, .msg = "Unknown workspace status subcommand: ünïcødé. Try: cmux workspace status [set <lane|auto> | cycle]" },
    };
    for (cases) |c| {
        try testing.expectError(c.err, parseSubcommand(c.args));
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeParseError(&w, c.err, c.args);
        try testing.expectEqualStrings(c.msg, w.buffered());
    }
}

test "unit: workspace_status: auto label reflects an active pin" {
    var buf: [64]u8 = undefined;
    var s: Status = .{};
    var w: std.Io.Writer = .fixed(&buf);
    try writeAutoLabel(&w, s, .working);
    try testing.expectEqualStrings("Auto \u{2014} working", w.buffered());
    s.set(.{ .lane = .review }, .working);
    w = .fixed(&buf);
    try writeAutoLabel(&w, s, .working);
    try testing.expectEqualStrings("Auto \u{2014} return to working", w.buffered());
}

test "unit: workspace_status: a stale pin is invisible before reconcile runs" {
    var s: Status = .{};
    s.set(.{ .lane = .review }, .working);
    try testing.expect(s.showsGlyph(true, .working));
    // Inference moved; nothing reports the pin even though it is still stored.
    try testing.expect(s.override != null);
    try testing.expect(!s.showsGlyph(true, .todo));
    try testing.expectEqual(@as(?Override, null), s.payload(.todo).override);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeAutoLabel(&w, s, .todo);
    try testing.expectEqualStrings("Auto \u{2014} todo", w.buffered());
    // A pin naming the inferred lane itself still holds until inference moves.
    var same: Status = .{};
    same.set(.{ .lane = .working }, .working);
    try testing.expect(!same.reconcile(.working));
    try testing.expect(same.showsGlyph(true, .working));
    try testing.expect(same.reconcile(.review));
    // reconcile without a pin is a no-op.
    var plain: Status = .{};
    try testing.expect(!plain.reconcile(.done));
    try testing.expectEqual(Status{}, plain);
}

test "unit: workspace_status: cycle and set on a hidden workspace show it again" {
    var s: Status = .new_workspace;
    try testing.expectEqual(Lane.working, s.cycle(.todo));
    try testing.expect(!s.hidden);
    try testing.expect(s.showsGlyph(true, .todo));
    // none keeps the pin; auto after none clears both.
    s.set(.none, .todo);
    try testing.expectEqual(Lane.working, s.effective(.todo));
    s.set(.none, .todo);
    try testing.expect(s.hidden);
    s.set(.auto, .todo);
    try testing.expectEqual(Status{}, s);
}

test "unit: workspace_status: done edge fires once per transition" {
    var e: DoneEdge = .{};
    try testing.expect(!e.observe(.todo));
    try testing.expect(e.observe(.done));
    try testing.expect(!e.observe(.done));
    try testing.expect(!e.observe(.review));
    try testing.expect(e.observe(.done));
    // Restored workspaces already done start armed-off.
    var restored: DoneEdge = .{ .done = true };
    try testing.expect(!restored.observe(.done));
}
