//! A workspace (a sidebar row, cmux "workspace"): one split tree of Panes,
//! the focused pane, its name, description and spawn directory, and the
//! sidebar metadata cache. Moved out of Window.zig in W0-A2
//! (ARCHITECTURE.md ADR-1.8); ui/Window.zig keeps the window's list of
//! workspaces.
//!
//! A workspace owns a single SplitTree of Panes. Each
//! Pane is a leaf in the tree and manages its own set of tabs.
//! Splits create new Panes; tabs live within a single
//! Pane. The workspace tracks which container is focused
//! (receives keyboard input and tab operations).
const Workspace = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pane = @import("Pane.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("Tab.zig");

const MAX_STATUS_BYTES = Pane.MAX_STATUS_BYTES;
const TabStatus = Tab.TabStatus;

/// Maximum bytes of a workspace's cached git branch name (Stage 2 sidebar
/// metadata). Inline so the async refresh result never allocates on apply;
/// over-long branch names are byte truncated.
pub const MAX_BRANCH_BYTES: usize = 64;

/// Maximum number of distinct listening TCP ports cached per workspace for
/// the sidebar metadata line. The walker dedups and caps at this; extra
/// ports are dropped (the row only has room for a few anyway).
pub const MAX_PORTS: usize = 8;

/// PR review/merge state cached per workspace from `gh pr view`. `none`
/// covers "no gh / not authed / no PR for the branch"; the sidebar only
/// renders a marker for the non-none states.
pub const PrState = enum { none, open, draft, merged, closed };

/// The workspace's split tree whose leaves are Panes.
split_tree: SplitTree(Pane) = .empty,
/// The currently focused Pane (receives keyboard input, tab operations).
focused_container: ?*Pane = null,
/// Workspace name shown on its sidebar row.
name: [64]u16 = undefined,
/// Length of the workspace name in UTF-16 code units.
name_len: u16 = 0,
/// Optional workspace description shown below the name in the sidebar.
/// UTF-16, inline like name (no allocation). Edited via the
/// edit_workspace_description action or the IPC workspace-set-description
/// command.
description: [256]u16 = undefined,
/// Length of the workspace description in UTF-16 code units.
description_len: u16 = 0,
/// Optional working directory this workspace's tabs spawn in (a git
/// worktree bound via `+workspace new --worktree`). Owned heap copy,
/// allocated by setWorkingDir and freed by freeWorkingDir. Null = the
/// configured default (the inherited/home cwd, current behavior). The
/// path is only consumed when a tab's surface config clone is built
/// (addTabWithCommand), so it is moved verbatim through workspace-slot
/// shifts (closeWorkspace) without re-validation.
working_dir: ?[]const u8 = null,

// --- Stage 2 orchestration metadata (sidebar second line) ----------
// All best-effort, populated off the UI thread (git/gh/TCP table) and
// applied via setMetadata; null/empty when unknown or not yet
// refreshed. Inline fixed buffers (like name/status_text) so the async
// apply never allocates and the values move verbatim through
// workspace-slot shifts (closeWorkspace) exactly like name/working_dir.

/// Cached git branch of working_dir (rev-parse --abbrev-ref HEAD).
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
/// thread applies a result only if the token still matches, so a result
/// for a since-recycled slot (closeWorkspace shifted a different
/// workspace into this index) is dropped instead of mis-applied. Bumped
/// by markMetadataDirty on dispatch.
meta_token: u64 = 0,

/// The number of leaf Panes in the workspace's split tree.
pub fn containerCount(self: *const Workspace) usize {
    var count: usize = 0;
    var it = self.split_tree.iterator();
    while (it.next()) |_| {
        count += 1;
    }
    return count;
}

/// The focused container, falling back to the first leaf in the tree.
pub fn focusedContainerOrFirst(self: *Workspace) ?*Pane {
    if (self.focused_container) |fc| return fc;
    var it = self.split_tree.iterator();
    if (it.next()) |entry| return entry.view;
    return null;
}

/// Find which Pane owns a given pane by scanning all
/// containers' tab arrays.
pub fn findContainerOf(self: *Workspace, pane: *Tab) ?*Pane {
    var it = self.split_tree.iterator();
    while (it.next()) |entry| {
        const container = entry.view;
        for (container.tabs[0..container.tab_count]) |tab_pane| {
            if (tab_pane == pane) return container;
        }
    }
    return null;
}

/// Find the split tree node handle for a given Pane.
pub fn findContainerHandle(self: *Workspace, container: *Pane) ?SplitTree(Pane).Node.Handle {
    var it = self.split_tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.eql(container)) return entry.handle;
    }
    return null;
}

