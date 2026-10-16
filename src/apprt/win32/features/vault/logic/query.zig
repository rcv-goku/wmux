//! Vault search query (agents-vault-search, hosted-vault-cli): operator parser,
//! matcher and recency ranking shared by the Vault pane, `vault search` and
//! global search. Pure.
//!
//! Syntax: whitespace-separated tokens; `"double quoted phrases"`; operators
//! `agent:<id>` (several = OR), `repo:<substring of the cwd basename>`,
//! `ws:<substring of the full cwd>`, `after:yyyy-MM-dd` (modified >= local
//! start of that day) and `before:yyyy-MM-dd` (modified < local start of that
//! day). Operator values may be quoted (`repo:"my project"`). Free-text terms
//! AND together across title, cwd, branch, agent name and transcript text.
//! Matching is case-insensitive for ASCII. Results are ranked by recency.

const std = @import("std");
const Allocator = std.mem.Allocator;
const index = @import("index.zig");
const Session = index.Session;

pub const Operator = enum { agent, repo, ws, after, before };

const operators = std.StaticStringMap(Operator).initComptime(.{
    .{ "agent", .agent },
    .{ "repo", .repo },
    .{ "ws", .ws },
    .{ "after", .after },
    .{ "before", .before },
});

pub const ParseOptions = struct {
    /// Local offset from UTC in minutes, for the start of day of after:/before:.
    tz_offset_min: i32 = 0,
};

/// A parsed query. Every slice is owned by the query.
pub const Query = struct {
    agents: std.ArrayList([]u8) = .empty,
    repos: std.ArrayList([]u8) = .empty,
    wss: std.ArrayList([]u8) = .empty,
    /// Free-text terms and phrases (ANDed).
    terms: std.ArrayList([]u8) = .empty,
    /// Inclusive lower bound on `Session.modifiedMs()` (after:).
    after_ms: ?i64 = null,
    /// Exclusive upper bound on `Session.modifiedMs()` (before:).
    before_ms: ?i64 = null,
    /// Operator tokens ignored because their date did not parse.
    invalid_dates: u32 = 0,

    pub fn deinit(self: *Query, gpa: Allocator) void {
        for ([_]*std.ArrayList([]u8){ &self.agents, &self.repos, &self.wss, &self.terms }) |list| {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        self.* = undefined;
    }

    /// True when the query has no constraint at all (lists everything).
    pub fn isEmpty(self: *const Query) bool {
        return self.agents.items.len == 0 and self.repos.items.len == 0 and
            self.wss.items.len == 0 and self.terms.items.len == 0 and
            self.after_ms == null and self.before_ms == null;
    }

    /// Metadata operators only (agent/repo/ws/dates), ignoring free text.
    pub fn matchesMetadata(self: *const Query, s: *const Session) bool {
        if (self.agents.items.len > 0) {
            var any = false;
            for (self.agents.items) |a| {
                if (std.ascii.eqlIgnoreCase(a, s.agent) or std.ascii.eqlIgnoreCase(a, s.agentName())) {
                    any = true;
                    break;
                }
            }
            if (!any) return false;
        }
        const base = index.basename(s.cwd);
        for (self.repos.items) |r| if (!containsIgnoreCase(base, r)) return false;
        for (self.wss.items) |w| if (!containsIgnoreCase(s.cwd, w)) return false;
        const m = s.modifiedMs();
        if (self.after_ms) |a| if (m < a) return false;
        if (self.before_ms) |b| if (m >= b) return false;
        return true;
    }

    /// Every free-text term occurs in title, cwd, branch, agent name or text.
    pub fn matchesText(self: *const Query, s: *const Session) bool {
        for (self.terms.items) |t| {
            if (containsIgnoreCase(s.title, t) or containsIgnoreCase(s.cwd, t) or
                containsIgnoreCase(s.branch, t) or containsIgnoreCase(s.agentName(), t) or
                containsIgnoreCase(s.agent, t) or containsIgnoreCase(s.text.items, t))
                continue;
            return false;
        }
        return true;
    }

    pub fn matches(self: *const Query, s: *const Session) bool {
        return self.matchesMetadata(s) and self.matchesText(s);
    }
};

/// One lexical token: its text (quotes removed) and, for `op:value`, the
/// operator name.
const Token = struct {
    key: ?[]const u8 = null,
    value: []const u8,
};

/// Tokenizer over the raw query. A `"` opens a phrase that runs to the next
/// `"` (or the end of input when unterminated). `key:"quoted value"` keeps the
/// key. There are no escapes.
const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }

    fn quoted(self: *Lexer) []const u8 {
        // self.src[self.pos] == '"'
        const start = self.pos + 1;
        const end = std.mem.indexOfScalarPos(u8, self.src, start, '"') orelse self.src.len;
        self.pos = @min(end + 1, self.src.len);
        return self.src[start..end];
    }

    fn next(self: *Lexer) ?Token {
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] == '"') return .{ .value = self.quoted() };
        const start = self.pos;
        while (self.pos < self.src.len and !isSpace(self.src[self.pos])) {
            const c = self.src[self.pos];
            if (c == ':' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"' and
                self.pos > start)
            {
                const key = self.src[start..self.pos];
                self.pos += 1;
                return .{ .key = key, .value = self.quoted() };
            }
            self.pos += 1;
        }
        const word = self.src[start..self.pos];
        if (std.mem.indexOfScalar(u8, word, ':')) |colon| {
            if (colon > 0) return .{ .key = word[0..colon], .value = word[colon + 1 ..] };
        }
        return .{ .value = word };
    }
};

