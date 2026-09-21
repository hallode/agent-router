#!/usr/bin/env bash
# agent-router.sh — PreToolUse:Agent. Rewrites the subagent's model.
#
# This is the only place in Claude Code where a hook can *enforce* a model
# choice: PreToolUse may rewrite tool input, and the Agent tool's explicit
# `model` param outranks both agent frontmatter and CLAUDE_CODE_SUBAGENT_MODEL.
# No hook can change the main session's model, so the session is configured
# once via the `opusplan` alias instead.
#
# Fails open in every error path: a broken router must never block a tool call.

set -uo pipefail

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"
ROUTER_CONFIG="${ROUTER_CONFIG:-$ROUTER_HOME/config.json}"
ROUTER_LOG="${ROUTER_LOG:-$ROUTER_HOME/decisions.jsonl}"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$ROUTER_CONFIG" ] || exit 0
# shellcheck source=/dev/null
. "$ROUTER_HOME/lib/config.sh"    || exit 0
. "$ROUTER_HOME/lib/classify.sh"  || exit 0
# shellcheck source=/dev/null
. "$ROUTER_HOME/lib/governor.sh"  || exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL" = "Agent" ] || exit 0

# A repository may override routing with .agent-router.json at its root.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
EFFECTIVE=$(router_effective_config "${CWD:-$PWD}")
if router_is_temp_config "$EFFECTIVE"; then
  ROUTER_CONFIG="$EFFECTIVE"
  trap 'rm -f "$EFFECTIVE"' EXIT
fi

TI=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null) || exit 0
AGENT_TYPE=$(printf '%s' "$TI" | jq -r '.subagent_type // ""' 2>/dev/null)
PROMPT=$(printf '%s'    "$TI" | jq -r '.prompt // ""'         2>/dev/null)
DESC=$(printf '%s'      "$TI" | jq -r '.description // ""'    2>/dev/null)

log_decision() {
  printf '%s\n' "$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg at "$AGENT_TYPE" --arg host claude \
    --arg d "$DESC" --arg tier "${1:-}" --arg model "${2:-}" \
    --arg st "${3:-}" --arg act "${4:-}" \
    '{ts:$ts,host:$host,agent_type:$at,description:$d,tier:$tier,model:$model,state:$st,action:$act}')" \
    >> "$ROUTER_LOG" 2>/dev/null || true
}

# A fork inherits the parent model by design; a model override is ignored there.
if [ "$AGENT_TYPE" = "fork" ]; then
  log_decision "" "" "" "skip:fork"
  exit 0
fi

# Escape hatch. `!!` at the head of the prompt means the caller picked the model
# deliberately — strip the marker and leave the call untouched.
BYPASS=$(jq -r '.bypass_prefix // "!!"' "$ROUTER_CONFIG" 2>/dev/null)
case "$PROMPT" in
  "$BYPASS"*)
    STRIPPED=${PROMPT#"$BYPASS"}
    STRIPPED=${STRIPPED# }
    log_decision "" "" "" "bypass"
    printf '%s\n' "$(jq -nc --argjson ti "$TI" --arg p "$STRIPPED" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:($ti + {prompt:$p})}}')"
    exit 0
    ;;
esac

TIER=$(classify_tier "$AGENT_TYPE" "$DESC $PROMPT") || exit 0
STATE=$(governor_state)
MODEL=$(governor_model "$TIER")
[ -n "$MODEL" ] || exit 0

# NOTE: `.enforce // true` is wrong here — jq's // treats false as empty, so
# `false // true` yields true and dry-run mode would never engage.
ENFORCE=$(jq -r 'if has("enforce") then .enforce else true end' "$ROUTER_CONFIG" 2>/dev/null)
if [ "$ENFORCE" != "true" ]; then
  log_decision "$TIER" "$MODEL" "$STATE" "dry-run"
  exit 0
fi

log_decision "$TIER" "$MODEL" "$STATE" "route"
printf '%s\n' "$(jq -nc --argjson ti "$TI" --arg m "$MODEL" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:($ti + {model:$m})}}')"
