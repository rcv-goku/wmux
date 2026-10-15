//! Worktree-path construction (pure; used by `workspace-new --worktree`):
//! branch validation and sanitization for <repo>/.worktrees/<branch>.
//!
//! Moved out of `ipc.zig` in W0-A1 (ARCHITECTURE.md ADR-1.8).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Failures from validating a git branch name destined for a worktree
/// directory under <repo>/.worktrees/.
pub const WorktreeError = error{
    /// The branch name is empty or only separators/whitespace.
    EmptyBranch,
    /// The branch name would escape the .worktrees directory: it contains
    /// a path separator, a drive/volume marker, or a ".." traversal
    /// component. Branches like "feature/x" are common in git, but we
    /// flatten them in worktreePath; an explicit path-traversal attempt
    /// ("../x", "a/../../b") is rejected outright rather than flattened so
    /// a hostile branch name can never write outside .worktrees.
    UnsafeBranch,
    /// The branch name is longer than the directory-name budget.
    BranchTooLong,
};

/// Hard cap on a sanitized worktree directory name (well under any
/// filesystem component limit; keeps the joined path bounded).
pub const max_worktree_name: usize = 128;

/// Reject a branch name that must never become a directory name because
/// it could escape <repo>/.worktrees/. Run BEFORE sanitization on the
/// raw, caller-supplied branch so traversal can't be laundered into a
/// safe-looking name. Rules:
///   * empty (after trimming ASCII whitespace) → EmptyBranch
///   * contains any '/' or '\\' path separator → UnsafeBranch
///     (git allows slashes in branches, but we keep one flat directory
///     under .worktrees and refuse to create nested dirs from the name)
///   * a ".." component, or a leading/trailing/standalone ".." → Unsafe
///   * a ':' (Windows drive/ADS marker) → UnsafeBranch
/// On success returns the trimmed branch slice (a subslice of `branch`).
pub fn validateBranch(branch: []const u8) WorktreeError![]const u8 {
    const trimmed = std.mem.trim(u8, branch, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.EmptyBranch;
    if (std.mem.eql(u8, trimmed, "..") or std.mem.eql(u8, trimmed, "."))
        return error.UnsafeBranch;
    for (trimmed) |ch| {
        switch (ch) {
            '/', '\\', ':' => return error.UnsafeBranch,
            else => {},
        }
    }
    // A literal ".." anywhere is traversal even without a separator on
    // either side (defense in depth; the separator check above already
    // catches "../").
    if (std.mem.indexOf(u8, trimmed, "..") != null) return error.UnsafeBranch;
    if (trimmed.len > max_worktree_name) return error.BranchTooLong;
    return trimmed;
}

/// Turn a (validated) branch name into a safe directory-name component:
/// every byte that isn't ASCII alphanumeric, '-', '_', or '.' becomes
/// '-'. validateBranch has already rejected separators and traversal, so
/// this only normalizes display-hostile bytes (spaces, punctuation) into
/// a tidy folder name. Writes into `buf` and returns the written slice;
/// the caller sizes buf >= max_worktree_name.
pub fn sanitizeBranchName(branch: []const u8, buf: []u8) []u8 {
    std.debug.assert(buf.len >= branch.len);
    for (branch, 0..) |ch, i| {
        buf[i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => ch,
            else => '-',
        };
    }
    return buf[0..branch.len];
}

/// Build the absolute worktree path <repo>/.worktrees/<sanitized-branch>
/// for a validated branch. `repo` is the resolved repository root
/// (forward or back slashes both fine on Windows). Caller owns the
/// returned slice. Validation (validateBranch) is the caller's
/// responsibility and must run first; this asserts the branch is already
/// separator/traversal-free.
pub fn worktreePath(
    alloc: Allocator,
    repo: []const u8,
    validated_branch: []const u8,
) Allocator.Error![]u8 {
    var name_buf: [max_worktree_name]u8 = undefined;
    const name = sanitizeBranchName(validated_branch, &name_buf);
    // std.fs.path.join normalizes the separator per the host; on Windows
    // this yields backslashes, which git -C accepts.
    return std.fs.path.join(alloc, &.{ repo, ".worktrees", name });
}

// ---------------------------------------------------------------------------
// git child runner (pipe thread; used by workspace-new --worktree)
// ---------------------------------------------------------------------------

/// One git child invocation. Captures stdout+stderr, returns whether it
/// exited 0 along with the owned output buffers (caller frees both).
pub const GitResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
};

pub fn runGit(alloc: Allocator, argv: []const []const u8) !GitResult {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(alloc);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(alloc);

    try child.spawn();
    // collectOutput reads both pipes to EOF (8 MiB cap is far beyond any
    // git worktree message) before wait, so a chatty child can't deadlock.
    try child.collectOutput(alloc, &stdout, &stderr, 8 * 1024 * 1024);
    const term = try child.wait();

    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    return .{
        .ok = ok,
        .stdout = try stdout.toOwnedSlice(alloc),
        .stderr = try stderr.toOwnedSlice(alloc),
    };
}

