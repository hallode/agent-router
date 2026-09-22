#!/usr/bin/env bash
# install.sh — copy agent-router into ~/.claude/router and print the hook config.
#
# Deliberately does not edit settings.json for you: hooks run arbitrary commands
# on every tool call, and that file is worth reading before something appends to
# it. The JSON to paste is printed at the end.
#
#   ./install.sh                 install to ~/.claude/router
#   ./install.sh <dir>           install somewhere else
#   ./install.sh --with-agents   also install the four standard roles and
#                                ROUTING.md into ~/.claude/
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd -P)
DEST="$HOME/.claude/router"
WITH_AGENTS=0

for arg in "$@"; do
  case "$arg" in
    --with-agents) WITH_AGENTS=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) DEST="$arg" ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

for d in lib hooks bin tests agents shell; do
  [ -d "$SRC/$d" ] || continue
  mkdir -p "$DEST/$d"
  cp "$SRC/$d"/* "$DEST/$d/" 2>/dev/null || true
done
# The test suite builds its fixture from the example config, so it ships too.
for f in config.example.json ROUTING.md README.md; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/$f"
done
chmod +x "$DEST"/lib/*.sh "$DEST"/hooks/*.sh "$DEST"/bin/* "$DEST"/tests/*.sh 2>/dev/null || true

if [ -f "$DEST/config.json" ]; then
  echo "kept existing $DEST/config.json"
else
  cp "$SRC/config.example.json" "$DEST/config.json"
  echo "created $DEST/config.json"
fi

echo
echo "running tests..."
bash "$DEST/tests/run.sh" | tail -3

# The unit suite proves the logic; this proves the wiring on this machine.
if [ -x "$DEST/tests/verify-install.sh" ]; then
  echo
  echo "verifying the installation..."
  ROUTER_HOME="$DEST" bash "$DEST/tests/verify-install.sh" | tail -3 || {
    echo "verify-install reported problems — read the output above before relying on it" >&2
  }
fi

if [ "$WITH_AGENTS" -eq 1 ]; then
  mkdir -p "$HOME/.claude/agents"
  cp "$DEST"/agents/*.md "$HOME/.claude/agents/" 2>/dev/null || true
  cp "$DEST/ROUTING.md" "$HOME/.claude/ROUTING.md" 2>/dev/null || true
  if [ -f "$HOME/.claude/CLAUDE.md" ] && ! grep -q 'ROUTING.md' "$HOME/.claude/CLAUDE.md"; then
    printf '@ROUTING.md\n' >> "$HOME/.claude/CLAUDE.md"
    echo "appended @ROUTING.md to ~/.claude/CLAUDE.md"
  fi
  echo "installed the four standard roles into ~/.claude/agents/"
  echo "(they become available in your NEXT Claude Code session, not this one)"
fi

cat <<EOF

installed to $DEST

The router serves two hosts. Wire up whichever you use — they share one config,
one governor and one decision log, so installing both is the point.

1. Claude Code — add to ~/.claude/settings.json:

  "hooks": {
    "PreToolUse":       [{"matcher": "Agent", "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/claude-subagent.sh\\"", "timeout": 10}]}],
    "UserPromptSubmit": [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/claude-advisor.sh\\"",  "timeout": 10}]}],
    "SessionStart":     [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/claude-session.sh\\"",  "timeout": 5}]}],
    "PostModelSwitch":  [{"matcher": "",      "hooks": [{"type": "command", "command": "bash \\"\$HOME/.claude/router/hooks/claude-session.sh\\"",  "timeout": 5}]}]
  }

2. Codex — add to ~/.codex/config.toml:

  [[hooks.SessionStart]]
  [[hooks.SessionStart.hooks]]
  type = "command"
  command = "\$HOME/.claude/router/hooks/codex-advisor.sh"
  timeout = 10

  [[hooks.UserPromptSubmit]]
  [[hooks.UserPromptSubmit.hooks]]
  type = "command"
  command = "\$HOME/.claude/router/hooks/codex-advisor.sh"
  timeout = 10

  Codex hooks cannot set a subagent's model, so this side injects budget state
  rather than choosing models. Model selection happens at launch, via cxr.

  Then fill in codex_chains in $DEST/config.json with models your account has:

    jq -r '.models[].slug' ~/.codex/models_cache.json

3. Both hosts, invisibly — add to ~/.zshrc:

  [[ -r "\$HOME/.claude/router/shell/router.zsh" ]] && source "\$HOME/.claude/router/shell/router.zsh"

  Then \`claude\` and \`codex\` route themselves. Subcommands, flags and
  explicit overrides pass through untouched.

4. Start in dry-run and read the log for a few days:

  $DEST/bin/router enforce false
  $DEST/bin/router status
  $DEST/bin/router log 20
  $DEST/bin/router enforce true

EOF
[ "$WITH_AGENTS" -eq 0 ] && echo "Re-run with --with-agents to also install the four standard roles."
exit 0
