//! CLI command family `layout_todo` (Appendix C).
//! layout save|list|get|open|delete (W4-7); todo, feed, vault, automation (W5a);
//! current, find-window (W5b). This WP (cf-cli-misc) adds `layout` and `todo`
//! (layout_todo/layout.zig, layout_todo/todo.zig).

const CommandSpec = @import("../command.zig").CommandSpec;
const layout = @import("layout_todo/layout.zig");
const todo = @import("layout_todo/todo.zig");

/// `CommandSpec` entries (ADR-4.9).
pub const commands = [_]CommandSpec{ layout.spec, todo.spec };

test {
    _ = layout;
    _ = todo;
    _ = @import("layout_todo/todo_rules.zig");
    _ = @import("layout_todo/tests.zig");
}
