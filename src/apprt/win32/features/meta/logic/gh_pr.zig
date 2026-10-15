//! GitHub pull-request parsers for the `pull_requests` sidebar contributor
//! (ADR-11.3, W2-6) and the `cmux pr` command. Pure: parses bytes produced
//! by `gh` (run elsewhere) into owned row models with cmux's row semantics:
//! label + `#number` + status (open, merged, closed), one row per
//! normalized URL, fresher then higher-status states winning, explicit
//! workspace links ordered after pane-derived ones, stale after repeated
//! refresh failures.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// argv for the per-branch probe, run with cwd = the pane directory.
pub const view_argv = [_][]const u8{
    "gh",
    "pr",
    "view",
    "--json",
    "number,state,isDraft,url,title,headRefName,reviewDecision,statusCheckRollup",
};

/// Cap on captured `gh pr view` stdout (status check rollups can be long).
pub const view_max_output_bytes: usize = 1024 * 1024;

/// Byte caps for owned row strings (G6), cut on code-point boundaries.
pub const max_title_bytes: usize = 512;
pub const max_url_bytes: usize = 2048;
pub const max_branch_bytes: usize = 512;

/// Default row label (cmux shows other review systems as e.g. `MR`).
pub const default_label = "PR";

/// Consecutive failed refreshes after which a row is marked stale.
pub const stale_after_failures: u8 = 3;

/// `cmux pr` error strings (cmux's exact wording; scripts match on them).
pub const invalid_selector_message = "cmux pr expects a pull-request URL or a positive pull-request number";
pub const foreign_repo_message = "cmux pr: the pull request does not belong to the detected repository";

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// cmux row status. Drafts are `open` with `Row.draft` set.
pub const Status = enum {
    open,
    closed,
    merged,

    /// Tie-break rank when two observations of one PR are equally fresh.
    pub fn rank(self: Status) u8 {
        return switch (self) {
            .open => 1,
            .closed => 2,
            .merged => 3,
        };
    }

    /// Lowercase word used in row text, `--state=` and JSON (`open`).
    pub fn word(self: Status) []const u8 {
        return @tagName(self);
    }

    /// From gh's `state` (`OPEN`, `CLOSED`, `MERGED`; case-insensitive) or
    /// cmux's lowercase words.
    pub fn parse(s: []const u8) ?Status {
        if (std.ascii.eqlIgnoreCase(s, "open")) return .open;
        if (std.ascii.eqlIgnoreCase(s, "closed")) return .closed;
        if (std.ascii.eqlIgnoreCase(s, "merged")) return .merged;
        return null;
    }
};

pub const ReviewDecision = enum {
    none,
    approved,
    changes_requested,
    review_required,

    pub fn parse(s: []const u8) ReviewDecision {
        if (std.ascii.eqlIgnoreCase(s, "APPROVED")) return .approved;
        if (std.ascii.eqlIgnoreCase(s, "CHANGES_REQUESTED")) return .changes_requested;
        if (std.ascii.eqlIgnoreCase(s, "REVIEW_REQUIRED")) return .review_required;
        return .none;
    }
};

pub const ChecksState = enum { none, pending, passing, failing };

/// Summary of `statusCheckRollup`.
pub const Checks = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    pending: u32 = 0,

    /// Any failure wins, then any pending check, then passing.
    pub fn state(self: Checks) ChecksState {
        if (self.failed > 0) return .failing;
        if (self.pending > 0) return .pending;
        if (self.total > 0) return .passing;
        return .none;
    }
};

/// Where a row came from.
pub const Source = enum {
    /// Automatic `gh` detection for a pane's branch.
    pane,
    /// Shell-integration `report_pr`.
    report,
    /// Manual workspace link (`cmux pr`); ordered after the others.
    manual,
};

/// One pull-request row. All slices are owned by the row.
pub const Row = struct {
    number: u32,
    status: Status,
    draft: bool = false,
    label: []u8,
    url: []u8,
    title: []u8,
    branch: []u8,
    review: ReviewDecision = .none,
    checks: Checks = .{},
    stale: bool = false,
    source: Source = .pane,
    /// Caller clock (ms) when this state was observed; fresher wins.
    observed_ms: i64 = 0,

    pub fn deinit(self: *Row, gpa: Allocator) void {
        gpa.free(self.label);
        gpa.free(self.url);
        gpa.free(self.title);
        gpa.free(self.branch);
        self.* = undefined;
    }

    pub fn clone(self: *const Row, gpa: Allocator) Allocator.Error!Row {
        var r = self.*;
        r.label = try gpa.dupe(u8, self.label);
        errdefer gpa.free(r.label);
        r.url = try gpa.dupe(u8, self.url);
        errdefer gpa.free(r.url);
        r.title = try gpa.dupe(u8, self.title);
        errdefer gpa.free(r.title);
        r.branch = try gpa.dupe(u8, self.branch);
        return r;
    }

    /// Row text: `PR #42 open`.
    pub fn format(self: *const Row, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} #{d} {s}", .{ self.label, self.number, self.status.word() });
    }

    /// Click tooltip: `Open PR #42`.
    pub fn writeTooltip(self: *const Row, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Open {s} #{d}", .{ self.label, self.number });
    }
};

