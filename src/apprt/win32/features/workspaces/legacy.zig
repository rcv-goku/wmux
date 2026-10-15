//! Legacy wmux-v1 JSON commands of the `workspaces` feature:
//! workspace-list, workspace-new, workspace-select, workspace-close,
//! workspace-set-description (`wmux +workspace ...`, `wmux +ssh
//! --workspace`).
//!
//! These mutate the single-UI-thread model and reply synchronously.
//! Workspace indices are window-local: every handler operates on the IPC
//! target window (foreground wmux window, else the first live one).
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-1
//! re-points them to the v2 `workspace.*` methods (Appendix B.4).

const std = @import("std");

const App = @import("../../App.zig");
const ipc = @import("../../rpc/compat/legacy_json.zig");
const LegacyCommand = @import("../../rpc/compat/legacy_table.zig").LegacyCommand;
const targets = @import("../../rpc/compat/legacy_targets.zig");
const worktree = @import("worktree.zig");

const log = std.log.scoped(.win32);

const IpcError = targets.IpcError;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read an optional u32 index field ("index"/"workspace"/"tab").
const ipcArgU32 = ipc.argU32;

/// Read an optional bool field (send's "enter").
const ipcArgBool = ipc.argBool;

pub const commands = [_]LegacyCommand{
    .{ .cmd = "workspace-list", .handler = &ipcWorkspaceList, .read_only = true },
    .{ .cmd = "workspace-new", .handler = &ipcWorkspaceNew, .prepare = &prepareWorkspaceNew },
    .{ .cmd = "workspace-select", .handler = &ipcWorkspaceSelect },
    .{ .cmd = "workspace-close", .handler = &ipcWorkspaceClose },
    .{ .cmd = "workspace-set-description", .handler = &ipcWorkspaceSetDescription },
};

/// Pipe-thread stage of `workspace-new` (the special case formerly inlined
/// in App.ipcCallback). `workspace-new --worktree` is the one verb that
/// does real work on the pipe thread, before the UI ever sees it: it
/// shells out to `git worktree add`, which touches the filesystem (and
/// can block on a large repo). Running it on the message loop would freeze
/// the UI, so we do it off-loop, stash the resolved path on the request,
/// and only then hand it to the UI thread. A git failure is answered
/// straight from here (the server's senders are thread-safe) and the
/// request is dropped without reaching the UI, so no empty workspace is
/// ever created.
fn prepareWorkspaceNew(self: *App, req: *ipc.Request) bool {
    if (ipc.argString(req, "worktree")) |branch| {
        // ipcPrepareWorktree answers the client with the git error (or a
        // validation error) itself when it returns false.
        return ipcPrepareWorktree(self, req, branch);
    }
    return true;
}

/// Pipe-thread helper for `workspace-new --worktree <branch> [--repo P]`.
/// Validates the branch, resolves the repo (the request's "repo" arg, or
/// the client's "cwd" arg — the app's own cwd is meaningless to the
/// agent), runs `git -C <repo> worktree add <repo>/.worktrees/<branch>
/// [-b <branch>]`, and on success stashes the resolved worktree path on
/// `req.worktree_path` for the UI handler. Returns true to proceed to the
/// UI, false after having sent the client an error (no workspace is
/// created). Runs entirely on the pipe thread.
fn ipcPrepareWorktree(self: *App, req: *ipc.Request, branch: []const u8) bool {
    const server = self.ipc_server orelse return false;
    const alloc = self.core_app.alloc;

    const validated = worktree.validateBranch(branch) catch |err| {
        server.sendError(req.id, @errorName(err)) catch {};
        return false;
    };

    // Resolve the repo root: explicit --repo wins, else the client's cwd
    // (sent in the request because the app's cwd is its own, not the
    // agent's). Without either we cannot locate a repository.
    const repo = ipc.argString(req, "repo") orelse
        ipc.argString(req, "cwd") orelse {
        server.sendError(req.id, "no repository: pass --repo or run from inside a git repo") catch {};
        return false;
    };

    const path = worktree.worktreePath(alloc, repo, validated) catch {
        server.sendError(req.id, "out of memory") catch {};
        return false;
    };
    // From here `path` is owned locally; on every early return free it,
    // and on success transfer ownership to req.worktree_path.
    var path_owned = true;
    defer if (path_owned) alloc.free(path);

    runGitWorktreeAdd(self, req.id, repo, path, validated) catch |err| switch (err) {
        // The git child ran and reported a usable stderr message;
        // runGitWorktreeAdd already answered the client.
        error.GitFailed => return false,
        // Couldn't even launch git, or some local failure.
        else => {
            server.sendError(req.id, @errorName(err)) catch {};
            return false;
        },
    };

    req.worktree_path = path;
    path_owned = false; // ownership moved to the request
    return true;
}

