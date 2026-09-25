#!/usr/bin/env bash
# controls.sh — the `router` subcommands both hosts answer the same way.
# Each host's bin/router handles its own model commands and delegates the rest.

# router_control <subcommand> [args] -> handles state|probe|log|stats|enforce.
# Returns 3 for a subcommand it does not own, so the caller can print usage.
router_control() {
  local value tmp
  case "$1" in
    state)
      case "${2:-}" in
        '') governor_state; echo ;;
        set) governor_set "${3:?state required}" "${4:-manual}" "${5:-0}"; echo ;;
        *) return 2 ;;
      esac ;;
    probe)
      governor_probe_quota >/dev/null 2>&1 || true
      printf 'state      %s\n' "$(governor_state)" ;;
    log)
      tail -n "${2:-20}" "$ROUTER_LOG" 2>/dev/null \
        | jq -r '[.ts,.action,.tier//"-",.model//"-",.description] | @tsv' 2>/dev/null ;;
    stats)
      [ -s "$ROUTER_LOG" ] || { echo 'no decisions logged yet'; return 0; }
      jq -rs 'group_by(.model) | map({model:.[0].model,n:length}) | sort_by(-.n) | .[] | "\(.n)\t\(.model)"' "$ROUTER_LOG" ;;
    enforce)
      # Always the global file: a merged project config is a throwaway copy.
      value="${2:?true|false}"; tmp="$ROUTER_BASE_CONFIG.tmp.$$"
      jq --argjson v "$value" '.enforce=$v' "$ROUTER_BASE_CONFIG" > "$tmp" && mv "$tmp" "$ROUTER_BASE_CONFIG"
      printf 'enforce=%s\n' "$value" ;;
    *) return 3 ;;
  esac
}

# router_status_header <host> -> the first lines of `router status`.
router_status_header() {
  printf 'host       %s\nstate      %s\nenforce    %s\n' \
    "$1" "$(governor_state)" "$(jq -r '.enforce' "$ROUTER_CONFIG")"
}