// ---------------------------------------------------------------------------
// gh pr view
// ---------------------------------------------------------------------------

pub const ParseError = Allocator.Error || error{ NotJson, MissingField, InvalidField };

/// Largest prefix of `s` that is at most `max` bytes and does not split a
/// UTF-8 sequence.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn dupeCapped(gpa: Allocator, s: []const u8, max: usize) Allocator.Error![]u8 {
    return gpa.dupe(u8, truncateUtf8(s, max));
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn positiveU32(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |i| if (i > 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

/// Parse `gh pr view --json number,state,isDraft,url,title,headRefName,
/// reviewDecision,statusCheckRollup` stdout. `number`, `state` and `url`
/// are required; the rest default. Unknown fields are ignored.
pub fn parseView(gpa: Allocator, bytes: []const u8) ParseError!Row {
    const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return error.NotJson;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotJson,
    };

    const number = positiveU32(obj.get("number") orelse return error.MissingField) orelse
        return error.InvalidField;
    const state_str = getString(obj, "state") orelse return error.MissingField;
    const status = Status.parse(state_str) orelse return error.InvalidField;
    const url = getString(obj, "url") orelse return error.MissingField;
    if (url.len == 0) return error.InvalidField;

    const draft = if (obj.get("isDraft")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;
    const review = if (getString(obj, "reviewDecision")) |s| ReviewDecision.parse(s) else .none;
    const checks = if (obj.get("statusCheckRollup")) |v| summarizeRollup(v) else Checks{};

    const label = try gpa.dupe(u8, default_label);
    errdefer gpa.free(label);
    const url_owned = try dupeCapped(gpa, url, max_url_bytes);
    errdefer gpa.free(url_owned);
    const title = try dupeCapped(gpa, getString(obj, "title") orelse "", max_title_bytes);
    errdefer gpa.free(title);
    const branch = try dupeCapped(gpa, getString(obj, "headRefName") orelse "", max_branch_bytes);

    return .{
        .number = number,
        .status = status,
        .draft = draft and status == .open,
        .label = label,
        .url = url_owned,
        .title = title,
        .branch = branch,
        .review = review,
        .checks = checks,
    };
}

const CheckOutcome = enum { passed, failed, pending, ignored };

fn classifyCheck(obj: std.json.ObjectMap) CheckOutcome {
    // StatusContext: `state` = SUCCESS | FAILURE | ERROR | PENDING | EXPECTED.
    if (getString(obj, "state")) |s| {
        if (std.ascii.eqlIgnoreCase(s, "SUCCESS")) return .passed;
        if (std.ascii.eqlIgnoreCase(s, "FAILURE") or std.ascii.eqlIgnoreCase(s, "ERROR")) return .failed;
        if (std.ascii.eqlIgnoreCase(s, "PENDING") or std.ascii.eqlIgnoreCase(s, "EXPECTED")) return .pending;
        return .ignored;
    }
    // CheckRun: `status` != COMPLETED is pending; else by `conclusion`.
    const status = getString(obj, "status") orelse return .ignored;
    if (!std.ascii.eqlIgnoreCase(status, "COMPLETED")) return .pending;
    const c = getString(obj, "conclusion") orelse return .pending;
    const failing = [_][]const u8{ "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE" };
    for (failing) |f| if (std.ascii.eqlIgnoreCase(c, f)) return .failed;
    const passing = [_][]const u8{ "SUCCESS", "NEUTRAL", "SKIPPED", "STALE" };
    for (passing) |p| if (std.ascii.eqlIgnoreCase(c, p)) return .passed;
    if (c.len == 0) return .pending;
    return .ignored;
}

/// Summarize a `statusCheckRollup` array (CheckRun and StatusContext items).
/// Non-array input and non-object items yield no checks.
pub fn summarizeRollup(v: std.json.Value) Checks {
    var c: Checks = .{};
    const arr = switch (v) {
        .array => |a| a,
        else => return c,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        switch (classifyCheck(obj)) {
            .passed => c.passed +|= 1,
            .failed => c.failed +|= 1,
            .pending => c.pending +|= 1,
            .ignored => continue,
        }
        c.total +|= 1;
    }
    return c;
}

/// Why a `gh pr view` probe produced no row, from its stderr.
pub const ProbeFailure = enum {
    /// The branch has no PR: clear pane-derived rows, not a refresh failure.
    no_pull_request,
    /// gh is not logged in: stop probing until settings/auth change.
    not_authenticated,
    /// The directory is not a GitHub repository: not a refresh failure.
    not_a_repository,
    /// Anything else (network, rate limit): counts toward staleness.
    other,
};

pub fn classifyFailure(stderr: []const u8) ProbeFailure {
    if (containsIgnoreCase(stderr, "no pull requests found") or
        containsIgnoreCase(stderr, "no open pull requests")) return .no_pull_request;
    if (containsIgnoreCase(stderr, "gh auth login") or
        containsIgnoreCase(stderr, "not logged in") or
        containsIgnoreCase(stderr, "authentication")) return .not_authenticated;
    if (containsIgnoreCase(stderr, "not a git repository") or
        containsIgnoreCase(stderr, "no git remotes found") or
        containsIgnoreCase(stderr, "none of the git remotes")) return .not_a_repository;
    return .other;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// Per-row refresh bookkeeping: a PR whose state cannot be confirmed after
/// `stale_after_failures` consecutive failed refreshes is stale.
pub const RefreshTracker = struct {
    failures: u8 = 0,

    pub fn onSuccess(self: *RefreshTracker) void {
        self.failures = 0;
    }

    /// Returns whether the row is now stale.
    pub fn onFailure(self: *RefreshTracker) bool {
        self.failures +|= 1;
        return self.stale();
    }

    pub fn stale(self: RefreshTracker) bool {
        return self.failures >= stale_after_failures;
    }
};

// ---------------------------------------------------------------------------
// URL normalization and row merging
// ---------------------------------------------------------------------------

/// Dedup key for a PR URL: lowercase scheme and host, `http` folded into
/// `https`, `www.` dropped, query and fragment dropped, trailing slashes
/// and a trailing `/files`, `/commits`, `/checks` view suffix removed.
/// Path case is kept. Caller owns the result.
pub fn normalizeUrl(gpa: Allocator, url: []const u8) Allocator.Error![]u8 {
    var u = std.mem.trim(u8, url, &std.ascii.whitespace);
    if (std.mem.indexOfAny(u8, u, "?#")) |q| u = u[0..q];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var rest = u;
    if (std.mem.indexOf(u8, u, "://")) |sch| {
        const scheme = u[0..sch];
        try out.appendSlice(gpa, if (std.ascii.eqlIgnoreCase(scheme, "http")) "https" else scheme);
        for (out.items) |*c| c.* = std.ascii.toLower(c.*);
        try out.appendSlice(gpa, "://");
        rest = u[sch + 3 ..];
        const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var host = rest[0..host_end];
        if (host.len > 4 and std.ascii.eqlIgnoreCase(host[0..4], "www.")) host = host[4..];
        for (host) |c| try out.append(gpa, std.ascii.toLower(c));
        rest = rest[host_end..];
    }
    var path = std.mem.trimRight(u8, rest, "/");
    for ([_][]const u8{ "/files", "/commits", "/checks" }) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) {
            path = std.mem.trimRight(u8, path[0 .. path.len - suffix.len], "/");
            break;
        }
    }
    try out.appendSlice(gpa, path);
    return out.toOwnedSlice(gpa);
}

/// True when `a` should replace `b` as the row for one PR: fresher wins,
/// then the higher status.
fn wins(a: *const Row, b: *const Row) bool {
    if (a.observed_ms != b.observed_ms) return a.observed_ms > b.observed_ms;
    return a.status.rank() > b.status.rank();
}

/// Deduplicate `rows` in place by normalized URL. The winner of each group
/// takes the position of the group's first row; losers are freed. Groups
/// made only of manual links are then moved (stably) after the others; a
/// group that has any pane-derived or reported member stays in the first
/// part even when a manual observation wins it.
pub fn mergeRows(gpa: Allocator, rows: *std.ArrayList(Row)) Allocator.Error!void {
    const n = rows.items.len;
    if (n == 0) return;
    const keys = try gpa.alloc([]u8, n);
    var made: usize = 0;
    defer {
        for (keys[0..made]) |k| gpa.free(k);
        gpa.free(keys);
    }
    for (rows.items, 0..) |r, i| {
        keys[i] = try normalizeUrl(gpa, r.url);
        made += 1;
    }
    const explicit_only = try gpa.alloc(bool, n);
    defer gpa.free(explicit_only);

    // Compact: `w` is the write index; `kept_keys[j]` maps kept slot j to its key.
    const kept_keys = try gpa.alloc(usize, n);
    defer gpa.free(kept_keys);
    var w: usize = 0;
    for (0..n) |i| {
        var cur = rows.items[i];
        const dup: ?usize = for (0..w) |j| {
            if (std.mem.eql(u8, keys[kept_keys[j]], keys[i])) break j;
        } else null;
        if (dup) |j| {
            explicit_only[j] = explicit_only[j] and cur.source == .manual;
            if (wins(&cur, &rows.items[j])) {
                rows.items[j].deinit(gpa);
                rows.items[j] = cur;
            } else {
                cur.deinit(gpa);
            }
        } else {
            rows.items[w] = cur;
            explicit_only[w] = cur.source == .manual;
            kept_keys[w] = i;
            w += 1;
        }
    }
    rows.shrinkRetainingCapacity(w);

    // Stable partition: non-explicit groups first.
    const tmp = try gpa.alloc(Row, w);
    defer gpa.free(tmp);
    var t: usize = 0;
    for (rows.items, 0..) |r, i| if (!explicit_only[i]) {
        tmp[t] = r;
        t += 1;
    };
    for (rows.items, 0..) |r, i| if (explicit_only[i]) {
        tmp[t] = r;
        t += 1;
    };
    @memcpy(rows.items, tmp);
}

// ---------------------------------------------------------------------------
// cmux pr selector and repository checks
// ---------------------------------------------------------------------------

pub const PrUrl = struct {
    /// Slices of the input.
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    number: u32,
};

pub const Selector = union(enum) {
    number: u32,
    url: PrUrl,
};

/// Parse the `cmux pr <url|number>` argument: a positive number (leading
/// `#` accepted) or `http(s)://<host>/<owner>/<repo>/pull/<n>[/...]`. Any
/// other input is `error.InvalidSelector` (report `invalid_selector_message`).
pub fn parseSelector(arg: []const u8) error{InvalidSelector}!Selector {
    const s = std.mem.trim(u8, arg, &std.ascii.whitespace);
    if (s.len == 0) return error.InvalidSelector;
    const digits = if (s[0] == '#') s[1..] else s;
    if (digits.len > 0 and std.ascii.isDigit(digits[0])) {
        return .{ .number = parsePositive(digits) orelse return error.InvalidSelector };
    }
    return .{ .url = parsePrUrl(s) orelse return error.InvalidSelector };
}

fn parsePositive(s: []const u8) ?u32 {
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return if (n == 0) null else n;
}

/// Parse a pull-request URL. Query and fragment are ignored.
pub fn parsePrUrl(url: []const u8) ?PrUrl {
    var u = url;
    if (std.mem.indexOfAny(u8, u, "?#")) |q| u = u[0..q];
    const sch = std.mem.indexOf(u8, u, "://") orelse return null;
    const scheme = u[0..sch];
    if (!std.ascii.eqlIgnoreCase(scheme, "https") and !std.ascii.eqlIgnoreCase(scheme, "http")) return null;
    var parts = std.mem.splitScalar(u8, u[sch + 3 ..], '/');
    const host = parts.next() orelse return null;
    const owner = parts.next() orelse return null;
    const repo = parts.next() orelse return null;
    const pull = parts.next() orelse return null;
    const num = parts.next() orelse return null;
    if (host.len == 0 or owner.len == 0 or repo.len == 0) return null;
    if (!std.mem.eql(u8, pull, "pull")) return null;
    return .{
        .host = host,
        .owner = owner,
        .repo = repo,
        .number = parsePositive(num) orelse return null,
    };
}

/// `gh repo view --json nameWithOwner,url,parent`. Owned strings.
pub const RepoInfo = struct {
    /// `owner/name`.
    name_with_owner: []u8,
    /// Lowercase host of `url` (`github.com`).
    host: []u8,
    /// Parent repository `owner/name` for forks.
    parent: ?[]u8 = null,

    pub fn deinit(self: *RepoInfo, gpa: Allocator) void {
        gpa.free(self.name_with_owner);
        gpa.free(self.host);
        if (self.parent) |p| gpa.free(p);
        self.* = undefined;
    }

    /// cmux requires the repository to be hosted on github.com.
    pub fn isGitHubDotCom(self: *const RepoInfo) bool {
        return std.mem.eql(u8, self.host, "github.com");
    }
};

fn parentName(gpa: Allocator, v: std.json.Value) Allocator.Error!?[]u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    if (getString(obj, "nameWithOwner")) |nwo| if (nwo.len > 0) return try gpa.dupe(u8, nwo);
    const name = getString(obj, "name") orelse return null;
    const owner_v = obj.get("owner") orelse return null;
    const login = switch (owner_v) {
        .object => |o| getString(o, "login") orelse return null,
        else => return null,
    };
    if (name.len == 0 or login.len == 0) return null;
    return try std.mem.concat(gpa, u8, &.{ login, "/", name });
}

