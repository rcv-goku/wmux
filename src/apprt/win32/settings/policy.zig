//! Managed policy layer (ARCHITECTURE.md ADR-5.7): values under
//! `HKLM\Software\Policies\wmux`, then `HKCU\Software\Policies\wmux`,
//! named by setting path (`REG_SZ` JSON literal, or `REG_DWORD` for
//! booleans and integers). HKLM beats HKCU (`resolve.policyValueFor`). In
//! test mode `WMUX_TEST_POLICY_FILE` names a JSON file that replaces the
//! registry (`layers.parsePolicyFile`), so tests never need admin rights
//! or touch the machine's policies.
//!
//! The watcher re-reads policy on registry change notifications for
//! `Software\Policies` in both hives (the writes Group Policy makes before
//! it broadcasts `WM_SETTINGCHANGE("Policy")`), on changes of the test
//! file and every 60 s. W7 (`policy` feature) ships the ADMX template.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("wmux_proto");

const layers = @import("logic/layers.zig");
const w32 = @import("../platform/win32.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.settings);

/// The test-mode policy file variable (Appendix G.2 test inputs).
pub const test_file_env = "WMUX_TEST_POLICY_FILE";

/// Registry key of the wmux policies, below each hive.
pub const policy_key = "Software\\Policies\\wmux";
/// The key watched for changes (wmux's own key may not exist yet).
pub const policies_parent_key = "Software\\Policies";

pub const HKEY_LOCAL_MACHINE: w32.HKEY = @ptrFromInt(0x80000002);
const REG_SZ: u32 = 1;
const REG_EXPAND_SZ: u32 = 2;
const KEY_NOTIFY: u32 = 0x0010;
const ERROR_NO_MORE_ITEMS: u32 = 259;
const ERROR_MORE_DATA: u32 = 234;
pub const REG_NOTIFY_CHANGE_NAME: u32 = 0x1;
pub const REG_NOTIFY_CHANGE_LAST_SET: u32 = 0x4;

extern "advapi32" fn RegEnumValueW(
    hKey: w32.HKEY,
    dwIndex: u32,
    lpValueName: [*]u16,
    lpcchValueName: *u32,
    lpReserved: ?*u32,
    lpType: ?*u32,
    lpData: ?[*]u8,
    lpcbData: ?*u32,
) callconv(.winapi) u32;

pub extern "advapi32" fn RegNotifyChangeKeyValue(
    hKey: w32.HKEY,
    bWatchSubtree: i32,
    dwNotifyFilter: u32,
    hEvent: ?std.os.windows.HANDLE,
    fAsynchronous: i32,
) callconv(.winapi) u32;

/// One read of the policy values.
pub const Values = struct {
    arena: std.heap.ArenaAllocator,
    items: []const layers.PolicyValue = &.{},
    fingerprint: u64 = 0,

    pub fn deinit(self: *Values) void {
        self.arena.deinit();
    }
};

/// The test policy file path when test mode allows one (caller owns).
/// The variable is read here rather than in app/runtime_env.zig (not
/// owned by the settings layer); only test mode honors it.
pub fn testFilePath(gpa: Allocator, test_mode: bool) ?[]u8 {
    if (!test_mode) return null;
    const v = std.process.getEnvVarOwned(gpa, test_file_env) catch return null;
    if (v.len == 0) {
        gpa.free(v);
        return null;
    }
    return v;
}

/// Reads the policy values: from `test_file` when given (a missing or
/// broken file means no policy, logged), otherwise from the registry.
pub fn read(gpa: Allocator, test_file: ?[]const u8) Allocator.Error!Values {
    var v: Values = .{ .arena = .init(gpa) };
    errdefer v.deinit();
    const a = v.arena.allocator();
    if (test_file) |path| {
        v.items = readFile(a, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    } else {
        var list: std.ArrayList(layers.PolicyValue) = .empty;
        try readHive(a, &list, HKEY_LOCAL_MACHINE, .hklm);
        try readHive(a, &list, w32.HKEY_CURRENT_USER, .hkcu);
        v.items = try list.toOwnedSlice(a);
    }
    v.fingerprint = layers.policyFingerprint(v.items);
    return v;
}

fn readFile(a: Allocator, path: []const u8) Allocator.Error![]const layers.PolicyValue {
    const src = std.fs.cwd().readFileAlloc(a, path, 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return &.{},
        else => {
            log.warn("policy test file {s} unreadable: {s}", .{ path, @errorName(err) });
            return &.{};
        },
    };
    var diag: proto.jsonc.Diagnostic = .{};
    return layers.parsePolicyFile(a, src, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            log.warn("policy test file {s}:{d}:{d}: {s}", .{ path, diag.pos.line, diag.pos.col, diag.message });
            return &.{};
        },
        error.NotAnObject => {
            log.warn("policy test file {s}: not a JSON object", .{path});
            return &.{};
        },
    };
}

fn readHive(a: Allocator, list: *std.ArrayList(layers.PolicyValue), hive: w32.HKEY, tag: proto.settings.resolve.PolicyHive) Allocator.Error!void {
    if (comptime builtin.os.tag != .windows) return;
    const key_w = std.unicode.utf8ToUtf16LeStringLiteral(policy_key);
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(hive, key_w, 0, w32.KEY_READ, &key) != w32.ERROR_SUCCESS) return;
    defer _ = w32.RegCloseKey(key);
    var index: u32 = 0;
    var name_buf: [512]u16 = undefined;
    var data_buf: [16 * 1024]u8 align(2) = undefined;
    while (index < 4096) : (index += 1) {
        var name_len: u32 = name_buf.len;
        var data_len: u32 = data_buf.len;
        var ty: u32 = 0;
        const rc = RegEnumValueW(key, index, &name_buf, &name_len, null, &ty, &data_buf, &data_len);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc == ERROR_MORE_DATA) continue; // oversized value: ignored
        if (rc != w32.ERROR_SUCCESS) break;
        const name = std.unicode.utf16LeToUtf8Alloc(a, name_buf[0..name_len]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        switch (ty) {
            w32.REG_DWORD => if (data_len >= 4) {
                const d = std.mem.readInt(u32, data_buf[0..4], .little);
                try list.append(a, .{ .path = name, .hive = tag, .data = .{ .dword = d } });
            },
            REG_SZ, REG_EXPAND_SZ => {
                const units: []const u16 = @as([*]const u16, @ptrCast(&data_buf))[0 .. data_len / 2];
                const trimmed = std.mem.sliceTo(units, 0);
                const text = std.unicode.utf16LeToUtf8Alloc(a, trimmed) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try list.append(a, .{ .path = name, .hive = tag, .data = .{ .json = text } });
            },
            else => {},
        }
    }
}

