//! Pure sidebar row model (ARCHITECTURE ADR-11.2 step 1, ADR-11.3).
//!
//! `build` turns a window's workspace list (plain data gathered on the UI
//! thread, plus the items feature contributors produced through
//! `RowBuilder`) into the ordered rows the sidebar shows: group headers and
//! workspace rows. A workspace row is a title line (leading badge/spinner,
//! pin, mute, media icons, status glyph, title, trailing badge/spinner,
//! close, shortcut hint) followed by detail items ordered by their
//! contributor's pre-assigned `Slot`.
//!
//! The model decides *what* is shown (visibility settings, pinned tier,
//! collapsed groups, "Show more" collapsing, compact agent status, title
//! disambiguation); `row_layout.zig` decides *where*. Every string in a
//! `Row` either borrows from the input or lives in the arena passed to
//! `build`, so one arena reset frees a whole model.
//!
//! std + wmux_proto only: runs in `zig build test-fast`.
const std = @import("std");
const proto = @import("wmux_proto");
const color = @import("../../gfx/logic/color.zig");

const Allocator = std.mem.Allocator;
pub const Uuid = proto.uuid.Uuid;
pub const Color = color.Color;

/// Byte cap (G6) for the texts the model derives or copies: titles, group
/// titles, markdown blocks, `RowBuilder.text` lines and tooltips. Longer
/// input is cut on a code-point boundary; DirectWrite trims visually long
/// before this. Slices passed to `line`/`lineEx`/`pills`/`chips` are
/// borrowed as is: they come from feature state, which is capped where it
/// is stored.
pub const max_text_bytes: usize = 8 * 1024;

/// Cap for the remote host in "title (host)" (hostnames are <= 253 bytes).
const max_host_bytes: usize = 255;

/// cmux's accent blue; a status color equal to it draws as the app accent.
pub const cmux_accent_hex: u24 = 0x4C8DFF;

/// Pre-assigned contributor order (ADR-11.3; values are binding).
pub const Slot = enum(u8) {
    description = 10,
    agent_status = 20,
    status_entries = 30,
    notification_preview = 40,
    progress = 50,
    log = 60,
    branch_dir = 70,
    pull_requests = 80,
    ports = 90,
    remote = 100,
    todo_summary = 110,
    custom_metadata = 120,
    loading = 130,

    pub const count = @typeInfo(Slot).@"enum".fields.len;

    /// Dense index (0..count) for per-slot tables.
    pub fn index(s: Slot) usize {
        return @as(usize, @intFromEnum(s)) / 10 - 1;
    }
};

/// Set of slots (e.g. the expanded "Show more" sections of one row).
pub const SlotSet = struct {
    bits: u16 = 0,

    pub fn has(self: SlotSet, s: Slot) bool {
        return self.bits & (@as(u16, 1) << @intCast(s.index())) != 0;
    }

    pub fn with(self: SlotSet, s: Slot) SlotSet {
        return .{ .bits = self.bits | (@as(u16, 1) << @intCast(s.index())) };
    }

    pub fn without(self: SlotSet, s: Slot) SlotSet {
        return .{ .bits = self.bits & ~(@as(u16, 1) << @intCast(s.index())) };
    }
};

/// Semantic text/fill tone; the painter maps tones to theme colors.
pub const Tone = enum(u8) {
    primary,
    secondary,
    accent,
    info,
    progress,
    success,
    warning,
    @"error",
    link,
    pr_open,
    pr_merged,
    pr_closed,
    pr_draft,
};

/// A color as requested by a contributor: a theme tone, an explicit sRGB
/// color, or the app accent (cmux's #4C8DFF sentinel).
pub const ColorSpec = union(enum) {
    tone: Tone,
    rgb: Color,
    accent,

    /// Parse a user color ("#ff9500"); `#4C8DFF` maps to the accent.
    pub fn parseHex(text: []const u8) Color.ParseError!ColorSpec {
        const c = try Color.parse(text);
        const accent = Color.hex(cmux_accent_hex);
        if (c.a == 1 and c.approxEql(accent, 0.5 / 255.0)) return .accent;
        return .{ .rgb = c };
    }
};

/// Inline text style of a run (DirectWrite ranges in the painter).
pub const RunStyle = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    _pad: u4 = 0,
};

/// A styled span of a text line; `link` makes it clickable.
pub const Run = struct {
    text: []const u8,
    style: RunStyle = .{},
    link: ?[]const u8 = null,
};

/// How a line too long for the row is shortened.
pub const Overflow = enum(u8) {
    /// One line, "…" at the end.
    truncate_end,
    /// One line, "…" at the start (paths: `pathLastSegmentOnly`).
    truncate_start,
    /// Word wrap, limited by `Line.max_lines` (0 = unlimited).
    wrap,
};

pub const Line = struct {
    /// Icon name (cmux SF Symbol name; `ui/icons.zig` maps it to a glyph).
    icon: ?[]const u8 = null,
    runs: []const Run,
    color: ?ColorSpec = null,
    /// Whole-line link (status entry `--url`, PR row); runs may carry their
    /// own links instead.
    link: ?[]const u8 = null,
    overflow: Overflow = .truncate_end,
    max_lines: u16 = 0,
    /// Tooltip shown on hover regardless of truncation (e.g. "Open PR #42").
    tooltip: ?[]const u8 = null,
    /// Never shortened from the start even with `truncate_start` (a
    /// reporter-supplied display label).
    emphasis: bool = false,
};

