#!/usr/bin/env bash
# Verify the two installed runtimes are functional and physically separate.
set -uo pipefail
CLAUDE_DEST="${CLAUDE_ROUTER_HOME:-$HOME/.claude/router}"
CODEX_DEST="${CODEX_ROUTER_HOME:-${CODEX_HOME:-$HOME/.codex}/router}"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

echo '== host files =='
command -v agent-router >/dev/null 2>&1 && ok || bad 'agent-router status command missing'
for f in bin/ccr bin/router hooks/claude-advisor.sh hooks/claude-session.sh hooks/claude-subagent.sh shell/claude.zsh lib/claude-model.sh lib/claude-agent.sh; do
  [ -f "$CLAUDE_DEST/$f" ] && ok || bad "Claude missing $f"
done
for f in bin/cxr bin/router bin/codex-quota hooks/codex-advisor.sh shell/codex.zsh lib/codex-budget.sh; do
  [ -f "$CODEX_DEST/$f" ] && ok || bad "Codex missing $f"
done
for f in bin/cxr bin/codex-quota hooks/codex-advisor.sh shell/codex.zsh lib/codex-budget.sh; do
  [ ! -e "$CLAUDE_DEST/$f" ] && ok || bad "Codex file in Claude: $f"
done
for f in bin/ccr hooks/claude-advisor.sh hooks/claude-session.sh hooks/claude-subagent.sh shell/claude.zsh lib/claude-model.sh; do
  [ ! -e "$CODEX_DEST/$f" ] && ok || bad "Claude file in Codex: $f"
done
cross=$(grep -Ril 'codex' "$CLAUDE_DEST/bin" "$CLAUDE_DEST/hooks" "$CLAUDE_DEST/lib" "$CLAUDE_DEST/shell" 2>/dev/null | head -1)
[ -z "$cross" ] && ok || bad "Codex reference in Claude runtime: $cross"
cross=$(grep -Ril 'claude' "$CODEX_DEST/bin" "$CODEX_DEST/hooks" "$CODEX_DEST/lib" "$CODEX_DEST/shell" 2>/dev/null | head -1)
[ -z "$cross" ] && ok || bad "Claude reference in Codex runtime: $cross"

echo '== configs and independent state =='
jq -e 'has("degrade") and (has("codex_chains")|not) and (.quota.command == "")' "$CLAUDE_DEST/config.json" >/dev/null 2>&1 && ok || bad 'Claude config is mixed'
jq -e 'has("codex_chains") and (has("degrade")|not)' "$CODEX_DEST/config.json" >/dev/null 2>&1 && ok || bad 'Codex config is mixed'
case "$(ROUTER_HOME="$CLAUDE_DEST" bash "$CLAUDE_DEST/bin/router" status 2>/dev/null)" in *'host       claude'*) ok ;; *) bad 'Claude router status' ;; esac
case "$(ROUTER_HOME="$CODEX_DEST" bash "$CODEX_DEST/bin/router" status 2>/dev/null)" in *'host       codex'*) ok ;; *) bad 'Codex router status' ;; esac
case "$(ROUTER_HOME="$CLAUDE_DEST" bash "$CLAUDE_DEST/bin/ccr" -n 'find the config file' 2>/dev/null)" in *'--model'*) ok ;; *) bad 'Claude prompt launch' ;; esac
case "$(ROUTER_HOME="$CODEX_DEST" bash "$CODEX_DEST/bin/cxr" -n 'find the config file' 2>/dev/null)" in *'model='*) ok ;; *) bad 'Codex prompt launch' ;; esac

echo '== configured hooks =='
if [ -r "$HOME/.codex/config.toml" ]; then
  if grep -qF 'command = "$HOME/.codex/router/hooks/codex-advisor.sh"' "$HOME/.codex/config.toml"; then ok; else bad 'Codex hook path'; fi
  if grep -qF 'command = "$HOME/.claude/router/hooks/codex-advisor.sh"' "$HOME/.codex/config.toml"; then bad 'Codex hook still uses Claude path'; else ok; fi
else bad 'Codex config.toml unreadable'; fi
if [ -r "$HOME/.claude/settings.json" ]; then
  jq -e '.hooks | tostring | contains(".claude/router/hooks/claude-")' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok || bad 'Claude hook path'
else bad 'Claude settings.json unreadable'; fi
if [ -r "$HOME/.zshrc" ]; then
  grep -qF '/.claude/router/shell/claude.zsh' "$HOME/.zshrc" && ok || bad 'Claude wrapper source'
  grep -qF '/.codex/router/shell/codex.zsh' "$HOME/.zshrc" && ok || bad 'Codex wrapper source'
  if grep -qF '/.claude/router/shell/router.zsh' "$HOME/.zshrc"; then bad 'legacy mixed wrapper still sourced'; else ok; fi
fi

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