/// Return the Nth leaf Pane (0-based) by iterating the
/// split tree. Used by IPC `--pane` arguments to address a specific
/// container by positional index.
pub fn containerAtIndex(self: *Workspace, idx: usize) ?*Pane {
    var it = self.split_tree.iterator();
    var n: usize = 0;
    while (it.next()) |entry| {
        if (n == idx) return entry.view;
        n += 1;
    }
    return null;
}

/// The worst status across all Panes in this workspace,
/// for the sidebar dot: exited > bell > normal.
pub fn aggregateStatus(self: *const Workspace) TabStatus {
    var worst: TabStatus = .normal;
    var it = self.split_tree.iterator();
    while (it.next()) |entry| {
        switch (entry.view.aggregateStatus()) {
            .exited => return .exited,
            .bell => worst = .bell,
            .normal => {},
        }
    }
    return worst;
}

/// Whether any Pane in this workspace has a tab flagged
/// for attention.
pub fn hasAttention(self: *const Workspace) bool {
    var it = self.split_tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.hasAttention()) return true;
    }
    return false;
}

/// The workspace description as a UTF-16 slice (empty when unset).
pub fn descriptionSlice(self: *const Workspace) []const u16 {
    return self.description[0..self.description_len];
}

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

/// Reset Stage 2 metadata to its unknown state. Called when a tab is
/// inserted into a fresh workspace and when a workspace slot is reused,
/// so a recycled row never shows the previous occupant's branch/ports.
pub fn resetMetadata(self: *Workspace) void {
    self.git_branch_len = 0;
    self.port_count = 0;
    self.pr_state = .none;
    self.pr_number = 0;
}

/// True when this workspace has any metadata worth a second sidebar
/// line: a git branch, a listening port, a PR, or an agent status. Used
/// to decide whether to render the taller two-line row.
pub fn hasMetadata(self: *const Workspace) bool {
    if (self.description_len > 0) return true;
    if (self.git_branch_len > 0) return true;
    if (self.port_count > 0) return true;
    if (self.pr_state != .none) return true;
    if (self.firstStatusText().len > 0) return true;
    return false;
}

/// Status text for the sidebar metadata line. Prioritizes the focused
/// container's active tab (most relevant to the user), then falls back
/// to the first non-empty status text across all containers.
pub fn firstStatusText(self: *const Workspace) []const u8 {
    if (self.focused_container) |fc| {
        if (fc.active_tab < fc.tab_count and fc.tab_status_text_len[fc.active_tab] > 0) {
            return fc.tab_status_text[fc.active_tab][0..fc.tab_status_text_len[fc.active_tab]];
        }
    }
    var it = self.split_tree.iterator();
    while (it.next()) |entry| {
        const c = entry.view;
        for (0..c.tab_count) |t| {
            if (c.tab_status_text_len[t] > 0) {
                return c.tab_status_text[t][0..c.tab_status_text_len[t]];
            }
        }
    }
    // focused_container may not be in the split tree (transient state
    // during init or in unit tests). Check its non-active tabs.
    if (self.focused_container) |fc| {
        for (0..fc.tab_count) |t| {
            if (fc.tab_status_text_len[t] > 0) {
                return fc.tab_status_text[t][0..fc.tab_status_text_len[t]];
            }
        }
    }
    return "";
}