pub const Pill = struct {
    icon: ?[]const u8 = null,
    text: []const u8,
    color: ?ColorSpec = null,
    link: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

pub const Progress = struct {
    /// 0...1; null = indeterminate.
    value: ?f32,
    label: ?[]const u8 = null,
    color: ?ColorSpec = null,
};

/// A small button such as a port (":8000").
pub const Chip = struct {
    text: []const u8,
    link: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

/// "Show more" / "Show less" toggle synthesized by `build`.
pub const Toggle = struct {
    slot: Slot,
    expanded: bool,
    label: []const u8,
};

pub const ItemKind = enum(u8) { line, pills, progress, chips, toggle };

pub const ItemBody = union(ItemKind) {
    line: Line,
    pills: []const Pill,
    progress: Progress,
    chips: []const Chip,
    toggle: Toggle,
};

/// One detail item of a workspace row.
pub const Item = struct {
    slot: Slot,
    body: ItemBody,
};

/// Collapsing request for one slot (ADR-11.3 `collapsible`).
pub const Collapsible = struct {
    slot: Slot,
    max_visible: u16,
    more_label: []const u8 = default_more_label,
    less_label: []const u8 = default_less_label,
};

pub const default_more_label = "Show more";
pub const default_less_label = "Show less";

/// Contributor output for one workspace.
pub const Details = struct {
    items: []const Item = &.{},
    collapsibles: []const Collapsible = &.{},
    /// Agent activity spinner (shown even with hideAllDetails).
    spinner: bool = false,
    /// Unread count (0 = no badge).
    badge: u32 = 0,
};

/// Pure accumulator behind the ADR-11.3 `RowBuilder` primitives.
/// `ui/sidebar/contrib.zig` wraps it (or aliases it) and calls
/// `beginSlot` before each contributor. Strings are borrowed, not copied:
/// they must outlive the model (use the frame arena for formatted text).
pub const RowBuilder = struct {
    arena: Allocator,
    slot: Slot = .description,
    items: std.ArrayList(Item) = .empty,
    collapsibles: std.ArrayList(Collapsible) = .empty,
    spinner_on: bool = false,
    badge_count: u32 = 0,

    pub fn init(arena: Allocator) RowBuilder {
        return .{ .arena = arena };
    }

    pub fn beginSlot(self: *RowBuilder, slot: Slot) void {
        self.slot = slot;
    }

    pub fn line(self: *RowBuilder, icon: ?[]const u8, runs: []const Run, c: ?ColorSpec, link: ?[]const u8) Allocator.Error!void {
        try self.lineEx(.{ .icon = icon, .runs = runs, .color = c, .link = link });
    }

    pub fn lineEx(self: *RowBuilder, l: Line) Allocator.Error!void {
        try self.items.append(self.arena, .{ .slot = self.slot, .body = .{ .line = l } });
    }

    /// Single-run plain line (capped at `max_text_bytes`).
    pub fn text(self: *RowBuilder, icon: ?[]const u8, s: []const u8, c: ?ColorSpec) Allocator.Error!void {
        const runs = try self.arena.alloc(Run, 1);
        runs[0] = .{ .text = proto.utf8.truncateUtf8(s, max_text_bytes) };
        try self.lineEx(.{ .icon = icon, .runs = runs, .color = c });
    }

    pub fn pills(self: *RowBuilder, items: []const Pill) Allocator.Error!void {
        if (items.len == 0) return;
        try self.items.append(self.arena, .{ .slot = self.slot, .body = .{ .pills = items } });
    }

    pub fn progress(self: *RowBuilder, value: ?f32, label: ?[]const u8) Allocator.Error!void {
        try self.items.append(self.arena, .{ .slot = self.slot, .body = .{ .progress = .{ .value = value, .label = label } } });
    }

    pub fn chips(self: *RowBuilder, items: []const Chip) Allocator.Error!void {
        if (items.len == 0) return;
        try self.items.append(self.arena, .{ .slot = self.slot, .body = .{ .chips = items } });
    }

    /// Markdown block (description): inline styles kept, links clickable,
    /// wraps up to `max_lines` (0 = unlimited).
    pub fn markdown(self: *RowBuilder, block: []const u8, max_lines: u16) Allocator.Error!void {
        const runs = try parseInlineMarkdown(self.arena, block, .keep);
        try self.lineEx(.{ .runs = runs, .overflow = .wrap, .max_lines = max_lines });
    }

    /// Markdown stripped to readable plain text (notification preview).
    pub fn markdownPlain(self: *RowBuilder, block: []const u8, max_lines: u16) Allocator.Error!void {
        const runs = try parseInlineMarkdown(self.arena, block, .strip);
        try self.lineEx(.{ .runs = runs, .overflow = .wrap, .max_lines = max_lines, .color = .{ .tone = .secondary } });
    }

    /// Show at most `max_visible` items of the current slot plus a toggle.
    pub fn collapsible(self: *RowBuilder, max_visible: u16, more_label: ?[]const u8) Allocator.Error!void {
        try self.collapsibles.append(self.arena, .{ .slot = self.slot, .max_visible = max_visible, .more_label = more_label orelse default_more_label });
    }

    pub fn spinner(self: *RowBuilder) void {
        self.spinner_on = true;
    }

    pub fn badge(self: *RowBuilder, n: u32) void {
        self.badge_count = n;
    }

    pub fn finish(self: *RowBuilder) Details {
        return .{
            .items = self.items.items,
            .collapsibles = self.collapsibles.items,
            .spinner = self.spinner_on,
            .badge = self.badge_count,
        };
    }
};

// ─── Inline markdown ────────────────────────────────────────────────────

pub const MarkdownMode = enum { keep, strip };

/// Minimal inline markdown: `[text](url)`, `**bold**`, `__bold__`,
/// `*em*`, `_em_`, `` `code` ``, `~~strike~~`, backslash escapes, and
/// leading `#` heading / `>` quote / `- `, `* `, `+ ` list markers per line
/// (lists become "• "). `.strip` drops styles and link targets (plain
/// readable text); `.keep` keeps them as run styles and links. Unclosed
/// markers are literal text. Only http(s) and mailto links are kept as
/// links; others render as their label.
pub fn parseInlineMarkdown(arena: Allocator, src_in: []const u8, mode: MarkdownMode) Allocator.Error![]Run {
    const src = proto.utf8.truncateUtf8(src_in, max_text_bytes);
    var runs: std.ArrayList(Run) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    var style: RunStyle = .{};

    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        if (!first) try buf.append(arena, '\n');
        first = false;
        var ln = std.mem.trimRight(u8, raw_line, "\r");
        ln = stripBlockPrefix(ln, &buf, arena) catch |e| return e;
        var i: usize = 0;
        while (i < ln.len) {
            const c = ln[i];
            if (c == '\\' and i + 1 < ln.len and std.mem.indexOfScalar(u8, "\\`*_[]()#+-.!~>", ln[i + 1]) != null) {
                try buf.append(arena, ln[i + 1]);
                i += 2;
                continue;
            }
            if (c == '`') {
                if (std.mem.indexOfScalarPos(u8, ln, i + 1, '`')) |end| {
                    try flushRun(arena, &runs, &buf, style, null);
                    try buf.appendSlice(arena, ln[i + 1 .. end]);
                    var s = style;
                    if (mode == .keep) s.code = true;
                    try flushRun(arena, &runs, &buf, s, null);
                    i = end + 1;
                    continue;
                }
            }
            if (c == '[') {
                if (parseLink(ln, i)) |lk| {
                    try flushRun(arena, &runs, &buf, style, null);
                    try buf.appendSlice(arena, lk.label);
                    const keep_link = mode == .keep and isSafeUrl(lk.url);
                    try flushRun(arena, &runs, &buf, style, if (keep_link) lk.url else null);
                    i = lk.end;
                    continue;
                }
            }
            if ((c == '*' or c == '_' or c == '~') and i + 1 < ln.len and ln[i + 1] == c) {
                const open = if (c == '~') style.strike else style.bold;
                if (open or findClosing(ln, i + 2, ln[i .. i + 2])) {
                    try flushRun(arena, &runs, &buf, style, null);
                    if (c == '~') style.strike = !style.strike else style.bold = !style.bold;
                } else {
                    // Unclosed double marker: literal text.
                    try buf.appendSlice(arena, ln[i .. i + 2]);
                }
                i += 2;
                continue;
            }
            if (c == '*' or c == '_') {
                // `_` only delimits at word edges (snake_case stays literal).
                const prev_word = i > 0 and isWordByte(ln[i - 1]);
                const next_word = i + 1 < ln.len and isWordByte(ln[i + 1]);
                const toggles = if (style.italic)
                    c == '*' or !next_word
                else
                    (c == '*' or !prev_word) and i + 1 < ln.len and ln[i + 1] != ' ' and findClosing(ln, i + 1, ln[i .. i + 1]);
                if (toggles) {
                    try flushRun(arena, &runs, &buf, style, null);
                    style.italic = !style.italic;
                    i += 1;
                    continue;
                }
            }
            try buf.append(arena, c);
            i += 1;
        }
        // Styles never span lines.
        try flushRun(arena, &runs, &buf, style, null);
        style = .{};
    }
    try flushRun(arena, &runs, &buf, style, null);
    if (mode == .strip) {
        for (runs.items) |*r| r.style = .{};
        return mergePlain(arena, runs.items);
    }
    return runs.items;
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

fn findClosing(ln: []const u8, from: usize, marker: []const u8) bool {
    if (from >= ln.len) return false;
    return std.mem.indexOfPos(u8, ln, from, marker) != null;
}

fn stripBlockPrefix(ln_in: []const u8, buf: *std.ArrayList(u8), arena: Allocator) Allocator.Error![]const u8 {
    var ln = std.mem.trimLeft(u8, ln_in, " \t");
    if (ln.len == 0) return ln;
    if (ln[0] == '#') {
        var n: usize = 0;
        while (n < ln.len and ln[n] == '#') n += 1;
        if (n <= 6 and (n == ln.len or ln[n] == ' ')) return std.mem.trimLeft(u8, ln[n..], " ");
    }
    if (ln[0] == '>') return std.mem.trimLeft(u8, ln[1..], " ");
    if (ln.len >= 2 and (ln[0] == '-' or ln[0] == '*' or ln[0] == '+') and ln[1] == ' ') {
        try buf.appendSlice(arena, "\u{2022} ");
        return ln[2..];
    }
    return ln;
}

const LinkParse = struct { label: []const u8, url: []const u8, end: usize };

fn parseLink(ln: []const u8, open: usize) ?LinkParse {
    const close = std.mem.indexOfScalarPos(u8, ln, open + 1, ']') orelse return null;
    if (close + 1 >= ln.len or ln[close + 1] != '(') return null;
    // The destination ends at the ')' that balances its '(', so URLs such
    // as https://en.wikipedia.org/wiki/Foo_(bar) keep their parentheses.
    var depth: usize = 0;
    var end = close + 2;
    while (end < ln.len) : (end += 1) switch (ln[end]) {
        '(' => depth += 1,
        ')' => if (depth == 0) break else {
            depth -= 1;
        },
        else => {},
    } else return null;
    const url = std.mem.trim(u8, ln[close + 2 .. end], " ");
    if (url.len == 0) return null;
    return .{ .label = ln[open + 1 .. close], .url = url, .end = end + 1 };
}

/// http(s) and mailto only (no `file:`, `javascript:` or app schemes), and
/// no whitespace or control characters (real URLs percent-encode them).
pub fn isSafeUrl(url: []const u8) bool {
    const scheme_ok = std.ascii.startsWithIgnoreCase(url, "https://") or
        std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "mailto:");
    if (!scheme_ok) return false;
    for (url) |b| if (b <= ' ' or b == 0x7f) return false;
    return true;
}

fn flushRun(arena: Allocator, runs: *std.ArrayList(Run), buf: *std.ArrayList(u8), style: RunStyle, link: ?[]const u8) Allocator.Error!void {
    if (buf.items.len == 0) return;
    const owned = try arena.dupe(u8, buf.items);
    buf.clearRetainingCapacity();
    try runs.append(arena, .{ .text = owned, .style = style, .link = link });
}

fn mergePlain(arena: Allocator, runs: []const Run) Allocator.Error![]Run {
    var total: usize = 0;
    for (runs) |r| total += r.text.len;
    if (total == 0) return &.{};
    const joined = try arena.alloc(u8, total);
    var at: usize = 0;
    for (runs) |r| {
        @memcpy(joined[at .. at + r.text.len], r.text);
        at += r.text.len;
    }
    const out = try arena.alloc(Run, 1);
    out[0] = .{ .text = joined };
    return out;
}

/// Plain text of a run list (for tooltips, accessibility names, measuring).
pub fn joinRuns(arena: Allocator, runs: []const Run) Allocator.Error![]const u8 {
    if (runs.len == 1) return runs[0].text;
    var total: usize = 0;
    for (runs) |r| total += r.text.len;
    const out = try arena.alloc(u8, total);
    var at: usize = 0;
    for (runs) |r| {
        @memcpy(out[at .. at + r.text.len], r.text);
        at += r.text.len;
    }
    return out;
}

/// Index of the run containing UTF-8 byte `offset` of the joined text (for
/// mapping a DirectWrite hit-test position to a run's link).
pub fn runAtOffset(runs: []const Run, offset: usize) ?usize {
    var at: usize = 0;
    for (runs, 0..) |r, i| {
        if (offset < at + r.text.len) return i;
        at += r.text.len;
    }
    return null;
}

// ─── Settings and input ─────────────────────────────────────────────────

pub const BadgePosition = enum { leading, trailing };

/// cmux `sidebar.*` settings that change the row model.
pub const Settings = struct {
    hide_all_details: bool = false,
    show_workspace_description: bool = true,
    show_notification_message: bool = true,
    show_branch_directory: bool = true,
    show_pull_requests: bool = true,
    show_ssh: bool = true,
    show_ports: bool = true,
    show_log: bool = true,
    show_progress: bool = true,
    show_custom_metadata: bool = true,
    show_agent_activity: bool = true,
    wrap_workspace_titles: bool = false,
    compact_agent_status: bool = false,
    notification_message_line_limit: u16 = 12,
    notification_badge_position: BadgePosition = .leading,
    loading_spinner_position: BadgePosition = .leading,
    /// remote-tmux "origin host titles": append " (host)" to duplicates.
    origin_host_titles: bool = false,

    /// Whether items of `slot` are shown. `hideAllDetails` wins over every
    /// per-detail toggle; compact agent status moves the notification
    /// preview into the status glyph's tooltip.
    pub fn slotVisible(self: Settings, slot: Slot) bool {
        if (self.hide_all_details) return false;
        return switch (slot) {
            .description => self.show_workspace_description,
            .notification_preview => self.show_notification_message and !self.compact_agent_status,
            .status_entries, .custom_metadata => self.show_custom_metadata,
            .progress => self.show_progress,
            .log => self.show_log,
            .branch_dir => self.show_branch_directory,
            .pull_requests => self.show_pull_requests,
            .ports => self.show_ports,
            .remote => self.show_ssh,
            .agent_status, .todo_summary, .loading => true,
        };
    }

    /// Whether a contributor's data probe for `slot` should run (a hidden
    /// detail also stops its probe, ADR-11.3). The notification preview is
    /// still needed in compact mode (it feeds the tooltip).
    pub fn probeWanted(self: Settings, slot: Slot) bool {
        if (slot == .notification_preview) return !self.hide_all_details and self.show_notification_message;
        return self.slotVisible(slot);
    }

    fn hashInto(self: Settings, h: *std.hash.Wyhash) void {
        // Only fields that change a row's content after filtering matter;
        // they are folded into each row's hash through its resolved data,
        // except the title wrap mode, which is layout-only.
        h.update(&.{ @intFromBool(self.wrap_workspace_titles and !self.compact_agent_status), @intFromBool(self.compact_agent_status) });
    }
};

pub const MediaIcon = enum(u8) { audio, microphone, camera, screen };

/// Status glyph before the title (manual status or compact agent status).
pub const Glyph = struct {
    icon: []const u8,
    color: ?ColorSpec = null,
    tooltip: ?[]const u8 = null,
};

pub const WorkspaceInput = struct {
    id: Uuid,
    /// User-set name; empty/blank = use `auto_title`.
    custom_title: []const u8 = "",
    /// Process title / directory basename / agent auto-name.
    auto_title: []const u8 = "",
    /// Remote origin host (remote-tmux), for duplicate disambiguation.
    host: ?[]const u8 = null,
    pinned: bool = false,
    muted: bool = false,
    media: []const MediaIcon = &.{},
    status_glyph: ?Glyph = null,
    /// Workspace custom color (left rail).
    color: ?Color = null,
    /// Status lane "done": content renders at `done_opacity`.
    done: bool = false,
    /// Shortcut hint shown on modifier hold ("Ctrl+1").
    shortcut_hint: ?[]const u8 = null,
    /// Expanded "Show more" sections.
    expanded: SlotSet = .{},
    details: Details = .{},
    /// Latest notification body as received (inline markdown allowed); in
    /// compact mode it becomes the glyph tooltip as stripped plain text.
    notification_preview: ?[]const u8 = null,
};

pub const GroupInput = struct {
    id: Uuid,
    title: []const u8,
    pinned: bool = false,
    collapsed: bool = false,
    color: ?Color = null,
    /// Members in the user's order.
    members: []const WorkspaceInput = &.{},
};

pub const Node = union(enum) {
    workspace: WorkspaceInput,
    group: GroupInput,

    fn pinned(self: Node) bool {
        return switch (self) {
            .workspace => |w| w.pinned,
            .group => |g| g.pinned,
        };
    }
};

pub const RowModelInput = struct {
    /// Top-level nodes in the user's drag order (pinned or not).
    nodes: []const Node,
    settings: Settings = .{},
};

// ─── Output ─────────────────────────────────────────────────────────────

pub const done_opacity: f32 = 0.6;

pub const Leading = struct {
    spinner: bool = false,
    /// Count badge text ("1".."99", "99+"); null = none.
    badge: ?[]const u8 = null,
    /// Compact agent status replaces the count by a blue "unseen" dot.
    unseen_dot: bool = false,
};

pub const Trailing = struct {
    spinner: bool = false,
    badge: ?[]const u8 = null,
    /// The hover close button (always present for workspace rows).
    close: bool = true,
};

pub const TitleLine = struct {
    leading: Leading = .{},
    pinned: bool = false,
    muted: bool = false,
    media: []const MediaIcon = &.{},
    glyph: ?Glyph = null,
    title: []const u8,
    wrap: bool = false,
    trailing: Trailing = .{},
    hint: ?[]const u8 = null,
};

pub const WorkspaceRow = struct {
    id: Uuid,
    /// Group the row belongs to (null = top level).
    group: ?Uuid = null,
    title: TitleLine,
    rail: ?Color = null,
    dimmed: bool = false,
    items: []const Item = &.{},
};

pub const GroupHeaderRow = struct {
    id: Uuid,
    title: []const u8,
    collapsed: bool,
    pinned: bool,
    color: ?Color = null,
    member_count: usize,
    /// Members (for reveal targets while collapsed).
    member_ids: []const Uuid,
    /// Sum of member unread counts as badge text; null = none.
    badge: ?[]const u8 = null,
};

pub const RowKind = enum(u8) { group_header, workspace };

pub const RowBody = union(RowKind) {
    group_header: GroupHeaderRow,
    workspace: WorkspaceRow,
};

pub const Row = struct {
    body: RowBody,
    /// Hash of everything that affects the row's laid-out elements: their
    /// presence, rectangles and actions (layout cache key together with
    /// width, DPI and metrics).
    content_hash: u64,

    pub fn id(self: *const Row) Uuid {
        return switch (self.body) {
            inline else => |b| b.id,
        };
    }

    pub fn kind(self: *const Row) RowKind {
        return self.body;
    }
};

/// Build the rows of one window's sidebar. Order: the pinned tier (pinned
/// workspaces and pinned groups) then the unpinned tier, each in the
/// user's order; group members follow their header unless the group is
/// collapsed. All allocations go to `arena`.
pub fn build(arena: Allocator, input: RowModelInput) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    const titles = try TitleIndex.init(arena, input);
    for ([_]bool{ true, false }) |tier_pinned| {
        for (input.nodes) |node| {
            if (node.pinned() != tier_pinned) continue;
            switch (node) {
                .workspace => |w| try rows.append(arena, try workspaceRow(arena, w, null, input.settings, &titles)),
                .group => |g| {
                    try rows.append(arena, try groupRow(arena, g));
                    if (g.collapsed) continue;
                    for (g.members) |m| try rows.append(arena, try workspaceRow(arena, m, g.id, input.settings, &titles));
                },
            }
        }
    }
    return rows.items;
}

