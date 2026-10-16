//! A workspace (a sidebar row, cmux "workspace"; ARCHITECTURE.md §0.2,
//! ADR-2.3): one split tree of Panes, the focused and zoomed pane, the
//! name (a Title), description, spawn directory and environment, and the
//! legacy sidebar metadata cache (git branch, ports, PR; W2-6 moves it into
//! the meta feature state). Workspaces are heap objects owned by their
//! window's `workspaces` list (ui/Window.zig), so a *Workspace stays valid
//! while workspaces are created, closed and reordered around it; there is
//! no workspace cap any more (G7).
const Workspace = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pane = @import("Pane.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("../Surface.zig");
const Tab = @import("Tab.zig");
const Title = @import("Title.zig");
const Window = @import("../ui/Window.zig");
const features_ext = @import("../features/ext.zig");
const titles = @import("logic/titles.zig");

const TabStatus = Tab.TabStatus;

/// Maximum bytes of a workspace's cached git branch name (Stage 2 sidebar
/// metadata). Inline so the async refresh result never allocates on apply;
/// over-long branch names are byte truncated.
pub const MAX_BRANCH_BYTES: usize = 64;

/// Maximum number of distinct listening TCP ports cached per workspace for
/// the sidebar metadata line. The walker dedups and caps at this; extra
/// ports are dropped (the row only has room for a few anyway).
pub const MAX_PORTS: usize = 8;

/// Display cap of a workspace name, in UTF-16 code units (the sidebar row
/// and the rename field were sized for it before W0-A2).
pub const NAME_MAX_UNITS: usize = 64;

/// Display cap of a workspace description, in UTF-16 code units.
pub const DESCRIPTION_MAX_UNITS: usize = 256;

/// PR review/merge state cached per workspace from `gh pr view`. `none`
/// covers "no gh / not authed / no PR for the branch"; the sidebar only
/// renders a marker for the non-none states.
pub const PrState = enum { none, open, draft, merged, closed };

/// The window whose `workspaces` list owns this workspace.
window: *Window,

/// The sidebar row name: a user rename is `title.custom`; an unnamed
/// workspace shows "Workspace N".
title: Title = .{},

/// Optional description shown below the name in the sidebar (owned UTF-8,
/// never empty: clearing it stores null). Edited via the
/// edit_workspace_description action or the IPC workspace-set-description
/// command.
description: ?[]u8 = null,

/// Optional working directory this workspace's tabs spawn in (a git
/// worktree bound via `+workspace new --worktree`). Owned heap copy. Null
/// = the configured default (the inherited/home cwd).
cwd: ?[]u8 = null,

/// Extra environment for the workspace's new terminals (ADR-2.3; filled
/// by W2-1). Keys and values are owned.
env: std.StringArrayHashMapUnmanaged([]u8) = .empty,

/// The workspace's split tree whose leaves are Panes.
tree: SplitTree(Pane) = .empty,

/// The focused pane (receives keyboard input and tab operations).
focused_pane: ?*Pane = null,

/// The zoomed pane, derived from `tree.zoomed` (syncZoomed).
zoomed_pane: ?*Pane = null,

/// Pinned workspaces sort first in the sidebar (cmux pin; no behavior
/// yet).
pinned: bool = false,

/// Per-workspace feature state (ADR-1.3).
ext: features_ext.WorkspaceExt = .{},

// --- Stage 2 orchestration metadata (sidebar second line) ----------
// All best-effort, populated off the UI thread (git/gh/TCP table) and
// applied through the setters below; empty when unknown or not yet
// refreshed. Inline fixed buffers so the async apply never allocates.

/// Cached git branch of cwd (rev-parse --abbrev-ref HEAD).
/// Empty (len 0) = unknown / not a worktree workspace.
git_branch: [MAX_BRANCH_BYTES]u8 = undefined,
git_branch_len: u8 = 0,
/// Cached listening TCP ports of this workspace's tabs' child process
/// trees, sorted ascending and deduped. ports[0..port_count] are live.
ports: [MAX_PORTS]u16 = undefined,
port_count: u8 = 0,
/// Cached PR state + number for the branch (gh pr view), best-effort.
pr_state: PrState = .none,
pr_number: u32 = 0,
/// Monotonic token stamped when an async metadata refresh job is
/// dispatched for this workspace and echoed back in the result. The UI
/// thread applies a result only if the workspace still bears the token,
/// so a stale result (a newer refresh was dispatched since) is dropped.
meta_token: u64 = 0,

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

/// Heap-allocate an empty workspace owned by `window`.
pub fn create(gpa: Allocator, window: *Window) Allocator.Error!*Workspace {
    const ws = try gpa.create(Workspace);
    ws.* = .{ .window = window };
    return ws;
}

/// Tear the workspace down: its split tree (which unrefs every pane and
/// so every tab), its strings and environment, then the object itself.
pub fn destroy(self: *Workspace, gpa: Allocator) void {
    self.tree.deinit();
    self.title.deinit(gpa);
    if (self.description) |d| gpa.free(d);
    if (self.cwd) |c| gpa.free(c);
    var it = self.env.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    self.env.deinit(gpa);
    gpa.destroy(self);
}

// ---------------------------------------------------------------------------
// Panes
// ---------------------------------------------------------------------------

/// A located tab: the workspace and pane that own it, plus the tab's
/// index within that pane (Window.findLoc / findLocOfSurface).
pub const Loc = struct {
    ws: *Workspace,
    pane: *Pane,
    index: usize,
};

/// Find `tab` among the panes of `workspaces`, in order.
pub fn locate(workspaces: []const *Workspace, tab: *const Tab) ?Loc {
    for (workspaces) |ws| {
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            const pane = entry.view;
            if (pane.indexOf(tab)) |i| return .{ .ws = ws, .pane = pane, .index = i };
        }
    }
    return null;
}

