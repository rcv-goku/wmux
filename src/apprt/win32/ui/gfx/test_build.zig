//! Standalone test build for the gfx layer and its platform bindings
//! (W1-8a), used until W1-8 wires `ui/gfx/tests.zig` into the app's test
//! graph. Run from the repository root:
//!
//!   & $Z build --build-file src/apprt/win32/ui/gfx/test_build.zig --cache-dir .zig-cache test
//!   & $Z build --build-file src/apprt/win32/ui/gfx/test_build.zig --cache-dir .zig-cache test "-Dtest-filter=headless"
//!
//! Why: `zig test src/apprt/win32/ui/gfx/tests.zig` cannot work, because a
//! module may not import files outside its root file's directory and the
//! gfx files import `../../platform/*.zig`. This script copies `ui/gfx/**`
//! and the four binding files into a generated tree with the same relative
//! layout plus a root file above both, and tests that. Delete it once the
//! real build graph runs these tests.
const std = @import("std");

const platform_files = [_][]const u8{ "com.zig", "d2d.zig", "dwrite.zig", "wic.zig" };
const system_libs = [_][]const u8{ "d2d1", "dwrite", "windowscodecs", "ole32", "user32", "gdi32" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    });
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this text (repeatable)") orelse &.{};

    const tree = b.addWriteFiles();
    for (platform_files) |name| {
        _ = tree.addCopyFile(b.path(b.fmt("../../platform/{s}", .{name})), b.fmt("platform/{s}", .{name}));
    }
    copyZigFiles(b, tree, "ui/gfx");
    const root = tree.add("gfx_test_root.zig", "test {\n    _ = @import(\"ui/gfx/tests.zig\");\n}\n");

    const mod = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (system_libs) |lib| mod.linkSystemLibrary(lib, .{});

    const tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Run the gfx layer and D2D/DirectWrite/WIC binding tests");
    step.dependOn(&run.step);
    b.default_step = step;
}

/// Copy every `.zig` file under the build root (this directory) into
/// `dest_prefix`, skipping cache/output directories.
fn copyZigFiles(b: *std.Build, tree: *std.Build.Step.WriteFile, dest_prefix: []const u8) void {
    var dir = b.build_root.handle.openDir(".", .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {s}", .{ b.build_root.path orelse ".", @errorName(err) });
    defer dir.close();
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next() catch |err| std.debug.panic("walking gfx sources failed: {s}", .{@errorName(err)})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.indexOf(u8, entry.path, "zig-cache") != null or std.mem.indexOf(u8, entry.path, "zig-out") != null) continue;
        const rel = b.dupe(entry.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        _ = tree.addCopyFile(b.path(rel), b.fmt("{s}/{s}", .{ dest_prefix, rel }));
    }
}
