#!/usr/bin/env bash
# codex-advisor.sh — Codex lifecycle hook and local activity signal.
#
# Codex hooks cannot set a subagent's model. This hook only supplies budget
# context; model selection for a new CLI task happens through `cxr`.
#
# Install by adding to ~/.codex/config.toml:
#
#   [[hooks.SessionStart]]
#   [[hooks.SessionStart.hooks]]
#   type = "command"
#   command = "$HOME/.codex/router/hooks/codex-advisor.sh"
#   timeout = 10
#
#   [[hooks.UserPromptSubmit]]
#   [[hooks.UserPromptSubmit.hooks]]
#   type = "command"
#   command = "$HOME/.codex/router/hooks/codex-advisor.sh"
#   timeout = 10
#
# Fails open like every other hook here: any error exits 0 with no output.

set -uo pipefail

ROUTER_HOME="${ROUTER_HOME:-${CODEX_HOME:-$HOME/.codex}/router}"
export ROUTER_CONFIG="${ROUTER_CONFIG:-$ROUTER_HOME/config.json}"

command -v jq >/dev/null 2>&1 || exit 0
[ -r "$ROUTER_CONFIG" ] || exit 0
. "$ROUTER_HOME/lib/config.sh"    2>/dev/null || exit 0
. "$ROUTER_HOME/lib/classify.sh"  2>/dev/null || exit 0
. "$ROUTER_HOME/lib/governor.sh"  2>/dev/null || exit 0
. "$ROUTER_HOME/lib/codex-budget.sh" 2>/dev/null || exit 0
. "$ROUTER_HOME/lib/workspace.sh" 2>/dev/null || exit 0
. "$ROUTER_HOME/lib/activity.sh" 2>/dev/null || exit 0

IN=$(cat 2>/dev/null)
EVENT=$(printf '%s' "$IN" | jq -r '.hook_event_name // ""' 2>/dev/null)
CWD=$(printf '%s'   "$IN" | jq -r '.cwd // .workspace_root // ""' 2>/dev/null)
SID=$(printf '%s' "$IN" | jq -r '.session_id // ""' 2>/dev/null)
MODEL=$(printf '%s' "$IN" | jq -r '.model // ""' 2>/dev/null)
PREVIOUS=$(router_activity_previous_model "$SID")
router_activity_record "$EVENT" "$SID" "$MODEL"
[ "$EVENT" = SessionEnd ] && exit 0
NOTICE=""
if [ -n "$PREVIOUS" ] && [ -n "$MODEL" ] && [ "$PREVIOUS" != "$MODEL" ]; then
  NOTICE="Agent Router · Codex switched model: $PREVIOUS → $MODEL."
fi

router_use_effective_config "${CWD:-$PWD}"

emit() { # emit <event> <context>
  jq -nc --arg e "$1" --arg c "$2" --arg n "$NOTICE" \
    '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}
     + (if $n == "" then {} else {systemMessage:$n} end)'
  exit 0
}

case "$EVENT" in
  SessionStart)
    # Refresh from quota so the first decision of the session is informed.
    governor_refresh_if_stale "$(jq -r '.quota.max_age_seconds // 300' "$ROUTER_CONFIG" 2>/dev/null)"
    STATE=$(governor_state)
    # Keep opted-in subagent roles on the models this budget state allows.
    codex_write_agents refresh >/dev/null 2>&1 || true
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
    [ -n "$PROMPT" ] || { [ -n "$NOTICE" ] && emit UserPromptSubmit ""; exit 0; }
    case "$PROMPT" in "!!"*|"/"*) [ -n "$NOTICE" ] && emit UserPromptSubmit ""; exit 0 ;; esac

    NOTES=""
    STATE=$(governor_state)
    case "$STATE" in
      CRITICAL|DEPLETED)
        NOTES="Agent router: budget state is ${STATE}. Prefer fewer, larger steps over many small ones, and skip exploration that is not needed to finish."
        ;;
    esac
    MM=$(workspace_mismatch "${CWD:-$PWD}")
    [ -n "$MM" ] && NOTES="${NOTES:+$NOTES }Workspace warning: $MM."

    # The running model cannot be changed from here; the user can change it
    # with /model. Say so once per mismatch, only at the ends of the range.
    CUR_RANK=$(codex_model_rank "$MODEL")
    if [ -n "$CUR_RANK" ]; then
      TIER=$(governor_codex_tier "$STATE" "$(classify_tier "" "$PROMPT")")
      TGT_RANK=$(codex_tier_rank "$TIER")
      TARGET=$(jq -r --arg t "$TIER" '.codex_chains[$t][0] | select(. != null) | "\(.model)\t\(.effort)"' "$ROUTER_CONFIG" 2>/dev/null)
      T_MODEL=${TARGET%%$'\t'*}; T_EFFORT=${TARGET#*$'\t'}
      if [ -n "$T_MODEL" ] && [ "$T_MODEL" != "$MODEL" ] &&
         router_rank_extreme "$CUR_RANK" "$TGT_RANK" &&
         router_session_once "$SID" "$CUR_RANK>$T_MODEL"; then
        NOTICE="${NOTICE:+$NOTICE }Agent Router · Codex: this prompt looks like ${TIER} work, which ${T_MODEL} (effort ${T_EFFORT}) covers. Use /model to switch."
      fi
    fi

    [ -z "$NOTES" ] && [ -z "$NOTICE" ] && exit 0
    emit UserPromptSubmit "$NOTES"
    ;;
esac

exit 0