/// Find the tab holding the terminal `surface` among the panes of
/// `workspaces`. Compares addresses only and never dereferences
/// `surface`, so callers can validate a possibly dangling pointer.
pub fn locateSurface(workspaces: []const *Workspace, surface: *const Surface) ?Loc {
    for (workspaces) |ws| {
        var it = ws.tree.iterator();
        while (it.next()) |entry| {
            const pane = entry.view;
            for (pane.tabs.items, 0..) |t, i| {
                if (t.surface() == surface) return .{ .ws = ws, .pane = pane, .index = i };
            }
        }
    }
    return null;
}

/// The number of leaf Panes in the workspace's split tree.
pub fn paneCount(self: *const Workspace) usize {
    var count: usize = 0;
    var it = self.tree.iterator();
    while (it.next()) |_| {
        count += 1;
    }
    return count;
}

/// The focused pane, falling back to the first leaf in the tree.
pub fn focusedPaneOrFirst(self: *const Workspace) ?*Pane {
    if (self.focused_pane) |fp| return fp;
    var it = self.tree.iterator();
    if (it.next()) |entry| return entry.view;
    return null;
}

/// Find which Pane owns a given tab by scanning every pane's tabs.
pub fn findPaneOfTab(self: *const Workspace, tab: *const Tab) ?*Pane {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.indexOf(tab) != null) return entry.view;
    }
    return null;
}

/// Find the split tree node handle of a given Pane.
pub fn paneHandle(self: *const Workspace, pane: *const Pane) ?SplitTree(Pane).Node.Handle {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.eql(pane)) return entry.handle;
    }
    return null;
}

/// Return the Nth leaf Pane (0-based) in split-tree node order (the order
/// of SplitTree.iterator), the positional index IPC `--pane` arguments and
/// the v2 session file have always used. Node order is not the on-screen
/// depth-first order of model/layout.zig's leaves: SplitTree.split stores
/// the inserted pane before the original it moves, so after splitting a
/// lone pane to the right the new pane is index 0. (ADR-2.4 defines the v2
/// pane index as depth-first; the legacy index keeps this order until W2-2
/// maps it.)
pub fn paneAt(self: *const Workspace, idx: usize) ?*Pane {
    var it = self.tree.iterator();
    var n: usize = 0;
    while (it.next()) |entry| {
        if (n == idx) return entry.view;
        n += 1;
    }
    return null;
}

/// Re-derive `zoomed_pane` from the tree's zoomed node.
pub fn syncZoomed(self: *Workspace) void {
    self.zoomed_pane = null;
    const handle = self.tree.zoomed orelse return;
    if (handle.idx() >= self.tree.nodes.len) return;
    switch (self.tree.nodes[handle.idx()]) {
        .leaf => |pane| self.zoomed_pane = pane,
        .split => {},
    }
}

/// The worst status across all Panes in this workspace,
/// for the sidebar dot: exited > bell > normal.
pub fn aggregateStatus(self: *const Workspace) TabStatus {
    var worst: TabStatus = .normal;
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        switch (entry.view.aggregateStatus()) {
            .exited => return .exited,
            .bell => worst = .bell,
            .normal => {},
        }
    }
    return worst;
}

/// Whether any Pane in this workspace has a tab flagged for attention.
pub fn hasAttention(self: *const Workspace) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.hasAttention()) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Name, description and spawn directory
// ---------------------------------------------------------------------------

