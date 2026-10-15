//! wmux build steps [frozen] (ADR-1.8 A3 item 5, ADR-4.1, ADR-5.6, ADR-12.2).
//!
//! build.zig delegates here once. Every step later work packages need is
//! defined now, pointing at stub files, so no later WP edits build.zig:
//!
//!   zig build test-fast        wmux_proto + every pure logic/ test index (std only)
//!   zig build test-cli         tests rooted at src/wmux_cli/main.zig
//!   zig build settings-schema  regenerates docs/wmux/schema/wmux.schema.json
//!   zig build cli              builds and installs only the cmux CLI
//!   zig build remote-daemon    wmuxd-remote (no-op until Wave 6, ADR-13)
//!
//! For Windows app builds `install()` adds, relative to the install prefix:
//!
//!   bin/cli/cmux.exe            the console CLI (src/wmux_cli/main.zig)
//!   bin/cli/wmux.com            byte copy of cmux.exe
//!   bin/cli/cmux, bin/cli/wmux  LF sh launchers (src/wmux_cli/scripts/)
//!   share/wmux/web/             src/web/** (once src/web exists)
//!   share/wmux/schema/          wmux.schema.json (once docs/wmux/schema has it)
//!
//! The CLI goes next to wmux.exe (bin/), as ADR-4.1 lays out dev builds
//! (`zig-out\bin\cli\cmux.exe`) and Appendix G.1 defines `CLI` = `INSTALL\cli`
//! with INSTALL = the directory of wmux.exe. share/ stays at the prefix, where
//! the existing Ghostty resources live.
//!
//! `addImports` gives app modules `@import("wmux_proto")` and
//! `@import("wmux_build_options")` (`version`, `channel`). `-Dwmux-channel`
//! overrides the compiled default channel (ADR-3.1).
const WmuxSteps = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// Directory of the CLI files, relative to the install directory of wmux.exe
/// (`.bin`, which follows --prefix-exe-dir like wmux.exe does). The relays
/// depend on this sibling layout: cmux.exe finds `..\wmux.exe` (ADR-4.3) and
/// wmux.exe runs `<exe dir>\cli\cmux.exe` (ADR-4.10).
pub const cli_subdir = "cli";

/// The committed settings schema, relative to the build root.
const schema_source_path = "docs/wmux/schema/wmux.schema.json";

/// The std-only shared module (src/wmux_proto/proto.zig). It has no target of
/// its own, so each compilation that imports it builds it for its target.
proto: *std.Build.Module,

/// The `wmux_build_options` module: `version` and `channel`.
build_options: *std.Build.Module,

/// Everything `install()` adds to the default install step. It has no
/// dependencies when the target is not Windows.
install_step: *std.Build.Step,

pub const Options = struct {
    /// `-Dtest-filter` values, applied to the test-fast and test-cli tests.
    test_filters: []const []const u8 = &.{},
};

