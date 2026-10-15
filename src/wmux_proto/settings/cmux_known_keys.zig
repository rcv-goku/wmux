//! cmux.json key paths that wmux knows (interface facts only: the key names
//! cmux documents in its configuration docs and schema descriptions), each
//! flagged per Appendix E D14 (ADR-5.3). `config doctor` uses this table for
//! keys that have no wmux spec yet: `supported` keys report "not yet
//! supported", `mac_only` and `ignored` keys report "ignored on Windows".
//! An entry also covers every path below it (`mobile` covers
//! `mobile.browserTunnel.allowOtherHosts`; `shortcuts.bindings` covers each
//! action id). `project` marks keys that cmux accepts in project files
//! (actions, commands, ui, notification hooks, agentChat, vault agents,
//! workspaceGroups, agents.launchers, root meta); all others are global-only.

const std = @import("std");

pub const Support = enum {
    /// wmux implements or plans the key with cmux semantics.
    supported,
    /// macOS-only behavior; accepted and ignored on Windows.
    mac_only,
    /// Accepted and ignored (cloud, mobile and other out-of-scope families).
    ignored,

    /// The `config doctor` info text for a key without a wmux spec.
    pub fn note(self: Support) []const u8 {
        return switch (self) {
            .supported => "not yet supported",
            .mac_only, .ignored => "ignored on Windows",
        };
    }
};

pub const KnownKey = struct {
    path: []const u8,
    support: Support,
    project: bool = false,
};

