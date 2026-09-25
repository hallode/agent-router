#!/usr/bin/env bash
# Codex fallback chains are for availability, not cost. Save budget by lowering
# the task tier, always starting at that tier's first model.
governor_codex_tier() { # <state> <classified-tier>
  local state="$1" tier="$2"
  case "$state:$tier" in
    NORMAL:*|CONSERVE:trivial|CRITICAL:trivial) printf '%s' "$tier" ;;
    CONSERVE:reasoning|CRITICAL:reasoning) printf 'execution' ;;
    CRITICAL:execution|DEPLETED:*) printf 'trivial' ;;
    *) printf '%s' "$tier" ;;
  esac
}

# codex_tier_rank <tier> -> 1 trivial, 2 execution, 3 reasoning.
codex_tier_rank() {
  case "$1" in trivial) printf '1' ;; execution) printf '2' ;; reasoning) printf '3' ;; esac
}

# codex_model_rank <model> -> rank of the tier whose first choice is <model>, or
# empty. Only first choices count: later entries are availability fallbacks
# that often repeat across tiers, so they say nothing about size.
codex_model_rank() {
  local tier
  [ -n "$1" ] || return 0
  tier=$(jq -r --arg m "$1" '
    [("reasoning","execution","trivial") as $t
     | select(.codex_chains[$t][0].model == $m) | $t] | first // empty' "$ROUTER_CONFIG" 2>/dev/null)
  codex_tier_rank "$tier"
}

# Codex subagent roles. A hook cannot set a spawned subagent's model, but a role
# file in the agents directory can, so the router writes one per role from the
# chains, stepped down for the current budget state like any other decision.
CODEX_ROLE_MARKER='# Managed by agent-router from codex_chains; edit the router config, not this file.'
CODEX_ROLES='router-scout:trivial:read-only:Find where something lives or how it currently works. Read-only; best for narrow codebase lookups and lists of locations.
router-builder:execution::Make a well-scoped code change and run relevant checks. Use when the expected behavior is clear and the approach does not need a separate decision.
router-inspector:reasoning:read-only:Check a change against its intended behavior and report concrete defects. Read-only; useful before relying on a result.
router-navigator:reasoning:read-only:Map a multi-step change to the relevant code, dependencies, risks, and checks before implementation. Read-only.'

codex_agents_dir() {
  printf '%s' "${CODEX_AGENTS_DIR:-${CODEX_HOME:-$HOME/.codex}/agents}"
}

# codex_write_agents <all|refresh> -> writes role files; prints each path written.
# `refresh` touches only files this router already owns, so nothing appears in
# the agents directory unless the user opted in with `router agents` once.
# A file without the marker belongs to someone else and is never replaced.
codex_write_agents() {
  local mode="$1" dir state name tier sandbox desc eff pick model effort file tmp
  dir=$(codex_agents_dir)
  state=$(governor_state)
  while IFS=: read -r name tier sandbox desc; do
    file="$dir/$name.toml"
    if [ -f "$file" ]; then
      head -1 "$file" 2>/dev/null | grep -qxF "$CODEX_ROLE_MARKER" || {
        echo "router: $file is not managed by agent-router; left alone" >&2; continue; }
    elif [ "$mode" != all ]; then
      continue
    fi
    eff=$(governor_codex_tier "$state" "$tier")
    pick=$(jq -r --arg t "$eff" '.codex_chains[$t][0] | select(. != null) | "\(.model)\t\(.effort)"' "$ROUTER_CONFIG" 2>/dev/null)
    [ -n "$pick" ] || continue
    model=${pick%%$'\t'*}; effort=${pick#*$'\t'}
    mkdir -p "$dir" 2>/dev/null || return 1
    # Codex role names are identifiers; the file keeps the shared hyphenated name.
    tmp="$file.tmp.$$"
    {
      printf '%s\n' "$CODEX_ROLE_MARKER"
      printf 'name = "%s"\ndescription = "%s"\nmodel = "%s"\nmodel_reasoning_effort = "%s"\n' \
        "${name//-/_}" "$desc" "$model" "$effort"
      [ -z "$sandbox" ] || printf 'sandbox_mode = "%s"\n' "$sandbox"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else mv "$tmp" "$file" && printf '%s\n' "$file"; fi
  done <<ROLES
$CODEX_ROLES
ROLES
}
