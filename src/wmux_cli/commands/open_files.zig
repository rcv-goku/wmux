//! CLI command family `open_files` (Appendix C).
//! open <path-or-url>..., cmux <path> (W4-2); markdown open (W4-1); diff,
//! comments list, review (W4-3). This WP (cf-cli-misc) adds `open`,
//! `markdown`, `diff` and `comments` (open_files/*.zig); `cmux <path>` is
//! dispatched by main.zig through launch.openPaths; `review` stays with W4-3.

const CommandSpec = @import("../command.zig").CommandSpec;
const open = @import("open_files/open.zig");
const markdown = @import("open_files/markdown.zig");
const diff = @import("open_files/diff.zig");
const comments = @import("open_files/comments.zig");

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{ open.spec, markdown.spec, diff.spec, comments.spec };

test {
    _ = open;
    _ = markdown;
    _ = diff;
    _ = comments;
    _ = @import("open_files/tests.zig");
}
