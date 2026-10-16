//! wmux_proto: std-only types and pure helpers shared by wmux.exe, the cmux
//! CLI and (Wave 6) the remote daemon (ADR-1.1, ADR-1.2). Import it only as
//! `@import("wmux_proto")`; never relative-import into or out of
//! src/wmux_proto/ (ADR-0.4). OS-specific files guard on builtin.os.tag.

pub const actions_catalog = @import("actions_catalog.zig");
pub const channel = @import("channel.zig");
pub const env_names = @import("env_names.zig");
pub const envelope = @import("envelope.zig");
pub const errors = @import("errors.zig");
pub const events_catalog = @import("events_catalog.zig");
pub const handles = @import("handles.zig");
pub const idformat = @import("idformat.zig");
pub const json_edit = @import("json_edit.zig");
pub const jsonc = @import("jsonc.zig");
pub const keymap_presets = @import("keymap_presets.zig");
pub const paths = @import("paths.zig");
pub const pipe_name = @import("pipe_name.zig");
pub const remote = @import("remote/remote.zig");
pub const selectors = @import("selectors.zig");
pub const shell_quote = @import("shell_quote.zig");
pub const strokes = @import("strokes.zig");
pub const utf8 = @import("utf8.zig");
pub const uuid = @import("uuid.zig");
pub const when = @import("when.zig");
pub const win_argv = @import("win_argv.zig");

/// Settings specs and their resolution, validation and schema export (ADR-5).
pub const settings = struct {
    pub const cmux_known_keys = @import("settings/cmux_known_keys.zig");
    pub const resolve = @import("settings/resolve.zig");
    pub const schema_dump = @import("settings/schema_dump.zig");
    pub const spec = @import("settings/spec.zig");
    pub const specs_manifest = @import("settings/specs_manifest.zig");
    pub const validate = @import("settings/validate.zig");
};

test {
    _ = actions_catalog;
    _ = channel;
    _ = env_names;
    _ = envelope;
    _ = errors;
    _ = events_catalog;
    _ = handles;
    _ = idformat;
    _ = json_edit;
    _ = jsonc;
    _ = keymap_presets;
    _ = paths;
    _ = pipe_name;
    _ = remote;
    _ = selectors;
    _ = shell_quote;
    _ = strokes;
    _ = utf8;
    _ = uuid;
    _ = when;
    _ = win_argv;
    _ = settings.cmux_known_keys;
    _ = settings.resolve;
    _ = settings.schema_dump;
    _ = settings.spec;
    _ = settings.specs_manifest;
    _ = settings.validate;
}
