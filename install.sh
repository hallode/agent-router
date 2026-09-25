#!/usr/bin/env bash
# Install separate Claude and Codex runtimes from this shared source checkout.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd -P)
CLAUDE_DEST="${CLAUDE_ROUTER_HOME:-$HOME/.claude/router}"
CODEX_DEST="${CODEX_ROUTER_HOME:-${CODEX_HOME:-$HOME/.codex}/router}"
BACKUP="${AGENT_ROUTER_BACKUP_HOME:-$HOME/.local/share/agent-router/pre-split}"
WITH_AGENTS=0
case "${1:-}" in
  '') ;;
  --with-agents) WITH_AGENTS=1 ;;
  *) echo 'usage: install.sh [--with-agents]' >&2; exit 2 ;;
esac
command -v jq >/dev/null || { echo 'install.sh: jq required' >&2; exit 1; }
[ "$CLAUDE_DEST" != "$CODEX_DEST" ] || { echo 'install.sh: host destinations must differ' >&2; exit 2; }

mkdir -p "$CLAUDE_DEST"/{bin,hooks,lib,shell,agents} "$CODEX_DEST"/{bin,hooks,lib,shell}
for lib in config.sh classify.sh governor.sh workspace.sh activity.sh controls.sh; do
  cp "$SRC/lib/$lib" "$CLAUDE_DEST/lib/$lib"
  cp "$SRC/lib/$lib" "$CODEX_DEST/lib/$lib"