/// The workspace name (null when unnamed).
pub fn name(self: *const Workspace) ?[]const u8 {
    return self.title.text();
}

/// Set the name from UTF-8 (IPC, session restore): capped at
/// NAME_MAX_UNITS bytes on a code-point boundary (so at most that many
/// UTF-16 units); an empty name clears it (unnamed). Invalid UTF-8 leaves
/// the name unchanged.
pub fn setNameUtf8(self: *Workspace, gpa: Allocator, value: []const u8) Allocator.Error!void {
    const capped = titles.capUtf8(value, NAME_MAX_UNITS);
    if (!std.unicode.utf8ValidateSlice(capped)) return;
    if (capped.len == 0) return self.title.clearCustom(gpa);
    try self.title.setCustom(gpa, capped);
}

/// Set the name from the inline rename field (UTF-16, may hold unpaired
/// surrogates), keeping at most NAME_MAX_UNITS units. Empty is ignored
/// (a blank rename keeps the old name).
pub fn setNameUtf16(self: *Workspace, gpa: Allocator, units: []const u16) Allocator.Error!void {
    if (units.len == 0) return;
    const text = try std.unicode.wtf16LeToWtf8Alloc(gpa, units[0..@min(units.len, NAME_MAX_UNITS)]);
    defer gpa.free(text);
    try self.title.setCustom(gpa, text);
}

/// The description (empty when unset).
pub fn descriptionText(self: *const Workspace) []const u8 {
    return self.description orelse "";
}

/// Replace the description with an owned copy of `text` (empty clears).
fn storeDescription(self: *Workspace, gpa: Allocator, text: []const u8) Allocator.Error!void {
    const copy: ?[]u8 = if (text.len == 0) null else try gpa.dupe(u8, text);
    if (self.description) |old| gpa.free(old);
    self.description = copy;
}

/// Set the description from UTF-8 (IPC): capped at DESCRIPTION_MAX_UNITS
/// bytes on a code-point boundary; empty clears it. Invalid UTF-8 leaves
/// the description unchanged.
pub fn setDescriptionUtf8(self: *Workspace, gpa: Allocator, text: []const u8) Allocator.Error!void {
    const capped = titles.capUtf8(text, DESCRIPTION_MAX_UNITS);
    if (!std.unicode.utf8ValidateSlice(capped)) return;
    try self.storeDescription(gpa, capped);
}

/// Set the description from the inline rename field (UTF-16), keeping at
/// most DESCRIPTION_MAX_UNITS units; empty clears it.
pub fn setDescriptionUtf16(self: *Workspace, gpa: Allocator, units: []const u16) Allocator.Error!void {
    const text = try std.unicode.wtf16LeToWtf8Alloc(gpa, units[0..@min(units.len, DESCRIPTION_MAX_UNITS)]);
    defer gpa.free(text);
    try self.storeDescription(gpa, text);
}

/// Bind (or replace) this workspace's spawn working directory with an
/// owned heap copy of `path`. Frees any previous binding first.
pub fn setCwd(self: *Workspace, gpa: Allocator, path: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, path);
    if (self.cwd) |old| gpa.free(old);
    self.cwd = copy;
}

/// Release this workspace's cwd binding, if any. Idempotent.
pub fn freeCwd(self: *Workspace, gpa: Allocator) void {
    if (self.cwd) |dir| {
        gpa.free(dir);
        self.cwd = null;
    }
}

// ---------------------------------------------------------------------------
// Sidebar metadata
// ---------------------------------------------------------------------------

/// The cached git branch (empty when unknown). Stage 2 metadata.
pub fn gitBranch(self: *const Workspace) []const u8 {
    return self.git_branch[0..self.git_branch_len];
}

/// Store the cached git branch, UTF-8 byte-truncated to the buffer.
/// Empty `branch` clears it. No allocation.
pub fn setGitBranch(self: *Workspace, branch: []const u8) void {
    const n: u8 = @intCast(@min(branch.len, MAX_BRANCH_BYTES));
    @memcpy(self.git_branch[0..n], branch[0..n]);
    self.git_branch_len = n;
}

/// The cached listening ports (ascending, deduped). Stage 2 metadata.
pub fn portsSlice(self: *const Workspace) []const u16 {
    return self.ports[0..self.port_count];
}

/// Store the cached listening ports, capped at MAX_PORTS. `src` is
/// expected sorted+deduped by the caller (the off-thread walker).
pub fn setPorts(self: *Workspace, src: []const u16) void {
    const n: u8 = @intCast(@min(src.len, MAX_PORTS));
    @memcpy(self.ports[0..n], src[0..n]);
    self.port_count = n;
}

