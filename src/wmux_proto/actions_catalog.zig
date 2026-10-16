//! COMPLETE action catalog keyed by cmux action ids, pure data (Appendix A, ADR-8.1).
//! [shared-appendable, merge=union: one sorted line per action]
//!
//! `keys` are Windows default strokes (grammar in strokes.zig), active under
//! `when` (null = global). `scoped` adds strokes that are only active under
//! their own clause (Appendix A rows such as "Ctrl+W only browserFocus").
//! `mac` is cmux's macOS default (cmux.json stroke syntax), kept for docs,
//! preset diffs and the cmux.json translation report. An entry with no keys
//! is "unbound" (palette and rebinding only); `.not_applicable` ids are
//! accepted in config and inert. The keymap conflict test at the bottom pins
//! the table against ADR-8.4.

const std = @import("std");
const strokes = @import("strokes.zig");
const when = @import("when.zig");

pub const Category = enum { app, window, workspace, surface, pane, notification, browser, find, viewer, sidebar, canvas, agent, terminal };

/// A default stroke that is only active under its own clause.
pub const Scoped = struct {
    key: []const u8,
    when: []const u8,
};

pub const Entry = struct {
    id: []const u8, // cmux id ("splitRight", "resize-pane-left", "toggleFileExplorer") or "wmux.<name>"
    title: []const u8, // English label (localized in W7)
    category: Category,
    keys: []const []const u8 = &.{}, // Windows defaults (grammar 8.3); a chord is "ctrl+b c"
    when: ?[]const u8 = null, // built-in context clause
    numbered: bool = false, // 1–9 family; 9 = last
    performable: bool = false, // key passes through when the handler returns .not_applicable
    priority_routing: bool = false, // wins its context outright (right-sidebar digits)
    palette: bool = true,
    availability: enum { supported, not_applicable } = .supported, // cloud/simulator/mac-only ids: accepted in config, inert
    scoped: []const Scoped = &.{}, // extra defaults with their own clause
    mac: ?[]const u8 = null, // cmux macOS default (cmux.json syntax)
};

/// Alternate ids accepted in config and resolved to a catalog id.
pub const aliases = [_]struct { []const u8, []const u8 }{
    .{ "toggleRightSidebar", "toggleFileExplorer" },
};

