//! The environment of a wmux terminal (ARCHITECTURE.md ADR-3.9).
//!
//! Two stages, both called by the apprt surface while its terminal spawns:
//!
//! - `adjustDefaultEnv` edits the inherited base environment, before
//!   Ghostty adds its own variables: the Anthropic credentials go (unless
//!   `wmux.agents.preserveAuthEnv`), `PATH` gets `INSTALL\cli` (and the
//!   agent shims directory while an agent integration is enabled) first,
//!   and `WSLENV` names the identity variables for WSL. Ghostty's own
//!   append of INSTALL to PATH (termio/Exec.zig) stays at the end.
//! - `protectedEnv` builds the variables `termio/Exec.zig` applies last,
//!   after the `env` configuration and any workspace or layout env, so
//!   nothing can override them (logic/env_table.zig lists them).
//!
//! `initInstance` resolves the values every terminal shares once at
//! startup. UI thread only.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("wmux_proto");
const build_options = @import("wmux_build_options");
const build_config = @import("../../../../build_config.zig");
const global_state = &@import("../../../../global.zig").state;

const App = @import("../../App.zig");
const Surface = @import("../../Surface.zig");
const settings = @import("../../settings/api.zig");
const rpc_server = @import("../../rpc/server/mod.zig");
const env_table = @import("logic/env_table.zig");
const wslenv = @import("logic/wslenv.zig");
const ports = @import("ports.zig");
const shims = @import("shims.zig");

const env_names = proto.env_names;
const paths = proto.paths;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;

const log = std.log.scoped(.env_identity);

// ---------------------------------------------------------------------------
// Instance values
// ---------------------------------------------------------------------------

/// Resolve INSTALL, the CLI and shell-integration paths, the channel, the
/// bundle id, the computed control pipe and the socket password once.
/// Never fails: a value that cannot be resolved stays null and its
/// variable falls back (see `protectedEnv`).
pub fn initInstance(app: *App) void {
    const gpa = app.core_app.alloc;
    const inst = &app.features.env_identity.instance;

    var proc_env = std.process.getEnvMap(gpa) catch EnvMap.init(gpa);
    defer proc_env.deinit();
    const env = env_names.Env.fromEnvMap(&proc_env);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&exe_buf)) |exe| {
        if (paths.installFromGuiExe(.windows, exe)) |install| {
            inst.install_dir = gpa.dupe(u8, install) catch null;
            inst.cli_dir = paths.cliDir(gpa, .windows, install) catch null;
            inst.bundled_cli = paths.cliExe(gpa, .windows, install) catch null;
            inst.shell_integration_dir = shellIntegrationDir(gpa, install) catch null;
        }
    } else |err| log.warn("exe path unknown err={}", .{err});

    inst.channel = proto.channel.resolveFromEnv(gpa, build_options.channel, env) catch null;
    if (inst.channel) |ch| {
        inst.bundle_id = proto.channel.bundleIdAlloc(gpa, ch) catch null;
        inst.fallback_pipe = computedPipe(gpa, ch) catch |err| p: {
            log.warn("control pipe name not computed err={}", .{err});
            break :p null;
        };
        if (paths.stateDir(gpa, env, .windows, ch) catch null) |state| {
            defer gpa.free(state);
            inst.agent_shims_dir = shims.prepare(gpa, state);
        }
    }
    if (env.first(&.{ env_names.WMUX_SOCKET_PASSWORD, env_names.CMUX_SOCKET_PASSWORD })) |pw| {
        inst.socket_password = gpa.dupe(u8, pw) catch null;
    }
    log.info("terminal environment: cli={s} pipe={s} bundle={s}", .{
        inst.cli_dir orelse "-",
        inst.fallback_pipe orelse "-",
        inst.bundle_id orelse "-",
    });
}

