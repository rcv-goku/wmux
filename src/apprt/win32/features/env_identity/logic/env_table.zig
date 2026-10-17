//! The terminal environment table (ARCHITECTURE.md ADR-3.9), pure:
//!
//! - `protectedEntries`: the variables applied **last** to every terminal
//!   spawn (after the inherited environment, Ghostty's own variables, shell
//!   integration and the `env` configuration), in a fixed order, so no
//!   workspace, layout or config env can override them;
//! - `stripAuth`: the inherited Anthropic credentials removed from the base
//!   environment unless `wmux.agents.preserveAuthEnv`;
//! - `prependPath`: `PATH` with `INSTALL\cli` (and the agent shims
//!   directory while an agent integration is enabled) first, exactly once.
//!
//! Std and wmux_proto only (runs in `zig build test-fast`).

const std = @import("std");
const proto = @import("wmux_proto");
const ports = @import("ports.zig");

const env_names = proto.env_names;
const Allocator = std.mem.Allocator;

/// `TERM` exported unless the Ghostty `term` key is set explicitly
/// (Windows deviation: WSL distros and ssh hosts lack `xterm-ghostty`).
pub const default_term = "xterm-256color";
pub const colorterm = "truecolor";
pub const term_program = "ghostty";

/// Everything the table depends on for one spawn. Ids are 36-character
/// uppercase UUID texts.
pub const Inputs = struct {
    workspace_id: []const u8,
    surface_id: []const u8,
    pane_id: []const u8,
    lifecycle_id: []const u8,
    /// The control pipe (`\\.\pipe\wmux-...`).
    socket_path: []const u8,
    /// `_cmux_capability_v1` token (W1-1b), when the server has one.
    socket_capability: ?[]const u8 = null,
    /// Only when the app itself was launched with a socket password.
    socket_password: ?[]const u8 = null,
    /// AUMID: `wmux.app` or `wmux.app.<channel>`.
    bundle_id: []const u8,
    /// `INSTALL\cli\cmux.exe`.
    bundled_cli_path: []const u8,
    /// `SHARE\wmux\shell-integration`.
    shell_integration_dir: []const u8,
    /// The workspace's port block, when one fits.
    port_block: ?ports.Block = null,
    /// The Ghostty `term` key was set in the user's configuration.
    term_explicit: bool = false,
    /// `TERM_PROGRAM_VERSION`.
    version: []const u8,
};

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

/// Upper bound of `protectedEntries(...).len`.
pub const max_entries = 32;

