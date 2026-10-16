//! Palette ranking (ADR-8.8 / W2-7): combines the fuzzy match score of every
//! item with its usage boost and item-type precedence, with deterministic
//! tie-breaks.
//!
//! Per cmux, an item is indexed by title + subtitle + keywords. Each query
//! token is scored against every field and keeps its best field; subtitle and
//! keyword matches cost a small per-token penalty so a title hit wins. All
//! tokens must match. Tokens that miss exactly fall back to a single-edit
//! (typo) match scored with `fuzzy.penalty_typo`; typo and exact matches are
//! merged into one list ordered by score.
//!
//! Final score = Σ token scores − unmatched-title penalty + usage boost (one
//! third with a non-empty query) + kind bonus (workspace > surface > command).
//! Order: score desc, then kind precedence, `rank` asc (provider order, e.g.
//! "selected window first"), title (case-insensitive), input index. With an
//! empty query every item is listed, ordered by usage boost and then the same
//! tie-breaks, so a command used often rises to the top.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fuzzy = @import("fuzzy.zig");
const usage = @import("usage.zig");

pub const Range = fuzzy.Range;

/// Item type; declaration order is precedence order.
pub const Kind = enum(u8) {
    workspace,
    surface,
    command,

    pub fn bonus(self: Kind) i32 {
        return switch (self) {
            .workspace => 4,
            .surface => 2,
            .command => 0,
        };
    }
};

pub const penalty_subtitle: i32 = 8;
pub const penalty_keyword: i32 = 12;
pub const coverage_unit: usize = 4;
pub const max_coverage_penalty: usize = 16;

pub const Item = struct {
    /// Command id (usage key) or workspace/surface UUID.
    id: []const u8,
    title: []const u8,
    subtitle: []const u8 = "",
    keywords: []const []const u8 = &.{},
    kind: Kind = .command,
    /// Provider order (lower first) used as a tie-break.
    rank: u32 = 0,
};

pub const Options = struct {
    /// Unix milliseconds, for usage decay.
    now_ms: i64 = 0,
    usage: ?*const usage.Store = null,
    /// Keep at most this many results (after sorting).
    limit: ?usize = null,
    /// Allow single-edit typo matches.
    typo: bool = true,
};

pub const Result = struct {
    /// Index into the input items.
    index: u32,
    score: i32,
    typo: bool,
    /// Byte ranges into the item's title / subtitle to highlight.
    title_ranges: []const Range,
    subtitle_ranges: []const Range,
};