/// Row to scroll to so workspace `ws` is revealed: its own row, or its
/// group header while the group is collapsed (or null if absent).
pub fn revealTarget(rows: []const Row, ws: Uuid) ?usize {
    for (rows, 0..) |*r, i| switch (r.body) {
        .workspace => |w| if (w.id.eql(ws)) return i,
        .group_header => |g| if (g.collapsed) {
            for (g.member_ids) |m| if (m.eql(ws)) return i;
        },
    };
    return null;
}

pub fn indexOf(rows: []const Row, row_id: Uuid) ?usize {
    for (rows, 0..) |*r, i| if (r.id().eql(row_id)) return i;
    return null;
}

/// Badge text for an unread count: "" for 0, the number up to 99, "99+".
pub fn badgeText(arena: Allocator, n: u64) Allocator.Error!?[]const u8 {
    if (n == 0) return null;
    if (n > 99) return "99+";
    return try std.fmt.allocPrint(arena, "{d}", .{n});
}

/// Display title: the custom name if non-blank, else the auto title, else
/// "Workspace".
pub fn resolveTitle(custom: []const u8, auto: []const u8) []const u8 {
    const c = std.mem.trim(u8, custom, " \t\r\n");
    if (c.len > 0) return proto.utf8.truncateUtf8(c, max_text_bytes);
    const a = std.mem.trim(u8, auto, " \t\r\n");
    if (a.len > 0) return proto.utf8.truncateUtf8(a, max_text_bytes);
    return "Workspace";
}

