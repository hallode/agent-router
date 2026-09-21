#!/usr/bin/env bash
# claude-session.sh — SessionStart / PostModelSwitch. Records the session's current
# model so the advisor hook can compare it against what a prompt actually needs.
# UserPromptSubmit does not carry the model, so it has to be remembered here.
set -uo pipefail
ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"
command -v jq >/dev/null 2>&1 || exit 0
IN=$(cat)
SID=$(printf '%s' "$IN" | jq -r '.session_id // "default"' 2>/dev/null)
M=$(printf '%s' "$IN" | jq -r '.model // .to_model // empty' 2>/dev/null)
[ -n "$M" ] || exit 0
mkdir -p "$ROUTER_HOME/sessions" 2>/dev/null
printf '%s' "$M" > "$ROUTER_HOME/sessions/$SID.model" 2>/dev/null || true

# On session start, say once what is active here. No question, no prompt to
# answer: the router is either installed or it is not, like any other hook.
EV=$(printf '%s' "$IN" | jq -r '.hook_event_name // ""' 2>/dev/null)
[ "$EV" = "SessionStart" ] || exit 0
[ -x "$ROUTER_HOME/bin/router" ] || exit 0
CWD=$(printf '%s' "$IN" | jq -r '.cwd // ""' 2>/dev/null)
LINE=$(cd "${CWD:-$PWD}" 2>/dev/null && "$ROUTER_HOME/bin/router" status 2>/dev/null \
       | awk '/^state|^account|^tier map|^override/ {printf "%s; ", $0}')
[ -n "$LINE" ] || exit 0
jq -nc --arg c "Agent router active — $LINE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