/// Opens `HKLM`/`HKCU` `Software\Policies` for change notification, or
/// null when it cannot be opened.
pub fn openNotifyKey(hive: w32.HKEY) ?w32.HKEY {
    if (comptime builtin.os.tag != .windows) return null;
    const key_w = std.unicode.utf8ToUtf16LeStringLiteral(policies_parent_key);
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(hive, key_w, 0, KEY_NOTIFY, &key) != w32.ERROR_SUCCESS) return null;
    return key;
}

/// Arms an asynchronous change notification of `key` on `event`.
pub fn armNotify(key: w32.HKEY, event: std.os.windows.HANDLE) bool {
    return RegNotifyChangeKeyValue(key, 1, REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET, event, 1) == w32.ERROR_SUCCESS;
}

test "unit: settings: policy test file replaces the registry" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "policy.json", .data = "{\"HKLM\": {\"automation.socketControlMode\": \"allowAll\"}}" });
    const path = try tmp.dir.realpathAlloc(gpa, "policy.json");
    defer gpa.free(path);
    var v = try read(gpa, path);
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 1), v.items.len);
    try std.testing.expectEqualStrings("\"allowAll\"", v.items[0].data.json);

    try tmp.dir.writeFile(.{ .sub_path = "broken.json", .data = "{" });
    const broken = try tmp.dir.realpathAlloc(gpa, "broken.json");
    defer gpa.free(broken);
    var b = try read(gpa, broken);
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 0), b.items.len);
    try std.testing.expect(testFilePath(gpa, false) == null);
}