/// Get status text for tab `idx` of the focused container.
pub fn tabStatusText(self: *const Workspace, idx: usize) []const u8 {
    const c = @constCast(self).focusedContainerOrFirst() orelse return "";
    if (idx >= c.tab_count) return "";
    const slen = c.tab_status_text_len[idx];
    if (slen == 0) return "";
    return c.tab_status_text[idx][0..slen];
}

/// Set status text for tab `idx` of the focused container.
pub fn setTabStatusText(self: *Workspace, idx: usize, text: []const u8) void {
    const c = self.focusedContainerOrFirst() orelse return;
    if (idx >= c.tab_count) return;
    const n: u16 = @intCast(@min(text.len, MAX_STATUS_BYTES));
    @memcpy(c.tab_status_text[idx][0..n], text[0..n]);
    c.tab_status_text_len[idx] = n;
}

/// Bind (or replace) this workspace's spawn working directory with an
/// owned heap copy of `path`. Frees any previous binding first.
pub fn setWorkingDir(self: *Workspace, alloc: Allocator, path: []const u8) Allocator.Error!void {
    const copy = try alloc.dupe(u8, path);
    if (self.working_dir) |old| alloc.free(old);
    self.working_dir = copy;
}

/// Release this workspace's working_dir binding, if any. Idempotent.
/// Must be called exactly once per workspace whose slot is going away
/// (window/workspace teardown), never on a slot whose value was moved
/// into another live slot (closeWorkspace's shift).
pub fn freeWorkingDir(self: *Workspace, alloc: Allocator) void {
    if (self.working_dir) |dir| {
        alloc.free(dir);
        self.working_dir = null;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: containerAtIndex empty workspace returns null" {
    var ws: Workspace = .{};
    try testing.expectEqual(@as(?*Pane, null), ws.containerAtIndex(0));
    try testing.expectEqual(@as(?*Pane, null), ws.containerAtIndex(1));
}

test "unit: workspace status text via focused container" {
    var pc: Pane = .{};
    pc.tab_count = 2;
    var ws: Workspace = .{};
    ws.focused_container = &pc;

    try testing.expectEqualStrings("", ws.tabStatusText(0));

    ws.setTabStatusText(0, "running tests");
    try testing.expectEqualStrings("running tests", ws.tabStatusText(0));
    try testing.expectEqualStrings("", ws.tabStatusText(1));
    ws.setTabStatusText(0, "");
    try testing.expectEqualStrings("", ws.tabStatusText(0));
}

test "unit: firstStatusText prioritises focused container active tab" {
    var pc: Pane = .{};
    pc.tab_count = 2;
    var ws: Workspace = .{};
    ws.focused_container = &pc;

    // No status set → empty.
    try testing.expectEqualStrings("", ws.firstStatusText());

    // Status on non-active tab (tab 1) → falls back to scanning.
    const msg = "building";
    @memcpy(pc.tab_status_text[1][0..msg.len], msg);
    pc.tab_status_text_len[1] = msg.len;
    try testing.expectEqualStrings("building", ws.firstStatusText());

    // Status on active tab (tab 0) takes priority.
    const msg2 = "testing";
    @memcpy(pc.tab_status_text[0][0..msg2.len], msg2);
    pc.tab_status_text_len[0] = msg2.len;
    try testing.expectEqualStrings("testing", ws.firstStatusText());

    // Clear active tab → falls back to tab 1.
    pc.tab_status_text_len[0] = 0;
    try testing.expectEqualStrings("building", ws.firstStatusText());
}

test "unit: workspace metadata setters store and report hasMetadata" {
    var ws: Workspace = .{};

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
    var pc: Pane = .{};
    pc.tab_count = 1;
    ws.focused_container = &pc;
    ws.setTabStatusText(0, "waiting");
    try testing.expect(ws.hasMetadata());
}

test "unit: branch over-long byte truncation never overruns the buffer" {
    var ws: Workspace = .{};
    var long: [MAX_BRANCH_BYTES + 10]u8 = undefined;
    @memset(&long, 'a');
    ws.setGitBranch(&long);
    try testing.expectEqual(MAX_BRANCH_BYTES, ws.gitBranch().len);
}
