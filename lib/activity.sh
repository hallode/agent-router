#!/usr/bin/env bash
# Small, prompt-free lifecycle log for the local status command.
router_activity_record() {
  local event="$1" sid="$2" model="${3:-}" file
  [ -n "$sid" ] && [ "$sid" != null ] || return 0
  case "$event" in SessionStart|UserPromptSubmit|PostModelSwitch|SessionEnd) ;; *) return 0 ;; esac
  file="${ROUTER_ACTIVITY:-$ROUTER_HOME/activity.jsonl}"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  jq -nc --arg sid "$sid" --arg event "$event" --arg model "$model" \
    --argjson ts "$(date +%s)" \
    '{session:$sid,event:$event,model:$model,ts:$ts}' >> "$file" 2>/dev/null || true
}

router_activity_previous_model() {
  local sid="$1" file="${ROUTER_ACTIVITY:-$ROUTER_HOME/activity.jsonl}"
  [ -n "$sid" ] && [ -s "$file" ] || return 0
  tail -n 1000 "$file" 2>/dev/null | jq -sr --arg sid "$sid" '
    map(select(.session == $sid and (.model | type == "string") and .model != ""))
    | last | .model // empty' 2>/dev/null
}

# router_session_once <sid> <key> -> 0 the first time a session sees <key>, 1 after.
# Keeps a model-fit suggestion to one mention per session instead of every prompt.
router_session_once() {
  local sid="$1" key="$2" dir file
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  dir="${ROUTER_SESSIONS:-$ROUTER_HOME/sessions}"
  file="$dir/$sid.hints"
  [ -f "$file" ] && grep -qxF "$key" "$file" 2>/dev/null && return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$key" >> "$file" 2>/dev/null || return 1
  return 0
}

# router_rank_extreme <current-rank> <target-rank> -> true only at the ends of
# the range: current the largest size while the target is smaller, or current
# the smallest while the target is larger. A middle rank is never flagged —
# only an oversized or undersized session is worth telling the user about.
router_rank_extreme() {
  local cur="$1" tgt="$2"
  { [ "$cur" -eq 3 ] && [ "$tgt" -lt 3 ]; } || { [ "$cur" -eq 1 ] && [ "$tgt" -gt 1 ]; }
}
