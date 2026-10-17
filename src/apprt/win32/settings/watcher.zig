//! The settings watcher (ARCHITECTURE.md ADR-5.4): one worker thread with
//! an overlapped `ReadDirectoryChangesW` per distinct directory of the
//! watched files (cmux.json, wmux.json, packs, the project file, the
//! Ghostty config files and includes, the overlay, the policy test file),
//! symlinks resolved to their targets (whose directories are watched
//! too), a 300 ms debounce, content hashes that skip no-op saves and
//! self-writes, registry change notifications on `Software\Policies` and a
//! 60 s policy poll. JSON layers are re-read and resolved on this thread;
//! the result (a snapshot, or the parse errors) is posted to the UI
//! thread through `app.tasks`. A changed Ghostty file posts a Ghostty
//! reload instead (the existing `reload_config` path).
//!
//! The thread never touches App state: it owns its inputs, and the UI
//! thread hands it the Ghostty file list and legacy keys after every
//! Ghostty load (`setGhostty`) or asks for a forced reload (`requestReload`).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const App = @import("../App.zig");
const api = @import("api.zig");
const debounce = @import("logic/debounce.zig");
const ghostty_layer = @import("ghostty_layer.zig");
const layers = @import("logic/layers.zig");
const legacy_keys = @import("legacy_keys.zig");
const loader = @import("loader.zig");
const policy = @import("policy.zig");
const snapshot = @import("snapshot.zig");
const tasks = @import("../app/tasks.zig");
const w32 = @import("../platform/win32.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.settings);

/// At most this many directories are watched (WaitForMultipleObjects
/// takes 64 handles; four are the stop/wake events and the two registry
/// notifications). Files beyond it are still picked up by the 60 s poll.
const max_dirs = 56;

/// What the watcher re-reads; the strings are owned by the watcher.
pub const BaseInputs = struct {
    cmux_path: ?[]const u8 = null,
    wmux_path: ?[]const u8 = null,
    project_cwd: ?[]const u8 = null,
    home: ?[]const u8 = null,
    policy_file: ?[]const u8 = null,
};

/// Result of a JSON reload, posted to the UI thread.
pub const ReloadTask = struct {
    task: tasks.Task = .{ .run = run, .destroy = destroy },
    gpa: Allocator,
    outcome: loader.Outcome,
    triggers: debounce.Triggers,
    /// The overrides file was rewritten: Ghostty must reload once.
    overrides_changed: bool,

    fn run(app: *App, task: *tasks.Task) void {
        const self: *ReloadTask = @fieldParentPtr("task", task);
        api.onReload(app, self);
    }

    fn destroy(task: *tasks.Task) void {
        const self: *ReloadTask = @fieldParentPtr("task", task);
        switch (self.outcome) {
            .ok => |s| s.release(), // api.onReload took its own reference
            .failed => |*f| f.deinit(),
        }
        self.gpa.destroy(self);
    }
};

/// A Ghostty config file changed: reload the Ghostty configuration.
pub const GhosttyTask = struct {
    task: tasks.Task = .{ .run = run, .destroy = destroy },
    gpa: Allocator,

    fn run(app: *App, task: *tasks.Task) void {
        _ = task;
        api.reloadGhostty(app, "file");
    }

    fn destroy(task: *tasks.Task) void {
        const self: *GhosttyTask = @fieldParentPtr("task", task);
        self.gpa.destroy(self);
    }
};

const FileKind = enum { settings, ghostty, policy };

/// One file whose directory is watched.
const Watched = struct {
    kind: FileKind,
    /// Full path as configured (the loader's view).
    path: []u8,
};

/// One watched directory.
const DirWatch = struct {
    path: []u8,
    handle: windows.HANDLE,
    event: windows.HANDLE,
    overlapped: windows.OVERLAPPED,
    buffer: [16 * 1024]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)),
    /// Base names of the watched files in this directory.
    names: std.ArrayList([]u8),
    /// Watches the whole subtree (an ancestor of a missing directory).
    subtree: bool = false,
};

