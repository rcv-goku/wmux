//! Git metadata parsers for the `branch_dir` sidebar contributor (ADR-11.3,
//! W2-6). Pure: every function takes bytes the caller already read (the
//! `.git` file, `commondir`, `HEAD`, `git status --porcelain=v2 --branch`
//! stdout) or a caller-supplied `Fs` view; nothing here touches the file
//! system or spawns processes.
//!
//! Repository discovery mirrors git's own rules for the cases wmux needs:
//! - `<dir>/.git` is a directory: `dir` is the worktree root and the git
//!   dir is `<dir>/.git`.
//! - `<dir>/.git` is a file `gitdir: <path>` (linked worktree, submodule):
//!   the git dir is `<path>`, resolved relative to `dir` when relative.
//! - `<gitdir>/commondir` (linked worktrees only) names the shared git dir,
//!   relative to the git dir when relative. Refs and packed-refs live there;
//!   `HEAD` and `index` stay per-worktree in the git dir.
//!
//! Paths accept both `/` and `\` separators, Windows drive roots (`C:\`)
//! and UNC roots (`\\server\share\`). Results use `\` when the input looks
//! like a Windows path and `/` otherwise.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Probe command
// ---------------------------------------------------------------------------

/// argv for the bounded status probe, run with cwd = the pane directory.
/// `--no-optional-locks` keeps the probe from taking `index.lock`, which
/// would otherwise race with the user's own git commands.
pub const status_argv = [_][]const u8{ "git", "--no-optional-locks", "status", "--porcelain=v2", "--branch" };

/// Cap on captured probe stdout. Output beyond this is cut by the caller and
/// parsed with `.truncated = true` (huge dirty trees still read as dirty).
pub const status_max_output_bytes: usize = 256 * 1024;

/// Cap on bytes read from `.git`, `commondir` and `HEAD` files. Real files
/// are well under 1 KiB; anything larger is not a git pointer file.
pub const pointer_file_max_bytes: usize = 4096;

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Length of the root prefix of `p`: `/`, `\`, `C:`, `C:\`, `\\server\share\`.
/// 0 for a relative path.
fn rootLen(p: []const u8) usize {
    if (p.len >= 2 and isSep(p[0]) and isSep(p[1])) {
        // UNC: \\server\share\ (or //server/share/).
        var i: usize = 2;
        var parts: u8 = 0;
        while (i < p.len) : (i += 1) {
            if (isSep(p[i])) {
                parts += 1;
                if (parts == 2) return i + 1;
            }
        }
        return p.len;
    }
    if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') {
        if (p.len >= 3 and isSep(p[2])) return 3;
        return 2;
    }
    if (p.len >= 1 and isSep(p[0])) return 1;
    return 0;
}

/// True for `/x`, `\x`, `C:\x`, `C:/x` and UNC paths. A bare `C:x` is
/// drive-relative and treated as relative.
pub fn isAbsolute(p: []const u8) bool {
    const r = rootLen(p);
    if (r == 0) return false;
    if (r == 2 and p[1] == ':') return false;
    return true;
}

fn preferredSep(p: []const u8) u8 {
    if (std.mem.indexOfScalar(u8, p, '\\') != null) return '\\';
    if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') return '\\';
    return '/';
}

/// Lexically normalize `p`: unify separators to `sep`, drop `.` and empty
/// components, fold `..` (never above the root; leading `..` of a relative
/// path are kept). Never returns an empty string (`.` for an empty relative
/// result). Caller owns the result.
pub fn normalize(gpa: Allocator, p: []const u8, sep: u8) Allocator.Error![]u8 {
    const r = rootLen(p);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (p[0..r]) |c| try out.append(gpa, if (isSep(c)) sep else c);
    const root_end = out.items.len;
    // Number of leading `..` components kept in a relative path.
    var kept_up: usize = 0;
    var comps: usize = 0;

    var it = std.mem.tokenizeAny(u8, p[r..], "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (comps > kept_up) {
                // Pop the last component (and its separator).
                const at = std.mem.lastIndexOfScalar(u8, out.items[root_end..], sep);
                out.shrinkRetainingCapacity(if (at) |a| root_end + a else root_end);
                comps -= 1;
                continue;
            }
            if (r != 0) continue; // `..` above an absolute root is a no-op.
            kept_up += 1;
        }
        if (out.items.len > root_end) try out.append(gpa, sep);
        try out.appendSlice(gpa, comp);
        comps += 1;
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

/// Join `rel` onto `base` (unless `rel` is absolute) and normalize. The
/// separator follows `base` (or `rel` when absolute). Caller owns the result.
pub fn resolvePath(gpa: Allocator, base: []const u8, rel: []const u8) Allocator.Error![]u8 {
    if (isAbsolute(rel)) return normalize(gpa, rel, preferredSep(rel));
    const sep = preferredSep(base);
    // No second separator after a base that already ends in one (`/`, `\`,
    // `C:\`): `//x` and `\\x` would read as UNC roots. An empty base keeps
    // `rel` relative.
    const sep_buf = [1]u8{sep};
    const glue: []const u8 = if (base.len == 0 or isSep(base[base.len - 1])) "" else &sep_buf;
    const joined = try std.mem.concat(gpa, u8, &.{ base, glue, rel });
    defer gpa.free(joined);
    return normalize(gpa, joined, sep);
}