/// Counts of resolved titles, for " (host)" disambiguation.
const TitleIndex = struct {
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    enabled: bool,

    fn init(arena: Allocator, input: RowModelInput) Allocator.Error!TitleIndex {
        var self: TitleIndex = .{ .enabled = input.settings.origin_host_titles };
        if (!self.enabled) return self;
        for (input.nodes) |node| switch (node) {
            .workspace => |w| try self.add(arena, w),
            .group => |g| for (g.members) |m| try self.add(arena, m),
        };
        return self;
    }

    fn add(self: *TitleIndex, arena: Allocator, w: WorkspaceInput) Allocator.Error!void {
        const gop = try self.counts.getOrPut(arena, resolveTitle(w.custom_title, w.auto_title));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    fn display(self: *const TitleIndex, arena: Allocator, w: WorkspaceInput) Allocator.Error![]const u8 {
        const t = resolveTitle(w.custom_title, w.auto_title);
        if (!self.enabled) return t;
        const host = w.host orelse return t;
        if (host.len == 0) return t;
        if ((self.counts.get(t) orelse 0) < 2) return t;
        const joined = try std.fmt.allocPrint(arena, "{s} ({s})", .{ t, proto.utf8.truncateUtf8(host, max_host_bytes) });
        return proto.utf8.truncateUtf8(joined, max_text_bytes);
    }
};

fn groupRow(arena: Allocator, g: GroupInput) Allocator.Error!Row {
    const ids = try arena.alloc(Uuid, g.members.len);
    var unread: u64 = 0;
    for (g.members, 0..) |m, i| {
        ids[i] = m.id;
        unread += m.details.badge;
    }
    const title = proto.utf8.truncateUtf8(g.title, max_text_bytes);
    // A collapsed group surfaces its members' unread count.
    const badge = if (g.collapsed) try badgeText(arena, unread) else null;
    var h = std.hash.Wyhash.init(0x6864_7267); // "grph"
    h.update(title);
    // A color adds the rail element, so its presence is geometry.
    h.update(&.{ 0, @intFromBool(g.collapsed), @intFromBool(g.pinned), @intFromBool(g.color != null) });
    h.update(std.mem.asBytes(&@as(u64, g.members.len)));
    if (badge) |b| h.update(b);
    return .{
        .body = .{ .group_header = .{
            .id = g.id,
            .title = title,
            .collapsed = g.collapsed,
            .pinned = g.pinned,
            .color = g.color,
            .member_count = g.members.len,
            .member_ids = ids,
            .badge = badge,
        } },
        .content_hash = h.final(),
    };
}

fn workspaceRow(arena: Allocator, w: WorkspaceInput, group: ?Uuid, s: Settings, titles: *const TitleIndex) Allocator.Error!Row {
    const d = w.details;
    const compact = s.compact_agent_status;
    const badge_text = if (compact) null else try badgeText(arena, d.badge);
    const spinner = d.spinner and s.show_agent_activity;

    var title: TitleLine = .{
        .pinned = w.pinned,
        .muted = w.muted,
        .media = w.media,
        .glyph = w.status_glyph,
        .title = try titles.display(arena, w),
        .wrap = s.wrap_workspace_titles and !compact,
        .hint = w.shortcut_hint,
    };
    if (compact and d.badge > 0) title.leading.unseen_dot = true;
    if (s.notification_badge_position == .leading) title.leading.badge = badge_text else title.trailing.badge = badge_text;
    if (s.loading_spinner_position == .leading) title.leading.spinner = spinner else title.trailing.spinner = spinner;

    // In compact mode the latest notification is the glyph's tooltip, as
    // readable plain text (inline markdown stripped, capped).
    if (compact) if (w.notification_preview) |raw| {
        const plain = try joinRuns(arena, try parseInlineMarkdown(arena, raw, .strip));
        const p = std.mem.trim(u8, plain, " \t\r\n");
        if (p.len > 0) {
            var g = title.glyph orelse Glyph{ .icon = "bell" };
            g.tooltip = if (g.tooltip) |t| try std.fmt.allocPrint(arena, "{s}\n{s}", .{ p, t }) else p;
            title.glyph = g;
        }
    };

    const items = try resolveItems(arena, d, w.expanded, s);
    var row: WorkspaceRow = .{
        .id = w.id,
        .group = group,
        .title = title,
        .rail = w.color,
        .dimmed = w.done,
        .items = items,
    };
    return .{ .body = .{ .workspace = row }, .content_hash = hashWorkspace(&row, s) };
}

/// Filter by visibility, order by slot (stable within a slot), then apply
/// "Show more" collapsing.
fn resolveItems(arena: Allocator, d: Details, expanded: SlotSet, s: Settings) Allocator.Error![]const Item {
    var kept: std.ArrayList(Item) = .empty;
    for (d.items) |it| {
        if (it.body == .toggle) continue; // synthesized only here
        if (s.slotVisible(it.slot)) try kept.append(arena, it);
    }
    std.sort.insertion(Item, kept.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return @intFromEnum(a.slot) < @intFromEnum(b.slot);
        }
    }.lt);

    var out: std.ArrayList(Item) = .empty;
    var i: usize = 0;
    while (i < kept.items.len) {
        const slot = kept.items[i].slot;
        var j = i;
        while (j < kept.items.len and kept.items[j].slot == slot) j += 1;
        const group = kept.items[i..j];
        const coll = findCollapsible(d.collapsibles, slot);
        if (coll != null and group.len > coll.?.max_visible) {
            const c = coll.?;
            const open = expanded.has(slot);
            try out.appendSlice(arena, if (open) group else group[0..c.max_visible]);
            try out.append(arena, .{ .slot = slot, .body = .{ .toggle = .{
                .slot = slot,
                .expanded = open,
                .label = if (open) c.less_label else c.more_label,
            } } });
        } else {
            try out.appendSlice(arena, group);
        }
        i = j;
    }
    return out.items;
}

