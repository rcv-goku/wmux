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

test {
    inline for (agents) |a| _ = a;
}