/// Parses `src`. Unknown `key:value` tokens and operators with an empty value
/// are free text; after:/before: with a malformed date are ignored and
/// counted in `invalid_dates`. Repeated after: keeps the latest date and
/// repeated before: the earliest (all bounds apply).
pub fn parse(gpa: Allocator, src: []const u8, opts: ParseOptions) Allocator.Error!Query {
    var q: Query = .{};
    errdefer q.deinit(gpa);
    var lx: Lexer = .{ .src = src };
    while (lx.next()) |tok| {
        const op: ?Operator = if (tok.key) |k| blk: {
            var lower: [8]u8 = undefined;
            if (k.len > lower.len) break :blk null;
            break :blk operators.get(std.ascii.lowerString(&lower, k));
        } else null;
        if (op == null or tok.value.len == 0) {
            // Rebuild free text from the raw token (`foo:bar`, `agent:`).
            const text = if (tok.key) |k| try std.mem.concat(gpa, u8, &.{ k, ":", tok.value }) else try gpa.dupe(u8, tok.value);
            errdefer gpa.free(text);
            if (text.len == 0) {
                gpa.free(text);
                continue;
            }
            try q.terms.append(gpa, text);
            continue;
        }
        switch (op.?) {
            .agent => try appendOwned(gpa, &q.agents, tok.value),
            .repo => try appendOwned(gpa, &q.repos, tok.value),
            .ws => try appendOwned(gpa, &q.wss, tok.value),
            .after, .before => {
                const day = index.parseDate(tok.value) orelse {
                    q.invalid_dates +|= 1;
                    continue;
                };
                const ms = day * 86_400_000 - @as(i64, opts.tz_offset_min) * 60_000;
                if (op.? == .after) {
                    q.after_ms = if (q.after_ms) |a| @max(a, ms) else ms;
                } else {
                    q.before_ms = if (q.before_ms) |b| @min(b, ms) else ms;
                }
            },
        }
    }
    return q;
}

fn appendOwned(gpa: Allocator, list: *std.ArrayList([]u8), s: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, s);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}

/// ASCII case-insensitive substring test; an empty needle always matches.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

pub const SearchResult = struct {
    /// Matching sessions, newest first. Pointers borrow from the input.
    hits: []*const Session,
    /// Total matches before `limit` was applied.
    total: usize,
    /// Some candidate passing the metadata filters could not be fully searched
    /// (truncated text or malformed lines): "Some session history could not
    /// be searched".
    partial: bool,

    pub fn deinit(self: *SearchResult, gpa: Allocator) void {
        gpa.free(self.hits);
        self.* = undefined;
    }
};

/// Runs `q` over `sessions` and ranks hits by recency (newest first, ties by
/// agent then id). `limit` 0 means unlimited.
pub fn search(gpa: Allocator, sessions: []const *const Session, q: *const Query, limit: usize) Allocator.Error!SearchResult {
    var hits: std.ArrayList(*const Session) = .empty;
    errdefer hits.deinit(gpa);
    var partial = false;
    for (sessions) |s| {
        if (!q.matchesMetadata(s)) continue;
        if (q.matchesText(s)) {
            try hits.append(gpa, s);
        } else if (s.partiallySearchable()) {
            partial = true;
        }
    }
    index.sortByRecency(hits.items);
    const total = hits.items.len;
    if (limit != 0 and hits.items.len > limit) hits.shrinkRetainingCapacity(limit);
    return .{ .hits = try hits.toOwnedSlice(gpa), .total = total, .partial = partial };
}

/// Filters of `vault sessions [--agent <id>] [--folder <path>] [--limit <n>]`.
pub const ListFilter = struct {
    agent: ?[]const u8 = null,
    /// Matches sessions whose cwd is this folder or inside it (separators `/`
    /// and `\` are equivalent; ASCII case-insensitive, as on Windows).
    folder: ?[]const u8 = null,
    /// 0 = unlimited.
    limit: usize = 0,
};

/// True when `cwd` equals `folder` or lies beneath it.
pub fn inFolder(cwd: []const u8, folder: []const u8) bool {
    const f = trimSeps(folder);
    const c = trimSeps(cwd);
    if (f.len == 0) return true;
    if (c.len < f.len) return false;
    for (c[0..f.len], f) |a, b| {
        if (isSep(a) and isSep(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return c.len == f.len or isSep(c[f.len]) or isSep(f[f.len - 1]);
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn trimSeps(p: []const u8) []const u8 {
    var end = p.len;
    // Keep a lone root separator ("/" or "C:\").
    while (end > 1 and isSep(p[end - 1]) and !(end == 3 and p[1] == ':')) end -= 1;
    return p[0..end];
}

/// Newest-first listing for `vault sessions`. Caller frees the slice.
pub fn listSessions(gpa: Allocator, sessions: []const *const Session, f: ListFilter) Allocator.Error![]*const Session {
    var out: std.ArrayList(*const Session) = .empty;
    errdefer out.deinit(gpa);
    for (sessions) |s| {
        if (f.agent) |a| if (!std.ascii.eqlIgnoreCase(a, s.agent)) continue;
        if (f.folder) |folder| if (!inFolder(s.cwd, folder)) continue;
        try out.append(gpa, s);
    }
    index.sortByRecency(out.items);
    if (f.limit != 0 and out.items.len > f.limit) out.shrinkRetainingCapacity(f.limit);
    return out.toOwnedSlice(gpa);
}
