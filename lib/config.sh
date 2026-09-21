#!/usr/bin/env bash
# config.sh — effective config resolution.
#
# The global config at $ROUTER_CONFIG is the default and needs no setup. A
# repository that wants different routing ships `.agent-router.json` at its
# root; the router walks up from the working directory, finds the nearest one,
# and merges it over the global config for that call only.
#
# Merge is recursive for objects and wholesale for arrays, so a project can
# override one tier without restating the rest:
#
#   {"agent_type_tiers": {"my-migration-agent": "reasoning"}}
#
# The global file is never modified. If anything goes wrong the global config is
# used unchanged — a malformed project file must not break routing.

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"
ROUTER_CONFIG="${ROUTER_CONFIG:-$ROUTER_HOME/config.json}"
ROUTER_PROJECT_FILE="${ROUTER_PROJECT_FILE:-.agent-router.json}"

# router_find_project_config [dir] -> path of the nearest project config, or empty.
# Stops at $HOME or / so it never escapes into unrelated parents.
router_find_project_config() {
  local dir="${1:-$PWD}"
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/$ROUTER_PROJECT_FILE" ]; then
      printf '%s' "$dir/$ROUTER_PROJECT_FILE"
      return 0
    fi
    [ "$dir" = "$HOME" ] && break
    dir=$(dirname "$dir")
  done
  return 0
}

# router_effective_config [dir] -> path to a config to read.
# Either $ROUTER_CONFIG itself, or a temp file the caller should delete. Check
# with router_is_temp_config before removing anything.
router_effective_config() {
  local dir="${1:-$PWD}" proj merged
  proj=$(router_find_project_config "$dir")
  if [ -z "$proj" ]; then printf '%s' "$ROUTER_CONFIG"; return 0; fi
  jq -e . "$proj" >/dev/null 2>&1 || { printf '%s' "$ROUTER_CONFIG"; return 0; }

  merged=$(mktemp "${TMPDIR:-/tmp}/agent-router.XXXXXX") || {
    printf '%s' "$ROUTER_CONFIG"; return 0; }
  if jq -s '.[0] * .[1]' "$ROUTER_CONFIG" "$proj" > "$merged" 2>/dev/null \
     && [ -s "$merged" ]; then
    printf '%s' "$merged"
  else
    rm -f "$merged"
    printf '%s' "$ROUTER_CONFIG"
  fi
}

router_is_temp_config() {
  case "$1" in
    "$ROUTER_CONFIG") return 1 ;;
    *agent-router.*)  return 0 ;;
    *)                return 1 ;;
  esac
}