pub fn init(b: *std.Build, cfg: *const Config, opts: Options) !WmuxSteps {
    const windows = cfg.target.result.os.tag == .windows;
    const test_target = cfg.baselineTarget();

    const channel = b.option(
        []const u8,
        "wmux-channel",
        "Compiled default wmux channel, [a-z0-9-]{1,40}. Default: debug for Debug builds, else stable",
    ) orelse switch (cfg.optimize) {
        .Debug => "debug",
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => "stable",
    };
    if (!isValidChannel(channel)) {
        std.log.err("-Dwmux-channel must match [a-z0-9-]{{1,40}}, got '{s}'", .{channel});
        return error.InvalidWmuxChannel;
    }

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.fmt("{f}", .{cfg.version}));
    options.addOption([]const u8, "channel", channel);
    const build_options = options.createModule();

    const proto = b.createModule(.{
        .root_source_file = b.path("src/wmux_proto/proto.zig"),
    });

    // settings-schema: a host tool prints the schema of the settings specs.
    const schema_tool = b.addExecutable(.{
        .name = "wmux-settings-schema",
        .root_module = b.createModule(.{
            .root_source_file = b.addWriteFiles().add(
                "settings_schema.zig",
                settings_schema_main,
            ),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "wmux_proto", .module = proto }},
        }),
    });
    {
        const step = b.step(
            "settings-schema",
            "Regenerate " ++ schema_source_path ++ " from the settings specs",
        );
        const run = b.addRunArtifact(schema_tool);
        run.addArg("write");
        const generated = run.addOutputFileArg("wmux.schema.json");
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(generated, schema_source_path);
        step.dependOn(&update.step);
    }
    const schema_committed = pathExists(b, schema_source_path);

    // test-fast: std + wmux_proto only, never Ghostty.
    {
        const step = b.step(
            "test-fast",
            "Run the std-only wmux tests (wmux_proto and every pure logic/ test index)",
        );
        const fast_tests = b.addTest(.{
            .name = "wmux-fast-test",
            .filters = opts.test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apprt/win32/fast_tests.zig"),
                .target = test_target,
                .optimize = .Debug,
                .imports = &.{.{ .name = "wmux_proto", .module = proto }},
            }),
        });
        step.dependOn(&b.addRunArtifact(fast_tests).step);

        const proto_tests = b.addTest(.{
            .name = "wmux-proto-test",
            .filters = opts.test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wmux_proto/proto.zig"),
                .target = test_target,
                .optimize = .Debug,
            }),
        });
        step.dependOn(&b.addRunArtifact(proto_tests).step);

        // Golden check (ADR-5.6): the committed schema must match the specs.
        if (schema_committed) {
            const check = b.addRunArtifact(schema_tool);
            check.addArg("check");
            check.addFileArg(b.path(schema_source_path));
            check.expectExitCode(0);
            step.dependOn(&check.step);
        }
    }

    const cli_imports: []const std.Build.Module.Import = &.{
        .{ .name = "wmux_proto", .module = proto },
        .{ .name = "wmux_build_options", .module = build_options },
    };
    const windows_only = "the cmux CLI targets Windows only (e.g. -Dtarget=x86_64-windows-gnu)";

    // test-cli
    {
        const step = b.step("test-cli", "Run the cmux CLI tests (src/wmux_cli)");
        if (windows) {
            const cli_tests = b.addTest(.{
                .name = "cmux-test",
                .filters = opts.test_filters,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/wmux_cli/main.zig"),
                    .target = test_target,
                    .optimize = .Debug,
                    .imports = cli_imports,
                }),
            });
            step.dependOn(&b.addRunArtifact(cli_tests).step);
        } else {
            step.dependOn(&b.addFail(windows_only).step);
        }
    }

    // cli, plus everything else install() adds (ADR-4.1, Appendix G.1).
    const install_step = b.allocator.create(std.Build.Step) catch @panic("OOM");
    install_step.* = .init(.{ .id = .custom, .name = "install wmux files", .owner = b });
    {
        const step = b.step(
            "cli",
            "Build and install only the cmux CLI (bin/cli/cmux.exe, wmux.com, cmux, wmux)",
        );
        if (windows) {
            const exe = b.addExecutable(.{
                .name = "cmux",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/wmux_cli/main.zig"),
                    .target = cfg.target,
                    .optimize = cfg.optimize,
                    .strip = cfg.strip,
                    .imports = cli_imports,
                }),
            });
            exe.subsystem = .Console;

            // Paths relative to `.bin`; the PDB is installed by hand so it
            // lands next to cmux.exe instead of in bin/.
            step.dependOn(&b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = .bin },
                .dest_sub_path = cli_subdir ++ "/cmux.exe",
                .pdb_dir = .disabled,
            }).step);
            if (exe.producesPdbFile()) {
                step.dependOn(&b.addInstallBinFile(exe.getEmittedPdb(), cli_subdir ++ "/cmux.pdb").step);
            }
            step.dependOn(&b.addInstallBinFile(exe.getEmittedBin(), cli_subdir ++ "/wmux.com").step);
            step.dependOn(&b.addInstallBinFile(b.path("src/wmux_cli/scripts/cmux"), cli_subdir ++ "/cmux").step);
            step.dependOn(&b.addInstallBinFile(b.path("src/wmux_cli/scripts/wmux"), cli_subdir ++ "/wmux").step);
            install_step.dependOn(step);

            if (pathExists(b, "src/web")) {
                install_step.dependOn(&b.addInstallDirectory(.{
                    .source_dir = b.path("src/web"),
                    .install_dir = .prefix,
                    .install_subdir = "share/wmux/web",
                }).step);
            }

            if (schema_committed) {
                install_step.dependOn(&b.addInstallFileWithDir(
                    b.path(schema_source_path),
                    .prefix,
                    "share/wmux/schema/wmux.schema.json",
                ).step);
            }
        } else {
            step.dependOn(&b.addFail(windows_only).step);
        }
    }

    // remote-daemon: filled by W6-2 (ADR-13).
    _ = b.step("remote-daemon", "Build the wmuxd-remote daemon (no-op until Wave 6)");

    return .{
        .proto = proto,
        .build_options = build_options,
        .install_step = install_step,
    };
}

