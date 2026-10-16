/**
 * Feed panel strings. Keys are stable ids for translators (W7); values are
 * the English defaults handed to tr(). index.html carries the same keys in
 * data-i18n / data-i18n-attr attributes for its static text.
 */
import { tr } from "../_shared/strings.js";

export const STRINGS = Object.freeze({
  "feed.title": "Feed",
  "feed.tabs": "Feed filter",
  "feed.tab.actionable": "Actionable",
  "feed.tab.activity": "All Activity",
  "feed.list": "Feed items",
  "feed.resolved": "Resolved",
  "feed.loadOlder": "Load older activity",
  "feed.loadingOlder": "Loading older activity...",
  "feed.workstreams": "Agents",
  "feed.workstream.pending": "{count} pending",
  "feed.source.unknown": "Agent",

  "feed.time.now": "now",
  "feed.time.minutes": "{count}m",
  "feed.time.hours": "{count}h",
  "feed.time.days": "{count}d",
  "feed.time.weeks": "{count}w",

  "feed.empty.actionable.title": "No pending decisions",
  "feed.empty.actionable.body": "Permission, plan, and question requests from AI agents will appear here.",
  "feed.empty.activity.title": "No activity yet",
  "feed.empty.activity.body": "Agent decisions and todo-list updates will appear here.",

  "feed.kind.permissionRequest": "PERMISSION",
  "feed.kind.exitPlan": "PLAN",
  "feed.kind.question": "QUESTION",
  "feed.kind.stop": "STOP",
  "feed.kind.todos": "TODOS",
  "feed.kind.notification": "NOTIFICATION",
  "feed.kind.message": "MESSAGE",
  "feed.kind.prompt": "PROMPT",
  "feed.kind.toolUse": "TOOL USE",
  "feed.kind.toolResult": "TOOL RESULT",
  "feed.kind.sessionStart": "SESSION START",
  "feed.kind.sessionEnd": "SESSION END",

  "feed.context.you": "You: {text}",
  "feed.context.plan": "Plan: {text}",
  "feed.toolResult.ok": "ok",
  "feed.toolResult.error": "error",
  "feed.jump": "Jump to agent",
  "feed.jump.unavailable": "This agent is not running in a wmux terminal.",
  "feed.jump.failed": "Could not jump to the agent: {message}",

  "feed.permission.once": "Allow Once",
  "feed.permission.always": "Always Allow",
  "feed.permission.all": "All tools",
  "feed.permission.bypass": "Bypass",
  "feed.permission.deny": "Deny",

  "feed.plan.ultraplan": "Ultraplan",
  "feed.plan.manual": "Manual",
  "feed.plan.autoAccept": "Auto",
  "feed.plan.bypassPermissions": "Bypass",
  "feed.plan.deny": "Deny",
  "feed.plan.file": "Plan file: {path}",
  "feed.plan.allowedPrompts": "Allowed prompts",
  "feed.plan.revise": "Revise…",
  "feed.plan.feedbackLabel": "Feedback for the agent",
  "feed.plan.feedbackPlaceholder": "Tell the agent what to change",
  "feed.plan.sendFeedback": "Send feedback",

  "feed.question.noOptions": "Agent provided no options.",
  "feed.question.multiSelect": "Multi-select",
  "feed.question.other": "Other…",
  "feed.question.otherPlaceholder": "Type something...",
  "feed.question.submit": "Submit",
  "feed.question.submitAll": "Submit All Answers",

  "feed.stop.title": "{source} finished — reply to continue",
  "feed.stop.placeholder": "Reply to {source}…",
  "feed.stop.send": "Send to {source}",

  "feed.todos.title": "Tasks",
  "feed.todos.open": "{count} open",
  "feed.todos.inProgress": "{count} in progress",
  "feed.todos.done": "{count} done",
  "feed.todos.show": "Show tasks",
  "feed.todos.collapse": "Collapse",
  "feed.todos.status.pending": "Open",
  "feed.todos.status.in_progress": "In progress",
  "feed.todos.status.completed": "Done",

  "feed.badge.timedOut": "timed out",
  "feed.badge.expired": "expired",
  "feed.sending": "Sending…",

  "feed.banner.region": "Pending decisions",
  "feed.banner.permission": "{source} permission",
  "feed.banner.permissionBody": "{tool} needs approval",
  "feed.banner.decisionNeeded": "Decision needed",
  "feed.banner.plan": "{source} plan ready",
  "feed.banner.planBody": "Review and approve the plan",
  "feed.banner.question": "{source} question",
  "feed.banner.questionBody": "Agent is asking a question",
  "feed.banner.review": "Review",
  "feed.banner.dismiss": "Dismiss banner",

  "feed.status.offline": "Not running inside wmux.",
  "feed.status.loadFailed": "Could not load the feed: {message}",
  "feed.status.replyFailed": "Could not send the decision: {message}",
  "feed.status.alreadyResolved": "This request was already resolved.",
});

/**
 * Translate a feed panel string.
 * @param {keyof typeof STRINGS | string} key
 * @param {Record<string, unknown>} [params]
 */
export function t(key, params) {
  const fallback = Object.prototype.hasOwnProperty.call(STRINGS, key) ? STRINGS[key] : key;
  return tr(key, fallback, params);
}