/// Distill git's stderr into a single-line client error message. git
/// often prints a progress line ("Preparing worktree ...") before the
/// actual failure, so prefer the first line tagged "fatal:" or "error:"
/// (the useful reason); fall back to the first non-empty line, then a
/// generic message when stderr is empty. Trimmed and capped.
pub fn gitMessage(stderr: []const u8) []const u8 {
    var first_nonempty: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0) continue;
        if (first_nonempty == null) first_nonempty = line;
        if (std.mem.startsWith(u8, line, "fatal:") or
            std.mem.startsWith(u8, line, "error:"))
        {
            return line[0..@min(line.len, 512)];
        }
    }
    if (first_nonempty) |line| return line[0..@min(line.len, 512)];
    return "git worktree add failed";
}

test "ipc: validateBranch accepts ordinary branch names" {
    try testing.expectEqualStrings("feature-x", try validateBranch("feature-x"));
    try testing.expectEqualStrings("v1.2.3", try validateBranch("v1.2.3"));
    try testing.expectEqualStrings("fix_42", try validateBranch("fix_42"));
    // Surrounding whitespace is trimmed.
    try testing.expectEqualStrings("trim-me", try validateBranch("  trim-me\t"));
}

test "ipc: validateBranch rejects empty and whitespace-only names" {
    try testing.expectError(error.EmptyBranch, validateBranch(""));
    try testing.expectError(error.EmptyBranch, validateBranch("   "));
    try testing.expectError(error.EmptyBranch, validateBranch("\t\n "));
}

test "ipc: validateBranch rejects path traversal and separators" {
    // The headline attack: escape .worktrees via "..".
    try testing.expectError(error.UnsafeBranch, validateBranch("../x"));
    try testing.expectError(error.UnsafeBranch, validateBranch(".."));
    try testing.expectError(error.UnsafeBranch, validateBranch("a/../../b"));
    try testing.expectError(error.UnsafeBranch, validateBranch("..\\evil"));
    // A lone "." is not a usable directory name either.
    try testing.expectError(error.UnsafeBranch, validateBranch("."));
    // Any separator is refused (we keep a single flat .worktrees dir).
    try testing.expectError(error.UnsafeBranch, validateBranch("feature/x"));
    try testing.expectError(error.UnsafeBranch, validateBranch("a\\b"));
    // Windows drive / alternate-data-stream marker.
    try testing.expectError(error.UnsafeBranch, validateBranch("C:evil"));
    // ".." embedded without a separator on each side is still traversal.
    try testing.expectError(error.UnsafeBranch, validateBranch("a..b"));
}

test "ipc: validateBranch rejects an over-long name" {
    const long = [_]u8{'a'} ** (max_worktree_name + 1);
    try testing.expectError(error.BranchTooLong, validateBranch(&long));
    // Exactly at the cap is fine.
    const at_cap = [_]u8{'a'} ** max_worktree_name;
    try testing.expectEqualStrings(&at_cap, try validateBranch(&at_cap));
}

test "ipc: sanitizeBranchName maps display-hostile bytes to dashes" {
    var buf: [max_worktree_name]u8 = undefined;
    // Spaces, punctuation → '-'; alnum/-/_/. pass through.
    try testing.expectEqualStrings("a-b-c", sanitizeBranchName("a b c", &buf));
    try testing.expectEqualStrings("v1.2.3", sanitizeBranchName("v1.2.3", &buf));
    try testing.expectEqualStrings("keep_me-", sanitizeBranchName("keep_me!", &buf));
    // A name that's already clean is unchanged.
    try testing.expectEqualStrings("feature-x", sanitizeBranchName("feature-x", &buf));
}

test "ipc: worktreePath joins repo/.worktrees/<sanitized>" {
    const alloc = testing.allocator;
    const branch = try validateBranch("feature x");
    const path = try worktreePath(alloc, "C:\\repos\\app", branch);
    defer alloc.free(path);
    // std.fs.path.join normalizes to the host separator (backslash on
    // Windows); assert the tail components regardless of separator style.
    try testing.expect(std.mem.endsWith(u8, path, "feature-x"));
    try testing.expect(std.mem.indexOf(u8, path, ".worktrees") != null);
    try testing.expect(std.mem.startsWith(u8, path, "C:\\repos\\app"));
}

test "ipc: worktreePath round-trips a clean branch" {
    const alloc = testing.allocator;
    const branch = try validateBranch("v1.2.3");
    const path = try worktreePath(alloc, "/home/me/proj", branch);
    defer alloc.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "v1.2.3"));
    try testing.expect(std.mem.indexOf(u8, path, ".worktrees") != null);
}