// zig fmt: off
pub const entries = [_]Entry{
    .{ .id = "agentInbox", .title = "Show Agent Inbox", .category = .notification, .keys = &.{"ctrl+shift+alt+i"}, .mac = "cmd+shift+i" },
    .{ .id = "attachTextBoxFile", .title = "Attach File to TextBox", .category = .agent, .keys = &.{"alt+shift+a"}, .when = "textBoxFocus", .mac = "cmd+opt+shift+a" },
    .{ .id = "browserBack", .title = "Back", .category = .browser, .keys = &.{ "alt+left", "ctrl+shift+[", "mouse4" }, .when = "browserFocus", .mac = "cmd+[" },
    .{ .id = "browserForward", .title = "Forward", .category = .browser, .keys = &.{ "alt+right", "ctrl+shift+]", "mouse5" }, .when = "browserFocus", .mac = "cmd+]" },
    .{ .id = "browserHardReload", .title = "Hard Reload Page", .category = .browser, .keys = &.{ "ctrl+f5", "ctrl+shift+r" }, .when = "browserFocus", .mac = "cmd+shift+r" },
    .{ .id = "browserReload", .title = "Reload Page", .category = .browser, .keys = &.{ "f5", "ctrl+r" }, .when = "browserFocus", .mac = "cmd+r" },
    .{ .id = "browserZoomIn", .title = "Zoom In", .category = .browser, .keys = &.{"ctrl+="}, .when = "browserFocus", .mac = "cmd+=" },
    .{ .id = "browserZoomOut", .title = "Zoom Out", .category = .browser, .keys = &.{"ctrl+-"}, .when = "browserFocus", .mac = "cmd+-" },
    .{ .id = "browserZoomReset", .title = "Actual Size", .category = .browser, .keys = &.{"ctrl+0"}, .when = "browserFocus", .mac = "cmd+0" },
    .{ .id = "canvasAlignBottom", .title = "Canvas: Align Bottom", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasAlignLeft", .title = "Canvas: Align Left", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasAlignRight", .title = "Canvas: Align Right", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasAlignTop", .title = "Canvas: Align Top", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasDistributeHorizontally", .title = "Canvas: Distribute Horizontally", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasDistributeVertically", .title = "Canvas: Distribute Vertically", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasEqualizeHeights", .title = "Canvas: Equalize Heights", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasEqualizeWidths", .title = "Canvas: Equalize Widths", .category = .canvas, .when = "workspaceCanvasLayout" },
    .{ .id = "canvasOverview", .title = "Canvas: Overview", .category = .canvas, .when = "workspaceCanvasLayout", .mac = "cmd+ctrl+o" },
    .{ .id = "canvasRevealFocusedPane", .title = "Canvas: Reveal Focused Pane", .category = .canvas, .when = "workspaceCanvasLayout", .mac = "cmd+ctrl+r" },
    .{ .id = "canvasTidy", .title = "Canvas: Tidy", .category = .canvas, .when = "workspaceCanvasLayout", .mac = "cmd+ctrl+t" },
    .{ .id = "canvasZoomIn", .title = "Canvas: Zoom In", .category = .canvas, .when = "workspaceCanvasLayout", .mac = "cmd+opt+=" },
    .{ .id = "canvasZoomOut", .title = "Canvas: Zoom Out", .category = .canvas, .when = "workspaceCanvasLayout", .mac = "cmd+opt+-" },
    .{ .id = "canvasZoomReset", .title = "Canvas: Actual Size", .category = .canvas, .when = "workspaceCanvasLayout", .mac = "cmd+0" },
    .{ .id = "clearAllNotifications", .title = "Clear All Notifications", .category = .notification },
    .{ .id = "clearScreenKeepScrollback", .title = "Clear Screen (Keep Scrollback)", .category = .terminal, .keys = &.{"ctrl+shift+alt+k"}, .when = "terminalFocus", .mac = "cmd+shift+k" },
    .{ .id = "closeOtherTabsInPane", .title = "Close Other Tabs in Pane", .category = .surface, .keys = &.{"alt+shift+t"}, .mac = "cmd+opt+t" },
    .{ .id = "closeTab", .title = "Close Tab", .category = .surface, .keys = &.{"ctrl+shift+w"}, .scoped = &.{.{ .key = "ctrl+w", .when = "browserFocus || webPanelFocus" }}, .mac = "cmd+w" },
    .{ .id = "closeWindow", .title = "Close Window", .category = .window, .keys = &.{"alt+f4"}, .mac = "cmd+ctrl+w" },
    .{ .id = "closeWorkspace", .title = "Close Workspace", .category = .workspace, .keys = &.{"ctrl+shift+alt+w"}, .mac = "cmd+shift+w" },
    .{ .id = "commandPalette", .title = "Command Palette", .category = .app, .keys = &.{"ctrl+shift+p"}, .mac = "cmd+shift+p" },
    .{ .id = "commandPaletteNext", .title = "Command Palette: Next Item", .category = .app, .keys = &.{ "ctrl+n", "down" }, .when = "commandPaletteVisible", .palette = false, .mac = "ctrl+n" },
    .{ .id = "commandPalettePrevious", .title = "Command Palette: Previous Item", .category = .app, .keys = &.{ "ctrl+p", "up" }, .when = "commandPaletteVisible", .palette = false, .mac = "ctrl+p" },
    .{ .id = "cycleTextBoxSubmitAction", .title = "Cycle TextBox Submit Action", .category = .agent, .keys = &.{"shift+tab"}, .when = "textBoxFocus", .mac = "shift+tab" },
    .{ .id = "cycleWorkspaceStatus", .title = "Cycle Workspace Status", .category = .workspace, .keys = &.{"ctrl+shift+alt+;"}, .mac = "cmd+shift+;" },
    .{ .id = "decreaseWorkspaceTerminalFontSize", .title = "Decrease Workspace Font Size", .category = .workspace, .keys = &.{"ctrl+shift+alt+-"}, .mac = "cmd+ctrl+-" },
    .{ .id = "diffViewerNextFile", .title = "Diff: Next File", .category = .viewer, .keys = &.{"] f"}, .when = "diffViewerFocus", .palette = false, .mac = "] f" },
    .{ .id = "diffViewerNextHunk", .title = "Diff: Next Hunk", .category = .viewer, .keys = &.{"n"}, .when = "diffViewerFocus", .palette = false, .mac = "n" },
    .{ .id = "diffViewerOpenFileSearch", .title = "Diff: Search Files", .category = .viewer, .keys = &.{"/"}, .when = "diffViewerFocus", .palette = false, .mac = "/" },
    .{ .id = "diffViewerPreviousFile", .title = "Diff: Previous File", .category = .viewer, .keys = &.{"[ f"}, .when = "diffViewerFocus", .palette = false, .mac = "[ f" },
    .{ .id = "diffViewerPreviousHunk", .title = "Diff: Previous Hunk", .category = .viewer, .keys = &.{"p"}, .when = "diffViewerFocus", .palette = false, .mac = "p" },
    .{ .id = "diffViewerScrollDown", .title = "Diff: Scroll Down", .category = .viewer, .keys = &.{"j"}, .when = "diffViewerFocus", .palette = false, .mac = "j" },
    .{ .id = "diffViewerScrollDownEmacs", .title = "Diff: Scroll Down (Emacs)", .category = .viewer, .keys = &.{"ctrl+n"}, .when = "diffViewerFocus", .palette = false, .mac = "ctrl+n" },
    .{ .id = "diffViewerScrollHalfPageDown", .title = "Diff: Half Page Down", .category = .viewer, .keys = &.{"ctrl+d"}, .when = "diffViewerFocus", .palette = false, .mac = "ctrl+d" },
    .{ .id = "diffViewerScrollHalfPageUp", .title = "Diff: Half Page Up", .category = .viewer, .keys = &.{"ctrl+u"}, .when = "diffViewerFocus", .palette = false, .mac = "ctrl+u" },
    .{ .id = "diffViewerScrollToBottom", .title = "Diff: Scroll to Bottom", .category = .viewer, .keys = &.{"shift+g"}, .when = "diffViewerFocus", .palette = false, .mac = "shift+g" },
    .{ .id = "diffViewerScrollToTop", .title = "Diff: Scroll to Top", .category = .viewer, .keys = &.{"g g"}, .when = "diffViewerFocus", .palette = false, .mac = "g g" },
    .{ .id = "diffViewerScrollUp", .title = "Diff: Scroll Up", .category = .viewer, .keys = &.{"k"}, .when = "diffViewerFocus", .palette = false, .mac = "k" },
    .{ .id = "diffViewerScrollUpEmacs", .title = "Diff: Scroll Up (Emacs)", .category = .viewer, .keys = &.{"ctrl+p"}, .when = "diffViewerFocus", .palette = false, .mac = "ctrl+p" },
    .{ .id = "diffViewerToggleViewed", .title = "Diff: Toggle Viewed", .category = .viewer, .keys = &.{"v"}, .when = "diffViewerFocus", .palette = false, .mac = "v" },
    .{ .id = "editWorkspaceDescription", .title = "Edit Workspace Description", .category = .workspace, .keys = &.{"alt+shift+e"}, .mac = "cmd+opt+e" },
    .{ .id = "equalizeSplits", .title = "Equalize Splits", .category = .pane, .keys = &.{"alt+shift+="}, .mac = "cmd+ctrl+shift+=" },
    .{ .id = "fileExplorerOpenSelection", .title = "Open Selection", .category = .sidebar, .keys = &.{"enter"}, .when = "fileExplorerFocus", .palette = false, .mac = "enter" },
    .{ .id = "fileExplorerOpenSelectionFinderAlias", .title = "Open Selection (Alternate)", .category = .sidebar, .keys = &.{"ctrl+down"}, .when = "fileExplorerFocus", .palette = false, .mac = "cmd+down" },
    .{ .id = "find", .title = "Find", .category = .find, .keys = &.{"ctrl+shift+f"}, .scoped = &.{.{ .key = "ctrl+f", .when = "!terminalFocus" }}, .mac = "cmd+f" },
    .{ .id = "findInDirectory", .title = "Find in Directory", .category = .find, .keys = &.{"ctrl+shift+alt+f"}, .mac = "cmd+shift+f" },
    .{ .id = "findNext", .title = "Find Next", .category = .find, .keys = &.{"f3"}, .when = "findVisible", .scoped = &.{.{ .key = "enter", .when = "findVisible && findFieldFocus" }}, .mac = "cmd+g" },
    .{ .id = "findPrevious", .title = "Find Previous", .category = .find, .keys = &.{"shift+f3"}, .when = "findVisible", .scoped = &.{.{ .key = "shift+enter", .when = "findVisible && findFieldFocus" }}, .mac = "cmd+opt+g" },
    .{ .id = "focusBrowserAddressBar", .title = "Focus Address Bar", .category = .browser, .keys = &.{ "ctrl+l", "alt+d", "f6" }, .when = "browserFocus", .mac = "cmd+l" },
    .{ .id = "focusDown", .title = "Focus Pane Below", .category = .pane, .keys = &.{"ctrl+alt+down"}, .performable = true, .mac = "cmd+opt+down" },
    .{ .id = "focusHistoryBack", .title = "Back", .category = .app, .keys = &.{ "ctrl+shift+[", "mouse4" }, .when = "!browserFocus", .mac = "cmd+[" },
    .{ .id = "focusHistoryForward", .title = "Forward", .category = .app, .keys = &.{ "ctrl+shift+]", "mouse5" }, .when = "!browserFocus", .mac = "cmd+]" },
    .{ .id = "focusHistoryLast", .title = "Go to Last Focused", .category = .app },
    .{ .id = "focusLeft", .title = "Focus Left Pane", .category = .pane, .keys = &.{"ctrl+alt+left"}, .performable = true, .mac = "cmd+opt+left" },
    .{ .id = "focusNextPane", .title = "Focus Next Pane", .category = .pane },
    .{ .id = "focusPaneByNumber", .title = "Focus Pane 1…9", .category = .pane, .numbered = true, .mac = "cmd+ctrl+1" },
    .{ .id = "focusPreviousPane", .title = "Focus Previous Pane", .category = .pane },
    .{ .id = "focusRight", .title = "Focus Right Pane", .category = .pane, .keys = &.{"ctrl+alt+right"}, .performable = true, .mac = "cmd+opt+right" },
    .{ .id = "focusRightSidebar", .title = "Focus Right Sidebar", .category = .sidebar, .keys = &.{"ctrl+shift+alt+e"}, .mac = "cmd+shift+e" },
    .{ .id = "focusSidebar", .title = "Focus Sidebar", .category = .sidebar, .keys = &.{"ctrl+shift+e"}, .mac = "cmd+ctrl+e" },
    .{ .id = "focusTextBoxInput", .title = "Focus TextBox", .category = .agent, .keys = &.{"ctrl+shift+alt+a"}, .mac = "cmd+shift+a" },
    .{ .id = "focusUp", .title = "Focus Pane Above", .category = .pane, .keys = &.{"ctrl+alt+up"}, .performable = true, .mac = "cmd+opt+up" },
    .{ .id = "globalSearch", .title = "Global Search", .category = .find, .keys = &.{"alt+shift+f"}, .mac = "cmd+opt+f" },
    .{ .id = "goToWorkspace", .title = "Go to Workspace", .category = .workspace, .keys = &.{"ctrl+shift+alt+p"}, .mac = "cmd+p" },
    .{ .id = "groupSelectedWorkspaces", .title = "Group Selected Workspaces", .category = .workspace, .keys = &.{"ctrl+shift+alt+g"}, .performable = true, .mac = "cmd+shift+g" },
    .{ .id = "hideFind", .title = "Hide Find Bar", .category = .find, .keys = &.{"escape"}, .when = "findVisible", .mac = "cmd+opt+shift+f" },
    .{ .id = "increaseWorkspaceTerminalFontSize", .title = "Increase Workspace Font Size", .category = .workspace, .keys = &.{"ctrl+shift+alt+="}, .mac = "cmd+ctrl+=" },
    .{ .id = "jumpToLastPrompt", .title = "Jump to Last Prompt", .category = .notification, .keys = &.{"ctrl+shift+alt+b"}, .mac = "cmd+shift+b" },
    .{ .id = "jumpToUnread", .title = "Jump to Latest Unread", .category = .notification, .keys = &.{"ctrl+shift+u"}, .mac = "cmd+shift+u" },
    .{ .id = "markAllNotificationsRead", .title = "Mark All Notifications Read", .category = .notification },
    .{ .id = "markOldestUnreadAndJumpNext", .title = "Mark Oldest Unread and Jump to Next", .category = .notification, .keys = &.{"ctrl+shift+alt+u"}, .mac = "cmd+ctrl+u" },
    .{ .id = "markWorkspaceDone", .title = "Mark Workspace Done", .category = .workspace, .keys = &.{"ctrl+shift+;"}, .mac = "cmd+;" },
    .{ .id = "markdownZoomIn", .title = "Markdown: Zoom In", .category = .viewer, .keys = &.{"ctrl+="}, .when = "markdownFocus", .mac = "cmd+=" },
    .{ .id = "markdownZoomOut", .title = "Markdown: Zoom Out", .category = .viewer, .keys = &.{"ctrl+-"}, .when = "markdownFocus", .mac = "cmd+-" },
    .{ .id = "markdownZoomReset", .title = "Markdown: Actual Size", .category = .viewer, .keys = &.{"ctrl+0"}, .when = "markdownFocus", .mac = "cmd+0" },
    .{ .id = "moveSurfaceLeft", .title = "Move Surface Left", .category = .surface, .keys = &.{"ctrl+shift+pgup"}, .mac = "cmd+opt+shift+[" },
    .{ .id = "moveSurfaceRight", .title = "Move Surface Right", .category = .surface, .keys = &.{"ctrl+shift+pgdn"}, .mac = "cmd+opt+shift+]" },
    .{ .id = "moveSurfaceToNextPane", .title = "Move Surface to Next Pane", .category = .surface, .mac = "cmd+ctrl+shift+]" },
    .{ .id = "moveSurfaceToPaneDown", .title = "Move Surface to Pane Below", .category = .surface, .keys = &.{"ctrl+shift+alt+down"}, .mac = "cmd+opt+shift+down" },
    .{ .id = "moveSurfaceToPaneLeft", .title = "Move Surface to Left Pane", .category = .surface, .keys = &.{"ctrl+shift+alt+left"}, .mac = "cmd+opt+shift+left" },
    .{ .id = "moveSurfaceToPaneRight", .title = "Move Surface to Right Pane", .category = .surface, .keys = &.{"ctrl+shift+alt+right"}, .mac = "cmd+opt+shift+right" },
    .{ .id = "moveSurfaceToPaneUp", .title = "Move Surface to Pane Above", .category = .surface, .keys = &.{"ctrl+shift+alt+up"}, .mac = "cmd+opt+shift+up" },
    .{ .id = "moveSurfaceToPreviousPane", .title = "Move Surface to Previous Pane", .category = .surface, .mac = "cmd+ctrl+shift+[" },
    .{ .id = "moveWorkspaceDown", .title = "Move Workspace Down", .category = .workspace, .keys = &.{"ctrl+shift+alt+pgdn"}, .mac = "cmd+ctrl+opt+]" },
    .{ .id = "moveWorkspaceUp", .title = "Move Workspace Up", .category = .workspace, .keys = &.{"ctrl+shift+alt+pgup"}, .mac = "cmd+ctrl+opt+[" },
    .{ .id = "newBrowserWorkspace", .title = "New Browser Workspace", .category = .workspace, .keys = &.{"alt+shift+n"}, .mac = "cmd+opt+n" },
    .{ .id = "newCloudMachine", .title = "New Cloud Machine", .category = .workspace, .palette = false, .availability = .not_applicable, .mac = "cmd+shift+y" },
    .{ .id = "newCloudWorkspace", .title = "New Cloud Workspace", .category = .workspace, .palette = false, .availability = .not_applicable, .mac = "cmd+y" },
    .{ .id = "newLocalWorkspace", .title = "New Local Workspace", .category = .workspace, .mac = "cmd+ctrl+opt+n" },
    .{ .id = "newPaneAutoLayout", .title = "New Pane (Auto Layout)", .category = .pane, .mac = "cmd+ctrl+n" },
    .{ .id = "newSurface", .title = "New Surface", .category = .surface, .keys = &.{"ctrl+shift+t"}, .mac = "cmd+t" },
    .{ .id = "newTab", .title = "New Workspace", .category = .workspace, .keys = &.{"ctrl+shift+n"}, .mac = "cmd+n" },
    .{ .id = "newWindow", .title = "New Window", .category = .window, .keys = &.{"ctrl+shift+alt+n"}, .mac = "cmd+shift+n" },
    .{ .id = "newWorkspaceGroup", .title = "New Workspace Group", .category = .workspace, .keys = &.{"alt+shift+g"}, .mac = "cmd+ctrl+g" },
    .{ .id = "nextSidebarTab", .title = "Next Workspace", .category = .workspace, .keys = &.{"ctrl+alt+pgdn"}, .mac = "cmd+ctrl+]" },
    .{ .id = "nextSidebarTabInGroup", .title = "Next Workspace in Group", .category = .workspace },
    .{ .id = "nextSurface", .title = "Next Surface", .category = .surface, .keys = &.{"ctrl+tab"}, .mac = "cmd+shift+]" },
    .{ .id = "openBrowser", .title = "Open Browser", .category = .browser, .keys = &.{"ctrl+shift+l"}, .mac = "cmd+shift+l" },
    .{ .id = "openDiffViewer", .title = "Open Diff Viewer", .category = .viewer, .keys = &.{"ctrl+shift+g"}, .mac = "cmd+ctrl+shift+d" },
    .{ .id = "openFolder", .title = "Open Folder…", .category = .app, .keys = &.{"ctrl+shift+o"}, .mac = "cmd+o" },
    .{ .id = "openSettings", .title = "Settings…", .category = .app, .keys = &.{"ctrl+,"}, .mac = "cmd+," },
    .{ .id = "openTeamPicker", .title = "Open Team Picker", .category = .app, .palette = false, .availability = .not_applicable, .mac = "cmd+opt+shift+t" },
    .{ .id = "pasteLastScreenshot", .title = "Paste Last Screenshot", .category = .terminal },
    .{ .id = "prevSidebarTab", .title = "Previous Workspace", .category = .workspace, .keys = &.{"ctrl+alt+pgup"}, .mac = "cmd+ctrl+[" },
    .{ .id = "prevSidebarTabInGroup", .title = "Previous Workspace in Group", .category = .workspace },
    .{ .id = "prevSurface", .title = "Previous Surface", .category = .surface, .keys = &.{"ctrl+shift+tab"}, .mac = "cmd+shift+[" },
    .{ .id = "quit", .title = "Quit", .category = .app, .keys = &.{"ctrl+shift+q"}, .mac = "cmd+q" },
    .{ .id = "reloadConfiguration", .title = "Reload Configuration", .category = .app, .keys = &.{"ctrl+shift+,"}, .mac = "cmd+shift+," },
    .{ .id = "renameTab", .title = "Rename Tab", .category = .surface, .keys = &.{"ctrl+shift+r"}, .when = "!browserFocus", .mac = "cmd+r" },
    .{ .id = "renameWorkspace", .title = "Rename Workspace", .category = .workspace, .keys = &.{"ctrl+shift+alt+r"}, .mac = "cmd+shift+r" },
    .{ .id = "reopenClosedBrowserPanel", .title = "Reopen Last Closed", .category = .surface, .keys = &.{"ctrl+shift+alt+t"}, .mac = "cmd+shift+t" },
    .{ .id = "reopenClosedWorkspace", .title = "Reopen Closed Workspace", .category = .workspace },
    .{ .id = "reopenPreviousSession", .title = "Reopen Previous Session", .category = .app, .keys = &.{"ctrl+shift+alt+o"}, .mac = "cmd+shift+o" },
    .{ .id = "resetWorkspaceTerminalFontSize", .title = "Reset Workspace Font Size", .category = .workspace, .keys = &.{"ctrl+shift+alt+0"}, .mac = "cmd+ctrl+0" },
    .{ .id = "resize-pane-down", .title = "Resize Pane Down", .category = .pane, .keys = &.{"alt+shift+down"}, .mac = "ctrl+shift+j" },
    .{ .id = "resize-pane-left", .title = "Resize Pane Left", .category = .pane, .keys = &.{"alt+shift+left"}, .mac = "ctrl+shift+h" },
    .{ .id = "resize-pane-right", .title = "Resize Pane Right", .category = .pane, .keys = &.{"alt+shift+right"}, .mac = "ctrl+shift+l" },
    .{ .id = "resize-pane-up", .title = "Resize Pane Up", .category = .pane, .keys = &.{"alt+shift+up"}, .mac = "ctrl+shift+k" },
    .{ .id = "saveFilePreview", .title = "Save File", .category = .viewer, .keys = &.{"ctrl+s"}, .when = "filePreviewTextEditorFocus || markdownEditFocus", .mac = "cmd+s" },
    .{ .id = "saveLayoutTemplate", .title = "Save Layout Template…", .category = .workspace, .keys = &.{"ctrl+shift+s"}, .mac = "cmd+ctrl+s" },
    .{ .id = "selectSurfaceByNumber", .title = "Select Surface 1…9", .category = .surface, .keys = &.{"ctrl+shift+alt+1"}, .numbered = true, .mac = "ctrl+1" },
    .{ .id = "selectWorkspaceByNumber", .title = "Select Workspace 1…9", .category = .workspace, .keys = &.{"ctrl+shift+1"}, .numbered = true, .mac = "cmd+1" },
    .{ .id = "sendCtrlFToTerminal", .title = "Send Ctrl+F to Terminal", .category = .terminal },
    .{ .id = "sendFeedback", .title = "Send Feedback", .category = .app, .palette = false, .availability = .not_applicable },
    .{ .id = "showBrowserJavaScriptConsole", .title = "Show JavaScript Console", .category = .browser, .keys = &.{"alt+shift+c"}, .when = "browserFocus", .mac = "cmd+opt+c" },
    .{ .id = "showHideAllWindows", .title = "Show/Hide All Windows", .category = .window, .mac = "cmd+ctrl+opt+." },
    .{ .id = "showNotifications", .title = "Show Notifications", .category = .notification, .keys = &.{"ctrl+shift+i"}, .mac = "cmd+i" },
    .{ .id = "showWindowHints", .title = "Show Window Hints", .category = .window, .keys = &.{"ctrl+shift+j"}, .mac = "cmd+j" },
    .{ .id = "simulatorHome", .title = "Simulator: Home", .category = .app, .when = "simulatorFocus", .palette = false, .availability = .not_applicable, .mac = "cmd+shift+h" },
    .{ .id = "simulatorRotateLeft", .title = "Simulator: Rotate Left", .category = .app, .when = "simulatorFocus", .palette = false, .availability = .not_applicable, .mac = "cmd+left" },
    .{ .id = "simulatorRotateRight", .title = "Simulator: Rotate Right", .category = .app, .when = "simulatorFocus", .palette = false, .availability = .not_applicable, .mac = "cmd+right" },
    .{ .id = "simulatorToggleAppearance", .title = "Simulator: Toggle Appearance", .category = .app, .when = "simulatorFocus", .palette = false, .availability = .not_applicable, .mac = "cmd+shift+a" },
    .{ .id = "simulatorToggleSoftwareKeyboard", .title = "Simulator: Toggle Software Keyboard", .category = .app, .when = "simulatorFocus", .palette = false, .availability = .not_applicable, .mac = "cmd+k" },
    .{ .id = "sizeTerminalToMyWindow", .title = "Size Terminal to My Window", .category = .terminal, .palette = false, .availability = .not_applicable, .mac = "cmd+ctrl+opt+=" },
    .{ .id = "splitBrowserDown", .title = "Split Browser Down", .category = .pane, .mac = "cmd+opt+shift+d" },
    .{ .id = "splitBrowserRight", .title = "Split Browser Right", .category = .pane, .keys = &.{"alt+shift+d"}, .mac = "cmd+opt+d" },
    .{ .id = "splitDown", .title = "Split Down", .category = .pane, .keys = &.{"ctrl+shift+alt+d"}, .mac = "cmd+shift+d" },
    .{ .id = "splitRight", .title = "Split Right", .category = .pane, .keys = &.{"ctrl+shift+d"}, .mac = "cmd+d" },
    .{ .id = "switchRightSidebarToDock", .title = "Show Sidebar Dock", .category = .sidebar, .keys = &.{"ctrl+5"}, .when = "rightSidebarFocus", .priority_routing = true, .mac = "ctrl+5" },
    .{ .id = "switchRightSidebarToFeed", .title = "Show Sidebar Feed", .category = .sidebar, .keys = &.{"ctrl+4"}, .when = "rightSidebarFocus", .priority_routing = true, .mac = "ctrl+4" },
    .{ .id = "switchRightSidebarToFiles", .title = "Show Sidebar Files", .category = .sidebar, .keys = &.{"ctrl+1"}, .when = "rightSidebarFocus", .priority_routing = true, .mac = "ctrl+1" },
    .{ .id = "switchRightSidebarToFind", .title = "Show Sidebar Find", .category = .sidebar, .keys = &.{"ctrl+2"}, .when = "rightSidebarFocus", .priority_routing = true, .mac = "ctrl+2" },
    .{ .id = "switchRightSidebarToMachines", .title = "Show Sidebar Machines", .category = .sidebar, .palette = false, .availability = .not_applicable, .mac = "ctrl+6" },
    .{ .id = "switchRightSidebarToSessions", .title = "Show Sidebar Sessions", .category = .sidebar, .keys = &.{"ctrl+3"}, .when = "rightSidebarFocus", .priority_routing = true, .mac = "ctrl+3" },
    .{ .id = "toggleBrowserDesignMode", .title = "Toggle Design Mode", .category = .browser, .when = "browserFocus", .mac = "cmd+ctrl+opt+d" },
    .{ .id = "toggleBrowserDeveloperTools", .title = "Toggle Developer Tools", .category = .browser, .keys = &.{ "f12", "alt+shift+i" }, .when = "browserFocus", .mac = "cmd+opt+i" },
    .{ .id = "toggleBrowserFocusMode", .title = "Toggle Browser Focus Mode", .category = .browser, .keys = &.{"alt+shift+enter"}, .when = "browserFocus", .mac = "cmd+opt+enter" },
    .{ .id = "toggleCanvasLayout", .title = "Toggle Canvas Layout", .category = .canvas, .keys = &.{"ctrl+shift+alt+c"}, .mac = "cmd+ctrl+c" },
    .{ .id = "toggleChecklistItemComplete", .title = "Toggle Checklist Item Complete", .category = .workspace, .keys = &.{"ctrl+enter"}, .when = "todoFocus", .mac = "cmd+enter" },
    .{ .id = "toggleFileEditorWordWrap", .title = "Toggle File Editor Word Wrap", .category = .viewer, .keys = &.{"alt+z"}, .when = "filePreviewTextEditorFocus", .mac = "opt+z" },
    .{ .id = "toggleFileExplorer", .title = "Toggle Right Sidebar", .category = .sidebar, .keys = &.{"alt+shift+b"}, .mac = "cmd+opt+b" },
    .{ .id = "toggleFocusedWorkspaceGroupCollapsed", .title = "Collapse/Expand Workspace Group", .category = .workspace, .keys = &.{"ctrl+shift+."}, .mac = "cmd+ctrl+." },
    .{ .id = "toggleFullScreen", .title = "Toggle Full Screen", .category = .window, .keys = &.{"f11"}, .mac = "cmd+ctrl+f" },
    .{ .id = "toggleReactGrab", .title = "Toggle React Grab", .category = .browser, .keys = &.{"ctrl+shift+alt+g"}, .when = "browserFocus", .mac = "cmd+shift+g" },
    .{ .id = "toggleSidebar", .title = "Toggle Sidebar", .category = .sidebar, .keys = &.{"ctrl+shift+b"}, .mac = "cmd+b" },
    .{ .id = "toggleSplitZoom", .title = "Toggle Split Zoom", .category = .pane, .keys = &.{"ctrl+shift+enter"}, .mac = "cmd+shift+enter" },
    .{ .id = "toggleTerminalCopyMode", .title = "Toggle Copy Mode", .category = .terminal, .keys = &.{"ctrl+shift+m"}, .when = "terminalFocus", .mac = "cmd+shift+m" },
    .{ .id = "toggleUnread", .title = "Toggle Unread", .category = .notification, .keys = &.{"alt+shift+u"}, .mac = "cmd+opt+u" },
    .{ .id = "triggerFlash", .title = "Flash Focused Panel", .category = .notification, .keys = &.{"ctrl+shift+h"}, .mac = "cmd+shift+h" },
    .{ .id = "useSelectionForFind", .title = "Use Selection for Find", .category = .find, .mac = "cmd+e" },
    .{ .id = "wmux.attentionClear", .title = "Clear Attention Ring", .category = .notification },
    .{ .id = "wmux.attentionRing", .title = "Ring Attention", .category = .notification },
    .{ .id = "wmux.breakPane", .title = "Break Pane into Workspace", .category = .pane },
    .{ .id = "wmux.clearScreen", .title = "Clear Screen", .category = .terminal, .keys = &.{"ctrl+shift+k"}, .when = "terminalFocus", .mac = "cmd+k" },
    .{ .id = "wmux.pasteFromClipboard", .title = "Paste", .category = .terminal, .keys = &.{"ctrl+v"}, .when = "terminalFocus && !terminalAlternateScreen", .performable = true, .mac = "cmd+v" },
    .{ .id = "wmux.selectLayout.evenHorizontal", .title = "Layout: Even Horizontal", .category = .pane },
    .{ .id = "wmux.selectLayout.evenVertical", .title = "Layout: Even Vertical", .category = .pane },
    .{ .id = "wmux.selectLayout.mainHorizontal", .title = "Layout: Main Horizontal", .category = .pane },
    .{ .id = "wmux.selectLayout.mainVertical", .title = "Layout: Main Vertical", .category = .pane },
    .{ .id = "wmux.selectLayout.tiled", .title = "Layout: Tiled", .category = .pane },
    .{ .id = "wmux.swapPane", .title = "Swap Pane", .category = .pane },
    .{ .id = "wmux.toggleQuickTerminal", .title = "Toggle Quick Terminal", .category = .window },
    .{ .id = "wmux.toggleSyncInput", .title = "Toggle Synchronized Input", .category = .pane },
};
// zig fmt: on

comptime {
    @setEvalBranchQuota(1_000_000);
    for (entries[1..], 1..) |e, i| {
        const prev = entries[i - 1].id;
        if (std.mem.eql(u8, prev, e.id)) @compileError("actions_catalog: duplicate id " ++ e.id);
        if (!std.mem.lessThan(u8, prev, e.id)) @compileError("actions_catalog: not sorted at " ++ e.id);
    }
    for (aliases) |al| {
        if (findComptime(al[0]) != null) @compileError("actions_catalog: alias shadows an id: " ++ al[0]);
        if (findComptime(al[1]) == null) @compileError("actions_catalog: alias target missing: " ++ al[1]);
    }
}

fn findComptime(comptime id: []const u8) ?usize {
    for (entries, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
    return null;
}

fn orderId(key: []const u8, e: Entry) std.math.Order {
    return std.mem.order(u8, key, e.id);
}

/// Looks up an action by id (aliases resolved). Binary search; entries are sorted.
pub fn find(id: []const u8) ?*const Entry {
    const target = for (aliases) |al| {
        if (std.mem.eql(u8, al[0], id)) break al[1];
    } else id;
    const idx = std.sort.binarySearch(Entry, &entries, target, orderId) orelse return null;
    return &entries[idx];
}

/// True for ids accepted in `shortcuts.bindings` / `shortcuts.when`.
pub fn isKnownId(id: []const u8) bool {
    return find(id) != null;
}

/// True for numbered families (selectWorkspaceByNumber etc.).
pub fn isNumbered(id: []const u8) bool {
    return if (find(id)) |e| e.numbered else false;
}

test "unit: keys: catalog lookup" {
    try std.testing.expectEqualStrings("splitRight", find("splitRight").?.id);
    try std.testing.expectEqualStrings("toggleFileExplorer", find("toggleRightSidebar").?.id);
    try std.testing.expect(find("resize-pane-left") != null);
    try std.testing.expect(find("wmux.selectLayout.tiled") != null);
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("splitright") == null);
    try std.testing.expect(find("zzz") == null);
    try std.testing.expect(isNumbered("selectWorkspaceByNumber"));
    try std.testing.expect(!isNumbered("splitRight"));
    for (&entries) |*e| try std.testing.expectEqual(e, find(e.id).?);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const keymap = @import("keymap_presets.zig");

/// Every Appendix A action id (wildcard rows expanded). Pinned by hand:
/// adding a catalog entry means adding it here too.
const appendix_a_ids = [_][]const u8{
    "agentInbox",                           "attachTextBoxFile",                "browserBack",                          "browserForward",               "browserHardReload",
    "browserReload",                        "browserZoomIn",                    "browserZoomOut",                       "browserZoomReset",             "canvasAlignBottom",
    "canvasAlignLeft",                      "canvasAlignRight",                 "canvasAlignTop",                       "canvasDistributeHorizontally", "canvasDistributeVertically",
    "canvasEqualizeHeights",                "canvasEqualizeWidths",             "canvasOverview",                       "canvasRevealFocusedPane",      "canvasTidy",
    "canvasZoomIn",                         "canvasZoomOut",                    "canvasZoomReset",                      "clearAllNotifications",        "clearScreenKeepScrollback",
    "closeOtherTabsInPane",                 "closeTab",                         "closeWindow",                          "closeWorkspace",               "commandPalette",
    "commandPaletteNext",                   "commandPalettePrevious",           "cycleTextBoxSubmitAction",             "cycleWorkspaceStatus",         "decreaseWorkspaceTerminalFontSize",
    "diffViewerNextFile",                   "diffViewerNextHunk",               "diffViewerOpenFileSearch",             "diffViewerPreviousFile",       "diffViewerPreviousHunk",
    "diffViewerScrollDown",                 "diffViewerScrollDownEmacs",        "diffViewerScrollHalfPageDown",         "diffViewerScrollHalfPageUp",   "diffViewerScrollToBottom",
    "diffViewerScrollToTop",                "diffViewerScrollUp",               "diffViewerScrollUpEmacs",              "diffViewerToggleViewed",       "editWorkspaceDescription",
    "equalizeSplits",                       "fileExplorerOpenSelection",        "fileExplorerOpenSelectionFinderAlias", "find",                         "findInDirectory",
    "findNext",                             "findPrevious",                     "focusBrowserAddressBar",               "focusDown",                    "focusHistoryBack",
    "focusHistoryForward",                  "focusHistoryLast",                 "focusLeft",                            "focusNextPane",                "focusPaneByNumber",
    "focusPreviousPane",                    "focusRight",                       "focusRightSidebar",                    "focusSidebar",                 "focusTextBoxInput",
    "focusUp",                              "globalSearch",                     "goToWorkspace",                        "groupSelectedWorkspaces",      "hideFind",
    "increaseWorkspaceTerminalFontSize",    "jumpToLastPrompt",                 "jumpToUnread",                         "markAllNotificationsRead",     "markOldestUnreadAndJumpNext",
    "markWorkspaceDone",                    "markdownZoomIn",                   "markdownZoomOut",                      "markdownZoomReset",            "moveSurfaceLeft",
    "moveSurfaceRight",                     "moveSurfaceToNextPane",            "moveSurfaceToPaneDown",                "moveSurfaceToPaneLeft",        "moveSurfaceToPaneRight",
    "moveSurfaceToPaneUp",                  "moveSurfaceToPreviousPane",        "moveWorkspaceDown",                    "moveWorkspaceUp",              "newBrowserWorkspace",
    "newCloudMachine",                      "newCloudWorkspace",                "newLocalWorkspace",                    "newPaneAutoLayout",            "newSurface",
    "newTab",                               "newWindow",                        "newWorkspaceGroup",                    "nextSidebarTab",               "nextSidebarTabInGroup",
    "nextSurface",                          "openBrowser",                      "openDiffViewer",                       "openFolder",                   "openSettings",
    "openTeamPicker",                       "pasteLastScreenshot",              "prevSidebarTab",                       "prevSidebarTabInGroup",        "prevSurface",
    "quit",                                 "reloadConfiguration",              "renameTab",                            "renameWorkspace",              "reopenClosedBrowserPanel",
    "reopenClosedWorkspace",                "reopenPreviousSession",            "resetWorkspaceTerminalFontSize",       "resize-pane-down",             "resize-pane-left",
    "resize-pane-right",                    "resize-pane-up",                   "saveFilePreview",                      "saveLayoutTemplate",           "selectSurfaceByNumber",
    "selectWorkspaceByNumber",              "sendCtrlFToTerminal",              "sendFeedback",                         "showBrowserJavaScriptConsole", "showHideAllWindows",
    "showNotifications",                    "showWindowHints",                  "simulatorHome",                        "simulatorRotateLeft",          "simulatorRotateRight",
    "simulatorToggleAppearance",            "simulatorToggleSoftwareKeyboard",  "sizeTerminalToMyWindow",               "splitBrowserDown",             "splitBrowserRight",
    "splitDown",                            "splitRight",                       "switchRightSidebarToDock",             "switchRightSidebarToFeed",     "switchRightSidebarToFiles",
    "switchRightSidebarToFind",             "switchRightSidebarToMachines",     "switchRightSidebarToSessions",         "toggleBrowserDesignMode",      "toggleBrowserDeveloperTools",
    "toggleBrowserFocusMode",               "toggleCanvasLayout",               "toggleChecklistItemComplete",          "toggleFileEditorWordWrap",     "toggleFileExplorer",
    "toggleFocusedWorkspaceGroupCollapsed", "toggleFullScreen",                 "toggleReactGrab",                      "toggleSidebar",                "toggleSplitZoom",
    "toggleTerminalCopyMode",               "toggleUnread",                     "triggerFlash",                         "useSelectionForFind",          "wmux.attentionClear",
    "wmux.attentionRing",                   "wmux.breakPane",                   "wmux.clearScreen",                     "wmux.pasteFromClipboard",      "wmux.selectLayout.evenHorizontal",
    "wmux.selectLayout.evenVertical",       "wmux.selectLayout.mainHorizontal", "wmux.selectLayout.mainVertical",       "wmux.selectLayout.tiled",      "wmux.swapPane",
    "wmux.toggleQuickTerminal",             "wmux.toggleSyncInput",
};

test "unit: keys: every Appendix A id present exactly once" {
    for (appendix_a_ids) |id| {
        var n: usize = 0;
        for (entries) |e| {
            if (std.mem.eql(u8, e.id, id)) n += 1;
        }
        testing.expectEqual(@as(usize, 1), n) catch |err| {
            std.log.err("Appendix A id '{s}' appears {d} times", .{ id, n });
            return err;
        };
    }
    try testing.expectEqual(appendix_a_ids.len, entries.len);
}

test "unit: keys: catalog entries are well-formed" {
    const gpa = testing.allocator;
    for (entries) |e| {
        errdefer std.log.err("bad catalog entry '{s}'", .{e.id});
        try testing.expect(e.id.len > 0 and e.title.len > 0);
        for (e.keys) |k| _ = try strokes.Trigger.parse(k, .windows);
        for (e.scoped) |sc| {
            _ = try strokes.Trigger.parse(sc.key, .windows);
            try expectKnownKeys(gpa, sc.when);
        }
        if (e.mac) |m| _ = try strokes.Trigger.parse(m, .mac);
        if (e.when) |w| try expectKnownKeys(gpa, w);
        if (e.numbered) {
            try testing.expect(e.keys.len <= 1);
            for (e.keys) |k| try testing.expectEqual(strokes.Key.@"1", (try strokes.Trigger.parse(k, .windows)).first.key);
        }
        if (e.priority_routing) try testing.expect(e.when != null);
        if (e.availability == .not_applicable) {
            try testing.expect(e.keys.len == 0 and e.scoped.len == 0 and !e.palette);
        }
        if (std.mem.startsWith(u8, e.id, "wmux.")) try testing.expect(e.id.len > "wmux.".len);
    }
}

fn expectKnownKeys(gpa: std.mem.Allocator, src: []const u8) !void {
    var c = try when.parse(gpa, src);
    defer c.deinit();
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    try c.collectKeys(gpa, &keys);
    for (keys.items) |k| {
        if (!when.isContextKey(k)) {
            std.log.err("unknown context key '{s}' in '{s}'", .{ k, src });
            return error.TestUnexpectedResult;
        }
    }
}

/// Defaults that intentionally share a stroke in an overlapping context:
/// `groupSelectedWorkspaces` is performable and falls through to the
/// browser's `toggleReactGrab` without a multi-selection (Appendix A.5).
const shared_strokes = [_][2][]const u8{
    .{ "groupSelectedWorkspaces", "toggleReactGrab" },
};

fn logBinding(b: keymap.Binding) void {
    var buf: [64]u8 = undefined;
    const t = strokes.bufPrint(&buf, b.trigger, .windows) catch "?";
    std.log.err("  {s}: '{s}' when {s}", .{ b.id, t, b.when orelse "(global)" });
}

test "unit: keys: KEYMAP CONFLICT TEST: no two defaults collide in the same effective context" {
    const gpa = testing.allocator;
    const bindings = try keymap.effectiveBindings(gpa, null);
    defer gpa.free(bindings);
    try testing.expect(bindings.len > 100);
    const conflicts = try keymap.findConflicts(gpa, bindings, .{ .allow = &shared_strokes });
    defer gpa.free(conflicts);
    for (conflicts) |c| {
        std.log.err("default keymap conflict:", .{});
        logBinding(c.a);
        logBinding(c.b);
    }
    try testing.expectEqual(@as(usize, 0), conflicts.len);
    // The allowlist is not stale: the pair really shares a stroke.
    const strict = try keymap.findConflicts(gpa, bindings, .{});
    defer gpa.free(strict);
    try testing.expectEqual(shared_strokes.len, strict.len);
}

/// Terminal-capable defaults exempt from the tier rules, with the reason
/// pinned here: they only fire while the find bar is visible (Appendix A.5;
/// F3 is deliberately not global because of htop/mc), and Esc mirrors
/// Ghostty's own `escape` → end search.
const safety_exempt = [_]struct { []const u8, []const u8 }{
    .{ "findNext", "f3" },
    .{ "findPrevious", "shift+f3" },
    .{ "hideFind", "escape" },
};

/// Ghostty win32 defaults kept on terminal focus (ADR-8.7, Appendix A.7).
const ghostty_kept = [_][]const u8{
    "ctrl+c",       "ctrl+shift+c", "ctrl+shift+v", "ctrl+insert",   "ctrl+shift+a",
    "shift+insert", "ctrl+=",       "ctrl+-",       "ctrl+0",        "shift+pgup",
    "shift+pgdn",   "shift+home",   "shift+end",    "ctrl+shift+up", "ctrl+shift+down",
    "escape",
};

fn isExempt(b: keymap.Binding) !bool {
    for (safety_exempt) |ex| {
        if (std.mem.eql(u8, ex[0], b.id) and b.trigger.eql(try strokes.Trigger.parse(ex[1], .windows))) return true;
    }
    return false;
}

test "unit: keys: no default claims a terminal-reserved key (ADR-8.4)" {
    const gpa = testing.allocator;
    const bindings = try keymap.effectiveBindings(gpa, null);
    defer gpa.free(bindings);
    var bad: usize = 0;
    var terminal_capable: usize = 0;
    for (bindings) |b| {
        const s = b.trigger.first;
        const m = s.mods;
        // Never, in any context: Alt+digit (readline/PSReadLine digit-argument),
        // Ctrl+Alt+<printable> (AltGr), Win+<key> (OS).
        const alt_digit = m.eql(.{ .alt = true }) and s.key.kind() == .digit;
        const altgr = m.ctrl and m.alt and !m.shift and s.key.isPrintable();
        if (alt_digit or altgr or m.win or m.cmd) {
            std.log.err("default claims a reserved key in every context:", .{});
            logBinding(b);
            bad += 1;
        }
        if (!keymap.terminalCapable(b)) continue;
        terminal_capable += 1;
        if (keymap.violatesTerminalSafety(b) and !try isExempt(b)) {
            std.log.err("terminal-capable default violates ADR-8.4:", .{});
            logBinding(b);
            bad += 1;
        }
        for (ghostty_kept) |g| {
            if (b.trigger.eql(try strokes.Trigger.parse(g, .windows)) and !try isExempt(b)) {
                std.log.err("terminal-capable default shadows a kept Ghostty key:", .{});
                logBinding(b);
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expect(terminal_capable > 50);
    // Every exemption is still in use.
    for (safety_exempt) |ex| {
        const e = find(ex[0]).?;
        try testing.expect(e.keys.len > 0 and std.mem.eql(u8, e.keys[0], ex[1]));
    }
}

test "unit: keys: non-terminal contexts may use plain Ctrl and bare keys" {
    const gpa = testing.allocator;
    const bindings = try keymap.effectiveBindings(gpa, null);
    defer gpa.free(bindings);
    var plain: usize = 0;
    for (bindings) |b| {
        if (keymap.terminalCapable(b)) continue;
        if (strokes.tier(b.trigger.first) == .reserved) plain += 1;
    }
    // diff viewer letters, browser Ctrl+L/F5, palette Ctrl+N, find Enter, ...
    try testing.expect(plain > 20);
    // Ctrl+W closes tabs only in browser/web panels; Ctrl+F finds only off-terminal.
    for (bindings) |b| {
        if (std.mem.eql(u8, b.id, "closeTab") or std.mem.eql(u8, b.id, "find")) {
            if (b.trigger.first.mods.eql(.{ .ctrl = true })) try testing.expect(!keymap.terminalCapable(b));
        }
    }
}

test "unit: keys: mac defaults parse and translate (ADR-8.6 spot checks)" {
    // The cmux.json translation (ADR-8.6) of every macOS default parses and
    // yields a stroke; entries whose Windows default follows the plain rule
    // agree with the translation (spot checks of the tier mapping).
    const same = [_][]const u8{ "splitRight", "newSurface", "splitDown", "renameWorkspace", "toggleFileExplorer", "editWorkspaceDescription", "closeOtherTabsInPane", "resize-pane-left" };
    for (same) |id| {
        const e = find(id).?;
        const t = strokes.translateMacTrigger(try strokes.Trigger.parse(e.mac.?, .mac));
        const want = try strokes.Trigger.parse(e.keys[0], .windows);
        if (std.mem.eql(u8, id, "resize-pane-left")) {
            // ⌃⇧H stays Ctrl+Shift+H (tier A collides with triggerFlash); Windows uses Alt+Shift+Left.
            try testing.expect(!t.eql(want));
            continue;
        }
        testing.expect(t.eql(want)) catch |err| {
            std.log.err("{s}: mac '{s}' does not translate to '{s}'", .{ id, e.mac.?, e.keys[0] });
            return err;
        };
    }
    for (entries) |e| if (e.mac) |m| {
        _ = strokes.translateMacTrigger(try strokes.Trigger.parse(m, .mac));
    };
}