pub const Ranking = struct {
    arena: std.heap.ArenaAllocator,
    results: []Result,
    /// Matches before `limit` was applied.
    total: usize,

    pub fn deinit(self: *Ranking) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Field = enum { title, subtitle, keyword };

const TokenBest = struct {
    score: i32 = 0,
    found: bool = false,
    typo: bool = false,
    field: Field = .title,
};

/// Ranks `items` against `query` (the search text after `modes.parse`).
/// Items and query are borrowed; results live in the returned arena.
pub fn rank(gpa: Allocator, items: []const Item, query: []const u8, opts: Options) Allocator.Error!Ranking {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(gpa);
    var it = fuzzy.tokenize(query);
    while (it.next()) |tok| try tokens.append(gpa, tok);
    const query_empty = tokens.items.len == 0;

    const best = try gpa.alloc(TokenBest, tokens.items.len);
    defer gpa.free(best);

    var m = fuzzy.Matcher.init(gpa);
    defer m.deinit();

    var results: std.ArrayList(Result) = .empty;
    for (items, 0..) |item, idx| {
        const boost = if (opts.usage) |u| u.boostFor(item.id, opts.now_ms, query_empty) else 0;
        var r: Result = .{
            .index = @intCast(idx),
            .score = boost + item.kind.bonus(),
            .typo = false,
            .title_ranges = &.{},
            .subtitle_ranges = &.{},
        };
        if (!query_empty) {
            @memset(best, .{});
            try scoreFields(&m, item, tokens.items, best, false);
            if (opts.typo and !allFound(best)) try scoreFields(&m, item, tokens.items, best, true);
            if (!allFound(best)) continue;
            for (best) |b| {
                r.score += b.score;
                r.typo = r.typo or b.typo;
            }
            r.title_ranges = try collectRanges(a, &m, item.title, .title, tokens.items, best);
            r.subtitle_ranges = try collectRanges(a, &m, item.subtitle, .subtitle, tokens.items, best);
            r.score -= coveragePenalty(item.title, r.title_ranges);
        }
        try results.append(a, r);
    }

    const Ctx = struct {
        items: []const Item,
        fn lessThan(ctx: @This(), x: Result, y: Result) bool {
            if (x.score != y.score) return x.score > y.score;
            const ix = ctx.items[x.index];
            const iy = ctx.items[y.index];
            if (ix.kind != iy.kind) return @intFromEnum(ix.kind) < @intFromEnum(iy.kind);
            if (ix.rank != iy.rank) return ix.rank < iy.rank;
            switch (std.ascii.orderIgnoreCase(ix.title, iy.title)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            switch (std.mem.order(u8, ix.title, iy.title)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            return x.index < y.index;
        }
    };
    std.mem.sort(Result, results.items, Ctx{ .items = items }, Ctx.lessThan);

    const total = results.items.len;
    if (opts.limit) |l| results.shrinkRetainingCapacity(@min(l, total));
    return .{ .arena = arena, .results = results.items, .total = total };
}

/// Penalty for title text the query left unmatched, so "Split Right" beats
/// "Split Browser Right" for "splt rght": one point per
/// `coverage_unit` unmatched code points, capped. Zero when no token matched
/// the title (keyword/subtitle hits already pay a field penalty).
fn coveragePenalty(title: []const u8, ranges: []const Range) i32 {
    if (ranges.len == 0) return 0;
    var matched: usize = 0;
    for (ranges) |r| matched += cpCount(title[r.start..r.end]);
    const unmatched = cpCount(title) -| matched;
    return @intCast(@min(max_coverage_penalty, unmatched / coverage_unit));
}

fn cpCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn allFound(best: []const TokenBest) bool {
    for (best) |b| if (!b.found) return false;
    return true;
}

fn fieldPenalty(f: Field) i32 {
    return switch (f) {
        .title => 0,
        .subtitle => penalty_subtitle,
        .keyword => penalty_keyword,
    };
}

/// Scores every not-yet-found token (typo pass) or every token (exact pass)
/// against each field, keeping the best field per token.
fn scoreFields(m: *fuzzy.Matcher, item: Item, tokens: []const []const u8, best: []TokenBest, typo: bool) Allocator.Error!void {
    try scoreField(m, item.title, .title, tokens, best, typo);
    try scoreField(m, item.subtitle, .subtitle, tokens, best, typo);
    for (item.keywords) |kw| try scoreField(m, kw, .keyword, tokens, best, typo);
}

fn scoreField(m: *fuzzy.Matcher, text: []const u8, field: Field, tokens: []const []const u8, best: []TokenBest, typo: bool) Allocator.Error!void {
    if (text.len == 0) return;
    var hay_set = false;
    for (tokens, best) |tok, *b| {
        if (typo and b.found and !b.typo) continue;
        if (!hay_set) {
            try m.setHaystack(text);
            hay_set = true;
        }
        const raw = if (typo) try m.matchTokenTypo(tok, null) else try m.matchToken(tok, null);
        const s = (raw orelse continue) - fieldPenalty(field);
        if (!b.found or s > b.score) b.* = .{ .score = s, .found = true, .typo = typo, .field = field };
    }
}

fn collectRanges(a: Allocator, m: *fuzzy.Matcher, text: []const u8, field: Field, tokens: []const []const u8, best: []const TokenBest) Allocator.Error![]const Range {
    // The matcher appends with its own allocator; copy into the arena.
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(m.gpa);
    var hay_set = false;
    for (tokens, best) |tok, b| {
        if (b.field != field) continue;
        if (!hay_set) {
            try m.setHaystack(text);
            hay_set = true;
        }
        _ = if (b.typo) try m.matchTokenTypo(tok, &out) else try m.matchToken(tok, &out);
    }
    return a.dupe(Range, out.items);
}

/// Splits a path or branch into searchable components ("C:\src\api" →
/// "C:", "src", "api"; "feature/login" → "feature", "login"), as the
/// switcher indexes path and branch components. Slices borrow `text`;
/// caller frees the outer slice.
pub fn componentKeywords(gpa: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, text, "/\\");
    while (it.next()) |c| try out.append(gpa, c);
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const proto = @import("wmux_proto");

fn titlesOf(r: Ranking, items: []const Item, buf: [][]const u8) []const []const u8 {
    const n = @min(buf.len, r.results.len);
    for (r.results[0..n], 0..) |res, i| buf[i] = items[res.index].title;
    return buf[0..n];
}

fn expectTop(items: []const Item, query: []const u8, opts: Options, expected: []const []const u8) !void {
    var r = try rank(testing.allocator, items, query, opts);
    defer r.deinit();
    var buf: [32][]const u8 = undefined;
    const got = titlesOf(r, items, buf[0..expected.len]);
    testing.expectEqual(expected.len, got.len) catch |err| {
        std.log.err("query '{s}': got {d} results", .{ query, got.len });
        return err;
    };
    for (expected, got, 0..) |e, g, i| {
        testing.expectEqualStrings(e, g) catch |err| {
            std.log.err("query '{s}' position {d}", .{ query, i });
            return err;
        };
    }
}

/// Palette commands from the real actions catalog (supported, palette = true).
fn catalogItems(gpa: Allocator) ![]Item {
    var list: std.ArrayList(Item) = .empty;
    errdefer list.deinit(gpa);
    for (proto.actions_catalog.entries, 0..) |e, i| {
        if (!e.palette or e.availability != .supported) continue;
        try list.append(gpa, .{ .id = e.id, .title = e.title, .kind = .command, .rank = @intCast(i) });
    }
    return list.toOwnedSlice(gpa);
}

test "unit: palette: ranking golden: catalog commands" {
    const gpa = testing.allocator;
    const items = try catalogItems(gpa);
    defer gpa.free(items);
    // Acceptance: the typo query ranks Split Right first.
    try expectTop(items, "splt rght", .{}, &.{"Split Right"});
    try expectTop(items, "split", .{}, &.{ "Split Down", "Split Right", "Split Browser Down", "Split Browser Right" });
    try expectTop(items, "new ws", .{}, &.{"New Workspace"});
    try expectTop(items, "close tab", .{}, &.{ "Close Tab", "Close Other Tabs in Pane" });
    try expectTop(items, "zoom", .{}, &.{"Zoom In"});
    try expectTop(items, "rename", .{}, &.{ "Rename Tab", "Rename Workspace" });
}

test "unit: palette: ranking golden: typo matches merge by score" {
    const gpa = testing.allocator;
    const items = try catalogItems(gpa);
    defer gpa.free(items);
    // "clsoe" is a scattered exact subsequence of "Close Other Tabs in Pane"
    // but a tight transposition of "Close": the typo match ranks first.
    try expectTop(items, "clsoe tab", .{}, &.{ "Close Tab", "Close Other Tabs in Pane" });
    try expectTop(items, "slpit rihgt", .{}, &.{"Split Right"});
    var r = try rank(gpa, items, "slpit rihgt", .{});
    defer r.deinit();
    try testing.expect(r.results[0].typo);
    // Disabling typos keeps only exact matches.
    try expectTop(items, "clsoe tab", .{ .typo = false }, &.{"Close Other Tabs in Pane"});
    var none_r = try rank(gpa, items, "slpit rihgt", .{ .typo = false });
    defer none_r.deinit();
    try testing.expectEqual(@as(usize, 0), none_r.results.len);
    // Exact matches still win against equally good typo matches.
    const two = [_]Item{
        .{ .id = "a", .title = "Spilt" },
        .{ .id = "b", .title = "Split" },
    };
    try expectTop(&two, "split", .{}, &.{ "Split", "Spilt" });
}

test "unit: palette: ranking golden: usage lifts a command to the top of the empty query" {
    const gpa = testing.allocator;
    const items = try catalogItems(gpa);
    defer gpa.free(items);
    const now: i64 = 1_760_000_000_000;
    var store: usage.Store = .empty;
    defer store.deinit(gpa);
    for (0..5) |_| try store.record(gpa, "toggleSidebar", now - 1000);
    try store.record(gpa, "splitDown", now - 30 * std.time.ms_per_day);
    try store.record(gpa, "find", now - 1000);
    const opts: Options = .{ .usage = &store, .now_ms = now };
    var r = try rank(gpa, items, "", opts);
    defer r.deinit();
    try testing.expectEqual(items.len, r.results.len);
    try testing.expectEqualStrings("toggleSidebar", items[r.results[0].index].id);
    try testing.expectEqualStrings("find", items[r.results[1].index].id);
    try testing.expectEqualStrings("splitDown", items[r.results[2].index].id);
    // Without usage the empty query keeps catalog order.
    var plain = try rank(gpa, items, "", .{});
    defer plain.deinit();
    for (plain.results, 0..) |res, i| try testing.expectEqual(@as(u32, @intCast(i)), res.index);
}

test "unit: palette: ranking usage boost is one third with a query" {
    const gpa = testing.allocator;
    const now: i64 = 1_760_000_000_000;
    const items = [_]Item{
        .{ .id = "splitDown", .title = "Split Down" },
        .{ .id = "splitRight", .title = "Split Right" },
    };
    var store: usage.Store = .empty;
    defer store.deinit(gpa);
    for (0..3) |_| try store.record(gpa, "splitRight", now);
    var r = try rank(gpa, &items, "split", .{ .usage = &store, .now_ms = now });
    defer r.deinit();
    try testing.expectEqualStrings("Split Right", items[r.results[0].index].title);
    try testing.expectEqual(r.results[1].score + 13, r.results[0].score);
    // A strong title match still beats a modest usage boost.
    try expectTop(&items, "sd", .{ .usage = &store, .now_ms = now }, &.{"Split Down"});
}

test "unit: palette: ranking golden: switcher over workspaces and surfaces" {
    const gpa = testing.allocator;
    const api_kw = [_][]const u8{ "C:\\src\\api", "feature/login-flow", "3000" };
    const web_kw = [_][]const u8{ "C:\\src\\web", "main", "5173", "Marketing site" };
    const docs_kw = [_][]const u8{ "D:\\notes", "docs/update" };
    const md_kw = try componentKeywords(gpa, "C:\\src\\api\\docs\\README.md");
    defer gpa.free(md_kw);
    const items = [_]Item{
        .{ .id = "W1", .title = "api", .subtitle = "Workspace", .keywords = &api_kw, .kind = .workspace, .rank = 0 },
        .{ .id = "W2", .title = "web", .subtitle = "Workspace", .keywords = &web_kw, .kind = .workspace, .rank = 1 },
        .{ .id = "W3", .title = "notes", .subtitle = "Window 2", .keywords = &docs_kw, .kind = .workspace, .rank = 2 },
        .{ .id = "S1", .title = "pwsh", .subtitle = "Terminal • api", .kind = .surface, .rank = 3 },
        .{ .id = "S2", .title = "README.md", .subtitle = "Markdown • api", .keywords = md_kw, .kind = .surface, .rank = 4 },
        .{ .id = "S3", .title = "localhost:5173", .subtitle = "Browser • web", .kind = .surface, .rank = 5 },
        .{ .id = "S4", .title = "web server", .subtitle = "Terminal • web", .kind = .surface, .rank = 6 },
    };
    // Empty query: provider order (selected window first), workspaces first.
    try expectTop(&items, "", .{}, &.{ "api", "web", "notes", "pwsh", "README.md", "localhost:5173", "web server" });
    // Acceptance: a branch name finds the workspace on that branch.
    try expectTop(&items, "login", .{}, &.{"api"});
    try expectTop(&items, "feature/login", .{}, &.{"api"});
    // Acceptance: a markdown filename finds its tab.
    try expectTop(&items, "readme", .{}, &.{"README.md"});
    // Port: the workspace listening on it (keyword prefix match plus the
    // workspace bonus) ranks above the browser tab showing it.
    try expectTop(&items, "5173", .{}, &.{ "web", "localhost:5173" });
    // Same title score: the workspace outranks the surface by precedence.
    try expectTop(&items, "web", .{}, &.{ "web", "web server", "localhost:5173" });
    // Subtitle search ("Markdown • api").
    try expectTop(&items, "markdown", .{}, &.{"README.md"});
    // Description keyword.
    try expectTop(&items, "marketing", .{}, &.{"web"});
}

test "unit: palette: ranking highlight ranges per field" {
    const items = [_]Item{
        .{ .id = "x", .title = "Split Right", .subtitle = "Terminal • api", .keywords = &.{"pane"} },
    };
    var r = try rank(testing.allocator, &items, "sr api pane", .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.results.len);
    const res = r.results[0];
    try testing.expectEqualSlices(Range, &.{ .{ .start = 0, .end = 1 }, .{ .start = 6, .end = 7 } }, res.title_ranges);
    const sub = items[0].subtitle;
    try testing.expectEqual(@as(usize, 1), res.subtitle_ranges.len);
    try testing.expectEqualStrings("api", sub[res.subtitle_ranges[0].start..res.subtitle_ranges[0].end]);
}

test "unit: palette: ranking typo matches highlight the corrected token" {
    const items = [_]Item{.{ .id = "x", .title = "Split Right", .subtitle = "Terminal" }};
    var r = try rank(testing.allocator, &items, "slpit termnial", .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.results.len);
    try testing.expect(r.results[0].typo);
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 5 }}, r.results[0].title_ranges);
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 8 }}, r.results[0].subtitle_ranges);
}

