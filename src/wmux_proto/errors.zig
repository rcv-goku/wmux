//! v2 error codes, cmux's exact error strings and the Zig error mapping
//! (ADR-3.5). Codes and the strings in `msg` are cmux interface facts; the
//! per-code `defaultMessage` texts that cmux does not define are wmux wording.

const std = @import("std");
const handles = @import("handles.zig");

/// The v2 error codes listed in ADR-3.5 (32 names; the ADR heading says 33,
/// see the W0-P1 report). The tag name is the wire string.
pub const Code = enum {
    parse_error,
    invalid_utf8,
    invalid_request,
    method_not_found,
    invalid_params,
    not_found,
    surface_unavailable,
    unavailable,
    invalid_state,
    not_supported,
    busy,
    cancelled,
    timeout,
    overloaded,
    rate_limited,
    input_queue_full,
    forbidden,
    confirmation_required,
    auth_required,
    auth_failed,
    auth_unconfigured,
    disabled,
    capability_disabled,
    browser_disabled,
    permission_denied,
    js_error,
    file_not_found,
    stale_state,
    internal_error,
    encode_error,
    slow_consumer,
    remote_relay_denied,

    /// The wire string (`"not_found"`).
    pub fn text(c: Code) []const u8 {
        return @tagName(c);
    }

    /// Exact, case-sensitive lookup of a wire string.
    pub fn parse(s: []const u8) ?Code {
        return std.meta.stringToEnum(Code, s);
    }

    /// Message used when a caller has nothing more specific. Envelope codes
    /// carry cmux's exact strings; the rest are short wmux defaults.
    pub fn defaultMessage(c: Code) []const u8 {
        return switch (c) {
            .parse_error => msg.invalid_json,
            .invalid_utf8 => msg.invalid_utf8,
            .invalid_request => msg.invalid_request,
            .method_not_found => msg.unknown_method,
            .invalid_params => "Invalid parameters",
            .not_found => "Not found",
            .surface_unavailable => "Surface is not available",
            .unavailable => "Unavailable",
            .invalid_state => "Invalid state",
            .not_supported => "Not supported",
            .busy => "Busy",
            .cancelled => "Cancelled",
            .timeout => "Timed out",
            .overloaded => "Server overloaded",
            .rate_limited => "Rate limited",
            .input_queue_full => "Input queue full",
            .forbidden => "Forbidden",
            .confirmation_required => "Confirmation required",
            .auth_required => "Authentication required",
            .auth_failed => "Authentication failed",
            .auth_unconfigured => "Authentication is not configured",
            .disabled => "Disabled",
            .capability_disabled => "Capability disabled",
            .browser_disabled => "Browser is disabled",
            .permission_denied => "Permission denied",
            .js_error => "JavaScript error",
            .file_not_found => "File not found",
            .stale_state => "Stale state",
            .internal_error => "Internal error",
            .encode_error => msg.encode_failed,
            .slow_consumer => "Slow consumer",
            .remote_relay_denied => "Remote relay denied",
        };
    }

    /// Codes a client may retry automatically (`overloaded`, `rate_limited`;
    /// `timeout` only when the server says `retryable`, ADR-4.5).
    pub fn isTransient(c: Code) bool {
        return c == .overloaded or c == .rate_limited;
    }

    pub fn jsonStringify(c: Code, jws: anytype) !void {
        try jws.write(@tagName(c));
    }
};

/// Alias used by `rpc/types.zig` (`ctx.fail(code: ErrorCode, ...)`).
pub const ErrorCode = Code;

pub const count = @typeInfo(Code).@"enum".fields.len;

/// Exact strings scripts match on (cmux interface facts).
pub const msg = struct {
    // Envelope (ADR-3.4).
    pub const invalid_utf8 = "Invalid UTF-8";
    pub const invalid_json = "Invalid JSON";
    pub const expected_object = "Expected JSON object";
    pub const missing_method = "Missing method";
    pub const unknown_method = "Unknown method";
    pub const encode_failed = "Failed to encode JSON";
    /// Not a cmux string: default for `invalid_request` when no specific
    /// reason applies.
    pub const invalid_request = "Invalid request";
    // Routing (ADR-2.6).
    pub const workspace_not_found = "Workspace not found";
    pub const surface_not_found_for_id = "Surface not found for the given surface_id";
    pub const no_focused_surface = "No focused surface";
    // CLI client (cli-v2-json-envelope, cli-id-format-output).
    pub const mismatched_response_id = "Mismatched v2 response id";
    pub const invalid_id_format = "--id-format must be one of: refs, uuids, both";
    pub const no_workspace_selected = "No workspace selected: --workspace was blank and CMUX_WORKSPACE_ID is unset";
    // Access mode (ADR-3.8; wmux wording of cmux's actionable error).
    pub const cmux_only_forbidden = "wmux control socket is in cmuxOnly mode; run from a wmux terminal or set \"automation.socketControlMode\" to \"automation\" in ~/.config/wmux/wmux.json";
};

/// Server-side "not found" message for an explicit selector of `kind`.
/// Workspace and surface use cmux's exact strings; the others follow the same
/// shape.
pub fn notFoundMessage(kind: handles.Kind) []const u8 {
    return switch (kind) {
        .window => "Window not found",
        .workspace => msg.workspace_not_found,
        .workspace_group => "Workspace group not found",
        .pane => "Pane not found",
        .surface => msg.surface_not_found_for_id,
    };
}