fn findCollapsible(list: []const Collapsible, slot: Slot) ?Collapsible {
    var found: ?Collapsible = null;
    for (list) |c| if (c.slot == slot) {
        found = c; // last request wins
    };
    return found;
}

fn hashOpt(h: *std.hash.Wyhash, s: ?[]const u8) void {
    if (s) |v| {
        h.update(&.{1});
        h.update(std.mem.asBytes(&@as(u64, v.len)));
        h.update(v);
    } else h.update(&.{0});
}

fn hashStr(h: *std.hash.Wyhash, s: []const u8) void {
    h.update(std.mem.asBytes(&@as(u64, s.len)));
    h.update(s);
}

fn hashWorkspace(r: *const WorkspaceRow, s: Settings) u64 {
    var h = std.hash.Wyhash.init(0x7773_726f); // "wsro"
    s.hashInto(&h);
    const t = &r.title;
    h.update(&.{
        @intFromBool(t.leading.spinner),  @intFromBool(t.leading.unseen_dot),
        @intFromBool(t.pinned),           @intFromBool(t.muted),
        @intFromBool(t.wrap),             @intFromBool(t.trailing.spinner),
        @intFromBool(t.trailing.close),   @intFromBool(r.rail != null),
        @intCast(@min(t.media.len, 255)),
    });
    hashOpt(&h, t.leading.badge);
    hashOpt(&h, t.trailing.badge);
    hashOpt(&h, t.hint);
    hashOpt(&h, if (t.glyph) |g| g.icon else null);
    hashStr(&h, t.title);
    for (r.items) |it| {
        h.update(&.{ @intFromEnum(it.slot), @intFromEnum(@as(ItemKind, it.body)) });
        switch (it.body) {
            .line => |l| {
                hashOpt(&h, l.icon);
                h.update(&.{ @intFromEnum(l.overflow), @intFromBool(l.emphasis), @intFromBool(l.link != null) });
                h.update(std.mem.asBytes(&l.max_lines));
                h.update(std.mem.asBytes(&@as(u64, l.runs.len)));
                for (l.runs) |run| {
                    hashStr(&h, run.text);
                    h.update(&.{ @bitCast(run.style), @intFromBool(run.link != null) });
                }
            },
            // A link makes the cached pill/chip element an open_link target.
            .pills => |ps| for (ps) |p| {
                hashOpt(&h, p.icon);
                hashStr(&h, p.text);
                h.update(&.{@intFromBool(p.link != null)});
            },
            .progress => |p| {
                h.update(&.{@intFromBool(p.value == null)});
                hashOpt(&h, p.label);
            },
            .chips => |cs| for (cs) |c| {
                hashStr(&h, c.text);
                h.update(&.{@intFromBool(c.link != null)});
            },
            .toggle => |tg| hashStr(&h, tg.label),
        }
    }
    return h.final();
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn testId(n: u8) Uuid {
    var u: Uuid = .nil;
    u.b[15] = n;
    return u;
}

test "unit: sidebar: slot values match the frozen contributor order" {
    try testing.expectEqual(@as(u8, 10), @intFromEnum(Slot.description));
    try testing.expectEqual(@as(u8, 130), @intFromEnum(Slot.loading));
    try testing.expectEqual(@as(usize, 13), Slot.count);
    inline for (@typeInfo(Slot).@"enum".fields, 0..) |f, i| {
        try testing.expectEqual(i, @as(Slot, @enumFromInt(f.value)).index());
    }
    var set: SlotSet = .{};
    set = set.with(.ports).with(.loading);
    try testing.expect(set.has(.ports) and set.has(.loading) and !set.has(.log));
    try testing.expect(!set.without(.ports).has(.ports));
}

test "unit: sidebar: pinned tier first, then unpinned, each in user order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]Node{
        .{ .workspace = .{ .id = testId(1), .custom_title = "one" } },
        .{ .workspace = .{ .id = testId(2), .custom_title = "two" } },
        .{ .workspace = .{ .id = testId(3), .custom_title = "three", .pinned = true } },
        .{ .group = .{ .id = testId(10), .title = "G", .pinned = true, .members = &.{
            .{ .id = testId(4), .custom_title = "four" },
        } } },
    };
    const rows = try build(a, .{ .nodes = &nodes });
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqualStrings("three", rows[0].body.workspace.title.title);
    try testing.expect(rows[0].body.workspace.title.pinned);
    try testing.expectEqualStrings("G", rows[1].body.group_header.title);
    try testing.expect(testId(10).eql(rows[2].body.workspace.group.?));
    try testing.expectEqualStrings("one", rows[3].body.workspace.title.title);
    try testing.expectEqualStrings("two", rows[4].body.workspace.title.title);
}