fn rankAndFree(gpa: Allocator, items: []const Item, query: []const u8, store: *const usage.Store) !void {
    var r = try rank(gpa, items, query, .{ .usage = store, .now_ms = 1_760_000_000_000, .limit = 2 });
    r.deinit();
    gpa.free(try componentKeywords(gpa, "C:\\src\\api/docs"));
}

test "unit: palette: ranking frees everything when an allocation fails" {
    const gpa = testing.allocator;
    var store: usage.Store = .empty;
    defer store.deinit(gpa);
    try store.record(gpa, "b", 1_760_000_000_000);
    const kw = [_][]const u8{ "C:\\src\\api", "feature/login-flow" };
    const items = [_]Item{
        .{ .id = "a", .title = "Split Right", .subtitle = "Terminal \u{2022} api", .keywords = &kw },
        .{ .id = "b", .title = "Split Down", .kind = .surface },
        .{ .id = "c", .title = "api", .kind = .workspace, .keywords = &kw },
    };
    // Empty query, exact + typo + subtitle tokens, keyword-only match, no match.
    for ([_][]const u8{ "", "slpit api", "login", "qqqq" }) |q| {
        try testing.checkAllAllocationFailures(gpa, rankAndFree, .{ &items, q, &store });
    }
}

test "unit: palette: ranking ties are stable and deterministic" {
    const items = [_]Item{
        .{ .id = "1", .title = "Duplicate" },
        .{ .id = "2", .title = "Duplicate" },
        .{ .id = "3", .title = "duplicate" },
        .{ .id = "4", .title = "Duplicate", .rank = 0, .kind = .surface },
        .{ .id = "5", .title = "Duplicate", .rank = 1, .kind = .surface },
    };
    var r = try rank(testing.allocator, &items, "dup", .{});
    defer r.deinit();
    var ids: [5][]const u8 = undefined;
    for (r.results, 0..) |res, i| ids[i] = items[res.index].id;
    // Surfaces first (kind bonus), then by rank; among commands "duplicate"
    // wins on exact case for the lowercase query, then input order.
    try testing.expectEqualSlices(u8, "4", ids[0]);
    try testing.expectEqualSlices(u8, "5", ids[1]);
    try testing.expectEqualSlices(u8, "3", ids[2]);
    try testing.expectEqualSlices(u8, "1", ids[3]);
    try testing.expectEqualSlices(u8, "2", ids[4]);
    // Same query twice gives the same order.
    var r2 = try rank(testing.allocator, &items, "dup", .{});
    defer r2.deinit();
    for (r.results, r2.results) |x, y| try testing.expectEqual(x.index, y.index);
}

