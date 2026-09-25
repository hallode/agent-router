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
. "$ROUTER_HOME/lib/claude-model.sh" || exit 0
. "$ROUTER_HOME/lib/activity.sh" || exit 0

IN=$(cat)
PROMPT=$(printf '%s' "$IN" | jq -r '.prompt // ""'            2>/dev/null)
CWD=$(printf '%s'    "$IN" | jq -r '.cwd // ""'               2>/dev/null)
SID=$(printf '%s'    "$IN" | jq -r '.session_id // "default"' 2>/dev/null)
TX=$(printf '%s'     "$IN" | jq -r '.transcript_path // ""'   2>/dev/null)
MODEL=""
case "$SID" in ''|*[!A-Za-z0-9_-]*) ;; *)
  SESS="${ROUTER_SESSIONS:-$ROUTER_HOME/sessions}"
  [ -f "$SESS/$SID.model" ] && MODEL=$(cat "$SESS/$SID.model" 2>/dev/null)
  ;;
esac
router_activity_record UserPromptSubmit "$SID" "$MODEL"
[ -n "$PROMPT" ] || exit 0

# The subagent router's escape hatch means the same thing here.
case "$PROMPT" in "!!"*) exit 0 ;; esac
# Slash commands carry their own instructions; do not talk over them.
case "$PROMPT" in "/"*) exit 0 ;; esac

router_use_effective_config "${CWD:-$PWD}"

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
      add_note "Router: this looks like a small read-only lookup. If it stands alone, use router-scout (routed to ${TARGET}); keep it here when it needs this conversation's context."
      ;;
    execution)
      add_note "Router: this looks like a bounded implementation task. If one part stands alone, use router-builder (routed to ${TARGET}) and keep decisions that need this conversation here."
      ;;
  esac
fi

# A running session's model cannot be switched by a hook, but the user can
# switch it in one command. Say so once per mismatch, and only at the ends of
# the range: a large model on work that does not need it is the overspend, a
# small model on reasoning is the costly retry. A mid-size session is never told.
FIT=""
TIER=${TIER:-$(classify_tier "" "$PROMPT")}
CUR_RANK=$(claude_model_rank "$MODEL")
if [ -n "$CUR_RANK" ]; then
  TARGET=$(governor_model "$TIER")
  TGT_RANK=$(claude_model_rank "$TARGET")
  if [ -n "$TGT_RANK" ] && router_rank_extreme "$CUR_RANK" "$TGT_RANK"; then
    if router_session_once "$SID" "$CUR_RANK>$TARGET"; then
      EFFORT=$(claude_effort "$TIER")
      FIT="Agent Router · Claude: this prompt looks like ${TIER} work, which ${TARGET} covers. Type /model ${TARGET}${EFFORT:+ and /effort ${EFFORT}} to switch."
    fi
  fi
fi

# Every turn resends the whole context, so past a threshold a compaction is the
# cheapest next step. Only the user can run it. Remind again after each further
# `repeat` tokens of growth, never on every prompt.
CTX=$(claude_context_tokens "$TX")
if [ -n "$CTX" ]; then
  case "$MODEL" in
    *'[1m]'*) LIMIT=$(jq -r '.compact.threshold_1m // 250000' "$ROUTER_CONFIG" 2>/dev/null) ;;
    *)        LIMIT=$(jq -r '.compact.threshold // 160000'    "$ROUTER_CONFIG" 2>/dev/null) ;;
  esac
  REPEAT=$(jq -r '.compact.repeat_every // 60000' "$ROUTER_CONFIG" 2>/dev/null)
  if [ "$CTX" -ge "$LIMIT" ] 2>/dev/null && [ "$REPEAT" -gt 0 ] 2>/dev/null &&
     router_session_once "$SID" "compact:$(( (CTX - LIMIT) / REPEAT ))"; then
    MSG="Agent Router · Claude: context is ~$((CTX / 1000))k tokens and every turn resends it. Type /compact, or /clear before an unrelated task."
    FIT="${FIT:+$FIT }$MSG"
  fi
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

[ -z "$NOTES" ] && [ -z "$FIT" ] && exit 0
jq -nc --arg c "$NOTES" --arg f "$FIT" \
  '(if $c == "" then {} else {hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}} end)
   + (if $f == "" then {} else {systemMessage:$f} end)'