test "unit: sidebar: collapsed group hides members and reveals via header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]Node{
        .{ .group = .{ .id = testId(10), .title = "G", .collapsed = true, .members = &.{
            .{ .id = testId(4), .details = .{ .badge = 2 } },
            .{ .id = testId(5), .details = .{ .badge = 3 } },
        } } },
        .{ .workspace = .{ .id = testId(6) } },
    };
    const rows = try build(a, .{ .nodes = &nodes });
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(?usize, 0), revealTarget(rows, testId(5)));
    try testing.expectEqual(@as(?usize, 1), revealTarget(rows, testId(6)));
    try testing.expectEqual(@as(?usize, null), revealTarget(rows, testId(99)));
    try testing.expectEqualStrings("5", rows[0].body.group_header.badge.?);
    try testing.expectEqual(@as(usize, 2), rows[0].body.group_header.member_count);
    try testing.expectEqual(@as(?usize, 1), indexOf(rows, testId(6)));
}

test "unit: sidebar: title resolution, blank names and host disambiguation" {
    try testing.expectEqualStrings("mine", resolveTitle("  mine ", "auto"));
    try testing.expectEqualStrings("auto", resolveTitle(" \t", "auto"));
    try testing.expectEqualStrings("Workspace", resolveTitle("", ""));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]Node{
        .{ .workspace = .{ .id = testId(1), .auto_title = "zsh", .host = "alpha" } },
        .{ .workspace = .{ .id = testId(2), .auto_title = "zsh", .host = "beta" } },
        .{ .workspace = .{ .id = testId(3), .auto_title = "vim", .host = "beta" } },
    };
    const off = try build(a, .{ .nodes = &nodes });
    try testing.expectEqualStrings("zsh", off[0].body.workspace.title.title);
    const on = try build(a, .{ .nodes = &nodes, .settings = .{ .origin_host_titles = true } });
    try testing.expectEqualStrings("zsh (alpha)", on[0].body.workspace.title.title);
    try testing.expectEqualStrings("zsh (beta)", on[1].body.workspace.title.title);
    try testing.expectEqualStrings("vim", on[2].body.workspace.title.title);
}

test "unit: sidebar: huge titles are capped on a code point boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, max_text_bytes + 2);
    @memset(big, 'x');
    big[max_text_bytes - 1] = 0xC3; // "é" straddles the cap
    big[max_text_bytes] = 0xA9;
    const t = resolveTitle(big, "");
    try testing.expectEqual(max_text_bytes - 1, t.len);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "unit: sidebar: badge text and positions, compact unseen dot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?[]const u8, null), try badgeText(a, 0));
    try testing.expectEqualStrings("7", (try badgeText(a, 7)).?);
    try testing.expectEqualStrings("99", (try badgeText(a, 99)).?);
    try testing.expectEqualStrings("99+", (try badgeText(a, 100)).?);
    try testing.expectEqualStrings("99+", (try badgeText(a, std.math.maxInt(u64))).?);

    const nodes = [_]Node{.{ .workspace = .{ .id = testId(1), .details = .{ .badge = 2, .spinner = true } } }};
    const lead = try build(a, .{ .nodes = &nodes });
    try testing.expectEqualStrings("2", lead[0].body.workspace.title.leading.badge.?);
    try testing.expect(lead[0].body.workspace.title.leading.spinner);
    try testing.expect(lead[0].body.workspace.title.trailing.badge == null);

    const trail = try build(a, .{ .nodes = &nodes, .settings = .{ .notification_badge_position = .trailing, .loading_spinner_position = .trailing } });
    try testing.expectEqualStrings("2", trail[0].body.workspace.title.trailing.badge.?);
    try testing.expect(trail[0].body.workspace.title.trailing.spinner);
    try testing.expect(trail[0].body.workspace.title.leading.badge == null);

    const compact = try build(a, .{ .nodes = &nodes, .settings = .{ .compact_agent_status = true, .wrap_workspace_titles = true } });
    try testing.expect(compact[0].body.workspace.title.leading.unseen_dot);
    try testing.expect(compact[0].body.workspace.title.leading.badge == null);
    try testing.expect(!compact[0].body.workspace.title.wrap); // compact forces one line

    const no_activity = try build(a, .{ .nodes = &nodes, .settings = .{ .show_agent_activity = false } });
    try testing.expect(!no_activity[0].body.workspace.title.leading.spinner);
}

test "unit: sidebar: items sort by slot, hideAllDetails keeps only spinner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = RowBuilder.init(a);
    b.beginSlot(.ports);
    try b.chips(&.{.{ .text = ":8000" }});
    b.beginSlot(.description);
    try b.markdown("Ship it", 0);
    b.beginSlot(.log);
    try b.text("info", "built", .{ .tone = .info });
    b.beginSlot(.agent_status);
    b.spinner();
    try b.pills(&.{}); // empty pills add nothing
    const nodes = [_]Node{.{ .workspace = .{ .id = testId(1), .details = b.finish() } }};
    const rows = try build(a, .{ .nodes = &nodes });
    const items = rows[0].body.workspace.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(Slot.description, items[0].slot);
    try testing.expectEqual(Slot.log, items[1].slot);
    try testing.expectEqual(Slot.ports, items[2].slot);

    const hidden = try build(a, .{ .nodes = &nodes, .settings = .{ .hide_all_details = true } });
    try testing.expectEqual(@as(usize, 0), hidden[0].body.workspace.items.len);
    try testing.expect(hidden[0].body.workspace.title.leading.spinner);

    const no_ports = try build(a, .{ .nodes = &nodes, .settings = .{ .show_ports = false } });
    try testing.expectEqual(@as(usize, 2), no_ports[0].body.workspace.items.len);
}

