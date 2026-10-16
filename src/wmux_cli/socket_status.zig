//! `cmux socket-status [--json]` (cli-socket-status-command, ADR-3.8): the
//! effective control-pipe access mode and where it came from, resolved the
//! way the app resolves it, WITHOUT connecting. Layers, lowest first:
//! default `cmuxOnly` < `~/.config/cmux/cmux.json` < `~/.config/wmux/wmux.json`
//! (`automation.socketControlMode`) < environment overrides
//! (`WMUX_SOCKET_MODE`/`CMUX_SOCKET_MODE`, `WMUX_SOCKET_ENABLE`/
//! `CMUX_SOCKET_ENABLE`) < managed policy
//! `HKLM|HKCU\Software\Policies\wmux\SocketControlMode`, which only accepts
//! `cmuxOnly` or `off` (anything else forces `off`). The pipe path is only
//! observed (present/absent), never opened.

const std = @import("std");
const proto = @import("wmux_proto");
const env_names = proto.env_names;
const Env = env_names.Env;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const platform_mod = @import("platform.zig");
const PolicyValue = platform_mod.PolicyValue;
const PipeState = platform_mod.PipeState;

pub const usage = "Usage: cmux socket-status [--json]";
pub const policy_key = "SocketControlMode";

pub const Mode = enum {
    off,
    cmuxOnly,
    automation,
    password,
    allowAll,
    readOnly,

    pub const default: Mode = .cmuxOnly;

    /// Case, `-` and `_` are ignored; `wmuxOnly`=`cmuxOnly`,
    /// `full`/`openAccess`=`allowAll`, `notifications`=`automation`.
    pub fn parse(raw: []const u8) ?Mode {
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (std.mem.trim(u8, raw, " \t")) |c| {
            if (c == '-' or c == '_') continue;
            if (n == buf.len) return null;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
        const s = buf[0..n];
        const table = [_]struct { []const u8, Mode }{
            .{ "off", .off },                  .{ "cmuxonly", .cmuxOnly },
            .{ "wmuxonly", .cmuxOnly },        .{ "automation", .automation },
            .{ "notifications", .automation }, .{ "password", .password },
            .{ "allowall", .allowAll },        .{ "full", .allowAll },
            .{ "openaccess", .allowAll },      .{ "readonly", .readOnly },
        };
        for (table) |t| if (std.mem.eql(u8, s, t[0])) return t[1];
        return null;
    }
};

pub const ConfigSource = enum { default, cmux_json, wmux_json };
pub const ManagedSource = enum { machinePolicy, userPolicy };
pub const ForcedStatus = enum { valid, invalid, unmanaged };

pub const Inputs = struct {
    /// `automation.socketControlMode` from cmux.json / wmux.json (raw).
    cmux_json: ?[]const u8 = null,
    wmux_json: ?[]const u8 = null,
    env: Env = Env.empty,
    hklm: PolicyValue = .absent,
    hkcu: PolicyValue = .absent,
    socket_path: ?[]const u8 = null,
    socket_path_state: PipeState = .absent,
};

pub const Status = struct {
    effective: Mode,
    configured: Mode,
    configured_source: ConfigSource,
    managed: bool,
    managed_source: ?ManagedSource,
    forced_value_status: ForcedStatus,
    socket_path: ?[]const u8,
    socket_path_state: PipeState,
};

fn parseBoolWord(v: []const u8) ?bool {
    const t = std.mem.trim(u8, v, " \t");
    for ([_][]const u8{ "1", "true", "yes", "on" }) |x| if (std.ascii.eqlIgnoreCase(t, x)) return true;
    for ([_][]const u8{ "0", "false", "no", "off" }) |x| if (std.ascii.eqlIgnoreCase(t, x)) return false;
    return null;
}

pub fn resolve(in: Inputs) Status {
    var configured: Mode = .default;
    var source: ConfigSource = .default;
    if (in.cmux_json) |v| if (Mode.parse(v)) |m| {
        configured = m;
        source = .cmux_json;
    };
    if (in.wmux_json) |v| if (Mode.parse(v)) |m| {
        configured = m;
        source = .wmux_json;
    };

    var effective = configured;
    if (in.env.first(&.{ env_names.WMUX_SOCKET_MODE, env_names.CMUX_SOCKET_MODE })) |v| {
        if (Mode.parse(v)) |m| effective = m;
    }
    if (in.env.first(&.{ env_names.WMUX_SOCKET_ENABLE, env_names.CMUX_SOCKET_ENABLE })) |v| {
        if (parseBoolWord(v)) |enabled| {
            if (!enabled) effective = .off else if (effective == .off) effective = .default;
        }
    }

    var status: Status = .{
        .effective = effective,
        .configured = configured,
        .configured_source = source,
        .managed = false,
        .managed_source = null,
        .forced_value_status = .unmanaged,
        .socket_path = in.socket_path,
        .socket_path_state = in.socket_path_state,
    };
    const hives = [_]struct { PolicyValue, ManagedSource }{ .{ in.hklm, .machinePolicy }, .{ in.hkcu, .userPolicy } };
    for (hives) |h| {
        switch (h[0]) {
            .absent => continue,
            .malformed => {
                status.forced_value_status = .invalid;
                status.effective = .off;
            },
            .string => |s| {
                const m = Mode.parse(s);
                if (m != null and (m.? == .cmuxOnly or m.? == .off)) {
                    status.forced_value_status = .valid;
                    status.effective = m.?;
                } else {
                    status.forced_value_status = .invalid;
                    status.effective = .off;
                }
            },
        }
        status.managed = true;
        status.managed_source = h[1];
        break;
    }
    return status;
}

pub fn writeText(w: *Writer, s: Status) Writer.Error!void {
    try w.print("Socket control mode: {s}", .{@tagName(s.effective)});
    if (s.managed_source) |m| try w.print(" ({s})", .{@tagName(m)});
    try w.writeAll(". Live enforcement: not observed.\n");
    try w.writeAll("Use --json for the profile source and socket-path observation. This command never connects to the automation socket.\n");
}

pub fn writeJson(w: *Writer, s: Status) Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("effective_mode");
    try js.write(@tagName(s.effective));
    try js.objectField("configured_mode");
    try js.write(@tagName(s.configured));
    try js.objectField("configured_source");
    try js.write(@tagName(s.configured_source));
    try js.objectField("managed");
    try js.write(s.managed);
    try js.objectField("managed_source");
    if (s.managed_source) |m| try js.write(@tagName(m)) else try js.write(null);
    try js.objectField("policy_key");
    try js.write(policy_key);
    try js.objectField("forced_value_status");
    try js.write(@tagName(s.forced_value_status));
    try js.objectField("socket_path");
    try js.write(s.socket_path);
    try js.objectField("socket_path_state");
    try js.write(@tagName(s.socket_path_state));
    try js.objectField("live_enforcement");
    try js.write("not_observed");
    try js.objectField("observation_scope");
    try js.write("profile_and_socket_path");
    try js.endObject();
    try w.writeByte('\n');
}