/// Store the cached PR state + number.
pub fn setPrStatus(self: *Workspace, state: PrState, number: u32) void {
    self.pr_state = state;
    self.pr_number = number;
}

/// Reset Stage 2 metadata to its unknown state.
pub fn resetMetadata(self: *Workspace) void {
    self.git_branch_len = 0;
    self.port_count = 0;
    self.pr_state = .none;
    self.pr_number = 0;
}

/// True when this workspace has any metadata worth a second sidebar
/// line: a description, a git branch, a listening port, a PR, or a tab
/// status text. Used to decide whether to render the taller two-line row.
pub fn hasMetadata(self: *const Workspace) bool {
    if (self.description != null) return true;
    if (self.git_branch_len > 0) return true;
    if (self.port_count > 0) return true;
    if (self.pr_state != .none) return true;
    if (self.firstStatusText().len > 0) return true;
    return false;
}

/// Status text for the sidebar metadata line. Prioritizes the focused
/// pane's selected tab (most relevant to the user), then falls back to
/// the first non-empty status text across all panes.
pub fn firstStatusText(self: *const Workspace) []const u8 {
    if (self.focused_pane) |fp| {
        if (fp.selectedTab()) |tab| {
            if (tab.legacy.status_text_len > 0) return tab.legacy.statusText();
        }
    }
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        for (entry.view.tabs.items) |tab| {
            if (tab.legacy.status_text_len > 0) return tab.legacy.statusText();
        }
    }
    // focused_pane may not be in the split tree (transient state during
    // init or in unit tests). Check its non-selected tabs.
    if (self.focused_pane) |fp| {
        for (fp.tabs.items) |tab| {
            if (tab.legacy.status_text_len > 0) return tab.legacy.statusText();
        }
    }
    return "";
}

/// Get status text for tab `idx` of the focused pane.
pub fn tabStatusText(self: *const Workspace, idx: usize) []const u8 {
    const pane = self.focusedPaneOrFirst() orelse return "";
    const tab = pane.tabAt(idx) orelse return "";
    return tab.legacy.statusText();
}

