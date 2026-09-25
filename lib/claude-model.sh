#!/usr/bin/env bash
# Claude model choice from the current budget state.
governor_model() {
  local tier="$1" st model
  st=$(governor_state)
  model=$(jq -r --arg s "$st" --arg t "$tier" '.degrade[$s][$t] // empty' "$ROUTER_CONFIG" 2>/dev/null)
  [ -z "$model" ] && model=sonnet
  printf '%s' "$model"
}

# claude_model_rank <model> -> 1 small, 2 mid, 3 large; empty when unrecognised.
# Accepts aliases (haiku) and full ids (claude-opus-5-5[1m]) alike.
claude_model_rank() {
  case "$1" in
    *haiku*) printf '1' ;;
    *sonnet*) printf '2' ;;
    *opus*|*fable*) printf '3' ;;
  esac
}

# claude_effort <tier> -> configured effort for the tier, or empty for no flag.
claude_effort() {
  jq -r --arg t "$1" '.effort[$t] // empty' "$ROUTER_CONFIG" 2>/dev/null
}

# claude_context_tokens <transcript> -> tokens the latest main-thread turn sent
# as context (fresh + cache read + cache write), or empty. Reads only the tail:
# a long transcript must not make every prompt slow.
claude_context_tokens() {
  [ -r "$1" ] || return 0
  tail -c 2097152 "$1" 2>/dev/null | grep '"type":"assistant"' | tail -n 50 \
    | jq -rs 'map(select(.isSidechain != true and .message.usage != null)) | last
              | .message.usage // empty
              | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null
}