/// `automation.socketControlMode` of a JSONC settings file; null when the
/// file is unreadable, malformed or lacks the key.
pub fn modeFromSettings(gpa: Allocator, src: []const u8) ?[]const u8 {
    var doc = proto.jsonc.parse(gpa, src, .{}, null) catch return null;
    defer doc.deinit();
    const node = doc.root.getDotted("automation.socketControlMode") orelse return null;
    const s = node.asString() orelse return null;
    // Copy out of the document arena; callers use an arena allocator.
    return gpa.dupe(u8, s) catch null;
}

const testing = std.testing;

test "unit: cli-socket-status: mode names and aliases" {
    try testing.expectEqual(Mode.cmuxOnly, Mode.parse("cmux-only").?);
    try testing.expectEqual(Mode.cmuxOnly, Mode.parse("WMUX_ONLY").?);
    try testing.expectEqual(Mode.allowAll, Mode.parse("openAccess").?);
    try testing.expectEqual(Mode.allowAll, Mode.parse("full").?);
    try testing.expectEqual(Mode.automation, Mode.parse("notifications").?);
    try testing.expectEqual(Mode.readOnly, Mode.parse(" read_only ").?);
    try testing.expectEqual(@as(?Mode, null), Mode.parse(""));
    try testing.expectEqual(@as(?Mode, null), Mode.parse("everything"));
    try testing.expectEqual(@as(?Mode, null), Mode.parse("a" ** 100));
}

test "unit: cli-socket-status: defaults and file layers" {
    const s = resolve(.{});
    try testing.expectEqual(Mode.cmuxOnly, s.effective);
    try testing.expect(!s.managed);
    try testing.expectEqual(ForcedStatus.unmanaged, s.forced_value_status);
    const files = resolve(.{ .cmux_json = "automation", .wmux_json = "password" });
    try testing.expectEqual(Mode.password, files.effective);
    try testing.expectEqual(ConfigSource.wmux_json, files.configured_source);
    const bad = resolve(.{ .cmux_json = "allowAll", .wmux_json = "nonsense" });
    try testing.expectEqual(Mode.allowAll, bad.effective);
    try testing.expectEqual(ConfigSource.cmux_json, bad.configured_source);
}

