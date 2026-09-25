#!/usr/bin/env bash
# Read a Claude agent's own explicit model declaration, if any.
router_agent_declared_model() {
  local at="$1" dir="${2:-$PWD}" f m
  [ -n "$at" ] || return 0
  case "$at" in */*|*..*) return 0 ;; esac
  for f in "$dir/.claude/agents/$at.md" "$HOME/.claude/agents/$at.md"; do
    [ -r "$f" ] || continue
    m=$(sed -n '/^---[[:space:]]*$/,/^---[[:space:]]*$/p' "$f" 2>/dev/null \
        | sed -n 's/^model:[[:space:]]*//p' | head -1 \
        | sed -e 's/[[:space:]]*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')
    [ -z "$m" ] && continue
    [ "$m" = inherit ] && return 0
    printf '%s' "$m"
    return 0
  done
}
