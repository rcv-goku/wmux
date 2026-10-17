//! The agent shims directory `STATE\shims\<build-id>\agents` (ARCHITECTURE.md
//! ADR-4.1, ADR-10.6): created at startup with a `.wmux-shims` sentinel in
//! `STATE\shims\<build-id>\`, and every other build-id directory that carries
//! the sentinel (so only directories wmux made) is deleted. W3-2 registers
//! the wrapper names (`claude.exe`, `codex.exe`, ...) it hardlinks there;
//! this WP only owns the directory and its place on PATH, which is
//! prepended only while an agent integration is enabled.
//!
//! The file work runs on a short detached thread (G3: no blocking file I/O
//! on the UI thread) with its own copies of the paths.

const std = @import("std");
const proto = @import("wmux_proto");
const build_config = @import("../../../../build_config.zig");

const App = @import("../../App.zig");

const log = std.log.scoped(.env_identity);

/// File written into `STATE\shims\<build-id>\` so pruning only ever deletes
/// directories wmux created.
pub const sentinel_name = ".wmux-shims";

/// The build id of this executable: the version string mapped onto
/// `[a-z0-9-]` (`1.2.0-dev+abc` → `1-2-0-dev-abc`), so a new build gets a
/// new directory and the old one is pruned.
pub fn buildId(buf: *[proto.channel.max_len]u8) []const u8 {
    return proto.channel.sanitizeBuf(buf, build_config.version_string) orelse "unknown";
}

/// Whether any agent integration is enabled, i.e. whether the shims
/// directory goes on PATH (ADR-3.9). No agent integration exists before
/// W3 (the wrappers arrive with W3-2 and their settings with W3-1), so
/// this is false until those WPs declare the setting it reads.
pub fn agentIntegrationEnabled(app: *const App) bool {
    _ = app;
    return false;
}

/// Prepare `STATE\shims\<build-id>\agents` in the background. `state` is the
/// STATE directory; the result path is returned (owned by `gpa`) without
/// waiting for the thread.
pub fn prepare(gpa: std.mem.Allocator, state: []const u8) ?[]u8 {
    var id_buf: [proto.channel.max_len]u8 = undefined;
    const id = buildId(&id_buf);
    const agents = proto.paths.shimsDir(gpa, .windows, state, id, .agents) catch return null;

    // The thread owns its copies (page allocator: it may outlive the app's
    // allocator checks at exit).
    const job = Job.create(state, id) catch |err| {
        log.warn("shims directory not prepared err={}", .{err});
        return agents;
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
        log.warn("shims thread not started err={}", .{err});
        job.destroy();
        return agents;
    };
    thread.detach();
    return agents;
}

const Job = struct {
    root: []u8,
    build_id: []u8,

    const pa = std.heap.page_allocator;

    fn create(state: []const u8, id: []const u8) !*Job {
        const self = try pa.create(Job);
        errdefer pa.destroy(self);
        self.root = try std.fs.path.join(pa, &.{ state, proto.paths.dirs.shims });
        errdefer pa.free(self.root);
        self.build_id = try pa.dupe(u8, id);
        return self;
    }

    fn destroy(self: *Job) void {
        pa.free(self.root);
        pa.free(self.build_id);
        pa.destroy(self);
    }

    fn run(self: *Job) void {
        defer self.destroy();
        maintain(self.root, self.build_id) catch |err| {
            log.warn("shims directory maintenance failed err={}", .{err});
        };
    }
};

/// Create `<root>\<build_id>\agents` and the sentinel, then delete every
/// other `<root>\<id>` that has a sentinel. Exposed for tests.
pub fn maintain(root: []const u8, build_id: []const u8) !void {
    var root_dir = try std.fs.cwd().makeOpenPath(root, .{ .iterate = true });
    defer root_dir.close();
    {
        var own = try root_dir.makeOpenPath(build_id, .{});
        defer own.close();
        try own.makePath(@tagName(proto.paths.ShimKind.agents));
        try own.writeFile(.{ .sub_path = sentinel_name, .data = build_config.version_string });
    }

    var it = root_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, build_id)) continue;
        if (!hasSentinel(root_dir, entry.name)) continue;
        root_dir.deleteTree(entry.name) catch |err| {
            // A running older build may still hold a file open.
            log.info("stale shims directory {s} kept err={}", .{ entry.name, err });
            continue;
        };
        log.info("stale shims directory {s} pruned", .{entry.name});
    }
}

fn hasSentinel(root_dir: std.fs.Dir, name: []const u8) bool {
    var sub = root_dir.openDir(name, .{}) catch return false;
    defer sub.close();
    sub.access(sentinel_name, .{}) catch return false;
    return true;
}

test "unit: env_identity: shims directory is created and stale build ids pruned" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    // An old build of ours, and a foreign directory without a sentinel.
    try tmp.dir.makePath("old-build/agents");
    try tmp.dir.writeFile(.{ .sub_path = "old-build/" ++ sentinel_name, .data = "0.1" });
    try tmp.dir.makePath("not-ours");

    try maintain(root, "new-build");
    try tmp.dir.access("new-build/agents", .{});
    try tmp.dir.access("new-build/" ++ sentinel_name, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access("old-build", .{}));
    try tmp.dir.access("not-ours", .{});

    // Idempotent.
    try maintain(root, "new-build");
    try tmp.dir.access("new-build/agents", .{});

    var buf: [proto.channel.max_len]u8 = undefined;
    const id = buildId(&buf);
    try testing.expect(proto.channel.isValid(id));
}
