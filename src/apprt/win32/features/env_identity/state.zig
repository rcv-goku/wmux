//! Per-object state of feature `env_identity` (ADR-1.3), aggregated by ../ext.zig.
//! Every type keeps a valid `.{}` default and may point at model objects but
//! never embeds them. Optional per-type decls: deinit, snapshot, restore.

const std = @import("std");
const proto = @import("wmux_proto");
const job = @import("../../platform/job.zig");
const ports = @import("logic/ports.zig");

const Allocator = std.mem.Allocator;
const Uuid = proto.uuid.Uuid;

/// App-wide state (`App.features.env_identity`). UI thread only.
pub const App = struct {
    /// The instance job the wmux process put itself in at startup
    /// (ADR-3.9; null when that failed: membership then falls back to
    /// ancestry and the capability, ADR-3.8).
    instance_job: ?job.Job = null,

    /// Per-tab jobs created by a terminal spawn whose tab has not joined
    /// the model yet, keyed by the tab (surface) UUID. `jobs.adopt` moves
    /// each into its `Tab.ext.env_identity` once the tab exists.
    pending_jobs: std.AutoHashMapUnmanaged(Uuid, job.Job) = .empty,

    /// Port-block ordinal of every workspace that spawned a terminal.
    port_ordinals: std.AutoHashMapUnmanaged(Uuid, u32) = .empty,
    ordinals: ports.Ordinals = .{},

    /// Instance-wide values of the terminal environment, resolved once in
    /// `init` (owned).
    instance: Instance = .{},

    pub fn deinit(self: *App, gpa: Allocator) void {
        if (self.instance_job) |*j| j.deinit();
        var it = self.pending_jobs.valueIterator();
        while (it.next()) |j| j.deinit();
        self.pending_jobs.deinit(gpa);
        self.port_ordinals.deinit(gpa);
        self.instance.deinit(gpa);
        self.* = .{};
    }
};

/// What every terminal of this instance shares (spawn_env.zig).
pub const Instance = struct {
    /// INSTALL (the directory of wmux.exe).
    install_dir: ?[]u8 = null,
    /// INSTALL\cli, prepended to PATH.
    cli_dir: ?[]u8 = null,
    /// INSTALL\cli\cmux.exe (`CMUX_BUNDLED_CLI_PATH`).
    bundled_cli: ?[]u8 = null,
    /// SHARE\wmux\shell-integration (`CMUX_SHELL_INTEGRATION_DIR`).
    shell_integration_dir: ?[]u8 = null,
    /// The resolved channel (ADR-3.1).
    channel: ?[]u8 = null,
    /// `wmux.app` or `wmux.app.<channel>` (`CMUX_BUNDLE_ID`).
    bundle_id: ?[]u8 = null,
    /// The computed control pipe path, used while the v2 server does not
    /// report its own (`controlPipeName` null).
    fallback_pipe: ?[]u8 = null,
    /// The socket password the app itself was launched with, if any.
    socket_password: ?[]u8 = null,
    /// STATE\shims\<build-id>\agents (created by shims.zig).
    agent_shims_dir: ?[]u8 = null,

    pub fn deinit(self: *Instance, gpa: Allocator) void {
        inline for (@typeInfo(Instance).@"struct".fields) |f| {
            if (@field(self, f.name)) |s| gpa.free(s);
        }
        self.* = .{};
    }
};

/// Per-window state (`Window.ext.env_identity`).
pub const Window = struct {};

/// Per-workspace state (`Workspace.ext.env_identity`).
pub const Workspace = struct {};

/// Per-pane state (`Pane.ext.env_identity`).
pub const Pane = struct {};

/// Per-surface state (`Tab.ext.env_identity`).
pub const Tab = struct {
    /// The tab's job (JOB_OBJECT_LIMIT_BREAKAWAY_OK only, never
    /// KILL_ON_JOB_CLOSE): its terminal's shell and every descendant that
    /// did not break away. Closing the handle leaves the processes running.
    job: ?job.Job = null,

    pub fn deinit(self: *Tab, gpa: Allocator) void {
        _ = gpa;
        if (self.job) |*j| j.deinit();
        self.* = .{};
    }
};