test "unit: palette: ranking title tie-break is case-insensitive" {
    const items = [_]Item{
        .{ .id = "b", .title = "beta" },
        .{ .id = "a", .title = "Alpha" },
        .{ .id = "c", .title = "Gamma" },
    };
    try expectTop(&items, "", .{}, &.{ "Alpha", "beta", "Gamma" });
}

test "unit: palette: ranking limit, no match and empty inputs" {
    const gpa = testing.allocator;
    const items = try catalogItems(gpa);
    defer gpa.free(items);
    var r = try rank(gpa, items, "", .{ .limit = 20 });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 20), r.results.len);
    try testing.expectEqual(items.len, r.total);
    var none_r = try rank(gpa, items, "qqqqzzzz", .{});
    defer none_r.deinit();
    try testing.expectEqual(@as(usize, 0), none_r.results.len);
    var empty = try rank(gpa, &.{}, "split", .{});
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.results.len);
    // Whitespace-only query behaves like the empty query.
    var ws = try rank(gpa, items, "   ", .{ .limit = 3 });
    defer ws.deinit();
    try testing.expectEqual(@as(usize, 3), ws.results.len);
}

test "unit: palette: ranking emoji and unicode titles are searchable" {
    const items = [_]Item{
        .{ .id = "a", .title = "🚀 Deploy" },
        .{ .id = "b", .title = "Déploiement" },
        .{ .id = "c", .title = "Deploy Preview" },
    };
    try expectTop(&items, "🚀", .{}, &.{"🚀 Deploy"});
    try expectTop(&items, "dépl", .{}, &.{"Déploiement"});
    try expectTop(&items, "deploy", .{}, &.{ "Deploy Preview", "🚀 Deploy" });
}