/// The protected variables for `in`, in their fixed order. Values borrow
/// from `in`, except the port numbers, which are formatted into `scratch`.
/// The result lives in `out`.
pub fn protectedEntries(in: Inputs, out: *[max_entries]Entry, scratch: *[3][10]u8) []const Entry {
    var n: usize = 0;
    const add = struct {
        fn f(o: *[max_entries]Entry, i: *usize, name: []const u8, value: []const u8) void {
            o[i.*] = .{ .name = name, .value = value };
            i.* += 1;
        }
    }.f;
    add(out, &n, env_names.CMUX_WORKSPACE_ID, in.workspace_id);
    add(out, &n, env_names.WMUX_WORKSPACE_ID, in.workspace_id);
    add(out, &n, env_names.CMUX_SURFACE_ID, in.surface_id);
    add(out, &n, env_names.WMUX_SURFACE_ID, in.surface_id);
    add(out, &n, env_names.CMUX_PANEL_ID, in.surface_id);
    // cmux legacy meaning: the workspace (no WMUX_TAB_ID).
    add(out, &n, env_names.CMUX_TAB_ID, in.workspace_id);
    add(out, &n, env_names.CMUX_PANE_ID, in.pane_id);
    add(out, &n, env_names.WMUX_PANE_ID, in.pane_id);
    add(out, &n, env_names.CMUX_TERMINAL_LIFECYCLE_ID, in.lifecycle_id);
    add(out, &n, env_names.WMUX_TERMINAL_LIFECYCLE_ID, in.lifecycle_id);
    add(out, &n, env_names.CMUX_SOCKET_PATH, in.socket_path);
    add(out, &n, env_names.WMUX_SOCKET_PATH, in.socket_path);
    // Deprecated alias: empty, so an inherited value cannot shadow the path.
    add(out, &n, env_names.CMUX_SOCKET, "");
    if (in.socket_capability) |cap| {
        add(out, &n, env_names.CMUX_SOCKET_CAPABILITY, cap);
        add(out, &n, env_names.WMUX_SOCKET_CAPABILITY, cap);
    }
    if (in.socket_password) |pw| add(out, &n, env_names.CMUX_SOCKET_PASSWORD, pw);
    add(out, &n, env_names.CMUX_BUNDLE_ID, in.bundle_id);
    add(out, &n, env_names.WMUX_BUNDLE_ID, in.bundle_id);
    add(out, &n, env_names.CMUX_BUNDLED_CLI_PATH, in.bundled_cli_path);
    add(out, &n, env_names.WMUX_BUNDLED_CLI_PATH, in.bundled_cli_path);
    add(out, &n, env_names.CMUX_SHELL_INTEGRATION_DIR, in.shell_integration_dir);
    if (in.port_block) |b| {
        add(out, &n, env_names.CMUX_PORT, std.fmt.bufPrint(&scratch[0], "{d}", .{b.start}) catch unreachable);
        add(out, &n, env_names.CMUX_PORT_END, std.fmt.bufPrint(&scratch[1], "{d}", .{b.end}) catch unreachable);
        add(out, &n, env_names.CMUX_PORT_RANGE, std.fmt.bufPrint(&scratch[2], "{d}", .{b.range}) catch unreachable);
    }
    if (!in.term_explicit) add(out, &n, env_names.TERM, default_term);
    add(out, &n, env_names.COLORTERM, colorterm);
    add(out, &n, env_names.TERM_PROGRAM, term_program);
    add(out, &n, env_names.TERM_PROGRAM_VERSION, in.version);
    return out[0..n];
}

/// Remove the inherited Anthropic credentials (ADR-3.9) from `env` unless
/// `preserve`. Returns how many were removed.
pub fn stripAuth(env: *std.process.EnvMap, preserve: bool) usize {
    if (preserve) return 0;
    var removed: usize = 0;
    for (env_names.stripped_auth_env) |name| {
        if (env.get(name) != null) {
            env.remove(name);
            removed += 1;
        }
    }
    return removed;
}

/// Windows path list comparison: case-insensitive, `/` = `\`, trailing
/// separators ignored.
pub fn samePathEntry(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimRight(u8, a, "\\/");
    const y = std.mem.trimRight(u8, b, "\\/");
    if (x.len != y.len) return false;
    for (x, y) |c, d| {
        const cn = if (c == '/') '\\' else std.ascii.toLower(c);
        const dn = if (d == '/') '\\' else std.ascii.toLower(d);
        if (cn != dn) return false;
    }
    return true;
}