test "unit: sidebar: visibility toggles map to slots and probes" {
    const s: Settings = .{ .compact_agent_status = true };
    try testing.expect(!s.slotVisible(.notification_preview));
    try testing.expect(s.probeWanted(.notification_preview));
    const all_off: Settings = .{ .hide_all_details = true };
    inline for (@typeInfo(Slot).@"enum".fields) |f| {
        try testing.expect(!all_off.slotVisible(@enumFromInt(f.value)));
        try testing.expect(!all_off.probeWanted(@enumFromInt(f.value)));
    }
    try testing.expect(!(Settings{ .show_custom_metadata = false }).slotVisible(.status_entries));
    try testing.expect(!(Settings{ .show_ssh = false }).slotVisible(.remote));
    try testing.expect(!(Settings{ .show_progress = false }).slotVisible(.progress));
    try testing.expect(!(Settings{ .show_log = false }).slotVisible(.log));
    try testing.expect(!(Settings{ .show_branch_directory = false }).slotVisible(.branch_dir));
    try testing.expect(!(Settings{ .show_pull_requests = false }).slotVisible(.pull_requests));
    try testing.expect(!(Settings{ .show_workspace_description = false }).slotVisible(.description));
    try testing.expect((Settings{}).slotVisible(.agent_status));
}

test "unit: sidebar: collapsible slot shows max_visible plus show more/less" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = RowBuilder.init(a);
    b.beginSlot(.status_entries);
    for (0..5) |i| try b.text(null, try std.fmt.allocPrint(a, "entry {d}", .{i}), null);
    try b.collapsible(3, null);
    b.beginSlot(.log);
    try b.text(null, "log", null);
    const d = b.finish();

    const nodes = [_]Node{.{ .workspace = .{ .id = testId(1), .details = d } }};
    const rows = try build(a, .{ .nodes = &nodes });
    const items = rows[0].body.workspace.items;
    try testing.expectEqual(@as(usize, 5), items.len); // 3 + toggle + log
    try testing.expectEqualStrings("Show more", items[3].body.toggle.label);
    try testing.expect(!items[3].body.toggle.expanded);
    try testing.expectEqual(Slot.log, items[4].slot);

    const open_nodes = [_]Node{.{ .workspace = .{ .id = testId(1), .details = d, .expanded = (SlotSet{}).with(.status_entries) } }};
    const open = try build(a, .{ .nodes = &open_nodes });
    const oi = open[0].body.workspace.items;
    try testing.expectEqual(@as(usize, 7), oi.len);
    try testing.expectEqualStrings("Show less", oi[5].body.toggle.label);
    try testing.expect(rows[0].content_hash != open[0].content_hash);
}

test "unit: sidebar: exactly max_visible entries need no toggle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = RowBuilder.init(a);
    b.beginSlot(.status_entries);
    for (0..3) |_| try b.text(null, "e", null);
    try b.collapsible(3, "More…");
    const nodes = [_]Node{.{ .workspace = .{ .id = testId(1), .details = b.finish() } }};
    const rows = try build(a, .{ .nodes = &nodes });
    try testing.expectEqual(@as(usize, 3), rows[0].body.workspace.items.len);
}

test "unit: sidebar: compact mode moves notification preview into glyph tooltip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = RowBuilder.init(a);
    b.beginSlot(.notification_preview);
    try b.markdownPlain("**done** in 3s", 12);
    // The raw notification body: markdown is stripped for the tooltip too.
    const nodes = [_]Node{.{ .workspace = .{
        .id = testId(1),
        .details = b.finish(),
        .notification_preview = "**done** in 3s",
        .status_glyph = .{ .icon = "checkmark", .tooltip = "Idle" },
    } }};
    const normal = try build(a, .{ .nodes = &nodes });
    try testing.expectEqual(@as(usize, 1), normal[0].body.workspace.items.len);
    try testing.expectEqualStrings("done in 3s", normal[0].body.workspace.items[0].body.line.runs[0].text);
    const compact = try build(a, .{ .nodes = &nodes, .settings = .{ .compact_agent_status = true } });
    try testing.expectEqual(@as(usize, 0), compact[0].body.workspace.items.len);
    try testing.expectEqualStrings("done in 3s\nIdle", compact[0].body.workspace.title.glyph.?.tooltip.?);
}

test "unit: sidebar: content hash ignores nothing that changes geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]Node{.{ .workspace = .{ .id = testId(1), .custom_title = "a" } }};
    const same = [_]Node{.{ .workspace = .{ .id = testId(2), .custom_title = "a", .color = Color.hex(0xff0000) } }};
    const renamed = [_]Node{.{ .workspace = .{ .id = testId(1), .custom_title = "b" } }};
    const pinned = [_]Node{.{ .workspace = .{ .id = testId(1), .custom_title = "a", .pinned = true } }};
    const h0 = (try build(a, .{ .nodes = &base }))[0].content_hash;
    // Identity and rail color do not move anything; a rail's presence does.
    const h_same = (try build(a, .{ .nodes = &same }))[0].content_hash;
    try testing.expect(h0 != h_same);
    const nodes_ok = [_]Node{.{ .workspace = .{ .id = testId(9), .custom_title = "a" } }};
    try testing.expectEqual(h0, (try build(a, .{ .nodes = &nodes_ok }))[0].content_hash);
    try testing.expect(h0 != (try build(a, .{ .nodes = &renamed }))[0].content_hash);
    try testing.expect(h0 != (try build(a, .{ .nodes = &pinned }))[0].content_hash);
    try testing.expect(h0 != (try build(a, .{ .nodes = &base, .settings = .{ .wrap_workspace_titles = true } }))[0].content_hash);
}

test "unit: sidebar: empty input builds no rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try build(arena.allocator(), .{ .nodes = &.{} });
    try testing.expectEqual(@as(usize, 0), rows.len);
    try testing.expectEqual(@as(?usize, null), revealTarget(rows, testId(1)));
}

test "unit: sidebar: inline markdown keeps links and styles or strips them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kept = try parseInlineMarkdown(a, "see [docs](https://example.com) **now**", .keep);
    try testing.expectEqual(@as(usize, 4), kept.len);
    try testing.expectEqualStrings("see ", kept[0].text);
    try testing.expectEqualStrings("docs", kept[1].text);
    try testing.expectEqualStrings("https://example.com", kept[1].link.?);
    try testing.expectEqualStrings(" ", kept[2].text);
    try testing.expectEqualStrings("now", kept[3].text);
    try testing.expect(kept[3].style.bold and !kept[1].style.bold);
    try testing.expectEqual(@as(?usize, 1), runAtOffset(kept, 5));
    try testing.expectEqual(@as(?usize, 3), runAtOffset(kept, 9));
    try testing.expectEqual(@as(?usize, null), runAtOffset(kept, 99));

    const plain = try parseInlineMarkdown(a, "**done** in `3s` _ok_ ~~x~~", .strip);
    try testing.expectEqual(@as(usize, 1), plain.len);
    try testing.expectEqualStrings("done in 3s ok x", plain[0].text);
    try testing.expectEqual(RunStyle{}, plain[0].style);
}

test "unit: sidebar: markdown block prefixes, escapes, unsafe links, malformed input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try parseInlineMarkdown(a, "# Title\n- item\n> quote\n\\*lit\\*", .strip);
    try testing.expectEqualStrings("Title\n\u{2022} item\nquote\n*lit*", plain[0].text);
    const bad = try parseInlineMarkdown(a, "[x](javascript:alert(1)) **open [no close", .keep);
    for (bad) |r| try testing.expect(r.link == null);
    try testing.expectEqualStrings("x", bad[0].text);
    const joined = try joinRuns(a, bad);
    try testing.expect(std.mem.indexOf(u8, joined, "**open [no close") != null);
    try testing.expectEqual(@as(usize, 0), (try parseInlineMarkdown(a, "", .keep)).len);
    try testing.expectEqual(@as(usize, 0), (try parseInlineMarkdown(a, "", .strip)).len);
    const uni = try parseInlineMarkdown(a, "**日本** 🚀 snake_case_name", .strip);
    try testing.expectEqualStrings("日本 🚀 snake_case_name", uni[0].text);
    const invalid = try parseInlineMarkdown(a, "\xff\xfe *a*", .strip);
    try testing.expectEqualStrings("\xff\xfe a", invalid[0].text);
}

