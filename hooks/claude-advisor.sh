#!/usr/bin/env bash
# claude-advisor.sh — UserPromptSubmit. The only automatic lever inside a live session.
#
# The subagent router is already fully automatic in the way a shell-command hook
# is: installed once, fires on its own, nothing to invoke. The catch is what it
# sits on. A command hook intercepts Bash, which fires constantly; this one
# intercepts the Agent tool, which fires only when work is delegated. Sessions
# that do everything inline never open that door, so the router never runs — and
# inline is where nearly all the spend is.
#
# No hook can switch a running session's model. What a hook can do is inject
# context, and telling the assistant to delegate is telling it to spend less:
# the orchestrator stays expensive and decides, the workers get priced by tier
# on the way out.
#
# It speaks only when there is something to gain, and says nothing otherwise.
# A hook that comments on every prompt gets switched off within a week.

set -uo pipefail

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"
export ROUTER_CONFIG="${ROUTER_CONFIG:-$ROUTER_HOME/config.json}"
command -v jq >/dev/null 2>&1 || exit 0
[ -f "$ROUTER_CONFIG" ] || exit 0
. "$ROUTER_HOME/lib/config.sh"    || exit 0
. "$ROUTER_HOME/lib/classify.sh"  || exit 0
. "$ROUTER_HOME/lib/workspace.sh" || exit 0
. "$ROUTER_HOME/lib/governor.sh"  || exit 0

IN=$(cat)
PROMPT=$(printf '%s' "$IN" | jq -r '.prompt // ""'            2>/dev/null)
CWD=$(printf '%s'    "$IN" | jq -r '.cwd // ""'               2>/dev/null)
SID=$(printf '%s'    "$IN" | jq -r '.session_id // "default"' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

# The subagent router's escape hatch means the same thing here.
case "$PROMPT" in "!!"*) exit 0 ;; esac
# Slash commands carry their own instructions; do not talk over them.
case "$PROMPT" in "/"*) exit 0 ;; esac

EFFECTIVE=$(router_effective_config "${CWD:-$PWD}")
if router_is_temp_config "$EFFECTIVE"; then
  ROUTER_CONFIG="$EFFECTIVE"
  trap 'rm -f "$EFFECTIVE"' EXIT
fi

MODEL=""
[ -f "$ROUTER_HOME/sessions/$SID.model" ] && MODEL=$(cat "$ROUTER_HOME/sessions/$SID.model" 2>/dev/null)

NOTES=""
add_note() { if [ -z "$NOTES" ]; then NOTES="$1"; else NOTES="$NOTES $1"; fi; }

# Only worth speaking when the session itself is an expensive one.
EXPENSIVE=0
case "$MODEL" in *opus*|*fable*) EXPENSIVE=1 ;; esac

DELEGATE=$(jq -r '.advisor.delegate // true' "$ROUTER_CONFIG" 2>/dev/null)
if [ "$EXPENSIVE" -eq 1 ] && [ "$DELEGATE" != "false" ]; then
  TIER=$(classify_tier "" "$PROMPT")
  TARGET=$(governor_model "$TIER")
  case "$TIER" in
    trivial)
      add_note "Router: this request reads as mechanical while the session is on an expensive model. Unless answering it needs the conversation so far, delegate it to router-explorer (routed to ${TARGET}). Running it inline pays the top rate for work that does not need it."
      ;;
    execution)
      add_note "Router: this reads as ordinary implementation work while the session is on an expensive model. Where a bounded part of it stands alone, delegate that part to router-worker (routed to ${TARGET}) and keep the judgement here. Do not delegate work that needs this conversation's context."
      ;;
  esac
fi

STATE=$(governor_state)
case "$STATE" in
  CRITICAL|DEPLETED)
    add_note "Router: budget state is ${STATE}, so subagents are already being degraded. Prefer fewer, larger delegations over many small ones."
    ;;
esac

if [ -n "$CWD" ]; then
  MM=$(workspace_mismatch "$CWD")
  [ -n "$MM" ] && add_note "Workspace warning: $MM."
fi

[ -z "$NOTES" ] && exit 0
jq -nc --arg c "$NOTES" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