/// Parent of a normalized path, or null at the root (or for `.`).
pub fn parentDir(p: []const u8) ?[]const u8 {
    const r = rootLen(p);
    if (p.len <= r) return null;
    var end = p.len;
    while (end > r and isSep(p[end - 1])) end -= 1;
    while (end > r and !isSep(p[end - 1])) end -= 1;
    if (end == r) {
        if (r == 0) return null;
        return p[0..r];
    }
    return p[0 .. end - 1];
}

// ---------------------------------------------------------------------------
// Pointer files
// ---------------------------------------------------------------------------

fn trimLine(raw: []const u8) []const u8 {
    var t = raw;
    if (std.mem.startsWith(u8, t, "\xEF\xBB\xBF")) t = t[3..];
    // Only the first line counts; git ignores anything after it.
    if (std.mem.indexOfAny(u8, t, "\r\n")) |nl| t = t[0..nl];
    return std.mem.trim(u8, t, " \t");
}

/// Parse a `.git` file (`gitdir: <path>`). Returns the raw path (a slice of
/// `contents`), or null when malformed or empty.
pub fn parseDotGitFile(contents: []const u8) ?[]const u8 {
    const line = trimLine(contents);
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const path = std.mem.trim(u8, line[prefix.len..], " \t");
    if (path.len == 0) return null;
    return path;
}

/// Parse a `commondir` file. Returns the raw path (a slice of `contents`),
/// or null when empty.
pub fn parseCommondir(contents: []const u8) ?[]const u8 {
    const line = trimLine(contents);
    if (line.len == 0) return null;
    return line;
}

// ---------------------------------------------------------------------------
// Repository resolution
// ---------------------------------------------------------------------------

pub const EntryKind = enum { missing, file, dir };

/// Read-only file-system view supplied by the caller (the worker thread
/// wraps real I/O; tests use a map). `read` returns owned bytes (allocated
/// with `gpa`, at most `pointer_file_max_bytes`) or null on any error.
pub const Fs = struct {
    ctx: *anyopaque,
    kind: *const fn (ctx: *anyopaque, path: []const u8) EntryKind,
    read: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8,
};

/// Where a directory's repository lives. All paths are normalized and owned.
pub const RepoLocation = struct {
    /// Directory containing `.git` (the worktree root).
    worktree_root: []u8,
    /// Per-worktree git dir (holds `HEAD`, `index`).
    git_dir: []u8,
    /// Shared git dir (holds `refs/`, `packed-refs`); equals `git_dir` for
    /// the main worktree.
    common_dir: []u8,
    /// True when `git_dir` carries a `commondir` file (a linked worktree).
    linked_worktree: bool,

    pub fn deinit(self: *RepoLocation, gpa: Allocator) void {
        gpa.free(self.worktree_root);
        gpa.free(self.git_dir);
        gpa.free(self.common_dir);
        self.* = undefined;
    }

    /// Path of the per-worktree `HEAD` file. Caller owns the result.
    pub fn headPath(self: *const RepoLocation, gpa: Allocator) Allocator.Error![]u8 {
        return resolvePath(gpa, self.git_dir, "HEAD");
    }
};

pub const ResolveError = Allocator.Error || error{MalformedGitFile};

/// Resolve the repository from the `.git` entry found in `worktree_root`.
/// `dot_git_contents` is null when `.git` is a directory, else the bytes of
/// the `.git` file. `commondir_contents` is the bytes of
/// `<git_dir>/commondir`, or null when absent.
pub fn resolveFromDotGit(
    gpa: Allocator,
    worktree_root: []const u8,
    dot_git_contents: ?[]const u8,
    commondir_contents: ?[]const u8,
) ResolveError!RepoLocation {
    const root = try normalize(gpa, worktree_root, preferredSep(worktree_root));
    errdefer gpa.free(root);
    const git_dir = if (dot_git_contents) |c| blk: {
        const rel = parseDotGitFile(c) orelse return error.MalformedGitFile;
        break :blk try resolvePath(gpa, root, rel);
    } else try resolvePath(gpa, root, ".git");
    errdefer gpa.free(git_dir);

    const common_rel = if (commondir_contents) |c| parseCommondir(c) else null;
    const common_dir = if (common_rel) |rel|
        try resolvePath(gpa, git_dir, rel)
    else
        try gpa.dupe(u8, git_dir);

    return .{
        .worktree_root = root,
        .git_dir = git_dir,
        .common_dir = common_dir,
        .linked_worktree = common_rel != null,
    };
}

