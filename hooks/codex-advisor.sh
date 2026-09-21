#!/usr/bin/env bash
# codex-advisor.sh — Codex lifecycle hook. Handles SessionStart and UserPromptSubmit.
#
# Codex's hook API is close to Claude Code's — PreToolUse can rewrite tool input
# with the same `hookSpecificOutput.updatedInput` shape — with one difference
# that matters here: a Codex hook *cannot* set a subagent's model. SubagentStart
# carries only `systemMessage` and `additionalContext`. So the enforcement that
# the Claude side gets has no Codex equivalent, and pretending otherwise would be
# worse than the gap.
#
# What does port is context injection, which is the same lever the Claude advisor
# uses: tell the agent what the budget looks like and let it spend accordingly.
# Model selection on this host happens at launch, through `cxr`.
#
# Install by adding to ~/.codex/config.toml:
#
#   [[hooks.SessionStart]]
#   [[hooks.SessionStart.hooks]]
#   type = "command"
#   command = "$HOME/.claude/router/hooks/codex-advisor.sh"
#   timeout = 10
#
#   [[hooks.UserPromptSubmit]]
#   [[hooks.UserPromptSubmit.hooks]]
#   type = "command"
#   command = "$HOME/.claude/router/hooks/codex-advisor.sh"
#   timeout = 10
#
# Fails open like every other hook here: any error exits 0 with no output.

set -uo pipefail

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"
export ROUTER_CONFIG="${ROUTER_CONFIG:-$ROUTER_HOME/config.json}"

command -v jq >/dev/null 2>&1 || exit 0
[ -r "$ROUTER_CONFIG" ] || exit 0
. "$ROUTER_HOME/lib/config.sh"    2>/dev/null || exit 0
. "$ROUTER_HOME/lib/classify.sh"  2>/dev/null || exit 0
. "$ROUTER_HOME/lib/governor.sh"  2>/dev/null || exit 0
. "$ROUTER_HOME/lib/workspace.sh" 2>/dev/null || exit 0

IN=$(cat 2>/dev/null)
EVENT=$(printf '%s' "$IN" | jq -r '.hook_event_name // ""' 2>/dev/null)
CWD=$(printf '%s'   "$IN" | jq -r '.cwd // .workspace_root // ""' 2>/dev/null)

EFFECTIVE=$(router_effective_config "${CWD:-$PWD}")
if router_is_temp_config "$EFFECTIVE"; then
  ROUTER_CONFIG="$EFFECTIVE"
  trap 'rm -f "$EFFECTIVE"' EXIT
fi

emit() { # emit <event> <context>
  jq -nc --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
  exit 0
}

case "$EVENT" in
  SessionStart)
    # Refresh from quota so the first decision of the session is informed.
    governor_refresh_if_stale "$(jq -r '.quota.max_age_seconds // 300' "$ROUTER_CONFIG" 2>/dev/null)"
    STATE=$(governor_state)
    NOTE="Agent router: budget state ${STATE}."
    case "$STATE" in
      CONSERVE) NOTE="$NOTE Quota is over 60% used — prefer the smallest model that can do each step." ;;
      CRITICAL) NOTE="$NOTE Quota is over 85% used — keep work tightly scoped and avoid speculative exploration." ;;
      DEPLETED) NOTE="$NOTE Quota is exhausted and this session is running on a fallback model. Finish what is started rather than beginning new work." ;;
      *)        NOTE="$NOTE Full quota available." ;;
    esac
    MM=$(workspace_mismatch "${CWD:-$PWD}")
    [ -n "$MM" ] && NOTE="$NOTE Workspace warning: $MM."
    emit SessionStart "$NOTE"
    ;;

  UserPromptSubmit)
    PROMPT=$(printf '%s' "$IN" | jq -r '.prompt // .user_prompt // ""' 2>/dev/null)
    [ -n "$PROMPT" ] || exit 0
    case "$PROMPT" in "!!"*|"/"*) exit 0 ;; esac

    NOTES=""
    STATE=$(governor_state)
    case "$STATE" in
      CRITICAL|DEPLETED)
        NOTES="Agent router: budget state is ${STATE}. Prefer fewer, larger steps over many small ones, and skip exploration that is not needed to finish."
        ;;
    esac
    MM=$(workspace_mismatch "${CWD:-$PWD}")
    [ -n "$MM" ] && NOTES="${NOTES:+$NOTES }Workspace warning: $MM."

    [ -z "$NOTES" ] && exit 0
    emit UserPromptSubmit "$NOTES"
    ;;
esac

exit 0