pub const Watcher = struct {
    gpa: Allocator,
    app: *App,
    thread: ?std.Thread = null,
    stop_event: windows.HANDLE,
    wake_event: windows.HANDLE,

    // Shared with the UI thread (under `mutex`).
    mutex: std.Thread.Mutex = .{},
    req_manual: bool = false,
    ghostty_dirty: bool = false,
    shared_ghostty_files: std.ArrayList([]u8) = .empty,
    shared_pairs_arena: std.heap.ArenaAllocator,
    shared_pairs: []const layers.GhosttyPair = &.{},

    // Owned by the watcher thread after `start`.
    base: BaseInputs,
    base_arena: std.heap.ArenaAllocator,
    pairs_arena: std.heap.ArenaAllocator,
    pairs: []const layers.GhosttyPair = &.{},
    pairs_fp: u64 = 0,
    settings_files: std.ArrayList([]u8) = .empty,
    ghostty_files: std.ArrayList([]u8) = .empty,
    book: debounce.HashBook = .{},
    policy_values: ?policy.Values = null,
    dirs: std.ArrayList(*DirWatch) = .empty,

    /// Creates the watcher (not started). `seed` is the startup snapshot's
    /// file list (its hashes seed the change detection), `pairs` the
    /// startup legacy keys and `policy_values` the startup policy (taken
    /// over).
    pub fn create(
        gpa: Allocator,
        app: *App,
        base: BaseInputs,
        seed: []const snapshot.FileRecord,
        pairs: []const layers.GhosttyPair,
        ghostty_files: []const ghostty_layer.WatchedFile,
        policy_values: policy.Values,
    ) !*Watcher {
        const self = try gpa.create(Watcher);
        errdefer gpa.destroy(self);
        const stop = w32.CreateEventW(null, 1, 0, null) orelse return error.Win32Error;
        errdefer _ = w32.CloseHandle(stop);
        const wake = w32.CreateEventW(null, 0, 0, null) orelse return error.Win32Error;
        self.* = .{
            .gpa = gpa,
            .app = app,
            .stop_event = stop,
            .wake_event = wake,
            .shared_pairs_arena = .init(gpa),
            .base = .{},
            .base_arena = .init(gpa),
            .pairs_arena = .init(gpa),
            .policy_values = policy_values,
        };
        const ba = self.base_arena.allocator();
        inline for (std.meta.fields(BaseInputs)) |f| {
            if (@field(base, f.name)) |v| @field(self.base, f.name) = try ba.dupe(u8, v);
        }
        self.pairs = try dupePairs(self.pairs_arena.allocator(), pairs);
        self.pairs_fp = legacy_keys.fingerprint(self.pairs);
        _ = try self.adoptSettingsFiles(seed, true);
        for (ghostty_files) |g| try self.ghostty_files.append(gpa, try gpa.dupe(u8, g.path));
        return self;
    }

    /// Starts the thread (UI thread, once `app.tasks` delivers).
    pub fn start(self: *Watcher) void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
            log.warn("settings watcher thread failed to start: {}", .{err});
            return;
        };
    }

    /// Stops the thread and frees everything (UI thread).
    pub fn destroy(self: *Watcher) void {
        _ = w32.SetEvent(self.stop_event);
        if (self.thread) |t| t.join();
        self.closeDirs();
        self.dirs.deinit(self.gpa);
        _ = w32.CloseHandle(self.stop_event);
        _ = w32.CloseHandle(self.wake_event);
        freeList(self.gpa, &self.shared_ghostty_files);
        freeList(self.gpa, &self.settings_files);
        freeList(self.gpa, &self.ghostty_files);
        self.shared_pairs_arena.deinit();
        self.base_arena.deinit();
        self.pairs_arena.deinit();
        self.book.deinit(self.gpa);
        if (self.policy_values) |*v| v.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Re-read every JSON layer now, without debounce and even when no
    /// file changed (reloadConfiguration, `config reload`). Any thread.
    pub fn requestReload(self: *Watcher) void {
        self.mutex.lock();
        self.req_manual = true;
        self.mutex.unlock();
        _ = w32.SetEvent(self.wake_event);
    }

    /// The Ghostty configuration was (re)loaded: its files and its
    /// explicitly set legacy keys. UI thread.
    pub fn setGhostty(self: *Watcher, files: []const ghostty_layer.WatchedFile, pairs: []const layers.GhosttyPair) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        freeList(self.gpa, &self.shared_ghostty_files);
        for (files) |f| {
            const copy = self.gpa.dupe(u8, f.path) catch break;
            self.shared_ghostty_files.append(self.gpa, copy) catch {
                self.gpa.free(copy);
                break;
            };
        }
        _ = self.shared_pairs_arena.reset(.retain_capacity);
        self.shared_pairs = dupePairs(self.shared_pairs_arena.allocator(), pairs) catch &.{};
        self.ghostty_dirty = true;
        _ = w32.SetEvent(self.wake_event);
    }

    // -----------------------------------------------------------------
    // Thread

    fn threadMain(self: *Watcher) void {
        var poll = debounce.PollClock.init(now());
        var quiet: debounce.Debouncer = .{};
        var triggers: debounce.Triggers = .{};

        self.seedGhosttyHashes();
        self.rebuildDirs();

        var reg_events: [2]?windows.HANDLE = .{ null, null };
        var reg_keys: [2]?w32.HKEY = .{ null, null };
        if (self.base.policy_file == null) {
            for ([_]w32.HKEY{ policy.HKEY_LOCAL_MACHINE, w32.HKEY_CURRENT_USER }, 0..) |hive, i| {
                const key = policy.openNotifyKey(hive) orelse continue;
                const ev = w32.CreateEventW(null, 0, 0, null) orelse {
                    _ = w32.RegCloseKey(key);
                    continue;
                };
                if (!policy.armNotify(key, ev)) {
                    _ = w32.CloseHandle(ev);
                    _ = w32.RegCloseKey(key);
                    continue;
                }
                reg_keys[i] = key;
                reg_events[i] = ev;
            }
        }
        defer for (reg_keys, reg_events) |k, e| {
            if (k) |key| _ = w32.RegCloseKey(key);
            if (e) |ev| _ = w32.CloseHandle(ev);
        };

        log.info("settings watcher started dirs={d} files={d}", .{ self.dirs.items.len, self.settings_files.items.len + self.ghostty_files.items.len });
        // Changes made between the startup load and arming the watches.
        self.checkAll(&triggers, false);

        while (true) {
            var handles: [64]windows.HANDLE = undefined;
            var n: usize = 0;
            handles[n] = self.stop_event;
            n += 1;
            handles[n] = self.wake_event;
            n += 1;
            const reg_base = n;
            var reg_slot: [2]?usize = .{ null, null };
            for (reg_events, 0..) |e, i| if (e) |ev| {
                reg_slot[i] = n;
                handles[n] = ev;
                n += 1;
            };
            const dir_base = n;
            _ = reg_base;
            for (self.dirs.items) |d| {
                handles[n] = d.event;
                n += 1;
            }

            const timeout = debounce.waitTimeoutMs(&quiet, &poll, now());
            const rc = windows.kernel32.WaitForMultipleObjectsEx(@intCast(n), &handles, 0, timeout, 0);
            const t = now();
            if (rc == w32.WAIT_OBJECT_0) break; // stop
            if (rc == w32.WAIT_OBJECT_0 + 1) {
                self.onWake(&triggers);
            } else if (rc >= w32.WAIT_OBJECT_0 + 2 and rc < w32.WAIT_OBJECT_0 + n) {
                const idx: usize = rc - w32.WAIT_OBJECT_0;
                if (idx >= dir_base) {
                    if (self.onDirEvent(self.dirs.items[idx - dir_base])) quiet.touch(t);
                } else {
                    for (reg_slot, 0..) |slot, i| if (slot == idx) {
                        if (reg_keys[i]) |key| _ = policy.armNotify(key, reg_events[i].?);
                        triggers.add(.policy);
                        quiet.touch(t);
                    };
                }
            } else if (rc != w32.WAIT_TIMEOUT) {
                log.warn("settings watcher wait failed rc={d}", .{rc});
                std.Thread.sleep(250 * std.time.ns_per_ms);
            }

            if (quiet.fire(now())) self.checkAll(&triggers, false);
            if (poll.due(now())) {
                triggers.add(.policy);
                self.checkAll(&triggers, false);
            }
        }
    }

    fn onWake(self: *Watcher, triggers: *debounce.Triggers) void {
        var manual = false;
        var ghostty_changed = false;
        var pairs_changed = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            manual = self.req_manual;
            self.req_manual = false;
            if (self.ghostty_dirty) {
                self.ghostty_dirty = false;
                ghostty_changed = !sameList(self.ghostty_files.items, self.shared_ghostty_files.items);
                if (ghostty_changed) {
                    freeList(self.gpa, &self.ghostty_files);
                    for (self.shared_ghostty_files.items) |p| {
                        const copy = self.gpa.dupe(u8, p) catch break;
                        self.ghostty_files.append(self.gpa, copy) catch {
                            self.gpa.free(copy);
                            break;
                        };
                    }
                }
                const fp = legacy_keys.fingerprint(self.shared_pairs);
                if (fp != self.pairs_fp) {
                    _ = self.pairs_arena.reset(.retain_capacity);
                    self.pairs = dupePairs(self.pairs_arena.allocator(), self.shared_pairs) catch &.{};
                    self.pairs_fp = fp;
                    pairs_changed = true;
                }
            }
        }
        if (ghostty_changed) {
            self.seedGhosttyHashes();
            self.rebuildDirs();
        }
        if (pairs_changed) triggers.add(.ghostty);
        if (manual) {
            triggers.add(.manual);
            self.checkAll(triggers, true);
        } else if (pairs_changed) {
            self.checkAll(triggers, true);
        }
    }

    /// Reads the change records of `d`; true when one names a watched file.
    fn onDirEvent(self: *Watcher, d: *DirWatch) bool {
        _ = self;
        var bytes: windows.DWORD = 0;
        const ok = windows.kernel32.GetOverlappedResult(d.handle, &d.overlapped, &bytes, 0);
        var hit = false;
        if (ok == 0 or bytes == 0) {
            // Overflow or error: treat as a change of every file here.
            hit = true;
        } else {
            var off: usize = 0;
            while (off < bytes) {
                const info: *const windows.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&d.buffer[off]));
                const name_ptr: [*]const u16 = @ptrCast(@alignCast(&d.buffer[off + @sizeOf(windows.FILE_NOTIFY_INFORMATION)]));
                const name_w = name_ptr[0 .. info.FileNameLength / 2];
                var name_buf: [520]u8 = undefined;
                if (name_w.len <= 256) {
                    if (std.unicode.utf16LeToUtf8(&name_buf, name_w)) |len| {
                        for (d.names.items) |want| {
                            if (debounce.recordNames(name_buf[0..len], want)) hit = true;
                        }
                    } else |_| {}
                }
                if (info.NextEntryOffset == 0) break;
                off += info.NextEntryOffset;
            }
        }
        armDir(d);
        return hit;
    }

    /// Compares every watched file (and the policy) with what the last
    /// load saw; reloads the JSON layers or the Ghostty config as needed.
    fn checkAll(self: *Watcher, triggers: *debounce.Triggers, force: bool) void {
        const gpa = self.gpa;
        // Ghostty files first: a Ghostty reload re-feeds the legacy keys.
        var ghostty_changed = false;
        for (self.ghostty_files.items) |p| {
            if (self.book.update(gpa, p, hashFile(gpa, p)) catch false) ghostty_changed = true;
        }
        if (ghostty_changed) {
            const t = gpa.create(GhosttyTask) catch null;
            if (t) |task| {
                task.* = .{ .gpa = gpa };
                self.app.tasks.post(&task.task);
            }
        }

        for (self.settings_files.items) |p| {
            if (self.book.update(gpa, p, hashFile(gpa, p)) catch false) triggers.add(self.kindOf(p));
        }
        // A project file that appeared since the last load.
        if (self.base.project_cwd) |cwd| {
            if (loader.findProjectFile(gpa, cwd, self.base.home) catch null) |p| {
                defer gpa.free(p);
                if (!containsPath(self.settings_files.items, p)) triggers.add(.project);
            }
        }
        if (self.base.policy_file) |pf| {
            if (self.book.update(gpa, pf, hashFile(gpa, pf)) catch false) triggers.add(.policy);
        }
        if (triggers.has(.policy)) {
            const fresh = policy.read(gpa, self.base.policy_file) catch null;
            if (fresh) |v| {
                const old_fp = if (self.policy_values) |pv| pv.fingerprint else 0;
                if (v.fingerprint == old_fp and !force and onlyPolicy(triggers.*)) {
                    var tmp = v;
                    tmp.deinit();
                    triggers.* = .{};
                    return;
                }
                if (self.policy_values) |*pv| pv.deinit();
                self.policy_values = v;
            }
        }
        if (triggers.isEmpty() and !force) return;
        self.load(triggers.*);
        triggers.* = .{};
    }

    fn onlyPolicy(t: debounce.Triggers) bool {
        var only: debounce.Triggers = .{};
        only.add(.policy);
        return t.bits == only.bits;
    }

    fn kindOf(self: *Watcher, path: []const u8) debounce.Triggers.Kind {
        if (self.base.cmux_path) |c| if (std.ascii.eqlIgnoreCase(c, path)) return .cmux_json;
        if (self.base.wmux_path) |w| if (std.ascii.eqlIgnoreCase(w, path)) return .wmux_json;
        const base = std.fs.path.basename(path);
        if (std.ascii.endsWithIgnoreCase(base, ".pack.json")) return .pack;
        if (self.base.project_cwd != null and (std.ascii.eqlIgnoreCase(base, "wmux.json") or std.ascii.eqlIgnoreCase(base, "cmux.json"))) return .project;
        return .pack;
    }

    /// Re-reads and resolves the JSON layers and posts the result.
    fn load(self: *Watcher, triggers: debounce.Triggers) void {
        const gpa = self.gpa;
        const outcome = loader.load(gpa, .{
            .cmux_path = self.base.cmux_path,
            .wmux_path = self.base.wmux_path,
            .project_cwd = self.base.project_cwd,
            .home = self.base.home,
            .ghostty_pairs = self.pairs,
            .policy = if (self.policy_values) |v| v.items else &.{},
            .policy_file = self.base.policy_file,
        }) catch {
            log.warn("settings reload out of memory", .{});
            return;
        };
        const files = switch (outcome) {
            .ok => |s| s.files,
            .failed => |f| f.files,
        };
        const files_changed = self.adoptSettingsFiles(files, false) catch false;
        if (files_changed) self.rebuildDirs();

        var overrides_changed = false;
        switch (outcome) {
            .ok => |s| {
                if (ghostty_layer.overridesPath(gpa, &self.app.runtime_env)) |path| {
                    defer gpa.free(path);
                    overrides_changed = ghostty_layer.writeIfChanged(gpa, path, s.ghostty_overrides) catch |err| blk: {
                        log.warn("settings overrides write failed: {}", .{err});
                        break :blk false;
                    };
                } else |_| {}
            },
            .failed => {},
        }
        const task = gpa.create(ReloadTask) catch {
            var o = outcome;
            switch (o) {
                .ok => |s| s.release(),
                .failed => |*f| f.deinit(),
            }
            return;
        };
        task.* = .{ .gpa = gpa, .outcome = outcome, .triggers = triggers, .overrides_changed = overrides_changed };
        self.app.tasks.post(&task.task);
    }

    /// Replaces the settings file list with `files` (paths, and the
    /// hashes the load saw). Returns whether the list changed.
    fn adoptSettingsFiles(self: *Watcher, files: []const snapshot.FileRecord, seed: bool) !bool {
        const gpa = self.gpa;
        var changed = files.len != self.settings_files.items.len;
        for (files) |f| {
            if (f.kind == .policy_file) continue;
            if (!containsPath(self.settings_files.items, f.path)) changed = true;
        }
        for (files) |f| {
            if (f.kind == .policy_file) continue;
            _ = try self.book.update(gpa, f.path, f.hash);
        }
        if (!changed and !seed) return false;
        freeList(gpa, &self.settings_files);
        for (files) |f| {
            if (f.kind == .policy_file) continue;
            try self.settings_files.append(gpa, try gpa.dupe(u8, f.path));
        }
        if (self.base.policy_file) |pf| _ = try self.book.update(gpa, pf, hashFile(gpa, pf));
        return true;
    }

    fn seedGhosttyHashes(self: *Watcher) void {
        for (self.ghostty_files.items) |p| _ = self.book.update(self.gpa, p, hashFile(self.gpa, p)) catch {};
    }

    // -----------------------------------------------------------------
    // Directory watches

    fn closeDirs(self: *Watcher) void {
        for (self.dirs.items) |d| {
            _ = windows.kernel32.CancelIoEx(d.handle, &d.overlapped);
            var bytes: windows.DWORD = 0;
            _ = windows.kernel32.GetOverlappedResult(d.handle, &d.overlapped, &bytes, 1);
            windows.CloseHandle(d.handle);
            _ = w32.CloseHandle(d.event);
            freeList(self.gpa, &d.names);
            self.gpa.free(d.path);
            self.gpa.destroy(d);
        }
        self.dirs.clearRetainingCapacity();
    }

    /// Watches the directory of every file (and of its symlink target).
    fn rebuildDirs(self: *Watcher) void {
        self.closeDirs();
        const gpa = self.gpa;
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(gpa);
        all.appendSlice(gpa, self.settings_files.items) catch {};
        all.appendSlice(gpa, self.ghostty_files.items) catch {};
        if (self.base.policy_file) |p| all.append(gpa, p) catch {};
        if (self.base.project_cwd) |cwd| {
            // A project file created later in the start directory.
            for ([_][]const u8{ "wmux.json", "cmux.json" }) |name| {
                const p = std.fs.path.join(gpa, &.{ cwd, name }) catch continue;
                defer gpa.free(p);
                self.addWatch(p);
            }
        }
        for (all.items) |p| {
            self.addWatch(p);
            // Symlinks: also watch the target's directory, under the
            // target's name (GetFinalPathNameByHandleW via realpath).
            if (std.fs.cwd().realpathAlloc(gpa, p)) |real| {
                defer gpa.free(real);
                if (!std.ascii.eqlIgnoreCase(real, p)) self.addWatch(real);
            } else |_| {}
        }
    }

    fn addWatch(self: *Watcher, file: []const u8) void {
        const gpa = self.gpa;
        const name = std.fs.path.basename(file);
        // A missing directory (cmux.json before ~/.config/cmux exists) is
        // watched through its nearest existing ancestor, up to three
        // levels up, with a subtree watch; deeper gaps rely on the poll.
        var dir = std.fs.path.dirname(file) orelse return;
        var subtree = false;
        var up: usize = 0;
        while (!dirExists(dir)) : (up += 1) {
            if (up >= 3) return;
            dir = std.fs.path.dirname(dir) orelse return;
            subtree = true;
        }
        for (self.dirs.items) |d| {
            if (!std.ascii.eqlIgnoreCase(d.path, dir) or d.subtree != subtree) continue;
            for (d.names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) return;
            const copy = gpa.dupe(u8, name) catch return;
            d.names.append(gpa, copy) catch gpa.free(copy);
            return;
        }
        if (self.dirs.items.len >= max_dirs) return;
        const dir_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, dir) catch return;
        defer gpa.free(dir_w);
        const h = windows.kernel32.CreateFileW(
            dir_w,
            windows.FILE_LIST_DIRECTORY,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (h == windows.INVALID_HANDLE_VALUE) return; // directory missing: the poll covers it
        const ev = w32.CreateEventW(null, 1, 0, null) orelse {
            windows.CloseHandle(h);
            return;
        };
        const d = gpa.create(DirWatch) catch {
            windows.CloseHandle(h);
            _ = w32.CloseHandle(ev);
            return;
        };
        d.* = .{
            .path = gpa.dupe(u8, dir) catch {
                windows.CloseHandle(h);
                _ = w32.CloseHandle(ev);
                gpa.destroy(d);
                return;
            },
            .handle = h,
            .event = ev,
            .overlapped = std.mem.zeroes(windows.OVERLAPPED),
            .subtree = subtree,
            .buffer = undefined,
            .names = .empty,
        };
        if (gpa.dupe(u8, name)) |copy| {
            d.names.append(gpa, copy) catch gpa.free(copy);
        } else |_| {}
        self.dirs.append(gpa, d) catch {
            windows.CloseHandle(h);
            _ = w32.CloseHandle(ev);
            freeList(gpa, &d.names);
            gpa.free(d.path);
            gpa.destroy(d);
            return;
        };
        armDir(d);
    }
};