done
cp "$SRC/lib/claude-model.sh" "$CLAUDE_DEST/lib/"
cp "$SRC/lib/claude-agent.sh" "$CLAUDE_DEST/lib/"
cp "$SRC/lib/codex-budget.sh" "$CODEX_DEST/lib/"
cp "$SRC/bin/ccr" "$CLAUDE_DEST/bin/"
cp "$SRC/bin/claude-router" "$CLAUDE_DEST/bin/router"
cp "$SRC/bin/cxr" "$CODEX_DEST/bin/"
cp "$SRC/bin/codex-router" "$CODEX_DEST/bin/router"
cp "$SRC/bin/codex-quota" "$CODEX_DEST/bin/"
cp "$SRC/hooks"/claude-*.sh "$CLAUDE_DEST/hooks/"
cp "$SRC/hooks/codex-advisor.sh" "$CODEX_DEST/hooks/"
cp "$SRC/shell/claude.zsh" "$CLAUDE_DEST/shell/"
cp "$SRC/shell/codex.zsh" "$CODEX_DEST/shell/"
cp "$SRC/agents"/router-*.md "$CLAUDE_DEST/agents/"
cp "$SRC/ROUTING.md" "$CLAUDE_DEST/"
chmod +x "$CLAUDE_DEST"/bin/* "$CLAUDE_DEST"/hooks/* "$CLAUDE_DEST"/lib/* \
  "$CODEX_DEST"/bin/* "$CODEX_DEST"/hooks/* "$CODEX_DEST"/lib/*

# One neutral, read-only user command. Runtime implementation stays host-local.
STATUS_DEST="${AGENT_ROUTER_STATUS_BIN:-$HOME/.local/bin/agent-router}"
mkdir -p "$(dirname "$STATUS_DEST")"
if [ -e "$STATUS_DEST" ] && ! cmp -s "$STATUS_DEST" "$SRC/bin/agent-router"; then
  echo "install.sh: refusing to replace existing $STATUS_DEST" >&2
  exit 1
fi
cp "$SRC/bin/agent-router" "$STATUS_DEST"
chmod +x "$STATUS_DEST"

# Keep a full, recoverable copy of the old mixed runtime before separating it.
MIGRATING=0
if [ -f "$CLAUDE_DEST/config.json" ] && jq -e 'has("codex_chains") or has("codex")' "$CLAUDE_DEST/config.json" >/dev/null; then
  MIGRATING=1
  mkdir -p "$BACKUP"
  [ -f "$BACKUP/config.json" ] || cp "$CLAUDE_DEST/config.json" "$BACKUP/config.json"
fi
CONFIG_SOURCE="$BACKUP/config.json"
[ -f "$CONFIG_SOURCE" ] || CONFIG_SOURCE="$SRC/config.example.json"

if [ ! -f "$CODEX_DEST/config.json" ]; then
  jq 'del(.degrade,.effort,.effort_comment,.compact,.advisor,.agent_type_tiers,.agent_type_tiers_comment)
      | .quota.command="$ROUTER_HOME/bin/codex-quota"' \
    "$CONFIG_SOURCE" > "$CODEX_DEST/config.json"
  echo "created $CODEX_DEST/config.json"
else
  echo "kept $CODEX_DEST/config.json"
fi
if [ ! -f "$CLAUDE_DEST/config.json" ]; then
  cp "$CONFIG_SOURCE" "$CLAUDE_DEST/config.json"
fi
if jq -e 'has("codex_chains") or has("codex")' "$CLAUDE_DEST/config.json" >/dev/null; then
  tmp="$CLAUDE_DEST/config.json.tmp.$$"
  jq 'del(.codex,.codex_chains)
      | .quota.command=""
      | .quota.comment="Optional Claude quota probe; leave empty unless configured."' \
    "$CLAUDE_DEST/config.json" > "$tmp"
  mv "$tmp" "$CLAUDE_DEST/config.json"
fi

# A former combined install may have host-crossing files and shared state.
# Archive, never discard, those exact router-owned artifacts.
archive_old() {
  local file="$1" name="$2"
  [ -e "$file" ] || return 0
  mkdir -p "$BACKUP"
  if [ -e "$BACKUP/$name" ]; then
    mv "$file" "$BACKUP/$name.$(date +%s).$$"
  else
    mv "$file" "$BACKUP/$name"
  fi
}
archive_old "$CLAUDE_DEST/hooks/codex-advisor.sh" codex-advisor.sh
archive_old "$CLAUDE_DEST/bin/cxr" cxr
archive_old "$CLAUDE_DEST/bin/codex-quota" codex-quota
archive_old "$CLAUDE_DEST/bin/router-learn" router-learn
archive_old "$CLAUDE_DEST/shell/router.zsh" router.zsh
archive_old "$CLAUDE_DEST/config.example.json" config.example.json
archive_old "$CLAUDE_DEST/README.md" README.md
archive_old "$CLAUDE_DEST/install.sh" install.sh
[ "$MIGRATING" -eq 0 ] || {
  archive_old "$CLAUDE_DEST/decisions.jsonl" decisions.jsonl
  archive_old "$CLAUDE_DEST/state.json" state.json
}
archive_old "$CLAUDE_DEST/tests" tests
archive_old "$CLAUDE_DEST/legacy-agents" legacy-agents

if [ "$WITH_AGENTS" -eq 1 ]; then
  mkdir -p "$HOME/.claude/agents"
  for role in scout builder inspector navigator; do
    cp "$CLAUDE_DEST/agents/router-$role.md" "$HOME/.claude/agents/"
  done
  cp "$CLAUDE_DEST/ROUTING.md" "$HOME/.claude/ROUTING.md"
  if [ -f "$HOME/.claude/CLAUDE.md" ] && ! grep -q 'ROUTING.md' "$HOME/.claude/CLAUDE.md"; then
    printf '@ROUTING.md\n' >> "$HOME/.claude/CLAUDE.md"
  fi
  # Codex roles are generated from its chains; SessionStart keeps them in step
  # with the budget state from then on.
  ROUTER_HOME="$CODEX_DEST" bash "$CODEX_DEST/bin/router" agents
fi

echo "Claude runtime: $CLAUDE_DEST"
echo "Codex runtime:  $CODEX_DEST"
echo "Status command: $STATUS_DEST status"
echo "Legacy files:   $BACKUP (when present)"
echo
echo 'Wire host hooks separately:'
echo "  Claude settings.json -> $CLAUDE_DEST/hooks/claude-*.sh"
echo "  Codex config.toml   -> $CODEX_DEST/hooks/codex-advisor.sh"
echo 'Source each wrapper from ~/.zshrc:'
echo "  source $CLAUDE_DEST/shell/claude.zsh"
echo "  source $CODEX_DEST/shell/codex.zsh"