/// Sorted by path bytes (checked at comptime).
pub const all = [_]KnownKey{
    .{ .path = "$schema", .support = .supported, .project = true },
    .{ .path = "actions", .support = .supported, .project = true },
    .{ .path = "activePaneBorderColor", .support = .supported },
    .{ .path = "agentChat", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.baseSize", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.bodyFamily", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.bodySize", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.codeFamily", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.codeLineHeight", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.codeSize", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.family", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.monoFamily", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.monoSize", .support = .supported, .project = true },
    .{ .path = "agentChat.fonts.sansFamily", .support = .supported, .project = true },
    .{ .path = "agentChat.keys.ctrlJ", .support = .supported, .project = true },
    .{ .path = "agentChat.startCommand", .support = .supported, .project = true },
    .{ .path = "agentChat.url", .support = .supported, .project = true },
    .{ .path = "agentMessages.enabled", .support = .supported },
    .{ .path = "agents.launchers", .support = .supported, .project = true },
    .{ .path = "app.accentColor", .support = .supported },
    .{ .path = "app.appearance", .support = .supported },
    .{ .path = "app.confirmQuit", .support = .supported },
    .{ .path = "app.devWindowDisplay", .support = .mac_only },
    .{ .path = "app.forkConversationDefaultDestination", .support = .supported },
    .{ .path = "app.globalFontMagnification", .support = .supported },
    .{ .path = "app.hideTabCloseButton", .support = .supported },
    .{ .path = "app.minimalMode", .support = .supported },
    .{ .path = "app.paneResizeStepPixels", .support = .supported },
    .{ .path = "app.preferredEditor", .support = .supported },
    .{ .path = "app.tabBarVisibility", .support = .supported },
    .{ .path = "app.warnBeforeClosingTabXButton", .support = .supported },
    .{ .path = "app.warnBeforeQuit", .support = .supported },
    .{ .path = "app.windowTitleTemplate", .support = .supported },
    .{ .path = "automation.agentAutoResume", .support = .supported },
    .{ .path = "automation.ampIntegration", .support = .supported },
    .{ .path = "automation.autoNamingAgent", .support = .supported },
    .{ .path = "automation.canonicalAgentScratch", .support = .supported },
    .{ .path = "automation.claudeBinaryPath", .support = .supported },
    .{ .path = "automation.portBase", .support = .supported },
    .{ .path = "automation.portRange", .support = .supported },
    .{ .path = "automation.socketControlMode", .support = .supported },
    .{ .path = "automation.socketPassword", .support = .supported },
    .{ .path = "automation.suppressSubagentNotifications", .support = .supported },
    .{ .path = "automation.workspaceAutoNaming", .support = .supported },
    .{ .path = "browser.askWhereToSaveDownloads", .support = .supported },
    .{ .path = "browser.customSearchEngineName", .support = .supported },
    .{ .path = "browser.customSearchEngineURLTemplate", .support = .supported },
    .{ .path = "browser.defaultSearchEngine", .support = .supported },
    .{ .path = "browser.defaultZoomLevel", .support = .supported },
    .{ .path = "browser.showLinkHoverURL", .support = .supported },
    .{ .path = "browser.urlAllowlist", .support = .supported },
    .{ .path = "canvas.paneGap", .support = .supported },
    .{ .path = "canvas.snappingEnabled", .support = .supported },
    .{ .path = "cloud", .support = .ignored },
    .{ .path = "commands", .support = .supported, .project = true },
    .{ .path = "computerUse.enabled", .support = .mac_only },
    .{ .path = "computerUse.showInMenuBar", .support = .mac_only },
    .{ .path = "diffViewer.defaultLayout", .support = .supported },
    .{ .path = "fileEditor.currentLineHighlight", .support = .supported },
    .{ .path = "fileEditor.indentGuides", .support = .supported },
    .{ .path = "fileEditor.lineNumbers", .support = .supported },
    .{ .path = "fileEditor.syntaxHighlighting", .support = .supported },
    .{ .path = "fileEditor.tabWidth", .support = .supported },
    .{ .path = "fileEditor.wordWrap", .support = .supported },
    .{ .path = "fileExplorer.doubleClickAction", .support = .supported },
    .{ .path = "markdown.fontFamily", .support = .supported },
    .{ .path = "markdown.fontSize", .support = .supported },
    .{ .path = "markdown.maxWidth", .support = .supported },
    .{ .path = "mobile", .support = .ignored },
    .{ .path = "mobile.artifactFolderAccess", .support = .ignored },
    .{ .path = "mobile.browserTunnel.allowOtherHosts", .support = .ignored },
    .{ .path = "notifications.agentIdleReminder", .support = .supported },
    .{ .path = "notifications.agentPermissionPrompt", .support = .supported },
    .{ .path = "notifications.agentTurnComplete", .support = .supported },
    .{ .path = "notifications.command", .support = .supported },
    .{ .path = "notifications.hooks", .support = .supported, .project = true },
    .{ .path = "notifications.hooksMode", .support = .supported, .project = true },
    .{ .path = "notifications.paneFlashColor", .support = .supported },
    .{ .path = "notifications.sound", .support = .supported },
    .{ .path = "notifications.soundOverrides", .support = .supported },
    .{ .path = "notifications.soundWhenFocused", .support = .supported },
    .{ .path = "notifications.suppressOnlyFocusedSurface", .support = .supported },
    .{ .path = "notifications.suppressWhenAppFocused", .support = .supported },
    .{ .path = "packs", .support = .supported, .project = true },
    .{ .path = "paneBorderColor", .support = .supported },
    .{ .path = "remoteTmux.beta.newWorkspaceOnHost.enabled", .support = .supported },
    .{ .path = "rightSidebar", .support = .supported },
    .{ .path = "rightSidebar.beta", .support = .supported },
    .{ .path = "schemaVersion", .support = .supported, .project = true },
    .{ .path = "settingPresets", .support = .supported },
    .{ .path = "shortcuts.bindings", .support = .supported },
    .{ .path = "shortcuts.bindings.newCloudMachine", .support = .ignored },
    .{ .path = "shortcuts.bindings.newCloudWorkspace", .support = .ignored },
    .{ .path = "shortcuts.showModifierHoldHints", .support = .supported },
    .{ .path = "shortcuts.when", .support = .supported },
    .{ .path = "sidebar.beta.conversations.enabled", .support = .supported },
    .{ .path = "sidebar.beta.workspaceTodos.checklistStyle", .support = .supported },
    .{ .path = "sidebar.beta.workspaceTodos.enabled", .support = .supported },
    .{ .path = "sidebar.compactAgentStatus", .support = .supported },
    .{ .path = "sidebar.compactStatusIcons", .support = .supported },
    .{ .path = "sidebar.fontSize", .support = .supported },
    .{ .path = "sidebar.hideAllDetails", .support = .supported },
    .{ .path = "sidebar.loadingSpinnerPosition", .support = .supported },
    .{ .path = "sidebar.notificationBadgePosition", .support = .supported },
    .{ .path = "sidebar.notificationMessageLineLimit", .support = .supported },
    .{ .path = "sidebar.rightMaxWidth", .support = .supported },
    .{ .path = "sidebar.showAgentActivity", .support = .supported },
    .{ .path = "sidebar.showAgentUsage", .support = .supported },
    .{ .path = "sidebar.showCloudDeviceIcons", .support = .ignored },
    .{ .path = "sidebar.showLog", .support = .supported },
    .{ .path = "sidebar.showPorts", .support = .supported },
    .{ .path = "sidebar.showPullRequests", .support = .supported },
    .{ .path = "terminal.adaptiveDefaultTheme", .support = .supported },
    .{ .path = "terminal.agentHibernation", .support = .supported },
    .{ .path = "terminal.agentHibernation.enabled", .support = .supported },
    .{ .path = "terminal.agentHibernation.idleSeconds", .support = .supported },
    .{ .path = "terminal.agentHibernation.maxLiveTerminals", .support = .supported },
    .{ .path = "terminal.autoResumeAgentSessions", .support = .supported },
    .{ .path = "terminal.confirmUnsafePaste", .support = .supported },
    .{ .path = "terminal.copyOnSelect", .support = .supported },
    .{ .path = "terminal.focusTextBoxOnNewTerminals", .support = .supported },
    .{ .path = "terminal.scrollSpeed", .support = .supported },
    .{ .path = "terminal.sessionContentAlignment", .support = .supported },
    .{ .path = "terminal.sessionContentMaxWidth", .support = .supported },
    .{ .path = "terminal.showTextBoxOnNewTerminals", .support = .supported },
    .{ .path = "terminal.textBoxDefaultSubmitAction", .support = .supported },
    .{ .path = "terminal.textBoxSubmitActions", .support = .supported },
    .{ .path = "terminal.uploadCommands", .support = .supported },
    .{ .path = "ui", .support = .supported, .project = true },
    .{ .path = "ui.newWorkspace.contextMenu", .support = .supported, .project = true },
    .{ .path = "vault.agents", .support = .supported, .project = true },
    .{ .path = "workspaceGroups", .support = .supported, .project = true },
    .{ .path = "workspaceGroups.byCwd", .support = .supported, .project = true },
    .{ .path = "workspaceGroups.newWorkspacePlacement", .support = .supported, .project = true },
};

comptime {
    @setEvalBranchQuota(1_000_000);
    for (all[1..], 0..) |k, i| {
        if (std.mem.order(u8, all[i].path, k.path) != .lt)
            @compileError("cmux_known_keys not sorted or duplicate at '" ++ k.path ++ "'");
    }
}

/// The entry for `path` itself or its nearest listed ancestor.
pub fn lookup(path: []const u8) ?*const KnownKey {
    return lookupIn(&all, path);
}

pub fn lookupIn(keys: []const KnownKey, path: []const u8) ?*const KnownKey {
    var best: ?*const KnownKey = null;
    for (keys) |*k| {
        const covers = std.mem.eql(u8, k.path, path) or
            (path.len > k.path.len and path[k.path.len] == '.' and std.mem.startsWith(u8, path, k.path));
        if (covers and (best == null or k.path.len > best.?.path.len)) best = k;
    }
    return best;
}

/// True when some entry lives strictly below `path` (e.g. `sidebar`).
pub fn isSection(path: []const u8) bool {
    return isSectionIn(&all, path);
}

pub fn isSectionIn(keys: []const KnownKey, path: []const u8) bool {
    for (keys) |*k| {
        if (k.path.len > path.len and k.path[path.len] == '.' and std.mem.startsWith(u8, k.path, path))
            return true;
    }
    return false;
}

const testing = std.testing;

test "unit: settings: cmux known keys cover documented paths" {
    for ([_][]const u8{
        "app.confirmQuit",
        "terminal.agentHibernation.idleSeconds",
        "sidebar.beta.workspaceTodos.checklistStyle",
        "automation.socketControlMode",
        "agentMessages.enabled",
        "diffViewer.defaultLayout",
        "agents.launchers",
        "notifications.soundOverrides",
        "fileEditor.wordWrap",
        "settingPresets",
    }) |p| {
        const k = lookup(p) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(p, k.path);
        try testing.expectEqual(Support.supported, k.support);
    }
}

test "unit: settings: cmux known keys flag mac-only and ignored families" {
    try testing.expectEqual(Support.mac_only, lookup("computerUse.enabled").?.support);
    try testing.expectEqual(Support.mac_only, lookup("app.devWindowDisplay").?.support);
    try testing.expectEqual(Support.ignored, lookup("mobile.browserTunnel.allowOtherHosts").?.support);
    try testing.expectEqual(Support.ignored, lookup("mobile.somethingNew").?.support);
    try testing.expectEqual(Support.ignored, lookup("cloud.anything.deep").?.support);
    try testing.expectEqual(Support.ignored, lookup("shortcuts.bindings.newCloudMachine").?.support);
    // Other bindings fall back to the covering `shortcuts.bindings` entry.
    try testing.expectEqual(Support.supported, lookup("shortcuts.bindings.newTerminal").?.support);
    try testing.expectEqualStrings("ignored on Windows", Support.mac_only.note());
    try testing.expectEqualStrings("not yet supported", Support.supported.note());
}

test "unit: settings: cmux known keys lookup edge cases" {
    try testing.expect(lookup("") == null);
    try testing.expect(lookup("app") == null);
    try testing.expect(isSection("app"));
    try testing.expect(isSection("sidebar.beta"));
    try testing.expect(!isSection("app.confirmQuit"));
    try testing.expect(lookup("mobileX") == null);
    try testing.expect(lookup("app.confirmQuitX") == null);
    try testing.expect(lookup("wmux.sidebar.width") == null);
    try testing.expect(lookup("日本.語") == null);
    try testing.expect(lookup("agentChat.fonts.codeSize").?.project);
    try testing.expect(lookup("notifications.hooks").?.project);
    try testing.expect(!lookup("notifications.sound").?.project);
    try testing.expect(!lookup("app.minimalMode").?.project);
}
