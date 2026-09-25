#!/usr/bin/env bash
# classify.sh — heuristic task tier classification. Zero LLM calls.
# bash 3.2 compatible (no associative arrays, no ${v,,}).
#
# Tiers, cheapest first:
#   trivial   mechanical / read-only / deterministic
#   execution normal implementation work            (default — safe fallback)
#   reasoning judgment, cross-system, design, audit
#
# Ordering rule: reasoning is tested first and wins over trivial. A prompt that
# looks mechanical but mentions a design decision is not mechanical.

# Lowercase and trim. The trim matters: callers join a description and a prompt,
# and an empty description leaves a leading space that defeats every ^-anchored
# pattern below — silently sending mechanical work to the middle tier.
router_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Signals that the task needs judgment rather than execution.
router_is_reasoning() {
  local t="$1"
  [[ "$t" =~ (architect|arsitektur|trade.?off|tradeoff) ]] && return 0
  [[ "$t" =~ (design|redesign|rancang|desain)([[:space:]]+[a-z0-9_.-]+){0,4}[[:space:]]+(system|systems|schema|api|architecture|arsitektur|module|modul|layout|structure|struktur|interface|contract|kontrak|flow|alur|package|service|pipeline|model|table|tabel) ]] && return 0
  [[ "$t" =~ (root[[:space:]]cause|akar[[:space:]]masalah|race[[:space:]]condition|deadlock|memory[[:space:]]leak|goroutine[[:space:]]leak) ]] && return 0
  [[ "$t" =~ (security[[:space:]](audit|review)|vulnerab|threat[[:space:]]model|sql[[:space:]]injection) ]] && return 0
  [[ "$t" =~ (investigat|diagnos|troubleshoot|debug|kenapa|mengapa) ]] && return 0
  [[ "$t" =~ (why[[:space:]](does|is|did|are|do)) ]] && return 0
  [[ "$t" =~ (performance[[:space:]](regression|bottleneck)|bottleneck|profiling) ]] && return 0
  [[ "$t" =~ (review[[:space:]]+(the[[:space:]]+)?(code|pr|diff|change|changes|implementation)) ]] && return 0
  [[ "$t" =~ (code[[:space:]]review|audit) ]] && return 0
  [[ "$t" =~ (migrat(e|ion)[[:space:]]+(across|multi)|rewrite|redesign|restructure) ]] && return 0
  [[ "$t" =~ (refactor[[:space:]]+across|split[[:space:]]+(the[[:space:]]+)?(package|module|service)) ]] && return 0
  [[ "$t" =~ (compare|bandingkan).*(approach|option|alternativ|pendekatan|opsi) ]] && return 0
  [[ "$t" =~ (strategy|strategi|plan[[:space:]]+(the|a|an)[[:space:]]) ]] && return 0
  [[ "$t" =~ (evaluate|assess|weigh)[[:space:]] ]] && return 0
  return 1
}

# Signals that the task is mechanical. Must be confident — a wrong Haiku costs a
# retry, which is more expensive than having used Sonnet in the first place.
router_is_trivial() {
  local t="$1"
  # A read-only opening verb does not make a mixed request read-only.
  # Keep narrowly mechanical fixes (typos, formatting, renames) cheap.
  if [[ "$t" =~ ^(fix|perbaiki)[[:space:]]+(the[[:space:]]+)?(typo|spelling|salah[[:space:]]ketik) ]] &&
     [[ ! "$t" =~ [[:space:]](and|dan|then|lalu)[[:space:]] ]]; then return 0; fi
  if [[ "$t" =~ ^update[[:space:]]+(the[[:space:]]+)?changelog ]] &&
     [[ ! "$t" =~ [[:space:]](and|dan|then|lalu)[[:space:]] ]]; then return 0; fi
  [[ "$t" =~ (^|[[:space:]])(implement|build|create|add|fix|perbaiki|buat|bangun|ubah|tambahkan|integrate|deploy|rewrite|update|write|tulis)([[:space:]]|$) ]] && return 1
  [[ "$t" =~ ^(list|ls|find|locate|grep|search|cari|cek|check|show|print|read|baca|count|hitung) ]] && return 0
  # Running a suite and reporting is mechanical; writing or fixing tests is not,
  # and those verbs already returned above.
  [[ "$t" =~ ^(run|jalankan)([[:space:]]+(the|all|semua))?([[:space:]]+(unit|integration))?[[:space:]]+tests? ]] && return 0
  [[ "$t" =~ ^((go|npm|pnpm|yarn|make|cargo)[[:space:]]+test|pytest)([[:space:]]|$) ]] && return 0
  [[ "$t" =~ ^(status|summari[sz]e|ringkas|jelaskan|explain|apa[[:space:]]+fungsi|what[[:space:]]+does)([[:space:]]|$) ]] && return 0
  [[ "$t" =~ (rename|ganti[[:space:]]nama|format|gofmt|prettier|lint|sort[[:space:]]imports|tidy|gofumpt) ]] && return 0
  [[ "$t" =~ (how[[:space:]]many|berapa[[:space:]]banyak|count[[:space:]]the) ]] && return 0
  [[ "$t" =~ (read[[:space:]]+(the[[:space:]]+)?file|show[[:space:]]+(me[[:space:]]+)?(the[[:space:]]+)?(content|file)) ]] && return 0
  [[ "$t" =~ (typo|spelling|salah[[:space:]]ketik) ]] && return 0
  [[ "$t" =~ (where[[:space:]]is.*(defined|declared)|di[[:space:]]mana.*didefinisikan) ]] && return 0
  [[ "$t" =~ (git[[:space:]](status|log|diff|branch|stash)) ]] && return 0
  [[ "$t" =~ (bump[[:space:]]version|update[[:space:]](the[[:space:]])?changelog) ]] && return 0
  [[ "$t" =~ (add[[:space:]]+(a[[:space:]]+)?comment|update[[:space:]]+(the[[:space:]]+)?(comment|docstring|godoc)) ]] && return 0
  [[ "$t" =~ (what[[:space:]]is[[:space:]]the[[:space:]]value|apa[[:space:]]isi) ]] && return 0
  return 1
}

# classify_tier <agent_type> <text> -> echoes tier
# Precedence: explicit agent-type map > reasoning signal > trivial signal > default.
classify_tier() {
  local agent_type="$1" raw="$2" t mapped
  t=$(router_lower "$raw")

  if [ -n "$agent_type" ] && [ -f "$ROUTER_CONFIG" ]; then
    mapped=$(jq -r --arg a "$agent_type" '.agent_type_tiers[$a] // empty' "$ROUTER_CONFIG" 2>/dev/null)
    # The router's own roles route even when a config predates them.
    if [ -z "$mapped" ]; then
      case "$agent_type" in
        router-scout)     mapped=trivial ;;
        router-builder)   mapped=execution ;;
        router-inspector|router-navigator) mapped=reasoning ;;
      esac
    fi
    if [ -n "$mapped" ]; then printf '%s' "$mapped"; return 0; fi
  fi

  if router_is_reasoning "$t"; then printf 'reasoning'; return 0; fi

  if router_is_trivial "$t"; then
    # A long prompt is rarely actually mechanical, whatever its opening verb.
    if [ "${#raw}" -gt 1500 ]; then printf 'execution'; else printf 'trivial'; fi
    return 0
  fi

  printf 'execution'
}
