//! Which session a launch restores (ARCHITECTURE.md ADR-9.8): the v3
//! `session.json`, else `session.json.bak`, else `session-previous.json`
//! (logic/integrity.zig planLoad; an unusable primary is quarantined to
//! `session.unusable-<ms>.json`, a newer schema kept as
//! `session.schema-v<N>.json`), and the one-time migration of the legacy
//! file (`%LOCALAPPDATA%\ghostty\session-state.json`, v2 or v1, read by
//! logic/migrate_v2.zig) when no v3 file exists at all: converted into
//! window 0 with minted ids, the old `window-state` seeding its placement,
//! written as `session.json`, and the legacy file renamed
//! `session-state.json.migrated`. Automatic saves never write the v2 file
//! again.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const app_paths = @import("../../app/paths.zig");
const autosave = @import("autosave.zig");
const build_config = @import("../../../../build_config.zig");
const integrity = @import("logic/integrity.zig");
const markers = @import("markers.zig");
const migrate_v2 = @import("logic/migrate_v2.zig");
const placement_io = @import("placement_io.zig");
const schema = @import("logic/schema_v3.zig");

const log = std.log.scoped(.session);

const max_file = 64 * 1024 * 1024;

/// The session to restore at launch (owned), or null.
pub fn loadForLaunch(core: *autosave.Core) ?schema.Parsed {
    const gpa = core.gpa;
    const dir = core.session_dir;

    var observed: integrity.Observed = .{};
    const names = [_][]const u8{ integrity.session_file, integrity.backup_file, integrity.previous_file };
    var verdicts: [3]?integrity.Verdict = .{ null, null, null };
    for (names, 0..) |name, i| {
        const bytes = markers.readFile(gpa, dir, name, max_file) orelse continue;
        defer gpa.free(bytes);
        verdicts[i] = integrity.classify(gpa, bytes) catch .corrupt;
    }
    observed.primary = verdicts[0];
    observed.backup = verdicts[1];
    observed.previous = verdicts[2];

    if (integrity.shouldMigrateLegacy(observed, legacyExists(core.app))) {
        return migrateLegacy(core);
    }

    const plan = integrity.planLoad(observed);
    if (plan.quarantine) |q| switch (q) {
        .move_unusable => markers.quarantineUnusable(dir),
        .copy_schema_version => |v| markers.copySchemaVersion(gpa, dir, v),
    };
    switch (plan.notice) {
        .none => {},
        .recovered_from_backup, .recovered_from_previous => autosave.deferNotice(core, .{
            .id = "session.recovered",
            .level = .warning,
            .title = "The session file was unusable",
            .body = if (plan.notice == .recovered_from_backup) "Restored from session.json.bak." else "Restored from session-previous.json.",
        }),
        .newer_schema => autosave.deferNotice(core, .{
            .id = "session.newer_schema",
            .level = .warning,
            .title = "The session was saved by a newer wmux",
            .body = "It was kept aside and not restored.",
        }),
        .nothing_restorable => autosave.deferNotice(core, .{
            .id = "session.unusable",
            .level = .warning,
            .title = "No usable session to restore",
        }),
    }
    const source = plan.source orelse return null;
    const name = switch (source) {
        .primary => integrity.session_file,
        .backup => integrity.backup_file,
        .previous => integrity.previous_file,
    };
    const bytes = markers.readFile(gpa, dir, name, max_file) orelse return null;
    defer gpa.free(bytes);
    return schema.parse(gpa, bytes, .{}, null) catch |err| {
        log.warn("session file {s} failed to parse err={}", .{ name, err });
        return null;
    };
}

fn legacyExists(app: *const App) bool {
    const gpa = app.core_app.alloc;
    const path = app_paths.sessionStatePath(gpa, &app.runtime_env) catch return false;
    defer gpa.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Convert the legacy file, write it as `session.json`, rename the legacy
/// file, and return the migrated session.
fn migrateLegacy(core: *autosave.Core) ?schema.Parsed {
    const app = core.app;
    const gpa = core.gpa;
    const path = app_paths.sessionStatePath(gpa, &app.runtime_env) catch return null;
    defer gpa.free(path);
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, max_file) catch return null;
    defer gpa.free(bytes);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const result = migrate_v2.migrate(arena_state.allocator(), bytes, .{
        .random = std.crypto.random,
        .app_version = build_config.version_string,
        .now_ms = std.time.milliTimestamp(),
        .placement = placement_io.legacyPlacement(app),
    }) catch |err| {
        log.warn("legacy session migration failed err={}; the file is left alone", .{err});
        return null;
    };
    const json = schema.writeAlloc(gpa, &result.session, .{}) catch return null;
    defer gpa.free(json);
    core.writer.writeSync(json) catch |err| {
        log.warn("could not write the migrated session err={}", .{err});
        return null;
    };
    const migrated = std.fmt.allocPrint(gpa, "{s}{s}", .{ path, migrate_v2.migrated_suffix }) catch return null;
    defer gpa.free(migrated);
    std.fs.cwd().rename(path, migrated) catch |err|
        log.warn("could not rename the migrated legacy session err={}", .{err});
    log.info("migrated the v{d} session file to session v3", .{result.source_version});
    return schema.parse(gpa, json, .{}, null) catch null;
}

/// The legacy file at `path` as a v3 session (allocated in `arena`), for
/// the explicit legacy `session-restore` command (features/session/
/// legacy_v2.zig): nothing is written or renamed.
pub fn readLegacy(arena: Allocator, bytes: []const u8) !schema.Session {
    const result = try migrate_v2.migrate(arena, bytes, .{
        .random = std.crypto.random,
        .app_version = build_config.version_string,
        .now_ms = std.time.milliTimestamp(),
    });
    return result.session;
}
