//! Ghostty interplay of the settings layer (ARCHITECTURE.md ADR-5.5): the
//! Ghostty configuration loads unchanged (default files, CLI, includes),
//! followed by the **wmux overlay** `CONFIG\config.ghostty` (themes, the
//! Settings font controls, import) and then the generated **JSON
//! overrides** `STATE\run\settings-overrides.ghostty` (one line per
//! explicitly set JSON key with a `ghostty_override`). Unset JSON keys defer
//! to Ghostty. Reloads keep the existing `reload_config` path
//! (`legacy_config_files.reloadConfig`), which loads through `loadConfig`.
//!
//! Ghostty diagnostics (unknown key, invalid value) raise one notice with
//! the first three, once per distinct set; it goes away when fixed.

const std = @import("std");
const builtin = @import("builtin");

const App = @import("../App.zig");
const RuntimeEnv = @import("../app/runtime_env.zig").RuntimeEnv;
const app_paths = @import("../app/paths.zig");
const configpkg = @import("../../../config.zig");
const notice = @import("../ui/notice.zig");

const Allocator = std.mem.Allocator;
const Config = configpkg.Config;
const log = std.log.scoped(.settings);

/// The overlay file name under CONFIG.
pub const overlay_name = "config.ghostty";
/// The generated overrides file under STATE.
pub const overrides_dir = "run";
pub const overrides_name = "settings-overrides.ghostty";

/// The notice id of Ghostty diagnostics.
pub const diagnostics_notice_id = "ghostty.config_errors";

/// `CONFIG\config.ghostty` (app/paths.zig configDir). Caller owns.
pub fn overlayPath(gpa: Allocator, env: *const RuntimeEnv) ![]u8 {
    const dir = try app_paths.configDir(gpa, env);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, overlay_name });
}

/// `STATE\run\settings-overrides.ghostty`: under WMUX_STATE_DIR, else
/// `%LOCALAPPDATA%\wmux` (the STATE root of Appendix G.1, as for logs).
/// Caller owns.
pub fn overridesPath(gpa: Allocator, env: *const RuntimeEnv) ![]u8 {
    if (env.state_dir) |dir| return std.fs.path.join(gpa, &.{ dir, overrides_dir, overrides_name });
    const local = try std.process.getEnvVarOwned(gpa, "LOCALAPPDATA");
    defer gpa.free(local);
    return std.fs.path.join(gpa, &.{ local, "wmux", overrides_dir, overrides_name });
}

/// Loads the Ghostty configuration like `Config.load`, then the overlay
/// and the overrides file when they exist, then finalizes. `config-file`
/// lines inside the overlay are not followed (only the user config's).
pub fn loadConfig(gpa: Allocator, env: *const RuntimeEnv) !Config {
    var cfg = try Config.default(gpa);
    errdefer cfg.deinit();
    try cfg.loadDefaultFiles(gpa);
    try cfg.loadCliArgs(gpa);
    try cfg.loadRecursiveFiles(gpa);
    try loadExtras(gpa, &cfg, env);
    try cfg.finalize();
    return cfg;
}

fn loadExtras(gpa: Allocator, cfg: *Config, env: *const RuntimeEnv) !void {
    if (overlayPath(gpa, env)) |p| {
        defer gpa.free(p);
        if (std.fs.path.isAbsolute(p)) _ = cfg.loadOptionalFile(gpa, p);
    } else |err| log.warn("ghostty overlay path unavailable: {}", .{err});
    if (overridesPath(gpa, env)) |p| {
        defer gpa.free(p);
        if (std.fs.path.isAbsolute(p)) _ = cfg.loadOptionalFile(gpa, p);
    } else |err| log.warn("settings overrides path unavailable: {}", .{err});
}

/// Whether the overlay or the overrides file has any setting line, i.e.
/// whether a configuration loaded without them would differ.
pub fn extrasPresent(gpa: Allocator, env: *const RuntimeEnv) bool {
    inline for (.{ overlayPath, overridesPath }) |f| {
        if (f(gpa, env)) |p| {
            defer gpa.free(p);
            if (hasSettingLine(gpa, p)) return true;
        } else |_| {}
    }
    return false;
}

fn hasSettingLine(gpa: Allocator, path: []const u8) bool {
    const text = std.fs.cwd().readFileAlloc(gpa, path, 4 * 1024 * 1024) catch return false;
    defer gpa.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] != '#') return true;
    }
    return false;
}