/// Walk from `cwd` up to the root looking for `.git` and resolve it through
/// `fs`. Returns null when no ancestor holds a usable `.git` entry. A
/// malformed `.git` file stops the walk (git does the same).
pub fn resolve(gpa: Allocator, cwd: []const u8, fs: Fs) Allocator.Error!?RepoLocation {
    if (cwd.len == 0) return null;
    const start = try normalize(gpa, cwd, preferredSep(cwd));
    defer gpa.free(start);

    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = parentDir(d)) {
        const dot_git = try resolvePath(gpa, d, ".git");
        defer gpa.free(dot_git);
        switch (fs.kind(fs.ctx, dot_git)) {
            .missing => continue,
            .dir => {
                const git_dir = try resolvePath(gpa, d, ".git");
                defer gpa.free(git_dir);
                return try resolveWithCommondir(gpa, d, null, git_dir, fs);
            },
            .file => {
                const contents = fs.read(fs.ctx, gpa, dot_git) orelse return null;
                defer gpa.free(contents);
                const rel = parseDotGitFile(contents) orelse return null;
                const git_dir = try resolvePath(gpa, d, rel);
                defer gpa.free(git_dir);
                return try resolveWithCommondir(gpa, d, contents, git_dir, fs);
            },
        }
    }
    return null;
}