/// `dirs` (in order) followed by every entry of `existing` (a `;` list)
/// that is not one of `dirs`, so each of `dirs` appears exactly once and
/// first. Empty entries of `existing` are dropped; empty `dirs` are
/// skipped. Caller owns the result.
pub fn prependPath(gpa: Allocator, existing: ?[]const u8, dirs: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (dirs, 0..) |d, i| {
        if (d.len == 0) continue;
        var dup = false;
        for (dirs[0..i]) |prev| dup = dup or samePathEntry(prev, d);
        if (dup) continue;
        if (out.items.len > 0) try out.append(gpa, ';');
        try out.appendSlice(gpa, d);
    }
    if (existing) |ex| {
        var it = std.mem.splitScalar(u8, ex, ';');
        while (it.next()) |entry| {
            if (std.mem.trim(u8, entry, " ").len == 0) continue;
            var ours = false;
            for (dirs) |d| ours = ours or (d.len > 0 and samePathEntry(d, entry));
            if (ours) continue;
            if (out.items.len > 0) try out.append(gpa, ';');
            try out.appendSlice(gpa, entry);
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const ws = "11111111-1111-4111-8111-111111111111";
const sf = "22222222-2222-4222-8222-222222222222";
const pn = "33333333-3333-4333-8333-333333333333";
const lc = "44444444-4444-4444-8444-444444444444";

fn sample() Inputs {
    return .{
        .workspace_id = ws,
        .surface_id = sf,
        .pane_id = pn,
        .lifecycle_id = lc,
        .socket_path = "\\\\.\\pipe\\wmux-test-0123abcd-3f9c1a0b-s1",
        .bundle_id = "wmux.app.test-0123abcd",
        .bundled_cli_path = "C:\\wmux\\cli\\cmux.exe",
        .shell_integration_dir = "C:\\wmux\\share\\wmux\\shell-integration",
        .version = "1.2.3",
    };
}

fn valueOf(entries: []const Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e.value;
    return null;
}

test "unit: env_identity: env table has every variable in the protected order" {
    var out: [max_entries]Entry = undefined;
    var scratch: [3][10]u8 = undefined;
    var in = sample();
    in.port_block = ports.block(ports.default_base, ports.default_range, 1);
    const e = protectedEntries(in, &out, &scratch);

    const want = [_]Entry{
        .{ .name = "CMUX_WORKSPACE_ID", .value = ws },
        .{ .name = "WMUX_WORKSPACE_ID", .value = ws },
        .{ .name = "CMUX_SURFACE_ID", .value = sf },
        .{ .name = "WMUX_SURFACE_ID", .value = sf },
        .{ .name = "CMUX_PANEL_ID", .value = sf },
        .{ .name = "CMUX_TAB_ID", .value = ws },
        .{ .name = "CMUX_PANE_ID", .value = pn },
        .{ .name = "WMUX_PANE_ID", .value = pn },
        .{ .name = "CMUX_TERMINAL_LIFECYCLE_ID", .value = lc },
        .{ .name = "WMUX_TERMINAL_LIFECYCLE_ID", .value = lc },
        .{ .name = "CMUX_SOCKET_PATH", .value = in.socket_path },
        .{ .name = "WMUX_SOCKET_PATH", .value = in.socket_path },
        .{ .name = "CMUX_SOCKET", .value = "" },
        .{ .name = "CMUX_BUNDLE_ID", .value = "wmux.app.test-0123abcd" },
        .{ .name = "WMUX_BUNDLE_ID", .value = "wmux.app.test-0123abcd" },
        .{ .name = "CMUX_BUNDLED_CLI_PATH", .value = "C:\\wmux\\cli\\cmux.exe" },
        .{ .name = "WMUX_BUNDLED_CLI_PATH", .value = "C:\\wmux\\cli\\cmux.exe" },
        .{ .name = "CMUX_SHELL_INTEGRATION_DIR", .value = "C:\\wmux\\share\\wmux\\shell-integration" },
        .{ .name = "CMUX_PORT", .value = "9110" },
        .{ .name = "CMUX_PORT_END", .value = "9119" },
        .{ .name = "CMUX_PORT_RANGE", .value = "10" },
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "COLORTERM", .value = "truecolor" },
        .{ .name = "TERM_PROGRAM", .value = "ghostty" },
        .{ .name = "TERM_PROGRAM_VERSION", .value = "1.2.3" },
    };
    try testing.expectEqual(want.len, e.len);
    for (want, e) |w, got| {
        try testing.expectEqualStrings(w.name, got.name);
        try testing.expectEqualStrings(w.value, got.value);
    }
    // No name twice (the hook applies them in order; a repeat would hide
    // an earlier value).
    for (e, 0..) |a, i| for (e[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.name, b.name));
    // Every always-protected name of the shared list is in the table,
    // except the capability (only once W1-1b has one).
    for (env_names.protected_terminal_env) |name| {
        if (std.mem.indexOf(u8, name, "CAPABILITY") != null) continue;
        try testing.expect(valueOf(e, name) != null);
    }
}

test "unit: env_identity: env table conditional variables" {
    var out: [max_entries]Entry = undefined;
    var scratch: [3][10]u8 = undefined;
    var in = sample();

    // Without a port block, capability or password: none of them.
    var e = protectedEntries(in, &out, &scratch);
    try testing.expectEqual(@as(?[]const u8, null), valueOf(e, "CMUX_PORT"));
    try testing.expectEqual(@as(?[]const u8, null), valueOf(e, "CMUX_SOCKET_CAPABILITY"));
    try testing.expectEqual(@as(?[]const u8, null), valueOf(e, "CMUX_SOCKET_PASSWORD"));
    try testing.expectEqualStrings("xterm-256color", valueOf(e, "TERM").?);

    // An explicit Ghostty `term` keeps Ghostty's TERM (not protected).
    in.term_explicit = true;
    in.socket_capability = "cap-token";
    in.socket_password = "pw";
    e = protectedEntries(in, &out, &scratch);
    try testing.expectEqual(@as(?[]const u8, null), valueOf(e, "TERM"));
    try testing.expectEqualStrings("cap-token", valueOf(e, "CMUX_SOCKET_CAPABILITY").?);
    try testing.expectEqualStrings("cap-token", valueOf(e, "WMUX_SOCKET_CAPABILITY").?);
    try testing.expectEqualStrings("pw", valueOf(e, "CMUX_SOCKET_PASSWORD").?);
    try testing.expectEqual(@as(?[]const u8, null), valueOf(e, "WMUX_SOCKET_PASSWORD"));
    try testing.expectEqualStrings("truecolor", valueOf(e, "COLORTERM").?);

    // The largest table fits.
    in.term_explicit = false;
    in.port_block = ports.block(1, 65535, std.math.maxInt(u32));
    e = protectedEntries(in, &out, &scratch);
    try testing.expect(e.len <= max_entries);
    try testing.expectEqualStrings("65535", valueOf(e, "CMUX_PORT_RANGE").?);
}

test "unit: env_identity: env table auth-variable removal" {
    const gpa = testing.allocator;
    var env = std.process.EnvMap.init(gpa);
    defer env.deinit();
    for (env_names.stripped_auth_env) |name| try env.put(name, "secret");
    try env.put("ANTHROPIC_BASE_URL", "https://example.invalid");
    try env.put("PATH", "C:\\Windows");

    // preserveAuthEnv keeps everything.
    try testing.expectEqual(@as(usize, 0), stripAuth(&env, true));
    try testing.expectEqualStrings("secret", env.get("ANTHROPIC_API_KEY").?);

    try testing.expectEqual(@as(usize, 5), stripAuth(&env, false));
    for (env_names.stripped_auth_env) |name| try testing.expect(env.get(name) == null);
    // Only the listed names go.
    try testing.expectEqualStrings("https://example.invalid", env.get("ANTHROPIC_BASE_URL").?);
    try testing.expectEqualStrings("C:\\Windows", env.get("PATH").?);
    try testing.expectEqual(@as(usize, 0), stripAuth(&env, false));
    const names = [_][]const u8{ "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX" };
    try testing.expectEqual(names.len, env_names.stripped_auth_env.len);
    for (names, env_names.stripped_auth_env) |a, b| try testing.expectEqualStrings(a, b);
}

test "unit: env_identity: PATH prepends the cli dir once and keeps the rest" {
    const gpa = testing.allocator;
    const cli = "C:\\wmux\\cli";
    const shims = "C:\\state\\shims\\1-2-3\\agents";

    const p1 = try prependPath(gpa, "C:\\Windows;C:\\wmux", &.{cli});
    defer gpa.free(p1);
    try testing.expectEqualStrings("C:\\wmux\\cli;C:\\Windows;C:\\wmux", p1);

    // Already present (other case, trailing separator, other slash): moved
    // to the front, never twice.
    const p2 = try prependPath(gpa, "C:\\Windows;c:/WMUX/cli/;;C:\\wmux", &.{ shims, cli });
    defer gpa.free(p2);
    try testing.expectEqualStrings("C:\\state\\shims\\1-2-3\\agents;C:\\wmux\\cli;C:\\Windows;C:\\wmux", p2);

    // Idempotent: a terminal started from a terminal.
    const p3 = try prependPath(gpa, p2, &.{ shims, cli });
    defer gpa.free(p3);
    try testing.expectEqualStrings(p2, p3);

    // No PATH at all; empty and repeated dirs are skipped.
    const p4 = try prependPath(gpa, null, &.{ "", cli, "C:\\WMUX\\CLI" });
    defer gpa.free(p4);
    try testing.expectEqualStrings(cli, p4);

    try testing.expect(samePathEntry("C:\\a\\b", "c:/A/B\\"));
    try testing.expect(!samePathEntry("C:\\a\\b", "C:\\a\\bc"));
}