/// Set status text for tab `idx` of the focused pane.
pub fn setTabStatusText(self: *Workspace, idx: usize, text: []const u8) void {
    const pane = self.focusedPaneOrFirst() orelse return;
    const tab = pane.tabAt(idx) orelse return;
    tab.legacy.setStatusText(text);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A pane over caller-owned placeholder tabs (read-only list).
fn testPane(tabs: []Tab, ptrs: []*Tab) Pane {
    for (tabs, 0..) |*t, i| ptrs[i] = t;
    return .{ .tabs = .{ .items = ptrs[0..tabs.len], .capacity = tabs.len } };
}

test "unit: model: paneAt of an empty workspace returns null" {
    const ws: Workspace = .{ .window = undefined };
    try testing.expectEqual(@as(?*Pane, null), ws.paneAt(0));
    try testing.expectEqual(@as(?*Pane, null), ws.paneAt(1));
    try testing.expectEqual(@as(usize, 0), ws.paneCount());
    try testing.expectEqual(@as(?*Pane, null), ws.focusedPaneOrFirst());
}

test "unit: model: workspace status text via the focused pane" {
    var tabs: [2]Tab = @splat(.{ .content = .placeholder });
    var ptrs: [2]*Tab = undefined;
    var pane = testPane(&tabs, &ptrs);
    var ws: Workspace = .{ .window = undefined };
    ws.focused_pane = &pane;

    try testing.expectEqualStrings("", ws.tabStatusText(0));

    ws.setTabStatusText(0, "running tests");
    try testing.expectEqualStrings("running tests", ws.tabStatusText(0));
    try testing.expectEqualStrings("", ws.tabStatusText(1));
    ws.setTabStatusText(0, "");
    try testing.expectEqualStrings("", ws.tabStatusText(0));
    // Out of range reads empty and writes nothing.
    ws.setTabStatusText(2, "nope");
    try testing.expectEqualStrings("", ws.tabStatusText(2));
}

test "unit: model: firstStatusText prefers the focused pane's selected tab" {
    var tabs: [2]Tab = @splat(.{ .content = .placeholder });
    var ptrs: [2]*Tab = undefined;
    var pane = testPane(&tabs, &ptrs);
    var ws: Workspace = .{ .window = undefined };
    ws.focused_pane = &pane;

    // No status set → empty.
    try testing.expectEqualStrings("", ws.firstStatusText());

    // Status on non-selected tab (tab 1) → falls back to scanning.
    tabs[1].legacy.setStatusText("building");
    try testing.expectEqualStrings("building", ws.firstStatusText());

    // Status on the selected tab (tab 0) takes priority.
    tabs[0].legacy.setStatusText("testing");
    try testing.expectEqualStrings("testing", ws.firstStatusText());

    // Clear the selected tab → falls back to tab 1.
    tabs[0].legacy.setStatusText("");
    try testing.expectEqualStrings("building", ws.firstStatusText());
}

test "unit: model: workspace metadata setters store and report hasMetadata" {
    var ws: Workspace = .{ .window = undefined };

    // Fresh workspace has no metadata.
    try testing.expect(!ws.hasMetadata());
    try testing.expectEqualStrings("", ws.gitBranch());
    try testing.expectEqual(@as(usize, 0), ws.portsSlice().len);
    try testing.expectEqual(PrState.none, ws.pr_state);

    // Branch round-trips and flips hasMetadata.
    ws.setGitBranch("feat/x");
    try testing.expectEqualStrings("feat/x", ws.gitBranch());
    try testing.expect(ws.hasMetadata());

    // Ports store sorted-as-given and dedup is the caller's job (setter
    // copies verbatim, capped at MAX_PORTS).
    ws.setPorts(&.{ 3000, 8080 });
    try testing.expectEqualSlices(u16, &.{ 3000, 8080 }, ws.portsSlice());

    // Over-cap input is truncated to MAX_PORTS.
    var many: [MAX_PORTS + 3]u16 = undefined;
    for (&many, 0..) |*p, i| p.* = @intCast(i);
    ws.setPorts(&many);
    try testing.expectEqual(MAX_PORTS, ws.portsSlice().len);

    // PR status.
    ws.setPrStatus(.draft, 42);
    try testing.expectEqual(PrState.draft, ws.pr_state);
    try testing.expectEqual(@as(u32, 42), ws.pr_number);

    // resetMetadata clears the lot back to unknown.
    ws.resetMetadata();
    try testing.expectEqualStrings("", ws.gitBranch());
    try testing.expectEqual(@as(usize, 0), ws.portsSlice().len);
    try testing.expectEqual(PrState.none, ws.pr_state);
    try testing.expect(!ws.hasMetadata());

    // A per-tab status alone also counts as metadata (the second-line
    // status segment).
    var tabs: [1]Tab = @splat(.{ .content = .placeholder });
    var ptrs: [1]*Tab = undefined;
    var pane = testPane(&tabs, &ptrs);
    ws.focused_pane = &pane;
    ws.setTabStatusText(0, "waiting");
    try testing.expect(ws.hasMetadata());
}

test "unit: model: an over-long git branch is byte truncated within the buffer" {
    var ws: Workspace = .{ .window = undefined };
    var long: [MAX_BRANCH_BYTES + 10]u8 = undefined;
    @memset(&long, 'a');
    ws.setGitBranch(&long);
    try testing.expectEqual(MAX_BRANCH_BYTES, ws.gitBranch().len);
}

test "unit: model: workspace name and description setters cap and clear" {
    const gpa = testing.allocator;
    var ws: Workspace = .{ .window = undefined };
    defer ws.title.deinit(gpa);
    defer if (ws.description) |d| gpa.free(d);

    try testing.expectEqual(@as(?[]const u8, null), ws.name());
    try ws.setNameUtf8(gpa, "api");
    try testing.expectEqualStrings("api", ws.name().?);
    // Over-long UTF-8 names are capped at NAME_MAX_UNITS bytes.
    var long: [NAME_MAX_UNITS + 9]u8 = undefined;
    @memset(&long, 'n');
    try ws.setNameUtf8(gpa, &long);
    try testing.expectEqual(NAME_MAX_UNITS, ws.name().?.len);
    // An empty UTF-8 name clears it; an empty rename keeps it.
    try ws.setNameUtf16(gpa, std.unicode.utf8ToUtf16LeStringLiteral("web"));
    try testing.expectEqualStrings("web", ws.name().?);
    try ws.setNameUtf16(gpa, &.{});
    try testing.expectEqualStrings("web", ws.name().?);
    try ws.setNameUtf8(gpa, "");
    try testing.expectEqual(@as(?[]const u8, null), ws.name());

    try testing.expect(!ws.hasMetadata());
    try ws.setDescriptionUtf8(gpa, "deploy box");
    try testing.expectEqualStrings("deploy box", ws.descriptionText());
    try testing.expect(ws.hasMetadata());
    try ws.setDescriptionUtf16(gpa, &.{});
    try testing.expectEqualStrings("", ws.descriptionText());
    try testing.expectEqual(@as(?[]u8, null), ws.description);
}