fn armDir(d: *DirWatch) void {
    _ = w32.ResetEvent(d.event);
    d.overlapped = std.mem.zeroes(windows.OVERLAPPED);
    d.overlapped.hEvent = d.event;
    const ok = windows.kernel32.ReadDirectoryChangesW(
        d.handle,
        &d.buffer,
        d.buffer.len,
        @intFromBool(d.subtree),
        .{ .file_name = true, .size = true, .last_write = true, .creation = true },
        null,
        &d.overlapped,
        null,
    );
    if (ok == 0) log.warn("ReadDirectoryChangesW failed for {s}", .{d.path});
}

fn dirExists(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

fn now() i64 {
    return std.time.milliTimestamp();
}

fn hashFile(gpa: Allocator, path: []const u8) ?u64 {
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, loader.max_file_bytes) catch return null;
    defer gpa.free(bytes);
    return debounce.contentHash(bytes);
}

fn freeList(gpa: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |p| gpa.free(p);
    list.clearAndFree(gpa);
}

fn containsPath(list: []const []u8, path: []const u8) bool {
    for (list) |p| if (std.ascii.eqlIgnoreCase(p, path)) return true;
    return false;
}

fn sameList(a: []const []u8, b: []const []u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.ascii.eqlIgnoreCase(x, y)) return false;
    return true;
}

fn dupePairs(arena: Allocator, pairs: []const layers.GhosttyPair) Allocator.Error![]const layers.GhosttyPair {
    const out = try arena.alloc(layers.GhosttyPair, pairs.len);
    for (pairs, out) |p, *o| o.* = .{ .key = try arena.dupe(u8, p.key), .value = try arena.dupe(u8, p.value) };
    return out;
}
