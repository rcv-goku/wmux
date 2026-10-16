//! Palette modes and query parsing (ADR-8.8 / W2-7).
//!
//! cmux semantics: `commandPalette` opens with the query ">" (the commands
//! scope); deleting the ">" switches to the workspace switcher; typing ">"
//! in the switcher switches back. `goToWorkspace` opens the switcher with an
//! empty query. Besides the two search scopes the palette hosts Find Work
//! and the rename / description editors, each with its own placeholder, empty
//! state and hint text.
//!
//! User-visible strings are returned as `Text{key, default}` so the UI can pass
//! them to `ui/strings.zig: tr(key, default)` (§15.4).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const commands_prefix: u8 = '>';

/// Number of rows rendered synchronously on open (cmux: top 20 preview rows).
pub const preview_rows: usize = 20;

pub const Scope = enum { commands, switcher };

pub const Parsed = struct {
    scope: Scope,
    /// Search text with the prefix and surrounding whitespace removed; a
    /// slice of the input.
    text: []const u8,

    pub fn isEmpty(self: Parsed) bool {
        return self.text.len == 0;
    }
};

/// Splits a raw palette query into scope and search text. Leading whitespace
/// before ">" is tolerated; only the first ">" is the prefix, so ">>x"
/// searches the commands for ">x".
pub fn parse(raw: []const u8) Parsed {
    const lead = std.mem.trimLeft(u8, raw, &std.ascii.whitespace);
    if (lead.len > 0 and lead[0] == commands_prefix) {
        return .{ .scope = .commands, .text = std.mem.trim(u8, lead[1..], &std.ascii.whitespace) };
    }
    return .{ .scope = .switcher, .text = std.mem.trim(u8, raw, &std.ascii.whitespace) };
}

pub const OpenRequest = enum {
    /// `commandPalette` (Ctrl+Shift+P).
    command_palette,
    /// `goToWorkspace` (Ctrl+Shift+Alt+P).
    go_to_workspace,
};

pub fn initialQuery(req: OpenRequest) []const u8 {
    return switch (req) {
        .command_palette => ">",
        .go_to_workspace => "",
    };
}

pub const RenameTarget = enum { tab, workspace, workspace_group };

pub const Mode = union(enum) {
    commands,
    /// `all_surfaces` mirrors `app.commandPaletteSearchesAllSurfaces`.
    switcher: struct { all_surfaces: bool = false },
    find_work,
    rename_input: RenameTarget,
    rename_confirm: RenameTarget,
    workspace_description_input,

    /// The search mode for a typed query; editor modes are not reachable by
    /// typing.
    pub fn fromQuery(raw: []const u8, all_surfaces: bool) Mode {
        return switch (parse(raw).scope) {
            .commands => .commands,
            .switcher => .{ .switcher = .{ .all_surfaces = all_surfaces } },
        };
    }

    /// Whether typing filters a result list (false for the editors).
    pub fn isSearch(self: Mode) bool {
        return switch (self) {
            .commands, .switcher, .find_work => true,
            else => false,
        };
    }

    /// Whether the editor is multi-line (the description editor).
    pub fn isMultiline(self: Mode) bool {
        return self == .workspace_description_input;
    }
};

pub const Text = struct {
    key: []const u8,
    default: []const u8,
};

fn t(comptime key: []const u8, comptime default: []const u8) Text {
    return .{ .key = "palette." ++ key, .default = default };
}

pub fn placeholder(mode: Mode) Text {
    return switch (mode) {
        .commands => t("placeholder.commands", "Type a command"),
        .switcher => |s| if (s.all_surfaces)
            t("placeholder.switcherAll", "Search workspaces and surfaces")
        else
            t("placeholder.switcher", "Search workspaces"),
        .find_work => t("placeholder.findWork", "Find current work"),
        .rename_input, .rename_confirm, .workspace_description_input => hint(mode),
    };
}

/// Empty-result text for search modes; null for editor modes.
pub fn emptyText(mode: Mode) ?Text {
    return switch (mode) {
        .commands => t("empty.commands", "No commands match your search."),
        .switcher => |s| if (s.all_surfaces)
            t("empty.switcherAll", "No workspaces or surfaces match your search.")
        else
            t("empty.switcher", "No workspaces match your search."),
        .find_work => t("empty.findWork", "No work in this snapshot matches your search."),
        else => null,
    };
}

/// Hint line shown under the editor field.
pub fn hint(mode: Mode) Text {
    return switch (mode) {
        .rename_input => |target| switch (target) {
            .tab => t("rename.tab.input", "Enter a tab name. Press Enter to rename, Escape to cancel."),
            .workspace => t("rename.workspace.input", "Enter a workspace name. Press Enter to rename, Escape to cancel."),
            .workspace_group => t("rename.group.input", "Enter a workspace group name. Press Enter to rename, Escape to cancel."),
        },
        .rename_confirm => |target| switch (target) {
            .tab => t("rename.tab.confirm", "Press Enter to apply this tab name, or Escape to cancel."),
            .workspace => t("rename.workspace.confirm", "Press Enter to apply this workspace name, or Escape to cancel."),
            .workspace_group => t("rename.group.confirm", "Press Enter to apply this workspace group name, or Escape to cancel."),
        },
        .workspace_description_input => t("description.input", "Enter a workspace description. Press Enter to save, Escape to cancel."),
        else => placeholder(mode),
    };
}