pub fn parseRepoView(gpa: Allocator, bytes: []const u8) ParseError!RepoInfo {
    const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return error.NotJson;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotJson,
    };
    const nwo = getString(obj, "nameWithOwner") orelse return error.MissingField;
    if (std.mem.indexOfScalar(u8, nwo, '/') == null) return error.InvalidField;
    const url = getString(obj, "url") orelse return error.MissingField;
    const sch = std.mem.indexOf(u8, url, "://") orelse return error.InvalidField;
    const after = url[sch + 3 ..];
    const host = after[0 .. std.mem.indexOfScalar(u8, after, '/') orelse after.len];
    if (host.len == 0) return error.InvalidField;

    const nwo_owned = try gpa.dupe(u8, nwo);
    errdefer gpa.free(nwo_owned);
    const host_owned = try std.ascii.allocLowerString(gpa, host);
    errdefer gpa.free(host_owned);
    const parent = if (obj.get("parent")) |p| try parentName(gpa, p) else null;
    return .{ .name_with_owner = nwo_owned, .host = host_owned, .parent = parent };
}

fn sameRepo(owner: []const u8, repo: []const u8, nwo: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, nwo, '/') orelse return false;
    var r = repo;
    if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - 4];
    return std.ascii.eqlIgnoreCase(owner, nwo[0..slash]) and std.ascii.eqlIgnoreCase(r, nwo[slash + 1 ..]);
}