/// Writes `text` to `path` (creating its directory) unless the file
/// already holds exactly `text`; temp file + rename, so Ghostty never
/// reads a half-written file. Returns whether the file changed.
pub fn writeIfChanged(gpa: Allocator, path: []const u8, text: []const u8) !bool {
    if (std.fs.cwd().readFileAlloc(gpa, path, 4 * 1024 * 1024)) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, text)) return false;
    } else |_| {}
    const dir_path = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    const base = std.fs.path.basename(path);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.wmux-tmp", .{base});
    defer gpa.free(tmp);
    try dir.writeFile(.{ .sub_path = tmp, .data = text });
    errdefer dir.deleteFile(tmp) catch {};
    try dir.rename(tmp, base);
    return true;
}

/// One Ghostty file the watcher watches.
pub const WatchedFile = struct { path: []u8 };

/// The Ghostty configuration files to watch: the default files (when
/// `config-default-files` is on), every `config-file` (CLI and includes)
/// and the overlay. Caller frees with `freeWatched`.
pub fn watchedFiles(gpa: Allocator, cfg: *const Config, env: *const RuntimeEnv) Allocator.Error![]WatchedFile {
    var out: std.ArrayList(WatchedFile) = .empty;
    errdefer freeWatchedList(gpa, &out);
    if (cfg.@"config-default-files") {
        if (configpkg.preferredDefaultFilePath(gpa)) |p| {
            defer gpa.free(p);
            if (std.fs.path.dirname(p)) |dir| {
                for ([_][]const u8{ "config", "config.ghostty" }) |name| {
                    try out.append(gpa, .{ .path = try std.fs.path.join(gpa, &.{ dir, name }) });
                }
            }
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }
    for (cfg.@"config-file".value.items) |item| {
        const p: []const u8 = switch (item) {
            inline else => |s| s,
        };
        if (!std.fs.path.isAbsolute(p)) continue;
        try out.append(gpa, .{ .path = try gpa.dupe(u8, p) });
    }
    if (overlayPath(gpa, env)) |p| {
        try out.append(gpa, .{ .path = p });
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

fn freeWatchedList(gpa: Allocator, list: *std.ArrayList(WatchedFile)) void {
    for (list.items) |w| gpa.free(w.path);
    list.deinit(gpa);
}

pub fn freeWatched(gpa: Allocator, files: []WatchedFile) void {
    for (files) |w| gpa.free(w.path);
    gpa.free(files);
}

/// Hash of the diagnostics shown last (0 = none), so the same set does
/// not re-raise a notice the user dismissed. UI thread only.
var shown_diagnostics: u64 = 0;

/// Raises (or clears) the Ghostty diagnostics notice for `cfg`: the first
/// three diagnostics, once per distinct set. UI thread.
pub fn reportDiagnostics(app: *App, cfg: *const Config) void {
    const items = cfg._diagnostics.items();
    if (items.len == 0) {
        if (shown_diagnostics != 0) notice.dismiss(app, diagnostics_notice_id);
        shown_diagnostics = 0;
        return;
    }
    const gpa = app.core_app.alloc;
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var h = std.hash.Wyhash.init(0x67686f);
    var first_file: ?[]const u8 = null;
    for (items, 0..) |*d, i| {
        var one: std.Io.Writer.Allocating = .init(gpa);
        defer one.deinit();
        d.format(&one.writer) catch continue;
        h.update(one.written());
        if (first_file == null) switch (d.location) {
            .file => |f| first_file = f.path,
            else => {},
        };
        if (i < 3) {
            if (i > 0) body.writer.writeByte('\n') catch {};
            body.writer.writeAll(one.written()) catch {};
        }
    }
    if (items.len > 3) body.writer.print("\n(and {d} more)", .{items.len - 3}) catch {};
    const hash = h.final() | 1;
    log.warn("ghostty config diagnostics count={d}", .{items.len});
    if (hash == shown_diagnostics) return;
    shown_diagnostics = hash;
    notice.show(app, .{
        .id = diagnostics_notice_id,
        .level = .warning,
        .title = "Ghostty configuration errors",
        .body = body.written(),
        .action = if (first_file) |f| .{ .label = "Open", .target = .{ .open = f } } else null,
    });
}

test "unit: settings: overrides file is rewritten only when it changes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "run", overrides_name });
    defer gpa.free(path);
    try std.testing.expect(try writeIfChanged(gpa, path, "copy-on-select = true\n"));
    try std.testing.expect(!try writeIfChanged(gpa, path, "copy-on-select = true\n"));
    try std.testing.expect(try writeIfChanged(gpa, path, "# none\n"));
    try std.testing.expect(!hasSettingLine(gpa, path));

    const env: RuntimeEnv = .{ .state_dir = "C:\\st", .config_dir = "C:\\cfg" };
    const o = try overridesPath(gpa, &env);
    defer gpa.free(o);
    try std.testing.expectEqualStrings("C:\\st\\run\\settings-overrides.ghostty", o);
    const ov = try overlayPath(gpa, &env);
    defer gpa.free(ov);
    try std.testing.expectEqualStrings("C:\\cfg\\config.ghostty", ov);
}