test "unit: palette: ranking huge item lists" {
    const gpa = testing.allocator;
    const n = 5000;
    const titles = try gpa.alloc([]u8, n);
    defer {
        for (titles) |t| gpa.free(t);
        gpa.free(titles);
    }
    const items = try gpa.alloc(Item, n);
    defer gpa.free(items);
    for (0..n) |i| {
        titles[i] = try std.fmt.allocPrint(gpa, "Workspace {d} feature-{d}", .{ i, i * 7 });
        items[i] = .{ .id = titles[i], .title = titles[i], .kind = .workspace, .rank = @intCast(i) };
    }
    var r = try rank(gpa, items, "workspace 4999", .{ .limit = 5 });
    defer r.deinit();
    try testing.expectEqualStrings("Workspace 4999 feature-34993", items[r.results[0].index].title);
    try testing.expectEqual(@as(usize, 5), r.results.len);
}

test "unit: palette: ranking componentKeywords splits paths and branches" {
    const gpa = testing.allocator;
    const a = try componentKeywords(gpa, "C:\\src\\api/docs//x");
    defer gpa.free(a);
    try testing.expectEqual(@as(usize, 5), a.len);
    try testing.expectEqualStrings("C:", a[0]);
    try testing.expectEqualStrings("x", a[4]);
    const b = try componentKeywords(gpa, "");
    defer gpa.free(b);
    try testing.expectEqual(@as(usize, 0), b.len);
}