/// Whether `sel` belongs to `repo` or its parent. Numbers always do (they
/// are looked up in the detected repository); URLs must match host and
/// owner/name (case-insensitive). Otherwise report `foreign_repo_message`.
pub fn belongsToRepo(sel: Selector, repo: *const RepoInfo) bool {
    const u = switch (sel) {
        .number => return true,
        .url => |u| u,
    };
    var host = u.host;
    if (host.len > 4 and std.ascii.eqlIgnoreCase(host[0..4], "www.")) host = host[4..];
    if (!std.ascii.eqlIgnoreCase(host, repo.host)) return false;
    if (sameRepo(u.owner, u.repo, repo.name_with_owner)) return true;
    if (repo.parent) |p| return sameRepo(u.owner, u.repo, p);
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixture_open =
    \\{
    \\  "headRefName": "feat/sidebar-ports",
    \\  "isDraft": false,
    \\  "number": 42,
    \\  "reviewDecision": "REVIEW_REQUIRED",
    \\  "state": "OPEN",
    \\  "statusCheckRollup": [
    \\    {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
    \\    {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SKIPPED"},
    \\    {"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS", "conclusion": ""},
    \\    {"__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS"}
    \\  ],
    \\  "title": "Add listening-port chips",
    \\  "url": "https://github.com/acme/wmux/pull/42"
    \\}
    \\
;

fn testRow(gpa: Allocator, url: []const u8, status: Status, source: Source, observed_ms: i64) !Row {
    return .{
        .number = 1,
        .status = status,
        .label = try gpa.dupe(u8, default_label),
        .url = try gpa.dupe(u8, url),
        .title = try gpa.dupe(u8, ""),
        .branch = try gpa.dupe(u8, ""),
        .source = source,
        .observed_ms = observed_ms,
    };
}

fn freeRows(gpa: Allocator, rows: *std.ArrayList(Row)) void {
    for (rows.items) |*r| r.deinit(gpa);
    rows.deinit(gpa);
}

test "unit: meta: gh_pr parseView open PR with checks and review" {
    const gpa = testing.allocator;
    var row = try parseView(gpa, fixture_open);
    defer row.deinit(gpa);
    try testing.expectEqual(@as(u32, 42), row.number);
    try testing.expectEqual(Status.open, row.status);
    try testing.expect(!row.draft);
    try testing.expectEqualStrings("PR", row.label);
    try testing.expectEqualStrings("https://github.com/acme/wmux/pull/42", row.url);
    try testing.expectEqualStrings("Add listening-port chips", row.title);
    try testing.expectEqualStrings("feat/sidebar-ports", row.branch);
    try testing.expectEqual(ReviewDecision.review_required, row.review);
    try testing.expectEqual(@as(u32, 4), row.checks.total);
    try testing.expectEqual(@as(u32, 3), row.checks.passed);
    try testing.expectEqual(@as(u32, 1), row.checks.pending);
    try testing.expectEqual(ChecksState.pending, row.checks.state());
    try testing.expect(!row.stale);
}

test "unit: meta: gh_pr row text and tooltip" {
    const gpa = testing.allocator;
    var row = try parseView(gpa, fixture_open);
    defer row.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("{f}", .{row});
    try testing.expectEqualStrings("PR #42 open", aw.written());
    aw.clearRetainingCapacity();
    try row.writeTooltip(&aw.writer);
    try testing.expectEqualStrings("Open PR #42", aw.written());
}

test "unit: meta: gh_pr parseView merged, closed and draft states" {
    const gpa = testing.allocator;
    {
        var r = try parseView(gpa, "{\"number\":9,\"state\":\"MERGED\",\"isDraft\":false,\"url\":\"u\",\"reviewDecision\":\"APPROVED\"}");
        defer r.deinit(gpa);
        try testing.expectEqual(Status.merged, r.status);
        try testing.expectEqual(ReviewDecision.approved, r.review);
        try testing.expectEqual(ChecksState.none, r.checks.state());
    }
    {
        var r = try parseView(gpa, "{\"number\":3,\"state\":\"CLOSED\",\"isDraft\":true,\"url\":\"u\"}");
        defer r.deinit(gpa);
        try testing.expectEqual(Status.closed, r.status);
        // Draft only qualifies open PRs.
        try testing.expect(!r.draft);
    }
    {
        var r = try parseView(gpa, "{\"number\":7,\"state\":\"open\",\"isDraft\":true,\"url\":\"u\",\"reviewDecision\":null,\"statusCheckRollup\":null,\"title\":null}");
        defer r.deinit(gpa);
        try testing.expectEqual(Status.open, r.status);
        try testing.expect(r.draft);
        try testing.expectEqual(ReviewDecision.none, r.review);
        try testing.expectEqualStrings("", r.title);
        try testing.expectEqualStrings("", r.branch);
    }
}

test "unit: meta: gh_pr parseView rejects malformed output" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotJson, parseView(gpa, ""));
    try testing.expectError(error.NotJson, parseView(gpa, "no pull requests found for branch \"main\""));
    try testing.expectError(error.NotJson, parseView(gpa, "{\"number\":1,"));
    try testing.expectError(error.NotJson, parseView(gpa, "[1,2]"));
    try testing.expectError(error.MissingField, parseView(gpa, "{\"state\":\"OPEN\",\"url\":\"u\"}"));
    try testing.expectError(error.MissingField, parseView(gpa, "{\"number\":1,\"url\":\"u\"}"));
    try testing.expectError(error.MissingField, parseView(gpa, "{\"number\":1,\"state\":\"OPEN\"}"));
    try testing.expectError(error.InvalidField, parseView(gpa, "{\"number\":0,\"state\":\"OPEN\",\"url\":\"u\"}"));
    try testing.expectError(error.InvalidField, parseView(gpa, "{\"number\":-4,\"state\":\"OPEN\",\"url\":\"u\"}"));
    try testing.expectError(error.InvalidField, parseView(gpa, "{\"number\":5000000000,\"state\":\"OPEN\",\"url\":\"u\"}"));
    try testing.expectError(error.InvalidField, parseView(gpa, "{\"number\":\"1\",\"state\":\"OPEN\",\"url\":\"u\"}"));
    try testing.expectError(error.InvalidField, parseView(gpa, "{\"number\":1,\"state\":\"WEIRD\",\"url\":\"u\"}"));
    try testing.expectError(error.InvalidField, parseView(gpa, "{\"number\":1,\"state\":\"OPEN\",\"url\":\"\"}"));
}

test "unit: meta: gh_pr parseView caps huge unicode titles on code-point boundaries" {
    const gpa = testing.allocator;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"number\":1,\"state\":\"OPEN\",\"url\":\"u\",\"title\":\"a");
    // 3-byte code points after a 1-byte prefix: the cap falls mid-sequence.
    for (0..1000) |_| try json.appendSlice(gpa, "日");
    try json.appendSlice(gpa, "\"}");
    var r = try parseView(gpa, json.items);
    defer r.deinit(gpa);
    try testing.expect(r.title.len <= max_title_bytes);
    try testing.expect(r.title.len > max_title_bytes - 4);
    try testing.expect(std.unicode.utf8ValidateSlice(r.title));
}

