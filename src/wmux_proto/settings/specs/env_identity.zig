//! Settings specs of feature `env_identity` (ADR-5.2), filled by W1-3: the
//! per-workspace port block exported as `CMUX_PORT`/`CMUX_PORT_END`/
//! `CMUX_PORT_RANGE` (cmux keys `automation.portBase`, `automation.portRange`)
//! and whether the inherited Anthropic credentials stay in terminals
//! (`wmux.agents.preserveAuthEnv`, ADR-3.9). All apply to terminals spawned
//! after the change (a workspace keeps the port block of its first
//! terminal); running terminals keep their environment.

const Spec = @import("../spec.zig").Spec;

pub const specs = [_]Spec{
    .{
        .path = "automation.portBase",
        .ty = .{ .integer = .{ .min = 1, .max = 65535 } },
        .default = "9100",
        .section = "automation",
        .label = "Workspace port base",
        .doc = "First port of the per-workspace port blocks: each workspace's terminals get CMUX_PORT = base + ordinal * range, CMUX_PORT_END and CMUX_PORT_RANGE. A workspace keeps the block of its first terminal: applies to workspaces started after the change.",
        .keywords = &.{ "port", "CMUX_PORT", "environment" },
    },
    .{
        .path = "automation.portRange",
        .ty = .{ .integer = .{ .min = 1, .max = 65535 } },
        .default = "10",
        .section = "automation",
        .label = "Ports per workspace",
        .doc = "Number of ports reserved for each workspace (CMUX_PORT_RANGE). Applies to workspaces started after the change.",
        .keywords = &.{ "port", "CMUX_PORT_RANGE", "environment" },
    },
    .{
        .path = "wmux.agents.preserveAuthEnv",
        .ty = .boolean,
        .default = "false",
        .section = "automation",
        .label = "Keep Anthropic credentials in terminals",
        .doc = "When false (default), ANTHROPIC_API_KEY, ANTHROPIC_MODEL, ANTHROPIC_SMALL_FAST_MODEL, CLAUDE_CODE_USE_BEDROCK and CLAUDE_CODE_USE_VERTEX inherited by wmux are removed from the environment of new terminals.",
        .keywords = &.{ "anthropic", "claude", "api key", "environment" },
        .cmux_compat = false,
    },
};

test {
    _ = &specs;
}