/// Run `git -C <repo> worktree add <path> -b <branch>`, falling back to
/// no `-b` (attach an existing branch) when git reports the branch
/// already exists. On a git error other than that, answer client request
/// `id` with git's own stderr (trimmed) and return error.GitFailed.
/// Returns normally only when a worktree now exists at `path`. Pipe-thread
/// only.
fn runGitWorktreeAdd(
    self: *App,
    id: u64,
    repo: []const u8,
    path: []const u8,
    branch: []const u8,
) !void {
    const server = self.ipc_server orelse return error.GitFailed;
    const alloc = self.core_app.alloc;

    // First attempt: create a new branch (-b). The common case.
    const first = try worktree.runGit(
        alloc,
        &.{ "git", "-C", repo, "worktree", "add", path, "-b", branch },
    );
    defer {
        alloc.free(first.stdout);
        alloc.free(first.stderr);
    }
    if (first.ok) return;

    // If the branch already exists, git refuses -b; retry attaching the
    // existing branch (no -b). git phrases this as "a branch named '...'
    // already exists" (newer) or "...already exists" (older).
    if (std.mem.indexOf(u8, first.stderr, "already exists") != null) {
        const second = try worktree.runGit(
            alloc,
            &.{ "git", "-C", repo, "worktree", "add", path, branch },
        );
        defer {
            alloc.free(second.stdout);
            alloc.free(second.stderr);
        }
        if (second.ok) return;
        server.sendError(id, worktree.gitMessage(second.stderr)) catch {};
        return error.GitFailed;
    }

    server.sendError(id, worktree.gitMessage(first.stderr)) catch {};
    return error.GitFailed;
}

/// workspace-list → [{index, name, active, tab_count}] for the target
/// window's workspaces.
fn ipcWorkspaceList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;
    const alloc = self.core_app.alloc;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (window.workspaces[0..window.workspace_count], 0..) |*ws, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.writer(alloc).print("{{\"index\":{d},\"name\":", .{i});
        try targets.ipcWriteJsonUtf16(self, &buf, ws.name[0..ws.name_len]);
        const fc = ws.focusedContainerOrFirst();
        const tc: usize = if (fc) |c| c.tab_count else 0;
        try buf.writer(alloc).print(
            ",\"active\":{},\"tab_count\":{d}}}",
            .{ i == window.active_workspace, tc },
        );
    }
    try buf.append(alloc, ']');
    server.sendOk(req.id, buf.items) catch {};
}