fn resolveWithCommondir(
    gpa: Allocator,
    root: []const u8,
    dot_git_contents: ?[]const u8,
    git_dir: []const u8,
    fs: Fs,
) Allocator.Error!RepoLocation {
    const commondir_path = try resolvePath(gpa, git_dir, "commondir");
    defer gpa.free(commondir_path);
    const commondir = if (fs.kind(fs.ctx, commondir_path) == .file)
        fs.read(fs.ctx, gpa, commondir_path)
    else
        null;
    defer if (commondir) |c| gpa.free(c);
    return resolveFromDotGit(gpa, root, dot_git_contents, commondir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Already validated by the caller.
        error.MalformedGitFile => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Change filtering for the .git watcher
// ---------------------------------------------------------------------------

/// Whether a change notification for `rel` (a path relative to the git dir
/// or common dir, either separator) can change the branch, dirty state or
/// PR lookup: `HEAD`, `index`, `packed-refs`, `refs/**`. Lock files,
/// objects, logs and other bookkeeping are ignored.
pub fn isRelevantChange(rel: []const u8) bool {
    var p = rel;
    while (p.len > 0 and isSep(p[0])) p = p[1..];
    if (p.len == 0) return false;
    if (std.mem.endsWith(u8, p, ".lock")) return false;
    if (std.mem.eql(u8, p, "HEAD") or std.mem.eql(u8, p, "index") or std.mem.eql(u8, p, "packed-refs"))
        return true;
    return p.len > 5 and std.mem.eql(u8, p[0..4], "refs") and isSep(p[4]);
}

// ---------------------------------------------------------------------------
// HEAD
// ---------------------------------------------------------------------------

pub const Head = union(enum) {
    /// `ref: refs/heads/<name>`; payload is `<name>`.
    branch: []const u8,
    /// `ref: <other>` that is not under `refs/heads/`; payload is the full ref.
    other_ref: []const u8,
    /// A bare object id (SHA-1 or SHA-256 hex); payload is the full id.
    detached: []const u8,
};

fn isHexId(s: []const u8) bool {
    if (s.len != 40 and s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Parse a `HEAD` file. Payloads are slices of `contents`. Null when empty
/// or malformed.
pub fn parseHead(contents: []const u8) ?Head {
    const line = trimLine(contents);
    if (std.mem.startsWith(u8, line, "ref:")) {
        const ref = std.mem.trim(u8, line[4..], " \t");
        if (ref.len == 0) return null;
        const heads = "refs/heads/";
        if (std.mem.startsWith(u8, ref, heads) and ref.len > heads.len)
            return .{ .branch = ref[heads.len..] };
        return .{ .other_ref = ref };
    }
    if (isHexId(line)) return .{ .detached = line };
    return null;
}

/// Length of the abbreviated object id shown for a detached HEAD.
pub const short_sha_len: usize = 7;

/// Abbreviate an object id for display (`0123abc`).
pub fn shortSha(id: []const u8) []const u8 {
    return id[0..@min(id.len, short_sha_len)];
}

// ---------------------------------------------------------------------------
// git status --porcelain=v2 --branch
// ---------------------------------------------------------------------------

pub const Status = struct {
    /// `# branch.oid`: the commit id, or null for `(initial)` / absent.
    oid: ?[]const u8 = null,
    /// `# branch.head`: the branch name, or null when detached / absent.
    head: ?[]const u8 = null,
    detached: bool = false,
    /// `# branch.upstream`, when tracking.
    upstream: ?[]const u8 = null,
    /// `# branch.ab +A -B`; null when there is no upstream.
    ahead: ?u32 = null,
    behind: ?u32 = null,
    /// Entries with a staged change (X != '.').
    staged: u32 = 0,
    /// Entries with an unstaged change (Y != '.').
    unstaged: u32 = 0,
    /// `u` entries (merge conflicts).
    conflicted: u32 = 0,
    /// `?` entries.
    untracked: u32 = 0,
    /// `!` entries (only with --ignored; never dirty).
    ignored: u32 = 0,
    /// Changed tracked entries (`1`, `2`), counted once each.
    changed: u32 = 0,
    /// The input was cut at the output cap; counts are lower bounds.
    incomplete: bool = false,

    /// The sidebar dirty marker: any tracked change, conflict or untracked
    /// file. Ignored files never count.
    pub fn dirty(self: *const Status) bool {
        return self.changed > 0 or self.conflicted > 0 or self.untracked > 0;
    }

    /// Text shown for the branch: the branch name, else the short commit id
    /// when detached, else null.
    pub fn displayBranch(self: *const Status) ?[]const u8 {
        if (self.head) |h| return h;
        if (self.detached) if (self.oid) |o| return shortSha(o);
        return null;
    }
};

pub const StatusOptions = struct {
    /// The caller cut the output at `status_max_output_bytes`: the final
    /// unterminated record is dropped and `Status.incomplete` is set.
    truncated: bool = false,
};

fn sat(x: u32) u32 {
    return x +| 1;
}

/// Parse `git status --porcelain=v2 --branch` output (LF, CRLF or `-z` NUL
/// records). String fields are slices of `bytes`. Unknown and malformed
/// records are skipped, never fatal.
pub fn parseStatusV2(bytes: []const u8, opts: StatusOptions) Status {
    var st: Status = .{ .incomplete = opts.truncated };
    const nul_mode = std.mem.indexOfScalar(u8, bytes, 0) != null;
    const term: u8 = if (nul_mode) 0 else '\n';

    var body = bytes;
    if (opts.truncated) {
        if (std.mem.lastIndexOfScalar(u8, body, term)) |last| body = body[0 .. last + 1] else body = body[0..0];
    }

    var skip_next = false;
    var it = std.mem.splitScalar(u8, body, term);
    while (it.next()) |raw| {
        if (skip_next) {
            // `-z` rename/copy records carry the original path as a separate
            // record; it is a path, not an entry.
            skip_next = false;
            continue;
        }
        const rec = if (!nul_mode) std.mem.trimRight(u8, raw, "\r") else raw;
        if (rec.len < 2) continue;
        switch (rec[0]) {
            '#' => parseHeader(&st, rec),
            '1', '2' => {
                if (rec[1] != ' ' or rec.len < 4) continue;
                const x = rec[2];
                const y = rec[3];
                if (x != '.') st.staged = sat(st.staged);
                if (y != '.') st.unstaged = sat(st.unstaged);
                st.changed = sat(st.changed);
                if (rec[0] == '2' and nul_mode) skip_next = true;
            },
            'u' => {
                if (rec[1] == ' ') st.conflicted = sat(st.conflicted);
            },
            '?' => {
                if (rec[1] == ' ') st.untracked = sat(st.untracked);
            },
            '!' => {
                if (rec[1] == ' ') st.ignored = sat(st.ignored);
            },
            else => {},
        }
    }
    return st;
}

fn parseHeader(st: *Status, rec: []const u8) void {
    if (!std.mem.startsWith(u8, rec, "# branch.")) return;
    const rest = rec["# branch.".len..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const key = rest[0..sp];
    const val = rest[sp + 1 ..];
    if (val.len == 0) return;
    if (std.mem.eql(u8, key, "oid")) {
        st.oid = if (std.mem.eql(u8, val, "(initial)")) null else val;
    } else if (std.mem.eql(u8, key, "head")) {
        if (std.mem.eql(u8, val, "(detached)")) {
            st.detached = true;
            st.head = null;
        } else {
            st.detached = false;
            st.head = val;
        }
    } else if (std.mem.eql(u8, key, "upstream")) {
        st.upstream = val;
    } else if (std.mem.eql(u8, key, "ab")) {
        var parts = std.mem.tokenizeScalar(u8, val, ' ');
        const a = parts.next() orelse return;
        const b = parts.next() orelse return;
        if (a.len < 2 or a[0] != '+' or b.len < 2 or b[0] != '-') return;
        const ahead = std.fmt.parseInt(u32, a[1..], 10) catch return;
        const behind = std.fmt.parseInt(u32, b[1..], 10) catch return;
        st.ahead = ahead;
        st.behind = behind;
    }
}

// ---------------------------------------------------------------------------
// Probe gate (bounded probe with in-flight guard)
// ---------------------------------------------------------------------------

/// Per-directory probe scheduler: at most one probe in flight; triggers that
/// arrive meanwhile coalesce into exactly one follow-up probe. Single-thread
/// use (the UI thread owns it; workers only report completion via a task).
pub const ProbeGate = struct {
    in_flight: bool = false,
    pending: bool = false,

    /// A watcher event or timer asks for a refresh. Returns true when the
    /// caller should start a probe now (then call `finish` when it ends).
    pub fn request(self: *ProbeGate) bool {
        if (self.in_flight) {
            self.pending = true;
            return false;
        }
        self.in_flight = true;
        return true;
    }

    /// The running probe completed. Returns true when a coalesced request
    /// is waiting: the caller should start the next probe immediately (the
    /// gate stays in flight).
    pub fn finish(self: *ProbeGate) bool {
        std.debug.assert(self.in_flight);
        if (self.pending) {
            self.pending = false;
            return true;
        }
        self.in_flight = false;
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Map-backed `Fs` for tests; directories are listed explicitly.
const FakeFs = struct {
    files: []const struct { []const u8, []const u8 },
    dirs: []const []const u8,

    fn kind(ctx: *anyopaque, path: []const u8) EntryKind {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.dirs) |d| if (std.mem.eql(u8, d, path)) return .dir;
        for (self.files) |f| if (std.mem.eql(u8, f[0], path)) return .file;
        return .missing;
    }

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], path)) return gpa.dupe(u8, f[1]) catch null;
        return null;
    }

    fn fs(self: *FakeFs) Fs {
        return .{ .ctx = self, .kind = kind, .read = read };
    }
};

fn expectNormalized(input: []const u8, sep: u8, want: []const u8) !void {
    const got = try normalize(testing.allocator, input, sep);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "unit: meta: git normalize folds dots, separators and roots" {
    try expectNormalized("/a/./b//c/", '/', "/a/b/c");
    try expectNormalized("/a/b/../../..", '/', "/");
    try expectNormalized("C:/Users\\me\\.\\proj\\", '\\', "C:\\Users\\me\\proj");
    try expectNormalized("C:\\..\\x", '\\', "C:\\x");
    try expectNormalized("\\\\srv\\share\\a\\..\\b", '\\', "\\\\srv\\share\\b");
    try expectNormalized("../a/../../b", '/', "../../b");
    try expectNormalized("a/..", '/', ".");
    try expectNormalized("", '/', ".");
    try expectNormalized("/проект/ü/../日本", '/', "/проект/日本");
}

test "unit: meta: git resolvePath joins relative and keeps absolute" {
    const gpa = testing.allocator;
    const a = try resolvePath(gpa, "C:\\repo\\wt", "../main/.git/worktrees/wt");
    defer gpa.free(a);
    try testing.expectEqualStrings("C:\\repo\\main\\.git\\worktrees\\wt", a);
    const b = try resolvePath(gpa, "C:\\repo\\wt", "D:/other/.git");
    defer gpa.free(b);
    try testing.expectEqualStrings("D:\\other\\.git", b);
    const c = try resolvePath(gpa, "/home/u/wt", "/home/u/main/.git/worktrees/wt");
    defer gpa.free(c);
    try testing.expectEqualStrings("/home/u/main/.git/worktrees/wt", c);
    try testing.expect(!isAbsolute("C:rel"));
    try testing.expect(isAbsolute("\\\\srv\\share"));
}

test "unit: meta: git resolvePath at a root adds no second separator" {
    const gpa = testing.allocator;
    // `//.git` or `\\.git` would be a UNC path to a server named `.git`.
    const cases = [_][3][]const u8{
        .{ "/", ".git", "/.git" },
        .{ "\\", ".git", "\\.git" },
        .{ "C:\\", ".git", "C:\\.git" },
        .{ "\\\\srv\\share\\", ".git", "\\\\srv\\share\\.git" },
        .{ "/home/u/", "x", "/home/u/x" },
        .{ "", ".git", ".git" },
    };
    for (cases) |c| {
        const got = try resolvePath(gpa, c[0], c[1]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "unit: meta: git parentDir walks to the root and stops" {
    try testing.expectEqualStrings("/a", parentDir("/a/b").?);
    try testing.expectEqualStrings("/", parentDir("/a").?);
    try testing.expect(parentDir("/") == null);
    try testing.expectEqualStrings("C:\\", parentDir("C:\\x").?);
    try testing.expect(parentDir("C:\\") == null);
    try testing.expectEqualStrings("\\\\srv\\share\\", parentDir("\\\\srv\\share\\a").?);
    try testing.expect(parentDir("rel") == null);
    try testing.expect(parentDir("") == null);
}

test "unit: meta: git parseDotGitFile accepts gitdir lines and rejects junk" {
    try testing.expectEqualStrings("../.git/worktrees/x", parseDotGitFile("gitdir: ../.git/worktrees/x\n").?);
    try testing.expectEqualStrings("C:/r/.git/modules/s", parseDotGitFile("\xEF\xBB\xBFgitdir:C:/r/.git/modules/s\r\nextra").?);
    try testing.expect(parseDotGitFile("") == null);
    try testing.expect(parseDotGitFile("gitdir:   \n") == null);
    try testing.expect(parseDotGitFile("GITDIR: x") == null);
    try testing.expect(parseDotGitFile("\x00\x01binary") == null);
    try testing.expectEqualStrings("../..", parseCommondir("../..\n").?);
    try testing.expect(parseCommondir("\r\n") == null);
}

test "unit: meta: git resolveFromDotGit main repo, linked worktree, submodule" {
    const gpa = testing.allocator;
    {
        var loc = try resolveFromDotGit(gpa, "C:\\src\\proj\\", null, null);
        defer loc.deinit(gpa);
        try testing.expectEqualStrings("C:\\src\\proj", loc.worktree_root);
        try testing.expectEqualStrings("C:\\src\\proj\\.git", loc.git_dir);
        try testing.expectEqualStrings(loc.git_dir, loc.common_dir);
        try testing.expect(!loc.linked_worktree);
        const head = try loc.headPath(gpa);
        defer gpa.free(head);
        try testing.expectEqualStrings("C:\\src\\proj\\.git\\HEAD", head);
    }
    {
        var loc = try resolveFromDotGit(gpa, "C:\\src\\feat", "gitdir: C:/src/proj/.git/worktrees/feat\n", "../..\n");
        defer loc.deinit(gpa);
        try testing.expectEqualStrings("C:\\src\\proj\\.git\\worktrees\\feat", loc.git_dir);
        try testing.expectEqualStrings("C:\\src\\proj\\.git", loc.common_dir);
        try testing.expect(loc.linked_worktree);
    }
    {
        var loc = try resolveFromDotGit(gpa, "/r/sub", "gitdir: ../.git/modules/sub", null);
        defer loc.deinit(gpa);
        try testing.expectEqualStrings("/r/.git/modules/sub", loc.git_dir);
        try testing.expectEqualStrings("/r/.git/modules/sub", loc.common_dir);
        try testing.expect(!loc.linked_worktree);
    }
    try testing.expectError(error.MalformedGitFile, resolveFromDotGit(gpa, "/r", "nonsense", null));
}

test "unit: meta: git resolve walks up from a nested cwd" {
    const gpa = testing.allocator;
    var fake: FakeFs = .{
        .dirs = &.{"C:\\src\\proj\\.git"},
        .files = &.{},
    };
    var loc = (try resolve(gpa, "C:\\src\\proj\\a\\b\\", fake.fs())).?;
    defer loc.deinit(gpa);
    try testing.expectEqualStrings("C:\\src\\proj", loc.worktree_root);
    try testing.expectEqualStrings("C:\\src\\proj\\.git", loc.common_dir);
}

test "unit: meta: git resolve finds a repo at the file-system root" {
    const gpa = testing.allocator;
    var fake: FakeFs = .{ .dirs = &.{"/.git"}, .files = &.{} };
    var loc = (try resolve(gpa, "/srv/app", fake.fs())).?;
    defer loc.deinit(gpa);
    try testing.expectEqualStrings("/", loc.worktree_root);
    try testing.expectEqualStrings("/.git", loc.git_dir);
    var drive = try resolveFromDotGit(gpa, "C:\\", null, null);
    defer drive.deinit(gpa);
    try testing.expectEqualStrings("C:\\.git", drive.git_dir);
}

test "unit: meta: git resolve follows .git file and commondir" {
    const gpa = testing.allocator;
    var fake: FakeFs = .{
        .dirs = &.{},
        .files = &.{
            .{ "/home/u/wt/.git", "gitdir: /home/u/main/.git/worktrees/wt\n" },
            .{ "/home/u/main/.git/worktrees/wt/commondir", "../..\n" },
        },
    };
    var loc = (try resolve(gpa, "/home/u/wt/src", fake.fs())).?;
    defer loc.deinit(gpa);
    try testing.expectEqualStrings("/home/u/wt", loc.worktree_root);
    try testing.expectEqualStrings("/home/u/main/.git/worktrees/wt", loc.git_dir);
    try testing.expectEqualStrings("/home/u/main/.git", loc.common_dir);
    try testing.expect(loc.linked_worktree);
}

test "unit: meta: git resolve returns null outside a repo or on a bad .git file" {
    const gpa = testing.allocator;
    var none: FakeFs = .{ .dirs = &.{}, .files = &.{} };
    try testing.expect((try resolve(gpa, "C:\\tmp\\x", none.fs())) == null);
    try testing.expect((try resolve(gpa, "", none.fs())) == null);
    // A malformed .git file stops the walk even if an ancestor is a repo.
    var bad: FakeFs = .{
        .dirs = &.{"/r/.git"},
        .files = &.{.{ "/r/sub/.git", "garbage" }},
    };
    try testing.expect((try resolve(gpa, "/r/sub/x", bad.fs())) == null);
}

test "unit: meta: git isRelevantChange filters watcher noise" {
    try testing.expect(isRelevantChange("HEAD"));
    try testing.expect(isRelevantChange("index"));
    try testing.expect(isRelevantChange("packed-refs"));
    try testing.expect(isRelevantChange("refs\\heads\\main"));
    try testing.expect(isRelevantChange("/refs/remotes/origin/feat/x"));
    try testing.expect(!isRelevantChange("index.lock"));
    try testing.expect(!isRelevantChange("refs/heads/main.lock"));
    try testing.expect(!isRelevantChange("objects/ab/cdef"));
    try testing.expect(!isRelevantChange("logs/HEAD"));
    try testing.expect(!isRelevantChange("refs"));
    try testing.expect(!isRelevantChange("refsx/y"));
    try testing.expect(!isRelevantChange(""));
}

test "unit: meta: git parseHead branch, other ref, detached, malformed" {
    try testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n").?.branch);
    try testing.expectEqualStrings("feat/ü-日本", parseHead("ref: refs/heads/feat/ü-日本\r\n").?.branch);
    try testing.expectEqualStrings("refs/remotes/origin/main", parseHead("ref:refs/remotes/origin/main").?.other_ref);
    try testing.expectEqualStrings("refs/heads/", parseHead("ref: refs/heads/").?.other_ref);
    const sha1 = "0123456789abcdef0123456789abcdef01234567";
    try testing.expectEqualStrings(sha1, parseHead(sha1 ++ "\n").?.detached);
    const sha256 = sha1 ++ "0123456789abcdef01234567";
    try testing.expectEqualStrings(sha256, parseHead(sha256).?.detached);
    try testing.expectEqualStrings("0123456", shortSha(sha1));
    try testing.expectEqualStrings("ab", shortSha("ab"));
    try testing.expect(parseHead("") == null);
    try testing.expect(parseHead("ref:   ") == null);
    try testing.expect(parseHead("0123") == null);
    try testing.expect(parseHead("zz23456789abcdef0123456789abcdef01234567") == null);
}

test "unit: meta: git parseStatusV2 clean branch with upstream" {
    const out =
        "# branch.oid 0123456789abcdef0123456789abcdef01234567\n" ++
        "# branch.head main\n" ++
        "# branch.upstream origin/main\n" ++
        "# branch.ab +2 -15\n";
    const st = parseStatusV2(out, .{});
    try testing.expectEqualStrings("main", st.head.?);
    try testing.expectEqualStrings("origin/main", st.upstream.?);
    try testing.expectEqual(@as(?u32, 2), st.ahead);
    try testing.expectEqual(@as(?u32, 15), st.behind);
    try testing.expect(!st.dirty());
    try testing.expect(!st.detached);
    try testing.expectEqualStrings("main", st.displayBranch().?);
}

test "unit: meta: git parseStatusV2 counts entries (CRLF)" {
    const out =
        "# branch.oid (initial)\r\n" ++
        "# branch.head feat/x\r\n" ++
        "1 .M N... 100644 100644 100644 aaa bbb src/a.zig\r\n" ++
        "1 A. N... 000000 100644 100644 000 bbb src/new.zig\r\n" ++
        "1 MM N... 100644 100644 100644 aaa bbb both.zig\r\n" ++
        "2 R. N... 100644 100644 100644 aaa bbb R100 new.zig\told.zig\r\n" ++
        "u UU N... 100644 100644 100644 100644 a b c conflict.zig\r\n" ++
        "? untracked file.txt\r\n" ++
        "? 日本.txt\r\n" ++
        "! zig-out/\r\n";
    const st = parseStatusV2(out, .{});
    try testing.expect(st.oid == null);
    try testing.expectEqualStrings("feat/x", st.head.?);
    try testing.expect(st.ahead == null and st.upstream == null);
    try testing.expectEqual(@as(u32, 4), st.changed);
    try testing.expectEqual(@as(u32, 3), st.staged);
    try testing.expectEqual(@as(u32, 2), st.unstaged);
    try testing.expectEqual(@as(u32, 1), st.conflicted);
    try testing.expectEqual(@as(u32, 2), st.untracked);
    try testing.expectEqual(@as(u32, 1), st.ignored);
    try testing.expect(st.dirty());
}

test "unit: meta: git parseStatusV2 untracked-only and ignored-only" {
    try testing.expect(parseStatusV2("# branch.head main\n? x\n", .{}).dirty());
    try testing.expect(!parseStatusV2("# branch.head main\n! x\n", .{}).dirty());
}

test "unit: meta: git parseStatusV2 detached shows short sha" {
    const out = "# branch.oid abcdef0123456789abcdef0123456789abcdef01\n# branch.head (detached)\n";
    const st = parseStatusV2(out, .{});
    try testing.expect(st.detached);
    try testing.expect(st.head == null);
    try testing.expectEqualStrings("abcdef0", st.displayBranch().?);
}

test "unit: meta: git parseStatusV2 -z skips rename origin records" {
    // The origin path "1 .M fake" would otherwise count as an entry.
    const out = "# branch.head main\x00" ++
        "2 R. N... 100644 100644 100644 a b R100 new\x00" ++
        "1 .M fake\x00" ++
        "? u\x00";
    const st = parseStatusV2(out, .{});
    try testing.expectEqual(@as(u32, 1), st.changed);
    try testing.expectEqual(@as(u32, 1), st.untracked);
}

test "unit: meta: git parseStatusV2 tolerates empty and malformed input" {
    const empty = parseStatusV2("", .{});
    try testing.expect(empty.head == null and !empty.dirty() and empty.displayBranch() == null);
    const junk = parseStatusV2(
        "garbage\n#\n# branch.\n# branch.head\n# branch.ab +x -1\n# branch.ab 1 2\n1X\n?\nuX y\n\xff\xfe\n",
        .{},
    );
    try testing.expect(junk.head == null);
    try testing.expect(junk.ahead == null);
    try testing.expect(!junk.dirty());
    // Overflowing ahead/behind counts are rejected, not wrapped.
    const big = parseStatusV2("# branch.ab +99999999999 -0\n", .{});
    try testing.expect(big.ahead == null);
}

test "unit: meta: git parseStatusV2 truncated output drops the partial record" {
    const out = "# branch.head main\n? a\n? b\n1 .M N... 100644 100644 100644 aaa bb";
    const st = parseStatusV2(out, .{ .truncated = true });
    try testing.expect(st.incomplete);
    try testing.expectEqual(@as(u32, 2), st.untracked);
    try testing.expectEqual(@as(u32, 0), st.changed);
    try testing.expect(st.dirty());
    // No terminator at all: nothing usable.
    const none = parseStatusV2("# branch.head ma", .{ .truncated = true });
    try testing.expect(none.head == null);
}

test "unit: meta: git parseStatusV2 huge input counts every record" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "# branch.head big\n");
    for (0..20_000) |_| try buf.appendSlice(gpa, "? f\n");
    const st = parseStatusV2(buf.items, .{});
    try testing.expectEqual(@as(u32, 20_000), st.untracked);
}

test "unit: meta: git ProbeGate coalesces requests while in flight" {
    var g: ProbeGate = .{};
    try testing.expect(g.request());
    try testing.expect(!g.request());
    try testing.expect(!g.request());
    // One follow-up for any number of coalesced requests.
    try testing.expect(g.finish());
    try testing.expect(!g.finish());
    try testing.expect(!g.in_flight);
    try testing.expect(g.request());
    try testing.expect(!g.finish());
}

test "unit: meta: git status_argv is the porcelain v2 branch probe" {
    try testing.expectEqualStrings("git", status_argv[0]);
    try testing.expectEqualStrings("--porcelain=v2", status_argv[3]);
    try testing.expectEqualStrings("--branch", status_argv[4]);
}