test "unit: sidebar: link destinations keep balanced parentheses and reject whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wiki = try parseInlineMarkdown(a, "see [Foo](https://en.wikipedia.org/wiki/Foo_(bar)) ok", .keep);
    try testing.expectEqual(@as(usize, 3), wiki.len);
    try testing.expectEqualStrings("Foo", wiki[1].text);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", wiki[1].link.?);
    try testing.expectEqualStrings(" ok", wiki[2].text);
    // Unbalanced destinations are literal text.
    const open = try parseInlineMarkdown(a, "[x](https://a.example/(b", .keep);
    for (open) |r| try testing.expect(r.link == null);
    try testing.expectEqualStrings("[x](https://a.example/(b", try joinRuns(a, open));
    // A real URL percent-encodes whitespace and control characters.
    try testing.expect(isSafeUrl("https://a.example/x_(y)?q=1#f"));
    try testing.expect(!isSafeUrl("https://a b") and !isSafeUrl("https://a\x00b"));
    try testing.expect(!isSafeUrl("http://a\tb") and !isSafeUrl("https://a\x7f") and !isSafeUrl("mailto:a@b\r\n"));
    const titled = try parseInlineMarkdown(a, "[x](https://a.example \"title\")", .keep);
    for (titled) |r| try testing.expect(r.link == null);
    try testing.expectEqualStrings("x", titled[0].text);
}

test "unit: sidebar: derived texts stay within the text cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, max_text_bytes);
    @memset(big, 't');
    const long_host = try a.alloc(u8, 1000);
    @memset(long_host, 'h');
    var b = RowBuilder.init(a);
    b.beginSlot(.log);
    try b.text(null, try std.mem.concat(a, u8, &.{ big, "tail" }), null);
    const nodes = [_]Node{
        .{ .workspace = .{ .id = testId(1), .custom_title = big, .host = "alpha", .details = b.finish() } },
        .{ .workspace = .{ .id = testId(2), .custom_title = big, .host = long_host } },
        .{ .workspace = .{ .id = testId(3), .custom_title = "zsh", .host = long_host } },
        .{ .workspace = .{ .id = testId(4), .custom_title = "zsh", .host = "beta" } },
    };
    const rows = try build(a, .{ .nodes = &nodes, .settings = .{ .origin_host_titles = true } });
    for (rows) |r| try testing.expect(r.body.workspace.title.title.len <= max_text_bytes);
    try testing.expectEqual(max_text_bytes, rows[0].body.workspace.items[0].body.line.runs[0].text.len);
    // A garbage host is cut; real hostnames (<= 253 bytes) are not.
    const t = rows[2].body.workspace.title.title;
    try testing.expect(std.mem.startsWith(u8, t, "zsh (hhh") and std.mem.endsWith(u8, t, "h)"));
    try testing.expect(t.len < 300);
    try testing.expectEqualStrings("zsh (beta)", rows[3].body.workspace.title.title);
}

test "unit: sidebar: markdown parser survives random marker soup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const pieces = [_][]const u8{
        "*",         "**",                 "_",          "__",           "~~",   "~",        "`",          "[",
        "]",         "(",                  ")",          "\\",           "# ",   "#",        "> ",         "- ",
        "+ ",        " ",                  "\n",         "\r\n",         "a",    "b c",      "snake_case", "\u{65e5}",
        "\u{1F680}", "https://x.example/", "mailto:m@x", "javascript:z", "\xff", "\xe2\x82",
    };
    var prng = std.Random.DefaultPrng.init(0x5eed_51de);
    const rand = prng.random();
    var src: std.ArrayList(u8) = .empty;
    for (0..4000) |_| {
        _ = scratch.reset(.retain_capacity);
        const s = scratch.allocator();
        src.clearRetainingCapacity();
        for (0..rand.uintLessThan(usize, 24)) |_| try src.appendSlice(arena.allocator(), pieces[rand.uintLessThan(usize, pieces.len)]);
        const lines = std.mem.count(u8, src.items, "\n") + 1;
        for ([_]MarkdownMode{ .keep, .strip }) |mode| {
            const runs = try parseInlineMarkdown(s, src.items, mode);
            if (mode == .strip) try testing.expect(runs.len <= 1);
            var total: usize = 0;
            for (runs) |r| {
                try testing.expect(r.text.len > 0);
                if (r.link) |l| try testing.expect(mode == .keep and isSafeUrl(l));
                if (mode == .strip) try testing.expectEqual(RunStyle{}, r.style);
                total += r.text.len;
            }
            // Markup only disappears, except list bullets ("- " -> "• ").
            try testing.expect(total <= src.items.len + 2 * lines);
        }
    }
}

test "unit: sidebar: expanded groups, zero max_visible and forged toggles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Members of an expanded group reveal their own row; only a collapsed
    // header carries the members' unread sum.
    const groups = [_]Node{.{ .group = .{ .id = testId(10), .title = "G", .members = &.{
        .{ .id = testId(4), .details = .{ .badge = 2 } },
        .{ .id = testId(5), .details = .{ .badge = 1 } },
    } } }};
    const rows = try build(a, .{ .nodes = &groups });
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(?usize, 2), revealTarget(rows, testId(5)));
    try testing.expect(rows[0].body.group_header.badge == null);

    // max_visible = 0 collapses a slot down to its toggle.
    var b = RowBuilder.init(a);
    b.beginSlot(.status_entries);
    try b.text(null, "a", null);
    try b.text(null, "b", null);
    try b.collapsible(0, null);
    const ws = [_]Node{.{ .workspace = .{ .id = testId(1), .details = b.finish() } }};
    const collapsed = try build(a, .{ .nodes = &ws });
    const items = collapsed[0].body.workspace.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings(default_more_label, items[0].body.toggle.label);

    // Toggles come only from build: one passed in by a contributor is dropped.
    const forged = [_]Node{.{ .workspace = .{ .id = testId(2), .details = .{ .items = &.{
        .{ .slot = .log, .body = .{ .toggle = .{ .slot = .log, .expanded = false, .label = "x" } } },
    } } } }};
    try testing.expectEqual(@as(usize, 0), (try build(a, .{ .nodes = &forged }))[0].body.workspace.items.len);
}

test "unit: sidebar: color spec maps the cmux accent sentinel" {
    try testing.expectEqual(ColorSpec.accent, try ColorSpec.parseHex("#4C8DFF"));
    try testing.expectEqual(ColorSpec.accent, try ColorSpec.parseHex("#4c8dff"));
    const orange = try ColorSpec.parseHex("#ff9500");
    try testing.expect(orange == .rgb);
    try testing.expectError(error.InvalidColor, ColorSpec.parseHex("nope"));
    try testing.expect(isSafeUrl("HTTPS://x") and isSafeUrl("mailto:a@b") and !isSafeUrl("file:///c:/x"));
}