test "unit: meta: gh_pr summarizeRollup classifies failures first" {
    const gpa = testing.allocator;
    const json =
        \\[{"status":"COMPLETED","conclusion":"SUCCESS"},
        \\ {"status":"QUEUED"},
        \\ {"status":"COMPLETED","conclusion":"TIMED_OUT"},
        \\ {"state":"ERROR"},
        \\ {"state":"EXPECTED"},
        \\ {"status":"COMPLETED","conclusion":"MYSTERY"},
        \\ 7, "x", null]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const c = summarizeRollup(parsed.value);
    try testing.expectEqual(@as(u32, 5), c.total);
    try testing.expectEqual(@as(u32, 1), c.passed);
    try testing.expectEqual(@as(u32, 2), c.failed);
    try testing.expectEqual(@as(u32, 2), c.pending);
    try testing.expectEqual(ChecksState.failing, c.state());
    try testing.expectEqual(ChecksState.passing, (Checks{ .total = 2, .passed = 2 }).state());
    try testing.expectEqual(ChecksState.none, summarizeRollup(.{ .integer = 3 }).state());
}

test "unit: meta: gh_pr classifyFailure maps gh stderr" {
    try testing.expectEqual(ProbeFailure.no_pull_request, classifyFailure("no pull requests found for branch \"main\"\n"));
    try testing.expectEqual(ProbeFailure.not_authenticated, classifyFailure("To get started with GitHub CLI, please run:  gh auth login"));
    try testing.expectEqual(ProbeFailure.not_a_repository, classifyFailure("failed to run git: fatal: not a git repository (or any of the parent directories): .git"));
    try testing.expectEqual(ProbeFailure.other, classifyFailure("HTTP 502: Bad Gateway"));
    try testing.expectEqual(ProbeFailure.other, classifyFailure(""));
}

