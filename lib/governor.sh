#!/usr/bin/env bash
# governor.sh — budget state machine driving tier degradation.
#
#   NORMAL    full configured map
#   CONSERVE  first budget-saving step
#   CRITICAL  stronger budget saving
#   DEPLETED  lowest configured budget tier
#
# State comes from, in precedence order:
#   1. a manual override (`router state set ...`), until it expires
#   2. a recorded rate-limit event, which escalates one level and decays
#   3. an optional quota command you configure, if you have one
# Absent all three, NORMAL. The governor never fails the caller: any error
# path returns NORMAL so a broken probe can never block a tool call.

ROUTER_HOME="${ROUTER_HOME:?set ROUTER_HOME to the host router directory}"
ROUTER_STATE="${ROUTER_STATE:-$ROUTER_HOME/state.json}"
ROUTER_LIMIT_TTL="${ROUTER_LIMIT_TTL:-3600}"   # a limit event decays after 1h

governor_init() {
  [ -f "$ROUTER_STATE" ] && return 0
  mkdir -p "$(dirname "$ROUTER_STATE")" 2>/dev/null
  printf '%s\n' '{"state":"NORMAL","reason":"init","updated":0,"expires":0}' > "$ROUTER_STATE"
}

governor_escalate_name() {
  case "$1" in
    NORMAL)   printf 'CONSERVE' ;;
    CONSERVE) printf 'CRITICAL' ;;
    *)        printf 'DEPLETED' ;;
  esac
}

# governor_state -> echoes the effective state, honouring expiry.
governor_state() {
  governor_init
  local now st exp
  now=$(date +%s)
  st=$(jq -r '.state // "NORMAL"' "$ROUTER_STATE" 2>/dev/null) || st=NORMAL
  exp=$(jq -r '.expires // 0' "$ROUTER_STATE" 2>/dev/null) || exp=0
  case "$st" in NORMAL|CONSERVE|CRITICAL|DEPLETED) ;; *) st=NORMAL ;; esac
  if [ "$exp" -gt 0 ] 2>/dev/null && [ "$now" -ge "$exp" ]; then
    governor_set NORMAL "expired" 0 >/dev/null 2>&1
    st=NORMAL
  fi
  printf '%s' "$st"
}

# governor_set <state> <reason> [ttl_seconds]
governor_set() {
  governor_init
  local st="$1" reason="${2:-manual}" ttl="${3:-0}" now exp tmp
  now=$(date +%s)
  exp=0
  [ "$ttl" -gt 0 ] 2>/dev/null && exp=$((now + ttl))
  tmp="$ROUTER_STATE.tmp.$$"
  jq -n --arg s "$st" --arg r "$reason" --argjson u "$now" --argjson e "$exp" \
     '{state:$s,reason:$r,updated:$u,expires:$e}' > "$tmp" 2>/dev/null \
     && mv "$tmp" "$ROUTER_STATE"
  printf '%s' "$st"
}

# governor_record_limit <source> — a provider said no. Escalate one level.
governor_record_limit() {
  local src="${1:-unknown}" cur next
  cur=$(governor_state)
  next=$(governor_escalate_name "$cur")
  governor_set "$next" "rate-limit:$src" "$ROUTER_LIMIT_TTL"
}

# governor_probe_quota — optional. Runs whatever command `quota.command` names,
# reads a used-percentage out of its JSON with `quota.percent_jq`, and sets the
# state from it. Unset by default: there is no portable way to ask a provider
# how much quota is left, so this stays a hook for whatever you happen to have.
# Without it the governor still works, driven by observed rate-limit errors.
governor_probe_quota() {
  local cmd filter out pct
  cmd=$(jq -r '.quota.command // ""' "$ROUTER_CONFIG" 2>/dev/null)
  [ -z "$cmd" ] && return 1
  filter=$(jq -r '.quota.percent_jq // "[.. | objects | (.usedPercent // .used_percent // empty)] | max"' \
           "$ROUTER_CONFIG" 2>/dev/null)
  out=$(eval "$cmd" 2>/dev/null) || return 1
  pct=$(printf '%s' "$out" | jq -r "$filter // empty" 2>/dev/null)
  [ -z "$pct" ] || [ "$pct" = "null" ] && return 1
  pct=${pct%.*}

  local c_conserve c_critical c_depleted ttl
  c_conserve=$(jq -r '.quota.conserve_at // 60' "$ROUTER_CONFIG" 2>/dev/null)
  c_critical=$(jq -r '.quota.critical_at // 85' "$ROUTER_CONFIG" 2>/dev/null)
  c_depleted=$(jq -r '.quota.depleted_at // 95' "$ROUTER_CONFIG" 2>/dev/null)
  ttl=$(jq -r '.quota.ttl_seconds // 900' "$ROUTER_CONFIG" 2>/dev/null)

  if   [ "$pct" -ge "$c_depleted" ] 2>/dev/null; then governor_set DEPLETED "quota:${pct}%" "$ttl"
  elif [ "$pct" -ge "$c_critical" ] 2>/dev/null; then governor_set CRITICAL "quota:${pct}%" "$ttl"
  elif [ "$pct" -ge "$c_conserve" ] 2>/dev/null; then governor_set CONSERVE "quota:${pct}%" "$ttl"
  else governor_set NORMAL "quota:${pct}%" "$ttl"
  fi
}

# governor_refresh_if_stale [max_age_seconds]
# Refresh the state from the quota command when the stored reading has gone
# stale. Callers that are about to pick a model use this so that "the governor
# sees the wall coming" does not depend on someone else having run `router
# probe` recently.
#
# An unexpired override — set by hand or by an observed rate-limit — is left
# alone: it was set because something was already known, and a probe must not
# quietly undo it. A probe that fails leaves the previous state untouched.
governor_refresh_if_stale() {
  local max_age="${1:-300}" now updated reason exp
  governor_init
  now=$(date +%s)
  updated=$(jq -r '.updated // 0' "$ROUTER_STATE" 2>/dev/null) || return 0
  reason=$(jq -r '.reason // ""'  "$ROUTER_STATE" 2>/dev/null)
  exp=$(jq -r '.expires // 0'     "$ROUTER_STATE" 2>/dev/null)

  case "$reason" in
    quota:*|init|expired) ;;                                   # probe-derived: replaceable
    *) [ "$exp" -gt "$now" ] 2>/dev/null && return 0 ;;        # live override: keep
  esac

  [ $((now - updated)) -lt "$max_age" ] 2>/dev/null && return 0
  governor_probe_quota >/dev/null 2>&1 || true
  return 0
}
