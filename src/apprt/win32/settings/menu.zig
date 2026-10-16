//! The settings menus (ARCHITECTURE.md ADR-1.6): the sidebar gear menu
//! (site `sidebar_gear`: open the config file or its folder, reload it,
//! "Set default shell...") and the default-shell picker it opens (site
//! `default_shell`: PowerShell, Command Prompt and every installed WSL
//! distribution, written to the `command` config key).

const std = @import("std");

const config_files = @import("legacy_config_files.zig");
const internal_os = @import("../../../os/main.zig");
const menus = @import("../ui/menus.zig");

const log = std.log.scoped(.win32);

const Context = menus.Context;

pub const menu_items = [_]menus.MenuItem{
    .{ .site = .sidebar_gear, .group = 0, .order = 0, .title = "Open config", .callback = openConfig },
    .{ .site = .sidebar_gear, .group = 0, .order = 1, .title = "Open config folder", .callback = openConfigFolder },
    .{ .site = .sidebar_gear, .group = 0, .order = 2, .title = "Reload config", .callback = reloadConfig },
    .{ .site = .sidebar_gear, .group = 1, .order = 0, .title = "Set default shell...", .callback = setDefaultShellMenu },
    .{ .site = .default_shell, .group = 0, .order = 0, .title = "PowerShell", .callback = pickDefaultShell, .arg = choiceArg(.pwsh) },
    .{ .site = .default_shell, .group = 0, .order = 1, .title = "Command Prompt", .callback = pickDefaultShell, .arg = choiceArg(.cmd) },
};

/// One row per installed WSL distribution in the default-shell picker.
pub fn menuEntries(b: *menus.MenuBuilder) std.mem.Allocator.Error!void {
    if (b.site != .default_shell) return;
    for (b.ctx.distros, 0..) |distro, i| {
        try b.addEntry(.{
            .group = 1,
            .order = @intCast(@min(i, std.math.maxInt(u16))),
            .title = try menus.distroMenuLabel(b.allocator(), distro.name, distro.is_default),
            .callback = pickDefaultShell,
            .arg = choiceArg(.{ .distro = i }),
        });
    }
}

fn openConfig(ctx: *Context, arg: usize) void {
    _ = arg;
    config_files.openConfigFile(ctx.app);
}

fn openConfigFolder(ctx: *Context, arg: usize) void {
    _ = arg;
    config_files.openConfigFolder(ctx.app);
}

/// Same path as the reload_config keybind: core performAction forwards
/// to the apprt's .reload_config handler.
fn reloadConfig(ctx: *Context, arg: usize) void {
    _ = arg;
    ctx.app.core_app.performAction(ctx.app, .reload_config) catch |err| {
        log.err("failed to reload config: {}", .{err});
    };
}

/// Open the default-shell picker anchored where the gear menu was (a
/// second popup; the first one's modal loop has already returned).
fn setDefaultShellMenu(ctx: *Context, arg: usize) void {
    _ = arg;
    menus.showDefaultShellMenu(ctx.window, ctx.client_x, ctx.client_y);
}

/// A default-shell picker row.
pub const DefaultShellChoice = union(enum) {
    pwsh,
    cmd,
    distro: usize,
};

/// Encode a choice as a menu item argument (distro index + 2).
fn choiceArg(choice: DefaultShellChoice) usize {
    return switch (choice) {
        .pwsh => 0,
        .cmd => 1,
        .distro => |i| i + 2,
    };
}

fn choiceFromArg(arg: usize) DefaultShellChoice {
    return switch (arg) {
        0 => .pwsh,
        1 => .cmd,
        else => .{ .distro = arg - 2 },
    };
}

/// The `command` config value for a default-shell choice (e.g.
/// "pwsh.exe" or "wsl.exe --cd ~ -d Ubuntu"), or null for a distro index
/// past the list. Pure; the distro value is written into `distro_buf`
/// and the slice returned points into it.
pub fn defaultShellValue(
    choice: DefaultShellChoice,
    distros: []const internal_os.wsl.Distro,
    distro_buf: []u8,
) ?[]const u8 {
    return switch (choice) {
        .pwsh => if (menus.havePwsh()) "pwsh.exe" else "powershell.exe",
        .cmd => "cmd.exe",
        // wsl.exe needs the distro selected explicitly so the default
        // shell is deterministic regardless of the WSL default.
        .distro => |idx| if (idx < distros.len)
            std.fmt.bufPrint(distro_buf, "wsl.exe --cd ~ -d {s}", .{distros[idx].name}) catch null
        else
            null,
    };
}

/// Write the chosen backend to the `command` config key (App.setDefaultShell
/// reloads the config so new tabs and splits use it).
fn pickDefaultShell(ctx: *Context, arg: usize) void {
    var distro_buf: [512]u8 = undefined;
    const value = defaultShellValue(choiceFromArg(arg), ctx.distros, &distro_buf) orelse return;
    config_files.setDefaultShell(ctx.app, value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: default-shell value maps the fixed shells" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{};

    // cmd is deterministic.
    try testing.expectEqualStrings("cmd.exe", defaultShellValue(.cmd, distros, &buf).?);

    // pwsh resolves to one of the two PowerShell exes depending on
    // whether PowerShell 7 is installed on the test host.
    const pwsh = defaultShellValue(.pwsh, distros, &buf).?;
    try testing.expect(
        std.mem.eql(u8, pwsh, "pwsh.exe") or
            std.mem.eql(u8, pwsh, "powershell.exe"),
    );
}

test "unit: default-shell value formats the distro argv" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
        .{ .name = "Debian", .guid = "{y}", .is_default = false, .version = 2 },
    };
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Ubuntu",
        defaultShellValue(.{ .distro = 0 }, distros, &buf).?,
    );
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Debian",
        defaultShellValue(.{ .distro = 1 }, distros, &buf).?,
    );
}

test "unit: default-shell value ignores out-of-range distros" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
    };
    try testing.expectEqual(@as(?[]const u8, null), defaultShellValue(.{ .distro = 1 }, distros, &buf));
    try testing.expectEqual(@as(?[]const u8, null), defaultShellValue(.{ .distro = 99 }, &.{}, &buf));
}

test "unit: ui: default-shell picker args round-trip every choice" {
    const choices = [_]DefaultShellChoice{ .pwsh, .cmd, .{ .distro = 0 }, .{ .distro = 63 } };
    for (choices) |choice| {
        try testing.expectEqual(choice, choiceFromArg(choiceArg(choice)));
    }
}