/// Result of mapping an escaped Zig error to the wire.
pub const Mapped = struct {
    code: Code,
    /// `@errorName(err)` for `data.error` when the error is not otherwise
    /// classified; null when the code says it all.
    error_name: ?[]const u8 = null,
};

/// Maps a Zig error that escaped an RPC handler (ADR-3.5): `OutOfMemory` →
/// internal_error, `*NotFound`/`Unknown*` → not_found, `Missing*`/`Bad*`/
/// `Invalid*` → invalid_params, `CoreNotReady` → surface_unavailable, else
/// internal_error with `data.error = @errorName(err)`.
pub fn fromZig(err: anyerror) Mapped {
    return fromName(@errorName(err));
}

/// `fromZig` over an error name (testable without declaring error sets).
pub fn fromName(name: []const u8) Mapped {
    if (std.mem.eql(u8, name, "OutOfMemory")) return .{ .code = .internal_error };
    if (std.mem.eql(u8, name, "CoreNotReady")) return .{ .code = .surface_unavailable };
    if (std.mem.endsWith(u8, name, "NotFound") or std.mem.startsWith(u8, name, "Unknown"))
        return .{ .code = .not_found };
    if (std.mem.startsWith(u8, name, "Missing") or std.mem.startsWith(u8, name, "Bad") or
        std.mem.startsWith(u8, name, "Invalid"))
        return .{ .code = .invalid_params };
    return .{ .code = .internal_error, .error_name = name };
}

/// Message for a mapped error: the code's default text.
pub fn mappedMessage(m: Mapped) []const u8 {
    return m.code.defaultMessage();
}

/// CLI exit codes (ADR-4.7).
pub const exit = struct {
    pub const ok: u8 = 0;
    pub const runtime: u8 = 1;
    pub const usage: u8 = 2;
};

const testing = std.testing;

test "unit: proto: errors has exactly the ADR-3.5 codes" {
    try testing.expectEqual(@as(usize, 32), count);
    const wire = "parse_error invalid_utf8 invalid_request method_not_found invalid_params not_found surface_unavailable unavailable invalid_state not_supported busy cancelled timeout overloaded rate_limited input_queue_full forbidden confirmation_required auth_required auth_failed auth_unconfigured disabled capability_disabled browser_disabled permission_denied js_error file_not_found stale_state internal_error encode_error slow_consumer remote_relay_denied";
    var it = std.mem.tokenizeScalar(u8, wire, ' ');
    var n: usize = 0;
    while (it.next()) |w| : (n += 1) {
        const c = Code.parse(w) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(w, c.text());
    }
    try testing.expectEqual(count, n);
}

test "unit: proto: errors code parse is exact" {
    try testing.expectEqual(@as(?Code, null), Code.parse(""));
    try testing.expectEqual(@as(?Code, null), Code.parse("NOT_FOUND"));
    try testing.expectEqual(@as(?Code, null), Code.parse("not_found "));
    try testing.expectEqual(@as(?Code, null), Code.parse("unknown_command"));
    try testing.expectEqual(@as(?Code, .remote_relay_denied), Code.parse("remote_relay_denied"));
}

test "unit: proto: errors envelope messages are cmux strings" {
    try testing.expectEqualStrings("Invalid JSON", Code.parse_error.defaultMessage());
    try testing.expectEqualStrings("Invalid UTF-8", Code.invalid_utf8.defaultMessage());
    try testing.expectEqualStrings("Unknown method", Code.method_not_found.defaultMessage());
    try testing.expectEqualStrings("Failed to encode JSON", Code.encode_error.defaultMessage());
    try testing.expectEqualStrings("Expected JSON object", msg.expected_object);
    try testing.expectEqualStrings("Missing method", msg.missing_method);
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        try testing.expect(c.defaultMessage().len > 0);
    }
}

test "unit: proto: errors not found messages per kind" {
    try testing.expectEqualStrings("Workspace not found", notFoundMessage(.workspace));
    try testing.expectEqualStrings("Surface not found for the given surface_id", notFoundMessage(.surface));
    try testing.expectEqualStrings("Pane not found", notFoundMessage(.pane));
}

test "unit: proto: errors fromZig mapping" {
    try testing.expectEqual(Code.internal_error, fromZig(error.OutOfMemory).code);
    try testing.expectEqual(@as(?[]const u8, null), fromZig(error.OutOfMemory).error_name);
    try testing.expectEqual(Code.not_found, fromZig(error.WorkspaceNotFound).code);
    try testing.expectEqual(Code.not_found, fromZig(error.FileNotFound).code);
    try testing.expectEqual(Code.not_found, fromZig(error.UnknownSurface).code);
    try testing.expectEqual(Code.invalid_params, fromZig(error.MissingText).code);
    try testing.expectEqual(Code.invalid_params, fromZig(error.BadDirection).code);
    try testing.expectEqual(Code.invalid_params, fromZig(error.InvalidUuid).code);
    try testing.expectEqual(Code.surface_unavailable, fromZig(error.CoreNotReady).code);
    const other = fromZig(error.NotATerminal);
    try testing.expectEqual(Code.internal_error, other.code);
    try testing.expectEqualStrings("NotATerminal", other.error_name.?);
    try testing.expectEqual(Code.internal_error, fromName("").code);
    try testing.expectEqualStrings("Internal error", mappedMessage(fromName("Weird")));
}

test "unit: proto: errors code stringifies as wire string" {
    const s = try std.json.Stringify.valueAlloc(testing.allocator, .{ .code = Code.rate_limited }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"code\":\"rate_limited\"}", s);
    try testing.expect(Code.overloaded.isTransient());
    try testing.expect(!Code.timeout.isTransient());
}
