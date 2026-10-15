//! cmux / wmux command-line front end (ADR-4): a console-subsystem executable
//! built from std, `wmux_proto` and its own Win32 externs only; it never links
//! the Ghostty terminal, renderer, fonts or apprt. Installed as cli\cmux.exe,
//! cli\wmux.com (byte copy) and the cli\cmux and cli\wmux sh launchers.
//!
//! Wave 0 skeleton: only the version forms work. W1-2 adds the cmux grammar,
//! socket discovery, the client and the offline commands. Command families
//! register in commands/manifest.zig, agent definitions in agents/manifest.zig.
const std = @import("std");
const build_options = @import("wmux_build_options");

pub const agents = @import("agents/manifest.zig");
pub const commands = @import("commands/manifest.zig");

/// What `cmux --version` prints.
pub const version_line = "cmux " ++ build_options.version ++ "\n";

/// What an invocation asks for, decided by its first argument.
pub const Invocation = union(enum) {
    /// No arguments, `--version`, `-v` or `version`.
    version,
    /// Anything else (not implemented yet); carries the first argument.
    unsupported: []const u8,
};

pub fn classify(first_arg: ?[]const u8) Invocation {
    const arg = first_arg orelse return .version;
    for ([_][]const u8{ "--version", "-v", "version" }) |spelling| {
        if (std.mem.eql(u8, arg, spelling)) return .version;
    }
    return .{ .unsupported = arg };
}

pub fn main() u8 {
    var args = std.process.argsWithAllocator(std.heap.page_allocator) catch return 1;
    defer args.deinit();
    _ = args.skip(); // argv[0]
    switch (classify(args.next())) {
        .version => {
            std.fs.File.stdout().writeAll(version_line) catch return 1;
            return 0;
        },
        .unsupported => |arg| {
            printUsageError(arg);
            return 2;
        },
    }
}

fn printUsageError(arg: []const u8) void {
    var buf: [512]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    stderr.interface.print(
        "cmux: '{s}' is not available in this build (only --version is implemented)\n",
        .{arg},
    ) catch return;
    stderr.interface.flush() catch return;
}

test "unit: cli: no arguments or a version spelling selects the version" {
    try std.testing.expect(classify(null) == .version);
    try std.testing.expect(classify("--version") == .version);
    try std.testing.expect(classify("-v") == .version);
    try std.testing.expect(classify("version") == .version);
}

test "unit: cli: any other first argument is a usage error for now" {
    try std.testing.expectEqualStrings("ping", classify("ping").unsupported);
    try std.testing.expectEqualStrings("--Version", classify("--Version").unsupported);
    try std.testing.expectEqualStrings("", classify("").unsupported);
}

test "unit: cli: the version line names cmux" {
    try std.testing.expect(std.mem.startsWith(u8, version_line, "cmux "));
    try std.testing.expect(std.mem.endsWith(u8, version_line, "\n"));
    try std.testing.expect(version_line.len > "cmux \n".len);
}

test {
    _ = agents;
    _ = commands;
    _ = @import("wmux_proto");
}