/// `SHARE\wmux\shell-integration`: the first existing of INSTALL\share
/// (release layout), the install prefix's share (dev builds install share\
/// next to bin\) and Ghostty's resources directory; the release path when
/// none exists.
fn shellIntegrationDir(gpa: Allocator, install: []const u8) ![]u8 {
    const release = try paths.shellIntegrationDir(gpa, .windows, install);
    if (exists(release)) return release;
    if (paths.dirname(.windows, install)) |prefix| {
        const dev = try paths.shellIntegrationDir(gpa, .windows, prefix);
        if (exists(dev)) {
            gpa.free(release);
            return dev;
        }
        gpa.free(dev);
    }
    if (global_state.resources_dir.host()) |res| {
        const ghostty = try std.fs.path.join(gpa, &.{ res, "shell-integration" });
        if (exists(ghostty)) {
            gpa.free(release);
            return ghostty;
        }
        gpa.free(ghostty);
    }
    return release;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>` (ADR-3.1).
fn computedPipe(gpa: Allocator, channel: []const u8) ![]u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    var sid_buf: [256]u8 = undefined;
    const sid = try win.userSid(&sid_buf);
    const hash = proto.pipe_name.sidHash8(sid);
    var session: u32 = 0;
    if (win.ProcessIdToSessionId(win.GetCurrentProcessId(), &session) == 0) return error.SessionUnknown;
    return proto.pipe_name.controlName(gpa, channel, &hash, session);
}

/// The control pipe the terminals name: the v2 server's own name once it
/// runs (W1-1a), else the computed one.
pub fn socketPath(app: *const App) []const u8 {
    if (rpc_server.controlPipeName(app)) |p| return p;
    return app.features.env_identity.instance.fallback_pipe orelse "";
}

// ---------------------------------------------------------------------------
// Base environment
// ---------------------------------------------------------------------------

pub fn adjustDefaultEnv(surface: *const Surface, env: *EnvMap) !void {
    const app = surface.app;
    const inst = &app.features.env_identity.instance;

    _ = env_table.stripAuth(env, settings.get(app, "wmux.agents.preserveAuthEnv"));

    var dirs_buf: [2][]const u8 = undefined;
    var n: usize = 0;
    if (shims.agentIntegrationEnabled(app)) {
        if (inst.agent_shims_dir) |d| {
            dirs_buf[n] = d;
            n += 1;
        }
    }
    if (inst.cli_dir) |d| {
        dirs_buf[n] = d;
        n += 1;
    }
    if (n > 0) {
        const path = try env_table.prependPath(env.hash_map.allocator, env.get(env_names.PATH), dirs_buf[0..n]);
        defer env.hash_map.allocator.free(path);
        try env.put(env_names.PATH, path);
    }

    const merged = try wslenv.merge(env.hash_map.allocator, env.get(env_names.WSLENV), inst.socket_password != null);
    defer env.hash_map.allocator.free(merged);
    try env.put(env_names.WSLENV, merged);
}

// ---------------------------------------------------------------------------
// Protected environment
// ---------------------------------------------------------------------------

/// The protected variables of `surface`'s spawn as an owned EnvMap
/// (allocated with the app allocator; the caller deinits it).
pub fn protectedEnv(surface: *Surface) !EnvMap {
    const app = surface.app;
    const gpa = app.core_app.alloc;
    const inst = &app.features.env_identity.instance;
    const id = surface.spawn_identity;

    const ws_text = id.workspace.toText();
    const sf_text = id.surface.toText();
    const pn_text = id.pane.toText();
    const lc_text = id.lifecycle.toText();

    const in: env_table.Inputs = .{
        .workspace_id = &ws_text,
        .surface_id = &sf_text,
        .pane_id = &pn_text,
        .lifecycle_id = &lc_text,
        .socket_path = socketPath(app),
        .socket_password = inst.socket_password,
        .bundle_id = inst.bundle_id orelse "wmux.app",
        .bundled_cli_path = inst.bundled_cli orelse "",
        .shell_integration_dir = inst.shell_integration_dir orelse "",
        .port_block = ports.blockFor(app, id.workspace),
        .term_explicit = termExplicit(app),
        .version = build_config.version_string,
    };

    var out: [env_table.max_entries]env_table.Entry = undefined;
    var scratch: [3][10]u8 = undefined;
    const entries = env_table.protectedEntries(in, &out, &scratch);

    var env = EnvMap.init(gpa);
    errdefer env.deinit();
    for (entries) |e| try env.put(e.name, e.value);
    return env;
}

/// Whether the user's Ghostty configuration sets `term` explicitly (a
/// replay step exists only for explicitly parsed arguments, never for a
/// default; settings/legacy_keys.zig uses the same rule).
fn termExplicit(app: *const App) bool {
    for (app.config._replay_steps.items) |step| {
        const arg: []const u8 = switch (step) {
            .arg => |a| a,
            else => continue,
        };
        if (std.mem.eql(u8, arg, "--term") or std.mem.startsWith(u8, arg, "--term=")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Win32
// ---------------------------------------------------------------------------

const win = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const DWORD = windows.DWORD;

    const TOKEN_QUERY: DWORD = 0x0008;
    const TokenUser: c_int = 1;

    const SID_AND_ATTRIBUTES = extern struct { Sid: ?*anyopaque, Attributes: DWORD };
    const TOKEN_USER = extern struct { User: SID_AND_ATTRIBUTES };

    extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn GetTokenInformation(TokenHandle: HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(Sid: *anyopaque, StringSid: *?[*:0]u16) callconv(.winapi) BOOL;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ProcessIdToSessionId(dwProcessId: DWORD, pSessionId: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

    /// The user SID string ("S-1-5-21-...") of this process, in `buf`.
    fn userSid(buf: []u8) ![]const u8 {
        var token: HANDLE = undefined;
        if (OpenProcessToken(windows.GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return error.TokenUnavailable;
        defer windows.CloseHandle(token);
        var info: [256]u8 align(@alignOf(TOKEN_USER)) = undefined;
        var needed: DWORD = 0;
        if (GetTokenInformation(token, TokenUser, &info, info.len, &needed) == 0) return error.TokenUnavailable;
        const user: *const TOKEN_USER = @ptrCast(&info);
        const sid = user.User.Sid orelse return error.TokenUnavailable;
        var text: ?[*:0]u16 = null;
        if (ConvertSidToStringSidW(sid, &text) == 0) return error.TokenUnavailable;
        defer _ = LocalFree(text);
        const wide = std.mem.span(text.?);
        // SID strings are ASCII.
        if (wide.len > buf.len) return error.TokenUnavailable;
        for (wide, 0..) |c, i| {
            if (c > 0x7F) return error.TokenUnavailable;
            buf[i] = @intCast(c);
        }
        return buf[0..wide.len];
    }
};
