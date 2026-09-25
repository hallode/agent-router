#!/usr/bin/env bash
# workspace.sh — optional: map a directory to the account that should pay for it.
#
# OFF BY DEFAULT. With `workspaces.enabled` false — the shipped default — every
# function here returns empty and nothing in the router changes behaviour. Tier
# routing does not depend on any of this.
#
# Turn it on only if you hold more than one subscription and care which one a
# given directory bills. Account labels are yours to name; the router never
# interprets them, it only compares them.
#
#   "workspaces": {
#     "enabled": true,
#     "rules": [
#       {"prefix": "$HOME/src/oss",  "account": "personal"},
#       {"prefix": "$HOME/src/acme", "account": "employer"}
#     ],
#     "default": "",
#     "remote_patterns": [
#       {"pattern": "git\\.acme\\.com", "account": "employer"}
#     ]
#   }
#
# A rule matches on path prefix. `remote_patterns` then cross-checks the git
# remote, so a repository checked out under the wrong prefix is flagged rather
# than silently billed to the wrong account.

ROUTER_HOME="${ROUTER_HOME:?set ROUTER_HOME to the host router directory}"
ROUTER_CONFIG="${ROUTER_CONFIG:-$ROUTER_HOME/config.json}"

workspace_enabled() {
  [ -f "$ROUTER_CONFIG" ] || return 1
  [ "$(jq -r '.workspaces.enabled // false' "$ROUTER_CONFIG" 2>/dev/null)" = "true" ]
}

# workspace_account [dir] -> account label, or empty when disabled or unmatched.
workspace_account() {
  workspace_enabled || return 0
  local dir="${1:-$PWD}" n i prefix account
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || dir="${1:-$PWD}"

  n=$(jq -r '.workspaces.rules // [] | length' "$ROUTER_CONFIG" 2>/dev/null)
  [ -z "$n" ] || [ "$n" = "null" ] && n=0
  i=0
  while [ "$i" -lt "$n" ]; do
    prefix=$(jq -r  --argjson i "$i" '.workspaces.rules[$i].prefix'  "$ROUTER_CONFIG" 2>/dev/null)
    account=$(jq -r --argjson i "$i" '.workspaces.rules[$i].account' "$ROUTER_CONFIG" 2>/dev/null)
    prefix=${prefix/#\~/$HOME}
    prefix=${prefix//\$HOME/$HOME}
    prefix=${prefix%/}
    case "$dir/" in
      "$prefix"/*) printf '%s' "$account"; return 0 ;;
    esac
    i=$((i + 1))
  done

  jq -r '.workspaces.default // ""' "$ROUTER_CONFIG" 2>/dev/null
}

# workspace_remote_account [dir] -> account label implied by the git remote, or
# empty when there is no repo, no remote, or no pattern matches. An unmatched
# remote is unknown, never a guess.
workspace_remote_account() {
  workspace_enabled || return 0
  local dir="${1:-$PWD}" remote n i pat account
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  [ -z "$remote" ] && return 0

  n=$(jq -r '.workspaces.remote_patterns // [] | length' "$ROUTER_CONFIG" 2>/dev/null)
  [ -z "$n" ] || [ "$n" = "null" ] && n=0
  i=0
  while [ "$i" -lt "$n" ]; do
    pat=$(jq -r     --argjson i "$i" '.workspaces.remote_patterns[$i].pattern' "$ROUTER_CONFIG" 2>/dev/null)
    account=$(jq -r --argjson i "$i" '.workspaces.remote_patterns[$i].account' "$ROUTER_CONFIG" 2>/dev/null)
    if [ -n "$pat" ] && printf '%s' "$remote" | grep -qE "$pat"; then
      printf '%s' "$account"; return 0
    fi
    i=$((i + 1))
  done
  return 0
}

# workspace_mismatch [dir] -> a message when path and remote disagree, else empty.
workspace_mismatch() {
  workspace_enabled || return 0
  local dir="${1:-$PWD}" by_path by_remote remote
  by_path=$(workspace_account "$dir")
  by_remote=$(workspace_remote_account "$dir")
  [ -z "$by_path" ] || [ -z "$by_remote" ] && return 0
  [ "$by_path" = "$by_remote" ] && return 0
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null)
  printf 'path implies account "%s" but remote %s implies "%s"' "$by_path" "$remote" "$by_remote"
}

# workspace_account_allowed <config-key> [dir]
# Returns 0 (allowed) when the check does not apply at all: feature disabled, no
# allow-list configured for that key, or the directory's account is unknown.
workspace_account_allowed() {
  local key="$1" dir="${2:-$PWD}" n acct allowed
  workspace_enabled || return 0
  n=$(jq -r --arg k "$key" '.[$k].allowed_accounts // [] | length' "$ROUTER_CONFIG" 2>/dev/null)
  [ -z "$n" ] || [ "$n" = "null" ] && n=0
  [ "$n" -eq 0 ] && return 0
  acct=$(workspace_account "$dir")
  [ -z "$acct" ] && return 0
  allowed=$(jq -r --arg k "$key" --arg a "$acct" \
    '[.[$k].allowed_accounts[] | select(. == $a)] | length' "$ROUTER_CONFIG" 2>/dev/null)
  [ "$allowed" -gt 0 ] 2>/dev/null
}