test "unit: cli-socket-status: environment overrides" {
    const allow: []const Env.Pair = &.{.{ "CMUX_SOCKET_MODE", "allowAll" }};
    const s = resolve(.{ .env = Env.fromPairs(&allow) });
    try testing.expectEqual(Mode.allowAll, s.effective);
    try testing.expectEqual(Mode.cmuxOnly, s.configured);
    const disabled: []const Env.Pair = &.{ .{ "CMUX_SOCKET_MODE", "allowAll" }, .{ "WMUX_SOCKET_ENABLE", "0" } };
    try testing.expectEqual(Mode.off, resolve(.{ .env = Env.fromPairs(&disabled) }).effective);
    const enabled: []const Env.Pair = &.{.{ "CMUX_SOCKET_ENABLE", "1" }};
    try testing.expectEqual(Mode.cmuxOnly, resolve(.{ .wmux_json = "off", .env = Env.fromPairs(&enabled) }).effective);
    const twin: []const Env.Pair = &.{ .{ "WMUX_SOCKET_MODE", "readOnly" }, .{ "CMUX_SOCKET_MODE", "allowAll" } };
    try testing.expectEqual(Mode.readOnly, resolve(.{ .env = Env.fromPairs(&twin) }).effective);
}

test "unit: cli-socket-status: policy forces cmuxOnly or off" {
    const off = resolve(.{ .wmux_json = "allowAll", .hklm = .{ .string = @constCast("off") } });
    try testing.expectEqual(Mode.off, off.effective);
    try testing.expect(off.managed);
    try testing.expectEqual(ManagedSource.machinePolicy, off.managed_source.?);
    try testing.expectEqual(ForcedStatus.valid, off.forced_value_status);
    const user = resolve(.{ .hkcu = .{ .string = @constCast("CMUXONLY") } });
    try testing.expectEqual(ManagedSource.userPolicy, user.managed_source.?);
    try testing.expectEqual(Mode.cmuxOnly, user.effective);
    const invalid = resolve(.{ .hkcu = .{ .string = @constCast("allowAll") } });
    try testing.expectEqual(Mode.off, invalid.effective);
    try testing.expectEqual(ForcedStatus.invalid, invalid.forced_value_status);
    const malformed = resolve(.{ .hklm = .malformed, .hkcu = .{ .string = @constCast("cmuxOnly") } });
    try testing.expectEqual(Mode.off, malformed.effective);
    try testing.expectEqual(ManagedSource.machinePolicy, malformed.managed_source.?);
    const env_loses: []const Env.Pair = &.{.{ "CMUX_SOCKET_MODE", "allowAll" }};
    try testing.expectEqual(Mode.cmuxOnly, resolve(.{ .env = Env.fromPairs(&env_loses), .hklm = .{ .string = @constCast("cmuxOnly") } }).effective);
}

test "unit: cli-socket-status: text and json output" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeText(&aw.writer, resolve(.{ .hklm = .{ .string = @constCast("off") } }));
    try testing.expectEqualStrings(
        "Socket control mode: off (machinePolicy). Live enforcement: not observed.\n" ++
            "Use --json for the profile source and socket-path observation. This command never connects to the automation socket.\n",
        aw.written(),
    );
    aw.clearRetainingCapacity();
    try writeJson(&aw.writer, resolve(.{ .socket_path = "\\\\.\\pipe\\wmux-stable-0123abcd-s1", .socket_path_state = .present }));
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer v.deinit();
    const o = v.value.object;
    try testing.expectEqualStrings("cmuxOnly", o.get("effective_mode").?.string);
    try testing.expect(o.get("managed_source").? == .null);
    try testing.expectEqualStrings("SocketControlMode", o.get("policy_key").?.string);
    try testing.expectEqualStrings("present", o.get("socket_path_state").?.string);
    try testing.expectEqualStrings("not_observed", o.get("live_enforcement").?.string);
    try testing.expectEqualStrings("profile_and_socket_path", o.get("observation_scope").?.string);
}

test "unit: cli-socket-status: settings file lookup tolerates junk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("allowAll", modeFromSettings(a, "// c\n{\"automation\": {\"socketControlMode\": \"allowAll\",},}").?);
    try testing.expectEqual(@as(?[]const u8, null), modeFromSettings(a, "{\"automation\": {\"socketControlMode\": 3}}"));
    try testing.expectEqual(@as(?[]const u8, null), modeFromSettings(a, "{"));
    try testing.expectEqual(@as(?[]const u8, null), modeFromSettings(a, ""));
    try testing.expectEqual(@as(?[]const u8, null), modeFromSettings(a, "[1,2]"));
}
