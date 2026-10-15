//! Agent catalog manifest [frozen, merge=union] (ADR-1.4, ADR-10.5): one line
//! per agent definition file, sorted. W3-1 defines `AgentDef` and fills claude
//! and codex; W3-3 fills the other agents.

pub const agents = .{
    @import("amp.zig"),
    @import("antigravity.zig"),
    @import("campfire.zig"),
    @import("claude.zig"),
    @import("codebuddy.zig"),
    @import("codex.zig"),
    @import("copilot.zig"),
    @import("cursor.zig"),
    @import("factory.zig"),
    @import("gemini.zig"),
    @import("grok.zig"),
    @import("kimi.zig"),
    @import("kiro.zig"),
    @import("muse.zig"),
    @import("omp.zig"),
    @import("opencode.zig"),
    @import("pi.zig"),
    @import("qoder.zig"),
    @import("rovodev.zig"),
};

// A line duplicated by a union merge fails the build here (ADR-0.4).
comptime {
    @setEvalBranchQuota(1_000_000);
    for (0..agents.len) |i| {
        for (0..i) |j| {
            if (agents[i] == agents[j]) {
                @compileError("duplicate agent in src/wmux_cli/agents/manifest.zig: " ++ @typeName(agents[i]));
            }
        }
    }
}

test {
    inline for (agents) |a| _ = a;
}