/// Makes `@import("wmux_proto")` and `@import("wmux_build_options")`
/// available to an app root module. build.zig calls it for every compile of
/// the app (wmux.exe, its valgrind build and the unit tests). Reuse these
/// module objects: two modules with the same root file in one compilation
/// fail the build.
pub fn addImports(self: *const WmuxSteps, module: *std.Build.Module) void {
    module.addImport("wmux_proto", self.proto);
    module.addImport("wmux_build_options", self.build_options);
}

/// Adds the CLI, web assets and settings schema to the default install step.
pub fn install(self: *const WmuxSteps) void {
    self.install_step.owner.getInstallStep().dependOn(self.install_step);
}

fn isValidChannel(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

fn pathExists(b: *std.Build, sub_path: []const u8) bool {
    b.build_root.handle.access(sub_path, .{}) catch return false;
    return true;
}

/// Root of the settings-schema host tool. It is generated here rather than
/// kept as a source file so the tool stays private to the build.
const settings_schema_main =
    \\//! Generated by src/build/WmuxSteps.zig (ADR-5.6).
    \\//!   write <path>   writes the wmux.json JSON Schema to <path>
    \\//!   check <path>   fails when <path> differs from the generated schema
    \\const std = @import("std");
    \\const schema_dump = @import("wmux_proto").settings.schema_dump;
    \\
    \\pub fn main() !u8 {
    \\    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    \\    defer _ = gpa_state.deinit();
    \\    const gpa = gpa_state.allocator();
    \\
    \\    const args = try std.process.argsAlloc(gpa);
    \\    defer std.process.argsFree(gpa, args);
    \\    if (args.len != 3) {
    \\        std.log.err("usage: wmux-settings-schema write|check <path>", .{});
    \\        return 2;
    \\    }
    \\
    \\    var out: std.Io.Writer.Allocating = .init(gpa);
    \\    defer out.deinit();
    \\    try generate(gpa, &out.writer);
    \\    const schema = out.written();
    \\
    \\    if (std.mem.eql(u8, args[1], "write")) {
    \\        try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = schema });
    \\        return 0;
    \\    }
    \\    if (std.mem.eql(u8, args[1], "check")) {
    \\        const committed = try std.fs.cwd().readFileAlloc(gpa, args[2], 64 << 20);
    \\        defer gpa.free(committed);
    \\        if (std.mem.eql(u8, committed, schema)) return 0;
    \\        std.log.err("{s} is stale; run `zig build settings-schema` and commit it", .{args[2]});
    \\        return 1;
    \\    }
    \\    std.log.err("unknown mode '{s}' (expected write or check)", .{args[1]});
    \\    return 2;
    \\}
    \\
    \\fn generate(gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    \\    if (@hasDecl(schema_dump, "writeSchema")) return schema_dump.writeSchema(gpa, w);
    \\
    \\    // Placeholder until wmux_proto's settings/schema_dump.zig declares writeSchema.
    \\    try std.json.Stringify.value(.{
    \\        .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
    \\        .title = "wmux.json",
    \\        .description = "wmux settings (placeholder: no settings specs are declared yet)",
    \\        .type = "object",
    \\    }, .{ .whitespace = .indent_2 }, w);
    \\    try w.writeByte('\n');
    \\}
    \\
;