/// What the confirm step shows for a proposed name: the trimmed name, or
/// "(clear custom name)" when it is empty (applying clears the custom name).
pub fn confirmDisplayName(proposed: []const u8) union(enum) { name: []const u8, clear: Text } {
    const trimmed = std.mem.trim(u8, proposed, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .clear = t("rename.clear", "(clear custom name)") };
    return .{ .name = trimmed };
}

/// Find Work truncation line: "Showing <shown> of <total> items". Caller owns.
pub fn showingText(gpa: Allocator, shown: usize, total: usize) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "Showing {d} of {d} items", .{ shown, total });
}

pub const outside_snapshot_text = t("findWork.outside", "Additional work is outside this snapshot.");

const testing = std.testing;

test "unit: palette: modes '>' selects the commands scope" {
    const p = parse(">split right");
    try testing.expectEqual(Scope.commands, p.scope);
    try testing.expectEqualStrings("split right", p.text);
    const q = parse(">");
    try testing.expectEqual(Scope.commands, q.scope);
    try testing.expect(q.isEmpty());
    const r = parse("  >  new  ");
    try testing.expectEqual(Scope.commands, r.scope);
    try testing.expectEqualStrings("new", r.text);
    const s = parse(">>x");
    try testing.expectEqualStrings(">x", s.text);
}

test "unit: palette: modes deleting '>' switches to the switcher" {
    const p = parse("");
    try testing.expectEqual(Scope.switcher, p.scope);
    try testing.expect(p.isEmpty());
    const q = parse("  feature/login ");
    try testing.expectEqual(Scope.switcher, q.scope);
    try testing.expectEqualStrings("feature/login", q.text);
    // A '>' that is not leading is literal search text.
    const r = parse("a>b");
    try testing.expectEqual(Scope.switcher, r.scope);
    try testing.expectEqualStrings("a>b", r.text);
    // Unicode is passed through untouched.
    try testing.expectEqualStrings("🚀 déploy", parse(">🚀 déploy").text);
}

test "unit: palette: modes open requests pick the initial query" {
    try testing.expectEqual(Scope.commands, parse(initialQuery(.command_palette)).scope);
    try testing.expectEqual(Scope.switcher, parse(initialQuery(.go_to_workspace)).scope);
    try testing.expectEqual(Mode.commands, Mode.fromQuery(">", false));
    try testing.expect(Mode.fromQuery("", true).switcher.all_surfaces);
    try testing.expect(!Mode.fromQuery("x", false).switcher.all_surfaces);
}

test "unit: palette: modes placeholders and empty states follow cmux" {
    try testing.expectEqualStrings("Type a command", placeholder(.commands).default);
    try testing.expectEqualStrings("Search workspaces", placeholder(.{ .switcher = .{} }).default);
    try testing.expectEqualStrings("Search workspaces and surfaces", placeholder(.{ .switcher = .{ .all_surfaces = true } }).default);
    try testing.expectEqualStrings("No commands match your search.", emptyText(.commands).?.default);
    try testing.expectEqualStrings("No workspaces match your search.", emptyText(.{ .switcher = .{} }).?.default);
    try testing.expectEqualStrings("No workspaces or surfaces match your search.", emptyText(.{ .switcher = .{ .all_surfaces = true } }).?.default);
    try testing.expectEqualStrings("Find current work", placeholder(.find_work).default);
    try testing.expectEqualStrings("No work in this snapshot matches your search.", emptyText(.find_work).?.default);
    try testing.expect(emptyText(.{ .rename_input = .tab }) == null);
    try testing.expectEqualStrings("palette.placeholder.commands", placeholder(.commands).key);
}

test "unit: palette: modes rename hints per phase and target" {
    try testing.expectEqualStrings("Enter a tab name. Press Enter to rename, Escape to cancel.", hint(.{ .rename_input = .tab }).default);
    try testing.expectEqualStrings("Press Enter to apply this tab name, or Escape to cancel.", hint(.{ .rename_confirm = .tab }).default);
    try testing.expectEqualStrings("Enter a workspace name. Press Enter to rename, Escape to cancel.", hint(.{ .rename_input = .workspace }).default);
    try testing.expectEqualStrings("Press Enter to apply this workspace name, or Escape to cancel.", hint(.{ .rename_confirm = .workspace }).default);
    try testing.expectEqualStrings("Press Enter to apply this workspace group name, or Escape to cancel.", hint(.{ .rename_confirm = .workspace_group }).default);
    try testing.expect(Mode.isMultiline(.workspace_description_input));
    try testing.expect(!Mode.isSearch(.workspace_description_input));
    try testing.expect(Mode.isSearch(.find_work));
    try testing.expectEqualStrings("Type a command", hint(.commands).default);
}

test "unit: palette: modes empty proposed name clears the custom name" {
    try testing.expectEqualStrings("(clear custom name)", confirmDisplayName("").clear.default);
    try testing.expectEqualStrings("(clear custom name)", confirmDisplayName(" \t ").clear.default);
    try testing.expectEqualStrings("api", confirmDisplayName("  api ").name);
}

test "unit: palette: modes find work truncation text" {
    const s = try showingText(testing.allocator, 100, 250);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Showing 100 of 250 items", s);
    try testing.expectEqualStrings("Additional work is outside this snapshot.", outside_snapshot_text.default);
}