test "unit: meta: gh_pr RefreshTracker marks stale after repeated failures" {
    var t: RefreshTracker = .{};
    try testing.expect(!t.onFailure());
    try testing.expect(!t.onFailure());
    try testing.expect(t.onFailure());
    t.onSuccess();
    try testing.expect(!t.stale());
    for (0..1000) |_| _ = t.onFailure();
    try testing.expect(t.stale());
}

test "unit: meta: gh_pr normalizeUrl folds equivalent PR URLs" {
    const gpa = testing.allocator;
    const want = "https://github.com/acme/wmux/pull/42";
    const variants = [_][]const u8{
        "https://github.com/acme/wmux/pull/42",
        "HTTP://GitHub.com/acme/wmux/pull/42/",
        "https://www.github.com/acme/wmux/pull/42/files?w=1#diff",
        "  https://github.com/acme/wmux/pull/42/commits  ",
    };
    for (variants) |v| {
        const got = try normalizeUrl(gpa, v);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
    const plain = try normalizeUrl(gpa, "not a url/");
    defer gpa.free(plain);
    try testing.expectEqualStrings("not a url", plain);
    const empty = try normalizeUrl(gpa, "");
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "unit: meta: gh_pr mergeRows dedups by URL, fresher then higher status" {
    const gpa = testing.allocator;
    var rows: std.ArrayList(Row) = .empty;
    defer freeRows(gpa, &rows);
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/1", .open, .pane, 100));
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/2", .open, .pane, 100));
    // Fresher observation of #1 wins even with a lower status rank.
    try rows.append(gpa, try testRow(gpa, "http://github.com/a/b/pull/1/", .open, .report, 200));
    // Same freshness: merged beats open.
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/2#x", .merged, .pane, 100));
    try mergeRows(gpa, &rows);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("http://github.com/a/b/pull/1/", rows.items[0].url);
    try testing.expectEqual(@as(i64, 200), rows.items[0].observed_ms);
    try testing.expectEqual(Status.merged, rows.items[1].status);
}

test "unit: meta: gh_pr mergeRows orders explicit links after pane-derived" {
    const gpa = testing.allocator;
    var rows: std.ArrayList(Row) = .empty;
    defer freeRows(gpa, &rows);
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/9", .open, .manual, 0));
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/5", .open, .pane, 0));
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/7", .open, .manual, 0));
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/6", .open, .pane, 0));
    // A manual link duplicating a pane PR keeps the group pane-derived.
    try rows.append(gpa, try testRow(gpa, "https://github.com/a/b/pull/6", .closed, .manual, 5));
    try mergeRows(gpa, &rows);
    try testing.expectEqual(@as(usize, 4), rows.items.len);
    try testing.expectEqualStrings("https://github.com/a/b/pull/5", rows.items[0].url);
    try testing.expectEqualStrings("https://github.com/a/b/pull/6", rows.items[1].url);
    try testing.expectEqual(Status.closed, rows.items[1].status);
    try testing.expectEqualStrings("https://github.com/a/b/pull/9", rows.items[2].url);
    try testing.expectEqualStrings("https://github.com/a/b/pull/7", rows.items[3].url);
}

test "unit: meta: gh_pr mergeRows on empty and single lists" {
    const gpa = testing.allocator;
    var rows: std.ArrayList(Row) = .empty;
    defer freeRows(gpa, &rows);
    try mergeRows(gpa, &rows);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
    try rows.append(gpa, try testRow(gpa, "u", .open, .manual, 0));
    try mergeRows(gpa, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
}

test "unit: meta: gh_pr Row.clone deep-copies" {
    const gpa = testing.allocator;
    var a = try parseView(gpa, fixture_open);
    defer a.deinit(gpa);
    var b = try a.clone(gpa);
    defer b.deinit(gpa);
    try testing.expect(a.url.ptr != b.url.ptr);
    try testing.expectEqualStrings(a.title, b.title);
}

test "unit: meta: gh_pr parseSelector numbers and URLs" {
    try testing.expectEqual(@as(u32, 123), (try parseSelector("123")).number);
    try testing.expectEqual(@as(u32, 123), (try parseSelector(" #123 ")).number);
    const u = (try parseSelector("https://github.com/acme/wmux/pull/77/files?x=1")).url;
    try testing.expectEqualStrings("github.com", u.host);
    try testing.expectEqualStrings("acme", u.owner);
    try testing.expectEqualStrings("wmux", u.repo);
    try testing.expectEqual(@as(u32, 77), u.number);
    const bad = [_][]const u8{
        "",
        "#",
        "0",
        "#0",
        "-1",
        "12a",
        "4294967296",
        "main",
        "日本",
        "https://github.com/acme/wmux/issues/1",
        "https://github.com/acme/wmux",
        "ftp://github.com/a/b/pull/1",
        "https://github.com/acme/wmux/pull/",
        "https://github.com/acme/wmux/pull/0",
    };
    for (bad) |b| try testing.expectError(error.InvalidSelector, parseSelector(b));
    try testing.expectEqualStrings(
        "cmux pr expects a pull-request URL or a positive pull-request number",
        invalid_selector_message,
    );
}

test "unit: meta: gh_pr parseRepoView and belongsToRepo" {
    const gpa = testing.allocator;
    var repo = try parseRepoView(gpa,
        \\{"nameWithOwner":"me/wmux","url":"https://GitHub.com/me/wmux",
        \\ "parent":{"id":"R_1","name":"wmux","owner":{"id":"U_1","login":"acme"}}}
    );
    defer repo.deinit(gpa);
    try testing.expectEqualStrings("me/wmux", repo.name_with_owner);
    try testing.expectEqualStrings("github.com", repo.host);
    try testing.expectEqualStrings("acme/wmux", repo.parent.?);
    try testing.expect(repo.isGitHubDotCom());

    try testing.expect(belongsToRepo(.{ .number = 5 }, &repo));
    try testing.expect(belongsToRepo(try parseSelector("https://github.com/ME/wmux/pull/1"), &repo));
    try testing.expect(belongsToRepo(try parseSelector("https://www.github.com/acme/wmux/pull/2"), &repo));
    try testing.expect(!belongsToRepo(try parseSelector("https://github.com/other/wmux/pull/3"), &repo));
    try testing.expect(!belongsToRepo(try parseSelector("https://gitlab.com/me/wmux/pull/3"), &repo));
    try testing.expectEqualStrings(
        "cmux pr: the pull request does not belong to the detected repository",
        foreign_repo_message,
    );
}

test "unit: meta: gh_pr parseRepoView without parent and malformed input" {
    const gpa = testing.allocator;
    var repo = try parseRepoView(gpa, "{\"nameWithOwner\":\"a/b\",\"url\":\"https://ghe.corp/a/b\",\"parent\":null}");
    defer repo.deinit(gpa);
    try testing.expect(repo.parent == null);
    try testing.expect(!repo.isGitHubDotCom());
    try testing.expectError(error.NotJson, parseRepoView(gpa, "oops"));
    try testing.expectError(error.MissingField, parseRepoView(gpa, "{\"url\":\"https://github.com/a/b\"}"));
    try testing.expectError(error.InvalidField, parseRepoView(gpa, "{\"nameWithOwner\":\"ab\",\"url\":\"https://github.com/a/b\"}"));
    try testing.expectError(error.InvalidField, parseRepoView(gpa, "{\"nameWithOwner\":\"a/b\",\"url\":\"github.com/a/b\"}"));
}