/// workspace-new {[name], [worktree], [repo], [cwd]} → create a workspace
/// (a sidebar row with one tab), optionally renaming it, and reply with
/// its index.
///
/// When the request carried a `worktree` branch, the pipe thread already
/// ran `git worktree add` and stashed the resolved path on
/// `req.worktree_path` (see ipcCallback/ipcPrepareWorktree). Here we just
/// bind that path to the new workspace so its tabs spawn inside the
/// worktree, and default the workspace name to the branch when no
/// explicit --name was given. A plain workspace-new (no worktree) keeps
/// the current behavior.
fn ipcWorkspaceNew(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;
    if (window.is_quick_terminal) return IpcError.QuickTerminal;

    // Parse an optional explicit command (split on whitespace) once; an
    // empty/whitespace-only command falls through to the default shell.
    // Used by `+ssh --workspace` to run `ssh user@host` in the first tab.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.core_app.alloc);
    if (ipcArgString(req, "command")) |command_str| {
        var it = std.mem.tokenizeAny(u8, command_str, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.core_app.alloc, tok);
    }
    const command: ?[]const []const u8 = if (argv.items.len > 0) argv.items else null;

    // Programmatic creation defaults to NON-FOCUS: the workspace is created
    // in the background and the user stays in whatever workspace (and
    // whatever app) they were in. `--focus` (focus:true over IPC) opts in
    // to switching the in-app active workspace to the new one. Matches
    // cmux #3215: "workspace creation is not a focus-intent operation."
    const focus = ipcArgBool(req, "focus") orelse false;

    const idx: usize = if (focus) blk: {
        // Focus path: create AND select the new workspace (the historical
        // behavior), but never steal OS foreground from another app — the
        // selectWorkspace/SetFocus only affects keyboard focus when this
        // window is already foreground.
        if (req.worktree_path) |path| {
            break :blk window.newWorkspaceWithDir(path) orelse return IpcError.NoWindow;
        }
        if (command) |c| {
            // Command-bearing workspace: create-and-select, add the
            // first tab with the explicit command.
            const ws_idx = window.createAndSelectWorkspace() orelse return IpcError.NoWindow;
            _ = window.addTabWithCommand(c, null) catch |err| {
                log.err("failed to create first tab with command for new workspace: {}", .{err});
                window.closeWorkspace(ws_idx);
                return IpcError.NoWindow;
            };
            break :blk ws_idx;
        }
        const before = window.workspace_count;
        window.newWorkspace();
        // newWorkspace collapses the slot if its first tab fails to spawn,
        // so confirm a workspace was actually added before reporting one.
        if (window.workspace_count <= before) return IpcError.NoWindow;
        break :blk window.workspace_count - 1;
    } else blk: {
        // Background path (default): create without changing the active
        // workspace. newWorkspaceBackground collapses the slot on failure.
        break :blk window.newWorkspaceBackground(req.worktree_path, command) orelse
            return IpcError.NoWindow;
    };

    // Name precedence: explicit --name wins; otherwise a worktree
    // workspace is named after its branch (the agent-friendly default).
    if (ipcArgString(req, "name")) |name| {
        if (name.len > 0) window.setWorkspaceName(idx, name);
    } else if (ipcArgString(req, "worktree")) |branch| {
        if (branch.len > 0) window.setWorkspaceName(idx, branch);
    }

    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"index\":{d}}}", .{idx}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// workspace-select {index} → switch the target window to workspace
/// `index`.
fn ipcWorkspaceSelect(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;
    if (idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    window.selectWorkspace(idx);
    server.sendOk(req.id, null) catch {};
}

/// workspace-close {index} → close workspace `index` in the target
/// window. Closing the last workspace closes the window.
fn ipcWorkspaceClose(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;
    if (idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    window.closeWorkspace(idx);
    server.sendOk(req.id, null) catch {};
}

/// workspace-set-description {workspace, text} → set (or clear) the
/// user-facing description text for workspace `workspace` in the target
/// window. An empty or absent `text` clears the description.
fn ipcWorkspaceSetDescription(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = targets.ipcTargetWindow(self) orelse return IpcError.NoWindow;
    const idx = ipcArgU32(req, "workspace") orelse return IpcError.MissingIndex;
    if (idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    const text = ipc.argString(req, "text") orelse "";
    window.setWorkspaceDescription(idx, text);
    server.sendOk(req.id, null) catch {};
}
