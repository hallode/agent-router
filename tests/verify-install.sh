#!/usr/bin/env bash
# verify-install.sh — check a live installation, not the source tree.
#
# tests/run.sh proves the logic. This proves the wiring: that the paths in
# settings.json and config.toml point at files that exist, that both hosts get
# the same treatment, and that a hook invoked exactly as its host invokes it
# returns what the host expects.
#
# Exits nonzero on any failure so it can gate a release. Written after a rename
# silently pointed one hook at a file that did not exist and the ad-hoc check
# that "verified" it reported success anyway: a checker that cannot fail is not
# a check.
set -uo pipefail

ROUTER_HOME="${ROUTER_HOME:-$HOME/.claude/router}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want=$2 got=$3"; fi; }

echo "== files are present and executable =="
for f in hooks/claude-subagent.sh hooks/claude-advisor.sh hooks/claude-session.sh \
         hooks/codex-advisor.sh bin/ccr bin/cxr bin/router bin/codex-quota \
         bin/router-learn lib/classify.sh lib/config.sh lib/governor.sh lib/workspace.sh; do
  [ -x "$ROUTER_HOME/$f" ] && ok "$f" || bad "$f" "missing or not executable"
done

echo "== no name is doubled by a careless rename =="
# This file names the doubled prefixes it looks for, so it must exclude itself.
DOUBLED=$(grep -rlE 'claude-claude|codex-codex|router-router' \
  "$ROUTER_HOME" "$HOME/.claude/settings.json" "$HOME/.codex/config.toml" 2>/dev/null \
  | grep -v 'verify-install.sh' | head -3 | tr '\n' ' ')
if [ -n "$DOUBLED" ]; then
  bad "doubled prefixes" "$DOUBLED"
else
  ok "no doubled prefixes"
fi

echo "== Claude: every configured hook path exists =="
if [ -r "$HOME/.claude/settings.json" ]; then
  while IFS=$'\t' read -r ev cmd; do
    [ -n "$cmd" ] || continue
    p=$(printf '%s' "$cmd" | /usr/bin/sed 's/.*"\(.*\)".*/\1/')
    p=${p//\$HOME/$HOME}
    [ -x "$p" ] && ok "settings.json $ev" || bad "settings.json $ev" "$p not executable"
  done < <(jq -r '.hooks // {} | to_entries[] | .key as $e | .value[]? | .hooks[]?
                  | select(.command // "" | test("router")) | "\($e)\t\(.command)"' \
           "$HOME/.claude/settings.json" 2>/dev/null)
else
  bad "settings.json" "not readable"
fi

echo "== Codex: every configured hook path exists =="
if [ -r "$HOME/.codex/config.toml" ]; then
  while IFS=$'\t' read -r ev p; do
    [ -n "$p" ] || continue
    [ -x "$p" ] && ok "config.toml $ev" || bad "config.toml $ev" "$p not executable"
  done < <(python3 - <<'PY'
import tomllib, os, sys
try:
    d = tomllib.load(open(os.path.expanduser('~/.codex/config.toml'), 'rb'))
except Exception:
    sys.exit(0)
for ev, groups in (d.get('hooks') or {}).items():
    for g in groups:
        for h in g.get('hooks', []):
            print(ev, h.get('command','').replace('$HOME', os.path.expanduser('~')), sep='\t')
PY
)
else
  bad "config.toml" "not readable"
fi

echo "== Claude: the enforcing hook actually rewrites a model =="
# Pin the budget state first. The governor legitimately degrades these models
# when quota is tight, so asserting absolute models without pinning tests the
# weather rather than the router.
SAVED=$("$ROUTER_HOME/bin/router" state)
"$ROUTER_HOME/bin/router" state set NORMAL verify 0 >/dev/null
cs() { printf '%s' "$1" | bash "$ROUTER_HOME/hooks/claude-subagent.sh" \
        | jq -r '.hookSpecificOutput.updatedInput.model // "NONE"'; }
want "mechanical prompt -> haiku" haiku \
  "$(cs '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"grep for TODO comments"}}')"
want "implementation -> sonnet" sonnet \
  "$(cs '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"implement the retry middleware"}}')"
want "reviewer role -> opus" opus \
  "$(cs '{"tool_name":"Agent","tool_input":{"subagent_type":"router-reviewer","prompt":"x"}}')"

"$ROUTER_HOME/bin/router" state set "$SAVED" restore 0 >/dev/null

echo "== Codex: the advisor answers both of its events =="
ca() { printf '%s' "$1" | bash "$ROUTER_HOME/hooks/codex-advisor.sh" \
        | jq -r '.hookSpecificOutput.additionalContext // ""'; }
case "$(ca '{"hook_event_name":"SessionStart","cwd":"'"$PWD"'"}')" in
  *"budget state"*) ok "SessionStart injects budget state" ;;
  *) bad "SessionStart" "no budget state in output" ;;
esac
OUT=$(printf '%s' '{"hook_event_name":"SessionStart"}' | bash "$ROUTER_HOME/hooks/codex-advisor.sh")
case "$OUT" in
  *updatedInput*|*'"model"'*) bad "codex advisor" "must never emit a model" ;;
  *) ok "codex advisor emits no model" ;;
esac

echo "== both hosts pick a model from the same prompt =="
X=$("$ROUTER_HOME/bin/cxr" -n "why does this deadlock under load" 2>/dev/null | head -1)
case "$X" in *model=*) ok "cxr selects a Codex model" ;; *) bad "cxr" "$X" ;; esac
Y=$("$ROUTER_HOME/bin/ccr" -n "why does this deadlock under load" 2>/dev/null | tail -1)
case "$Y" in *--model*) ok "ccr selects a Claude model" ;; *) bad "ccr" "$Y" ;; esac

echo "== the two hosts share one governor =="
BEFORE=$("$ROUTER_HOME/bin/router" state)
"$ROUTER_HOME/bin/router" state set CONSERVE verify 0 >/dev/null
A=$("$ROUTER_HOME/bin/cxr" -n -t reasoning "x" 2>&1 | head -1)
B=$("$ROUTER_HOME/bin/ccr" -n -t reasoning "x" 2>&1 | head -1)
case "$A" in *CONSERVE*) ok "cxr sees the shared state" ;; *) bad "cxr state" "$A" ;; esac
case "$B" in *CONSERVE*) ok "ccr sees the shared state" ;; *) bad "ccr state" "$B" ;; esac
"$ROUTER_HOME/bin/router" state set "$BEFORE" restore 0 >/dev/null

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
